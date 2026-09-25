defmodule PhpBeam.Eval.Assign do
  @moduledoc """
  The lvalue machinery: assignment (every target shape), path-based nested
  writes, isset/unset/destructuring. Bodies moved verbatim from Eval (P2c);
  the write-back gateway for ho builtins is `assign/4` via the Eval facade.
  """

  alias PhpBeam.Eval
  alias PhpBeam.{Env, Error, Interp, PArray, Pattern, Value}

  def assign({:prop, obj_e, name_e}, v, env, interp) do
    {{:val, obj_val}, env2, interp2} = Eval.eval(obj_e, env, interp)

    case obj_val do
      {:object, _} = obj_ref ->
        obj = Eval.get_object(interp2, obj_ref)
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
                {env2, Eval.put_object(interp2, obj_ref, %{obj | props: props2})}

              {:error, _} ->
                {env2, interp2}
            end

          true ->
            case PhpBeam.Classes.find_method(interp2, obj.class, "__set") do
              nil ->
                case PArray.put(obj.props, {:string, key}, v) do
                  {:ok, props2} ->
                    {env2, Eval.put_object(interp2, obj_ref, %{obj | props: props2})}

                  _ ->
                    {env2, interp2}
                end

              m ->
                gkey = {elem(obj_ref, 1), key}

                if MapSet.member?(interp2.set_guards, gkey) do
                  # php: writing the same property inside its own __set does
                  # not re-dispatch — the dynamic property is created directly
                  case PArray.put(obj.props, {:string, key}, v) do
                    {:ok, props2} ->
                      {env2, Eval.put_object(interp2, obj_ref, %{obj | props: props2})}

                    _ ->
                      {env2, interp2}
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
         Eval.warn(
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
            {env, Eval.warn(env, interp, "Access to undeclared static property")}
        end

      {:error, _} ->
        {env, interp}
    end
  end

  # a prop is readonly if its declaration says so OR the whole class is
  # `readonly class` (all instance props become readonly); inherited props
  # consult their DECLARING class

  def read_target(target, env, interp) do
    case target do
      {:var, name} ->
        case Env.lookup(env, interp, name) do
          {:ok, v} ->
            {v, env, interp}

          {:static, key, sname} ->
            {Map.get(interp.statics[key], sname, :null), env, interp}

          :undefined ->
            interp2 = Eval.warn(env, interp, "Undefined variable $#{name}")
            {:null, env, interp2}
        end

      {:var_var, e} ->
        {{:val, {:string, name}}, _e2, _i2} = Eval.eval(e, env, interp)
        read_target({:var, name}, env, interp)

      _ ->
        {{:val, v}, env2, interp2} = Eval.eval(target, env, interp)
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
    {{:val, name}, _e2, _i2} = Eval.eval(e, env, interp)

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
    {{:val, key}, env2, interp2} = Eval.eval(idx, env, interp)

    case Eval.deref(key, interp2) do
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

  def prop_rooted?({:index, inner, _}), do: prop_rooted?(inner)

  def prop_rooted?({:prop, _, _}), do: true

  def prop_rooted?({:static_prop, _, _}), do: true

  def prop_rooted?(_), do: false

  def assign({:index, container, idx}, v, env, interp) do
    generic_index_assign(container, idx, v, env, interp)
  end

  def generic_index_assign(container, idx, v, env, interp) do
    {path, env2, interp2} = build_path(container, env, interp)

    case idx do
      nil ->
        path_append(path, v, env2, interp2)

      idx_expr ->
        {{:val, key}, env3, interp3} = Eval.eval(idx_expr, env2, interp2)
        path_set(path, Eval.deref(key, interp3), v, env3, interp3)
    end
  end

  def nested_member_write({:index, inner, idx}, v, env, interp) do
    {{:val, container}, e2, i2} = quiet_read(inner, env, interp)
    container2 = mutate_member(container, idx, v, e2, i2)
    assign(inner, container2, e2, i2)
  end

  def nested_member_write(prop_t, idx, v, env, interp) do
    {{:val, container}, e2, i2} = quiet_read(prop_t, env, interp)
    container2 = mutate_member(container, idx, v, e2, i2)
    assign(prop_t, container2, e2, i2)
  end

  # write-context reads autovivify silently: php does not warn for missing
  # array keys / properties along `$a->p[$missing] = v` paths (undefined
  # VARIABLES along the path still warn, so those keep normal eval)

  def quiet_read({:index, cont, idx}, env, interp) do
    {{:val, c}, e2, i2} = quiet_read(cont, env, interp)

    case idx do
      nil ->
        {{:val, :null}, e2, i2}

      _ ->
        {{:val, k}, e3, i3} = Eval.eval(idx, e2, i2)

        case c do
          {:array, arr} -> {{:val, PArray.get(arr, Eval.deref(k, i3), :null)}, e3, i3}
          _ -> {{:val, :null}, e3, i3}
        end
    end
  end

  def quiet_read({:prop, obj_e, name_e} = ast, env, interp) do
    {{:val, ov}, e2, i2} = Eval.eval(obj_e, env, interp)

    case ov do
      {:object, _} = obj_ref ->
        obj = Eval.get_object(i2, obj_ref)
        key = String.downcase(prop_name_string(name_e, e2, i2))

        case PArray.fetch(obj.props, {:string, key}) do
          {:ok, v} -> {{:val, Eval.deref(v, i2)}, e2, i2}
          _ -> {{:val, :null}, e2, i2}
        end

      _ ->
        Eval.eval(ast, env, interp)
    end
  end

  def quiet_read(other, env, interp), do: Eval.eval(other, env, interp)

  def mutate_member(container, idx, v, e2, i2) do
    case container do
      {:array, arr} ->
        case idx do
          nil ->
            {:array, PArray.push(arr, v)}

          _ ->
            {{:val, key}, _, _} = Eval.eval(idx, e2, i2)

            case PArray.put(arr, Eval.deref(key, i2), v) do
              {:ok, a2} -> {:array, a2}
              _ -> container
            end
        end

      :null ->
        case idx do
          nil ->
            {:array, PArray.from_pairs([{nil, v}])}

          _ ->
            {{:val, key}, _, _} = Eval.eval(idx, e2, i2)
            {:array, PArray.from_pairs([{key, v}])}
        end

      _ ->
        container
    end
  end

  def assign(_, _v, env, interp), do: {env, interp}

  # build a write path: [{:var, name} | segments]

  def build_path(target, env, interp) do
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

  def update_path_env(base, [], v, _env, _interp), do: {v, nil, nil}

  def update_path_env(base, [{:index_expr, e} | rest], v, env, interp) do
    {{:val, k}, env2, interp2} = Eval.eval(e, env, interp)
    k2 = Eval.deref(k, interp2 || interp)
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

  def split_path([h]), do: {h, []}

  def split_path(path), do: {hd(path), tl(path)}

  # ───────────────────────── reads ─────────────────────────

  def index_read(container, key, env, interp) do
    case container do
      {:array, arr} ->
        case PArray.fetch(arr, key) do
          {:ok, v} ->
            {{:val, Eval.deref(v, interp)}, env, interp}

          :error ->
            interp2 = Eval.warn(env, interp, "Undefined array key \"#{plain_key(key)}\"")
            {{:val, :null}, env, interp2}
        end

      {:string, s} ->
        case Value.to_int(key) do
          {:ok, {:int, i}} ->
            i2 = if i < 0, do: byte_size(s) + i, else: i

            if i2 >= 0 and i2 < byte_size(s) do
              {{:val, {:string, binary_part(s, i2, 1)}}, env, interp}
            else
              interp2 = Eval.warn(env, interp, "Uninitialized string offset")
              {{:val, {:string, ""}}, env, interp2}
            end

          _ ->
            interp2 = Eval.warn(env, interp, "Illegal string offset")
            {{:val, {:string, ""}}, env, interp2}
        end

      :null ->
        interp2 = Eval.warn(env, interp, "Trying to access array offset on value of type null")
        {{:val, :null}, env, interp2}

      _ ->
        interp2 =
          Eval.warn(
            env,
            interp,
            "Trying to access array offset on value of type #{Value.gettype(container)}"
          )

        {{:val, :null}, env, interp2}
    end
  end

  def read_index_raw({:array, arr}, idx) do
    case PArray.fetch(arr, idx) do
      {:ok, v} -> v
      :error -> :null
    end
  end

  def read_index_raw(_, _), do: :null

  def plain_key({:int, i}), do: Integer.to_string(i)

  def plain_key({:string, s}), do: s

  def plain_key(_), do: ""

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
          {{:val, c}, env3, interp3} = Eval.eval(container, env2, interp2)

          case idx_expr do
            nil ->
              {false, env3, interp3}

            _ ->
              {{:val, k}, env4, interp4} = Eval.eval(idx_expr, env3, interp3)

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
        {{:val, ov}, env2, interp2} = Eval.eval(obj_e, env, interp)

        case ov do
          {:object, _} = obj_ref ->
            obj = Eval.get_object(interp2, obj_ref)
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
        {{:val, v}, env2, interp2} = Eval.eval(target, env, interp)
        {v != :null, env2, interp2}
    end
  end

  def unset_target({:var, name}, env, interp) do
    {:ok, e2, i2} = Env.unset_var(env, interp, name)
    {:ok, e2, i2}
  end

  def unset_target({:index, container, idx_expr}, env, interp) do
    case lvalue_path(container, env) do
      {:ok, path} ->
        {{:val, c}, env2, interp2} = Eval.eval(container, env, interp)
        {{:val, k}, env3, interp3} = Eval.eval(idx_expr, env2, interp2)

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
    {{:val, obj_val}, env2, interp2} = Eval.eval(obj_e, env, interp)

    case obj_val do
      {:object, _} = obj_ref ->
        obj = Eval.get_object(interp2, obj_ref)
        key = String.downcase(prop_name_string(name_e, env2, interp2))

        if readonly_prop?(interp2, obj, key) do
          msg =
            "Cannot unset readonly property #{prop_declarer_display(interp2, obj, key)}::$#{key}"

          {oref, i3} = materialize_native({:native_error, "Error", msg}, interp2)
          {{:unwind, {:php_throw, oref}}, env2, i3}
        else
          case PArray.delete(obj.props, {:string, key}) do
            {:ok, props2} ->
              {:ok, env2, Eval.put_object(interp2, obj_ref, %{obj | props: props2})}

            :error ->
              {:ok, env2, interp2}
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
          {{:val, k}, _e2, _i2} = Eval.eval(kexpr, e, i)
          {e3, i3} = assign(target, PArray.get(arr, k, :null), e, i)
          {idx, {e3, i3}}
      end)

    result
  end

  def deref_container({:ref, id}, interp), do: Map.get(interp.refs, id, :null)

  def deref_container(v, _), do: v

  # empty path (unsupported lvalue root): php would fatal; keep state safe

  def path_put([], _v, env, interp), do: {env, interp}

  def path_put([{:var, name}], v, env, interp), do: assign({:var, name}, v, env, interp)

  def path_put([{:var, name} | rest], v, env, interp) do
    base =
      case Env.lookup(env, interp, name) do
        {:ok, bv} -> deref_container(bv, interp)
        {:static, key, sname} -> Map.get(interp.statics[key] || %{}, sname, :null)
        :undefined -> :null
      end

    {updated, env2, interp2} = update_path_env(base, rest, v, env, interp)
    assign({:var, name}, updated, env2, interp2)
  end

  def string_offset_isset?(s, k, env, interp) do
    case Value.to_int(k) do
      {:ok, {:int, i}} ->
        i2 = if i < 0, do: byte_size(s) + i, else: i
        {i2 >= 0 and i2 < byte_size(s), env, interp}

      _ ->
        {false, env, interp}
    end
  end

  # ───────────────────────── unset ─────────────────────────
  def path_get([{:var, name} | rest], env, interp) do
    base =
      case Env.lookup(env, interp, name) do
        {:ok, v} -> deref_container(v, interp)
        {:static, key, sname} -> Map.get(interp.statics[key] || %{}, sname, :null)
        :undefined -> :null
      end

    walk_path_get(base, rest, env, interp)
  end

  def path_get([], _env, interp), do: {:null, nil, interp}

  def walk_path_get(base, [], env, interp), do: {base, env, interp}

  def walk_path_get(base, [{:index_expr, e} | rest], env, interp) do
    {{:val, k}, env2, interp2} = Eval.eval(e, env, interp)
    walk_path_get(read_index_raw(base, Eval.deref(k, interp2)), rest, env2, interp2)
  end

  defp class_name_of(a, b), do: Eval.class_name_of(a, b)
  defp display_class(a, b), do: Eval.display_class(a, b)
  defp env_scope_class(a), do: Eval.env_scope_class(a)
  defp make_instance(a, b), do: Eval.make_instance(a, b)
  defp materialize_native(a, b), do: Eval.materialize_native(a, b)
  defp method_name(a, b), do: Eval.method_name(a, b)
  defp pop_class_scope(a, b, c), do: Eval.pop_class_scope(a, b, c)
  defp prop_declarer_display(a, b, c), do: Eval.prop_declarer_display(a, b, c)
  defp prop_name_string(a, b, c), do: Eval.prop_name_string(a, b, c)
  defp push_class_scope(a, b), do: Eval.push_class_scope(a, b)
  defp put_ref_aware(a, b, c, d), do: Eval.put_ref_aware(a, b, c, d)
  defp readonly_init_scope?(a, b, c, d), do: Eval.readonly_init_scope?(a, b, c, d)
  defp readonly_prop?(a, b, c), do: Eval.readonly_prop?(a, b, c)
  defp strip_def_file(a, b), do: Eval.strip_def_file(a, b)
  defp call_php_method(a, b, c, d, e), do: Eval.call_php_method(a, b, c, d, e)
  defp class_key_of(a, b, c), do: Eval.class_key_of(a, b, c)
  defp static_prop_name(a, b, c), do: Eval.static_prop_name(a, b, c)
  defp static_props_key(a), do: Eval.static_props_key(a)

  def path_append(path, v, env, interp) do
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

  def path_set(path, key, v, env, interp) do
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
  def first_byte_str({:string, <<b::binary-size(1), _::binary>>}), do: b

  def first_byte_str(_), do: ""

  def string_offset_write(s, key, v, env, interp) do
    {ok?, idx} = offset_index(key)

    case Value.to_int(idx) do
      {:ok, {:int, i}} ->
        i2 = if i < 0, do: byte_size(s) + i, else: i

        cond do
          i2 < 0 or i2 >= byte_size(s) ->
            Eval.warn(env, interp, "Uninitialized string offset")
            s

          true ->
            <<pre::binary-size(i2), _c, post::binary>> = s
            pre <> first_byte_str(v) <> post
        end

      _ ->
        if ok? do
          s
        else
          Eval.warn(env, interp, "Illegal string offset")
          s
        end
    end
  end

  defp warn(a, b, c), do: Eval.warn(a, b, c)

  defp throw_set_error(a, b, c), do: Eval.throw_set_error(a, b, c)
  def offset_index({:int, i}), do: {true, {:int, i}}

  def offset_index({:string, s}), do: {false, {:string, s}}

  def offset_index(v), do: {true, v}
  # ── call machinery lives in PhpBeam.Eval.Call (delegates keep the old surface) ──
end
