defmodule PhpBeam.Interp do
  @moduledoc """
  Interpreter state and program driver. Expression evaluation lives in
  `PhpBeam.Eval`, rendering in `PhpBeam.Render`, builtins in `PhpBeam.Builtin`.

  Every eval function threads `{result, env, interp}` where result is
  `{:val, v}` for expressions or `:ok | {:unwind, signal}` for statements.
  Unwinds carry PHP control flow (return/break/continue/throw/halt) so that
  interpreter state changes (statics, refs) survive unwinding — unlike
  Elixir exceptions, which would discard accumulated state.
  """

  alias PhpBeam.{Env, Eval, PArray, Value}

  defstruct out: [],
            functions: %{},
            globals: %{},
            consts: %{},
            classes: %{},
            refs: %{},
            next_ref: 0,
            statics: %{},
            objects: %{},
            next_obj: 1,
            ns: [],
            uses: %{normal: %{}, function: %{}, const: %{}},
            halted: nil,
            suppress: 0,
            warnings: 0

  @type t :: %__MODULE__{}

  # ───────────────────────── entry points ─────────────────────────

  def run(src) do
    interp = register_builtins(%__MODULE__{})
    env = Env.global_scope(argv_info(src))

    with {:ok, toks} <- PhpBeam.Lexer.tokenize(src),
         {:ok, stmts} <- PhpBeam.Parser.parse(toks) do
      {res, _env, interp2} = exec_stmts(stmts, env, interp)

      case res do
        {:unwind, {:halt, code}} ->
          finish(interp2, code)

        {:unwrap, _} ->
          finish(interp2, 0)

        :ok ->
          finish(interp2, 0)

        {:unwind, {:php_throw, val}} ->
          {render_uncaught(val, interp2), 255, interp2}

        {:unwind, {:fatal, msg}} ->
          {"PHP Fatal error:  #{msg}\n", 255, interp2}
      end
    else
      {:error, msg, line} ->
        {"PHP Parse error:  syntax error, #{msg}" <> maybe_line(line) <> "\n", 255,
         interp2_stub()}
    end
  end

  # used by tests: returns {output, exit_code} without stderr noise
  def run_quiet(src) do
    {out, code, _interp} = run(src)
    {out, code}
  end

  # ───────────────────────── persistent REPL state ─────────────────────────

  def repl_init do
    {Env.global_scope([]), register_builtins(%__MODULE__{})}
  end

  # evaluate one snippet against persistent state: {output, new_state}
  def repl_eval({env, interp}, src) do
    with {:ok, toks} <- PhpBeam.Lexer.tokenize("<?php " <> src),
         {:ok, stmts} <- PhpBeam.Parser.parse(toks) do
      {res, e2, i2} = exec_stmts(stmts, env, interp)

      out = IO.iodata_to_binary(Enum.reverse(i2.out))
      i3 = %{i2 | out: []}

      case res do
        :ok ->
          {out, {e2, i3}}

        {:unwind, {:return, _}} ->
          {out, {e2, i3}}

        {:unwind, {:halt, code}} ->
          {out, {:halt, code}}

        {:unwind, {:php_throw, val}} ->
          msg = uncaught_message(val, i3)
          {out <> msg, {env, i3}}

        {:unwind, {:fatal, msg}} ->
          {out <> "PHP Fatal error:  #{msg}\n", {env, i3}}

        {:unwind, _} ->
          {out, {e2, i3}}
      end
    else
      {:error, msg, line} ->
        {"PHP Parse error:  #{msg} on line #{line}\n", {env, interp}}
    end
  end

  defp uncaught_message({:native_error, class, msg}, _i),
    do: "\nPHP Fatal error:  Uncaught #{class}: #{msg}\n"

  defp uncaught_message({:object, _} = obj_ref, i) do
    obj = Eval.get_object(i, obj_ref)
    cls = display_class(i, obj.class)
    msg = PhpBeam.Eval.php_to_string(PArray.get(obj.props, {:string, "message"}, {:string, ""}))
    "\nPHP Fatal error:  Uncaught #{cls}: #{msg}\n"
  end

  defp uncaught_message(_, _i), do: "\nPHP Fatal error:  uncaught value\n"

  defp display_class(i, key) do
    case PhpBeam.Classes.get_class(i, key) do
      %{name: n} -> n
      _ -> if key == "stdclass", do: "stdClass", else: key
    end
  end

  defp interp2_stub, do: %__MODULE__{}

  defp maybe_line(0), do: ""
  defp maybe_line(l), do: " on line #{l}"

  defp argv_info(_src), do: []

  @doc "placeholder interp for contexts without one"
  def new_stub, do: %__MODULE__{}

  defp finish(interp, code) do
    {IO.iodata_to_binary(Enum.reverse(interp.out)), code, interp}
  end

  defp render_uncaught({:native_error, class, msg}, interp) do
    out = IO.iodata_to_binary(Enum.reverse(interp.out))
    out <> "\nPHP Fatal error:  Uncaught #{class}: #{msg}\n  thrown on line 1\n"
  end

  defp render_uncaught(_, interp), do: IO.iodata_to_binary(Enum.reverse(interp.out))

  # ───────────────────────── output / warnings ─────────────────────────

  def write(interp, data) when is_binary(data),
    do: %{interp | out: [data | interp.out]}

  def warn(interp, msg) do
    if interp.suppress > 0 do
      interp
    else
      IO.write(:stderr, "PHP Warning:  #{msg}\n")
      %{interp | warnings: interp.warnings + 1}
    end
  end

  defp register_builtins(interp) do
    interp
    |> Map.update!(:functions, fn fns -> Map.merge(fns, PhpBeam.Builtin.registry()) end)
    |> Map.update!(:classes, fn classes ->
      Map.merge(PhpBeam.Classes.native_classes(), classes)
    end)
  end

  # ───────────────────────── statement execution ─────────────────────────

  def exec_stmts(stmts, env, interp, acc \\ :ok)

  def exec_stmts([], env, interp, :ok), do: {:ok, env, interp}

  def exec_stmts([], env, interp, {:unwind, u}), do: {{:unwind, u}, env, interp}

  # once unwound, stop executing the remaining statements
  def exec_stmts([_ | _], env, interp, {:unwind, u}), do: {{:unwind, u}, env, interp}

  def exec_stmts([s | rest], env, interp, :ok) do
    case exec_stmt(s, env, interp) do
      {:ok, env2, interp2} -> exec_stmts(rest, env2, interp2, :ok)
      {{:unwind, u}, env2, interp2} -> exec_stmts([], env2, interp2, {:unwind, u})
    end
  end

  def exec_stmt({:html, text}, env, interp), do: {:ok, env, write(interp, text)}

  def exec_stmt({:block, stmts}, env, interp), do: exec_stmts(stmts, env, interp)

  def exec_stmt({:echo, exprs}, env, interp) do
    case Eval.concat_to_string(exprs, env, interp) do
      {out, env2, interp2} -> {:ok, env2, write(interp2, out)}
      {:unwind, u, env2, interp2} -> {{:unwind, u}, env2, interp2}
    end
  end

  def exec_stmt({:expr_stmt, e}, env, interp) do
    case Eval.eval(e, env, interp) do
      {{:val, _}, env2, interp2} -> {:ok, env2, interp2}
      unw -> unw
    end
  end

  def exec_stmt({:if, cond, then, else_part}, env, interp) do
    {{:val, c}, env2, interp2} = Eval.eval(cond, env, interp)

    if Value.truthy?(c) do
      exec_stmts(then, env2, interp2)
    else
      case else_part do
        nil -> {:ok, env2, interp2}
        stmts -> exec_stmts(stmts, env2, interp2)
      end
    end
  end

  def exec_stmt({:while, cond, body}, env, interp), do: loop_while(cond, body, env, interp)

  defp loop_while(cond, body, env, interp) do
    {{:val, c}, env2, interp2} = Eval.eval(cond, env, interp)

    if Value.truthy?(c) do
      case exec_stmts(body, env2, interp2) do
        {:ok, env3, interp3} ->
          loop_while(cond, body, env3, interp3)

        {{:unwind, {:break, 1}}, env3, interp3} ->
          {:ok, env3, interp3}

        {{:unwind, {:continue, 1}}, env3, interp3} ->
          loop_while(cond, body, env3, interp3)

        {{:unwind, {:break, n}}, env3, interp3} ->
          {{:unwind, {:break, n - 1}}, env3, interp3}

        {{:unwind, {:continue, n}}, env3, interp3} ->
          {{:unwind, {:continue, n - 1}}, env3, interp3}

        unw ->
          unw
      end
    else
      {:ok, env2, interp2}
    end
  end

  def exec_stmt({:do_while, body, cond}, env, interp), do: loop_do_while(body, cond, env, interp)

  defp loop_do_while(body, cond, env, interp) do
    case exec_stmts(body, env, interp) do
      {:ok, env2, interp2} ->
        {{:val, c}, env3, interp3} = Eval.eval(cond, env2, interp2)

        if Value.truthy?(c),
          do: loop_do_while(body, cond, env3, interp3),
          else: {:ok, env3, interp3}

      {{:unwind, {:break, 1}}, env2, interp2} ->
        {:ok, env2, interp2}

      {{:unwind, {:continue, 1}}, env2, interp2} ->
        {{:val, c}, env3, interp3} = Eval.eval(cond, env2, interp2)

        if Value.truthy?(c),
          do: loop_do_while(body, cond, env3, interp3),
          else: {:ok, env3, interp3}

      {{:unwind, {:break, n}}, env2, interp2} ->
        {{:unwind, {:break, n - 1}}, env2, interp2}

      {{:unwind, {:continue, n}}, env2, interp2} ->
        {{:unwind, {:continue, n - 1}}, env2, interp2}

      unw ->
        unw
    end
  end

  def exec_stmt({:for, init, cond, step, body}, env, interp) do
    {_, env1, interp1} = eval_all(init, env, interp)
    loop_for(cond, step, body, env1, interp1)
  end

  defp loop_for(cond, step, body, env, interp) do
    {go?, env2, interp2} =
      case cond do
        nil ->
          {true, env, interp}

        c ->
          {{:val, v}, e, i} = Eval.eval(c, env, interp)
          {Value.truthy?(v), e, i}
      end

    if go? do
      case exec_stmts(body, env2, interp2) do
        {:ok, env3, interp3} ->
          {_, env4, interp4} = eval_all(step, env3, interp3)
          loop_for(cond, step, body, env4, interp4)

        {{:unwind, {:break, 1}}, env3, interp3} ->
          {:ok, env3, interp3}

        {{:unwind, {:continue, 1}}, env3, interp3} ->
          {_, env4, interp4} = eval_all(step, env3, interp3)
          loop_for(cond, step, body, env4, interp4)

        {{:unwind, {:break, n}}, env3, interp3} ->
          {{:unwind, {:break, n - 1}}, env3, interp3}

        {{:unwind, {:continue, n}}, env3, interp3} ->
          {{:unwind, {:continue, n - 1}}, env3, interp3}

        unw ->
          unw
      end
    else
      {:ok, env2, interp2}
    end
  end

  defp eval_all(exprs, env, interp) do
    Enum.reduce(exprs, {[], env, interp}, fn e, {_, en, it} -> Eval.eval(e, en, it) end)
  end

  def exec_stmt({:foreach, subj, key_t, val_t, by_ref?, body}, env, interp) do
    {{:val, subject}, env2, interp2} = Eval.eval(subj, env, interp)

    case subject do
      {:array, arr} ->
        pairs = PArray.to_pairs(arr)

        if by_ref? do
          # by-ref foreach requires a writable lvalue subject for write-back
          case Eval.lvalue_path(subj, env2) do
            {:ok, path} -> foreach_ref(pairs, path, key_t, val_t, body, env2, interp2, subj)
            :error -> foreach_val(pairs, key_t, val_t, body, env2, interp2, true)
          end
        else
          foreach_val(pairs, key_t, val_t, body, env2, interp2, false)
        end

      _other ->
        interp3 = warn(interp2, "foreach() argument must be of type array")
        {:ok, env2, interp3}
    end
  end

  defp foreach_val([], _key_t, _val_t, _body, env, interp, _ref?), do: {:ok, env, interp}

  defp foreach_val([{k, v} | rest], key_t, val_t, body, env, interp, ref?) do
    v = if ref?, do: v, else: Eval.deref(v, interp)

    {env2, interp2} = bind_target(env, interp, val_t, v)
    {env3, interp3} = bind_target(env2, interp2, key_t, wrap_key(k))

    case exec_stmts(body, env3, interp3) do
      {:ok, e4, i4} -> foreach_val(rest, key_t, val_t, body, e4, i4, ref?)
      {{:unwind, {:break, 1}}, e4, i4} -> {:ok, e4, i4}
      {{:unwind, {:continue, 1}}, e4, i4} -> foreach_val(rest, key_t, val_t, body, e4, i4, ref?)
      {{:unwind, {:break, n}}, e4, i4} -> {{:unwind, {:break, n - 1}}, e4, i4}
      {{:unwind, {:continue, n}}, e4, i4} -> {{:unwind, {:continue, n - 1}}, e4, i4}
      unw -> unw
    end
  end

  defp foreach_ref([], _path, _key_t, _val_t, _body, env, interp, _subj), do: {:ok, env, interp}

  defp foreach_ref([{k, v} | rest], path, key_t, val_t, body, env, interp, subj) do
    # bind $v to a reference cell, storing the cell in the array element
    {v_val, interp2} =
      case v do
        {:ref, _} = r ->
          {r, interp}

        plain ->
          {id, it} = new_ref(plain, interp)
          {{:ref, id}, it}
      end

    # write the ref back into the subject container
    interp3 =
      case Eval.path_write(path, k, v_val, env, interp2) do
        {_e, it} -> it
        _ -> interp2
      end

    {env2, interp4} = bind_target(env, interp3, val_t, v_val)
    {env3, interp5} = bind_target(env2, interp4, key_t, wrap_key(k))

    case exec_stmts(body, env3, interp5) do
      {:ok, env3, interp4} ->
        # subject may have been reassigned during the body; re-evaluate
        {{:val, subject}, _e, interp5} = Eval.eval(subj, env3, interp4)

        remaining =
          case subject do
            {:array, arr} -> remaining_pairs(arr, k)
            _ -> []
          end

        foreach_ref(remaining, path, key_t, val_t, body, env3, interp5, subj)

      {{:unwind, {:break, 1}}, env3, interp3} ->
        {:ok, env3, interp3}

      {{:unwind, {:continue, 1}}, env3, interp3} ->
        {{:val, subject}, _e, interp5} = Eval.eval(subj, env3, interp3)

        remaining =
          case subject do
            {:array, arr} -> remaining_pairs(arr, k)
            _ -> []
          end

        foreach_ref(remaining, path, key_t, val_t, body, env3, interp5, subj)

      {{:unwind, {:break, n}}, env3, interp3} ->
        {{:unwind, {:break, n - 1}}, env3, interp3}

      {{:unwind, {:continue, n}}, env3, interp3} ->
        {{:unwind, {:continue, n - 1}}, env3, interp3}

      unw ->
        unw
    end
  end

  # keys here are bare (int/binary), not tagged values
  defp remaining_pairs(arr, after_key) do
    pairs = PArray.to_pairs(arr)
    idx = Enum.find_index(pairs, fn {k, _} -> k == after_key end)

    cond do
      is_nil(idx) -> []
      true -> Enum.drop(pairs, idx + 1)
    end
  end

  defp bind_target(env, target, v, interp)

  # returns {env, interp} — binding at top level also updates interp.globals
  defp bind_target(env, interp, {:var, name}, v) do
    {:ok, env2, interp2} = Env.bind_var(env, interp, name, v)
    {env2, interp2}
  end

  defp bind_target(env, interp, {:var_var, e}, v) do
    case Eval.eval(e, env, interp) do
      {{:val, {:string, name}}, _e2, _i2} ->
        {:ok, env2, interp2} = Env.bind_var(env, interp, name, v)
        {env2, interp2}

      _ ->
        {env, interp}
    end
  end

  defp bind_target(env, interp, {:list_pat, items}, v) do
    {env2, interp2} = Eval.destructure(items, v, env, interp)
    {env2, interp2}
  end

  defp bind_target(env, interp, _other, _v), do: {env, interp}

  def exec_stmt({:switch, subj, cases}, env, interp) do
    {{:val, s}, env2, interp2} = Eval.eval(subj, env, interp)
    exec_switch_cases(cases, s, env2, interp2)
  end

  defp exec_switch_cases([], _s, env, interp), do: {:ok, env, interp}

  defp exec_switch_cases([{vals, stmts} | rest], s, env, interp) do
    match? =
      case vals do
        :default ->
          true

        list ->
          Enum.any?(list, fn v -> Value.loose_eq(s, Eval.const_eval_quiet(v, env, interp)) end)
      end

    if match? do
      # PHP executes the matched case body then falls through every
      # subsequent body (including a later default) until a break
      bodies = [stmts | Enum.map(rest, fn {_, st} -> st end)]
      run_switch_body(bodies, env, interp)
    else
      exec_switch_cases(rest, s, env, interp)
    end
  end

  defp run_switch_body([], env, interp), do: {:ok, env, interp}

  defp run_switch_body([stmts | rest], env, interp) do
    case exec_stmts(stmts, env, interp) do
      {:ok, env2, interp2} -> run_switch_body(rest, env2, interp2)
      {{:unwind, {:break, 1}}, env2, interp2} -> {:ok, env2, interp2}
      {{:unwind, {:break, n}}, env2, interp2} -> {{:unwind, {:break, n - 1}}, env2, interp2}
      {{:unwind, {:continue, n}}, env2, interp2} -> {{:unwind, {:continue, n}}, env2, interp2}
      unw -> unw
    end
  end

  def exec_stmt({:break, n}, env, interp),
    do: {{:unwind, {:break, level(n)}}, env, interp}

  def exec_stmt({:continue, n}, env, interp),
    do: {{:unwind, {:continue, level(n)}}, env, interp}

  defp level(nil), do: 1
  defp level({:int, n}) when n >= 1, do: n
  defp level(_), do: 1

  def exec_stmt({:return, nil}, _env, interp), do: {{:unwind, {:return, :null}}, nil, interp}

  def exec_stmt({:return, e}, env, interp) do
    case Eval.eval(e, env, interp) do
      {{:val, v}, _e2, i2} -> {{:unwind, {:return, v}}, nil, i2}
      unw -> unw
    end
  end

  def exec_stmt({:global, names}, env, interp) do
    env2 = Enum.reduce(names, env, fn n, acc -> Env.globalize(acc, n) end)
    {:ok, env2, interp}
  end

  def exec_stmt({:static_vars, decls}, env, interp) do
    key = env.statics_key || {:main}

    case Map.fetch(interp.statics, key) do
      :error ->
        {vals, interp2} =
          Enum.reduce(decls, {%{}, interp}, fn {name, init}, {acc, it} ->
            case init do
              nil ->
                {Map.put(acc, name, :null), it}

              e ->
                case Eval.eval(e, env, it) do
                  {{:val, v}, _e2, it2} -> {Map.put(acc, name, v), it2}
                  _ -> {Map.put(acc, name, :null), it}
                end
            end
          end)

        env2 = Enum.reduce(Map.keys(vals), env, &Env.bind_static(&2, &1, key))
        {:ok, env2, put_in(interp2.statics[key], vals)}

      {:ok, vals} ->
        env2 = Enum.reduce(Map.keys(vals), env, &Env.bind_static(&2, &1, key))
        {:ok, env2, interp}
    end
  end

  def exec_stmt({:unset, targets}, env, interp) do
    {env2, interp2} =
      Enum.reduce(targets, {env, interp}, fn t, {e, i} ->
        case Eval.unset_target(t, e, i) do
          {:ok, e2, i2} -> {e2, i2}
          _ -> {e, i}
        end
      end)

    {:ok, env2, interp2}
  end

  def exec_stmt({:try_stmt, body, catches, finally}, env, interp) do
    case exec_stmts(body, env, interp) do
      {:ok, e2, i2} ->
        run_finally(finally, {:ok, e2, i2}, catches, e2, i2)

      {{:unwind, {:php_throw, val}} = uw, e2, i2} ->
        case find_catch(catches, val, e2, i2) do
          {:caught, {res, e3, i3}} ->
            run_finally(finally, {res, e3, i3}, catches, e3, i3)

          :none ->
            case run_finally_raw(finally, e2, i2) do
              {:ok, e3, i3} -> {uw, e3, i3}
              other -> other
            end
        end

      {{:unwind, _} = uw, e2, i2} ->
        case run_finally_raw(finally, e2, i2) do
          {:ok, e3, i3} -> {uw, e3, i3}
          other -> other
        end
    end
  end

  defp run_finally(nil, res, _catches, _e, _i), do: res

  # finally's side effects must flow on: keep its env/interp, keep res's signal
  defp run_finally(finally, res, _catches, e, i) do
    case exec_stmts(finally, e, i) do
      {:ok, e2, i2} ->
        case res do
          {:ok, _, _} -> {:ok, e2, i2}
          {{:unwind, u}, _, _} -> {{:unwind, u}, e2, i2}
          other -> other
        end

      other ->
        other
    end
  end

  defp run_finally_raw(nil, e, i), do: {:ok, e, i}

  defp run_finally_raw(finally, e, i) do
    case exec_stmts(finally, e, i) do
      {:ok, e2, i2} -> {:ok, e2, i2}
      other -> other
    end
  end

  defp find_catch([], _val, _e, _i), do: :none

  defp find_catch([{types, var, body} | rest], val, e, i) do
    if catch_matches?(types, val, e, i) do
      {e2, i2} =
        if var do
          {:ok, e2, i2} = Env.bind_var(e, i, var, val)
          {e2, i2}
        else
          {e, i}
        end

      {:caught, exec_stmts(body, e2, i2)}
    else
      find_catch(rest, val, e, i)
    end
  end

  # a catch matches when the thrown value's class is or extends any listed type
  defp catch_matches?(types, val, _env, interp) do
    thrown_key =
      case val do
        {:object, _} ->
          Eval.get_object(interp, val).class

        {:native_error, class, _msg} ->
          String.downcase(class)

        _ ->
          nil
      end

    if thrown_key == nil do
      false
    else
      Enum.any?(types, fn parts ->
        case Eval.resolve_class_key({:cname, false, parts}, nil, interp) do
          {:ok, tkey} ->
            PhpBeam.Classes.is_a?(interp, thrown_key, tkey)

          _ ->
            false
        end
      end)
    end
  end

  def exec_stmt({:namespace, name, stmts}, env, interp) do
    # use aliases are per-namespace-block
    interp2 = %{interp | ns: name || [], uses: %{normal: %{}, function: %{}, const: %{}}}

    case stmts do
      nil -> {:ok, env, interp2}
      list -> exec_stmts(list, env, interp2)
    end
  end

  def exec_stmt({:use, kind, items, prefix}, env, interp) do
    uses =
      Enum.reduce(items, interp.uses, fn {parts, as}, acc ->
        full = if prefix, do: prefix ++ parts, else: parts
        short = as || List.last(full)
        fq = full |> Enum.join("\\") |> String.downcase()

        kind_map = Map.get(acc, kind, %{})
        Map.put(acc, kind, Map.put(kind_map, String.downcase(short), fq))
      end)

    {:ok, env, %{interp | uses: uses}}
  end

  def exec_stmt({:halt, _}, env, interp), do: {:ok, env, interp}

  def exec_stmt({:class_def, decl}, env, interp) do
    case PhpBeam.Classes.register(decl, interp) do
      {:ok, interp2} -> {:ok, env, interp2}
      {:error, msg} -> {{:unwind, {:fatal, msg}}, env, interp}
    end
  end

  def exec_stmt({:const_decl, entries}, env, interp) do
    consts =
      Enum.reduce(entries, interp.consts, fn {name, expr}, acc ->
        Map.put(acc, name, Eval.const_fold(expr, interp))
      end)

    {:ok, env, %{interp | consts: consts}}
  end

  def exec_stmt({:func_def, name, params, body}, env, interp) do
    if Map.has_key?(interp.functions, name) do
      {:ok, env, warn(interp, "Cannot redeclare function #{name}()")}
    else
      {:ok, env, %{interp | functions: Map.put(interp.functions, name, {:user, params, body})}}
    end
  end

  defp wrap_key(k) when is_integer(k), do: {:int, k}
  defp wrap_key(k) when is_binary(k), do: {:string, k}

  # ───────────────────────── references ─────────────────────────

  def new_ref(v, interp) do
    id = interp.next_ref
    {id, %{interp | refs: Map.put(interp.refs, id, v), next_ref: id + 1}}
  end
end
