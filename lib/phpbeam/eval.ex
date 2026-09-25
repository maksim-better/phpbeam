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
  def assign({:prop, obj_e, name_e}, v, env, interp) do
    {{:val, obj_val}, env2, interp2} = eval(obj_e, env, interp)

    case obj_val do
      {:object, _} = obj_ref ->
        obj = get_object(interp2, obj_ref)
        key = String.downcase(prop_name_string(name_e, env2, interp2))

        declared =
          PhpBeam.Classes.find_prop(interp2, obj.class, key) != nil or
            PArray.has_key?(obj.props, {:string, key})

        readonly? = readonly_prop?(interp2, obj, key)
        initialized = PArray.has_key?(obj.props, {:string, key})

        cond do
          declared and readonly? and initialized ->
            msg =
              "Cannot modify readonly property #{prop_declarer_display(interp2, obj, key)}::$#{key}"

            {obj_ref, i3} = materialize_native({:native_error, "Error", msg}, interp2)
            throw({:readonly_throw, obj_ref, env2, i3})

          declared and readonly? and not readonly_init_scope?(interp2, obj, key, env2) ->
            # php 8.4 wording for out-of-scope INITIALIZATION attempts
            scope =
              case env_scope_class(env2) do
                nil -> "global scope"
                sc -> "scope #{display_class(interp2, sc)}"
              end

            msg =
              "Cannot modify protected(set) readonly property " <>
                "#{prop_declarer_display(interp2, obj, key)}::$#{key} from #{scope}"

            {obj_ref, i3} = materialize_native({:native_error, "Error", msg}, interp2)
            throw({:readonly_throw, obj_ref, env2, i3})

          declared ->
            case PArray.put(obj.props, {:string, key}, v) do
              {:ok, props2} ->
                {env2, put_object(interp2, obj_ref, %{obj | props: props2})}

              {:error, _} ->
                {env2, interp2}
            end

          true ->
            case PhpBeam.Classes.find_method(interp2, obj.class, "__set") do
              nil ->
                case PArray.put(obj.props, {:string, key}, v) do
                  {:ok, props2} -> {env2, put_object(interp2, obj_ref, %{obj | props: props2})}
                  _ -> {env2, interp2}
                end

              m ->
                gkey = {elem(obj_ref, 1), key}

                if MapSet.member?(interp2.set_guards, gkey) do
                  # php: writing the same property inside its own __set does
                  # not re-dispatch — the dynamic property is created directly
                  case PArray.put(obj.props, {:string, key}, v) do
                    {:ok, props2} -> {env2, put_object(interp2, obj_ref, %{obj | props: props2})}
                    _ -> {env2, interp2}
                  end
                else
                  margs = [
                    {:arg, {:lit_val, {:string, key}}, false, nil},
                    {:arg, {:lit_val, v}, false, nil}
                  ]

                  it3 = %{interp2 | set_guards: MapSet.put(interp2.set_guards, gkey)}

                  case call_php_method(obj_ref, m, margs, env2, it3) do
                    {{:val, _}, _, i4} ->
                      {env2, %{i4 | set_guards: MapSet.delete(i4.set_guards, gkey)}}

                    _ ->
                      {env2, interp2}
                  end
                end
            end
        end

      _ ->
        {env2,
         warn(
           env2,
           interp2,
           "Attempt to assign property on value of type #{PhpBeam.Value.gettype(obj_val)}"
         )}
    end
  end

  def assign({:static_prop, cname_e, name_e}, v, env, interp) do
    case class_key_of(cname_e, env, interp) do
      {:ok, key} ->
        name = static_prop_name(name_e, env, interp)

        case PhpBeam.Classes.find_prop(interp, key, name) do
          {:ok, prop} when prop.static? ->
            skey = static_props_key(key)
            statics = Map.get(interp.statics, skey, %{})
            {env, put_in(interp.statics[skey], Map.put(statics, prop.name, v))}

          _ ->
            {env, warn(env, interp, "Access to undeclared static property")}
        end

      {:error, _} ->
        {env, interp}
    end
  end

  # a prop is readonly if its declaration says so OR the whole class is
  # `readonly class` (all instance props become readonly); inherited props
  # consult their DECLARING class
  defp readonly_prop?(interp, obj, key) do
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
  defp readonly_init_scope?(interp, obj, key, env) do
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

  defp env_scope_class(env) do
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

  defp wrap_bare(n) when is_integer(n), do: {:int, n}
  defp wrap_bare(other), do: other

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
  def start_generator(fenv, body, env, interp) do
    me = self()

    pid =
      spawn(fn ->
        receive do
          {:gen_start, driver, ii} ->
            ctx = %{
              driver: driver,
              key: 0,
              file: top_file(ii),
              ns: ii.ns,
              uses: ii.uses
            }

            i0 = %{ii | gen_ctx: ctx}

            case Interp.exec_stmts(body, fenv, i0) do
              {:ok, _, i2} ->
                send(
                  i2.gen_ctx.driver,
                  {:gen_done, :null, strip_gen(strip_def_file(i2, i2.gen_ctx.file))}
                )

              {{:unwind, {:return, v}}, _, i2} ->
                send(
                  i2.gen_ctx.driver,
                  {:gen_done, v, strip_gen(strip_def_file(i2, i2.gen_ctx.file))}
                )

              {{:unwind, u}, _, i2} ->
                send(
                  i2.gen_ctx.driver,
                  {:gen_throw, u, strip_gen(strip_def_file(i2, i2.gen_ctx.file))}
                )
            end
        end
      end)

    {obj_ref, interp2} = make_instance(interp, "generator")
    obj = get_object(interp2, obj_ref)

    st = %{pid: pid, started: false, done: false, k: :null, v: :null, ret: :null}

    props =
      case PArray.put(obj.props, {:string, "gen_state"}, {:gen_state, st}) do
        {:ok, p2} -> p2
        _ -> obj.props
      end

    {{:val, obj_ref}, env, put_object(interp2, obj_ref, %{obj | props: props})}
  end

  @doc """
  Resumes a Generator object. `:start` boots a fresh generator to its first
  yield; `:null` is next(); any other value is send(). Returns
  `{:yielded, k, v, interp}` | `{:done, ret, interp}` | `{:thrown, u, interp}`
  with the latest interpreter state.
  """
  def gen_resume({:object, _} = obj_ref, send_v, interp) do
    obj = get_object(interp, obj_ref)

    case PArray.get(obj.props, {:string, "gen_state"}) do
      {:gen_state, st} ->
        cond do
          st.done ->
            {:done, st.ret, interp}

          st.pid == nil ->
            {:done, :null, interp}

          true ->
            my_ctx = interp.gen_ctx
            my_ns = interp.ns
            my_uses = interp.uses
            # file_stack is per-context like ns/uses: the generator's copy
            # carries its (def-file-stripped) view — keep the driver's own,
            # or every warning/throw after a generator use loses its file
            my_files = interp.file_stack
            ref = :erlang.monitor(:process, st.pid)

            msg =
              case {st.started, send_v} do
                {false, :start} ->
                  {:gen_start, self(), strip_gen(interp)}

                {false, v} ->
                  [
                    {:gen_start, self(), strip_gen(interp)},
                    {:gen_resume, self(), v, strip_gen(interp)}
                  ]

                {true, :start} ->
                  {:gen_resume, self(), :null, strip_gen(interp)}

                {true, v} ->
                  {:gen_resume, self(), v, strip_gen(interp)}
              end

            send_each(st.pid, msg)

            receive do
              {:gen_yield, k, v, i2} ->
                :erlang.demonitor(ref, [:flush])
                i3 = put_gen_state(i2, obj_ref, %{st | started: true, done: false, k: k, v: v})

                {:yielded, k, v,
                 %{i3 | gen_ctx: my_ctx, ns: my_ns, uses: my_uses, file_stack: my_files}}

              {:gen_done, ret, i2} ->
                :erlang.demonitor(ref, [:flush])
                i3 = put_gen_state(i2, obj_ref, %{st | started: true, done: true, ret: ret})

                {:done, ret,
                 %{i3 | gen_ctx: my_ctx, ns: my_ns, uses: my_uses, file_stack: my_files}}

              {:gen_throw, u, i2} ->
                :erlang.demonitor(ref, [:flush])
                i3 = put_gen_state(i2, obj_ref, %{st | started: true, done: true})

                {:thrown, u,
                 %{i3 | gen_ctx: my_ctx, ns: my_ns, uses: my_uses, file_stack: my_files}}

              {:DOWN, _, :process, _, reason} ->
                {:thrown, {:fatal, "generator process died: #{inspect(reason)}"}, interp}
            end
        end
    end
  end

  def gen_resume(_, _, interp), do: {:done, :null, interp}

  defp send_each(pid, msgs) when is_list(msgs), do: Enum.each(msgs, &send(pid, &1))
  defp send_each(pid, msg), do: send(pid, msg)

  defp top_file(%{file_stack: [f | _]}) when is_binary(f), do: f
  defp top_file(_), do: nil

  defp strip_gen(%{gen_ctx: _} = i), do: %{i | gen_ctx: nil}

  defp put_gen_state(interp, {:object, id}, st) do
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
  defp gen_yield(env, interp, k, v, ctx2) do
    ctx = interp.gen_ctx

    case ctx do
      nil ->
        {{:unwind, {:fatal, "Cannot use \"yield\" outside of a generator"}}, env, interp}

      _ ->
        def_file = Map.get(ctx, :file)
        stripped = strip_def_file(interp, def_file)

        send(ctx.driver, {:gen_yield, k, v, %{stripped | gen_ctx: ctx2}})

        receive do
          {:gen_resume, driver2, send_v, i3} ->
            restored =
              case {def_file, i3.file_stack} do
                {f, stack} when is_binary(f) -> %{i3 | file_stack: [f | stack]}
                _ -> i3
              end

            body_scope = %{restored | ns: ctx2.ns, uses: ctx2.uses}
            {{:val, send_v}, env, %{body_scope | gen_ctx: %{ctx2 | driver: driver2}}}
        end
    end
  end

  defp strip_def_file(%{file_stack: [f | rest]} = i, f) when is_binary(f),
    do: %{i | file_stack: rest}

  defp strip_def_file(i, _), do: i

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

  defp class_key_of({:cname, _, _} = cname, env, interp),
    do: resolve_class_key(cname, env, interp)

  defp class_key_of(cls_expr, env, interp), do: resolve_class_key(cls_expr, env, interp)

  defp display_class(interp, key) do
    case PhpBeam.Classes.get_class(interp, key) do
      # messages render anonymous classes short: class@anonymous, without
      # the \0file:line$id suffix get_class() reports
      %{name: n} -> n |> String.split("\0") |> List.first()
      _ -> key |> to_string() |> String.split("\0") |> List.first()
    end
  end

  # readonly/typed-property messages name the DECLARING class (php: an
  # inherited readonly prop reports its declarer, not the instance class)
  defp prop_declarer_display(interp, obj, key) do
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

  def higher_order(name, args, env, interp) do
    cond do
      # sorts + preg $matches writers need raw argument lvalues for writeback;
      # the callback variant needs the callback AST
      name in ~w(usort uasort uksort preg_match preg_match_all preg_replace_callback array_any array_all parse_str) ->
        unwrap_args =
          Enum.map(args, fn
            {:arg, e, _, _} -> e
            {:arg_spread, e, _} -> e
          end)

        dispatch_ho(name, unwrap_args, env, interp)

      name in ~w(call_user_func call_user_func_array array_map array_filter array_reduce array_walk eval func_get_args func_get_arg func_num_args compact extract exit die) ->
        case resolve_args(eval_args(args, env, interp, false)) do
          {:ok, vals, it} -> dispatch_ho(name, vals, env, it || interp)
          {:unwind, u, it} -> {{:unwind, u}, env, it || interp}
        end

      true ->
        :not_mine
    end
  end

  # eval: the string is PHP code WITHOUT tags; executes in the calling
  # scope, `return` yields the value. Warnings inside report the pseudo
  # file `{calling_file}({calling_line}) : eval()'d code` with in-string lines
  defp dispatch_ho("eval", [{:string, code} | _], env, interp) do
    pseudo = eval_file(interp) <> "(#{interp.cur_line}) : eval()'d code"

    with {:ok, toks} <- PhpBeam.Lexer.tokenize("<?php " <> code),
         {:ok, stmts} <- PhpBeam.Parser.parse(toks) do
      i2 = %{interp | file_stack: [pseudo | interp.file_stack]}

      case Interp.exec_stmts(stmts, env, i2) do
        {:ok, e2, i3} ->
          {{:val, :null}, e2, pop_file(i3)}

        {{:unwind, {:return, v}}, _, i3} ->
          {{:val, v}, env, pop_file(i3)}

        {{:unwind, _} = u, e2, i3} ->
          {u, e2, i3}
      end
    else
      {:error, msg, line} ->
        {{:unwind, {:parse_error, msg, pseudo, line}}, env, interp}
    end
  end

  defp dispatch_ho("func_num_args", _vals, env, interp) do
    case fn_context("func_num_args", env, interp) do
      nil -> {{:val, {:int, length(env.args)}}, env, interp}
      err -> err
    end
  end

  defp dispatch_ho("func_get_args", _vals, env, interp) do
    case fn_context("func_get_args", env, interp) do
      nil ->
        arr = PArray.from_pairs(Enum.map(env.args, &{nil, &1}))
        {{:val, {:array, arr}}, env, interp}

      err ->
        err
    end
  end

  defp dispatch_ho("func_get_arg", [{:int, n} | _], env, interp) do
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

  defp dispatch_ho("func_get_arg", _, env, interp), do: {{:val, {:bool, false}}, env, interp}

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

  def eval_file(%{file_stack: [f | _]}), do: f
  def eval_file(_), do: "Command line code"

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

  # user-comparator sorts mutate their array argument (writeback via lvalue)
  # ───────────────────── scope-writing misc ─────────────────────

  # compact("a", ["b", ...]) — reads the CALLING scope; skips undefined vars
  defp dispatch_ho("compact", vals, env, interp) do
    names =
      vals
      |> Enum.flat_map(fn
        {:string, n} -> [n]
        {:array, arr} -> Enum.map(PArray.values(arr), &Value.cast_string_unsafe/1)
        _ -> []
      end)
      |> Enum.uniq()

    pairs =
      for n <- names,
          {:ok, v} <- [Env.lookup(env, interp, n)] do
        {{:string, n}, v}
      end

    {{:val, {:array, PArray.from_pairs(pairs)}}, env, interp}
  end

  # parse_str(qs) → current scope vars; parse_str(qs, $arr) → writes the array
  defp dispatch_ho("parse_str", [q_arg | rest], env, interp) do
    {{:val, qv}, _, i1} = eval(q_arg, env, interp)
    parsed = parse_query(Value.cast_string_unsafe(qv))

    case rest do
      [] ->
        # global scope writes land in interp.globals — thread BOTH returns
        {env2, interp2} =
          Enum.reduce(parsed, {env, i1}, fn {k, v}, {e, it} ->
            {:ok, e2, it2} = Env.bind_var(e, it, k, v)
            {e2, it2}
          end)

        {{:val, :null}, env2, interp2}

      [arr_lval | _] ->
        arr = PArray.from_pairs(Enum.map(parsed, fn {k, v} -> {{:string, k}, v} end))
        {env2, i2} = assign(arr_lval, {:array, arr}, env, i1)
        {{:val, :null}, env2, i2}
    end
  end

  # php nests bracket keys: b[0]=x&c[y]=z
  defp parse_query(q) do
    # duplicate base keys (arr[0]=..&arr[q]=..) merge into ONE tree
    URI.decode_query(q)
    |> Enum.reduce(PArray.new(), fn {k, v}, acc ->
      case Regex.split(~r/\[|\]/, k, trim: true) do
        [base] ->
          {:ok, a2} = PArray.put(acc, {:string, base}, {:string, v})
          a2

        [base | path] ->
          inner =
            case PArray.fetch(acc, {:string, base}) do
              {:ok, {:array, in2}} -> in2
              _ -> PArray.new()
            end

          {:ok, a2} =
            PArray.put(acc, {:string, base}, {:array, put_path(inner, path, {:string, v})})

          a2
      end
    end)
    |> PArray.to_pairs()
    |> Enum.map(fn {k, v} -> {k, v} end)
  end

  defp put_path(arr, [last], v) do
    if last == "" do
      {:ok, a2} = PArray.push(arr, v)
      a2
    else
      case PArray.fetch(arr, {:string, last}) do
        {:ok, {:array, inner}} ->
          {:ok, a2} = PArray.put(arr, {:string, last}, {:array, put_path(inner, [], v)})
          a2

        _ ->
          {:ok, a2} = PArray.put(arr, {:string, last}, v)
          a2
      end
    end
  end

  defp put_path(arr, [head | rest], v) do
    inner =
      case PArray.fetch(arr, {:string, head}) do
        {:ok, {:array, in2}} -> in2
        _ -> PArray.new()
      end

    {:ok, a2} = PArray.put(arr, {:string, head}, {:array, put_path(inner, rest, v)})
    a2
  end

  defp put_path(arr, [], v) do
    {:ok, a2} = PArray.push(arr, v)
    a2
  end

  defp dispatch_ho("extract", vals, env, interp) do
    case Enum.at(vals, 0) do
      {:array, arr} ->
        flags = extract_flags(vals)

        {env2, interp2, count} =
          Enum.reduce(PArray.to_pairs(arr), {env, interp, 0}, fn {k, v}, {e, it, n} ->
            name = if is_binary(k), do: k, else: Integer.to_string(k)

            if String.match?(name, ~r/^[a-zA-Z_]/) do
              skip? =
                (flags == 1 and match?({:ok, _}, Env.lookup(e, interp, name))) or
                  (flags == 6 and match?(:error, map_fetch_env(e, interp, name)))

              if skip? do
                {e, it, n}
              else
                {:ok, e2, it2} = Env.bind_var(e, it, name, v)
                {e2, it2, n + 1}
              end
            else
              {e, it, n}
            end
          end)

        {{:val, {:int, count}}, env2, interp2}

      _ ->
        {{:val, {:int, 0}}, env, interp}
    end
  end

  defp extract_flags(vals) do
    case Enum.at(vals, 1) do
      {:int, f} -> f
      _ -> 0
    end
  end

  defp map_fetch_env(env, interp, name) do
    case Env.lookup(env, interp, name) do
      {:ok, _} -> {:ok, :found}
      _ -> :error
    end
  end

  # exit()/die() invoked as function calls
  defp dispatch_ho("exit", vals, env, interp), do: exit_call(vals, env, interp)
  defp dispatch_ho("die", vals, env, interp), do: exit_call(vals, env, interp)

  defp exit_call(vals, env, interp) do
    case Enum.at(vals, 0) do
      {:int, code} ->
        {{:unwind, {:halt, code}}, env, interp}

      {:string, msg} ->
        interp2 = Interp.write(interp, msg)
        {{:unwind, {:halt, 0}}, env, interp2}

      nil ->
        {{:unwind, {:halt, 0}}, env, interp}

      _ ->
        {{:unwind, {:halt, 0}}, env, interp}
    end
  end

  # php 8.4 array_any/array_all with callback (raw AST)
  defp dispatch_ho("array_any", [arr_arg, cb_arg | _], env, interp) do
    {{:val, {:array, arr}}, _, i1} = eval(arr_arg, env, interp)

    any =
      PArray.values(arr)
      |> Enum.any?(fn v ->
        case call_cb_raw(cb_arg, [v], env, i1) do
          {{:val, r}, _, _} -> Value.truthy?(r)
          _ -> false
        end
      end)

    {{:val, {:bool, any}}, env, i1}
  end

  defp dispatch_ho("array_all", [arr_arg, cb_arg | _], env, interp) do
    {{:val, {:array, arr}}, _, i1} = eval(arr_arg, env, interp)

    all =
      PArray.values(arr)
      |> Enum.all?(fn v ->
        case call_cb_raw(cb_arg, [v], env, i1) do
          {{:val, r}, _, _} -> Value.truthy?(r)
          _ -> false
        end
      end)

    {{:val, {:bool, all}}, env, i1}
  end

  # ───────────────────────── preg family ─────────────────────────

  defp dispatch_ho("preg_match", [pat_arg, subj_arg | rest], env, interp) do
    {{:val, pv}, _, i1} = eval(pat_arg, env, interp)
    {{:val, sv}, _, i2} = eval(subj_arg, env, i1)
    flags = int_arg(rest, 1, env, i2)
    offset = int_arg(rest, 2, env, i2)

    with {:string, p} <- pv,
         {:string, s} <- sv,
         {:ok, %Pattern{} = pat} <- Pattern.parse(p) do
      case Pattern.run_at(pat, s, max(0, offset)) do
        {:ok, pairs, _next} ->
          row = Pattern.row(pairs, pat, s, flags)
          {env2, i3} = assign_matches(rest, 0, {:array, row}, env, i2)
          {{:val, {:int, 1}}, env2, i3}

        _ ->
          {env2, i3} = assign_matches(rest, 0, {:array, PArray.new()}, env, i2)
          {{:val, {:int, 0}}, env2, i3}
      end
    else
      {:error, msg} ->
        i3 = warn(env, i2, "preg_match(): #{msg}")
        {{:val, {:bool, false}}, env, i3}

      _ ->
        {{:val, {:bool, false}}, env, i2}
    end
  end

  defp dispatch_ho("preg_match_all", [pat_arg, subj_arg | rest], env, interp) do
    {{:val, pv}, _, i1} = eval(pat_arg, env, interp)
    {{:val, sv}, _, i2} = eval(subj_arg, env, i1)
    flags = int_arg(rest, 1, env, i2)
    set_order? = Bitwise.band(flags, 2) != 0

    with {:string, p} <- pv,
         {:string, s} <- sv,
         {:ok, %Pattern{} = pat} <- Pattern.parse(p) do
      case Pattern.scan_all(pat, s, 0) do
        {:ok, all} ->
          row_count = length(all)

          arr =
            if set_order? do
              rows = Enum.map(all, &{:array, Pattern.row(&1, pat, s, flags)})
              PArray.from_pairs(Enum.map(rows, &{nil, &1}))
            else
              # PATTERN_ORDER: matches[0] = fulls, [i] = group i-1 per match
              fulls =
                Enum.map(all, fn pairs -> {nil, {:string, Pattern.capture_bin(s, pairs, 0)}} end)

              groups =
                for gi <- 1..pat.ngroups do
                  vals =
                    Enum.map(all, fn pairs ->
                      {cs, cl} = Pattern.span(pairs, gi)

                      if cs >= 0,
                        do: {nil, {:string, binary_part(s, cs, cl)}},
                        else: {nil, {:string, ""}}
                    end)

                  {{:int, gi}, {:array, PArray.from_pairs(vals)}}
                end

              named =
                for {gi, name} <- pat.names do
                  vals =
                    Enum.map(all, fn pairs ->
                      {cs, cl} = Pattern.span(pairs, gi)

                      if cs >= 0,
                        do: {nil, {:string, binary_part(s, cs, cl)}},
                        else: {nil, {:string, ""}}
                    end)

                  {{:string, name}, {:array, PArray.from_pairs(vals)}}
                end

              PArray.from_pairs(
                [{{:int, 0}, {:array, PArray.from_pairs(fulls)}}] ++ groups ++ named
              )
            end

          {env2, i3} = assign_matches(rest, 0, {:array, arr}, env, i2)
          {{:val, {:int, row_count}}, env2, i3}

        _ ->
          {env2, i3} = assign_matches(rest, 0, {:array, PArray.new()}, env, i2)
          {{:val, {:int, 0}}, env2, i3}
      end
    else
      {:error, msg} ->
        i3 = warn(env, i2, "preg_match_all(): #{msg}")
        {{:val, {:bool, false}}, env, i3}

      _ ->
        {{:val, {:bool, false}}, env, i2}
    end
  end

  defp dispatch_ho("preg_replace_callback", [pat_arg, cb_arg, subj_arg | rest], env, interp) do
    {{:val, pv}, _, i1} = eval(pat_arg, env, interp)
    {{:val, sv}, _, i2} = eval(subj_arg, env, i1)
    limit = int_arg(rest, 0, env, i2, -1)

    with {:string, p} <- pv,
         {:string, s} <- sv,
         {:ok, %Pattern{} = pat} <- Pattern.parse(p) do
      {out, _n} =
        cb_replace_loop(s, pat, cb_arg, limit, 0, 0, [], env, i2)

      {{:val, {:string, IO.iodata_to_binary(out)}}, env, i2}
    else
      {:error, msg} ->
        i3 = warn(env, i2, "preg_replace_callback(): #{msg}")
        {{:val, {:bool, false}}, env, i3}

      _ ->
        {{:val, :null}, env, i2}
    end
  end

  defp cb_replace_loop(subject, pat, cb_arg, limit, pos, count, acc, env, interp) do
    if limit >= 0 and count >= limit do
      {Enum.reverse([binary_part(subject, pos, byte_size(subject) - pos) | acc]), count}
    else
      case Pattern.run_at(pat, subject, pos) do
        {:ok, pairs, next} ->
          {s, l} = hd(pairs)
          pre = binary_part(subject, pos, s - pos)
          row = {:array, Pattern.row(pairs, pat, subject, 0)}

          piece =
            case call_cb_raw(cb_arg, [row], env, interp) do
              {{:val, v}, _, _} -> PhpBeam.Value.cast_string_unsafe(v)
              _ -> ""
            end

          cb_replace_loop(
            subject,
            pat,
            cb_arg,
            limit,
            max(next, pos + 1),
            count + 1,
            [piece, pre | acc],
            env,
            interp
          )

        _ ->
          {Enum.reverse([binary_part(subject, pos, byte_size(subject) - pos) | acc]), count}
      end
    end
  end

  # bare-AST arguments (the raw dispatch branch unwraps {:arg, ...}):
  # evaluate non-ref args like PREG_* constants; write $matches via lvalue
  defp int_arg(args, n, env, interp, default \\ 0)

  defp int_arg(args, n, env, interp, default) do
    case Enum.at(args, n) do
      nil ->
        default

      e ->
        case eval(e, env, interp) do
          {{:val, {:int, v}}, _, _} -> v
          _ -> default
        end
    end
  end

  defp assign_matches(args, n, value, env, interp) do
    case Enum.at(args, n) do
      nil -> {env, interp}
      lval -> assign(lval, value, env, interp)
    end
  end

  defp dispatch_ho("usort", [arr_arg, cb_arg | _], env, interp) do
    {{:val, {:array, arr}}, _, i1} = eval(arr_arg, env, interp)

    cmp_val = fn a, b ->
      case call_cb_raw(cb_arg, [a, b], env, i1) do
        {{:val, v}, _, _} -> PhpBeam.Value.compare(v, {:int, 0})
        _ -> 0
      end
    end

    sorted = merge_sort(PArray.values(arr), cmp_val)
    {e2, i2} = assign(arr_arg, {:array, PArray.from_pairs(Enum.map(sorted, &{nil, &1}))}, env, i1)
    {{:val, {:bool, true}}, e2, i2}
  end

  defp dispatch_ho("uasort", [arr_arg, cb_arg | _], env, interp) do
    {{:val, {:array, arr}}, _, i1} = eval(arr_arg, env, interp)

    cmp_val = fn {_ka, a}, {_kb, b} ->
      case call_cb_raw(cb_arg, [a, b], env, i1) do
        {{:val, v}, _, _} -> PhpBeam.Value.compare(v, {:int, 0})
        _ -> 0
      end
    end

    sorted = merge_sort(PArray.to_pairs(arr), cmp_val)

    out =
      Enum.reduce(sorted, PArray.new(), fn {k, v}, acc ->
        {:ok, a2} = PArray.put(acc, wrap_bare(k), v)
        a2
      end)

    {e2, i2} = assign(arr_arg, {:array, out}, env, i1)
    {{:val, {:bool, true}}, e2, i2}
  end

  defp dispatch_ho("uksort", [arr_arg, cb_arg | _], env, interp) do
    {{:val, {:array, arr}}, _, i1} = eval(arr_arg, env, interp)

    cmp_val = fn {ka, _}, {kb, _} ->
      case call_cb_raw(cb_arg, [wrap_bare(ka), wrap_bare(kb)], env, i1) do
        {{:val, v}, _, _} -> PhpBeam.Value.compare(v, {:int, 0})
        _ -> 0
      end
    end

    sorted = merge_sort(PArray.to_pairs(arr), cmp_val)

    out =
      Enum.reduce(sorted, PArray.new(), fn {k, v}, acc ->
        {:ok, a2} = PArray.put(acc, wrap_bare(k), v)
        a2
      end)

    {e2, i2} = assign(arr_arg, {:array, out}, env, i1)
    {{:val, {:bool, true}}, e2, i2}
  end

  defp wrap_bare(k) when is_integer(k), do: {:int, k}
  defp wrap_bare(k) when is_binary(k), do: {:string, k}

  # comparator returns -1|0|1; negative = keep order
  defp merge_sort(list, cmp_val) when length(list) > 1 do
    mid = div(length(list), 2)
    {left, right} = Enum.split(list, mid)
    merge(merge_sort(left, cmp_val), merge_sort(right, cmp_val), cmp_val)
  end

  defp merge_sort([_] = single, _cmp_val), do: single
  defp merge_sort([], _cmp_val), do: []

  defp merge([], right, _cmp), do: right
  defp merge(left, [], _cmp), do: left

  defp merge([a | rest_a], [b | rest_b], cmp) do
    if cmp.(a, b) <= 0 do
      [a | merge(rest_a, [b | rest_b], cmp)]
    else
      [b | merge([a | rest_a], rest_b, cmp)]
    end
  end

  defp dispatch_ho(_, _, env, interp), do: :not_mine

  defp call_cb_raw(cb_ast, call_args, env, interp) do
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

  defp warn(interp, msg), do: PhpBeam.Interp.warn(interp, msg)

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

  defp method_name(%{scope_class: sc, function: f}, interp)
       when is_binary(sc) and is_binary(f),
       do: "#{class_display(sc, interp)}::#{f}"

  defp method_name(%{function: f}, _interp) when is_binary(f), do: f
  defp method_name(_, _interp), do: ""

  defp class_name_of(%{scope_class: sc}, interp) when is_binary(sc),
    do: class_display(sc, interp)

  defp class_name_of(_, _interp), do: ""

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

  def const_eval_quiet(v, _env, _interp), do: eval_const_expr(v)

  defp eval_const_expr({:int, n}), do: {:int, n}
  defp eval_const_expr({:string, s}), do: {:string, s}
  defp eval_const_expr({:bool, b}), do: {:bool, b}
  defp eval_const_expr(:null), do: :null
  defp eval_const_expr(_), do: :null

  # resolve a class-name AST to a storage key (downcased, no leading backslash)
  # class lookup with the registered spl autoloaders run on miss (php
  # triggers them for new/static calls/class_exists-with-autoload). Returns
  # {class_or_nil, interp} — the autoloaders' side effects (require files
  # registering classes) thread back.
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
  def const_fold(ast, interp), do: const_fold(ast, interp, nil)

  # folds in the declaring class's scope so self::CONST resolves; anything
  # that can't fold eagerly (forward refs, function calls) defers to the AST
  def const_fold(ast, interp, scope) do
    env = if scope, do: %Env{scope_class: scope, called_class: scope}, else: nil

    case eval(ast, env, interp) do
      {{:val, :null}, _, _} ->
        case ast do
          :null -> {:ok, :null}
          _ -> :defer
        end

      {{:val, v}, _, _} ->
        {:ok, v}

      _ ->
        :defer
    end
  rescue
    _ -> :defer
  end

  # lazy const-expr evaluation (deferred {:const_ast, ...} markers)
  def const_eval(ast, interp, decl_key) do
    env = %Env{scope_class: decl_key, called_class: decl_key}
    {ns0, uses0, i0} = push_class_scope(interp, decl_key)

    case eval(ast, env, i0) do
      {{:val, v}, _, i2} -> {v, pop_class_scope(i2, ns0, uses0)}
      {{:unwind, _}, _, i2} -> {:null, pop_class_scope(i2, ns0, uses0)}
    end
  end

  # php compiles each class with its declaring file's namespace + use
  # aliases; method/const evaluation runs under that scope
  def push_class_scope(interp, key) do
    case PhpBeam.Classes.get_class(interp, key) do
      %{ns: cns, uses: cuses} when is_list(cns) and is_map(cuses) ->
        {interp.ns, interp.uses, %{interp | ns: cns, uses: cuses}}

      _ ->
        {interp.ns, interp.uses, interp}
    end
  end

  def pop_class_scope(interp, ns0, uses0), do: %{interp | ns: ns0, uses: uses0}

  defp resolve_const(name, _fq, env, interp) do
    case magic_const(name, env, interp) do
      {:ok, _} = ok -> ok
      :error -> resolve_plain_const(name, interp)
    end
  end

  defp resolve_plain_const(name, interp) do
    case Map.fetch(interp.consts, name) do
      {:ok, v} -> {:ok, v}
      :error -> builtin_const(name)
    end
  end

  # magic constants are case-insensitive and resolve per file (include)
  defp magic_const(name, env, interp) do
    current =
      case interp.file_stack do
        [cur | _] -> cur
        [] -> "Command line code"
      end

    case String.upcase(name) do
      "__FILE__" -> {:ok, {:string, current}}
      "__DIR__" -> {:ok, {:string, Path.dirname(current)}}
      "__FUNCTION__" -> {:ok, {:string, env.function || ""}}
      "__METHOD__" -> {:ok, {:string, method_name(env, interp)}}
      "__CLASS__" -> {:ok, {:string, class_name_of(env, interp)}}
      "__NAMESPACE__" -> {:ok, {:string, Enum.join(interp.ns, "\\")}}
      _ -> :error
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

      "PHP_VERSION_ID" ->
        {:ok, {:int, 80_402}}

      "PHP_MAJOR_VERSION" ->
        {:ok, {:int, 8}}

      "PHP_MINOR_VERSION" ->
        {:ok, {:int, 4}}

      "PHP_RELEASE_VERSION" ->
        {:ok, {:int, 2}}

      "PHP_EXTRA_VERSION" ->
        {:ok, {:string, ""}}

      "PHP_ZTS" ->
        {:ok, {:bool, false}}

      "PHP_OS" ->
        {:ok, {:string, "Darwin"}}

      "PHP_FLOAT_DIG" ->
        {:ok, {:int, 15}}

      "PHP_MAXPATHLEN" ->
        {:ok, {:int, 1024}}

      "PHP_BINARY" ->
        {:ok, {:string, "/opt/homebrew/bin/php"}}

      "PHP_OS" ->
        {:ok, {:string, "Darwin"}}

      "PHP_OS_FAMILY" ->
        {:ok, {:string, "Darwin"}}

      "PHP_SAPI" ->
        {:ok, {:string, "cli"}}

      "PHP_DEBUG" ->
        {:ok, {:bool, false}}

      "PHP_WINDOWS_VERSION_MAJOR" ->
        {:ok, {:bool, false}}

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

      "JSON_HEX_AMP" ->
        {:ok, {:int, 2}}

      "JSON_HEX_APOS" ->
        {:ok, {:int, 4}}

      "JSON_HEX_QUOT" ->
        {:ok, {:int, 8}}

      "JSON_FORCE_OBJECT" ->
        {:ok, {:int, 16}}

      "JSON_UNESCAPED_SLASHES" ->
        {:ok, {:int, 64}}

      "JSON_PRETTY_PRINT" ->
        {:ok, {:int, 128}}

      "JSON_UNESCAPED_UNICODE" ->
        {:ok, {:int, 256}}

      "JSON_PARTIAL_OUTPUT_ON_ERROR" ->
        {:ok, {:int, 512}}

      "JSON_INVALID_UTF8_SUBSTITUTE" ->
        {:ok, {:int, 2_097_152}}

      "JSON_THROW_ON_ERROR" ->
        {:ok, {:int, 4_194_304}}

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

      # error-reporting bit mask (PHP 8 values)
      "E_ERROR" ->
        {:ok, {:int, 1}}

      "E_RECOVERABLE_ERROR" ->
        {:ok, {:int, 4096}}

      "E_PARSE" ->
        {:ok, {:int, 4}}

      "E_CORE_ERROR" ->
        {:ok, {:int, 16}}

      "E_CORE_WARNING" ->
        {:ok, {:int, 32}}

      "E_COMPILE_ERROR" ->
        {:ok, {:int, 64}}

      "E_COMPILE_WARNING" ->
        {:ok, {:int, 128}}

      "E_USER_ERROR" ->
        {:ok, {:int, 256}}

      "E_USER_WARNING" ->
        {:ok, {:int, 512}}

      "E_USER_NOTICE" ->
        {:ok, {:int, 1024}}

      "E_USER_DEPRECATED" ->
        {:ok, {:int, 16_384}}

      "E_DEPRECATED" ->
        {:ok, {:int, 8192}}

      "E_STRICT" ->
        {:ok, {:int, 2048}}

      # setlocale categories (darwin C library values)
      "LC_CTYPE" ->
        {:ok, {:int, 0}}

      "LC_NUMERIC" ->
        {:ok, {:int, 1}}

      "LC_TIME" ->
        {:ok, {:int, 2}}

      "LC_COLLATE" ->
        {:ok, {:int, 3}}

      "LC_MONETARY" ->
        {:ok, {:int, 4}}

      "LC_MESSAGES" ->
        {:ok, {:int, 5}}

      "LC_ALL" ->
        {:ok, {:int, 6}}

      "DIRECTORY_SEPARATOR" ->
        {:ok, {:string, "/"}}

      "PATH_SEPARATOR" ->
        {:ok, {:string, ":"}}

      "FILE_APPEND" ->
        {:ok, {:int, 8}}

      "FILE_USE_INCLUDE_PATH" ->
        {:ok, {:int, 1}}

      "LOCK_EX" ->
        {:ok, {:int, 2}}

      "PREG_PATTERN_ORDER" ->
        {:ok, {:int, 1}}

      "PREG_SET_ORDER" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_NO_EMPTY" ->
        {:ok, {:int, 1}}

      "PREG_SPLIT_DELIM_CAPTURE" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_OFFSET_CAPTURE" ->
        {:ok, {:int, 4}}

      "PREG_OFFSET_CAPTURE" ->
        {:ok, {:int, 256}}

      "PREG_UNMATCHED_AS_NULL" ->
        {:ok, {:int, 512}}

      "PREG_GREP_INVERT" ->
        {:ok, {:int, 1}}

      "PREG_NO_ERROR" ->
        {:ok, {:int, 0}}

      "PHP_URL_SCHEME" ->
        {:ok, {:int, 0}}

      "PHP_URL_HOST" ->
        {:ok, {:int, 1}}

      "PHP_URL_PORT" ->
        {:ok, {:int, 2}}

      "PHP_URL_USER" ->
        {:ok, {:int, 3}}

      "PHP_URL_PASS" ->
        {:ok, {:int, 4}}

      "PHP_URL_PATH" ->
        {:ok, {:int, 5}}

      "PHP_URL_QUERY" ->
        {:ok, {:int, 6}}

      "PHP_URL_FRAGMENT" ->
        {:ok, {:int, 7}}

      "PATHINFO_DIRNAME" ->
        {:ok, {:int, 1}}

      "PATHINFO_BASENAME" ->
        {:ok, {:int, 2}}

      "PATHINFO_EXTENSION" ->
        {:ok, {:int, 4}}

      "PATHINFO_FILENAME" ->
        {:ok, {:int, 3}}

      "FILE_IGNORE_NEW_LINES" ->
        {:ok, {:int, 2}}

      "FILE_SKIP_EMPTY_LINES" ->
        {:ok, {:int, 4}}

      "EXTR_OVERWRITE" ->
        {:ok, {:int, 0}}

      "EXTR_SKIP" ->
        {:ok, {:int, 1}}

      "EXTR_PREFIX_SAME" ->
        {:ok, {:int, 2}}

      "EXTR_IF_EXISTS" ->
        {:ok, {:int, 6}}

      "PHP_QUERY_RFC1738" ->
        {:ok, {:int, 1738}}

      "PHP_QUERY_RFC3986" ->
        {:ok, {:int, 3986}}

      "JSON_ERROR_NONE" ->
        {:ok, {:int, 0}}

      "STDIN" ->
        {:ok, {:resource, 0}}

      "STDOUT" ->
        {:ok, {:resource, 1}}

      "STDERR" ->
        {:ok, {:resource, 2}}

      "SEEK_SET" ->
        {:ok, {:int, 0}}

      "SEEK_CUR" ->
        {:ok, {:int, 1}}

      "SEEK_END" ->
        {:ok, {:int, 2}}

      "LOCK_SH" ->
        {:ok, {:int, 1}}

      "LOCK_UN" ->
        {:ok, {:int, 3}}

      "MYSQLI_REPORT_OFF" ->
        {:ok, {:int, 0}}

      "ENT_COMPAT" ->
        {:ok, {:int, 2}}

      "ENT_QUOTES" ->
        {:ok, {:int, 3}}

      "ENT_NOQUOTES" ->
        {:ok, {:int, 0}}

      "ENT_IGNORE" ->
        {:ok, {:int, 4}}

      "ENT_SUBSTITUTE" ->
        {:ok, {:int, 8}}

      "ENT_HTML401" ->
        {:ok, {:int, 0}}

      "ENT_HTML5" ->
        {:ok, {:int, 48}}

      "CASE_UPPER" ->
        {:ok, {:int, 1}}

      "CASE_LOWER" ->
        {:ok, {:int, 0}}

      "MYSQLI_CLIENT_SSL" ->
        {:ok, {:int, 2048}}

      "MYSQLI_CLIENT_COMPRESS" ->
        {:ok, {:int, 32}}

      "MYSQLI_OPT_SSL_VERIFY_SERVER_CERT" ->
        {:ok, {:int, 2048}}

      "MYSQLI_REPORT_ERROR" ->
        {:ok, {:int, 1}}

      "MYSQLI_REPORT_STRICT" ->
        {:ok, {:int, 2}}

      "MYSQLI_REPORT_INDEX" ->
        {:ok, {:int, 4}}

      "MYSQLI_REPORT_ALL" ->
        {:ok, {:int, 255}}

      "MYSQLI_ASSOC" ->
        {:ok, {:int, 1}}

      "MYSQLI_NUM" ->
        {:ok, {:int, 2}}

      "MYSQLI_BOTH" ->
        {:ok, {:int, 3}}

      "MYSQLI_CLIENT_COMPRESS" ->
        {:ok, {:int, 32}}

      "MYSQLI_OPT_INT_AND_FLOAT_NATIVE" ->
        {:ok, {:int, 205}}

      "DATE_W3C" ->
        {:ok, {:string, "Y-m-d\\TH:i:sP"}}

      "DATE_ATOM" ->
        {:ok, {:string, "Y-m-d\\TH:i:sP"}}

      "DATE_ISO8601" ->
        {:ok, {:string, "Y-m-d\\TH:i:sO"}}

      "DATE_RFC2822" ->
        {:ok, {:string, "D, d M Y H:i:s O"}}

      "PREG_PATTERN_ORDER" ->
        {:ok, {:int, 1}}

      "PREG_SET_ORDER" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_NO_EMPTY" ->
        {:ok, {:int, 1}}

      "PREG_SPLIT_DELIM_CAPTURE" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_OFFSET_CAPTURE" ->
        {:ok, {:int, 4}}

      "PREG_OFFSET_CAPTURE" ->
        {:ok, {:int, 256}}

      "PREG_UNMATCHED_AS_NULL" ->
        {:ok, {:int, 512}}

      "PREG_GREP_INVERT" ->
        {:ok, {:int, 1}}

      "PREG_NO_ERROR" ->
        {:ok, {:int, 0}}

      _ ->
        :error
    end
  end

  def warn(env, interp, msg) do
    # warnings are interpreter state now (they write to stdout/ob buffers);
    # env is accepted for call-site uniformity
    _ = env
    Interp.warn(interp, msg)
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

  # nested writes into member containers: $this->arr[$k] = v / self::$a[] = v
  # $GLOBALS['k'] = v writes the real global slot; nested writes
  # ($GLOBALS['a']['b'] = v) flow through the generic path, whose write-back
  # lands here too
  def assign({:index, {:var, "GLOBALS"}, idx}, v, env, interp) when idx != nil do
    {{:val, key}, env2, interp2} = eval(idx, env, interp)

    case deref(key, interp2) do
      {:string, k} ->
        {env2, %{interp2 | globals: Map.put(interp2.globals, k, v)}}

      {:int, n} ->
        {env2, %{interp2 | globals: Map.put(interp2.globals, Integer.to_string(n), v)}}

      _ ->
        {env2, interp2}
    end
  end

  def assign({:index, {:prop, _, _} = prop_t, idx}, v, env, interp) do
    nested_member_write(prop_t, idx, v, env, interp)
  end

  def assign({:index, {:static_prop, _, _} = prop_t, idx}, v, env, interp) do
    nested_member_write(prop_t, idx, v, env, interp)
  end

  # deeper chains rooted at a property ($obj->p[$i][$j] = v): lvalue_path
  # can't build a var path for these, so mutate level by level and write back
  def assign({:index, container, idx}, v, env, interp) when elem(container, 0) == :index do
    if prop_rooted?(container) do
      nested_member_write(container, idx, v, env, interp)
    else
      generic_index_assign(container, idx, v, env, interp)
    end
  end

  defp prop_rooted?({:index, inner, _}), do: prop_rooted?(inner)
  defp prop_rooted?({:prop, _, _}), do: true
  defp prop_rooted?({:static_prop, _, _}), do: true
  defp prop_rooted?(_), do: false

  def assign({:index, container, idx}, v, env, interp) do
    generic_index_assign(container, idx, v, env, interp)
  end

  defp generic_index_assign(container, idx, v, env, interp) do
    {path, env2, interp2} = build_path(container, env, interp)

    case idx do
      nil ->
        path_append(path, v, env2, interp2)

      idx_expr ->
        {{:val, key}, env3, interp3} = eval(idx_expr, env2, interp2)
        path_set(path, deref(key, interp3), v, env3, interp3)
    end
  end

  defp nested_member_write({:index, inner, idx}, v, env, interp) do
    {{:val, container}, e2, i2} = quiet_read(inner, env, interp)
    container2 = mutate_member(container, idx, v, e2, i2)
    assign(inner, container2, e2, i2)
  end

  defp nested_member_write(prop_t, idx, v, env, interp) do
    {{:val, container}, e2, i2} = quiet_read(prop_t, env, interp)
    container2 = mutate_member(container, idx, v, e2, i2)
    assign(prop_t, container2, e2, i2)
  end

  # write-context reads autovivify silently: php does not warn for missing
  # array keys / properties along `$a->p[$missing] = v` paths (undefined
  # VARIABLES along the path still warn, so those keep normal eval)
  defp quiet_read({:index, cont, idx}, env, interp) do
    {{:val, c}, e2, i2} = quiet_read(cont, env, interp)

    case idx do
      nil ->
        {{:val, :null}, e2, i2}

      _ ->
        {{:val, k}, e3, i3} = eval(idx, e2, i2)

        case c do
          {:array, arr} -> {{:val, PArray.get(arr, deref(k, i3), :null)}, e3, i3}
          _ -> {{:val, :null}, e3, i3}
        end
    end
  end

  defp quiet_read({:prop, obj_e, name_e} = ast, env, interp) do
    {{:val, ov}, e2, i2} = eval(obj_e, env, interp)

    case ov do
      {:object, _} = obj_ref ->
        obj = get_object(i2, obj_ref)
        key = String.downcase(prop_name_string(name_e, e2, i2))

        case PArray.fetch(obj.props, {:string, key}) do
          {:ok, v} -> {{:val, deref(v, i2)}, e2, i2}
          _ -> {{:val, :null}, e2, i2}
        end

      _ ->
        eval(ast, env, interp)
    end
  end

  defp quiet_read(other, env, interp), do: eval(other, env, interp)

  defp mutate_member(container, idx, v, e2, i2) do
    case container do
      {:array, arr} ->
        case idx do
          nil ->
            {:array, PArray.push(arr, v)}

          _ ->
            {{:val, key}, _, _} = eval(idx, e2, i2)

            case PArray.put(arr, deref(key, i2), v) do
              {:ok, a2} -> {:array, a2}
              _ -> container
            end
        end

      :null ->
        case idx do
          nil ->
            {:array, PArray.from_pairs([{nil, v}])}

          _ ->
            {{:val, key}, _, _} = eval(idx, e2, i2)
            {:array, PArray.from_pairs([{key, v}])}
        end

      _ ->
        container
    end
  end

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

    {new_container, interp2b} =
      case container do
        {:array, arr} ->
          case put_ref_aware(arr, key, v, interp2) do
            {:ok, arr2, interp2c} -> {{:array, arr2}, interp2c}
            {:error, msg} -> throw_set_error(msg, env2, interp2)
          end

        :null ->
          {{:array, PArray.from_pairs([{key, v}])}, interp2}

        {:string, s} ->
          {string_offset_write(s, key, v, env2, interp2), interp2}

        _ ->
          i_w = warn(env2, interp2, "Cannot use a scalar value as an array")
          {container, i_w}
      end

    path_put(path, new_container, env2, interp2b)
  end

  # php: writing to an array element that IS a reference writes the cell
  defp put_ref_aware(arr, k, v, interp) do
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

  # read the value AT the full path (walking index segments; dynamic keys
  # evaluate with the live env — `$d[$k]["n"]` writes used to no-op on
  # non-literal keys)
  defp path_get([{:var, name} | rest], env, interp) do
    base =
      case Env.lookup(env, interp, name) do
        {:ok, v} -> deref_container(v, interp)
        {:static, key, sname} -> Map.get(interp.statics[key] || %{}, sname, :null)
        :undefined -> :null
      end

    walk_path_get(base, rest, env, interp)
  end

  defp path_get([], _env, interp), do: {:null, nil, interp}

  defp walk_path_get(base, [], env, interp), do: {base, env, interp}

  defp walk_path_get(base, [{:index_expr, e} | rest], env, interp) do
    {{:val, k}, env2, interp2} = eval(e, env, interp)
    walk_path_get(read_index_raw(base, deref(k, interp2)), rest, env2, interp2)
  end

  defp deref_container({:ref, id}, interp), do: Map.get(interp.refs, id, :null)
  defp deref_container(v, _), do: v

  # empty path (unsupported lvalue root): php would fatal; keep state safe
  defp path_put([], _v, env, interp), do: {env, interp}

  defp path_put([{:var, name}], v, env, interp), do: assign({:var, name}, v, env, interp)

  defp path_put([{:var, name} | rest], v, env, interp) do
    base =
      case Env.lookup(env, interp, name) do
        {:ok, bv} -> deref_container(bv, interp)
        {:static, key, sname} -> Map.get(interp.statics[key] || %{}, sname, :null)
        :undefined -> :null
      end

    {updated, env2, interp2} = update_path_env(base, rest, v, env, interp)
    assign({:var, name}, updated, env2, interp2)
  end

  defp update_path_env(base, [], v, _env, _interp), do: {v, nil, nil}

  defp update_path_env(base, [{:index_expr, e} | rest], v, env, interp) do
    {{:val, k}, env2, interp2} = eval(e, env, interp)
    k2 = deref(k, interp2 || interp)
    inner = read_index_raw(base, k2)
    {inner2, env3, interp3} = update_path_env(inner, rest, v, env2, interp2)
    e3 = env3 || env2
    i3 = interp3 || interp2

    {new_base, i3b} =
      case base do
        {:array, arr} ->
          case put_ref_aware(arr, k2, inner2, i3) do
            {:ok, arr2, i3c} -> {{:array, arr2}, i3c}
            _ -> {base, i3}
          end

        _ ->
          # php autovivifies: $x[k][k2] on null/scalar becomes an array
          case PArray.put(PArray.new(), k2, inner2) do
            {:ok, arr2} -> {{:array, arr2}, i3}
            _ -> {base, i3}
          end
      end

    {new_base, e3, i3b}
  end

  # write into a specific key of the path root (foreach by-ref);
  # keys arriving bare (int/binary from to_pairs) get wrapped
  def path_write(path, key, v, env, interp) when is_binary(key) do
    path_write(path, {:string, key}, v, env, interp)
  end

  def path_write(path, key, v, env, interp) when is_integer(key) do
    path_write(path, {:int, key}, v, env, interp)
  end

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

  # isset without warnings (env may be nil on unwind paths)
  def isset?(_target, nil, interp), do: {false, nil, interp}

  def isset?(target, env, interp) do
    case target do
      {:var, name} when not is_binary(name) ->
        {false, env, interp}

      {:var, name} when is_binary(name) ->
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

      {:prop, obj_e, name_e} ->
        {{:val, ov}, env2, interp2} = eval(obj_e, env, interp)

        case ov do
          {:object, _} = obj_ref ->
            obj = get_object(interp2, obj_ref)
            key = String.downcase(prop_name_string(name_e, env2, interp2))

            case PArray.fetch(obj.props, {:string, key}) do
              {:ok, v} ->
                {v != :null, env2, interp2}

              :error ->
                case PhpBeam.Classes.find_method(interp2, obj.class, "__isset") do
                  nil ->
                    {false, env2, interp2}

                  m ->
                    case call_php_method(
                           obj_ref,
                           m,
                           [{:arg, {:lit_val, {:string, key}}, false, nil}],
                           env2,
                           interp2
                         ) do
                      {{:val, res}, _, i3} -> {PhpBeam.Value.truthy?(res), env2, i3}
                      _ -> {false, env2, interp2}
                    end
                end
            end

          _ ->
            {false, env2, interp2}
        end

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

  def unset_target({:prop, obj_e, name_e}, env, interp) do
    {{:val, obj_val}, env2, interp2} = eval(obj_e, env, interp)

    case obj_val do
      {:object, _} = obj_ref ->
        obj = get_object(interp2, obj_ref)
        key = String.downcase(prop_name_string(name_e, env2, interp2))

        if readonly_prop?(interp2, obj, key) do
          msg =
            "Cannot unset readonly property #{prop_declarer_display(interp2, obj, key)}::$#{key}"

          {oref, i3} = materialize_native({:native_error, "Error", msg}, interp2)
          {{:unwind, {:php_throw, oref}}, env2, i3}
        else
          case PArray.delete(obj.props, {:string, key}) do
            {:ok, props2} -> {:ok, env2, put_object(interp2, obj_ref, %{obj | props: props2})}
            :error -> {:ok, env2, interp2}
          end
        end

      _ ->
        {:ok, env2, interp2}
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

  # ── call machinery lives in PhpBeam.Eval.Call (delegates keep the old surface) ──
  defdelegate align_slots(_p0, _p1, _p2, _p3), to: PhpBeam.Eval.Call

  defdelegate arg_count_error(_p0, _p1, _p2, _p3, _p4, _p5, _p6, _p7, _p8, _p9),
    to: PhpBeam.Eval.Call

  defdelegate arg_values(_p0, _p1, _p2), to: PhpBeam.Eval.Call
  defdelegate bind_params(_p0, _p1, _p2, _p3, _p4, _p5, _p6, _p7), to: PhpBeam.Eval.Call
  defdelegate call_builtin(_p0, _p1, _p2, _p3, _p4), to: PhpBeam.Eval.Call
  defdelegate call_cb(_p0, _p1, _p2, _p3), to: PhpBeam.Eval.Call
  defdelegate call_constructor(_p0, _p1, _p2, _p3), to: PhpBeam.Eval.Call
  defdelegate call_count_method(_p0, _p1), to: PhpBeam.Eval.Call
  defdelegate call_function(_p0, _p1, _p2, _p3, _p4, _p5), to: PhpBeam.Eval.Call
  defdelegate call_generator_fn(_p0, _p1, _p2, _p3, _p4), to: PhpBeam.Eval.Call
  defdelegate call_named(_p0, _p1, _p2, _p3, _p4, _p5), to: PhpBeam.Eval.Call
  defdelegate call_php_method(_p0, _p1, _p2, _p3, _p4), to: PhpBeam.Eval.Call
  defdelegate call_php_method_inner(_p0, _p1, _p2, _p3, _p4), to: PhpBeam.Eval.Call
  defdelegate call_resolved_builtin(_p0, _p1, _p2, _p3, _p4, _p5), to: PhpBeam.Eval.Call
  defdelegate call_resolved_builtin(_p0, _p1, _p2, _p3, _p4, _p5, _p6), to: PhpBeam.Eval.Call
  defdelegate call_value(_p0, _p1, _p2, _p3), to: PhpBeam.Eval.Call
  defdelegate do_bind_params(_p0, _p1, _p2, _p3, _p4, _p5), to: PhpBeam.Eval.Call
  defdelegate do_call(_p0, _p1, _p2, _p3), to: PhpBeam.Eval.Call
  defdelegate eval_args(_p0, _p1, _p2, _p3), to: PhpBeam.Eval.Call
  defdelegate eval_call_args(_p0, _p1, _p2), to: PhpBeam.Eval.Call
  defdelegate invoke_fcc(_p0, _p1, _p2, _p3), to: PhpBeam.Eval.Call
  defdelegate materialize_native(_p0, _p1), to: PhpBeam.Eval.Call
  defdelegate named_arg_throw(_p0, _p1, _p2), to: PhpBeam.Eval.Call
  defdelegate reorder_builtin_args(_p0, _p1), to: PhpBeam.Eval.Call
  defdelegate reorder_named(_p0, _p1), to: PhpBeam.Eval.Call
  defdelegate reorder_named_general(_p0, _p1, _p2), to: PhpBeam.Eval.Call
  defdelegate resolve_args(_p0), to: PhpBeam.Eval.Call
  defdelegate resolve_function(_p0, _p1, _p2), to: PhpBeam.Eval.Call
  defdelegate resolve_named_results(_p0), to: PhpBeam.Eval.Call
  defdelegate wrap_args(_p0), to: PhpBeam.Eval.Call
  defdelegate write_back_ref_args(_p0, _p1, _p2, _p3, _p4), to: PhpBeam.Eval.Call
  defdelegate write_back_refs(_p0, _p1, _p2, _p3, _p4), to: PhpBeam.Eval.Call
end
