defmodule PhpBeam.Eval do
  @moduledoc """
  Expression evaluation, lvalues, and call dispatch.

  `eval/3` returns `{{:val, v} | {:unwind, signal}, env, interp}`.
  """

  alias PhpBeam.{Env, Error, Interp, PArray, Pattern, Value}

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
    if name == "GLOBALS" do
      # $GLOBALS is the global symbol table itself — writes through it must
      # reach the real global slots (php: wp_cache_init assigns
      # $GLOBALS['wp_object_cache'])
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

    case resolve_const(name, fq, env, interp) do
      {:ok, v} -> {{:val, v}, env, interp}
      :error -> {{:unwind, {:fatal, "Undefined constant \"#{name}\""}}, env, interp}
    end
  end

  def eval({:interp, parts}, env, interp) do
    {out, env2, interp2} = interp_parts(parts, env, interp)
    {{:val, {:string, out}}, env2, interp2}
  end

  def eval({:array, entries}, env, interp) do
    case array_pairs(entries, env, interp) do
      {:unwind, u, e2, i2} ->
        {{:unwind, u}, e2, i2}

      {:ok, pairs, env2, interp2} ->
        {{:val, {:array, PArray.from_pairs(Enum.reverse(pairs))}}, env2, interp2}
    end
  end

  # array-literal element/key evaluation must thread unwinds: [g()] where g()
  # throws propagates the exception, not a crash
  defp array_pairs(entries, env, interp) do
    entries
    |> Enum.reduce_while({:ok, [], env, interp}, fn
      nil, {:ok, acc, e, i} ->
        {:cont, {:ok, acc, e, i}}

      {:kv, nil, {:spread_elem, se}, false}, {:ok, ps, e, i} ->
        case eval(se, e, i) do
          {{:val, {:array, arr}}, e2, i2} ->
            # php keeps string keys from a spread, re-keys integers
            # sequentially; acc is reversed, so prepend reversed pairs
            spread =
              arr
              |> PArray.to_pairs()
              |> Enum.map(fn
                {k, v} when is_binary(k) -> {{:string, k}, v}
                {_k, v} -> {nil, v}
              end)
              |> Enum.reverse()

            {:cont, {:ok, spread ++ ps, e2, i2}}

          {{:val, _}, e2, i2} ->
            i3 = warn(e2, i2, "Only arrays and Traversables can be spread")
            {:cont, {:ok, ps, e2, i3}}

          {{:unwind, _} = u, e2, i2} ->
            {:halt, {:unwind, elem(u, 1), e2, i2}}
        end

      {:kv, k, v, by_ref?}, {:ok, ps, e, i} ->
        case array_key(k, e, i) do
          {:unwind, u, e2, i2} ->
            {:halt, {:unwind, u, e2, i2}}

          {:nokey, e2, i2} ->
            array_value(v, nil, by_ref?, ps, e2, i2)

          {:key, kv, e2, i2} ->
            array_value(v, kv, by_ref?, ps, e2, i2)
        end
    end)
  end

  defp array_key(nil, e, i), do: {:nokey, e, i}

  defp array_key(kexpr, e, i) do
    case eval(kexpr, e, i) do
      {{:val, kv}, e2, i2} -> {:key, kv, e2, i2}
      {{:unwind, _} = u, e2, i2} -> {:unwind, elem(u, 1), e2, i2}
    end
  end

  defp array_value(v, kv, by_ref?, ps, e, i) do
    case eval(v, e, i) do
      {{:unwind, _} = u, e3, i3} ->
        {:halt, {:unwind, elem(u, 1), e3, i3}}

      {{:val, vv}, e3, i3} ->
        if by_ref? do
          case vv do
            {:ref, _} ->
              {:cont, {:ok, [{kv, vv} | ps], e3, i3}}

            plain ->
              # the cell must be registered in the INTERP that keeps flowing
              # (elem(0) alone dropped it — the ref later read as NULL)
              {cell, i4} = make_ref_cell(plain, i3)
              {:cont, {:ok, [{kv, cell} | ps], e3, i4}}
          end
        else
          {:cont, {:ok, [{kv, vv} | ps], e3, i3}}
        end
    end
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
    {{:val, obj_val}, env2, interp2} = eval(obj_e, env, interp)

    case obj_val do
      {:object, _} = obj_ref ->
        obj = get_object(interp2, obj_ref)
        key = prop_name_string(name_e, env2, interp2)

        hidden = prop_read_violation(interp2, obj.class, String.downcase(key), env)

        declared_ro_uninit =
          PArray.fetch(obj.props, {:string, String.downcase(key)}) == :error and
            PhpBeam.Classes.find_prop(interp2, obj.class, key) != nil and
            readonly_prop?(interp2, obj, String.downcase(key))

        cond do
          is_binary(hidden) ->
            {{:unwind, {:fatal, hidden}}, env2, interp2}

          declared_ro_uninit ->
            # readonly implies typed; php throws on the uninitialized read
            msg =
              "Typed property #{prop_declarer_display(interp2, obj, key)}::$#{key} must not be accessed before initialization"

            {obj_ref2, i3} = materialize_native({:native_error, "Error", msg}, interp2)
            {{:unwind, {:php_throw, obj_ref2}}, env2, i3}

          true ->
            case {PArray.fetch(obj.props, {:string, String.downcase(key)}),
                  PhpBeam.Classes.find_method(interp2, obj.class, "__get")} do
              {{:ok, v}, _} ->
                {{:val, deref(v, interp2)}, env2, interp2}

              {:error, nil} ->
                interp3 =
                  warn(
                    env2,
                    interp2,
                    "Undefined property: #{display_class(interp2, obj.class)}::$#{key}"
                  )

                {{:val, :null}, env2, interp3}

              {:error, m} ->
                gkey = {elem(obj_ref, 1), String.downcase(key)}

                if MapSet.member?(interp2.get_guards, gkey) do
                  # php re-reading the same property inside its own __get:
                  # no second dispatch — null + undefined-property warning
                  interp3 =
                    warn(
                      env2,
                      interp2,
                      "Undefined property: #{display_class(interp2, obj.class)}::$#{key}"
                    )

                  {{:val, :null}, env2, interp3}
                else
                  it3 = %{interp2 | get_guards: MapSet.put(interp2.get_guards, gkey)}

                  case call_php_method(
                         obj_ref,
                         m,
                         [{:arg, {:lit_val, {:string, key}}, false, nil}],
                         env2,
                         it3
                       ) do
                    {{:val, v}, e3, it4} ->
                      {{:val, v}, e3, %{it4 | get_guards: MapSet.delete(it4.get_guards, gkey)}}

                    {{:unwind, _} = u, e3, it4} ->
                      {u, e3, %{it4 | get_guards: MapSet.delete(it4.get_guards, gkey)}}
                  end
                end
            end
        end

      :null ->
        key = prop_name_string(name_e, env2, interp2)
        {{:val, :null}, env2, warn(env2, interp2, "Attempt to read property \"#{key}\" on null")}

      other ->
        key = prop_name_string(name_e, env2, interp2)

        interp3 =
          warn(
            env2,
            interp2,
            "Attempt to read property \"#{key}\" on value of type #{PhpBeam.Value.gettype(other)}"
          )

        {{:val, :null}, env2, interp3}
    end
  end

  def eval({:nullsafe_prop, obj_e, name_e}, env, interp) do
    case isset?(obj_e, env, interp) do
      {true, env2, interp2} -> eval({:prop, obj_e, name_e}, env2, interp2)
      {false, env2, interp2} -> {{:val, :null}, env2, interp2}
    end
  end

  # property writes flow through the object registry so every holder sees them
  def readonly_prop?(interp, obj, key) do
    case PhpBeam.Classes.get_class(interp, obj.class) do
      %{kind: :class} = c ->
        mods = Map.get(c, :modifiers) || []

        cond do
          "readonly" in mods ->
            true

          true ->
            case PhpBeam.Classes.prop_declarer(interp, obj.class, key) do
              nil ->
                false

              dk ->
                PhpBeam.Classes.get_class(interp, dk).props
                |> Enum.find(&(&1.name == key))
                |> case do
                  %{readonly?: true} -> true
                  _ -> false
                end
            end
        end

      _ ->
        false
    end
  end

  # readonly initialization is legal from the declaring class OR any
  # subclass (php: any method of the hierarchy touching the instance)
  def readonly_init_scope?(interp, obj, key, env) do
    case env_scope_class(env) do
      nil ->
        false

      sc ->
        case PhpBeam.Classes.prop_declarer(interp, obj.class, key) do
          nil -> true
          dk -> dk in PhpBeam.Classes.self_and_ancestors(interp, sc)
        end
    end
  end

  def env_scope_class(env) do
    case env do
      %{scope_class: sc} when is_binary(sc) -> sc
      _ -> nil
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

  def eval({:nullsafe_prop, _, _}, env, interp),
    do: {{:unwind, {:fatal, "property access requires class support (M5)"}}, env, interp}

  def eval({:static_prop, cname_e, name_e}, env, interp) do
    with {:ok, key} <- class_key_of(cname_e, env, interp) do
      if is_nil(PhpBeam.Classes.get_class(interp, key)) do
        {{:unwind, {:fatal, "Class \"#{class_display_string(cname_e, env, interp)}\" not found"}},
         env, interp}
      else
        name = static_prop_name(name_e, env, interp)

        case PhpBeam.Classes.find_prop(interp, key, name) do
          {:ok, prop} when prop.static? ->
            case static_prop_violation(interp, key, prop, env) do
              nil ->
                statics = Map.get(interp.statics, static_props_key(key), %{})
                {{:val, Map.get(statics, prop.name, prop.default)}, env, interp}

              msg ->
                {{:unwind, {:fatal, msg}}, env, interp}
            end

          _ ->
            {{:unwind,
              {:fatal,
               "Access to undeclared static property #{display_class(interp, key)}::$#{name}"}},
             env, interp}
        end
      end
    else
      {:error, msg} -> {{:unwind, {:fatal, msg}}, env, interp}
    end
  end

  # php: reading a private/protected prop from an unrelated scope is a
  # fatal Error; a subclass reading the parent's PRIVATE prop is not visible
  # (falls through to Undefined-property semantics on the subclass copy)
  defp prop_read_violation(interp, class_key, key, env) do
    walk_prop_visibility(interp, class_key, key, env)
  end

  defp walk_prop_visibility(_interp, nil, _key, _env), do: nil

  defp walk_prop_visibility(interp, class_key, key, env) do
    class = interp.classes[class_key]

    case class && Enum.find(class.props, &(&1.name == key)) do
      %{visibility: vis} when vis in [:private, :protected] ->
        scope = env && env.scope_class

        cond do
          vis == :private and scope != nil and scope != class_key ->
            # from another class scope, an invisible prop behaves as
            # undeclared (php: Undefined property warning, not a fatal)
            :hidden

          scope == nil ->
            "Cannot access #{vis} property #{display_class(interp, class_key)}::$#{key}"

          true ->
            visible =
              if(vis == :private,
                do: scope == class_key,
                else: scope_in_chain?(interp, scope, class_key)
              )

            if visible,
              do: nil,
              else: "Cannot access #{vis} property #{display_class(interp, class_key)}::$#{key}"
        end

      _ ->
        parent = class && class.parent
        walk_prop_visibility(interp, parent, key, env)
    end
  end

  # php: Call to private/protected method A::f() from global scope / from scope B
  def method_violation(interp, class_key, method, env) do
    vis = method.visibility

    if vis in [:private, :protected] do
      scope = env && env.scope_class

      cond do
        vis == :private and scope != nil and scope != method.class and scope != class_key ->
          "Call to private method #{display_class(interp, method.class || class_key)}::#{method.name}() from scope #{display_class(interp, scope)}"

        scope == nil ->
          "Call to #{vis} method #{display_class(interp, method.class || class_key)}::#{method.name}() from global scope"

        true ->
          # trait-flattened methods carry the trait's key as their class —
          # the USING class's chain also grants access
          visible =
            if vis == :private,
              do: scope in [method.class, class_key],
              else:
                scope_in_chain?(interp, scope, method.class || class_key) or
                  scope_in_chain?(interp, scope, class_key)

          if visible,
            do: nil,
            else:
              "Call to #{vis} method #{display_class(interp, method.class || class_key)}::#{method.name}() from scope #{display_class(interp, scope)}"
      end
    else
      nil
    end
  end

  # static props have no "treat as undeclared" fallback — always a fatal
  defp static_prop_violation(interp, class_key, prop, env) do
    vis = prop.visibility

    if vis in [:private, :protected] do
      scope = env && env.scope_class

      visible? =
        cond do
          scope == nil -> false
          vis == :private -> scope == class_key
          true -> scope_in_chain?(interp, scope, class_key)
        end

      if visible?,
        do: nil,
        else: "Cannot access #{vis} property #{display_class(interp, class_key)}::$#{prop.name}"
    else
      nil
    end
  end

  defp scope_in_chain?(_interp, nil, _target), do: false

  defp scope_in_chain?(interp, key, target) do
    key == target or
      (interp.classes[key] &&
         scope_in_chain?(interp, interp.classes[key].parent, target))
  end

  # the display name keeps the source spelling (keys are lowercased)
  defp class_display_via_resolve({:cname, _, _} = c, env, interp) do
    case resolve_class_display(c, env, interp) do
      disp when is_binary(disp) -> disp
      _ -> class_display_string(c, env, interp)
    end
  end

  defp class_display_via_resolve(e, env, interp), do: class_display_string(e, env, interp)

  defp class_display_string({:cname, _fq, parts}, _env, _interp), do: Enum.join(parts, "\\")

  defp class_display_string(e, env, interp) do
    case eval(e, env, interp) do
      {{:val, {:string, s}}, _, _} -> s
      _ -> ""
    end
  end

  def static_props_key(class_key), do: {:static_props, class_key}

  # `A::$x` uses the literal variable name; only `A::$$x` dereferences
  def static_prop_name({:var, v}, _env, _interp), do: String.downcase(v)
  def static_prop_name({:lit_name, n}, _env, _interp), do: String.downcase(n)

  def static_prop_name(other, env, interp),
    do: String.downcase(prop_name_string(other, env, interp))

  def eval({:class_const, cname_e, "class"}, env, interp) do
    case class_key_of(cname_e, env, interp) do
      {:ok, key} -> {{:val, {:string, display_class(interp, key)}}, env, interp}
      {:error, msg} -> {{:unwind, {:fatal, msg}}, env, interp}
    end
  end

  def eval({:class_const, cname_e, cname}, env, interp) do
    with {:ok, key} <- class_key_of(cname_e, env, interp) do
      {_, interp1} = fetch_class(interp, key, class_display_via_resolve(cname_e, env, interp))

      if is_nil(PhpBeam.Classes.get_class(interp1, key)) do
        class_const_missing(interp1, key, cname, env)
      else
        case PhpBeam.Classes.find_const_lazy(interp1, key, cname) do
          {:ok, v, interp2} ->
            {{:val, v}, env, interp2}

          :error ->
            # unknown constants fall back to global constants
            case Map.fetch(interp1.consts, cname) do
              {:ok, v} ->
                {{:val, v}, env, interp1}

              :error ->
                {{:unwind,
                  {:fatal, "Undefined constant #{display_class(interp1, key)}::#{cname}"}}, env,
                 interp1}
            end

          _ ->
            class_const_missing(interp1, key, cname, env)
        end
      end
    else
      {:error, msg} ->
        {{:unwind, {:fatal, msg}}, env, interp}
    end
  end

  defp class_const_missing(interp, key, cname, env) do
    {{:unwind, {:fatal, "Undefined constant #{display_class(interp, key)}::#{cname}"}}, env,
     interp}
  end

  def eval({:assign, target, rhs}, env, interp) do
    case eval(rhs, env, interp) do
      {{:val, v}, env2, interp2} ->
        try do
          {env3, interp3} = assign(target, v, env2, interp2)
          {{:val, v}, env3, interp3}
        catch
          {:readonly_throw, obj_ref, e3, i3} ->
            {{:unwind, {:php_throw, obj_ref}}, e3, i3}
        end

      unw ->
        unw
    end
  end

  # $b = &$a — both names share one ref cell afterwards
  def eval({:assign_ref, target, rhs}, env, interp) do
    case rhs do
      {:var, rname} ->
        {id, interp2} =
          case Env.lookup(env, interp, rname) do
            {:ok, {:ref, rid}} ->
              {rid, interp}

            {:ok, v} ->
              new_ref(deref(v, interp), interp)

            # taking a reference of a static local: share the static cell
            # (WP does exactly this for $noop_translations in l10n.php)
            {:static, skey, sname} ->
              cur = deref(Map.get(interp.statics[skey] || %{}, sname, :null), interp)
              {rid, i2} = new_ref(cur, interp)
              cell = Map.get(i2.statics, skey, %{})
              i3 = %{i2 | statics: Map.put(i2.statics, skey, Map.put(cell, sname, {:ref, rid}))}
              {rid, i3}

            _ ->
              new_ref(:null, interp)
          end

        {:ok, env2, interp3} = Env.bind_var(env, interp2, rname, {:ref, id})
        {env3, interp4} = assign(target, {:ref, id}, env2, interp3)
        {{:val, deref({:ref, id}, interp4)}, env3, interp4}

      {:index, _, _} = path_expr ->
        # taking a reference of an array element (incl. static-prop and
        # object-prop paths): the element becomes a ref cell, the target
        # binds the same cell (WP: `$collection = &self::$collections[$path]`)
        case eval(path_expr, env, interp) do
          {{:val, cur}, _, _} ->
            {id, interp2} = new_ref(cur, interp)
            {env2, interp3} = assign(path_expr, {:ref, id}, env, interp2)
            {env3, interp4} = assign(target, {:ref, id}, env2, interp3)
            {{:val, deref({:ref, id}, interp4)}, env3, interp4}

          {{:unwind, _} = u, env2, interp2} ->
            {u, env2, interp2}
        end

      {:static_prop, _, _} = spath ->
        case eval(spath, env, interp) do
          {{:val, cur}, _, _} ->
            {id, interp2} = new_ref(cur, interp)
            {env2, interp3} = assign(spath, {:ref, id}, env, interp2)
            {env3, interp4} = assign(target, {:ref, id}, env2, interp3)
            {{:val, deref({:ref, id}, interp4)}, env3, interp4}

          {{:unwind, _} = u, env2, interp2} ->
            {u, env2, interp2}
        end

      {:prop, _, _} = ppath ->
        case eval(ppath, env, interp) do
          {{:val, cur}, _, _} ->
            {id, interp2} = new_ref(cur, interp)
            {env2, interp3} = assign(ppath, {:ref, id}, env, interp2)
            {env3, interp4} = assign(target, {:ref, id}, env2, interp3)
            {{:val, deref({:ref, id}, interp4)}, env3, interp4}

          {{:unwind, _} = u, env2, interp2} ->
            {u, env2, interp2}
        end

      {:new, _, _} ->
        {{:unwind, {:fatal, "cannot take reference of new expression"}}, env, interp}

      _ ->
        {{:unwind, {:fatal, "cannot take reference of this expression"}}, env, interp}
    end
  end

  def eval({:assign_op, op, target, rhs}, env, interp) do
    {cur0, get_env, interp2} = read_target(target, env, interp)
    cur = deref(cur0, interp2)

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

      # some binop arms return the bare tagged value (or a 3-tuple with the
      # threaded interp) — accept all three shapes
      v when is_tuple(v) and tuple_size(v) in [2, 3] and elem(v, 0) != :ok ->
        val =
          case v do
            {_, val} -> val
            {_, val, _} -> val
          end

        i_r =
          case v do
            {_, _, i4} -> i4
            _ -> interp3
          end

        {env3, i5} = assign(target, val, env2, i_r || interp3)
        {{:val, val}, env3, i5}

      {:ok, v} ->
        {env3, interp4} = assign(target, v, env2, interp3)
        {{:val, v}, env3, interp4}
    end
  end

  def eval({:pre_inc, target}, env, interp) do
    {cur0, env2, interp2} = read_target(target, env, interp)
    cur = deref(cur0, interp2)
    v = Value.increment(deref(cur, interp2))
    {env3, interp3} = assign(target, v, env2, interp2)
    {{:val, v}, env3, interp3}
  end

  def eval({:pre_dec, target}, env, interp) do
    {cur0, env2, interp2} = read_target(target, env, interp)
    cur = deref(cur0, interp2)
    v = Value.decrement(deref(cur, interp2))
    {env3, interp3} = assign(target, v, env2, interp2)
    {{:val, v}, env3, interp3}
  end

  def eval({:post_inc, target}, env, interp) do
    {cur0, env2, interp2} = read_target(target, env, interp)
    cur = deref(cur0, interp2)
    v = Value.increment(deref(cur, interp2))
    {env3, interp3} = assign(target, v, env2, interp2)
    {{:val, cur}, env3, interp3}
  end

  def eval({:post_dec, target}, env, interp) do
    {cur0, env2, interp2} = read_target(target, env, interp)
    cur = deref(cur0, interp2)
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

    case kind do
      :int ->
        # lossy float→int casts raise a php 8.1+ deprecation on stdout
        interp3 =
          with {:float, f} <- v,
               true <- trunc(f) != f do
            Interp.warn_level(
              interp2,
              "Deprecated",
              "Implicit conversion from float " <>
                Value.float_to_string(f) <> " to int loses precision"
            )
          else
            _ -> interp2
          end

        out = Value.to_int(v) |> elem(1)
        {{:val, out}, env2, interp3}

      other ->
        out =
          case other do
            :float -> Value.to_float(v) |> elem(1)
            :bool -> {:bool, Value.truthy?(v)}
            :string -> Value.cast_string(v) |> string_of_cast() |> wrap_string()
            :array -> Value.to_array(v)
            :object -> v
          end

        {{:val, out}, env2, interp2}
    end
  end

  def eval({:binop, :&&, l, r}, env, interp) do
    case eval(l, env, interp) do
      {{:val, lv}, env2, interp2} ->
        if Value.truthy?(lv) do
          case eval(r, env2, interp2) do
            {{:val, rv}, env3, interp3} ->
              {{:val, {:bool, Value.truthy?(rv)}}, env3, interp3}

            {{:unwind, _} = u, env3, interp3} ->
              {u, env3, interp3}
          end
        else
          {{:val, {:bool, false}}, env2, interp2}
        end

      {{:unwind, _} = u, env2, interp2} ->
        {u, env2, interp2}
    end
  end

  def eval({:binop, :||, l, r}, env, interp) do
    case eval(l, env, interp) do
      {{:val, lv}, env2, interp2} ->
        if Value.truthy?(lv) do
          {{:val, {:bool, true}}, env2, interp2}
        else
          case eval(r, env2, interp2) do
            {{:val, rv}, env3, interp3} ->
              {{:val, {:bool, Value.truthy?(rv)}}, env3, interp3}

            {{:unwind, _} = u, env3, interp3} ->
              {u, env3, interp3}
          end
        end

      {{:unwind, _} = u, env2, interp2} ->
        {u, env2, interp2}
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

  # instanceof: the RHS is a class reference, not a constant
  def eval({:binop, :instanceof, l, r}, env, interp) do
    {{:val, lv}, env2, interp2} = eval(l, env, interp)

    target =
      case r do
        {:const, parts, fq} ->
          resolve_class_key({:cname, fq, parts}, env2, interp2)

        {:cname, _, _} = c ->
          resolve_class_key(c, env2, interp2)

        _ ->
          case eval(r, env2, interp2) do
            {{:val, {:object, _} = oref}, _, i3} -> {:ok, get_object(i3, oref).class}
            {{:val, {:string, name}}, _, i3} -> {:ok, resolve_class_string(name, i3)}
            _ -> {:error, "invalid instanceof target"}
          end
      end

    case {lv, target} do
      {{:object, _} = obj_ref, {:ok, tkey}} ->
        key = get_object(interp2, obj_ref).class
        {{:val, {:bool, PhpBeam.Classes.is_a?(interp2, key, tkey)}}, env2, interp2}

      {_, _} ->
        {{:val, {:bool, false}}, env2, interp2}
    end
  end

  def eval({:binop, op, l, r}, env, interp) do
    # operands must thread unwinds (a fatal in `$x::$y . "z"` used to badmatch)
    case eval(l, env, interp) do
      {{:val, lv}, env2, interp2} ->
        case eval(r, env2, interp2) do
          {{:val, rv}, env3, interp3} ->
            case apply_binop(op, lv, rv, env3, interp3) do
              {:ok, v} -> {{:val, v}, env3, interp3}
              {:ok, v, interp4} -> {{:val, v}, env3, interp4}
              {:unwind, u, interp4} -> {{:unwind, u}, env3, interp4}
              {:unwind, _} = u -> {u, env3, interp3}
            end

          {{:unwind, _} = u, env3, interp3} ->
            {u, env3, interp3}
        end

      {{:unwind, _} = u, env2, interp2} ->
        {u, env2, interp2}
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
    case eval(c, env, interp) do
      {{:val, cv}, env2, interp2} ->
        if Value.truthy?(cv), do: eval(t, env2, interp2), else: eval(f, env2, interp2)

      {{:unwind, _} = u, env2, interp2} ->
        {u, env2, interp2}
    end
  end

  def eval({:short_ternary, c, f}, env, interp) do
    case eval(c, env, interp) do
      {{:val, cv}, env2, interp2} ->
        if Value.truthy?(cv) do
          {{:val, cv}, env2, interp2}
        else
          eval(f, env2, interp2)
        end

      {{:unwind, _} = u, env2, interp2} ->
        {u, env2, interp2}
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

  # include/require: full-expression language constructs; the included file
  # executes inline so it shares the calling scope (top level → globals)
  def eval({:include, kind, path_e}, env, interp) do
    {{:val, pv}, env2, i2} = eval(path_e, env, interp)
    path = Value.cast_string_unsafe(pv)

    case resolve_include_path(path, i2) do
      nil ->
        missing_include(kind, path, env2, i2)

      resolved ->
        once? = kind in [:include_once, :require_once]

        if once? and Map.has_key?(i2.included, resolved) do
          {{:val, {:bool, true}}, env2, i2}
        else
          case File.read(resolved) do
            {:ok, src} ->
              # the included file may declare a namespace — save/restore it so
              # declarations don't leak into the includer (sodium_compat!)
              ns0 = i2.ns
              uses0 = i2.uses

              i3 = %{
                i2
                | included: Map.put(i2.included, resolved, true),
                  file_stack: [resolved | i2.file_stack],
                  ns: [],
                  uses: %{normal: %{}, function: %{}, const: %{}}
              }

              with {:ok, toks} <- PhpBeam.Lexer.tokenize(src),
                   {:ok, stmts} <- PhpBeam.Parser.parse(toks) do
                case Interp.exec_stmts(stmts, env2, i3) do
                  {:ok, env3, i4} ->
                    {{:val, {:int, 1}}, env3, pop_file(restore_uses(restore_ns(i4, ns0), uses0))}

                  # return unwinds carry a nil env by convention — the
                  # include's value goes back to the caller's live env
                  {{:unwind, {:return, v}}, _env3, i4} ->
                    {{:val, v}, env2, pop_file(restore_uses(restore_ns(i4, ns0), uses0))}

                  {{:unwind, _} = u, env3, i4} ->
                    {u, env3, restore_uses(restore_ns(i4, ns0), uses0)}
                end
              else
                {:error, msg, line} ->
                  {{:unwind, {:fatal, "syntax error, #{msg} in #{resolved} on line #{line}"}},
                   env2, i2}
              end

            {:error, _} ->
              missing_include(kind, path, env2, i2)
          end
        end
    end
  end

  def pop_file(%{file_stack: [_ | rest]} = i), do: %{i | file_stack: rest}

  def pop_file_once(interp), do: pop_file(interp)

  # php: the auto key counter starts at 0; an explicit int key advances it to
  # key+1 (probe-verified: `yield 10 => b; yield c;` gives c the key 11)
  def eval({:yield_bare}, env, interp) do
    i2 = adv_key(interp, nil)
    gen_yield(env, i2, wrap_bare(interp.gen_ctx[:key]), :null, i2.gen_ctx)
  end

  def eval({:yield, e}, env, interp) do
    {{:val, v}, env2, i2} = eval(e, env, interp)
    i3 = adv_key(i2, nil)
    k = wrap_bare(i2.gen_ctx[:key])
    gen_yield(env2, i3, k, v, i3.gen_ctx)
  end

  def eval({:yield_kv, ke, ve}, env, interp) do
    {{:val, k}, env2, i2} = eval(ke, env, interp)
    {{:val, v}, env3, i3} = eval(ve, env2, i2)
    i4 = adv_key(i3, k)
    gen_yield(env3, i4, k, v, i4.gen_ctx)
  end

  # yield from: delegate to an inner generator/iterable, yielding each pair
  def eval({:yield_from, e}, env, interp) do
    {{:val, src}, env2, i2} = eval(e, env, interp)

    case src do
      {:object, _} = obj_ref ->
        obj = get_object(i2, obj_ref)

        if obj.class == "generator" do
          yield_from_gen(obj_ref, env2, i2, :start)
        else
          i3 = adv_key(i2, nil)
          gen_yield(env2, i3, wrap_bare(i2.gen_ctx[:key]), src, i3.gen_ctx)
        end

      {:array, arr} ->
        yield_from_array(PArray.to_pairs(arr), env2, i2)

      _ ->
        {{:unwind, {:fatal, "Can only yield from generators and arrays"}}, env2, i2}
    end
  end

  defp yield_from_array([], env, interp), do: {{:val, :null}, env, interp}

  defp yield_from_array([{k, v} | rest], env, interp) do
    i2 = adv_key(interp, unwrap_key(k))

    case gen_yield(env, i2, wrap_bare(unwrap_key(k)), v, i2.gen_ctx) do
      {{:val, _}, env2, i3} -> yield_from_array(rest, env2, i3)
      other -> other
    end
  end

  defp yield_from_gen(obj_ref, env, interp, first) do
    case gen_resume(obj_ref, first, interp) do
      {:yielded, k, v, i2} ->
        i3 = adv_key(i2, nil)

        case gen_yield(env, i3, k, v, i3.gen_ctx) do
          {{:val, _}, env2, i4} -> yield_from_gen(obj_ref, env2, i4, :null)
          other -> other
        end

      {:done, _ret, i2} ->
        {{:val, :null}, env, i2}

      {:thrown, u, i2} ->
        {{:unwind, u}, env, i2}
    end
  end

  defp auto_key(%{gen_ctx: %{key: n}}), do: n
  defp auto_key(_), do: 0

  defp adv_key(%{gen_ctx: ctx} = i, k) do
    case k do
      {:int, n} -> %{i | gen_ctx: %{ctx | key: n + 1}}
      _ -> %{i | gen_ctx: %{ctx | key: ctx[:key] + 1}}
    end
  end

  defp unwrap_key({:int, n}), do: {:int, n}
  defp unwrap_key({:string, _} = s), do: s
  defp unwrap_key(other), do: other

  defp restore_ns(i, ns), do: %{i | ns: ns}
  defp restore_uses(i, uses), do: %{i | uses: uses}
  def pop_file(i), do: i

  # ───────────────────────── generators (yield) ─────────────────────────
  # A generator body runs in its own BEAM process; the interpreter struct —
  # the shared world (objects, output, statics) — shuttles across on every
  # resume/yield, so side effects stay visible on both sides. The body's
  # suspended Elixir stack (its env + program counter) lives only in that
  # process, which blocks in receive at each yield.

  @doc """
  Creates a Generator object for a (sub)body that contains yield. `fenv`
  already has params bound; nothing executes until the first resume (php
  generators are lazy).
  """
  def put_gen_state(interp, {:object, id}, st) do
    obj = get_object(interp, {:object, id})

    props =
      case PArray.put(obj.props, {:string, "gen_state"}, {:gen_state, st}) do
        {:ok, p2} -> p2
        _ -> obj.props
      end

    put_object(interp, {:object, id}, %{obj | props: props})
  end

  # yield: hand k/v + the latest world to the driver, block until resumed.
  # The resumed interp carries the DRIVER's gen_ctx — restore ours (with the
  # advanced auto-key counter and the new driver pid). The body's defining
  # file (pushed by the factory call) is stripped for the driver and restored
  # on resume, so __DIR__/warning attribution stays correct on both sides.
  def strip_def_file(%{file_stack: [f | rest]} = i, f) when is_binary(f),
    do: %{i | file_stack: rest}

  def strip_def_file(i, _), do: i

  # php order: include_path entries (relative to cwd), then the including
  # file's directory, then cwd
  defp resolve_include_path(path, interp) do
    if Path.type(path) == :absolute do
      if File.exists?(path), do: path
    else
      entries = String.split(Map.get(interp.ini, "include_path", "."), ":", trim: true)

      cands = Enum.map(entries, fn e -> if e == ".", do: path, else: Path.join(e, path) end)

      cands =
        case interp.file_stack do
          [cur | _] -> cands ++ [Path.join(Path.dirname(cur), path)]
          [] -> cands
        end

      case Enum.find(cands, &File.exists?/1) do
        nil -> nil
        found -> real_path(found)
      end
    end
  end

  defp real_path(p) do
    Interp.real_path(p)
  end

  defp missing_include(kind, path, env, interp) do
    ip = Map.get(interp.ini, "include_path", ".")

    if kind in [:require, :require_once] do
      {{:unwind, {:fatal, "Failed opening required '#{path}' (include_path='#{ip}')"}}, env,
       interp}
    else
      i2 = warn(env, interp, "include(#{path}): Failed to open stream: No such file or directory")

      i3 =
        warn(env, i2, "include(): Failed opening '#{path}' for inclusion (include_path='#{ip}')")

      {{:val, {:bool, false}}, env, i3}
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
          {:int, n} ->
            {{:unwind, {:halt, n}}, env2, interp2}

          {:string, s} ->
            {{:unwind, {:halt, 0}}, env2, Interp.write(interp2, s)}

          _ ->
            {{:unwind, {:halt, 0}}, env2, interp2}
        end
    end
  end

  # ── first-class callables ──
  def eval({:value_fcc, {:const, parts, _fq}}, env, interp) do
    # `strlen(...)` — the bare name becomes a string callable, NOT a const eval
    {{:val, {:fcc, {:string, Enum.join(parts, "\\")}}}, env, interp}
  end

  def eval({:value_fcc, e}, env, interp) do
    case eval(e, env, interp) do
      {{:val, v}, e2, i2} -> {{:val, {:fcc, v}}, e2, i2}
      {{:unwind, _} = u, e2, i2} -> {u, e2, i2}
    end
  end

  def eval({:method_fcc, obj_e, name_e}, env, interp) do
    case eval(obj_e, env, interp) do
      {{:val, {:object, _} = obj_ref}, e2, i2} ->
        {{:val, {:method_fcc, obj_ref, prop_name_string(name_e, e2, i2)}}, e2, i2}

      {{:val, _}, e2, i2} ->
        interp3 = warn(e2, i2, "Attempt to read property on value of type null")
        {{:val, :null}, e2, interp3}

      {{:unwind, _} = u, e2, i2} ->
        {u, e2, i2}
    end
  end

  def eval({:static_fcc, cname_e, name_e}, env, interp) do
    with {:ok, key} <- class_key_of(cname_e, env, interp) do
      mname = prop_name_string(name_e, env, interp)

      # php validates at CREATION: `C::m(...)` for a non-static m throws
      # immediately (unless collected from an instance scope, which never
      # reaches here — that form goes through method_fcc)
      case PhpBeam.Classes.find_method(interp, key, mname) do
        %{static?: false} = m ->
          if m.native do
            {{:val, {:static_fcc, key, mname}}, env, interp}
          else
            msg =
              "Non-static method #{display_class(interp, key)}::#{mname}() cannot be called statically"

            {obj_ref, it2} = materialize_native({:native_error, "Error", msg}, interp)
            {{:unwind, {:php_throw, obj_ref}}, env, it2}
          end

        _ ->
          {{:val, {:static_fcc, key, mname}}, env, interp}
      end
    else
      {:error, msg} -> {{:unwind, {:fatal, msg}}, env, interp}
    end
  end

  def eval({:anon_class, decl, args}, env, interp) do
    # php names anonymous classes `Parent@anonymous file:line$id` — the
    # per-site counter makes the name unique across instantiations
    file = eval_file(interp)
    line = interp.cur_line

    {n, interp} =
      Map.get_and_update(interp, :anon_sites, fn sites ->
        nn = Map.get(sites, {file, line}, 0)
        {nn, Map.put(sites, {file, line}, nn + 1)}
      end)

    parent =
      case decl.extends do
        [{parts, _fq} | _] ->
          case resolve_class_key({:cname, false, parts}, env, interp) do
            {:ok, pkey} ->
              case PhpBeam.Classes.get_class(interp, pkey) do
                %{name: pn} -> pn
                _ -> Enum.join(parts, "\\")
              end

            _ ->
              Enum.join(parts, "\\")
          end

        _ ->
          "class"
      end

    name = "#{parent}@anonymous\0#{file}:#{line}$#{n}"
    anon_decl = %{decl | name: name}

    case PhpBeam.Classes.register(anon_decl, interp) do
      {:ok, interp2} ->
        key = PhpBeam.Classes.full_key_of(name, interp2)
        {{:object, _} = obj_ref, interp3} = make_instance(interp2, key)
        call_constructor(obj_ref, args, env, interp3)

      {:error, msg} ->
        {{:unwind, {:engine_fatal, msg}}, env, interp}
    end
  end

  def eval({:new, cls, args}, env, interp) do
    with {:ok, key} <- class_key_of(cls, env, interp) do
      {klass, interp1} = fetch_class(interp, key, class_display_via_resolve(cls, env, interp))

      case klass do
        nil ->
          {{:unwind, {:fatal, "Class \"#{display_class(interp, key)}\" not found"}}, env, interp1}

        class ->
          cond do
            class.abstract? ->
              {{:unwind, {:fatal, "Cannot instantiate abstract class #{class.name}"}}, env,
               interp1}

            class.kind == :interface or class.kind == :trait ->
              {{:unwind, {:fatal, "Cannot instantiate #{class.kind} #{class.name}"}}, env,
               interp1}

            true ->
              {{:object, _} = obj_ref, interp2} = make_instance(interp1, key)
              call_constructor(obj_ref, args, env, interp2)
          end
      end
    else
      {:error, msg} -> {{:unwind, {:fatal, msg}}, env, interp}
    end
  end

  def class_key_of({:cname, _, _} = cname, env, interp),
    do: resolve_class_key(cname, env, interp)

  def class_key_of(cls_expr, env, interp), do: resolve_class_key(cls_expr, env, interp)

  def display_class(interp, key) do
    case PhpBeam.Classes.get_class(interp, key) do
      # messages render anonymous classes short: class@anonymous, without
      # the \0file:line$id suffix get_class() reports
      %{name: n} -> n |> String.split("\0") |> List.first()
      _ -> key |> to_string() |> String.split("\0") |> List.first()
    end
  end

  # readonly/typed-property messages name the DECLARING class (php: an
  # inherited readonly prop reports its declarer, not the instance class)
  def prop_declarer_display(interp, obj, key) do
    case PhpBeam.Classes.prop_declarer(interp, obj.class, key) do
      nil -> display_class(interp, obj.class)
      dk -> display_class(interp, dk)
    end
  end

  # display name + declaring file for a class key (methods declare errors in
  # their defining class's file)
  def decl_site_of(interp, key) do
    case PhpBeam.Classes.get_class(interp, key) do
      %{name: n, file: f} when is_binary(f) and f != "" -> {n, f}
      %{name: n} -> {n, eval_file(interp)}
      _ -> {key, eval_file(interp)}
    end
  end

  # object registry ops live in PhpBeam.Objects (handles + interp.objects);
  # kept as delegates — builtins/render/enums call these through Eval
  defdelegate make_instance(interp, key), to: PhpBeam.Objects
  defdelegate get_object(interp, ref), to: PhpBeam.Objects
  defdelegate put_object(interp, ref, obj_map), to: PhpBeam.Objects
  defdelegate new_stdclass(interp, props), to: PhpBeam.Objects

  def eval({:clone, obj_e}, env, interp) do
    {{:val, obj}, env2, interp2} = eval(obj_e, env, interp)

    case obj do
      {:object, _} ->
        omap = get_object(interp2, obj)
        {{:object, _} = copy_ref, interp3} = make_instance(interp2, omap.class)
        interp4 = put_object(interp3, copy_ref, %{omap | __ref__: elem(copy_ref, 1)})
        {{:val, copy_ref}, env2, interp4}

      other ->
        {{:val, other}, env2, interp2}
    end
  end

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

    captures =
      if env.this != nil or env.called_class != nil do
        Map.put(captures, :__obj_ctx, %{
          this: env.this,
          called_class: env.called_class,
          scope_class: env.scope_class
        })
      else
        captures
      end

    # php names closures `{closure:file:line}` (definition site) in error
    # messages and stack traces — carry the site in the runtime value; a
    # body containing yield makes the closure a generator factory
    gen? = PhpBeam.Ast.has_yield?(body)

    closure =
      PhpBeam.Closure.runtime(
        params,
        body,
        captures,
        arrow?,
        eval_file(interp),
        interp.cur_line,
        gen?
      )

    {{:val, closure}, env2, interp2}
  end

  def eval({:method_call, obj_e, name_e, args, nullsafe?}, env, interp) do
    case eval(obj_e, env, interp) do
      {{:val, obj_ref}, env2, interp2} ->
        method_call_on(obj_ref, name_e, args, nullsafe?, env2, interp2, env)

      {{:unwind, _} = u, env2, interp2} ->
        {u, env2, interp2}
    end
  end

  defp method_call_on(obj_ref, name_e, args, nullsafe?, env2, interp2, _env) do
    case obj_ref do
      :null when nullsafe? ->
        {{:val, :null}, env2, interp2}

      :null ->
        name = prop_name_string(name_e, env2, interp2)
        {{:unwind, {:fatal, "Call to a member function #{name}() on null"}}, env2, interp2}

      {:object, _} ->
        obj = get_object(interp2, obj_ref)
        name = prop_name_string(name_e, env2, interp2)

        case PhpBeam.Classes.find_method(interp2, obj.class, name) do
          nil ->
            magic_call(obj_ref, name, args, env2, interp2)

          method ->
            if method.static? do
              {{:unwind, {:fatal, "Non-static method #{name}() cannot be called statically"}},
               env2, interp2}
            else
              call_php_method(obj_ref, method, args, env2, interp2)
            end
        end

      _ ->
        name = prop_name_string(name_e, env2, interp2)

        interp3 =
          warn(
            env2,
            interp2,
            "Call to a member function #{name}() on value of type #{PhpBeam.Value.gettype(obj_ref)}"
          )

        {{:val, :null}, env2, interp3}
    end
  end

  defp magic_call({:object, _} = obj_ref, name, args, env, interp) do
    obj = get_object(interp, obj_ref)

    case PhpBeam.Classes.find_method(interp, obj.class, "__call") do
      nil ->
        {{:unwind,
          {:fatal, "Call to undefined method #{display_class(interp, obj.class)}::#{name}()"}},
         env, interp}

      m ->
        margs = [
          {:arg, {:lit_val, {:string, name}}, false, nil},
          {:arg,
           {:lit_val,
            {:array,
             PArray.from_pairs(Enum.map(elem(arg_values(args, env, interp), 0), &{nil, &1}))}},
           false, nil}
        ]

        call_php_method(obj_ref, m, margs, env, interp)
    end
  end

  def eval({:static_call, cname_e, name_e, args}, env, interp) do
    name = prop_name_string(name_e, env, interp)

    with {:ok, key} <- class_key_of(cname_e, env, interp) do
      {klass, interp1} = fetch_class(interp, key, class_display_via_resolve(cname_e, env, interp))

      case klass do
        nil ->
          {{:unwind,
            {:fatal, "Class \"#{class_display_string(cname_e, env, interp)}\" not found"}}, env,
           interp1}

        _class ->
          static_call_found(key, name, args, env, interp1)
      end
    else
      {:error, msg} ->
        {{:unwind, {:fatal, msg}}, env, interp}
    end
  end

  defp static_call_found(key, name, args, env, interp) do
    case PhpBeam.Classes.find_method(interp, key, name) do
      nil ->
        magic_static_call(key, name, args, env, interp)

      method ->
        cond do
          method.static? ->
            try do
              call_static_method(key, method, args, env, interp)
            catch
              {:fatal_violation, msg, e, i} -> {{:unwind, {:fatal, msg}}, e, i}
            end

          # parent::method() / self::method() inside an instance method
          env != nil and env.this != nil ->
            call_php_method(env.this, method, args, env, interp)

          true ->
            # php 8 throws a catchable Error (no warning, no call frame)
            msg =
              "Non-static method #{display_class(interp, key)}::#{name}() cannot be called statically"

            {obj_ref, it2} = materialize_native({:native_error, "Error", msg}, interp)
            {{:unwind, {:php_throw, obj_ref}}, env, it2}
        end
    end
  end

  defp magic_static_call(key, name, args, env, interp) do
    case PhpBeam.Classes.find_method(interp, key, "__callstatic") do
      nil ->
        {{:unwind, {:fatal, "Call to undefined method #{display_class(interp, key)}::#{name}()"}},
         env, interp}

      m ->
        margs = [
          {:arg, {:lit_val, {:string, name}}, false, nil},
          {:arg,
           {:lit_val,
            {:array,
             PArray.from_pairs(Enum.map(elem(arg_values(args, env, interp), 0), &{nil, &1}))}},
           false, nil}
        ]

        call_static_method(key, m, margs, env, interp)
    end
  end

  defp call_static_method(key, method, args, env, interp) do
    case method_violation(interp, key, method, env) do
      nil ->
        :ok

      msg ->
        throw({:fatal_violation, msg, env, interp})
    end

    if method.native do
      {:native, native} = method.native
      {vals, interp} = arg_values(args, env, interp)

      case native.(%{__ref__: 0, class: key, props: PArray.new()}, vals, interp) do
        {:ok, {ret, _obj2}, interp2} -> {{:val, ret}, env, interp2}
        {{:unwind, _} = u, _, interp2} -> {u, env, interp2}
        other -> other
      end
    else
      mkey = key <> "::" <> String.downcase(method.name)

      fenv = %Env{
        function: method.name,
        statics_key: mkey,
        this: nil,
        called_class: key,
        scope_class: method.class || key
      }

      ckey = method.class || key
      {defc, cfile} = decl_site_of(interp, ckey)

      case bind_params(
             method.params,
             args,
             fenv,
             env,
             interp,
             "#{defc}::#{method.name}",
             "#{defc}::#{method.name}",
             {cfile, method.line || interp.cur_line}
           ) do
        {:ok, binds, vals, srcs, interp2} ->
          fenv2 =
            Enum.reduce(binds, %{fenv | args: vals}, fn {n, v}, acc ->
              %{acc | vars: Map.put(acc.vars, n, v)}
            end)

          {ns0, uses0, interp2} = push_class_scope(interp2, ckey)

          result =
            if method.gen? do
              {res, env2, interp3} =
                start_generator(fenv2, method.body, env, %{
                  interp2
                  | file_stack: [cfile | interp2.file_stack]
                })

              {res, env2, pop_file(interp3)}
            else
              interp2 = Interp.push_frame(interp2, "#{defc}::#{method.name}", vals)
              # static bodies also evaluate __DIR__ against their defining file
              interp2 = %{interp2 | file_stack: [cfile | interp2.file_stack]}

              {res, _, interp3} = Interp.exec_stmts(method.body, fenv2, interp2)
              {interp4, env_out} = write_back_refs(method.params, srcs, env, fenv2, interp3)

              case res do
                :ok ->
                  {{:val, :null}, env_out, Interp.pop_frame(pop_file_once(interp4))}

                {:unwind, {:return, v}} ->
                  {{:val, v}, env_out, Interp.pop_frame(pop_file_once(interp4))}

                # a throw escaping keeps its frame alive for the uncaught trace
                {:unwind, _} = u ->
                  {{:unwind, elem(u, 1)}, env_out, interp4}
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

  def eval({:call, callee, args}, env, interp), do: do_call(callee, args, env, interp)

  # ───────────────────────── calls ─────────────────────────

  def eval_file(%{file_stack: [f | _]}), do: f
  def eval_file(_), do: "Command line code"

  defp wrap_bare(k) when is_integer(k), do: {:int, k}
  defp wrap_bare(k) when is_binary(k), do: {:string, k}
  defp wrap_bare(other), do: other

  # raw-AST callback gateway for ho builtins (sorts/preg writers)
  def call_cb_raw(cb_ast, call_args, env, interp) do
    case eval(cb_ast, env, interp) do
      {{:val, cb}, e2, i2} -> call_cb(cb, call_args, e2, i2)
      unw -> unw
    end
  end

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
        value_or_throw(Value.divide(l, r), interp)

      :% ->
        interp = lossy_warn(l, interp)
        interp = lossy_warn(r, interp)

        case Value.modulo(l, r) do
          {:ok, v} -> {:ok, v, interp}
          {:error, %Error{} = err} -> value_or_throw({:error, err}, interp)
        end

      :** ->
        value_or_throw(Value.power(l, r), interp)

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
    PhpBeam.Interp.warn_level(
      interp,
      "Deprecated",
      "Implicit conversion from float " <>
        PhpBeam.Value.float_to_string(f) <> " to int loses precision"
    )
  end

  defp lossy_warn(_, interp), do: interp

  defp value_or_throw({:ok, v}, _interp), do: {:ok, v}

  defp value_or_throw({:error, %Error{} = err}, interp) do
    {obj_ref, interp2} =
      materialize_native({:native_error, Error.php_class(err), err.message}, interp)

    {:unwind, {:php_throw, obj_ref}, interp2}
  end

  defp throw_error(%Error{} = err) do
    {:unwind, {:php_throw, {:native_error, Error.php_class(err), err.message}}}
  end

  # materialize native error tuples into real Throwable instances
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

  # {:unwind, u, env, interp} carries the latest state so the exception
  # object survives across statement boundaries
  def concat_to_string(exprs, env, interp) do
    Enum.reduce_while(exprs, {"", env, interp}, fn e, {acc, en, it} ->
      case eval(e, en, it) do
        {{:val, v}, en2, it2} ->
          {s, it3} = warn_to_string(v, en2, it2)
          {:cont, {acc <> s, en2, it3}}

        {{:unwind, u}, en2, it2} ->
          {:halt, {:unwind, u, en2, it2}}
      end
    end)
  end

  # string conversion that emits the Array-to-string warning; objects use __toString
  def warn_to_string(v, env, interp) do
    case v do
      {:object, _} = obj_ref ->
        obj = get_object(interp, obj_ref)

        case PhpBeam.Classes.find_method(interp, obj.class, "__tostring") do
          nil ->
            {obj_str_default(obj), interp}

          m ->
            case call_php_method(obj_ref, m, [], env, interp) do
              {{:val, {:string, sv}}, _, i2} -> {sv, i2}
              {{:val, other}, _, i2} -> {php_to_string(other), i2}
              _ -> {"Object", interp}
            end
        end

      _ ->
        case Value.cast_string(v) do
          {:ok, s} -> {s, interp}
          {:warn_array, _} -> {"Array", warn(interp, "Array to string conversion")}
          _ -> {"", interp}
        end
    end
  end

  defp obj_str_default(_obj), do: "Object"

  def warn(interp, msg), do: PhpBeam.Interp.warn(interp, msg)

  defp interp_parts(parts, env, interp) do
    Enum.reduce(parts, {"", env, interp}, fn part, {acc, en, it} ->
      case part do
        {:text, s} ->
          {acc <> s, en, it}

        # php attributes interpolation warnings to the interpolated
        # variable's own line (heredoc bodies span lines)
        {:line_e, line, ast} ->
          {{:val, v}, en2, it2} = eval(ast, en, %{it | cur_line: line})
          {acc <> php_to_string(v), en2, it2}

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
  defp wrap_string(s) when is_binary(s), do: {:string, s}
  defp wrap_string(v), do: v

  def method_name(%{scope_class: sc, function: f}, interp)
      when is_binary(sc) and is_binary(f),
      do: "#{class_display(sc, interp)}::#{f}"

  def method_name(%{function: f}, _interp) when is_binary(f), do: f
  def method_name(_, _interp), do: ""

  def class_name_of(%{scope_class: sc}, interp) when is_binary(sc),
    do: class_display(sc, interp)

  def class_name_of(_, _interp), do: ""

  defp class_display(key, interp) do
    case PhpBeam.Classes.get_class(interp, key) do
      %{name: n} -> n
      _ -> key
    end
  end

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

  def fetch_class(interp, key, display_name) do
    case PhpBeam.Classes.get_class(interp, key) do
      nil when interp.autoload_fns != [] ->
        # autoloaders resolve GLOBAL names — strip the active namespace, or
        # `Autoload` inside `namespace WpOrg\Requests;` would recurse through
        # fetch_class forever (ns\autoload misses -> autoload -> ...)
        global = %{interp | ns: [], uses: %{normal: %{}, function: %{}, const: %{}}}

        it2 =
          Enum.reduce(interp.autoload_fns, global, fn cb, it ->
            case PhpBeam.Classes.get_class(it, key) do
              nil ->
                case call_cb(deref(cb, it), [{:string, display_name}], nil_env(), it) do
                  {{:val, _}, _, it2} -> it2
                  {{:unwind, _}, _, it2} -> it2
                end

              _ ->
                it
            end
          end)

        # the autoloaders ran under a ns/uses-stripped interp; restore the
        # CALLER's scope — classes/side effects they registered persist
        {PhpBeam.Classes.get_class(it2, key), %{it2 | ns: interp.ns, uses: interp.uses}}

      other ->
        {other, interp}
    end
  end

  defp nil_env(), do: %Env{}

  # same resolution as resolve_class_key but PRESERVES case — php hands
  # autoloaders the fully-qualified name (aliases applied), and PSR-4
  # autoloaders build file paths from it
  def resolve_class_display({:cname, fq, parts}, env, interp) do
    first = hd(parts)
    rest = tl(parts)

    cond do
      fq == true ->
        Enum.join(parts, "\\")

      first == "self" and env != nil and env.scope_class ->
        env.scope_class

      first == "static" and env != nil ->
        env.called_class || env.scope_class

      first == "parent" and env != nil and env.scope_class ->
        parent_key(interp, env.scope_class) || Enum.join(parts, "\\")

      alias_key = Map.get(interp.uses.normal, String.downcase(first)) ->
        Enum.join([alias_key | rest], "\\")

      interp.ns != [] and rest == [] ->
        Enum.join(interp.ns ++ parts, "\\")

      true ->
        Enum.join(parts, "\\")
    end
  end

  def resolve_class_key({:cname, fq, parts}, env, interp) do
    first = hd(parts)
    rest = tl(parts)

    key =
      cond do
        fq == true ->
          Enum.join(parts, "\\")

        first == "self" and env != nil and env.scope_class ->
          join_maybe(env.scope_class, rest)

        first == "static" and env != nil ->
          join_maybe(env.called_class || env.scope_class, rest)

        first == "parent" and env != nil and env.scope_class ->
          parent = parent_key(interp, env.scope_class)
          if parent, do: join_maybe(parent, rest), else: Enum.join(parts, "\\")

        alias_key = Map.get(interp.uses.normal, String.downcase(first)) ->
          Enum.join([alias_key | rest], "\\")

        interp.ns != [] and rest == [] ->
          Enum.join(interp.ns ++ parts, "\\")

        true ->
          Enum.join(parts, "\\")
      end

    {:ok, String.downcase(key)}
  end

  def resolve_class_key(cname_expr, env, interp) when is_tuple(cname_expr) do
    case eval(cname_expr, env, interp) do
      {{:val, {:string, name}}, _e, i} ->
        {:ok, resolve_class_string(name, i)}

      _ ->
        {:error, "class name must be a string"}
    end
  end

  def resolve_class_string(name, interp) do
    name = String.trim_leading(name, "\\")
    down = String.downcase(name)

    cond do
      Map.has_key?(interp.classes, down) ->
        down

      interp.ns != [] ->
        ns_key = (interp.ns ++ [name]) |> Enum.join("\\") |> String.downcase()
        if Map.has_key?(interp.classes, ns_key), do: ns_key, else: down

      true ->
        down
    end
  end

  defp join_maybe(prefix, rest), do: Enum.join([prefix | rest], "\\")

  defp parent_key(interp, key) do
    case PhpBeam.Classes.get_class(interp, key) do
      %{parent: p} when is_binary(p) -> p
      _ -> nil
    end
  end

  # constant folding for class constants / property defaults / enum cases
  def push_class_scope(interp, key) do
    case PhpBeam.Classes.get_class(interp, key) do
      %{ns: cns, uses: cuses} when is_list(cns) and is_map(cuses) ->
        {interp.ns, interp.uses, %{interp | ns: cns, uses: cuses}}

      _ ->
        {interp.ns, interp.uses, interp}
    end
  end

  def pop_class_scope(interp, ns0, uses0), do: %{interp | ns: ns0, uses: uses0}

  def warn(env, interp, msg) do
    # warnings are interpreter state now (they write to stdout/ob buffers);
    # env is accepted for call-site uniformity
    _ = env
    Interp.warn(interp, msg)
  end

  # ───────────────────────── lvalues ─────────────────────────

  def put_ref_aware(arr, k, v, interp) do
    case PArray.fetch(arr, k) do
      {:ok, {:ref, id}} ->
        {:ok, arr, %{interp | refs: Map.put(interp.refs, id, v)}}

      _ ->
        case PArray.put(arr, k, v) do
          {:ok, arr2} -> {:ok, arr2, interp}
          e -> e
        end
    end
  end

  def throw_set_error(msg, _env, _interp), do: throw({:set_error, msg})

  # ── facade: submodules own the machinery, Eval keeps the public surface ──
  defdelegate do_call(a, b, c, d), to: PhpBeam.Eval.Call
  defdelegate call_named(a, b, c, d, e, f), to: PhpBeam.Eval.Call
  defdelegate call_generator_fn(a, b, c, d, e), to: PhpBeam.Eval.Call
  defdelegate call_value(a, b, c, d), to: PhpBeam.Eval.Call
  defdelegate call_cb(a, b, c, d), to: PhpBeam.Eval.Call
  defdelegate call_count_method(a, b), to: PhpBeam.Eval.Call
  defdelegate call_php_method(a, b, c, d, e), to: PhpBeam.Eval.Call
  defdelegate call_constructor(a, b, c, d), to: PhpBeam.Eval.Call
  defdelegate call_function(a, b, c, d, e, f), to: PhpBeam.Eval.Call
  defdelegate call_builtin(a, b, c, d, e), to: PhpBeam.Eval.Call
  defdelegate call_resolved_builtin(a, b, c, d, e, f, g), to: PhpBeam.Eval.Call
  defdelegate bind_params(a, b, c, d, e, f, g, h), to: PhpBeam.Eval.Call
  defdelegate do_bind_params(a, b, c, d, e, f), to: PhpBeam.Eval.Call
  defdelegate reorder_named(a, b), to: PhpBeam.Eval.Call
  defdelegate reorder_named_general(a, b, c), to: PhpBeam.Eval.Call
  defdelegate align_slots(a, b, c, d), to: PhpBeam.Eval.Call
  defdelegate named_arg_throw(a, b, c), to: PhpBeam.Eval.Call
  defdelegate eval_call_args(a, b, c), to: PhpBeam.Eval.Call
  defdelegate resolve_named_results(a), to: PhpBeam.Eval.Call
  defdelegate reorder_builtin_args(a, b), to: PhpBeam.Eval.Call
  defdelegate arg_count_error(a, b, c, d, e, f, g, h, n0, n1), to: PhpBeam.Eval.Call
  defdelegate resolve_args(a), to: PhpBeam.Eval.Call
  defdelegate eval_args(a, b, c, d), to: PhpBeam.Eval.Call
  defdelegate resolve_function(a, b, c), to: PhpBeam.Eval.Call
  defdelegate materialize_native(a, b), to: PhpBeam.Eval.Call
  defdelegate wrap_args(a), to: PhpBeam.Eval.Call
  defdelegate arg_values(a, b, c), to: PhpBeam.Eval.Call
  defdelegate call_php_method_inner(a, b, c, d, e), to: PhpBeam.Eval.Call
  defdelegate invoke_fcc(a, b, c, d), to: PhpBeam.Eval.Call
  defdelegate write_back_refs(a, b, c, d, e), to: PhpBeam.Eval.Call
  defdelegate write_back_ref_args(a, b, c, d, e), to: PhpBeam.Eval.Call
  defdelegate assign(a, b, c, d), to: PhpBeam.Eval.Assign
  defdelegate read_target(a, b, c), to: PhpBeam.Eval.Assign
  defdelegate prop_rooted?(a), to: PhpBeam.Eval.Assign
  defdelegate generic_index_assign(a, b, c, d, e), to: PhpBeam.Eval.Assign
  defdelegate nested_member_write(a, b, c, d), to: PhpBeam.Eval.Assign
  defdelegate nested_member_write(a, b, c, d, e), to: PhpBeam.Eval.Assign
  defdelegate quiet_read(a, b, c), to: PhpBeam.Eval.Assign
  defdelegate mutate_member(a, b, c, d, e), to: PhpBeam.Eval.Assign
  defdelegate build_path(a, b, c), to: PhpBeam.Eval.Assign
  defdelegate lvalue_path(a, b), to: PhpBeam.Eval.Assign
  defdelegate update_path_env(a, b, c, d, e), to: PhpBeam.Eval.Assign
  defdelegate path_write(a, b, c, d, e), to: PhpBeam.Eval.Assign
  defdelegate split_path(a), to: PhpBeam.Eval.Assign
  defdelegate index_read(a, b, c, d), to: PhpBeam.Eval.Assign
  defdelegate read_index_raw(a, b), to: PhpBeam.Eval.Assign
  defdelegate plain_key(a), to: PhpBeam.Eval.Assign
  defdelegate isset?(a, b, c), to: PhpBeam.Eval.Assign
  defdelegate unset_target(a, b, c), to: PhpBeam.Eval.Assign
  defdelegate destructure(a, b, c, d), to: PhpBeam.Eval.Assign
  defdelegate deref_container(a, b), to: PhpBeam.Eval.Assign
  defdelegate path_put(a, b, c, d), to: PhpBeam.Eval.Assign
  defdelegate string_offset_isset?(a, b, c, d), to: PhpBeam.Eval.Assign
  defdelegate path_get(a, b, c), to: PhpBeam.Eval.Assign
  defdelegate walk_path_get(a, b, c, d), to: PhpBeam.Eval.Assign
  defdelegate path_append(a, b, c, d), to: PhpBeam.Eval.Assign
  defdelegate path_set(a, b, c, d, e), to: PhpBeam.Eval.Assign
  defdelegate first_byte_str(a), to: PhpBeam.Eval.Assign
  defdelegate string_offset_write(a, b, c, d, e), to: PhpBeam.Eval.Assign
  defdelegate offset_index(a), to: PhpBeam.Eval.Assign
  defdelegate start_generator(a, b, c, d), to: PhpBeam.Eval.Generator
  defdelegate gen_resume(a, b, c), to: PhpBeam.Eval.Generator
  defdelegate send_each(a, b), to: PhpBeam.Eval.Generator
  defdelegate top_file(a), to: PhpBeam.Eval.Generator
  defdelegate strip_gen(a), to: PhpBeam.Eval.Generator
  defdelegate gen_yield(a, b, c, d, e), to: PhpBeam.Eval.Generator
  defdelegate const_eval_quiet(a, b, c), to: PhpBeam.Eval.ConstEval
  defdelegate eval_const_expr(a), to: PhpBeam.Eval.ConstEval
  defdelegate const_fold(a, b), to: PhpBeam.Eval.ConstEval
  defdelegate const_fold(a, b, c), to: PhpBeam.Eval.ConstEval
  defdelegate const_eval(a, b, c), to: PhpBeam.Eval.ConstEval
  defdelegate resolve_const(a, b, c, d), to: PhpBeam.Eval.ConstEval
  defdelegate resolve_plain_const(a, b), to: PhpBeam.Eval.ConstEval
  defdelegate magic_const(a, b, c), to: PhpBeam.Eval.ConstEval
  defdelegate builtin_const(a), to: PhpBeam.Eval.ConstEval
  defdelegate make_instance(interp, key), to: PhpBeam.Objects
  defdelegate get_object(interp, ref), to: PhpBeam.Objects
  defdelegate put_object(interp, ref, obj_map), to: PhpBeam.Objects
  defdelegate new_stdclass(interp, props), to: PhpBeam.Objects
end
