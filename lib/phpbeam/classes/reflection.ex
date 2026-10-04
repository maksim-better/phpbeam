defmodule PhpBeam.Classes.Reflection2 do
  @moduledoc """
  PHASE B4: the Reflection expansion — ReflectionFunction(+Abstract),
  ReflectionObject, ReflectionProperty, ReflectionClassConstant,
  ReflectionUnionType/IntersectionType, ReflectionEnum(+cases),
  ReflectionGenerator/Fiber stubs (php surface but thin), plus the
  ReflectionClass/Method/Parameter methods Laravel's container actually
  calls (getProperty/getConstants/hasProperty/getConstant/getDefaultProperties,
  getDeclaringClass/getNumberOfParameters/getReturnType, property access
  with setAccessible/getValue/setValue, class constants).

  State rides `dt_state` maps like the L2-era slices in Table (key "ckey"
  etc.), so both modules interoperate.
  """

  alias PhpBeam.{Eval, PArray, Value}
  alias PhpBeam.Classes.Table

  defp display_class(i, key) do
    case Table.get_class(i, key) do
      %{name: n} -> n
      _ -> key
    end
  end

  # full inheritance chain INCLUDING self, outermost-last
  defp chain(i, key) do
    case Table.get_class(i, key) do
      %{parent: p} when not is_nil(p) -> [key | chain(i, p)]
      _ -> [key]
    end
  end

  @doc """
  Method tables for the classes this module owns; merged INTO
  Table.native_classes/0 by the caller (Table can't alias us — we alias it).
  """
  def classes do
    %{
      "reflectionfunctionabstract" =>
        class_shell("ReflectionFunctionAbstract", fn_abSTRACT_methods()),
      "reflectionfunction" => class_shell("ReflectionFunction", function_methods()),
      "reflectionobject" => object_class(),
      "reflectionproperty" => property_class(),
      "reflectionclassconstant" => class_constant_class(),
      "reflectionuniontype" => union_type_class("ReflectionUnionType"),
      "reflectionintersectiontype" => union_type_class("ReflectionIntersectionType"),
      "reflectionenum" => enum_class(),
      "reflectionenumunitcase" => enum_case_class("ReflectionEnumUnitCase"),
      "reflectionenumbackedcase" => enum_case_class("ReflectionEnumBackedCase"),
      "reflectiongenerator" => class_shell("ReflectionGenerator", %{}),
      "reflectionfiber" => class_shell("ReflectionFiber", %{}),
      "reflectionreference" => class_shell("ReflectionReference", %{}),
      "reflectionextension" => class_shell("ReflectionExtension", %{}),
      "reflectionzendextension" => class_shell("ReflectionZendExtension", %{})
    }
  end

  ## ───────────────── shell + state helpers ─────────────────

  def class_shell(name, methods), do: shell_struct(name, methods)

  defp shell_struct(name, methods) do
    %Table{
      name: name,
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: methods,
      file: ""
    }
  end

  def st(obj), do: Map.get(obj, :dt_state) || %{}

  # Table's ReflectionClass stores the target as "key"
  defp ckey_of(obj), do: st(obj)["ckey"] || st(obj)["key"]
  def st_put(obj, k, v), do: Map.put(obj, :dt_state, Map.put(st(obj), k, v))

  defp dt_s({:string, s}), do: s
  defp dt_s(v), do: Eval.php_to_string(v)

  defp fn_native(name, fun) do
    # mirrors Table's native_fn shape
    %{
      name: name,
      visibility: :public,
      static?: false,
      abstract?: false,
      final?: false,
      params: [],
      body: [],
      class: nil,
      native: {:native, fun}
    }
  end

  # the passthrough native_call shape is {{:unwind,u}, env, i}
  defp throw_ex(i, msg) do
    {oref, i2} = Eval.materialize_native({:native_error, "ReflectionException", msg}, i)
    {{:unwind, {:php_throw, oref}}, nil, i2}
  end

  ## ───────────────── ReflectionFunctionAbstract ─────────────────

  def fn_abSTRACT_methods do
    Map.new(
      [
        fn_native("__construct", fn _obj, _args, i ->
          throw_ex(i, "Cannot instantiate abstract class ReflectionFunctionAbstract")
        end),
        fn_native("getname", fn obj, _args, i ->
          {:ok, {{:string, st(obj)["name"] || ""}, obj}, i}
        end),
        fn_native("getnumberofparameters", fn obj, _args, i ->
          {:ok, {{:int, length(fn_params(obj))}, obj}, i}
        end),
        fn_native("getnumberofrequiredparameters", fn obj, _args, i ->
          n = Enum.count(fn_params(obj), fn p -> p_required?(p) end)
          {:ok, {{:int, n}, obj}, i}
        end),
        fn_native("getparameters", fn obj, _args, i ->
          make_param_objs(obj, i)
        end),
        fn_native("hasreturntype", fn obj, _args, i ->
          {:ok, {{:bool, fn_ret_type(obj) != nil}, obj}, i}
        end),
        fn_native("getreturntype", fn obj, _args, i ->
          case fn_ret_type(obj) do
            nil ->
              {:ok, {{:null, obj}, obj}, i}

            types ->
              {oref, i3} = type_obj(types, i)
              {:ok, {oref, obj}, i3}
          end
        end),
        fn_native("__tostring", fn obj, _args, i ->
          {:ok, {{:string, st(obj)["name"] || ""}, obj}, i}
        end)
      ],
      fn m -> {String.downcase(m.name), m} end
    )
  end

  # builtin arginfo for functions whose registry entry lacks :params
  # (string functions without declared names in the table)
  @builtin_arginfo %{
    "strlen" => ["string"],
    "count" => ["value"],
    "in_array" => ["needle", "haystack"],
    "array_key_exists" => ["key", "array"],
    "is_array" => ["value"],
    "is_string" => ["value"],
    "is_int" => ["value"],
    "is_null" => ["value"],
    "sprintf" => ["format"],
    "printf" => ["format"],
    "implode" => ["separator", "array"],
    "explode" => ["separator", "string"],
    "str_repeat" => ["string", "times"],
    "substr" => ["string", "offset"],
    "str_replace" => ["search", "replace", "subject"],
    "strtolower" => ["string"],
    "strtoupper" => ["string"],
    "trim" => ["string", "characters"]
  }

  defp fn_params(obj) do
    case st(obj)["params"] do
      ps when is_list(ps) and ps != [] ->
        ps

      _ ->
        name = st(obj)["name"] || ""

        (@builtin_arginfo[name] || [])
        |> Enum.map(&{:param, &1, nil, nil, false, false})
    end
  end

  defp p_required?({:param, _n, _t, default, _by_ref, _variadic}), do: default == nil

  defp fn_ret_type(obj) do
    st(obj)["ret"]
    |> case do
      nil -> nil
      "" -> nil
      types -> types
    end
  end

  defp make_param_objs(obj, i) do
    {pairs, ifinal} =
      fn_params(obj)
      |> Enum.with_index(fn p, idx -> {p, idx} end)
      |> Enum.map_reduce(i, fn {p, idx}, ia ->
        {oref, ib} = Eval.make_instance(ia, "reflectionparameter")
        po = Eval.get_object(ib, oref)

        po2 =
          st_put(po, "pname", elem(p, 1))
          # php exposes ->name as a real property (Laravel's container
          # dependency resolution reads $dependency->name directly)
          |> st_put("name", elem(p, 1))
          |> st_put("ptype", elem(p, 2))
          |> st_put("pdefault", elem(p, 3))
          |> st_put("by_ref", elem(p, 4))
          |> st_put("variadic", elem(p, 5))
          |> st_put("position", idx)
          |> st_put("fn_name", st(obj)["name"] || "")

        # ->name must be a REAL property (not just method/state) — the
        # native class declares no props, so write into the instance's
        # dynamic prop table (Laravel reads $dependency->name directly)
        po3 =
          case PArray.put(po2.props, {:string, "name"}, {:string, elem(p, 1)}) do
            {:ok, pp} -> %{po2 | props: pp}
            _ -> po2
          end

        ib2 = PhpBeam.Objects.put_object(ib, oref, po3)
        {oref, ib2}
      end)

    arr =
      pairs
      |> Enum.with_index(fn r, idx -> {idx, r} end)
      |> PArray.from_pairs()

    {:ok, {{:array, arr}, obj}, ifinal}
  end

  # types: list of type-name strings; >1 → union; single with "?" prefix nullable
  def make_type_obj(types, i), do: type_obj(types, i)

  defp type_obj([_single] = types, i) do
    {oref, i2} = Eval.make_instance(i, "reflectionnamedtype")
    to = Eval.get_object(i2, oref)
    to2 = st_put(to, "tname", hd(types)) |> st_put("nullable", false)
    i3 = PhpBeam.Objects.put_object(i2, oref, to2)
    {oref, i3}
  end

  defp type_obj(types, i) do
    {oref, i2} = Eval.make_instance(i, "reflectionuniontype")
    to = Eval.get_object(i2, oref)

    to2 =
      st_put(to, "tnames", types)

    i3 = PhpBeam.Objects.put_object(i2, oref, to2)
    {oref, i3}
  end

  ## ───────────────── ReflectionFunction ─────────────────

  def function_methods do
    Map.merge(
      fn_abSTRACT_methods(),
      Map.new(
        [
          fn_native("__construct", fn obj, args, i ->
            case args do
              [{:string, fname} | _] ->
                case Map.get(i.functions, String.downcase(fname)) do
                  # userland fn: {:user, params, body, file, line, ns, uses}
                  {:user, uparams, _, _, _, _, _} = uentry ->
                    ps =
                      Enum.map(uparams, fn
                        {:param, n, _, _, _, _} -> {:param, n, nil, nil, false, false}
                        n when is_binary(n) -> {:param, n, nil, nil, false, false}
                      end)

                    obj2 =
                      st_put(obj, "name", fname)
                      |> st_put("params", ps)
                      |> st_put("builtin?", false)
                      |> st_put("ret", elem(uentry, 0) == :ok and nil)

                    {:ok, {{:null, obj2}, obj2}, i}

                  entry when is_map(entry) ->
                    # params: optional names list; absent → no parameters
                    ps =
                      entry
                      |> Map.get(:params, [])
                      |> Enum.map(&{:param, &1, nil, nil, false, false})

                    obj2 =
                      st_put(obj, "name", fname)
                      |> st_put("params", ps)
                      |> st_put("builtin?", not Map.has_key?(entry, :ho))
                      |> st_put("ret", nil)

                    {:ok, {{:null, obj2}, obj2}, i}

                  _ ->
                    throw_ex(i, "Function #{dt_s(hd(args))}() does not exist")
                end

              [cb | _] when elem(cb, 0) == :closure ->
                cs = closure_state(obj, cb, i)
                {:ok, {{:null, cs}, cs}, i}

              _ ->
                throw_ex(i, "Invalid argument")
            end
          end),
          fn_native("isbuiltin", fn obj, _args, i ->
            {:ok, {{:bool, st(obj)["builtin?"] == true}, obj}, i}
          end),
          fn_native("isinternal", fn obj, _args, i ->
            {:ok, {{:bool, st(obj)["builtin?"] == true}, obj}, i}
          end),
          fn_native("invoke", fn obj, args, i ->
            name = st(obj)["name"] || ""

            case Eval.call_cb({:string, name}, args, %{}, i) do
              {{:val, v}, _, i2} -> {:ok, {v, obj}, i2}
              {{:unwind, _} = u, _, i2} -> {u, nil, i2}
              _ -> {:ok, {{:bool, false}, obj}, i}
            end
          end),
          fn_native("getclosure", fn obj, _args, i ->
            {:ok, {{:null, obj}, obj}, i}
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )
    )
  end

  # closure value: {:closure, id, params, body, captures, arrow?, def_file, def_line, gen?}
  defp closure_state(obj, cb, i) do
    params = elem(cb, 2)

    name =
      case elem(cb, 6) do
        nil -> "{closure}"
        f -> "{closure:#{f}:#{elem(cb, 7)}}"
      end

    st_put(obj, "name", name)
    |> st_put("params", params)
    |> st_put("builtin?", false)
    |> st_put("ret", nil)
    |> st_put("closure", cb)
  end

  ## ───────────────── ReflectionObject ─────────────────

  defp object_class do
    shell_struct(
      "ReflectionObject",
      Map.new(
        [
          fn_native("__construct", fn obj, args, i ->
            case args do
              [{:object, _} = oref | _] ->
                key = Eval.get_object(i, oref).class
                {:ok, {{:null, st_put(obj, "ckey", key) |> st_put("oref", oref)}, obj}, i}

              _ ->
                throw_ex(i, "ReflectionObject::__construct() expects an object")
            end
          end),
          fn_native("getname", fn obj, _args, i ->
            key = ckey_of(obj)
            name = Table.display_class(i, key)
            {:ok, {{:string, name}, obj}, i}
          end),
          fn_native("getproperties", fn obj, _args, i ->
            key = ckey_of(obj)

            props =
              chain(i, key)
              |> Enum.reverse()
              |> Enum.flat_map(fn k ->
                case Table.get_class(i, k) do
                  %{props: ps} -> ps
                  _ -> []
                end
              end)
              |> Enum.reverse()

            {refs, i2} =
              Enum.reduce(props, {[], i}, fn {pname, p}, {acc, ia} ->
                {pref, ib} = Eval.make_instance(ia, "reflectionproperty")
                po = Eval.get_object(ib, pref)

                po2 =
                  st_put(po, "ckey", key)
                  |> st_put("pname", pname)
                  |> st_put("vis", p.visibility)

                ib2 = PhpBeam.Objects.put_object(ib, pref, po2)
                {[pref | acc], ib2}
              end)

            arr =
              refs
              |> Enum.reverse()
              |> Enum.with_index(fn r, idx -> {idx, r} end)
              |> PArray.from_pairs()

            {:ok, {{:array, arr}, obj}, i2}
          end),
          fn_native("getproperty", fn obj, args, i ->
            key = ckey_of(obj)

            case Table.find_prop(i, key, dt_s(Enum.at(args, 0, {:string, ""}))) do
              {:ok, prop} ->
                {pref, i2} = Eval.make_instance(i, "reflectionproperty")
                po = Eval.get_object(i2, pref)

                po2 =
                  st_put(po, "ckey", key)
                  |> st_put("pname", prop.name)
                  |> st_put("vis", prop.visibility)

                i3 = PhpBeam.Objects.put_object(i2, pref, po2)
                {:ok, {pref, obj}, i3}

              _ ->
                throw_ex(
                  i,
                  "Property " <> dt_s(Enum.at(args, 0, {:string, ""})) <> " does not exist"
                )
            end
          end),
          fn_native("hasproperty", fn obj, args, i ->
            key = ckey_of(obj)

            found =
              match?(
                {:ok, _},
                Table.find_prop(i, key, dt_s(Enum.at(args, 0, {:string, ""})))
              )

            {:ok, {{:bool, found}, obj}, i}
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )
    )
  end

  ## ───────────────── ReflectionProperty ─────────────────

  defp property_class do
    shell_struct(
      "ReflectionProperty",
      Map.new(
        [
          fn_native("__construct", fn obj, args, i ->
            case args do
              [{:string, cls}, {:string, pname} | _] ->
                key = find_key(i, cls)

                if key && match?({:ok, _}, Table.find_prop(i, key, pname)) do
                  obj2 = st_put(obj, "ckey", key) |> st_put("pname", pname)
                  {:ok, {:null, obj2}, i}
                else
                  throw_ex(i, "Property #{"\\$" <> pname} does not exist")
                end

              _ ->
                throw_ex(i, "Invalid arguments")
            end
          end),
          fn_native("getname", fn obj, _args, i ->
            {:ok, {{:string, st(obj)["pname"] || ""}, obj}, i}
          end),
          fn_native("ispublic", fn obj, _args, i -> vis_bool(obj, i, :public) end),
          fn_native("isprivate", fn obj, _args, i -> vis_bool(obj, i, :private) end),
          fn_native("isprotected", fn obj, _args, i -> vis_bool(obj, i, :protected) end),
          fn_native("isstatic", fn obj, _args, i ->
            prop = find_own_prop(obj, i)
            {:ok, {{:bool, prop != nil and Map.get(prop, :static?, false) == true}, obj}, i}
          end),
          fn_native("isdefault", fn obj, _args, i ->
            # declared-with-default properties; dynamic ones are not default
            prop = find_own_prop(obj, i)
            {:ok, {{:bool, prop != nil}, obj}, i}
          end),
          fn_native("setaccessible", fn obj, _args, i ->
            {:ok, {{:bool, true}, st_put(obj, "accessible", true)}, i}
          end),
          fn_native("getdeclaringclass", fn obj, _args, i ->
            key = ckey_of(obj)
            {cref, i2} = Eval.make_instance(i, "reflectionclass")
            co = Eval.get_object(i2, cref)
            co2 = st_put(co, "ckey", key) |> st_put("key", key)
            i3 = PhpBeam.Objects.put_object(i2, cref, co2)
            {:ok, {cref, obj}, i3}
          end),
          fn_native("getvalue", fn obj, args, i ->
            key = st(obj)["pname"]

            case args do
              [{:object, _} = oref | _] ->
                target = Eval.get_object(i, oref)

                case PArray.fetch(target.props, {:string, key}) do
                  {:ok, v} -> {:ok, {v, obj}, i}
                  _ -> {:ok, {{:null, obj}, obj}, i}
                end

              _ ->
                throw_ex(i, "Cannot get non-static property without an object")
            end
          end),
          fn_native("setvalue", fn obj, args, i ->
            key = st(obj)["pname"]

            case args do
              [{:object, _} = oref, v | _] ->
                target = Eval.get_object(i, oref)

                target2 =
                  case PArray.put(target.props, {:string, key}, v) do
                    {:ok, p} -> %{target | props: p}
                    _ -> target
                  end

                i2 = PhpBeam.Objects.put_object(i, oref, target2)
                {:ok, {:null, obj}, i2}

              _ ->
                throw_ex(i, "Cannot set non-static property without an object")
            end
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )
    )
  end

  defp find_key(i, name) do
    dn = String.downcase(name)
    if Map.has_key?(i.classes, dn), do: dn, else: nil
  end

  defp vis_bool(obj, i, vis) do
    key = ckey_of(obj)
    pname = st(obj)["pname"]

    actual =
      case Table.find_prop(i, key, pname) do
        {:ok, prop} -> prop.visibility
        _ -> nil
      end

    {:ok, {{:bool, actual == vis}, obj}, i}
  end

  defp find_own_prop(obj, i) do
    key = ckey_of(obj)
    pname = st(obj)["pname"]

    case Table.find_prop(i, key, pname) do
      {:ok, prop} -> prop
      _ -> nil
    end
  end

  ## ───────────────── ReflectionClassConstant ─────────────────

  defp class_constant_class do
    shell_struct(
      "ReflectionClassConstant",
      Map.new(
        [
          fn_native("__construct", fn obj, args, i ->
            case args do
              [{:string, cls}, {:string, cname} | _] ->
                key = find_key(i, cls)

                consts =
                  chain(i, key)
                  |> Enum.reverse()
                  |> Enum.flat_map(fn k ->
                    case Table.get_class(i, k) do
                      %{consts: cs} -> Map.to_list(cs)
                      _ -> []
                    end
                  end)

                found = Enum.find(consts, fn {n, _} -> to_string(n) == cname end)

                if found do
                  {cn, cv} = found

                  {:ok,
                   {:null,
                    st_put(obj, "cname", to_string(cn))
                    |> st_put("cval", cv)
                    |> st_put("ckey", key)}, i}
                else
                  throw_ex(i, "Constant #{"\\\"" <> cname <> "\\\""} does not exist")
                end

              _ ->
                throw_ex(i, "Invalid arguments")
            end
          end),
          fn_native("getname", fn obj, _args, i ->
            {:ok, {{:string, st(obj)["cname"] || ""}, obj}, i}
          end),
          fn_native("getvalue", fn obj, _args, i ->
            {:ok, {st(obj)["cval"] || :null, obj}, i}
          end),
          fn_native("ispublic", fn obj, _args, i ->
            {:ok, {{:bool, true}, obj}, i}
          end),
          fn_native("getdeclaringclass", fn obj, _args, i ->
            key = ckey_of(obj)
            {cref, i2} = Eval.make_instance(i, "reflectionclass")
            co = Eval.get_object(i2, cref)
            co2 = st_put(co, "ckey", key) |> st_put("key", key)
            i3 = PhpBeam.Objects.put_object(i2, cref, co2)
            {:ok, {cref, obj}, i3}
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )
    )
  end

  ## ───────────────── union/intersection types ─────────────────

  defp union_type_class(name) do
    shell_struct(
      name,
      Map.new(
        [
          fn_native("gettypes", fn obj, _args, i ->
            names = st(obj)["tnames"] || []

            {refs, i2} =
              Enum.reduce(names, {[], i}, fn n, {acc, ia} ->
                {tref, ib} = Eval.make_instance(ia, "reflectionnamedtype")
                to = Eval.get_object(ib, tref)
                to2 = st_put(to, "tname", n)
                ib2 = PhpBeam.Objects.put_object(ib, tref, to2)
                {[tref | acc], ib2}
              end)

            arr =
              refs
              |> Enum.reverse()
              |> Enum.with_index(fn r, idx -> {idx, r} end)
              |> PArray.from_pairs()

            {:ok, {{:array, arr}, obj}, i2}
          end),
          fn_native("__tostring", fn obj, _args, i ->
            names = st(obj)["tnames"] || []
            sep = if name == "ReflectionUnionType", do: "|", else: "&"
            {:ok, {{:string, Enum.join(names, sep)}, obj}, i}
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )
    )
  end

  ## ───────────────── enums ─────────────────

  defp enum_class do
    shell_struct(
      "ReflectionEnum",
      Map.new(
        [
          fn_native("__construct", fn obj, args, i ->
            case args do
              [{:string, cls} | _] ->
                key = find_key(i, cls)
                {:ok, {:null, st_put(obj, "ckey", key)}, i}

              _ ->
                {:ok, {{:null, obj}, obj}, i}
            end
          end),
          fn_native("getcases", fn obj, _args, i ->
            key = ckey_of(obj)

            case Table.get_class(i, key) do
              %{kind: :enum, consts: consts} ->
                {refs, i2} =
                  Enum.reduce(consts, {[], i}, fn
                    {n, {:array, _}}, {acc, ia} ->
                      # case singletons are stored as enum objects
                      {cref, ib} = Eval.make_instance(ia, "reflectionenumunitcase")
                      co = Eval.get_object(ib, cref)
                      co2 = st_put(co, "cname", to_string(n)) |> st_put("ckey", key)
                      ib2 = PhpBeam.Objects.put_object(ib, cref, co2)
                      {[cref | acc], ib2}

                    _, acc ->
                      acc
                  end)

                arr =
                  refs
                  |> Enum.reverse()
                  |> Enum.with_index(fn r, idx -> {idx, r} end)
                  |> PArray.from_pairs()

                {:ok, {{:array, arr}, obj}, i2}

              _ ->
                {:ok, {{:array, PArray.new()}, obj}, i}
            end
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )
    )
  end

  defp enum_case_class(name) do
    shell_struct(
      name,
      Map.new(
        [
          fn_native("getname", fn obj, _args, i ->
            {:ok, {{:string, st(obj)["cname"] || ""}, obj}, i}
          end),
          fn_native("getvalue", fn obj, _args, i ->
            # backed cases: backing value; unit: the case object
            {:ok, {st(obj)["cval"] || :null, obj}, i}
          end),
          fn_native("getenum", fn obj, _args, i ->
            key = ckey_of(obj)
            {cref, i2} = Eval.make_instance(i, "reflectionenum")
            co = Eval.get_object(i2, cref)
            co2 = st_put(co, "ckey", key)
            i3 = PhpBeam.Objects.put_object(i2, cref, co2)
            {:ok, {cref, obj}, i3}
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )
    )
  end

  # extra ReflectionClass methods (B4): property/constant surface
  def reflection_class_extras do
    Map.new(
      [
        fn_native_rc("getproperty", fn _obj, args, i ->
          {rcobj, key} = rc_self(_obj)

          case Table.find_prop(i, key, dt_s(Enum.at(args, 0, {:string, ""}))) do
            {:ok, prop} ->
              {pref, i2} = Eval.make_instance(i, "reflectionproperty")
              po = Eval.get_object(i2, pref)

              po2 =
                st_put(po, "ckey", key)
                |> st_put("pname", prop.name)
                |> st_put("vis", prop.visibility)

              i3 = PhpBeam.Objects.put_object(i2, pref, po2)
              {:ok, {pref, rcobj}, i3}

            _ ->
              throw_ex(
                i,
                "Property " <> dt_s(Enum.at(args, 0, {:string, ""})) <> " does not exist"
              )
          end
        end),
        fn_native_rc("hasproperty", fn obj, args, i ->
          key = ckey_of(obj)

          found =
            match?(
              {:ok, _},
              Table.find_prop(i, key, dt_s(Enum.at(args, 0, {:string, ""})))
            )

          {:ok, {{:bool, found}, obj}, i}
        end),
        fn_native_rc("getproperties", fn obj, _args, i ->
          key = ckey_of(obj)

          props =
            chain(i, key)
            |> Enum.reverse()
            |> Enum.flat_map(fn k ->
              case Table.get_class(i, k) do
                %{props: ps} -> Enum.map(ps, fn p -> {p.name, p} end)
                _ -> []
              end
            end)

          {refs, i2} =
            Enum.reduce(props, {[], i}, fn {pname, p}, {acc, ia} ->
              {pref, ib} = Eval.make_instance(ia, "reflectionproperty")
              po = Eval.get_object(ib, pref)

              po2 =
                st_put(po, "ckey", key)
                |> st_put("pname", pname)
                |> st_put("vis", p.visibility)

              ib2 = PhpBeam.Objects.put_object(ib, pref, po2)
              {[pref | acc], ib2}
            end)

          arr =
            refs
            |> Enum.reverse()
            |> Enum.with_index(fn r, idx -> {idx, r} end)
            |> PArray.from_pairs()

          {:ok, {{:array, arr}, obj}, i2}
        end),
        fn_native_rc("getconstants", fn obj, _args, i ->
          key = ckey_of(obj)

          consts =
            chain(i, key)
            |> Enum.reverse()
            |> Enum.flat_map(fn k ->
              case Table.get_class(i, k) do
                %{consts: cs} -> Map.to_list(cs)
                _ -> []
              end
            end)

          arr =
            PArray.from_pairs(Enum.map(consts, fn {n, v} -> {to_string(n), v} end))

          {:ok, {{:array, arr}, obj}, i}
        end),
        fn_native_rc("hasconstant", fn obj, args, i ->
          key = ckey_of(obj)
          cname = dt_s(Enum.at(args, 0, {:string, ""}))

          found =
            chain(i, key)
            |> Enum.any?(fn k ->
              case Table.get_class(i, k) do
                %{consts: cs} -> Map.has_key?(cs, cname)
                _ -> false
              end
            end)

          {:ok, {{:bool, found}, obj}, i}
        end),
        fn_native_rc("getconstant", fn obj, args, i ->
          key = ckey_of(obj)
          cname = dt_s(Enum.at(args, 0, {:string, ""}))

          val =
            chain(i, key)
            |> Enum.find_value(fn k ->
              case Table.get_class(i, k) do
                %{consts: cs} ->
                  Map.get(cs, cname) || Map.get(cs, String.to_atom(cname))

                _ ->
                  nil
              end
            end)

          case val do
            nil -> throw_ex(i, "Constant " <> cname <> " does not exist")
            v -> {:ok, {v, obj}, i}
          end
        end),
        fn_native_rc("getreflectionconstant", fn obj, args, i ->
          key = ckey_of(obj)
          cname = dt_s(Enum.at(args, 0, {:string, ""}))

          found =
            chain(i, key)
            |> Enum.find_value(fn k ->
              case Table.get_class(i, k) do
                %{consts: cs} ->
                  entry =
                    Enum.find(Map.to_list(cs), fn {n, _} ->
                      to_string(n) == cname
                    end)

                  if entry, do: {k, entry}

                _ ->
                  nil
              end
            end)

          case found do
            {k, {n, v}} ->
              {cref, i2} = Eval.make_instance(i, "reflectionclassconstant")
              co = Eval.get_object(i2, cref)

              co2 =
                st_put(co, "cname", to_string(n)) |> st_put("cval", v) |> st_put("ckey", k)

              i3 = PhpBeam.Objects.put_object(i2, cref, co2)
              {:ok, {cref, obj}, i3}

            nil ->
              throw_ex(i, "Constant " <> cname <> " does not exist")
          end
        end),
        fn_native_rc("getdefaultproperties", fn obj, _args, i ->
          key = ckey_of(obj)

          props =
            chain(i, key)
            |> Enum.reverse()
            |> Enum.flat_map(fn k ->
              case Table.get_class(i, k) do
                %{props: ps} -> Enum.map(ps, fn p -> {p.name, p} end)
                _ -> []
              end
            end)

          arr =
            PArray.from_pairs(
              Enum.flat_map(props, fn {pname, p} ->
                case Map.get(p, :default) do
                  nil -> []
                  :null -> []
                  d -> [{pname, d}]
                end
              end)
            )

          {:ok, {{:array, arr}, obj}, i}
        end)
      ],
      fn m -> {String.downcase(m.name), m} end
    )
  end

  defp fn_native_rc(name, fun) do
    fn_native(name, fn obj, args, i -> fun.(obj, args, i) end)
  end

  defp rc_self(obj), do: {obj, ckey_of(obj)}
end
