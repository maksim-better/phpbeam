defmodule PhpBeam.Eval do
  @moduledoc """
  Expression evaluation, lvalues, and call dispatch.

  `eval/3` returns `{{:val, v} | {:unwind, signal}, env, interp}`.
  """

  alias PhpBeam.{Env, Error, Interp, PArray, Value}

  @int_min -9_223_372_036_854_775_808
  @int_max 9_223_372_036_854_775_807

  # ───────────────────────── expressions ─────────────────────────

  def eval(ast, env, interp)

  def eval({:int, n}, env, interp), do: {{:val, {:int, n}}, env, interp}
  def eval({:float, f}, env, interp), do: {{:val, {:float, f}}, env, interp}
  def eval({:string, s}, env, interp), do: {{:val, {:string, s}}, env, interp}
  def eval({:bool, b}, env, interp), do: {{:val, {:bool, b}}, env, interp}
  def eval(:null, env, interp), do: {{:val, :null}, env, interp}

  def eval({:lit_val, v}, env, interp), do: {{:val, v}, env, interp}

  def eval({:var, name}, env, interp) do
    if name == "GLOBALS" and env.function != nil do
      {{:val, globals_array(interp)}, env, interp}
    else
      case Env.lookup(env, interp, name) do
        {:ok, v} ->
          {{:val, deref(v, interp)}, env, interp}

        {:static, key, sname} ->
          {{:val, deref(Map.get(interp.statics[key], sname), interp)}, env, interp}

        :undefined ->
          interp2 = warn(env, interp, "Undefined variable $#{name}")
          {{:val, :null}, env, interp2}
      end
    end
  end

  def eval({:var_var, e}, env, interp) do
    case eval(e, env, interp) do
      {{:val, {:string, name}}, env2, interp2} ->
        eval({:var, name}, env2, interp2)

      {{:val, _}, env2, interp2} ->
        interp3 = warn(env2, interp2, "Undefined variable $#{name_of(e)}")
        {{:val, :null}, env2, interp3}

      unw ->
        unw
    end
  end

  def eval({:const, parts, fq}, env, interp) do
    name = Enum.join(parts, "\\")

    case resolve_const(name, fq, interp) do
      {:ok, v} -> {{:val, v}, env, interp}
      :error -> {{:unwind, {:fatal, "Undefined constant \"#{name}\""}}, env, interp}
    end
  end

  def eval({:interp, parts}, env, interp) do
    {out, env2, interp2} = interp_parts(parts, env, interp)
    {{:val, {:string, out}}, env2, interp2}
  end

  def eval({:array, entries}, env, interp) do
    {pairs, env2, interp2} =
      Enum.reduce(entries, {[], env, interp}, fn
        nil, acc ->
          acc

        {:kv, k, v, by_ref?}, {ps, e, i} ->
          {k_pair, e1, i1} =
            case k do
              nil ->
                {nil, e, i}

              kexpr ->
                {{:val, kv}, e2, i2} = eval(kexpr, e, i)
                {kv, e2, i2}
            end

          {{:val, vv}, e3, i3} = eval(v, e1, i1)

          vv2 =
            if by_ref? do
              case vv do
                {:ref, _} -> vv
                plain -> make_ref_cell(plain, i3) |> elem(0)
              end
            else
              vv
            end

          {[{k_pair, vv2} | ps], e3, i3}
      end)

    {{:val, {:array, PArray.from_pairs(Enum.reverse(pairs))}}, env2, interp2}
  end

  def eval({:index, container, idx}, env, interp) do
    {{:val, c}, env2, interp2} = eval(container, env, interp)

    case idx do
      nil ->
        interp3 = warn(env2, interp2, "Cannot use [] for reading")
        {{:val, :null}, env2, interp3}

      idx_expr ->
        {{:val, i}, env3, interp3} = eval(idx_expr, env2, interp2)
        index_read(c, i, env3, interp3)
    end
  end

  def eval({:prop, obj_e, name_e}, env, interp) do
    {{:val, obj}, env2, interp2} = eval(obj_e, env, interp)

    case obj do
      {:object, %{props: props}} ->
        key = PhpBeam.Eval.prop_name_string(name_e, env2, interp2)
        val = PArray.get(props, {:string, key}, :null)

        if val == :null do
          interp3 = warn(env2, interp2, "Undefined property: stdClass::$#{key}")
          {{:val, :null}, env2, interp3}
        else
          {{:val, deref(val, interp2)}, env2, interp2}
        end

      :null ->
        {{:val, :null}, env2, warn(env2, interp2, "Attempt to read property \"value\" on null")}

      _ ->
        interp3 =
          warn(
            env2,
            interp2,
            "Attempt to read property on value of type #{PhpBeam.Value.gettype(obj)}"
          )

        {{:val, :null}, env2, interp3}
    end
  end

  def prop_name_string({:lit_name, n}, _env, _interp), do: n

  def prop_name_string({:var, v}, env, interp) do
    case eval({:var, v}, env, interp) do
      {{:val, {:string, s}}, _, _} -> s
      _ -> ""
    end
  end

  def prop_name_string(_, _env, _interp), do: ""

  def stdclass(%PArray{} = props) do
    %{__ref__: :erlang.unique_integer([:positive]), class: "stdClass", props: props}
  end

  def eval({:nullsafe_prop, _, _}, env, interp),
    do: {{:unwind, {:fatal, "property access requires class support (M5)"}}, env, interp}

  def eval({:static_prop, _, _}, env, interp),
    do: {{:unwind, {:fatal, "static properties require class support (M5)"}}, env, interp}

  def eval({:class_const, _, _}, env, interp) do
    # `::class` on simple names resolves textually even before M5
    {{:val, {:string, "class"}}, env, interp}
  end

  def eval({:assign, target, rhs}, env, interp) do
    case eval(rhs, env, interp) do
      {{:val, v}, env2, interp2} ->
        {env3, interp3} = assign(target, v, env2, interp2)
        {{:val, v}, env3, interp3}

      unw ->
        unw
    end
  end

  def eval({:assign_ref, target, rhs}, env, interp) do
    case rhs do
      {:var, _} = rv ->
        {{:val, v}, env2, interp2} = eval(rv, env, interp)

        # reuse the existing ref cell if the RHS is already a reference
        {id, interp3} =
          case Env.lookup(env2, interp2, var_name(rv)) do
            {:ok, {:ref, rid}} -> {rid, interp2}
            _ -> new_ref(v, interp2)
          end

        {env3, interp4} = assign(target, {:ref, id}, env2, interp3)

        case target do
          {:var, _} -> :ok
          _ -> :ok
        end
        |> tap(fn _ -> bind_var_to_ref(env3, interp4, target, id) end)

        {{:val, deref({:ref, id}, interp4)}, env3, interp4}

      {:new, _, _} ->
        {{:unwind, {:fatal, "cannot take reference of new expression"}}, env, interp}

      _ ->
        {{:unwind, {:fatal, "cannot take reference of this expression"}}, env, interp}
    end
  end

  def eval({:assign_op, op, target, rhs}, env, interp) do
    {cur, get_env, interp2} = read_target(target, env, interp)

    {{:val, r}, env2, interp3} = eval(rhs, get_env, interp2)

    result =
      case op do
        :coalesce ->
          if Value.type(cur) == :null, do: r, else: cur

        _ ->
          apply_binop(op, cur, r, env2, interp3)
      end

    case result do
      {:unwind, _} = u ->
        {{:unwrap, _}, _, _} = {u, env2, interp3}
        {{:unwind, elem(u, 1)}, env2, interp3}

      {:ok, v} ->
        {env3, interp4} = assign(target, v, env2, interp3)
        {{:val, v}, env3, interp4}
    end
  end

  def eval({:pre_inc, target}, env, interp) do
    {cur, env2, interp2} = read_target(target, env, interp)
    v = Value.increment(deref(cur, interp2))
    {env3, interp3} = assign(target, v, env2, interp2)
    {{:val, v}, env3, interp3}
  end

  def eval({:pre_dec, target}, env, interp) do
    {cur, env2, interp2} = read_target(target, env, interp)
    v = Value.decrement(deref(cur, interp2))
    {env3, interp3} = assign(target, v, env2, interp2)
    {{:val, v}, env3, interp3}
  end

  def eval({:post_inc, target}, env, interp) do
    {cur, env2, interp2} = read_target(target, env, interp)
    v = Value.increment(deref(cur, interp2))
    {env3, interp3} = assign(target, v, env2, interp2)
    {{:val, cur}, env3, interp3}
  end

  def eval({:post_dec, target}, env, interp) do
    {cur, env2, interp2} = read_target(target, env, interp)
    v = Value.decrement(deref(cur, interp2))
    {env3, interp3} = assign(target, v, env2, interp2)
    {{:val, cur}, env3, interp3}
  end

  def eval({:unop, :!, e}, env, interp) do
    {{:val, v}, env2, interp2} = eval(e, env, interp)
    {{:val, {:bool, not Value.truthy?(v)}}, env2, interp2}
  end

  def eval({:unop, :-, e}, env, interp) do
    with_val(e, env, interp, fn v ->
      case Value.negate(v) do
        {:ok, r} -> {{:val, r}, nil, nil}
        {:error, err} -> throw_error(err)
      end
    end)
  end

  def eval({:unop, :+, e}, env, interp) do
    with_val(e, env, interp, fn v ->
      case Value.type(v) do
        t when t in [:int, :float] -> {{:val, v}, nil, nil}
        _ -> {{:val, v}, nil, nil}
      end
    end)
  end

  def eval({:unop, :bnot, e}, env, interp) do
    with_val(e, env, interp, fn v ->
      case Value.bnot(v) do
        {:ok, r} -> {{:val, r}, nil, nil}
        {:error, err} -> throw_error(err)
      end
    end)
  end

  def eval({:unop, :@, e}, env, interp) do
    {{:val, v}, env2, interp2} = eval(e, env, %{interp | suppress: interp.suppress + 1})
    {{:val, v}, env2, %{interp2 | suppress: interp2.suppress - 1}}
  end

  def eval({:cast, kind, e}, env, interp) do
    {{:val, v}, env2, interp2} = eval(e, env, interp)

    out =
      case kind do
        :int -> Value.to_int(v) |> elem(1)
        :float -> Value.to_float(v) |> elem(1)
        :bool -> {:bool, Value.truthy?(v)}
        :string -> Value.cast_string(v) |> string_of_cast()
        :array -> Value.to_array(v)
        :object -> v
      end

    {{:val, out}, env2, interp2}
  end

  def eval({:binop, :&&, l, r}, env, interp) do
    {{:val, lv}, env2, interp2} = eval(l, env, interp)

    if Value.truthy?(lv) do
      {{:val, rv}, env3, interp3} = eval(r, env2, interp2)
      {{:val, {:bool, Value.truthy?(rv)}}, env3, interp3}
    else
      {{:val, {:bool, false}}, env2, interp2}
    end
  end

  def eval({:binop, :||, l, r}, env, interp) do
    {{:val, lv}, env2, interp2} = eval(l, env, interp)

    if Value.truthy?(lv) do
      {{:val, {:bool, true}}, env2, interp2}
    else
      {{:val, rv}, env3, interp3} = eval(r, env2, interp2)
      {{:val, {:bool, Value.truthy?(rv)}}, env3, interp3}
    end
  end

  def eval({:binop, op, l, r}, env, interp) when op in [:and, :or, :xor] do
    {{:val, lv}, env2, interp2} = eval(l, env, interp)
    {{:val, rv}, env3, interp3} = eval(r, env2, interp2)

    res =
      case op do
        :and -> Value.truthy?(lv) and Value.truthy?(rv)
        :or -> Value.truthy?(lv) or Value.truthy?(rv)
        :xor -> Value.truthy?(lv) != Value.truthy?(rv)
      end

    {{:val, {:bool, res}}, env3, interp3}
  end

  def eval({:binop, op, l, r}, env, interp) do
    {{:val, lv}, env2, interp2} = eval(l, env, interp)
    {{:val, rv}, env3, interp3} = eval(r, env2, interp2)
    # note: `and`/`or`/`xor` above don't short-circuit per PHP semantics
    # for `&&`/`||`; keyword forms are handled above with eager evaluation

    case apply_binop(op, lv, rv, env3, interp3) do
      {:ok, v} -> {{:val, v}, env3, interp3}
      {:unwind, _} = u -> {u, env3, interp3}
    end
  end

  def eval({:coalesce, l, r}, env, interp) do
    case isset?(l, env, interp) do
      {true, env2, interp2} ->
        {{:val, v}, env3, interp3} = eval(l, env2, interp2)
        {{:val, deref(v, interp3)}, env3, interp3}

      {false, env2, interp2} ->
        eval(r, env2, interp2)
    end
  end

  def eval({:ternary, c, t, f}, env, interp) do
    {{:val, cv}, env2, interp2} = eval(c, env, interp)

    if Value.truthy?(cv) do
      eval(t, env2, interp2)
    else
      eval(f, env2, interp2)
    end
  end

  def eval({:short_ternary, c, f}, env, interp) do
    {{:val, cv}, env2, interp2} = eval(c, env, interp)

    if Value.truthy?(cv) do
      {{:val, cv}, env2, interp2}
    else
      eval(f, env2, interp2)
    end
  end

  def eval({:match, subj, arms}, env, interp) do
    {{:val, s}, env2, interp2} = eval(subj, env, interp)
    match_arms(arms, s, env2, interp2)
  end

  def eval({:isset, targets}, env, interp) do
    res =
      Enum.all?(targets, fn t ->
        {ok?, _, _} = isset?(t, env, interp)
        ok?
      end)

    {{:val, {:bool, res}}, env, interp}
  end

  def eval({:empty, e}, env, interp) do
    {ok?, _, _} = isset?(e, env, interp)

    if ok? do
      {{:val, v}, _env2, _i2} = eval(e, env, interp)
      {{:val, {:bool, not Value.truthy?(v)}}, env, interp}
    else
      {{:val, {:bool, true}}, env, interp}
    end
  end

  def eval({:print, e}, env, interp) do
    {out, env2, interp2} = concat_to_string([e], env, interp)
    {{:val, {:int, 1}}, env2, Interp.write(interp2, out)}
  end

  def eval({:throw, e}, env, interp) do
    {{:val, v}, env2, interp2} = eval(e, env, interp)
    {{:unwind, {:php_throw, v}}, env2, interp2}
  end

  def eval({:exit_expr, e}, env, interp) do
    case e do
      nil ->
        {{:unwind, {:halt, 0}}, env, interp}

      _ ->
        {{:val, v}, env2, interp2} = eval(e, env, interp)

        case v do
          {:int, n} -> {{:unwind, {:halt, n}}, env2, interp2}
          {:string, s} -> {{:unwind, {:halt_write, s}}, env2, interp2}
          _ -> {{:unwind, {:halt, 0}}, env2, interp2}
        end
    end
  end

  def eval({:new, _, _}, env, interp),
    do: {{:unwind, {:fatal, "class instances require class support (M5)"}}, env, interp}

  def eval({:clone, _}, env, interp),
    do: {{:unwind, {:fatal, "clone requires class support (M5)"}}, env, interp}

  def eval({:closure, params, uses, _by_ref?, body, arrow?}, env, interp) do
    {captures, env2, interp2} =
      Enum.reduce(uses, {%{}, env, interp}, fn
        {:ref, name}, {caps, e, it} ->
          {id, it2} =
            case Env.lookup(e, it, name) do
              {:ok, {:ref, rid}} ->
                {rid, it}

              {:ok, v} ->
                new_ref(deref(v, it), it)

              _ ->
                new_ref(:null, it)
            end

          # the outer variable now shares the cell
          {:ok, e2, it3} = Env.bind_var(e, it2, name, {:ref, id})
          {Map.put(caps, name, {:ref, id}), e2, it3}

        name, {caps, e, it} ->
          v =
            case Env.lookup(e, it, name) do
              {:ok, v2} -> deref(v2, it)
              _ -> :null
            end

          {Map.put(caps, name, v), e, it}
      end)

    {{:val, {:closure, params, body, captures, arrow?}}, env2, interp2}
  end

  def eval({:method_call, _, _, _, _}, env, interp),
    do: {{:unwind, {:fatal, "method calls require class support (M5)"}}, env, interp}

  def eval({:static_call, _, _, _}, env, interp),
    do: {{:unwind, {:fatal, "static calls require class support (M5)"}}, env, interp}

  def eval({:call, callee, args}, env, interp), do: do_call(callee, args, env, interp)

  # ───────────────────────── calls ─────────────────────────

  defp do_call(callee, args, env, interp) do
    case callee do
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

      {:const, parts, fq} ->
        name = Enum.join(parts, "\\") |> String.downcase()

        case higher_order(name, args, env, interp) do
          :not_mine ->
            call_named(parts, name, fq, args, env, interp)

          result ->
            result
        end

      _ ->
        {{:unwind, {:fatal, "unsupported call target"}}, env, interp}
    end
  end

  defp call_named(parts, name, fq, args, env, interp) do
    case resolve_function(name, fq, interp) do
      {:user, _params, _body} = fn_def ->
        call_function(fn_def, name, args, env, interp, false)

      %{fun: _} = entry ->
        call_builtin(entry, name, args, env, interp)

      :error ->
        fname = Enum.join(parts, "\\")
        {{:unwind, {:fatal, "Call to undefined function " <> fname <> "()"}}, env, interp}
    end
  end

  # ─────────────────── higher-order builtins (need the evaluator) ───────────────────

  defp higher_order(name, args, env, interp) do
    if name in ~w(call_user_func call_user_func_array array_map array_filter array_reduce array_walk) do
      case resolve_args(eval_args(args, env, interp, false)) do
        {:ok, vals} -> dispatch_ho(name, vals, env, interp)
        {:unwind, u} -> {{:unwind, u}, env, interp}
      end
    else
      :not_mine
    end
  end

  defp dispatch_ho("call_user_func", [cb | rest], env, interp),
    do: call_cb(cb, rest, env, interp)

  defp dispatch_ho("call_user_func_array", [cb, {:array, arr}], env, interp),
    do: call_cb(cb, PArray.values(arr), env, interp)

  defp dispatch_ho("array_map", [cb | arrays], env, interp) do
    case arrays do
      [{:array, arr} | more] ->
        more_vals = Enum.map(more, fn {:array, a} -> PArray.values(a) end)
        map_cb(cb, arr, more_vals, env, interp)

      _ ->
        {{:val, {:array, PArray.new()}}, env, interp}
    end
  end

  defp dispatch_ho("array_map", _, env, interp),
    do: {{:val, {:array, PArray.new()}}, env, interp}

  defp dispatch_ho("array_filter", [{:array, arr} | rest], env, interp),
    do: filter_cb(arr, rest, env, interp)

  defp dispatch_ho("array_reduce", [{:array, arr}, cb | rest], env, interp) do
    initial =
      case rest do
        [v | _] -> v
        [] -> :null
      end

    reduce_cb(arr, cb, initial, env, interp)
  end

  defp dispatch_ho("array_walk", _, env, interp),
    do: {{:val, {:bool, false}}, env, interp}

  defp dispatch_ho(_, _, env, interp), do: :not_mine

  defp expand_spreads(args, env, interp) do
    Enum.flat_map(args, fn
      {:arg_spread, e, _} ->
        case eval(e, env, interp) do
          {{:val, {:array, arr}}, _, _} -> PArray.values(arr)
          _ -> []
        end

      {:arg, e, _, _} ->
        case eval(e, env, interp) do
          {{:val, v}, _, _} -> [v]
          _ -> []
        end
    end)
  end

  # call a PHP callable value
  def call_cb(cb, call_args, env, interp)

  def call_cb({:closure, _, _, _, _} = closure_value, call_args, env, interp),
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

  def call_cb({:array, _} = _method_pair, _call_args, env, interp) do
    {{:unwind, {:fatal, "callable arrays require class support (M5)"}}, env, interp}
  end

  def call_cb(_, _call_args, env, interp) do
    {{:unwind, {:fatal, "Value not callable"}}, env, interp}
  end

  defp wrap_args(vals), do: Enum.map(vals, &{:arg, {:lit_val, &1}, false, nil})

  defp map_cb(cb, %PhpBeam.PArray{} = arr, more_arrs, env, interp) do
    rows = pad_zip([PArray.values(arr) | more_arrs])

    {vals, {e2, i2}} =
      Enum.reduce(rows, {[], {env, interp}}, fn row, {acc, ctx} ->
        case call_cb(cb, row, elem(ctx, 0), elem(ctx, 1)) do
          {{:val, v}, e3, i3} -> {acc ++ [v], {e3, i3}}
          _ -> {acc, ctx}
        end
      end)

    {{:val, {:array, PArray.from_pairs(Enum.map(vals, &{nil, &1}))}}, e2, i2}
  end

  defp pad_zip([first | rest]) do
    n = length(first)

    Enum.map(Enum.with_index(first), fn {v, idx} ->
      [v | Enum.map(rest, fn arr -> Enum.at(arr, idx) || :null end)]
    end)
    |> Kernel.++(if n > 0, do: [], else: [])
  end

  defp pad_zip([]), do: []

  defp filter_cb(arr, rest, env, interp) do
    cb =
      case rest do
        [c | _] -> c
        [] -> nil
      end

    kept =
      PArray.to_pairs(arr)
      |> Enum.filter(fn {_k, v} ->
        case cb do
          nil ->
            Value.truthy?(v)

          c ->
            case call_cb(c, [v], env, interp) do
              {{:val, res}, _, _} -> Value.truthy?(res)
              _ -> false
            end
        end
      end)

    out =
      Enum.reduce(kept, PArray.new(), fn {k, v}, acc ->
        {:ok, a2} = PArray.put(acc, wrap_raw_key(k), v)
        a2
      end)

    {{:val, {:array, out}}, env, interp}
  end

  defp wrap_raw_key(k) when is_integer(k), do: {:int, k}
  defp wrap_raw_key(k) when is_binary(k), do: {:string, k}

  defp reduce_cb(arr, cb, initial, env, interp) do
    PArray.values(arr)
    |> Enum.reduce(initial, fn v, acc ->
      case call_cb(cb, [acc, v], env, interp) do
        {{:val, res}, _, _} -> res
        _ -> acc
      end
    end)
    |> then(&{{:val, &1}, env, interp})
  end

  defp call_value({:closure, params, body, captures, _arrow?}, args, env, interp) do
    # captures may hold {:ref, id} cells for by-ref uses; reads and writes
    # flow through Env.lookup / assign naturally
    fenv = %Env{function: "{closure}", statics_key: nil, closure_captures: captures}
    {binds, interp2} = bind_params(params, args, fenv, env, interp)
    fenv2 = Enum.reduce(binds, fenv, fn {n, v}, acc -> %{acc | vars: Map.put(acc.vars, n, v)} end)

    case Interp.exec_stmts(body, fenv2, interp2) do
      {:ok, e, i} -> {{:val, :null}, e, i}
      {{:unwind, {:return, v}}, _, i} -> {{:val, v}, env, i}
      {{:unwind, _} = u, _, _} -> {u, env, interp2}
    end
  end

  def call_function({:user, params, body}, name, args, env, interp, _from_method?) do
    fenv = Env.function_scope(name, name)
    {binds, interp2} = bind_params(params, args, fenv, env, interp)

    # write back by-ref arguments
    fenv2 = Enum.reduce(binds, fenv, fn {n, v}, acc -> %{acc | vars: Map.put(acc.vars, n, v)} end)

    {res, _, interp3} = Interp.exec_stmts(body, fenv2, interp2)

    {interp4, env_out} =
      write_back_refs(params, args, env, fenv2, interp3)

    case res do
      :ok -> {{:val, :null}, env_out, interp4}
      {:unwind, {:return, v}} -> {{:val, v}, env_out, interp4}
      {:unwind, _} = u -> {{:unwind, elem(u, 1)}, env_out, interp4}
    end
  end

  defp write_back_refs(params, args, env, fenv, interp) do
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

  defp bind_params(params, args, fenv, env, interp) do
    args =
      Enum.map(args, fn
        {:arg, e, _, _} -> e
        {:arg_spread, e, _} -> {:spread, e}
      end)

    {vals, env2, interp2} = spread_args(args, env, interp)
    do_bind_params(params, vals, fenv, env2, interp2, [])
  end

  defp spread_args(args, env, interp) do
    Enum.reduce(args, {[], env, interp}, fn
      {:spread, e}, {acc, en, it} ->
        {{:val, v}, en2, it2} = eval(e, en, it)

        case v do
          {:array, arr} -> {acc ++ Enum.map(PArray.values(arr), &{:val, &1}), en2, it2}
          _ -> {acc, en2, warn(en2, it2, "only arrays can be spread")}
        end

      e, {acc, en, it} ->
        {{:val, v}, en2, it2} = eval(e, en, it)
        {acc ++ [{:val, v}], en2, it2}
    end)
  end

  defp do_bind_params(
         [{:param, name, _t, default, by_ref?, variadic?} | rest],
         args,
         fenv,
         env,
         interp,
         acc
       ) do
    if variadic? do
      rest_vals = Enum.map(args, fn {:val, v} -> v end)
      acc2 = [{name, {:array, PArray.from_pairs(Enum.map(rest_vals, &{nil, &1}))}} | acc]
      do_bind_params(rest, [], fenv, env, interp, acc2)
    else
      case args do
        [{:val, v} | more] ->
          {v2, interp2} =
            if by_ref? do
              case v do
                {:ref, _} -> {v, interp}
                plain -> make_ref_cell(plain, interp)
              end
            else
              {v, interp}
            end

          do_bind_params(rest, more, fenv, env, interp2, [{name, v2} | acc])

        [] ->
          case default do
            nil ->
              # ArgumentCountError is a PHP Error (catchable)
              err = %Error{kind: :argument_count_error, message: "Too few arguments"}
              {Enum.reverse(acc) ++ [{name, :null}], throw_error_tuple(err, interp)}

            dexpr ->
              {{:val, dv}, _e2, it2} = eval(dexpr, fenv, interp)
              do_bind_params(rest, [], fenv, env, it2, [{name, dv} | acc])
          end
      end
    end
  end

  defp do_bind_params([], _args, _fenv, _env, interp, acc), do: {Enum.reverse(acc), interp}

  defp call_builtin(entry, _name, args, env, interp) do
    %{fun: fun, refs: ref_positions} = entry

    case args |> eval_args(env, interp, false) |> resolve_args() do
      {:unwind, u} ->
        {{:unwind, u}, env, interp}

      {:ok, vals} ->
        call_resolved_builtin(fun, vals, args, ref_positions, env, interp)
    end
  end

  defp call_resolved_builtin(fun, vals, args, ref_positions, env, interp) do
    case fun.(vals, interp, %{env: env}) do
      {:ok, v, interp3} ->
        {{:val, v}, env, interp3}

      {:unwind, u, interp3} ->
        {{:unwind, u}, env, interp3}

      {:ref_call, v, new_vals, interp3} ->
        {{:val, v}, env, write_back_ref_args(args, new_vals, env, interp3, ref_positions)}
    end
  end

  defp eval_args(args, env, interp, _spread?) do
    Enum.map(args, fn
      {:arg, e, _, _} -> eval(e, env, interp)
      {:arg_spread, e, _} -> eval(e, env, interp)
    end)
  end

  defp resolve_args(arg_results) do
    Enum.reduce_while(arg_results, {:ok, []}, fn
      {{:val, v}, _, _}, {:ok, acc} -> {:cont, {:ok, acc ++ [v]}}
      {{:unwind, u}, _, _}, _ -> {:halt, {:unwind, u}}
    end)
  end

  defp write_back_ref_args(_args, _new_vals, env, interp, []) do
    interp
  end

  defp write_back_ref_args(args, new_vals, env, interp, positions) do
    Enum.reduce(positions, interp, fn pos, it ->
      case Enum.at(args, pos) do
        {:arg, lval, _, _} ->
          case Enum.at(new_vals, pos) do
            nil ->
              it

            new_v ->
              {_e2, it2} = assign(lval, new_v, env, it)
              it2
          end

        _ ->
          it
      end
    end)
  end

  # ───────────────────────── binary ops ─────────────────────────

  def apply_binop(op, l, r, _env, interp) do
    interp = interp || PhpBeam.Interp.new_stub()

    case op do
      :. ->
        {:ok, {:string, php_to_string(l) <> php_to_string(r)}}

      :+ ->
        arith(:+, l, r)

      :- ->
        arith(:-, l, r)

      :* ->
        arith(:*, l, r)

      :/ ->
        Value.divide(l, r)

      :% ->
        lossy_warn(l, interp)
        lossy_warn(r, interp)
        Value.modulo(l, r)

      :** ->
        Value.power(l, r)

      :== ->
        {:ok, {:bool, Value.loose_eq(l, r)}}

      :!= ->
        {:ok, {:bool, not Value.loose_eq(l, r)}}

      :=== ->
        {:ok, {:bool, Value.strict_eq(l, r)}}

      :!== ->
        {:ok, {:bool, not Value.strict_eq(l, r)}}

      :< ->
        {:ok, {:bool, Value.compare(l, r) < 0}}

      :<= ->
        {:ok, {:bool, Value.compare(l, r) <= 0}}

      :> ->
        {:ok, {:bool, Value.compare(l, r) > 0}}

      :>= ->
        {:ok, {:bool, Value.compare(l, r) >= 0}}

      :"<=>" ->
        {:ok, {:int, Value.compare(l, r)}}

      :& ->
        Value.bitwise(:&, l, r)

      :| ->
        Value.bitwise(:|, l, r)

      :^ ->
        Value.bitwise(:^, l, r)

      :shl ->
        Value.bitwise(:shl, l, r)

      :shr ->
        Value.bitwise(:shr, l, r)

      :instanceof ->
        {:ok, {:bool, false}}
    end
  end

  defp arith(op, {:array, a}, {:array, b}) when op == :+ do
    {:ok, {:array, PArray.union(a, b)}}
  end

  defp arith(op, l, r) do
    case Value.arith(op, l, r) do
      {:ok, v} -> {:ok, v}
      {:error, %Error{} = err} -> throw_error(err)
    end
  end

  # float→int implicit conversion deprecation (parity with PHP 8)
  defp lossy_warn({:float, f}, interp) when trunc(f) != f do
    PhpBeam.Interp.warn(
      interp,
      "Implicit conversion from float " <>
        PhpBeam.Value.float_to_string(f) <> " to int loses precision"
    )
  end

  defp lossy_warn(_, _interp), do: :ok

  defp throw_error(%Error{} = err) do
    {:unwind, {:php_throw, {:native_error, Error.php_class(err), err.message}}}
  end

  defp throw_error_tuple(err, interp), do: throw_error(err) |> elem(1) |> then(&{&1, interp})

  defp with_val(e, env, interp, f) do
    {{:val, v}, env2, interp2} = eval(e, env, interp)

    case f.(v) do
      {{:val, r}, _, _} -> {{:val, r}, env2, interp2}
      {:unwind, _} = u -> {u, env2, interp2}
    end
  end

  # ───────────────────────── helpers ─────────────────────────

  def deref({:ref, id}, interp), do: Map.get(interp.refs, id, :null)
  def deref(v, _interp), do: v

  def new_ref(v, interp) do
    id = interp.next_ref
    {id, %{interp | refs: Map.put(interp.refs, id, v), next_ref: id + 1}}
  end

  def make_ref_cell(v, interp) do
    {id, interp2} = new_ref(v, interp)
    {{:ref, id}, interp2}
  end

  defp var_name({:var, n}), do: n

  defp var_value(env, interp, name) do
    case Env.lookup(env, interp, name) do
      {:ok, v} -> deref(v, interp)
      _ -> :null
    end
  end

  defp var_or_new_ref(env, interp, name) do
    case Env.lookup(env, interp, name) do
      {:ok, {:ref, _} = r} -> r
      {:ok, v} -> elem(make_ref_cell(v, interp), 0)
      _ -> elem(make_ref_cell(:null, interp), 0)
    end
  end

  defp globals_array(interp) do
    {:array, PArray.from_pairs(Enum.map(interp.globals, fn {k, v} -> {{:string, k}, v} end))}
  end

  defp bind_var_to_ref(env, _interp, {:var, name}, id) do
    # keep a local binding pointing at the same cell so later writes share it
    {:ok, env2, _} = {Env.bind_var(env, nil, name, {:ref, id}), nil}
    env2
  end

  defp bind_var_to_ref(env, _interp, _target, _id), do: env

  def concat_to_string(exprs, env, interp) do
    Enum.reduce_while(exprs, {"", env, interp}, fn e, {acc, en, it} ->
      case eval(e, en, it) do
        {{:val, v}, en2, it2} ->
          {s, it3} = warn_to_string(v, en2, it2)
          {:cont, {acc <> s, en2, it3}}

        {{:unwind, u}, _, _} ->
          {:halt, {:unwind, u}}
      end
    end)
  end

  # string conversion that emits the Array-to-string warning
  def warn_to_string(v, _env, interp) do
    case Value.cast_string(v) do
      {:ok, s} -> {s, interp}
      {:warn_array, _} -> {"Array", warn(interp, "Array to string conversion")}
      _ -> {"", interp}
    end
  end

  defp warn(interp, msg), do: PhpBeam.Interp.warn(interp, msg)

  defp interp_parts(parts, env, interp) do
    Enum.reduce(parts, {"", env, interp}, fn part, {acc, en, it} ->
      case part do
        {:text, s} ->
          {acc <> s, en, it}

        {:complex, ast} ->
          {{:val, v}, en2, it2} = eval(ast, en, it)
          {acc <> php_to_string(v), en2, it2}

        other when is_tuple(other) ->
          {{:val, v}, en2, it2} = eval(other, en, it)
          {acc <> php_to_string(v), en2, it2}
      end
    end)
  end

  def php_to_string(v) do
    case Value.cast_string(v) do
      {:ok, s} -> s
      {:warn_array, _} -> "Array"
      _ -> ""
    end
  end

  defp string_of_cast({:ok, s}), do: s
  defp string_of_cast({:warn_array, _}), do: "Array"

  defp name_of({:var, n}), do: n
  defp name_of(_), do: ""

  defp match_arms([], _s, _env, _interp) do
    {{:unwind, {:php_throw, {:native_error, "UnhandledMatchError", "Unhandled match case"}}}, nil,
     nil}
  end

  defp match_arms([{:default, body} | _], _s, env, interp), do: eval(body, env, interp)

  defp match_arms([{conds, body} | rest], s, env, interp) do
    match =
      Enum.any?(conds, fn c ->
        {{:val, cv}, _e, _i} = eval(c, env, interp)
        Value.strict_eq(s, cv)
      end)

    if match do
      eval(body, env, interp)
    else
      match_arms(rest, s, env, interp)
    end
  end

  def const_eval_quiet(v, _env, _interp), do: eval_const_expr(v)

  defp eval_const_expr({:int, n}), do: {:int, n}
  defp eval_const_expr({:string, s}), do: {:string, s}
  defp eval_const_expr({:bool, b}), do: {:bool, b}
  defp eval_const_expr(:null), do: :null
  defp eval_const_expr(_), do: :null

  defp resolve_function(name, fq, interp) do
    cond do
      fq == true ->
        Map.get(interp.functions, name, :error)

      interp.ns == [] ->
        Map.get(interp.functions, name, :error)

      true ->
        ns_name = (interp.ns ++ [name]) |> Enum.join("\\") |> String.downcase()

        Map.get(interp.functions, ns_name, Map.get(interp.functions, name, :error))
    end
  end

  defp resolve_const(name, _fq, interp) do
    case Map.fetch(interp.consts, name) do
      {:ok, v} -> {:ok, v}
      :error -> builtin_const(name)
    end
  end

  defp builtin_const(name) do
    case name do
      "PHP_EOL" ->
        {:ok, {:string, "\n"}}

      "PHP_INT_MAX" ->
        {:ok, {:int, @int_max}}

      "PHP_INT_MIN" ->
        {:ok, {:int, @int_min}}

      "PHP_INT_SIZE" ->
        {:ok, {:int, 8}}

      "PHP_FLOAT_EPSILON" ->
        {:ok, {:float, :math.pow(2, -52)}}

      "PHP_FLOAT_MAX" ->
        {:ok, {:float, 1.7976931348623157e308}}

      "PHP_FLOAT_MIN" ->
        {:ok, {:float, 2.2250738585072014e-308}}

      "PHP_VERSION" ->
        {:ok, {:string, "8.4.2"}}

      "PHP_OS" ->
        {:ok, {:string, "Darwin"}}

      "PHP_OS_FAMILY" ->
        {:ok, {:string, "Darwin"}}

      "M_PI" ->
        {:ok, {:float, :math.pi()}}

      "M_E" ->
        {:ok, {:float, :math.exp(1)}}

      "M_SQRT2" ->
        {:ok, {:float, :math.sqrt(2)}}

      "NAN" ->
        {:ok, {:float, :erlang.nan()}}

      "INF" ->
        {:ok,
         {:float, :erlang.float_to_binary(:erlang.list_to_float('1.0e308')) |> String.to_float()}}

      "E_ALL" ->
        {:ok, {:int, 32767}}

      "E_WARNING" ->
        {:ok, {:int, 2}}

      "E_NOTICE" ->
        {:ok, {:int, 8}}

      "PHP_ZTS" ->
        {:ok, {:bool, false}}
        SHOULD_NOT_EXIST

      "STR_PAD_LEFT" ->
        {:ok, {:int, 0}}

      "STR_PAD_RIGHT" ->
        {:ok, {:int, 1}}

      "STR_PAD_BOTH" ->
        {:ok, {:int, 2}}

      "SORT_REGULAR" ->
        {:ok, {:int, 0}}

      "SORT_NUMERIC" ->
        {:ok, {:int, 1}}

      "SORT_STRING" ->
        {:ok, {:int, 2}}

      "COUNT_RECURSIVE" ->
        {:ok, {:int, 1}}

      "JSON_HEX_TAG" ->
        {:ok, {:int, 1}}

      "EXTR_OVERWRITE" ->
        {:ok, {:int, 0}}

      "PHP_DEBUG" ->
        {:ok, {:bool, false}}

      "TRUE" ->
        {:ok, {:bool, true}}

      "FALSE" ->
        {:ok, {:bool, false}}

      "NULL" ->
        {:ok, :null}

      _ ->
        :error
    end
  end

  def warn(env, interp, msg) do
    # suppression is tracked on the interpreter; env is accepted for uniformity
    Interp.warn(%{interp | __struct__: PhpBeam.Interp}, msg)
    interp
  end

  # ───────────────────────── lvalues ─────────────────────────

  def read_target(target, env, interp) do
    case target do
      {:var, name} ->
        case Env.lookup(env, interp, name) do
          {:ok, v} ->
            {v, env, interp}

          {:static, key, sname} ->
            {Map.get(interp.statics[key], sname, :null), env, interp}

          :undefined ->
            interp2 = warn(env, interp, "Undefined variable $#{name}")
            {:null, env, interp2}
        end

      {:var_var, e} ->
        {{:val, {:string, name}}, _e2, _i2} = eval(e, env, interp)
        read_target({:var, name}, env, interp)

      _ ->
        {{:val, v}, env2, interp2} = eval(target, env, interp)
        {v, env2, interp2}
    end
  end

  def assign(target, v, env, interp)

  def assign({:var, name}, v, env, interp) do
    cond do
      Map.has_key?(env.statics, name) ->
        key = env.statics[name]
        {env, update_in(interp.statics[key], &Map.put(&1, name, v))}

      true ->
        case Env.lookup(env, interp, name) do
          {:ok, {:ref, id}} ->
            {env, %{interp | refs: Map.put(interp.refs, id, v)}}

          _ ->
            {:ok, env2, interp2} = Env.bind_var(env, interp, name, v)
            {env2, interp2}
        end
    end
  end

  def assign({:var_var, e}, v, env, interp) do
    {{:val, name}, _e2, _i2} = eval(e, env, interp)

    case name do
      {:string, n} -> assign({:var, n}, v, env, interp)
      _ -> {env, interp}
    end
  end

  def assign({:list_pat, items}, v, env, interp) do
    destructure(items, v, env, interp)
  end

  def assign({:index, container, idx}, v, env, interp) do
    {path, env2, interp2} = build_path(container, env, interp)

    case idx do
      nil ->
        path_append(path, v, env2, interp2)

      idx_expr ->
        {{:val, key}, env3, interp3} = eval(idx_expr, env2, interp2)
        path_set(path, key, v, env3, interp3)
    end
  end

  def assign({:prop, _, _}, _v, env, interp), do: {env, interp}
  def assign({:static_prop, _, _}, _v, env, interp), do: {env, interp}
  def assign(_, _v, env, interp), do: {env, interp}

  # build a write path: [{:var, name} | segments]
  defp build_path(target, env, interp) do
    case lvalue_path(target, env) do
      {:ok, path} -> {path, env, interp}
      :error -> {[], env, interp}
    end
  end

  def lvalue_path({:var, name}, _env), do: {:ok, [{:var, name}]}
  def lvalue_path({:var_var, _}, _env), do: :error

  def lvalue_path({:index, container, idx_expr}, env) do
    case lvalue_path(container, env) do
      {:ok, path} -> {:ok, path ++ [{:index_expr, idx_expr}]}
      :error -> :error
    end
  end

  def lvalue_path(_, _env), do: :error

  defp path_append(path, v, env, interp) do
    {container, env2, interp2} = path_get(path, env, interp)

    new_container =
      case container do
        {:array, arr} -> {:array, PArray.push(arr, v)}
        :null -> {:array, PArray.push(PArray.new(), v)}
        {:string, s} -> {:string, s <> first_byte_str(v)}
        _ -> container
      end

    path_put(path, new_container, env2, interp2)
  end

  defp first_byte_str({:string, <<b::binary-size(1), _::binary>>}), do: b
  defp first_byte_str(_), do: ""

  defp path_set(path, key, v, env, interp) do
    {container, env2, interp2} = path_get(path, env, interp)

    new_container =
      case container do
        {:array, arr} ->
          case PArray.put(arr, key, v) do
            {:ok, arr2} -> {:array, arr2}
            {:error, msg} -> throw_set_error(msg, env2, interp2)
          end

        :null ->
          {:array, PArray.from_pairs([{key, v}])}

        {:string, s} ->
          string_offset_write(s, key, v, env2, interp2)

        _ ->
          warn(env2, interp2, "Cannot use a scalar value as an array")
          container
      end

    path_put(path, new_container, env2, interp2)
  end

  defp throw_set_error(msg, _env, _interp), do: throw({:set_error, msg})

  defp string_offset_write(s, key, v, env, interp) do
    {ok?, idx} = offset_index(key)

    case Value.to_int(idx) do
      {:ok, {:int, i}} ->
        i2 = if i < 0, do: byte_size(s) + i, else: i

        cond do
          i2 < 0 or i2 >= byte_size(s) ->
            warn(env, interp, "Uninitialized string offset")
            s

          true ->
            <<pre::binary-size(i2), _c, post::binary>> = s
            pre <> first_byte_str(v) <> post
        end

      _ ->
        if ok? do
          s
        else
          warn(env, interp, "Illegal string offset")
          s
        end
    end
  end

  defp offset_index({:int, i}), do: {true, {:int, i}}
  defp offset_index({:string, s}), do: {false, {:string, s}}
  defp offset_index(v), do: {true, v}

  # read the container at a path head (variable) — paths are var-rooted
  defp path_get([{:var, name} | _], env, interp) do
    case Env.lookup(env, interp, name) do
      {:ok, v} -> {deref_container(v, interp), env, interp}
      {:static, key, sname} -> {Map.get(interp.statics[key], sname, :null), env, interp}
      :undefined -> {:null, env, interp}
    end
  end

  defp path_get([], _env, interp), do: {:null, nil, interp}

  defp deref_container({:ref, id}, interp), do: Map.get(interp.refs, id, :null)
  defp deref_container(v, _), do: v

  defp path_put([{:var, name}], v, env, interp), do: assign({:var, name}, v, env, interp)

  defp path_put([{:var, name} | rest], v, env, interp) do
    {base, _, _} = path_get([{:var, name}], env, interp)
    updated = update_path(base, rest, v)
    assign({:var, name}, updated, env, interp)
  end

  defp update_path(base, [{:index_expr, idx_expr} | rest], v) do
    # constant-expression index within a nested write: evaluate statically when literal
    idx = literal_idx(idx_expr)
    update_at(base, idx, rest, v)
  end

  defp literal_idx({:int, n}), do: {:int, n}
  defp literal_idx({:string, s}), do: {:string, s}
  defp literal_idx({:var, _}), do: nil
  defp literal_idx(_), do: nil

  defp update_at(base, nil, _rest, _v), do: base

  defp update_at(base, idx, [{:index_expr, next_idx}], v) do
    inner = read_index_raw(base, idx)
    updated = update_at(inner, literal_idx(next_idx), [], v)

    case {base, idx} do
      {{:array, arr}, k} ->
        case PArray.put(arr, k, updated) do
          {:ok, arr2} -> {:array, arr2}
          _ -> base
        end

      _ ->
        base
    end
  end

  defp update_at(base, idx, [], v) do
    case {base, idx} do
      {{:array, arr}, k} ->
        case PArray.put(arr, k, v) do
          {:ok, arr2} -> {:array, arr2}
          _ -> base
        end

      {_, nil} ->
        case base do
          {:array, arr} -> {:array, PArray.push(arr, v)}
          _ -> {:array, PArray.push(PArray.new(), v)}
        end

      _ ->
        base
    end
  end

  # write into a specific key of the path root (foreach by-ref)
  def path_write(path, key, v, env, interp) do
    {head, rest} = split_path(path)

    container =
      case head do
        {:var, name} ->
          case Env.lookup(env, interp, name) do
            {:ok, cv} -> deref_container(cv, interp)
            _ -> :null
          end
      end

    container2 =
      case {container, rest} do
        {{:array, arr}, []} ->
          case PArray.put(arr, key, v) do
            {:ok, arr2} -> {:array, arr2}
            _ -> container
          end

        _ ->
          container
      end

    case head do
      {:var, name} -> assign({:var, name}, container2, env, interp)
    end
  end

  defp split_path([h]), do: {h, []}
  defp split_path(path), do: {hd(path), tl(path)}

  # ───────────────────────── reads ─────────────────────────

  defp index_read(container, key, env, interp) do
    case container do
      {:array, arr} ->
        case PArray.fetch(arr, key) do
          {:ok, v} ->
            {{:val, deref(v, interp)}, env, interp}

          :error ->
            interp2 = warn(env, interp, "Undefined array key \"#{plain_key(key)}\"")
            {{:val, :null}, env, interp2}
        end

      {:string, s} ->
        case Value.to_int(key) do
          {:ok, {:int, i}} ->
            i2 = if i < 0, do: byte_size(s) + i, else: i

            if i2 >= 0 and i2 < byte_size(s) do
              {{:val, {:string, binary_part(s, i2, 1)}}, env, interp}
            else
              interp2 = warn(env, interp, "Uninitialized string offset")
              {{:val, {:string, ""}}, env, interp2}
            end

          _ ->
            interp2 = warn(env, interp, "Illegal string offset")
            {{:val, {:string, ""}}, env, interp2}
        end

      :null ->
        interp2 = warn(env, interp, "Trying to access array offset on value of type null")
        {{:val, :null}, env, interp2}

      _ ->
        interp2 =
          warn(
            env,
            interp,
            "Trying to access array offset on value of type #{Value.gettype(container)}"
          )

        {{:val, :null}, env, interp2}
    end
  end

  defp read_index_raw({:array, arr}, idx) do
    case PArray.fetch(arr, idx) do
      {:ok, v} -> v
      :error -> :null
    end
  end

  defp read_index_raw(_, _), do: :null

  defp plain_key({:int, i}), do: Integer.to_string(i)
  defp plain_key({:string, s}), do: s
  defp plain_key(_), do: ""

  # isset without warnings
  def isset?(target, env, interp) do
    case target do
      {:var, name} ->
        case Env.lookup(env, interp, name) do
          {:ok, v} ->
            {v != :null, env, interp}

          {:static, key, sname} ->
            {Map.get(interp.statics[key], sname, :null) != :null, env, interp}

          :undefined ->
            {false, env, interp}
        end

      {:index, container, idx_expr} ->
        {ok?, env2, interp2} = isset?(container, env, interp)

        if ok? do
          {{:val, c}, env3, interp3} = eval(container, env2, interp2)

          case idx_expr do
            nil ->
              {false, env3, interp3}

            _ ->
              {{:val, k}, env4, interp4} = eval(idx_expr, env3, interp3)

              case c do
                {:array, arr} ->
                  {PArray.has_key?(arr, k) and PArray.get(arr, k) != :null, env4, interp4}

                {:string, s} ->
                  string_offset_isset?(s, k, env4, interp4)

                _ ->
                  {false, env4, interp4}
              end
          end
        else
          {false, env2, interp2}
        end

      {:prop, _, _} ->
        {false, env, interp}

      {:nullsafe_prop, _, _} ->
        {false, env, interp}

      _ ->
        {{:val, v}, env2, interp2} = eval(target, env, interp)
        {v != :null, env2, interp2}
    end
  end

  defp string_offset_isset?(s, k, env, interp) do
    case Value.to_int(k) do
      {:ok, {:int, i}} ->
        i2 = if i < 0, do: byte_size(s) + i, else: i
        {i2 >= 0 and i2 < byte_size(s), env, interp}

      _ ->
        {false, env, interp}
    end
  end

  # ───────────────────────── unset ─────────────────────────

  def unset_target({:var, name}, env, interp) do
    {:ok, e2, i2} = Env.unset_var(env, interp, name)
    {:ok, e2, i2}
  end

  def unset_target({:index, container, idx_expr}, env, interp) do
    case lvalue_path(container, env) do
      {:ok, path} ->
        {{:val, c}, env2, interp2} = eval(container, env, interp)
        {{:val, k}, env3, interp3} = eval(idx_expr, env2, interp2)

        case c do
          {:array, arr} ->
            case PArray.delete(arr, k) do
              {:ok, arr2} ->
                path_put(path, {:array, arr2}, env3, interp3)
                |> then(fn {e, i} -> {:ok, e, i} end)
            end

          _ ->
            {:ok, env3, interp3}
        end

      :error ->
        {:ok, env, interp}
    end
  end

  def unset_target(_, env, interp), do: {:ok, env, interp}

  # ───────────────────────── destructuring ─────────────────────────

  def destructure(items, v, env, interp) do
    arr =
      case v do
        {:array, a} -> a
        _ -> PArray.new()
      end

    {_, result} =
      Enum.reduce(items, {0, {env, interp}}, fn
        nil, {idx, acc} ->
          {idx + 1, acc}

        {:kv, nil, target, _}, {idx, {e, i}} ->
          {e2, i2} = assign(target, PArray.get(arr, {:int, idx}), e, i)
          {idx + 1, {e2, i2}}

        {:kv, kexpr, target, _}, {idx, {e, i}} ->
          {{:val, k}, _e2, _i2} = eval(kexpr, e, i)
          {e3, i3} = assign(target, PArray.get(arr, k, :null), e, i)
          {idx, {e3, i3}}
      end)

    result
  end
end
