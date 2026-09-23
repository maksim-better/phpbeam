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
    {{:val, obj_val}, env2, interp2} = eval(obj_e, env, interp)

    case obj_val do
      {:object, _} = obj_ref ->
        obj = get_object(interp2, obj_ref)
        key = prop_name_string(name_e, env2, interp2)

        case PArray.fetch(obj.props, {:string, String.downcase(key)}) do
          {:ok, v} ->
            {{:val, deref(v, interp2)}, env2, interp2}

          :error ->
            case PhpBeam.Classes.find_method(interp2, obj.class, "__get") do
              nil ->
                interp3 =
                  warn(
                    env2,
                    interp2,
                    "Undefined property: #{display_class(interp2, obj.class)}::$#{key}"
                  )

                {{:val, :null}, env2, interp3}

              m ->
                call_php_method(
                  obj_ref,
                  m,
                  [{:arg, {:lit_val, {:string, key}}, false, nil}],
                  env2,
                  interp2
                )
            end
        end

      :null ->
        {{:val, :null}, env2, warn(env2, interp2, "Attempt to read property \"value\" on null")}

      other ->
        interp3 =
          warn(
            env2,
            interp2,
            "Attempt to read property on value of type #{PhpBeam.Value.gettype(other)}"
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

        if declared do
          case PArray.put(obj.props, {:string, key}, v) do
            {:ok, props2} ->
              {env2, put_object(interp2, obj_ref, %{obj | props: props2})}

            {:error, _} ->
              {env2, interp2}
          end
        else
          case PhpBeam.Classes.find_method(interp2, obj.class, "__set") do
            nil ->
              case PArray.put(obj.props, {:string, key}, v) do
                {:ok, props2} -> {env2, put_object(interp2, obj_ref, %{obj | props: props2})}
                _ -> {env2, interp2}
              end

            m ->
              margs = [
                {:arg, {:lit_val, {:string, key}}, false, nil},
                {:arg, {:lit_val, v}, false, nil}
              ]

              case call_php_method(obj_ref, m, margs, env2, interp2) do
                {{:val, _}, _, i3} -> {env2, i3}
                _ -> {env2, interp2}
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
      name = static_prop_name(name_e, env, interp)

      case PhpBeam.Classes.find_prop(interp, key, name) do
        {:ok, prop} when prop.static? ->
          statics = Map.get(interp.statics, static_props_key(key), %{})
          {{:val, Map.get(statics, prop.name, prop.default)}, env, interp}

        _ ->
          {{:unwind,
            {:fatal,
             "Access to undeclared static property #{display_class(interp, key)}::$#{name}"}},
           env, interp}
      end
    else
      {:error, msg} -> {{:unwind, {:fatal, msg}}, env, interp}
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
      case PhpBeam.Classes.find_const(interp, key, cname) do
        {:ok, v} ->
          {{:val, v}, env, interp}

        :error ->
          # unknown constants fall back to global constants
          case Map.fetch(interp.consts, cname) do
            {:ok, v} ->
              {{:val, v}, env, interp}

            :error ->
              {{:unwind, {:fatal, "Undefined constant #{display_class(interp, key)}::#{cname}"}},
               env, interp}
          end
      end
    else
      {:error, msg} -> {{:unwind, {:fatal, msg}}, env, interp}
    end
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

            _ ->
              new_ref(:null, interp)
          end

        {:ok, env2, interp3} = Env.bind_var(env, interp2, rname, {:ref, id})
        {env3, interp4} = assign(target, {:ref, id}, env2, interp3)
        {{:val, deref({:ref, id}, interp4)}, env3, interp4}

      {:index, _, _} ->
        # taking a reference of an array element: bind the element to a cell
        {{:val, _cur}, _, _} = eval(rhs, env, interp)
        {{:unwind, {:fatal, "cannot take reference of this expression yet"}}, env, interp}

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
    {{:val, lv}, env2, interp2} = eval(l, env, interp)
    {{:val, rv}, env3, interp3} = eval(r, env2, interp2)
    # note: `and`/`or`/`xor` above don't short-circuit per PHP semantics
    # for `&&`/`||`; keyword forms are handled above with eager evaluation

    case apply_binop(op, lv, rv, env3, interp3) do
      {:ok, v} ->
        {{:val, v}, env3, interp3}

      {:unwind, u, interp4} ->
        {{:unwind, u}, env3, interp4}

      {:unwind, _} = u ->
        {u, env3, interp3}
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

  def eval({:new, cls, args}, env, interp) do
    with {:ok, key} <- class_key_of(cls, env, interp) do
      case PhpBeam.Classes.get_class(interp, key) do
        nil ->
          {{:unwind, {:fatal, "Class \"#{display_class(interp, key)}\" not found"}}, env, interp}

        class ->
          if class.kind == :interface or class.kind == :trait do
            {{:unwind, {:fatal, "Cannot instantiate #{class.kind} #{class.name}"}}, env, interp}
          else
            {{:object, _} = obj_ref, interp2} = make_instance(interp, key)
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
      %{name: n} -> n
      _ -> key
    end
  end

  # objects live in the interpreter (handle semantics); the value is a ref id
  def make_instance(interp, key) do
    id = interp.next_obj
    obj = PhpBeam.Classes.instantiate(interp, key, id)
    interp2 = %{interp | objects: Map.put(interp.objects, id, obj), next_obj: id + 1}
    {{:object, id}, interp2}
  end

  def get_object(interp, {:object, id}),
    do: Map.get(interp.objects, id, %{__ref__: id, class: "stdclass", props: PArray.new()})

  def get_object(_interp, other), do: other

  def put_object(interp, {:object, id}, obj_map) do
    %{interp | objects: Map.put(interp.objects, id, obj_map)}
  end

  def new_stdclass(interp, props) do
    id = interp.next_obj
    obj = %{__ref__: id, class: "stdclass", props: props, stdclass?: true}
    {{:object, id}, %{interp | objects: Map.put(interp.objects, id, obj), next_obj: id + 1}}
  end

  defp call_constructor({:object, _} = obj_ref, args, env, interp) do
    obj = get_object(interp, obj_ref)

    case PhpBeam.Classes.find_method(interp, obj.class, "__construct") do
      nil ->
        {{:val, obj_ref}, env, interp}

      method ->
        case call_php_method(obj_ref, method, args, env, interp) do
          {{:val, _ret}, e2, i2} -> {{:val, obj_ref}, e2, i2}
          {{:unwind, _} = u, _, _} -> u
        end
    end
  end

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

    {{:val, {:closure, params, body, captures, arrow?}}, env2, interp2}
  end

  def eval({:method_call, obj_e, name_e, args, nullsafe?}, env, interp) do
    {{:val, obj_ref}, env2, interp2} = eval(obj_e, env, interp)

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
            {:array, PArray.from_pairs(Enum.map(arg_values(args, env, interp), &{nil, &1}))}},
           false, nil}
        ]

        call_php_method(obj_ref, m, margs, env, interp)
    end
  end

  defp arg_values(args, env, interp) do
    case resolve_args(eval_args(args, env, interp, false)) do
      {:ok, vals} -> vals
      _ -> []
    end
  end

  # dispatch a PHP method (user or native) with $this bound
  def call_php_method({:object, _} = obj_ref, method, args, env, interp) do
    obj = get_object(interp, obj_ref)

    if method.native do
      {:native, native} = method.native

      vals = arg_values(args, env, interp)

      case native.(obj, vals, interp) do
        {:ok, {ret, obj2}, interp2} ->
          interp3 = put_object(interp2, obj_ref, obj2)
          {{:val, ret}, env, interp3}

        other ->
          other
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

      {binds, interp2} = bind_params(method.params, args, fenv, env, interp)

      fenv2 =
        Enum.reduce(binds, fenv, fn {n, v}, acc -> %{acc | vars: Map.put(acc.vars, n, v)} end)

      {res, _, interp3} = Interp.exec_stmts(method.body, fenv2, interp2)

      {interp4, env_out} = write_back_refs(method.params, args, env, fenv2, interp3)

      case res do
        :ok -> {{:val, :null}, env_out, interp4}
        {:unwind, {:return, v}} -> {{:val, v}, env_out, interp4}
        {:unwind, _} = u -> {{:unwind, elem(u, 1)}, env_out, interp4}
      end
    end
  end

  def eval({:static_call, cname_e, name_e, args}, env, interp) do
    name = prop_name_string(name_e, env, interp)

    with {:ok, key} <- class_key_of(cname_e, env, interp),
         class when class != nil <- PhpBeam.Classes.get_class(interp, key) || :none do
      case PhpBeam.Classes.find_method(interp, key, name) do
        nil ->
          magic_static_call(key, name, args, env, interp)

        method ->
          cond do
            method.static? ->
              call_static_method(key, method, args, env, interp)

            # parent::method() / self::method() inside an instance method
            env != nil and env.this != nil ->
              call_php_method(env.this, method, args, env, interp)

            true ->
              msg =
                "Non-static method #{display_class(interp, key)}::#{name}() cannot be called statically"

              {{:unwind, {:fatal, msg}}, env, warn(env, interp, msg)}
          end
      end
    else
      :none ->
        {{:unwind, {:fatal, "Class \"#{inspect(cname_e)}\" not found"}}, env, interp}

      {:error, msg} ->
        {{:unwind, {:fatal, msg}}, env, interp}
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
            {:array, PArray.from_pairs(Enum.map(arg_values(args, env, interp), &{nil, &1}))}},
           false, nil}
        ]

        call_static_method(key, m, margs, env, interp)
    end
  end

  defp call_static_method(key, method, args, env, interp) do
    if method.native do
      {:native, native} = method.native
      vals = arg_values(args, env, interp)

      case native.(%{__ref__: 0, class: key, props: PArray.new()}, vals, interp) do
        {:ok, {ret, _obj2}, interp2} -> {{:val, ret}, env, interp2}
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

      {binds, interp2} = bind_params(method.params, args, fenv, env, interp)

      fenv2 =
        Enum.reduce(binds, fenv, fn {n, v}, acc -> %{acc | vars: Map.put(acc.vars, n, v)} end)

      {res, _, interp3} = Interp.exec_stmts(method.body, fenv2, interp2)
      {interp4, env_out} = write_back_refs(method.params, args, env, fenv2, interp3)

      case res do
        :ok -> {{:val, :null}, env_out, interp4}
        {:unwind, {:return, v}} -> {{:val, v}, env_out, interp4}
        {:unwind, _} = u -> {{:unwind, elem(u, 1)}, env_out, interp4}
      end
    end
  end

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
    cond do
      # sorts need the raw array-argument lvalue for writeback
      name in ~w(usort uasort uksort) ->
        unwrap_args =
          Enum.map(args, fn
            {:arg, e, _, _} -> e
            {:arg_spread, e, _} -> e
          end)

        dispatch_ho(name, unwrap_args, env, interp)

      name in ~w(call_user_func call_user_func_array array_map array_filter array_reduce array_walk) ->
        case resolve_args(eval_args(args, env, interp, false)) do
          {:ok, vals} -> dispatch_ho(name, vals, env, interp)
          {:unwind, u} -> {{:unwind, u}, env, interp}
        end

      true ->
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

  # user-comparator sorts mutate their array argument (writeback via lvalue)
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
    {this, called_class, scope_class} =
      case Map.get(captures, :__obj_ctx) do
        nil -> {nil, nil, nil}
        ctx -> {Map.get(ctx, :this), Map.get(ctx, :called_class), Map.get(ctx, :scope_class)}
      end

    fenv = %Env{
      function: "{closure}",
      statics_key: nil,
      closure_captures: Map.delete(captures, :__obj_ctx),
      this: this,
      called_class: called_class,
      scope_class: scope_class
    }

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
      {:ok, {:unwind, {:php_throw, {:native_error, _, _} = ne}}, interp3} ->
        {obj_ref, interp4} = materialize_native(ne, interp3)
        {{:unwind, {:php_throw, obj_ref}}, env, interp4}

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
        value_or_throw(Value.divide(l, r), interp)

      :% ->
        lossy_warn(l, interp)
        lossy_warn(r, interp)
        value_or_throw(Value.modulo(l, r), interp)

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
    PhpBeam.Interp.warn(
      interp,
      "Implicit conversion from float " <>
        PhpBeam.Value.float_to_string(f) <> " to int loses precision"
    )
  end

  defp lossy_warn(_, _interp), do: :ok

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

  # resolve a class-name AST to a storage key (downcased, no leading backslash)
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

      {{:val, {:object, %{class: key}}}, _e, _i} ->
        {:ok, key}

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
  def const_fold(ast, interp) do
    case eval(ast, nil, interp) do
      {{:val, v}, _, _} -> v
      _ -> :null
    end
  rescue
    _ -> :null
  end

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

  # nested writes into member containers: $this->arr[$k] = v / self::$a[] = v
  def assign({:index, {:prop, _, _} = prop_t, idx}, v, env, interp) do
    nested_member_write(prop_t, idx, v, env, interp)
  end

  def assign({:index, {:static_prop, _, _} = prop_t, idx}, v, env, interp) do
    nested_member_write(prop_t, idx, v, env, interp)
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

  defp nested_member_write(prop_t, idx, v, env, interp) do
    {{:val, container}, e2, i2} = eval(prop_t, env, interp)

    container2 =
      case container do
        {:array, arr} ->
          case idx do
            nil ->
              {:array, PArray.push(arr, v)}

            _ ->
              {{:val, key}, _, _} = eval(idx, e2, i2)

              case PArray.put(arr, key, v) do
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

    assign(prop_t, container2, e2, i2)
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
