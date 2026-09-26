defmodule PhpBeam.Eval.Call do
  @moduledoc """
  The call protocol: named/closure/method/static dispatch, builtin invocation
  (registry + higher-order), parameter binding (positional + named + spread,
  L1.5), and the two gateway functions builtins use to re-enter semantics
  (call_cb / assign via Eval). Extracted from Eval verbatim (P2a).
  """

  alias PhpBeam.Eval
  alias PhpBeam.{Env, Error, Interp, PArray, Pattern, Value}

  def do_call(callee, args, env, interp) do
    case callee do
      {:static_call, {:cname, _, ["Closure"]}, {:lit_name, "bind"}, _} = _skip ->
        # ClassLoader's Closure::bind(...) — Closure is native; calling it
        # statically lands here; route to the native method
        eval({:static_call, {:cname, false, ["Closure"]}, {:lit_name, "bind"}, args}, env, interp)

      {:var, name} ->
        case Env.lookup(env, interp, name) do
          {:ok, v} -> call_value(deref(v, interp), args, env, interp)
          _ -> {{:unwind, {:fatal, "Undefined variable $#{name}"}}, env, interp}
        end

      {:closure, _, _, _, _, _} ->
        # IIFE: evaluate the closure then call it
        case eval(callee, env, interp) do
          {{:val, v}, e2, i2} -> call_value(deref(v, i2), args, e2, i2)
          unw -> unw
        end

      # immediate FCC invocation: `strlen(...)("x")`, `$o->m(...)(7)`
      fcc when elem(fcc, 0) in [:fcc, :method_fcc, :static_fcc, :value_fcc] ->
        case eval(fcc, env, interp) do
          {{:val, v}, e2, i2} -> call_value(v, args, e2, i2)
          unw -> unw
        end

      {:const, parts, fq} ->
        name = Enum.join(parts, "\\") |> String.downcase()

        case engine_ho(name, args, env, interp) do
          :not_mine ->
            call_named(parts, name, fq, args, env, interp)

          result ->
            result
        end

      _ ->
        {{:unwind, {:fatal, "unsupported call target"}}, env, interp}
    end
  end

  def call_named(parts, name, fq, args, env, interp) do
    case resolve_function(name, fq, interp) do
      {:user, _params, _body, _def_file, _def_line, _ns, _uses} = fn_def ->
        call_function(fn_def, name, args, env, interp, false)

      {:user_gen, _params, _body, _def_file, _def_line, _ns, _uses} = fn_def ->
        call_generator_fn(fn_def, name, args, env, interp)

      # higher-order builtins (registry v2): raw mode receives argument ASTs
      # (lvalue writeback), eval mode receives evaluated values
      %{ho: %{args: :raw}} = entry ->
        asts =
          Enum.map(args, fn
            {:arg, e, _, _} -> e
            {:arg_spread, e, _} -> e
          end)

        entry.ho.fun.(asts, env, interp)

      %{ho: %{args: :eval}} = entry ->
        case resolve_args(eval_args(args, env, interp, false)) do
          {:ok, vals, it} -> entry.ho.fun.(vals, env, it || interp)
          {:unwind, u, it} -> {{:unwind, u}, env, it || interp}
        end

      %{fun: _} = entry ->
        call_builtin(entry, name, args, env, interp)

      :error ->
        fname = Enum.join(parts, "\\")
        {{:unwind, {:fatal, "Call to undefined function " <> fname <> "()"}}, env, interp}
    end
  end

  # generator factory call: bind params (ArgumentCountError still applies at
  # call time), then hand the prepared env/body to the lazy generator

  def call_generator_fn(
        {:user_gen, params, body, def_file, def_line, dns, duses},
        name,
        args,
        env,
        interp
      ) do
    fenv = Env.function_scope(name, name)

    case bind_params(params, args, fenv, env, interp, name, name, {def_file, def_line}) do
      {:ok, binds, vals, _srcs, interp2} ->
        fenv2 =
          Enum.reduce(binds, %{fenv | args: vals}, fn {n, v}, acc ->
            %{acc | vars: Map.put(acc.vars, n, v)}
          end)

        # generator bodies evaluate __DIR__ against their defining file and
        # resolve names under the defining ns/uses
        i3 = %{
          interp2
          | file_stack: [def_file | interp2.file_stack],
            ns: dns || interp2.ns,
            uses: duses || interp2.uses
        }

        {res, env2, interp4} = start_generator(fenv2, body, env, i3)

        {res, env2, %{pop_file(interp4) | ns: interp2.ns, uses: interp2.uses}}

      {{:unwind, _} = u, _, it2} ->
        {u, env, it2}
    end
  end

  # ─────────────────── higher-order builtins (need the evaluator) ───────────────────

  def call_value({:fcc, inner}, args, env, interp),
    do: invoke_fcc(inner, args, env, interp)

  def call_value({:method_fcc, _, _} = f, args, env, interp),
    do: invoke_fcc(f, args, env, interp)

  def call_value({:static_fcc, _, _} = f, args, env, interp),
    do: invoke_fcc(f, args, env, interp)

  def call_value(
        {:closure, params, body, captures, _arrow?, def_file, def_line, gen?},
        args,
        env,
        interp
      ) do
    # captures may hold {:ref, id} cells for by-ref uses; reads and writes
    # flow through Env.lookup / assign naturally
    {this, called_class, scope_class} =
      case Map.get(captures, :__obj_ctx) do
        nil -> {nil, nil, nil}
        ctx -> {Map.get(ctx, :this), Map.get(ctx, :called_class), Map.get(ctx, :scope_class)}
      end

    fenv = %Env{
      function: "{closure}",
      statics_key: nil,
      closure_captures: Map.delete(captures, :__obj_ctx) |> Map.delete(:__ns_ctx),
      this: this,
      called_class: called_class,
      scope_class: scope_class
    }

    # php names closures by definition site: {closure:file:line}
    cname = "{closure:#{def_file}:#{def_line}}"

    case bind_params(params, args, fenv, env, interp, cname, cname, {def_file, def_line}) do
      {:ok, binds, vals, _srcs, interp2} ->
        fenv2 =
          Enum.reduce(binds, %{fenv | args: vals}, fn {n, v}, acc ->
            %{acc | vars: Map.put(acc.vars, n, v)}
          end)

        # defining-site ns/uses ride the closure (see eval.ex creation)
        {dns, duses} =
          case Map.get(captures, :__ns_ctx) do
            {ns, uses} -> {ns, uses}
            nil -> {interp2.ns, interp2.uses}
          end

        if gen? do
          {res, env2, interp3} =
            start_generator(fenv2, body, env, %{
              interp2
              | file_stack: [def_file | interp2.file_stack],
                ns: dns,
                uses: duses
            })

          {res, env2, pop_file(%{interp3 | ns: interp2.ns, uses: interp2.uses})}
        else
          interp2 = Interp.push_frame(interp2, cname, vals)
          # closure bodies evaluate __DIR__ against their defining file
          interp2 = %{interp2 | file_stack: [def_file | interp2.file_stack], ns: dns, uses: duses}

          case Interp.exec_stmts(body, fenv2, interp2) do
            # return the CALLER's env (like named functions): the closure
            # scope must not clobber the caller's locals — by-ref params and
            # use-cells flow through interp.refs, not through env identity
            {:ok, _e, i} ->
              {{:val, :null}, env,
               Interp.pop_frame(pop_file_once(%{i | ns: interp.ns, uses: interp.uses}))}

            {{:unwind, {:return, v}}, _, i} ->
              {{:val, v}, env,
               Interp.pop_frame(pop_file_once(%{i | ns: interp.ns, uses: interp.uses}))}

            {{:unwind, _} = u, _, i} ->
              {u, env, %{i | ns: interp.ns, uses: interp.uses}}
          end
        end

      {{:unwind, _} = u, _, it2} ->
        {u, env, it2}
    end
  end

  def call_cb(cb, call_args, env, interp)

  def call_cb({:closure, _, _, _, _, _, _, _} = closure_value, call_args, env, interp),
    do: call_value(closure_value, wrap_args(call_args), env, interp)

  def call_cb({:closure, _, _, _, _, _} = closure_ast, call_args, env, interp) do
    case eval(closure_ast, env, interp) do
      {{:val, v}, e2, i2} -> call_value(deref(v, i2), call_args, e2, i2)
      unw -> unw
    end
  end

  def call_cb({:string, fname}, call_args, env, interp) do
    call_named([fname], String.downcase(fname), false, wrap_args(call_args), env, interp)
  end

  def call_cb({:fcc, inner}, call_args, env, interp),
    do: call_cb(inner, call_args, env, interp)

  def call_cb({:method_fcc, obj_ref, mname}, call_args, env, interp) do
    eval(
      {:method_call, {:lit_val, obj_ref}, {:lit_name, mname}, wrap_args(call_args), false},
      env,
      interp
    )
  end

  def call_cb({:static_fcc, key, mname}, call_args, env, interp) do
    eval(
      {:static_call, {:cname, false, [key]}, {:lit_name, mname}, wrap_args(call_args)},
      env,
      interp
    )
  end

  def call_cb({:array, arr}, call_args, env, interp) do
    case PArray.values(arr) do
      [{:object, _} = obj_ref, {:string, m}] ->
        # php: unreachable-via-call_user_func* callbacks raise a catchable
        # TypeError naming the caller; direct $cb() keeps the plain Error
        obj = get_object(interp, obj_ref)
        meth = PhpBeam.Classes.find_method(interp, obj.class, m)
        caller = call_cb_caller(interp)

        if (meth && meth.visibility != :public) and
             caller in ~w(call_user_func call_user_func_array) and
             not cb_scope_ok?(env.scope_class, meth, obj.class, interp) do
          native_throw(
            "TypeError",
            "#{caller}(): Argument #1 ($callback) must be a valid callback, cannot access " <>
              "#{meth.visibility} method #{obj_display(interp, obj.class)}::#{meth.name}()",
            env,
            interp,
            "#{caller}(Array)"
          )
        else
          eval(
            {:method_call, {:lit_val, obj_ref}, {:lit_name, m}, wrap_args(call_args), false},
            env,
            interp
          )
        end

      [{:string, c}, {:string, m}] ->
        eval(
          {:static_call, {:cname, false, [c]}, {:lit_name, m}, wrap_args(call_args)},
          env,
          interp
        )

      _ ->
        {{:unwind, {:fatal, "Value not callable"}}, env, interp}
    end
  end

  def call_cb(_, _call_args, env, interp) do
    {{:unwind, {:fatal, "Value not callable"}}, env, interp}
  end

  def call_count_method(obj_ref, interp) do
    case PhpBeam.Classes.find_method(
           interp,
           PhpBeam.Eval.get_object(interp, obj_ref).class,
           "count"
         ) do
      nil -> {{:val, {:int, 1}}, nil, interp}
      m -> call_php_method(obj_ref, m, [], nil, interp)
    end
  end

  def call_php_method(obj_ref, method, args, env, interp) do
    try do
      call_php_method_inner(obj_ref, method, args, env, interp)
    catch
      {:fatal_violation, msg, e, i} -> {{:unwind, {:fatal, msg}}, e, i}
    end
  end

  def call_constructor({:object, _} = obj_ref, args, env, interp) do
    obj = get_object(interp, obj_ref)

    case PhpBeam.Classes.find_method(interp, obj.class, "__construct") do
      nil ->
        {{:val, obj_ref}, env, interp}

      method ->
        case call_php_method(obj_ref, method, args, env, interp) do
          {{:val, _ret}, e2, i2} -> {{:val, obj_ref}, e2, i2}
          # propagate with the method's interp: side effects (objects, output)
          # made before the throw must survive
          {{:unwind, _} = u, _, it2} -> {u, env, it2}
        end
    end
  end

  def call_function(
        {:user, params, body, def_file, def_line, dns, duses},
        name,
        args,
        env,
        interp,
        _from_method?
      ) do
    fenv = Env.function_scope(name, name)

    case bind_params(params, args, fenv, env, interp, name, name, {def_file, def_line}) do
      {:ok, binds, vals, srcs, interp2} ->
        interp2 = Interp.push_frame(interp2, name, vals)

        # write back by-ref arguments
        fenv2 =
          Enum.reduce(binds, %{fenv | args: vals}, fn {n, v}, acc ->
            %{acc | vars: Map.put(acc.vars, n, v)}
          end)

        # php attributes errors inside a function to its DEFINING file and
        # compiles it with that file's ns/use aliases
        interp2 = %{
          interp2
          | file_stack: [def_file | interp2.file_stack],
            ns: dns || interp2.ns,
            uses: duses || interp2.uses
        }

        {res, _, interp3} = Interp.exec_stmts(body, fenv2, interp2)

        {interp4, env_out} =
          write_back_refs(params, srcs, env, fenv2, interp3)

        interp5 = Interp.pop_frame(pop_file_once(interp4))

        restore = fn i -> %{i | ns: interp.ns, uses: interp.uses} end

        case res do
          :ok -> {{:val, :null}, env_out, restore.(interp5)}
          {:unwind, {:return, v}} -> {{:val, v}, env_out, restore.(interp5)}
          # a throw escaping keeps its frame alive for the uncaught trace
          {:unwind, _} = u -> {{:unwind, elem(u, 1)}, env_out, restore.(interp4)}
        end

      {{:unwind, _} = u, _, it2} ->
        {u, env, it2}
    end
  end

  def call_builtin(entry, name, args, env, interp) do
    %{fun: fun, refs: ref_positions} = entry
    skip_positions = Map.get(entry, :skip_eval_refs)

    {arg_list, ref_set} =
      {args, MapSet.new(skip_positions || [])}

    {results, _env2, _it2} =
      Enum.reduce(arg_list |> Enum.with_index(), {[], env, interp}, fn {a, idx}, {acc, en, it} ->
        if MapSet.member?(ref_set, idx) do
          # ONLY for pure-output refs (headers_sent's &$file): a placeholder
          # avoids warnings php never emits. Sort-style in-out refs evaluate.
          {[{{:val, :null, nil, a}, en, it} | acc], en, it}
        else
          case a do
            {:arg_spread, e, _} ->
              case eval(e, en, it) do
                {{:val, {:array, arr}}, en2, it2} ->
                  triples =
                    Enum.map(PArray.to_pairs(arr), fn
                      {k, v} when is_binary(k) -> {:val, v, k, a}
                      {_, v} -> {:val, v, nil, a}
                    end)

                  {Enum.reverse(Enum.map(triples, &{&1, en2, it2})) ++ acc, en2, it2}

                {{:val, _}, en2, it2} ->
                  {acc, en2, warn(en2, it2, "only arrays can be spread")}

                {{:unwind, _} = unw, en2, it2} ->
                  {[{unw, en2, it2} | acc], en2, it2}
              end

            {:arg, e, _, aname} ->
              case eval(e, en, it) do
                {{:val, v}, en2, it2} -> {[{{:val, v, aname, a}, en2, it2} | acc], en2, it2}
                {{:unwind, _} = unw, en2, it2} -> {[{unw, en2, it2} | acc], en2, it2}
              end
          end
        end
      end)

    case resolve_named_results(Enum.reverse(results)) do
      {:unwind, u, it} ->
        {{:unwind, u}, env, it || interp}

      {:ok, triples, it} ->
        case reorder_builtin_args(entry, triples) do
          {:error, msg} ->
            named_arg_throw(msg, env, it || interp)

          {:ok, vals} ->
            call_resolved_builtin(fun, vals, args, ref_positions, env, it || interp, name)
        end
    end
  end

  # like resolve_args but preserves the named-arg triples for reordering

  def call_resolved_builtin(fun, vals, args, ref_positions, env, interp, name \\ "") do
    case fun.(vals, interp, %{env: env}) do
      {:ok, {:unwind, {:php_throw, {:native_error, _, _} = ne}}, interp3} ->
        {obj_ref, interp4} = materialize_native(ne, interp3)
        i5 = Interp.push_frame(interp4, name, vals)
        {{:unwind, {:php_throw, obj_ref}}, env, i5}

      {:ok, v, interp3} ->
        {{:val, v}, env, interp3}

      # already-shaped throws (stream TypeErrors materialize + frame themselves)
      {:unwind, u, interp3} ->
        {{:unwind, u}, env, interp3}

      {:ref_call, v, new_vals, interp3} ->
        {env4, it4} = write_back_ref_args(args, new_vals, env, interp3, ref_positions)
        {{:val, v}, env4, it4}
    end
  end

  # evaluate call arguments SEQUENTIALLY threading the interpreter — a
  # later argument must observe earlier arguments' side effects
  # (var_dump(next($a), current($a)) sees the moved cursor)

  def bind_params(params, args, fenv, env, interp, msg_name, frame_disp, decl_site) do
    case eval_call_args(args, env, interp) do
      {:unwind, u, en2, it2} ->
        {{:unwind, u}, en2, it2}

      {:ok, triples, env2, interp2} ->
        case reorder_named(params, triples) do
          {:error, {:unknown, name}} ->
            named_arg_throw("Unknown named parameter $#{name}", env2, interp2)

          {:error, {:overwrite, name}} ->
            named_arg_throw(
              "Named parameter $#{name} overwrites previous argument",
              env2,
              interp2
            )

          {:ok, slots, extra_named, pos_left} ->
            {ordered, srcs, display} = align_slots(params, slots, extra_named, pos_left)

            case do_bind_params(params, ordered, fenv, env2, interp2, []) do
              {:ok, binds, interp3} ->
                {:ok, binds, display, srcs, interp3}

              {:missing, interp3, miss_idx} ->
                arg_count_error(
                  msg_name,
                  frame_disp,
                  params,
                  triples,
                  slots,
                  miss_idx,
                  extra_named,
                  env2,
                  interp3,
                  decl_site
                )
            end
        end
    end
  end

  # php named-argument binding, single pass in CALL order so overwrite
  # detection matches php (a named arg landing on a slot already filled —
  # positionally or by an earlier name — throws). Positional args fill the
  # first still-empty slots in declaration order; leftover positionals and
  # unknown-but-variadic named args collect into the variadic (positional
  # extras keep 0.. int keys, named extras keep string keys, positionals
  # first). Returns slots aligned to the non-variadic params ({v, src} | nil).

  def do_bind_params(params, ordered, fenv, env, interp, acc)

  def do_bind_params([], [], _fenv, _env, interp, acc), do: {:ok, Enum.reverse(acc), interp}

  def do_bind_params(
        [{:param, name, _t, _default, _by_ref?, true} | rest],
        [{:bound, v} | more],
        fenv,
        env,
        interp,
        acc
      ) do
    do_bind_params(rest, more, fenv, env, interp, [{name, v} | acc])
  end

  def do_bind_params(
        [{_, name, _, default, by_ref?, false} | rest],
        [bv | more],
        fenv,
        env,
        interp,
        acc
      ) do
    case bv do
      {:bound, v} ->
        {v2, interp2} =
          if by_ref? do
            case v do
              {:ref, _} -> {v, interp}
              plain -> make_ref_cell(plain, interp)
            end
          else
            # ref cells arriving through arrays (do_action_ref_array)
            # deref for by-value params — php copies the current value
            {deref(v, interp), interp}
          end

        do_bind_params(rest, more, fenv, env, interp2, [{name, v2} | acc])

      :absent ->
        # acc holds one entry per already-processed param, so its length IS
        # this param's index in the declaration
        case default do
          nil ->
            # ArgumentCountError is a catchable PHP Error; the caller-side
            # arg_count_error renders the php-exact message
            {:missing, interp, length(acc)}

          dexpr ->
            {{:val, dv}, _e2, it2} = eval(dexpr, fenv, interp)
            do_bind_params(rest, more, fenv, env, it2, [{name, dv} | acc])
        end
    end
  end

  def reorder_named(params, triples) do
    fixed = Enum.reject(params, &match?({:param, _, _, _, _, true}, &1))
    has_variadic = length(fixed) != length(params)
    names = Enum.map(fixed, fn {:param, n, _, _, _, _} -> n end)

    if Enum.all?(triples, &match?({:val, _, nil, _}, &1)) do
      # fast path — purely positional (func/010 passes 16k args; the general
      # path's per-arg slot scan is quadratic)
      {taken, over} = Enum.split(triples, length(names))

      slots =
        Enum.map(taken, &{elem(&1, 1), elem(&1, 3)}) ++
          List.duplicate(nil, length(names) - length(taken))

      {:ok, slots, [], Enum.map(over, &{elem(&1, 1), elem(&1, 3)})}
    else
      reorder_named_general(names, has_variadic, triples)
    end
  end

  def reorder_named_general(names, has_variadic, triples) do
    init = {List.duplicate(nil, length(names)), [], [], nil}

    {slots, extra_named, pos_rev, err} =
      Enum.reduce(triples, init, fn {:val, v, name, src}, {sl, extra, pos, e} ->
        case name do
          nil ->
            case Enum.find_index(sl, &is_nil(&1)) do
              # no empty slot left: with a variadic it collects there; php
              # silently ignores extra positionals otherwise (func_get_args
              # still shows them — known approximation)
              nil -> {sl, extra, [{v, src} | pos], e}
              i -> {List.replace_at(sl, i, {v, src}), extra, pos, e}
            end

          nm ->
            idx = Enum.find_index(names, &(&1 == nm))

            cond do
              idx != nil and Enum.at(sl, idx) != nil ->
                {sl, extra, pos, {:overwrite, nm}}

              idx != nil ->
                {List.replace_at(sl, idx, {v, src}), extra, pos, e}

              has_variadic ->
                {sl, extra ++ [{nm, v, src}], pos, e}

              true ->
                {sl, extra, pos, {:unknown, nm}}
            end
        end
      end)

    case err do
      {kind, nm} -> {:error, {kind, nm}}
      nil -> {:ok, slots, extra_named, Enum.reverse(pos_rev)}
    end
  end

  # build do_bind_params input ({:bound, v} | :absent per param, variadic
  # pre-bound to its extras array), the writeback src list, and the display
  # vals (bound values in param order — what Env.args/frames show)

  def align_slots(params, slots, extra_named, pos_left) do
    variadic_arr =
      {:array,
       PArray.from_pairs(
         Enum.map(Enum.with_index(pos_left), fn {{v, _}, i} -> {i, v} end) ++
           Enum.map(extra_named, fn {nm, v, _} -> {nm, v} end)
       )}

    {ordered, srcs, display, _} =
      Enum.reduce(params, {[], [], [], slots}, fn
        # func_get_args/frames FLATTEN the variadic's positional elements
        # (probe(7, 9, 11, 13) snapshots [7, 9, 11, 13]) but EXCLUDE named
        # extras collected by the variadic — v(1, 2, x: 9) snapshots [1, 2]
        {:param, _, _, _, _, true}, {o, s, d, sl} ->
          flat = Enum.map(pos_left, &elem(&1, 0))
          {[{:bound, variadic_arr} | o], [nil | s], flat ++ d, sl}

        {:param, _, _, _, _, _}, {o, s, d, [h | t]} ->
          case h do
            nil -> {[:absent | o], [nil | s], d, t}
            {v, src} -> {[{:bound, v} | o], [src | s], [v | d], t}
          end
      end)

    # no variadic to collect the extra positionals: func_get_args still
    # reports them (php never errors on extra positional args)
    extra_tail =
      if Enum.any?(params, &match?({:param, _, _, _, _, true}, &1)),
        do: [],
        else: Enum.map(pos_left, &elem(&1, 0))

    {Enum.reverse(ordered), Enum.reverse(srcs), Enum.reverse(display) ++ extra_tail}
  end

  # Unknown-named-parameter / overwrite Errors: catchable, thrown at the call
  # site, and — unlike ArgumentCountError — WITHOUT a call frame (php's trace
  # starts at {main})

  def named_arg_throw(msg, env, interp) do
    {obj_ref, it2} = materialize_native({:native_error, "Error", msg}, interp)
    {{:unwind, {:php_throw, obj_ref}}, env, it2}
  end

  # evaluates call arguments in order, threading the interpreter; spread
  # arrays splice — int keys become positional arguments, string keys become
  # NAMED arguments (php 8.1+). Result triples carry the source AST for
  # by-ref writeback.

  def eval_call_args(args, env, interp) do
    args
    |> Enum.reduce_while({:ok, [], env, interp}, fn
      {:arg_spread, e, _}, {:ok, acc, en, it} ->
        case eval(e, en, it) do
          {{:val, {:array, arr}}, en2, it2} ->
            triples =
              Enum.map(PArray.to_pairs(arr), fn
                {k, v} when is_binary(k) -> {:val, v, k, {:arg_spread, e, nil}}
                {_, v} -> {:val, v, nil, {:arg_spread, e, nil}}
              end)

            {:cont, {:ok, acc ++ triples, en2, it2}}

          {{:val, _}, en2, it2} ->
            {:cont, {:ok, acc, en2, warn(en2, it2, "only arrays can be spread")}}

          {{:unwind, u}, en2, it2} ->
            {:halt, {:unwind, u, en2, it2}}
        end

      {:arg, e, _, name}, {:ok, acc, en, it} ->
        case eval(e, en, it) do
          {{:val, v}, en2, it2} ->
            {:cont, {:ok, acc ++ [{:val, v, name, {:arg, e, false, name}}], en2, it2}}

          {{:unwind, u}, en2, it2} ->
            {:halt, {:unwind, u, en2, it2}}
        end
    end)
  end

  # php has TWO missing-argument messages. Pure positional shortfall:
  # "Too few arguments to function %s(), %d passed in %s on line %d and
  # %s %d expected" (name scope-qualified, counts exclude variadics,
  # "exactly" iff every declared param is required; the "passed" count only
  # counts args bound to DECLARED params — named args landing in a variadic
  # don't count). A named-arg call that skips a param reports instead
  # "%s(): Argument #%d ($%s) not passed" — chosen whenever any param AFTER
  # the first missing one was filled.

  def resolve_named_results(arg_results) do
    Enum.reduce_while(arg_results, {:ok, [], nil}, fn
      {{:val, v, name, _src}, _, it}, {:ok, acc, _} ->
        {:cont, {:ok, acc ++ [{:val, v, name, nil}], it}}

      {{:unwind, u}, _, it}, _ ->
        {:halt, {:unwind, u, it}}
    end)
  end

  # builtin named-argument binding against the registry's `params:` name
  # metadata (php arginfo names). Positional args fill in order, named by
  # name (case sensitive), leftovers append positionally — builtin variadics
  # like sprintf's $values receive them individually. Without metadata we
  # fall back to positional binding (names stripped) rather than guessing.

  def reorder_builtin_args(entry, triples) do
    named_any = Enum.any?(triples, &match?({:val, _, n, _} when n != nil, &1))
    meta = Map.get(entry, :params)

    cond do
      not named_any ->
        {:ok, Enum.map(triples, fn {:val, v, _, _} -> v end)}

      meta == nil ->
        {:ok, Enum.map(triples, fn {:val, v, _, _} -> v end)}

      true ->
        case reorder_named(Enum.map(meta, &{:param, &1, nil, nil, false, false}), triples) do
          {:error, {:unknown, name}} ->
            {:error, "Unknown named parameter $#{name}"}

          {:error, {:overwrite, name}} ->
            {:error, "Named parameter $#{name} overwrites previous argument"}

          {:ok, slots, extra_named, pos_left} ->
            vals =
              Enum.map(slots, fn
                nil -> :null
                {v, _} -> v
              end) ++
                Enum.map(pos_left, &elem(&1, 0)) ++ Enum.map(extra_named, &elem(&1, 1))

            {:ok, vals}
        end
    end
  end

  def arg_count_error(
        msg_name,
        frame_disp,
        params,
        _triples,
        slots,
        miss_idx,
        extra_named,
        env,
        interp,
        {df, dl}
      ) do
    named = Enum.reject(params, &match?({:param, _, _, _, _, true}, &1))
    num = length(named)
    req = Enum.count(named, &match?({:param, _, _, nil, _, _}, &1))
    bound_count = Enum.count(slots, &(&1 != nil))

    later_bound = Enum.any?(Enum.drop(slots, miss_idx), &(&1 != nil))

    # frame/Env.args display: slots up to the highest bound one, :null for
    # the gaps (php renders skipped RECVs as NULL: f(1, NULL, 9)); named
    # args collected by a variadic render as `name: value` after them
    display_vals =
      case Enum.reverse(slots) |> Enum.find_index(&(&1 != nil)) do
        nil ->
          []

        ridx ->
          slots
          |> Enum.take(length(slots) - ridx)
          |> Enum.map(fn
            nil -> :null
            {v, _} -> v
          end)
      end

    miss_param = Enum.at(params, miss_idx)
    {:param, miss_name, _, _, _, _} = miss_param

    msg =
      if later_bound do
        "#{msg_name}(): Argument ##{miss_idx + 1} ($#{miss_name}) not passed"
      else
        how = if req == num, do: "exactly", else: "at least"

        "Too few arguments to function #{msg_name}(), #{bound_count} passed" <>
          " in #{eval_file(interp)} on line #{interp.cur_line} and #{how} #{req} expected"
      end

    rendered =
      Interp.render_frame_args(display_vals, interp) <>
        case extra_named do
          [] ->
            ""

          _ ->
            joined =
              Enum.map_join(extra_named, ", ", fn {n, v, _src} ->
                "#{n}: #{Interp.render_arg(v, interp)}"
              end)

            if display_vals == [], do: joined, else: ", " <> joined
        end

    it2 = Interp.push_frame(interp, "#{frame_disp}(#{rendered})")
    {obj_ref, it3} = materialize_native({:native_error, "ArgumentCountError", msg}, it2)
    # the exception's file/line is the declaration, not the propagation point
    {{:unwind, {:php_throw, obj_ref}}, env, %{it3 | throw_pos: {df, dl}}}
  end

  # ordered: per-param {:bound, v} | :absent (variadic always {:bound, arr},
  # precomputed by align_slots). miss_idx counts the FULL param list (variadic
  # never missing) and feeds the "Argument #N ($name) not passed" variant.

  def resolve_args(arg_results) do
    Enum.reduce_while(arg_results, {:ok, [], nil}, fn
      {{:val, v}, _, it}, {:ok, acc, _} ->
        {:cont, {:ok, acc ++ [v], it}}

      {{:unwind, u}, _, it}, _ ->
        {:halt, {:unwind, u, it}}
    end)
  end

  def eval_args(args, env, interp, _spread?) do
    {rev, _env2, _interp2} =
      Enum.reduce_while(args, {[], env, interp}, fn a, {acc, en, it} ->
        e =
          case a do
            {:arg, x, _, _} -> x
            {:arg_spread, x, _} -> x
          end

        case eval(e, en, it) do
          {{:val, v}, en2, it2} ->
            {:cont, {[{{:val, v}, en2, it2} | acc], en2, it2}}

          # stop on the first unwind — later args must not evaluate with nil env
          {{:unwind, _} = unw, en2, it2} ->
            {:halt, {[{unw, en2, it2} | acc], en2, it2}}
        end
      end)

    Enum.reverse(rev)
  end

  def resolve_function(name, fq, interp) do
    cond do
      fq == true ->
        Map.get(interp.functions, name, :error)

      # `use function A\B\f;` imports win over ns/global fallback (php)
      imported = Map.get(interp.uses.function, name) ->
        Map.get(interp.functions, String.downcase(imported), :error)

      interp.ns == [] ->
        Map.get(interp.functions, name, :error)

      true ->
        ns_name = (interp.ns ++ [name]) |> Enum.join("\\") |> String.downcase()

        Map.get(interp.functions, ns_name, Map.get(interp.functions, name, :error))
    end
  end

  def materialize_native({:native_error, class, msg}, interp) do
    key = String.downcase(class)
    {obj_ref, interp2} = make_instance(interp, key)
    obj = get_object(interp2, obj_ref)

    props =
      case PArray.put(obj.props, {:string, "message"}, {:string, msg}) do
        {:ok, p2} -> p2
        _ -> obj.props
      end

    interp3 = put_object(interp2, obj_ref, %{obj | props: props})
    {obj_ref, interp3}
  end

  def materialize_native(other, interp), do: {other, interp}

  def wrap_args(vals), do: Enum.map(vals, &{:arg, {:lit_val, &1}, false, nil})

  # evaluates raw args for native-method invocation; unwinds PROPAGATE
  # (an undefined function inside the arg list is a fatal, not an empty list)
  defp native_call(obj, obj_ref, native, vals, env, interp) do
    case native.(obj, vals, interp) do
      {:ok, {ret, obj2}, interp2} ->
        interp3 = put_object(interp2, obj_ref, obj2)
        {{:val, ret}, env, interp3}

      {{:unwind, _} = u, _, interp2} ->
        {u, env, interp2}

      other ->
        other
    end
  end

  def arg_values(args, env, interp) do
    case resolve_args(eval_args(args, env, interp, false)) do
      {:ok, vals, it} -> {:ok, vals, it || interp}
      {:unwind, u, it} -> {:unwind, u, it || interp}
    end
  end

  # dispatch a PHP method (user or native) with $this bound
  def call_php_method_inner({:object, _} = obj_ref, method, args, env, interp) do
    obj = get_object(interp, obj_ref)

    case method_violation(interp, obj.class, method, env) do
      nil -> :ok
      msg -> throw({:fatal_violation, msg, env, interp})
    end

    if method.native do
      {:native, native} = method.native

      case arg_values(args, env, interp) do
        {:unwind, _} = u ->
          u

        {:ok, vals, interp} ->
          native_call(obj, obj_ref, native, vals, env, interp)
      end
    else
      mkey = obj.class <> "::" <> String.downcase(method.name)

      fenv = %Env{
        function: method.name,
        statics_key: mkey,
        this: obj_ref,
        called_class: obj.class,
        scope_class: method.class || obj.class
      }

      ckey = method.class || obj.class
      {defc, cfile} = decl_site_of(interp, ckey)

      case bind_params(
             method.params,
             args,
             fenv,
             env,
             interp,
             "#{defc}::#{method.name}",
             "#{defc}->#{method.name}",
             {cfile, method.line || interp.cur_line}
           ) do
        {:ok, binds, vals, srcs, interp2} ->
          fenv2 =
            binds
            |> Enum.reduce(%{fenv | args: vals}, fn {n, v}, acc ->
              %{acc | vars: Map.put(acc.vars, n, v)}
            end)

          {ns0, uses0, interp2} = push_class_scope(interp2, ckey)

          result =
            if method.gen? do
              # php binds __DIR__/__FILE__ to the DEFINING file at compile time
              interp2 = %{interp2 | file_stack: [cfile | interp2.file_stack]}
              {res, env2, interp2b} = start_generator(fenv2, method.body, env, interp2)
              {res, env2, pop_file(interp2b)}
            else
              interp2 = Interp.push_frame(interp2, "#{defc}->#{method.name}", vals)
              # method bodies evaluate __DIR__ etc. against their defining file
              interp2 = %{interp2 | file_stack: [cfile | interp2.file_stack]}

              {res, _, interp3} = Interp.exec_stmts(method.body, fenv2, interp2)

              {interp4, env_out} = write_back_refs(method.params, srcs, env, fenv2, interp3)

              interp5 = Interp.pop_frame(pop_file_once(interp4))

              case res do
                :ok -> {{:val, :null}, env_out, interp5}
                {:unwind, {:return, v}} -> {{:val, v}, env_out, interp5}
                # a throw escaping keeps its frame alive for the uncaught trace
                {:unwind, _} = u -> {{:unwind, elem(u, 1)}, env_out, interp4}
              end
            end

          case result do
            {{:val, v}, e, i} -> {{:val, v}, e, pop_class_scope(i, ns0, uses0)}
            {{:unwind, u}, e, i} -> {{:unwind, u}, e, pop_class_scope(i, ns0, uses0)}
          end

        {{:unwind, _} = u, _, it2} ->
          {u, env, it2}
      end
    end
  end

  def invoke_fcc(cb, args, env, interp) do
    case arg_values(args, env, interp) do
      {:ok, vals, interp2} -> call_cb(cb, vals, env, interp2)
      {:unwind, _} = u -> u
    end
  end

  def write_back_refs(params, args, env, fenv, interp) do
    params
    |> Enum.with_index()
    |> Enum.filter(fn {{:param, _, _, _, by_ref?, _}, _} -> by_ref? end)
    |> Enum.reduce({interp, env}, fn {{:param, pname, _, _, _, _}, idx}, {it, e} ->
      case Enum.at(args, idx) do
        {:arg, {:var, vname}, _, _} ->
          case Env.lookup(fenv, it, pname) do
            {:ok, {:ref, _rid}} ->
              {:ok, v} = Env.lookup(fenv, it, pname)
              {:ok, e2, it2} = Env.bind_var(e, it, vname, deref(v, it))
              {it2, e2}

            _ ->
              {it, e}
          end

        _ ->
          {it, e}
      end
    end)
  end

  # returns {:ok, binds, vals, srcs, interp} or {{:unwind, u}, env, interp} — the
  # unwind covers argument-expression throws, Unknown-named-parameter/overwrite
  # Errors, and ArgumentCountError (missing required params). msg_name/frame_disp
  # feed the php-exact error message and stack frame; decl_site ({file, line})
  # becomes the throw position: php raises the error at the function's RECV
  # opcodes, so file/line = declaration site. srcs aligns each param with the
  # original arg AST node for by-ref writeback.

  def write_back_ref_args(_args, _new_vals, env, interp, []) do
    {env, interp}
  end

  def write_back_ref_args(args, new_vals, env, interp, positions) do
    Enum.reduce(positions, {env, interp}, fn pos, {en, it} ->
      case Enum.at(args, pos) do
        {:arg, lval, _, _} ->
          case Enum.at(new_vals, pos) do
            nil ->
              {en, it}

            new_v ->
              {e2, it2} = assign(lval, new_v, en, it)
              {e2, it2}
          end

        _ ->
          {en, it}
      end
    end)
  end

  # ───────────────────────── binary ops ─────────────────────────

  # ── forwarders to Eval's public helpers (bare calls inside moved bodies) ──
  defp eval(a, b, c), do: Eval.eval(a, b, c)
  defp deref(v, i), do: Eval.deref(v, i)
  defp eval_file(i), do: Eval.eval_file(i)
  defp pop_file(i), do: Eval.pop_file(i)
  defp pop_file_once(i), do: Eval.pop_file_once(i)
  defp get_object(i, r), do: Eval.get_object(i, r)
  defp put_object(i, r, m), do: Eval.put_object(i, r, m)
  defp make_instance(i, k), do: Eval.make_instance(i, k)
  defp make_ref_cell(v, i), do: Eval.make_ref_cell(v, i)
  defp start_generator(a, b, c, d), do: Eval.start_generator(a, b, c, d)
  defp warn(a, b, c), do: Eval.warn(a, b, c)
  defp assign(t, v, e, i), do: Eval.assign(t, v, e, i)
  defp decl_site_of(a, b), do: Eval.decl_site_of(a, b)
  defp method_violation(a, b, c, d), do: Eval.method_violation(a, b, c, d)
  defp pop_class_scope(a, b, c), do: Eval.pop_class_scope(a, b, c)
  defp push_class_scope(a, b), do: Eval.push_class_scope(a, b)

  # ── engine introspection ho functions (live HERE, not the registry) ──
  # eval() is lexer+parser+exec; func_get_args family reads the call frame's
  # argument snapshot. Both need engine internals no builtin domain should own.

  defp engine_ho(name, args, env, interp) do
    if name in ~w(eval func_get_args func_get_arg func_num_args) do
      case resolve_args(eval_args(args, env, interp, false)) do
        {:ok, vals, it} -> engine_fn(name, vals, env, it || interp)
        {:unwind, u, it} -> {{:unwind, u}, env, it || interp}
      end
    else
      :not_mine
    end
  end

  defp engine_fn("eval", vals, env, interp) do
    case vals do
      [{:string, code} | _] -> eval_code(code, env, interp)
      _ -> {{:val, :null}, env, interp}
    end
  end

  defp eval_code(code, env, interp) do
    pseudo = Eval.eval_file(interp) <> "(#{interp.cur_line}) : eval()'d code"

    with {:ok, toks} <- PhpBeam.Lexer.tokenize("<?php " <> code),
         {:ok, stmts} <- PhpBeam.Parser.parse(toks) do
      i2 = %{interp | file_stack: [pseudo | interp.file_stack]}

      case Interp.exec_stmts(stmts, env, i2) do
        {:ok, e2, i3} ->
          {{:val, :null}, e2, Eval.pop_file(i3)}

        {{:unwind, {:return, v}}, _, i3} ->
          {{:val, v}, env, Eval.pop_file(i3)}

        {{:unwind, _} = u, e2, i3} ->
          {u, e2, i3}
      end
    else
      {:error, msg, line} ->
        {{:unwind, {:parse_error, msg, pseudo, line}}, env, interp}
    end
  end

  defp engine_fn("func_num_args", _vals, env, interp) do
    case fn_context("func_num_args", env, interp) do
      nil -> {{:val, {:int, length(env.args)}}, env, interp}
      err -> err
    end
  end

  defp engine_fn("func_get_args", _vals, env, interp) do
    case fn_context("func_get_args", env, interp) do
      nil ->
        arr = PArray.from_pairs(Enum.map(env.args, &{nil, &1}))
        {{:val, {:array, arr}}, env, interp}

      err ->
        err
    end
  end

  defp engine_fn("func_get_arg", [{:int, n} | _], env, interp) do
    case fn_context("func_get_arg", env, interp) do
      nil ->
        cond do
          n < 0 ->
            native_throw(
              "ValueError",
              "func_get_arg(): Argument #1 ($position) must be greater than or equal to 0",
              env,
              interp,
              "func_get_arg(#{n})"
            )

          n >= length(env.args) ->
            native_throw(
              "ValueError",
              "func_get_arg(): Argument #1 ($position) must be less than the number of the arguments passed to the currently executed function",
              env,
              interp,
              "func_get_arg(#{n})"
            )

          true ->
            {{:val, Enum.at(env.args, n)}, env, interp}
        end

      err ->
        err
    end
  end

  defp engine_fn("func_get_arg", _, env, interp), do: {{:val, {:bool, false}}, env, interp}

  defp fn_context(name, env, interp) do
    if env.function == nil do
      native_throw(
        "Error",
        "#{name}() must be called from a function context",
        env,
        interp,
        "#{name}()"
      )
    else
      nil
    end
  end

  defp native_throw(class, msg, env, interp, frame_display) do
    interp2 = Interp.push_frame(interp, frame_display)
    # materialize eagerly: catch bindings and get_class() expect a real object
    {obj_ref, interp3} = materialize_native({:native_error, class, msg}, interp2)
    {{:unwind, {:php_throw, obj_ref}}, env, interp3}
  end

  # frame display names carry rendered args — the bare name is before "("
  defp call_cb_caller(%{call_stack: [%{func: f} | _]}) when is_binary(f),
    do: f |> String.split("(", parts: 2) |> hd() |> String.trim_trailing("(")

  defp call_cb_caller(_), do: nil

  defp cb_scope_ok?(nil, _meth, _cls, _interp), do: false

  defp cb_scope_ok?(scope, meth, cls, interp) do
    case meth.visibility do
      :public -> true
      :private -> scope == meth.class
      :protected -> PhpBeam.Classes.is_a?(interp, scope, meth.class || cls)
    end
  end

  defp obj_display(interp, key) do
    case PhpBeam.Classes.get_class(interp, key) do
      %{name: n} -> n
      _ -> key
    end
  end
end
