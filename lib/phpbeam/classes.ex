defmodule PhpBeam.Classes do
  @moduledoc """
  PHP class model: registration (with trait flattening), method/property
  lookup along the inheritance chain, and the native `Throwable` hierarchy.

  Property/method maps are keyed by lowercased member name; instance props
  keep declaration order for construction and var_dump output.
  """

  alias PhpBeam.{Eval, PArray}

  defstruct name: "",
            kind: :class,
            parent: nil,
            interfaces: [],
            traits: [],
            consts: %{},
            props: [],
            methods: %{},
            abstract?: false,
            final?: false,
            file: ""

  @type t :: %__MODULE__{}
  @type obj :: %{__ref__: pos_integer(), class: binary(), props: PArray.t()}

  @native_method_marker :native

  # ───────────────────────── registration ─────────────────────────

  def register(decl, interp) do
    %{
      name: name,
      kind: kind,
      extends: extends,
      implements: implements,
      consts: consts,
      props: props,
      methods: methods,
      uses: uses,
      modifiers: mods
    } = decl

    key = full_key(name, interp)

    if Map.has_key?(interp.classes, key) do
      {:error, "Cannot declare class #{name} because the name is already in use"}
    else
      parent_key = parent_key(extends, kind, interp)
      iface_keys = Enum.map(implements, &resolve_decl_name(&1, interp))

      missing =
        [parent_key | iface_keys]
        |> Enum.reject(&is_nil/1)
        |> Enum.find(&(not Map.has_key?(interp.classes, &1)))

      if missing do
        {:error, "Class \"#{missing}\" not found"}
      else
        class =
          build_class(
            name,
            kind,
            key,
            parent_key,
            iface_keys,
            consts,
            props,
            methods,
            mods,
            interp
          )

        case apply_traits(class, uses, interp) do
          {:ok, class2} ->
            interp2 = %{interp | classes: Map.put(interp.classes, key, class2)}

            case link_checks(class2, key, interp2) do
              :ok -> {:ok, interp2}
              {:error, msg} -> {:error, msg}
            end

          {:error, msg} ->
            {:error, msg}
        end
      end
    end
  end

  defp build_class(name, kind, key, parent_key, iface_keys, consts, props, methods, mods, interp) do
    consts_map = Map.new(consts, fn {cname, cexpr} -> {cname, Eval.const_fold(cexpr, interp)} end)

    props_list =
      Enum.map(props, fn {vis, static?, pname, default} ->
        %{
          name: String.downcase(pname),
          display: pname,
          visibility: vis,
          static?: static?,
          default: Eval.const_fold(default || :null, interp)
        }
      end)

    methods_map =
      Map.new(methods, fn {vis, static?, abstract?, final?, _by_ref?, mname, params, body, line} ->
        {String.downcase(mname),
         %{
           name: mname,
           visibility: vis,
           static?: static?,
           abstract?: abstract?,
           final?: final?,
           params: params,
           body: body,
           class: key,
           line: line,
           native: nil
         }}
      end)

    %__MODULE__{
      name: display_name(name, interp),
      kind: kind,
      parent: parent_key,
      interfaces: iface_keys,
      traits: [],
      consts: consts_map,
      props: props_list,
      methods: methods_map,
      abstract?: "abstract" in mods,
      final?: "final" in mods,
      # php attributes method-declared errors (ArgumentCountError) to the
      # file containing the class declaration
      file: decl_file(interp)
    }
  end

  defp decl_file(%{file_stack: [f | _]}), do: f
  defp decl_file(_), do: "Command line code"

  defp full_key(name, interp) do
    if interp.ns == [] do
      String.downcase(name)
    else
      (interp.ns ++ [name]) |> Enum.join("\\") |> String.downcase()
    end
  end

  defp display_name(name, interp) do
    if interp.ns == [], do: name, else: Enum.join(interp.ns ++ [name], "\\")
  end

  defp parent_key([], _kind, _interp), do: nil

  defp parent_key([parts], kind, interp) when kind in [:class, :trait],
    do: resolve_decl_name(parts, interp)

  defp parent_key(_parts, _kind, _interp), do: nil

  defp resolve_decl_name({parts, fq}, interp) do
    {:ok, key} = Eval.resolve_class_key({:cname, fq, parts}, nil, interp)
    key
  end

  defp resolve_decl_name(parts, interp) do
    {:ok, key} = Eval.resolve_class_key({:cname, false, parts}, nil, interp)
    key
  end

  # ───────────────────────── traits ─────────────────────────

  # each `use` statement contributes one {trait_names, adaptions} pair
  defp apply_traits(class, uses_list, interp) when is_list(uses_list) do
    Enum.reduce(uses_list, {:ok, class}, fn
      {traits, adaptions}, {:ok, acc} ->
        apply_traits_pair(acc, traits, adaptions, interp)

      _pair, error ->
        error
    end)
  end

  defp apply_traits(class, nil, _interp), do: {:ok, class}

  defp apply_traits_pair(class, trait_names, adaptions, interp) do
    trait_keys = Enum.map(trait_names, &resolve_decl_name(&1, interp))

    bad =
      Enum.find(trait_keys, fn key ->
        case Map.get(interp.classes, key) do
          %{kind: :trait} -> false
          _ -> true
        end
      end)

    if bad do
      {:error, "Trait \"#{bad}\" not found"}
    else
      merged = merge_trait_methods(class, trait_keys, adaptions, interp)
      {:ok, %{class | methods: merged, traits: trait_keys}}
    end
  end

  defp merge_trait_methods(class, trait_keys, adaptions, interp) do
    candidates =
      Enum.flat_map(trait_keys, fn tkey ->
        trait = Map.get(interp.classes, tkey)
        Enum.map(trait.methods, fn {mname, m} -> {mname, m, tkey} end)
      end)

    # insteadof: method from `from`-trait wins; excluded traits' versions drop
    kept =
      Enum.reject(candidates, fn {mname, _m, tkey} ->
        Enum.any?(adaptions, fn
          {:insteadof, from, method, excluded} ->
            String.downcase(method) == mname and
              resolve_decl_name(from, interp) == tkey and
              false

          _ ->
            false
        end) or insteadof_excluded?(mname, tkey, adaptions, interp)
      end)

    # as: alias / re-visibility
    renamed =
      Enum.map(kept, fn {mname, m, tkey} ->
        hit =
          Enum.find(adaptions, fn
            {:as, from, orig, _alias, _vis} ->
              String.downcase(orig) == mname and
                (from == nil or resolve_decl_name(from, interp) == tkey)

            _ ->
              false
          end)

        case hit do
          {:as, _from, _orig, alias_name, vis} when alias_name != nil ->
            {String.downcase(alias_name),
             %{m | name: alias_name, visibility: vis || m.visibility}, tkey}

          {:as, _from, _orig, _alias, vis} ->
            {mname, %{m | visibility: vis || m.visibility}, tkey}

          nil ->
            {mname, m, tkey}
        end
      end)

    Enum.reduce(renamed, class.methods, fn {mname, m, _tkey}, acc ->
      if Map.has_key?(class.methods, mname) or Map.has_key?(acc, mname) do
        acc
      else
        Map.put(acc, mname, m)
      end
    end)
  end

  defp insteadof_excluded?(mname, tkey, adaptions, interp) do
    Enum.any?(adaptions, fn
      {:insteadof, from, method, excluded} ->
        String.downcase(method) == mname and
          tkey in Enum.map(excluded, &resolve_decl_name(&1, interp)) and
          resolve_decl_name(from, interp) != tkey

      _ ->
        false
    end)
  end

  # ───────────────────────── lookup ─────────────────────────

  def get_class(interp, key), do: Map.get(interp.classes, key)

  # returns the method map or nil
  # ─────────────── inheritance strictness (link-time fatals) ───────────────

  defp link_checks(class, key, interp) do
    chain = parent_chain(interp, class.parent)

    with :ok <- check_prop_overrides(class, chain, interp),
         :ok <- check_method_overrides(class, chain, interp),
         :ok <- check_abstract_methods(class, key, chain, interp) do
      :ok
    end
  end

  # ancestors of `key` INCLUDING itself, nearest first
  defp parent_chain(_interp, nil), do: []

  defp parent_chain(interp, key) do
    case interp.classes[key] do
      %{parent: p} -> [key | parent_chain(interp, p)]
      _ -> [key]
    end
  end

  defp check_prop_overrides(class, chain, interp) do
    chain
    |> Enum.find_value(fn a_key ->
      ancestor = interp.classes[a_key]

      Enum.find_value(ancestor.props, fn p ->
        if p.visibility == :private do
          nil
        else
          case Enum.find(class.props, &(&1.name == p.name)) do
            nil ->
              nil

            cp ->
              cond do
                p.static? != cp.static? ->
                  ours = if p.static?, do: "static", else: "non static"
                  theirs = if p.static?, do: "non static", else: "static"

                  "Cannot redeclare #{ours} #{ancestor.name}::$#{p.display} as #{theirs} " <>
                    "#{class.name}::$#{cp.display}"

                vis_rank(cp.visibility) < vis_rank(p.visibility) ->
                  "Access level to #{class.name}::$#{cp.display} must be #{p.visibility}" <>
                    " (as in class #{ancestor.name})"

                true ->
                  nil
              end
          end
        end
      end)
    end)
    |> case do
      nil -> :ok
      msg -> {:error, msg}
    end
  end

  defp check_method_overrides(class, chain, interp) do
    (chain ++ class.interfaces)
    |> Enum.find_value(fn a_key ->
      ancestor = interp.classes[a_key]
      iface? = ancestor.kind == :interface

      Enum.find_value(ancestor.methods, fn {lname, pm} ->
        if pm.visibility == :private and not iface? do
          nil
        else
          case Map.get(class.methods, lname) do
            nil ->
              nil

            cm ->
              cond do
                pm.final? ->
                  "Cannot override final method #{ancestor.name}::#{pm.name}()"

                pm.static? != cm.static? ->
                  if pm.static?,
                    do:
                      "Cannot make static method #{ancestor.name}::#{pm.name}() non static" <>
                        " in class #{class.name}",
                    else:
                      "Cannot make non static method #{ancestor.name}::#{pm.name}() static" <>
                        " in class #{class.name}"

                vis_rank(cm.visibility) < vis_rank(pm.visibility) and pm.name != "__construct" ->
                  "Access level to #{class.name}::#{cm.name}() must be #{pm.visibility}" <>
                    " (as in class #{ancestor.name})"

                pm.name != "__construct" and not params_compat?(pm.params, cm.params) ->
                  "Declaration of #{class.name}::#{cm.name}(#{param_sig(cm.params)})" <>
                    " must be compatible with #{ancestor.name}::#{pm.name}(#{param_sig(pm.params)})"

                true ->
                  nil
              end
          end
        end
      end)
    end)
    |> case do
      nil -> :ok
      msg -> {:error, msg}
    end
  end

  defp check_abstract_methods(class, key, chain, interp) do
    if class.abstract? do
      :ok
    else
      ancestors = chain ++ class.interfaces

      names =
        [class.methods | Enum.map(ancestors, &interp.classes[&1].methods)]
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()

      missing =
        Enum.flat_map(names, fn lname ->
          case chain_lookup(interp, [key | chain], lname) do
            {%{abstract?: true} = m, _owner} ->
              [{owner_name(interp, m.class), m.name}]

            {_m, _owner} ->
              []

            nil ->
              case Enum.find(class.interfaces, fn ik ->
                     Map.has_key?(interp.classes[ik].methods, lname)
                   end) do
                nil -> []
                ik -> [{owner_name(interp, ik), interp.classes[ik].methods[lname].name}]
              end
          end
        end)

      case missing do
        [] ->
          :ok

        missing ->
          count = length(missing)

          noun = if count == 1, do: "1 abstract method", else: "#{count} abstract methods"

          list =
            missing |> Enum.map(fn {owner, name} -> "#{owner}::#{name}" end) |> Enum.join(", ")

          {:error,
           "Class #{class.name} contains #{noun} and must therefore be declared abstract" <>
             " or implement the remaining methods (#{list})"}
      end
    end
  end

  defp chain_lookup(interp, [k | rest], lname) do
    case interp.classes[k] do
      %{methods: methods} = c ->
        case Map.fetch(methods, lname) do
          {:ok, m} -> {m, c}
          :error -> chain_lookup(interp, rest, lname)
        end

      _ ->
        chain_lookup(interp, rest, lname)
    end
  end

  defp chain_lookup(_interp, [], _lname), do: nil

  defp owner_name(interp, key) do
    case interp.classes[key] do
      %{name: n} -> n
      _ -> key
    end
  end

  defp vis_rank(:private), do: 0
  defp vis_rank(:protected), do: 1
  defp vis_rank(:public), do: 2

  # param tuples: {:param, name, type, default, by_ref?, variadic?}
  defp params_compat?(pp, cp) do
    p_var? = Enum.any?(pp, &match?({:param, _, _, _, _, true}, &1))
    c_var? = Enum.any?(cp, &match?({:param, _, _, _, _, true}, &1))

    cond do
      not c_var? and length(cp) < length(pp) ->
        false

      required_count(cp) > required_count(pp) ->
        false

      true ->
        Enum.zip(pp, cp)
        |> Enum.all?(fn {{:param, _, pt, _, pr, _}, {:param, _, ct, _, cr, _}} ->
          pr == cr and (ct == nil or ct == pt)
        end)
    end
  end

  defp required_count(params),
    do: Enum.count(params, &match?({:param, _, _, nil, _, false}, &1))

  defp param_sig(params) do
    params
    |> Enum.map(fn {:param, name, type, default, by_ref?, variadic?} ->
      t = if type, do: type <> " ", else: ""
      r = if by_ref?, do: "&", else: ""
      d = if variadic?, do: "...", else: ""
      def_ = if default != nil, do: " = " <> default_sig(default), else: ""
      t <> r <> d <> "$" <> name <> def_
    end)
    |> Enum.join(", ")
  end

  defp default_sig({:int, n}), do: Integer.to_string(n)
  defp default_sig({:float, f}), do: PhpBeam.Value.float_to_string(f)
  defp default_sig({:string, s}), do: "\"#{s}\""
  defp default_sig({:bool, true}), do: "true"
  defp default_sig({:bool, false}), do: "false"
  defp default_sig(:null), do: "null"
  defp default_sig(_), do: "unknown"

  def find_method(interp, key, name) do
    case find_up(interp, key, String.downcase(name), fn class ->
           Map.fetch(class.methods, String.downcase(name))
         end) do
      {:ok, m} -> m
      _ -> nil
    end
  end

  def find_prop(interp, key, name) do
    lname = String.downcase(name)

    find_up(interp, key, lname, fn class ->
      class.props |> Enum.find(&(&1.name == lname)) |> then(&if(&1, do: {:ok, &1}, else: :error))
    end)
  end

  def find_const(interp, key, name) do
    find_up(interp, key, name, &Map.fetch(&1.consts, name), interfaces: true)
  end

  defp find_up(interp, key, target, fetch, opts \\ []) do
    do_find_up(interp, key, fetch, opts, MapSet.new())
  end

  defp do_find_up(interp, nil, _fetch, _opts, _seen), do: nil

  defp do_find_up(interp, key, fetch, opts, seen) do
    case Map.get(interp.classes, key) do
      nil ->
        nil

      class ->
        case fetch.(class) do
          {:ok, _} = ok ->
            ok

          :error ->
            next =
              [class.parent] ++
                if(opts[:interfaces], do: class.interfaces, else: [])

            next
            |> Enum.reject(&is_nil(&1))
            |> Enum.reject(&MapSet.member?(seen, &1))
            |> Enum.find_value(fn k ->
              do_find_up(interp, k, fetch, opts, MapSet.put(seen, k))
            end)
        end
    end
  end

  def is_a?(interp, key, target_key) do
    key == target_key or chain_has?(interp, key, target_key, MapSet.new())
  end

  defp chain_has?(interp, nil, _target, _seen), do: false

  defp chain_has?(interp, key, target, seen) do
    case Map.get(interp.classes, key) do
      nil ->
        false

      class ->
        class.parent == target or target in class.interfaces or
          Enum.any?([class.parent | class.interfaces], fn k ->
            k != nil and not MapSet.member?(seen, k) and
              chain_has?(interp, k, target, MapSet.put(seen, k))
          end)
    end
  end

  def instance_of?(interp, {:object, %{class: key}}, target_key),
    do: is_a?(interp, key, target_key)

  def instance_of?(_interp, _, _target_key), do: false

  # ───────────────────────── instantiation ─────────────────────────

  # returns the object MAP (the {:object, id} handle wraps it in the registry)
  def instantiate(interp, key, obj_id) do
    defaults = instance_defaults(interp, key)
    %{__ref__: obj_id, class: key, props: PArray.from_pairs(defaults)}
  end

  defp instance_defaults(interp, key) do
    case Map.get(interp.classes, key) do
      nil ->
        []

      class ->
        own =
          class.props
          |> Enum.reject(& &1.static?)
          |> Enum.map(&{{:string, &1.display}, &1.default})

        own ++ instance_defaults(interp, class.parent)
    end
  end

  # ───────────────────────── native exception hierarchy ─────────────────────────

  @doc "Class map for Throwable and friends; methods are native closures."
  def native_classes do
    base = %{
      "throwable" => native_class("Throwable", nil, []),
      "exception" => native_class("Exception", "throwable", []),
      "error" => native_class("Error", "throwable", []),
      "typeerror" => native_class("TypeError", "error", []),
      "argumentcounterror" => native_class("ArgumentCountError", "typeerror", []),
      "divisionbyzeroerror" => native_class("DivisionByZeroError", "arithmeticerror", []),
      "arithmeticerror" => native_class("ArithmeticError", "error", []),
      "valueerror" => native_class("ValueError", "error", []),
      "unhandledmatcherror" => native_class("UnhandledMatchError", "error", []),
      "errorexception" => native_class("ErrorException", "exception", []),
      "runtimeexception" => native_class("RuntimeException", "exception", []),
      "logicexception" => native_class("LogicException", "exception", []),
      "invalidargumentexception" =>
        native_class("InvalidArgumentException", "logicexception", []),
      "outofboundsexception" => native_class("OutOfBoundsException", "runtimeexception", []),
      "rangeexception" => native_class("RangeException", "runtimeexception", []),
      "domainexception" => native_class("DomainException", "logicexception", []),
      "lengthexception" => native_class("LengthException", "logicexception", []),
      "outofrangeexception" => native_class("OutOfRangeException", "logicexception", []),
      "underflowexception" => native_class("UnderflowException", "logicexception", []),
      "unexpectedvalueexception" =>
        native_class("UnexpectedValueException", "runtimeexception", []),
      "badfunctioncallexception" =>
        native_class("BadFunctionCallException", "logicexception", []),
      "badmethodcallexception" =>
        native_class("BadMethodCallException", "badfunctioncallexception", [])
    }

    members = native_throwable_methods()

    ifaces =
      Map.new(
        ~w(countable arrayaccess stringable jsonserializable iterator aggregate traversable),
        &{&1, native_iface(String.capitalize(&1))}
      )

    base
    |> Enum.reduce(base, fn {key, class}, acc ->
      if key == "throwable" do
        acc
      else
        put_in(acc, [key, Access.key!(:methods)], members)
      end
    end)
    |> Map.merge(ifaces)
  end

  defp native_iface(name) do
    %__MODULE__{
      name: name,
      kind: :interface,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{}
    }
  end

  defp native_class(name, parent, ifaces) do
    %__MODULE__{
      name: name,
      kind: :class,
      parent: parent,
      interfaces: ifaces,
      consts: %{},
      props: exception_props(),
      methods: %{},
      abstract?: name == "Throwable"
    }
  end

  defp exception_props do
    [
      %{
        name: "message",
        display: "message",
        visibility: :protected,
        static?: false,
        default: {:string, ""}
      },
      %{
        name: "code",
        display: "code",
        visibility: :protected,
        static?: false,
        default: {:int, 0}
      },
      %{
        name: "file",
        display: "file",
        visibility: :protected,
        static?: false,
        default: {:string, "php"}
      },
      %{
        name: "line",
        display: "line",
        visibility: :protected,
        static?: false,
        default: {:int, 0}
      },
      %{
        name: "previous",
        display: "previous",
        visibility: :protected,
        static?: false,
        default: :null
      }
    ]
  end

  # native methods run as fn(obj, args, interp) -> {:ok, {value, obj2}, interp}
  defp native_throwable_methods do
    %{
      "__construct" =>
        native_fn("__construct", fn obj, args, interp ->
          message = Enum.at(args, 0, {:string, ""})
          code = Enum.at(args, 1, {:int, 0})
          previous = Enum.at(args, 2, :null)

          props =
            obj.props
            |> native_put("message", message)
            |> native_put("code", code)
            |> native_put("previous", previous)

          {:ok, {:null, %{obj | props: props}}, interp}
        end),
      "getmessage" =>
        native_fn("getMessage", fn obj, _args, interp ->
          {:ok, {native_get(obj, "message"), obj}, interp}
        end),
      "getcode" =>
        native_fn("getCode", fn obj, _args, interp ->
          {:ok, {native_get(obj, "code"), obj}, interp}
        end),
      "getfile" =>
        native_fn("getFile", fn obj, _args, interp ->
          {:ok, {native_get(obj, "file"), obj}, interp}
        end),
      "getline" =>
        native_fn("getLine", fn obj, _args, interp ->
          {:ok, {native_get(obj, "line"), obj}, interp}
        end),
      "getprevious" =>
        native_fn("getPrevious", fn obj, _args, interp ->
          {:ok, {native_get(obj, "previous"), obj}, interp}
        end),
      "gettrace" =>
        native_fn("getTrace", fn obj, _args, interp ->
          {:ok, {{:array, PArray.new()}, obj}, interp}
        end),
      "gettraceasstring" =>
        native_fn("getTraceAsString", fn obj, _args, interp ->
          {:ok, {{:string, "#0 {main}"}, obj}, interp}
        end),
      "__tostring" =>
        native_fn("__toString", fn obj, _args, interp ->
          cls = Map.get(interp.classes, obj.class)
          name = if cls, do: cls.name, else: obj.class
          msg = Eval.php_to_string(native_get(obj, "message"))
          {:ok, {{:string, "exception '#{name}' with message '#{msg}'"}, obj}, interp}
        end)
    }
  end

  defp native_fn(name, fun) do
    %{
      name: name,
      visibility: :public,
      static?: false,
      abstract?: false,
      final?: false,
      params: [],
      body: [],
      class: nil,
      native: {@native_method_marker, fun}
    }
  end

  defp native_put(props, name, value) do
    case PArray.put(props, {:string, name}, value) do
      {:ok, p2} -> p2
      _ -> props
    end
  end

  @doc "Class display name + message for a thrown exception object"
  def exception_info(interp, {:object, id}) do
    case Map.get(interp.objects, id) do
      nil ->
        {"Exception", ""}

      %{class: cls} = obj ->
        name =
          case get_class(interp, cls) do
            %{name: n} -> n
            _ -> cls
          end

        {name, Eval.php_to_string(native_get(obj, "message"))}
    end
  end

  defp native_get(obj, name), do: PArray.get(obj.props, {:string, name}, :null)
end
