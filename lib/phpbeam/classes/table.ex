defmodule PhpBeam.Classes.Table do
  @moduledoc """
  PHP class model: registration (with trait flattening), method/property
  lookup along the inheritance chain, and the native `Throwable` hierarchy.

  Property/method maps are keyed by lowercased member name; instance props
  keep declaration order for construction and var_dump output.
  """

  alias PhpBeam.{Env, Eval, Interp, PArray}

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
            file: "",
            # declaring-file scope: method bodies resolve unqualified names and
            # use-aliases against these (php binds them at compile time)
            ns: [],
            uses: %{},
            # enum: declaration-ordered [{case_name, object_ref}]
            enum_cases: [],
            backed?: false,
            # source modifiers (["readonly", ...]) for readonly-class checks
            modifiers: [],
            # closing-brace line: php attributes early-binding fatals here
            end_line: 0

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
      parent_key0 = parent_key(extends, kind, interp)
      iface_keys0 = Enum.map(implements, &resolve_decl_name(&1, interp))

      # php autoloads missing parents/interfaces before the link checks —
      # WpOrg\Requests\Hooks extends parents declared in sibling files
      {parent_key, iface_keys, interp} =
        autoload_missing_links(interp, parent_key0, iface_keys0, extends, implements)

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
            interp,
            decl[:end_line] || 0
          )

        case apply_traits(class, uses, interp) do
          {:ok, class2, it} ->
            interp2 = %{it | classes: Map.put(it.classes, key, class2)}
            interp2 = warn_magic_methods(class2, interp2)

            case link_checks(class2, key, interp2) do
              :ok -> {:ok, interp2}
              {:error, _msg, _line} = err -> err
              {:error, msg} -> {:error, msg}
            end

          {:error, msg} ->
            {:error, msg}
        end
      end
    end
  end

  defp build_class(
         name,
         kind,
         key,
         parent_key,
         iface_keys,
         consts,
         props,
         methods,
         mods,
         interp,
         end_line
       ) do
    # php allows forward refs and self::CONST in const expressions (they
    # resolve with full class scope) — non-literal folds defer to the AST and
    # evaluate lazily on first access
    consts_map =
      Map.new(consts, fn {cname, cexpr} ->
        case Eval.const_fold(cexpr, interp, key) do
          {:ok, v} -> {cname, v}
          :defer -> {cname, {:const_ast, cexpr, key}}
        end
      end)

    # constructor property promotion: `__construct(private int $x = 1)`
    # desugars to a declared prop + a leading `$this->x = $x;` assignment;
    # promoted props are collected from the RAW method list first — the
    # desugar strips the {:param_promoted, ...} markers
    props =
      props ++
        Enum.flat_map(methods, fn
          {_, _, _, _, _, "__construct", params, _, _} ->
            Enum.map(params, fn
              {:param_promoted, pvis, ro?, name, _t, d, _br, _var} ->
                vis = if pvis in [:public, :protected, :private], do: pvis, else: :public
                {vis, false, ro?, name, d || :null, true}

              _ ->
                nil
            end)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end)

    props_list =
      Enum.map(props, fn
        {vis, static?, ro?, pname, default, promoted?} ->
          %{
            name: String.downcase(pname),
            display: pname,
            visibility: vis,
            static?: static?,
            readonly?: ro?,
            promoted?: promoted?,
            default:
              case Eval.const_fold(default || :null, interp, key) do
                {:ok, v} -> v
                :defer -> :null
              end
          }

        {vis, static?, ro?, pname, default} ->
          %{
            name: String.downcase(pname),
            display: pname,
            visibility: vis,
            static?: static?,
            readonly?: ro?,
            promoted?: false,
            default:
              case Eval.const_fold(default || :null, interp, key) do
                {:ok, v} -> v
                :defer -> :null
              end
          }
      end)

    methods =
      Enum.map(methods, fn
        {vis, st?, ab?, fi?, br?, "__construct", params, body, line} = m ->
          {promoted, plain} =
            Enum.split_with(params, &match?({:param_promoted, _, _, _, _, _, _, _}, &1))

          if promoted == [] do
            m
          else
            body_line = line || 1

            assigns =
              Enum.map(promoted, fn {:param_promoted, _pvis, _ro, name, _t, _d, _br, _var} ->
                {:stmt_line, body_line,
                 {:expr_stmt, {:assign, {:prop, {:var, "this"}, {:lit_name, name}}, {:var, name}}}}
              end)

            # php keeps DECLARATION ORDER — promoted params stay where the
            # author wrote them ($a, private int $mode → [$a, $mode], NOT
            # promoted-first; probed: swapping reorders positional binding)
            new_params =
              Enum.map(params, fn
                {:param_promoted, _pvis, _ro, name, t, d, br, var} ->
                  {:param, name, t, d, br, var}

                p ->
                  p
              end)

            {vis, st?, ab?, fi?, br?, "__construct", new_params, assigns ++ body, line}
          end

        m ->
          m
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
           gen?: PhpBeam.Ast.has_yield?(body),
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
      file: decl_file(interp),
      ns: interp.ns,
      uses: interp.uses,
      modifiers: mods,
      end_line: end_line
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

  # runs the spl autoloaders for unresolved parents/interfaces (php semantics)
  defp autoload_missing_links(interp, parent_key, iface_keys, extends, implements) do
    needs =
      [parent_key | iface_keys]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&Map.has_key?(interp.classes, &1))

    if needs == [] or interp.autoload_fns == [] do
      {parent_key, iface_keys, interp}
    else
      displays = Enum.map(extends ++ implements, &display_decl(&1, interp))

      all = [parent_key | iface_keys] |> Enum.reject(&is_nil/1)
      display_for = Map.new(Enum.zip(all, displays ++ all))

      interp2 =
        Enum.reduce(needs, interp, fn k, it ->
          {_, it2} = Eval.fetch_class(it, k, Map.get(display_for, k, k))
          it2
        end)

      {parent_key, iface_keys, interp2}
    end
  end

  # fully-qualified display name (aliases applied, ns-prefixed, case kept) —
  # what php hands to autoloaders
  defp display_decl({parts, _fq}, interp) when is_list(parts),
    do: display_decl(parts, interp)

  defp display_decl(parts, interp) when is_list(parts) do
    first = hd(parts)
    rest = tl(parts)

    cond do
      alias_disp = Map.get(interp.uses.normal, String.downcase(first)) ->
        Enum.join([alias_disp | rest], "\\")

      interp.ns != [] and rest == [] ->
        Enum.join(interp.ns ++ parts, "\\")

      true ->
        Enum.join(parts, "\\")
    end
  end

  # non-name decl shapes (dynamic expressions): NEVER inspect unbounded —
  # autoload dispatch renders this per class-load and a giant AST here
  # pins the CPU in Inspect.Algebra for minutes
  defp display_decl(other, _interp), do: inspect(other, printable_limit: 120)

  @doc "Public namespaced-key lookup for dynamically declared classes (anonymous classes)"
  def full_key_of(name, interp), do: full_key(name, interp)

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
    Enum.reduce(uses_list, {:ok, class, interp}, fn
      {traits, adaptions}, {:ok, acc, it} ->
        apply_traits_pair(acc, traits, adaptions, it)

      _pair, error ->
        error
    end)
  end

  defp apply_traits(class, nil, interp), do: {:ok, class, interp}

  defp apply_traits_pair(class, trait_names, adaptions, interp) do
    trait_keys = Enum.map(trait_names, &resolve_decl_name(&1, interp))

    # php autoloads used traits (HookDispatcher lives in a sibling file)
    interp =
      Enum.reduce(trait_keys, interp, fn key, it ->
        case Map.get(it.classes, key) do
          %{kind: :trait} ->
            it

          _ ->
            display =
              trait_names
              |> Enum.find(fn parts -> resolve_decl_name(parts, it) == key end)
              |> then(&display_decl(&1, it))

            {_, it2} = Eval.fetch_class(it, key, display)
            it2
        end
      end)

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
      # php merges trait PROPERTIES into the using class too (Carbon's
      # Options::$localMacros must read as declared-null from $this — NOT
      # fall through to __get). Class's own props win; among traits the
      # first declarer wins; same-name re-declaration is idempotent.
      merged_props =
        (class.props || []) ++
          Enum.flat_map(trait_keys, fn tkey ->
            case Map.get(interp.classes, tkey) do
              %{props: props} when is_list(props) -> props
              _ -> []
            end
          end)
        |> Enum.uniq_by(fn p -> String.downcase(p.name) end)

      # thread the trait-loaded interp back: link_checks' signature
      # compatibility resolves types against the DECLARING class (the trait)
      # — those classes must be visible
      {:ok, %{class | methods: merged, props: merged_props, traits: trait_keys}, interp}
    end
  end

  defp merge_trait_methods(class, trait_keys, adaptions, interp) do
    candidates =
      Enum.flat_map(trait_keys, fn tkey ->
        trait = Map.get(interp.classes, tkey)
        # keep the TRAIT as declaring class: php compiled the signature in
        # the trait file's use-alias context (DateInterval resolves GLOBAL
        # there even when the using class lacks the import)
        Enum.map(trait.methods, fn {mname, m} -> {mname, %{m | class: tkey}, tkey} end)
      end)

    # insteadof: method from `from`-trait wins; excluded traits' versions drop
    # from the ORIGINAL slot only — an `as` alias may still target them (php:
    # `TB::f as fB` adds fB even though TB::f lost the f-slot to TA::f)
    kept =
      Enum.reject(candidates, fn {mname, _m, tkey} ->
        insteadof_excluded?(mname, tkey, adaptions, interp)
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
            am = %{m | name: alias_name, visibility: vis || m.visibility}
            {mname, m, String.downcase(alias_name), am}

          {:as, _from, _orig, _alias, vis} ->
            {mname, %{m | visibility: vis || m.visibility}, tkey}

          nil ->
            {mname, m, tkey}
        end
      end)

    # php: `m as x` ADDS an alias while keeping m accessible (only
    # insteadof removes); entries carry the originals alongside renames
    acc0 =
      Enum.reduce(renamed, class.methods, fn entry, acc ->
        case entry do
          {mname, m, _tkey} ->
            if Map.has_key?(class.methods, mname) or Map.has_key?(acc, mname) do
              acc
            else
              Map.put(acc, mname, m)
            end

          {mname, m, alias_name, am} ->
            acc2 =
              if Map.has_key?(class.methods, mname) or Map.has_key?(acc, mname) do
                acc
              else
                Map.put(acc, mname, m)
              end

            if Map.has_key?(class.methods, alias_name) or Map.has_key?(acc2, alias_name) do
              acc2
            else
              Map.put(acc2, alias_name, am)
            end
        end
      end)

    # aliases whose SOURCE was insteadof-excluded: resolve against the full
    # candidate set (they never entered `kept`/`renamed`) — enter under the
    # alias name only
    excluded_aliases =
      for {:as, from, orig, alias_name, vis} <- adaptions,
          alias_name != nil,
          {mname, m, tkey} <- candidates,
          String.downcase(orig) == mname,
          from != nil and resolve_decl_name(from, interp) == tkey,
          insteadof_excluded?(mname, tkey, adaptions, interp) do
        {String.downcase(alias_name), %{m | name: alias_name, visibility: vis || m.visibility}}
      end
      |> Enum.uniq_by(&elem(&1, 0))

    merged =
      Enum.reduce(excluded_aliases, acc0, fn {alias_key, am}, acc ->
        if Map.has_key?(class.methods, alias_key) or Map.has_key?(acc, alias_key) do
          acc
        else
          Map.put(acc, alias_key, am)
        end
      end)

    # php compiles trait methods INTO the using class: self::/parent:: inside
    # a flattened method resolve against the USING class's chain — NOT the
    # runtime LSB child (called_class stays Illuminate\Support\Carbon while
    # Carbon\Carbon's ctor must parent:: into DateTime, not re-enter itself)
    own = class_owner_key(class)

    Map.new(merged, fn {k, v} ->
      if Map.has_key?(class.methods, k), do: {k, v}, else: {k, Map.put(v, :owner, own)}
    end)
  end

  defp class_owner_key(%{ns: ns, name: name}) do
    base = if String.contains?(name, "\\"), do: name, else: Enum.join(ns ++ [name], "\\")
    String.downcase(base)
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

  @doc "Declaring class KEY of a property (walks the parent chain), or nil."
  def prop_declarer(interp, key, name) do
    walk_declarer(interp, key, String.downcase(name), MapSet.new())
  end

  @doc "The class key plus all ancestors, nearest first."
  def self_and_ancestors(interp, key) do
    case Map.get(interp.classes, key) do
      %{parent: p} -> [key | self_and_ancestors(interp, p)]
      _ -> [key]
    end
  end

  defp walk_declarer(_interp, nil, _lname, _seen), do: nil

  defp walk_declarer(interp, key, lname, seen) do
    if MapSet.member?(seen, key) do
      nil
    else
      case Map.get(interp.classes, key) do
        %{props: props, parent: p} ->
          if Enum.any?(props, &(&1.name == lname)) do
            key
          else
            walk_declarer(interp, p, lname, MapSet.put(seen, key))
          end

        _ ->
          nil
      end
    end
  end

  # returns the method map or nil
  # ─────────────── inheritance strictness (link-time fatals) ───────────────

  defp link_checks(class, key, interp) do
    chain = parent_chain(interp, class.parent)

    with :ok <- check_method_modifiers(class),
         :ok <- check_interface_access(class),
         :ok <- check_this_param(class),
         :ok <- check_prop_overrides(class, chain, interp),
         :ok <- check_method_overrides(class, chain, interp),
         :ok <- check_abstract_methods(class, key, chain, interp),
         :ok <- check_readonly_props(class) do
      :ok
    else
      # per-check attribution: {:error, msg, line} carries the zend line
      # (child member line); bare errors keep cur_line (class START — the
      # abstract-count convention)
      {:error, _msg, _line} = err -> err
      {:error, msg} -> {:error, msg}
    end
  end

  # zend compile fatals: abstract+final / abstract+static modifiers, and
  # $this as parameter name (interface methods are implicitly abstract)
  defp check_method_modifiers(class) do
    Enum.find_value(class.methods, fn {_k, m} ->
      abstract? = m.abstract? or class.kind == :interface

      cond do
        abstract? and m.final? ->
          {:error, "Cannot use the final modifier on an abstract method", m.line}

        m.static? and m.name == "__construct" ->
          {:error, "Constructor #{class.name}::__construct() cannot be static", m.line}

        true ->
          nil
      end
    end) || :ok
  end

  defp check_interface_access(class) do
    if class.kind == :interface do
      Enum.find_value(class.methods, fn {_k, m} ->
        if m.visibility != :public,
          do:
            {:error, "Access type for interface method #{class.name}::#{m.name}() must be public",
             m.line},
          else: nil
      end) || :ok
    else
      :ok
    end
  end

  defp check_this_param(class) do
    Enum.find_value(class.methods, fn {_k, m} ->
      if Enum.any?(m.params || [], &match?({:param, "this", _, _, _, _}, &1)),
        do: {:error, "Cannot use $this as parameter", m.line},
        else: nil
    end) || :ok
  end

  # magic-method visibility warnings (php emits these at class compile and
  # CONTINUES); register threads the warned interp through
  defp warn_magic_methods(class, interp) do
    needs_public = ~w(__call __get __set __isset __unset __callstatic)

    Enum.reduce(class.methods, interp, fn {_k, m}, acc ->
      lname = String.downcase(m.name)

      acc =
        if lname in needs_public and m.visibility != :public do
          Interp.warn(
            acc,
            "The magic method #{class.name}::#{m.name}() must have public visibility"
          )
        else
          acc
        end

      if lname == "__callstatic" and not m.static? do
        Interp.warn(acc, "The magic method #{class.name}::#{m.name}() must be static")
      else
        acc
      end
    end)
  end

  # php compile-time readonly-prop constraints (both render as bare Fatal
  # errors — the engine_fatal channel matches)
  defp check_readonly_props(class) do
    Enum.find(class.props, fn p -> p.readonly? end)
    |> case do
      nil ->
        :ok

      p ->
        cond do
          p.static? ->
            {:error, "Static property #{class.name}::$#{p.display} cannot be readonly"}

          p.default != :null and p[:promoted?] != true ->
            {:error, "Readonly property #{class.name}::$#{p.display} cannot have default value"}

          true ->
            :ok
        end
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
                    " (as in class #{ancestor.name})" <>
                    if(p.visibility == :public, do: "", else: " or weaker")

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
              # zend attributes inheritance fatals to the CHILD method's
              # declaration line
              cond do
                pm.final? ->
                  {"Cannot override final method #{ancestor.name}::#{pm.name}()", cm.line}

                pm.static? != cm.static? ->
                  if pm.static?,
                    do:
                      {"Cannot make static method #{ancestor.name}::#{pm.name}() non static" <>
                         " in class #{class.name}", cm.line},
                    else:
                      {"Cannot make non static method #{ancestor.name}::#{pm.name}() static" <>
                         " in class #{class.name}", cm.line}

                vis_rank(cm.visibility) < vis_rank(pm.visibility) and pm.name != "__construct" ->
                  {"Access level to #{class.name}::#{cm.name}() must be #{pm.visibility}" <>
                     " (as in class #{ancestor.name})" <>
                     if(pm.visibility == :public, do: "", else: " or weaker"), cm.line}

                pm.name != "__construct" and pm.native == nil and
                    not params_compat?(
                      pm.params,
                      cm.params,
                      interp,
                      interp.classes[cm.class] || class,
                      ancestor
                    ) ->
                  {"Declaration of #{class.name}::#{cm.name}(#{param_sig(cm.params)})" <>
                     " must be compatible with #{ancestor.name}::#{pm.name}(#{param_sig(pm.params)})",
                   cm.line}

                true ->
                  nil
              end
          end
        end
      end)
    end)
    |> case do
      nil -> :ok
      {msg, line} -> {:error, msg, line}
    end
  end

  defp check_abstract_methods(class, key, chain, interp) do
    # php: abstract methods in a TRAIT are requirements on the USING class —
    # the trait itself is never "incomplete" (ParsesLogConfiguration)
    if class.abstract? or class.kind == :trait do
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
  defp params_compat?(pp, cp, interp, class, pclass) do
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
          r = pr == cr and type_eq?(pt, ct, interp, class, pclass)
          pr == cr and type_eq?(pt, ct, interp, class, pclass)
          r
        end)
    end
  end

  # php compares RESOLVED types: an aliased `HttpTransporterInterface` in the
  # child matches the parent's fully-qualified spelling
  # leading-backslash ABSOLUTE form: resolve_type_fq skips ns/alias
  # prefixing for fq names, so the expansion lands as-is. `name` may already
  # carry the full namespaced display — don't re-prefix.
  defp ancestor_key(%{ns: ns, name: name}), do: fq_type_key(ns, name)
  defp child_key(%{ns: ns, name: name}), do: fq_type_key(ns, name)

  defp fq_type_key(ns, name) do
    # `name` may already carry the full namespaced display — don't re-prefix
    base = if String.contains?(name, "\\"), do: name, else: Enum.join(ns ++ [name], "\\")
    "\\" <> base
  end

  defp type_eq?(nil, _ct, _interp, _class, _pclass), do: true

  defp type_eq?(_pt, nil, _interp, _class, _pclass), do: true

  defp type_eq?(pt, ct, _interp, _class, _pclass) when pt == ct, do: true

  defp type_eq?(pt, ct, interp, class, pclass) do
    builtin_types =
      ~w(int float string bool array callable iterable object mixed null false true self static)

    pt_l = String.downcase(pt)
    ct_l = String.downcase(ct)

    cond do
      # `self`/`static` bind to a class: parent's self = the DECLARING
      # (ancestor) class, child's = the child — expand before comparing
      # (php: Some::orElse(Option $e) is compatible with Option::orElse(self $e))
      pt_l in ~w(self static) ->
        type_eq?(ancestor_key(pclass), ct, interp, class, pclass)

      ct_l in ~w(self static) ->
        type_eq?(pt, child_key(class), interp, class, pclass)

      pt_l in builtin_types or ct_l in builtin_types ->
        # builtin spellings (int/integer, bool/boolean) normalize loosely;
        # the child may WIDEN (contravariance): callable -> ?callable is
        # legal, narrowing is not
        cond do
          loose_builtin(pt_l) == loose_builtin(ct_l) -> true
          ct_l == "mixed" -> true
          true -> widen_ok?(pt_l, ct_l)
        end

      true ->
        # class types resolve against their DECLARING class's aliases/ns —
        # `SymfonyRequest` (child alias) meets the parent's `Request` alias
        # as the same FQCN. Unions compare as UNORDERED sets (php ignores
        # member order: float|int|string == string|int|float)
        types_equiv?(pt, ct, interp, pclass, class)
    end
  end

  # the CASED resolution (reflection type names / php-visible spellings —
  # container alias tables are case-sensitive); resolve_type_fq stays
  # lowercased for KEY comparison
  defp resolve_type_cased(t, cls) when is_binary(t) do
    {fq?, t2} =
      if String.starts_with?(t, "\\"), do: {true, String.trim_leading(t, "\\")}, else: {false, t}

    parts = String.split(t2, "\\")

    if length(parts) == 1 and not fq? do
      case cls.uses.normal[String.downcase(t2)] do
        nil ->
          if cls.ns != [],
            do: Enum.join(cls.ns ++ [t2], "\\"),
            else: t2

        full ->
          full
      end
    else
      t2
    end
  end

  defp resolve_type_fq(t, _interp, nil), do: String.downcase(t)

  @builtin_type_names ~w(int float string bool array callable iterable object mixed null false true self static)

  # builtin spellings are NOT class names — ns/alias resolution must not
  # touch them (union members like string|float are not Carbon\string)
  defp resolve_type_fq(t, _interp, _cls) when t in @builtin_type_names,
    do: String.downcase(t)

  defp resolve_type_fq(t, _interp, cls) do
    {fq?, t2} =
      if String.starts_with?(t, "\\"), do: {true, String.trim_leading(t, "\\")}, else: {false, t}

    parts = String.split(t2, "\\")

    if length(parts) == 1 and not fq? do
      lname = String.downcase(t2)

      case cls.uses.normal[lname] do
        nil ->
          if cls.ns != [],
            do: (cls.ns ++ [t2]) |> Enum.join("\\") |> String.downcase(),
            else: lname

        full ->
          String.downcase(full)
      end
    else
      String.downcase(t2)
    end
  end

  # pt (parent) "callable" vs ct (child) "?callable" — widening
  defp widen_ok?("mixed", _ct), do: true

  defp widen_ok?(pt, ct) do
    case {pt, ct} do
      {p, "?" <> p2} -> p == p2
      _ -> false
    end
  end

  # union/intersection types compare as unordered sets; each MEMBER resolves
  # against its declaring class before comparison (a union is not a class
  # name — ns-prefixing the whole string poisons the first member)
  defp types_equiv?(a, b, interp, pclass, class) do
    members =
      fn t, cls ->
        t
        |> String.split("|")
        |> Enum.map(&resolve_type_fq(String.trim(&1), interp, cls))
        |> Enum.sort()
      end

    members.(a, pclass) == members.(b, class)
  end

  defp normalize_type_set(t) do
    t |> String.split("|") |> Enum.map(&String.trim/1) |> Enum.sort()
  end

  defp loose_builtin("integer"), do: "int"
  defp loose_builtin("boolean"), do: "bool"
  defp loose_builtin(b), do: b

  defp seg(t), do: t |> String.split("\\") |> List.last() |> String.downcase()

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

  def find_method(_interp, key, name) when is_nil(key) or is_nil(name), do: nil

  def find_method(interp, key, name) do
    # class maps are IMMUTABLE after registration, so a resolution cache
    # never goes stale (positive AND negative entries; find_method misses
    # are hot too — __call/__callStatic probes)
    case mc_get(key, name) do
      :miss ->
        m =
          case find_up(interp, key, String.downcase(name), fn class ->
                 Map.fetch(class.methods, String.downcase(name))
               end) do
            {:ok, m} -> m
            _ -> nil
          end

        mc_put(key, name, m)
        m

      cached ->
        cached
    end
  end

  @mc_table :phpbeam_method_cache

  # ETS with graceful degradation: if the owning process died (generators!),
  # fall through to the uncached path
  defp mc_get(key, name) do
    ensure_mc()

    try do
      :ets.lookup(@mc_table, {key, name})
    rescue
      _ -> :miss
    else
      [{_, v}] -> v
      [] -> :miss
    end
  end

  defp mc_put(key, name, v) do
    try do
      :ets.insert_new(@mc_table, {{key, name}, v})
    rescue
      _ -> :ok
    end

    :ok
  end

  defp ensure_mc do
    if :ets.whereis(@mc_table) == :undefined do
      try do
        :ets.new(@mc_table, [:named, :public, :set, read_concurrency: true])
      rescue
        _ -> :ok
      end
    else
      :ok
    end
  end

  def find_prop(interp, key, name) do
    lname = String.downcase(name)

    find_up(interp, key, lname, fn class ->
      class.props |> Enum.find(&(&1.name == lname)) |> then(&if(&1, do: {:ok, &1}, else: :error))
    end)
  end

  def find_const(interp, key, name) do
    find_up(
      interp,
      key,
      name,
      fn class ->
        case Map.fetch(class.consts, name) do
          {:ok, _} = ok -> ok
          :error -> enum_const(class, name)
        end
      end,
      interfaces: true
    )
  end

  # enum case access reads like a class const (Suit::Hearts)
  defp enum_const(%{kind: :enum, enum_cases: pairs}, name) do
    case List.keyfind(pairs, name, 0) do
      {^name, ref} -> {:ok, ref}
      nil -> :error
    end
  end

  defp enum_const(_, _), do: :error

  @doc """
  Class-const lookup with lazy folding: `{:const_ast, expr, declaring_key}`
  markers evaluate in the declaring class's scope (self::CONST, forward
  refs) and cache the folded value back. Returns `{:ok, v, interp}` |
  `:error` | nil.
  """
  def find_const_lazy(interp, key, name) do
    fetch =
      fn class ->
        case Map.fetch(class.consts, name) do
          {:ok, _} = ok -> ok
          :error -> enum_const(class, name)
        end
      end

    case find_up(interp, key, name, fetch, interfaces: true) do
      {:ok, {:const_ast, ast, decl}} ->
        {v, i2} = Eval.const_eval(ast, interp, decl)

        cached =
          update_in(i2, [Access.key!(:classes), decl, Access.key!(:consts)], fn consts ->
            Map.put(consts, name, v)
          end)

        {:ok, v, cached}

      {:ok, v} ->
        {:ok, v, interp}

      other ->
        other
    end
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

  # ───────────────────────── native exception hierarchy ─────────────────────────

  @doc "Class map for Throwable and friends; methods are native closures."
  def native_classes do
    base = %{
      "stdclass" => native_stdclass(),
      "closure" => native_closure_class(),
      "weakmap" => native_weakmap_class(),
      "reflectionclass" => patch_reflection_class(native_reflection_class()),
      "reflectionmethod" => patch_reflection_method(native_reflection_method_class()),
      "reflectionparameter" => native_reflection_parameter_class(),
      "reflectionnamedtype" => native_reflection_named_type_class(),
      "reflectionattribute" => native_reflection_attribute_class(),
      "reflectionexception" => native_class("ReflectionException", "runtimeexception", []),
      "mysqli_sql_exception" => native_class("mysqli_sql_exception", "runtimeexception", []),
      "reflectionfunctionabstract" =>
        PhpBeam.Classes.Reflection2.classes()["reflectionfunctionabstract"],
      "reflectionfunction" => PhpBeam.Classes.Reflection2.classes()["reflectionfunction"],
      "reflectionobject" => PhpBeam.Classes.Reflection2.classes()["reflectionobject"],
      "reflectionproperty" => PhpBeam.Classes.Reflection2.classes()["reflectionproperty"],
      "reflectionclassconstant" =>
        PhpBeam.Classes.Reflection2.classes()["reflectionclassconstant"],
      "reflectionuniontype" => PhpBeam.Classes.Reflection2.classes()["reflectionuniontype"],
      "reflectionintersectiontype" =>
        PhpBeam.Classes.Reflection2.classes()["reflectionintersectiontype"],
      "reflectionenum" => PhpBeam.Classes.Reflection2.classes()["reflectionenum"],
      "reflectionenumunitcase" => PhpBeam.Classes.Reflection2.classes()["reflectionenumunitcase"],
      "reflectionenumbackedcase" =>
        PhpBeam.Classes.Reflection2.classes()["reflectionenumbackedcase"],
      "reflectiongenerator" => PhpBeam.Classes.Reflection2.classes()["reflectiongenerator"],
      "arrayobject" => PhpBeam.Classes.Spl.classes()["arrayobject"],
      "gmp" => PhpBeam.Classes.Gmp.classes()["gmp"],
      "roundingmode" => PhpBeam.Classes.NativeEnums.classes()["roundingmode"],
      "ziparchive" => PhpBeam.Classes.Zip.classes()["ziparchive"],
      "phar" => PhpBeam.Classes.PharArchive.classes()["phar"],
      "phardata" => PhpBeam.Classes.PharArchive.classes()["phardata"],
      "pharfileinfo" => PhpBeam.Classes.PharArchive.classes()["pharfileinfo"],
      "pharexception" => PhpBeam.Classes.PharArchive.classes()["pharexception"],
      "socket" => PhpBeam.Builtin.SocketsFns.classes()["socket"],
      "pdo" => PhpBeam.Classes.Pdo.classes()["pdo"],
      "pdostatement" => PhpBeam.Classes.Pdo.classes()["pdostatement"],
      "sqlite3" => PhpBeam.Classes.Sqlite3.classes()["sqlite3"],
      "sqlite3result" => PhpBeam.Classes.Sqlite3.classes()["sqlite3result"],
      "sqlite3stmt" => PhpBeam.Classes.Sqlite3.classes()["sqlite3stmt"],
      "pdoexception" => PhpBeam.Classes.Pdo.classes()["pdoexception"],
      "simplexmlelement" => PhpBeam.Classes.SimpleXml.classes()["simplexmlelement"],
      "domdocument" => PhpBeam.Classes.Dom.classes()["domdocument"],
      "domelement" => PhpBeam.Classes.Dom.classes()["domelement"],
      "domnode" => PhpBeam.Classes.Dom.classes()["domnode"],
      "domtext" => PhpBeam.Classes.Dom.classes()["domtext"],
      "domattr" => PhpBeam.Classes.Dom.classes()["domattr"],
      "domnodelist" => PhpBeam.Classes.Dom.classes()["domnodelist"],
      "domxpath" => PhpBeam.Classes.Dom.classes()["domxpath"],
      "domexception" => PhpBeam.Classes.Dom.classes()["domexception"],
      "domdocumentfragment" => PhpBeam.Classes.Dom.classes()["domdocumentfragment"],
      "xmlparser" => PhpBeam.Builtin.XmlFns.classes()["xmlparser"],
      "ftpconnection" => PhpBeam.Builtin.FtpFns.classes()["ftpconnection"],
      "curlhandle" => PhpBeam.Builtin.CurlFns.classes()["curlhandle"],
      "curlmultihandle" => PhpBeam.Builtin.CurlFns.classes()["curlmultihandle"],
      "curlsharehandle" => PhpBeam.Builtin.CurlFns.classes()["curlsharehandle"],
      "curlfile" => PhpBeam.Builtin.CurlFns.classes()["curlfile"],
      "curlstringfile" => PhpBeam.Builtin.CurlFns.classes()["curlstringfile"],
      "opensslassymmetrickey" => PhpBeam.Builtin.OpensslFns.classes()["opensslassymmetrickey"],
      "opensslcertificate" => PhpBeam.Builtin.OpensslFns.classes()["opensslcertificate"],
      "opensslcertificatesigningrequest" => PhpBeam.Builtin.OpensslFns.classes()["opensslcertificatesigningrequest"],
      "deflatecontext" => PhpBeam.Builtin.ZlibFns.classes()["deflatecontext"],
      "inflatecontext" => PhpBeam.Builtin.ZlibFns.classes()["inflatecontext"],
      "arrayiterator" => PhpBeam.Classes.Spl.classes()["arrayiterator"],
      "spldoublylinkedlist" => PhpBeam.Classes.Spl.classes()["spldoublylinkedlist"],
      "splstack" => PhpBeam.Classes.Spl.classes()["splstack"],
      "splqueue" => PhpBeam.Classes.Spl.classes()["splqueue"],
      "splheap" => PhpBeam.Classes.Spl.classes()["splheap"],
      "splminheap" => PhpBeam.Classes.Spl.classes()["splminheap"],
      "splmaxheap" => PhpBeam.Classes.Spl.classes()["splmaxheap"],
      "splpriorityqueue" => PhpBeam.Classes.Spl.classes()["splpriorityqueue"],
      "splfixedarray" => PhpBeam.Classes.Spl.classes()["splfixedarray"],
      "splobjectstorage" => PhpBeam.Classes.Spl.classes()["splobjectstorage"],
      "splfileinfo" => PhpBeam.Classes.Spl.classes()["splfileinfo"],
      "splfileobject" => PhpBeam.Classes.Spl.classes()["splfileobject"],
      "spltempfileobject" => PhpBeam.Classes.Spl.classes()["spltempfileobject"],
      "splobserver" => PhpBeam.Classes.Spl.classes()["splobserver"],
      "splsubject" => PhpBeam.Classes.Spl.classes()["splsubject"],
      "iteratoriterator" => PhpBeam.Classes.Spl.classes()["iteratoriterator"],
      "filteriterator" => PhpBeam.Classes.Spl.classes()["filteriterator"],
      "directoryiterator" => PhpBeam.Classes.Spl.classes()["directoryiterator"],
      "filesystemiterator" => PhpBeam.Classes.Spl.classes()["filesystemiterator"],
      "recursivedirectoryiterator" => PhpBeam.Classes.Spl.classes()["recursivedirectoryiterator"],
      "globiterator" => PhpBeam.Classes.Spl.classes()["globiterator"],
      "recursiveiteratoriterator" => PhpBeam.Classes.Spl.classes()["recursiveiteratoriterator"],
      "recursiveiterator" => PhpBeam.Classes.Spl.classes()["recursiveiterator"],
      "reflectionfiber" => PhpBeam.Classes.Reflection2.classes()["reflectionfiber"],
      "datetime" => native_datetime_class(),
      "datetimeimmutable" => native_datetimeimmutable_class(),
      "datetimezone" => native_datetimezone_class(),
      "dateinterval" => native_dateinterval_class(),
      "dateperiod" => native_dateperiod_class(),
      "throwable" => native_class("Throwable", nil, []),
      "exception" => native_class("Exception", "throwable", []),
      "error" => native_class("Error", "throwable", []),
      "assertionerror" => native_class("AssertionError", "error", []),
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

    # proper SPL/interface names — the class-name field drives resolution
    # (IteratorAggregate must NOT capitalize to "Aggregate")
    ifaces =
      Map.new(
        [
          {"countable", "Countable", nil},
          {"arrayaccess", "ArrayAccess", nil},
          {"stringable", "Stringable", nil},
          {"jsonserializable", "JsonSerializable", nil},
          # php: Iterator and IteratorAggregate both extend Traversable —
          # is_a?/instanceof walks this edge (Some implements IteratorAggregate
          # IS a Traversable)
          {"iterator", "Iterator", "traversable"},
          {"iteratoraggregate", "IteratorAggregate", "traversable"},
          {"traversable", "Traversable", nil},
          {"serializable", "Serializable", nil},
          {"datetimeinterface", "DateTimeInterface", nil}
        ],
        fn {key, name, parent} -> {key, native_iface(name, parent)} end
      )

    base
    |> Enum.reduce(base, fn {key, _class}, acc ->
      # only the exception hierarchy gets Throwable's methods — stdClass
      # would otherwise inherit its constructor (and its message/code props),
      # and DateTime carries its own native methods
      if key in ~w(throwable stdclass closure weakmap datetime datetimeimmutable datetimezone dateinterval dateperiod generator reflectionclass reflectionmethod reflectionparameter reflectionnamedtype reflectionattribute reflectionfunctionabstract reflectionfunction reflectionobject reflectionproperty reflectionclassconstant reflectionuniontype reflectionintersectiontype reflectionenum reflectionenumunitcase reflectionenumbackedcase reflectiongenerator reflectionfiber arrayobject arrayiterator iteratoriterator filteriterator directoryiterator filesystemiterator recursivedirectoryiterator globiterator recursiveiteratoriterator recursiveiterator spldoublylinkedlist splstack splqueue splheap splminheap splmaxheap splpriorityqueue splfixedarray splobjectstorage splfileinfo splfileobject spltempfileobject splobserver splsubject gmp roundingmode deflatecontext inflatecontext ziparchive phar phardata pharfileinfo pharexception socket ftpconnection sqlite3 sqlite3result sqlite3stmt pdo pdostatement pdoexception simplexmlelement domdocument domelement domnode domtext domattr domnodelist domxpath domexception domdocumentfragment xmlparser curlhandle curlmultihandle curlsharehandle curlfile curlstringfile opensslassymmetrickey opensslcertificate opensslcertificatesigningrequest sessionhandler sessionhandlerinterface) do
        acc
      else
        put_in(acc, [key, Access.key!(:methods)], members)
      end
    end)
    |> Map.merge(ifaces)
    |> Map.put("generator", native_generator_class())
  end

  # minimal native DateTime/DateTimeZone (WP uses format('T') on install)
  defp native_datetimezone_class do
    %__MODULE__{
      name: "DateTimeZone",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{
        "__construct" =>
          native_fn("__construct", fn obj, args, i ->
            name = args |> Enum.at(0, {:string, "UTC"}) |> dt_s()

            valid? =
              PhpBeam.DtZone.valid?(name) or
                match?({:ok, _}, parse_tz_offset(name))

            if valid? do
              {:ok, {:null, dt_put(obj, "name", {:string, name})}, i}
            else
              {oref, i2} =
                Eval.materialize_native(
                  {:native_error, "Exception",
                   "DateTimeZone::__construct(): Unknown or bad timezone (#{name})"},
                  i
                )

              {{:unwind, {:php_throw, oref}}, i2}
            end
          end),
        "getname" =>
          native_fn("getName", fn obj, _args, i ->
            {:ok, {Map.get(native_state(obj), "name", {:string, "UTC"}), obj}, i}
          end),
        "getoffset" =>
          native_fn("getOffset", fn obj, args, i ->
            zname = dt_s(Map.get(native_state(obj), "name", {:string, "UTC"}))

            ts =
              case args do
                [{:object, _} = dt_ref | _] ->
                  dt_obj = Eval.get_object(i, dt_ref)
                  st = native_state(dt_obj)

                  case Map.get(st, "dt") do
                    %PhpBeam.Dt{utc: u} -> u
                    _ -> System.system_time(:second)
                  end

                _ ->
                  System.system_time(:second)
              end

            offset =
              case parse_tz_offset(zname) do
                {:ok, off} ->
                  off

                :error ->
                  case PhpBeam.DtZone.resolve(zname) do
                    {:ok, z} -> PhpBeam.DtZone.offset_at(z, ts) |> elem(0)
                    _ -> 0
                  end
              end

            {:ok, {{:int, offset}, obj}, i}
          end)
      },
      file: ""
    }
  end

  # "+05:30" / "-0500" / "+0530" style offsets
  defp parse_tz_offset(<<?+, rest::binary>>) do
    tz_offset_parts(rest, 1)
  end

  defp parse_tz_offset(<<?-, rest::binary>>) do
    tz_offset_parts(rest, -1)
  end

  defp parse_tz_offset(_), do: :error

  defp tz_offset_parts(rest, sign) do
    case String.split(rest, ":") do
      [h, m] ->
        with {hi, ""} <- Integer.parse(h),
             {mi, ""} <- Integer.parse(m),
             do: {:ok, sign * (hi * 3600 + mi * 60)},
             else: (_ -> :error)

      [<<h::binary-size(2), m::binary-size(2)>>] ->
        {:ok, sign * (String.to_integer(h) * 3600 + String.to_integer(m) * 60)}

      _ ->
        :error
    end
  end

  defp native_datetime_class do
    dt_base_methods("DateTime")
  end

  defp native_datetimeimmutable_class do
    dt_base_methods("DateTimeImmutable")
  end

  # shared engine-backed surface: immutable methods return a NEW instance
  # (php contract), DateTime mutates and returns $this
  defp dt_base_methods(class_name) do
    immutable? = class_name == "DateTimeImmutable"

    # {return_value, interp, obj_to_write_back} — for the mutable case the
    # return is $this; the caller writes the mutated object back
    mut = fn obj, obj_ref, dt, i ->
      if immutable? do
        {oref, i2} = Eval.make_instance(i, String.downcase(class_name))
        clone = Eval.get_object(i2, oref)
        clone2 = native_dt_put(clone, dt)
        {oref, i2, clone2}
      else
        {{:object, obj_ref}, i, native_dt_put(obj, dt)}
      end
    end

    %__MODULE__{
      name: class_name,
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{
        "ATOM" => {:string, "Y-m-d\\TH:i:sP"},
        "COOKIE" => {:string, "l, d-M-Y H:i:s T"},
        "ISO8601" => {:string, "Y-m-d\\TH:i:sO"},
        "RFC822" => {:string, "D, d M y H:i:s O"},
        "RFC850" => {:string, "l, d-M-y H:i:s T"},
        "RFC1036" => {:string, "D, d M y H:i:s O"},
        "RFC1123" => {:string, "D, d M Y H:i:s O"},
        "RFC2822" => {:string, "D, d M Y H:i:s O"},
        "RFC3339" => {:string, "Y-m-d\\TH:i:sP"},
        "RFC3339_EXTENDED" => {:string, "Y-m-d\\TH:i:s.vP"},
        "RSS" => {:string, "D, d M Y H:i:s O"},
        "W3C" => {:string, "Y-m-d\\TH:i:sP"}
      },
      props: [],
      methods:
        %{
          "__construct" =>
            native_fn("__construct", fn obj, args, i ->
              time_s = args |> Enum.at(0, {:string, "now"}) |> dt_s()

              tz_name =
                case args do
                  [_, {:object, _} = zref | _] ->
                    zobj = Eval.get_object(i, zref)
                    dt_s(Map.get(native_state(zobj), "name", {:string, "UTC"}))

                  _ ->
                    Map.get(i.ini, "date.timezone", "UTC")
                    |> case do
                      "" -> "UTC"
                      tz -> tz
                    end
                end

              case PhpBeam.Dt.parse(time_s, tz_name) do
                {:ok, dt} ->
                  dt =
                    if String.starts_with?(time_s, "@") do
                      # php: @epoch keeps +00:00 zone unless a zone arg follows
                      case args do
                        [_, {:object, _} | _] -> %{dt | zone: PhpBeam.Dt.zone_of(tz_name)}
                        _ -> dt
                      end
                    else
                      dt
                    end

                  {:ok, {:null, native_dt_put(obj, dt)}, i}

                :error ->
                  {oref, i2} =
                    Eval.materialize_native(
                      {:native_error, "Exception",
                       "Failed to parse time string (#{time_s}) at position 0 (n): The timezone could not be found in the database"},
                      i
                    )

                  {{:unwind, {:php_throw, oref}}, i2}
              end
            end),
          "format" =>
            native_fn("format", fn obj, args, i ->
              fmt = args |> Enum.at(0, {:string, "U"}) |> dt_s()
              dt = native_dt_get(obj)
              {:ok, {{:string, PhpBeam.Dt.format(dt, fmt)}, obj}, i}
            end),
          "modify" =>
            native_fn("modify", fn obj, args, i ->
              mod = args |> Enum.at(0, {:string, ""}) |> dt_s()
              dt = native_dt_get(obj)

              case PhpBeam.Dt.apply_relative(dt, mod) do
                {:ok, dt2} ->
                  {ret, i2, obj2} = mut.(obj, obj.__ref__, dt2, i)

                  if immutable? do
                    i3 = PhpBeam.Objects.put_object(i2, ret, obj2)
                    {:ok, {ret, obj}, i3}
                  else
                    {:ok, {ret, obj2}, i2}
                  end

                :error ->
                  {oref, i2} =
                    Eval.materialize_native(
                      {:native_error, "Exception",
                       "Failed to parse time string (#{mod}) at position 0 (n): The timezone could not be found in the database"},
                      i
                    )

                  {{:unwind, {:php_throw, oref}}, i2}
              end
            end),
          "gettimestamp" =>
            native_fn("getTimestamp", fn obj, _args, i ->
              {:ok, {{:int, native_dt_get(obj).utc}, obj}, i}
            end),
          "settimestamp" =>
            native_fn("setTimestamp", fn obj, args, i ->
              ts = args |> Enum.at(0, {:int, 0}) |> php_int()
              dt = native_dt_get(obj)
              {ret, i2, obj2} = mut.(obj, obj.__ref__, %{dt | utc: ts, us: 0}, i)
              {:ok, ret, i2, obj2}
            end),
          "gettimezone" =>
            native_fn("getTimezone", fn obj, _args, i ->
              {zref, i2} = Eval.make_instance(i, "datetimezone")
              zobj = Eval.get_object(i2, zref)
              zname = zone_name_of(native_dt_get(obj))
              zobj2 = dt_put(zobj, "name", {:string, zname})
              i3 = PhpBeam.Objects.put_object(i2, zref, zobj2)
              {:ok, {zref, obj}, i3}
            end),
          "settimezone" =>
            native_fn("setTimezone", fn obj, args, i ->
              case args do
                [{:object, _} = zref | _] ->
                  zobj = Eval.get_object(i, zref)
                  zname = dt_s(Map.get(native_state(zobj), "name", {:string, "UTC"}))
                  dt = native_dt_get(obj)

                  {ret, i2, obj2} =
                    mut.(obj, obj.__ref__, %{dt | zone: PhpBeam.Dt.zone_of(zname)}, i)

                  {:ok, ret, i2, obj2}

                _ ->
                  {:ok, :null, i}
              end
            end),
          "add" =>
            native_fn("add", fn obj, args, i ->
              dt = native_dt_get(obj)

              case dt_interval_shift(dt, args, 1, i) do
                {:ok, dt2} ->
                  {ret, i2, obj2} = mut.(obj, obj.__ref__, dt2, i)

                  if immutable? do
                    i3 = PhpBeam.Objects.put_object(i2, ret, obj2)
                    {:ok, {ret, obj}, i3}
                  else
                    {:ok, {ret, obj2}, i2}
                  end

                _ ->
                  {:ok, {:null, obj}, i}
              end
            end),
          "sub" =>
            native_fn("sub", fn obj, args, i ->
              dt = native_dt_get(obj)

              case dt_interval_shift(dt, args, -1, i) do
                {:ok, dt2} ->
                  {ret, i2, obj2} = mut.(obj, obj.__ref__, dt2, i)

                  if immutable? do
                    i3 = PhpBeam.Objects.put_object(i2, ret, obj2)
                    {:ok, {ret, obj}, i3}
                  else
                    {:ok, {ret, obj2}, i2}
                  end

                _ ->
                  {:ok, {:null, obj}, i}
              end
            end),
          "diff" =>
            native_fn("diff", fn obj, args, i ->
              case args do
                [{:object, _} = other_ref | _] ->
                  other = Eval.get_object(i, other_ref)
                  dt2 = native_dt_get(other)
                  dt1 = native_dt_get(obj)
                  {iref, i2} = Eval.make_instance(i, "dateinterval")
                  iobj = Eval.get_object(i2, iref)
                  iv = PhpBeam.Dt.diff(dt1, dt2)

                  iobj2 =
                    Enum.reduce(
                      [
                        {"y", {:int, iv.y}},
                        {"m", {:int, iv.m}},
                        {"d", {:int, iv.d}},
                        {"h", {:int, iv.h}},
                        {"i", {:int, iv.i}},
                        {"s", {:int, iv.s}},
                        {"days", {:int, iv.days}},
                        {"invert", {:int, iv.invert}},
                        {"f", {:float, 0.0}}
                      ],
                      iobj,
                      fn {k, v}, acc ->
                        case PArray.put(acc.props, {:string, k}, v) do
                          {:ok, pr} -> %{acc | props: pr}
                          _ -> acc
                        end
                      end
                    )

                  i3 = PhpBeam.Objects.put_object(i2, iref, iobj2)
                  {:ok, {iref, obj}, i3}

                _ ->
                  {:ok, {:null, obj}, i}
              end
            end),
          "createfromformat" =>
            native_fn_static("createFromFormat", fn _obj, args, i ->
              fmt = args |> Enum.at(0, {:string, ""}) |> dt_s()
              val = args |> Enum.at(1, {:string, ""}) |> dt_s()
              base_tz = Map.get(i.ini, "date.timezone", "UTC")

              case PhpBeam.Dt.create_from_format(fmt, val, base_tz) do
                {:ok, dt} ->
                  {oref, i2} = Eval.make_instance(i, String.downcase(class_name))
                  o = Eval.get_object(i2, oref)
                  i3 = PhpBeam.Objects.put_object(i2, oref, native_dt_put(o, dt))
                  {:ok, {oref, nil}, i3}

                :error ->
                  {:ok, {{:bool, false}, nil}, i}
              end
            end),
          "createfromimmutable" =>
            native_fn_static("createFromImmutable", fn _obj, args, i ->
              case args do
                [{:object, _} = src_ref | _] ->
                  src = Eval.get_object(i, src_ref)
                  {oref, i2} = Eval.make_instance(i, "datetime")
                  o = Eval.get_object(i2, oref)
                  i3 = PhpBeam.Objects.put_object(i2, oref, native_dt_put(o, native_dt_get(src)))
                  {:ok, {oref, nil}, i3}

                _ ->
                  {:ok, {{:bool, false}, nil}, i}
              end
            end),
          "getlasterrors" =>
            native_fn_static("getLastErrors", fn _obj, _args, i ->
              {:ok, {{:bool, false}, nil}, i}
            end)
        }
        |> Map.new(fn {k, v} -> {k, v} end),
      file: ""
    }
  end

  defp native_dt_get(obj) do
    case Map.get(obj, :dt_state) do
      %{"dt" => %PhpBeam.Dt{} = dt} ->
        dt

      # legacy {ts, tz} shape — migrate on read
      %{"ts" => {:int, ts}} ->
        tz = Map.get(obj, :dt_state) |> Map.get("tz", {:string, "UTC"}) |> dt_s()
        %PhpBeam.Dt{utc: ts, zone: PhpBeam.Dt.zone_of(tz)}

      _ ->
        PhpBeam.Dt.now()
    end
  end

  defp native_dt_put(obj, %PhpBeam.Dt{} = dt) do
    Map.put(obj, :dt_state, %{"dt" => dt})
  end

  defp native_state_put_interval(obj, iv) do
    Map.put(obj, :dt_state, iv)
  end

  defp zone_name_of(%PhpBeam.Dt{zone: {:named, z}}), do: z.name
  defp zone_name_of(%PhpBeam.Dt{zone: {:offset, off}}), do: PhpBeam.Dt.offset_str(off, ":")
  defp zone_name_of(%PhpBeam.Dt{zone: {:utc}}), do: "UTC"

  defp php_int({:int, n}), do: n
  defp php_int(_), do: 0

  # add()/sub() with a DateInterval argument: months via calendar carry,
  # the rest as flat seconds (sign -1 inverts)
  defp dt_interval_shift(dt, [{:object, _} = iref | _], sign, i) do
    iobj = Eval.get_object(i, iref)

    g = fn k ->
      case PArray.fetch(iobj.props, {:string, k}) do
        {:ok, {:int, n}} -> n
        _ -> 0
      end
    end

    months = g.("y") * 12 + g.("m")
    secs = g.("h") * 3600 + g.("i") * 60 + g.("s")

    dt2 =
      dt
      |> then(fn d -> if months != 0, do: PhpBeam.Dt.add_months(d, sign * months), else: d end)
      |> then(fn d -> %{d | utc: d.utc + sign * secs + sign * g.("d") * 86_400} end)

    {:ok, dt2}
  end

  defp native_dateinterval_class do
    %__MODULE__{
      name: "DateInterval",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{
        "format" =>
          native_fn("format", fn obj, args, i ->
            fmt = args |> Enum.at(0, {:string, "%a"}) |> dt_s()

            g = fn k, default ->
              case PArray.fetch(obj.props, {:string, k}) do
                {:ok, v} -> v
                _ -> default
              end
            end

            days = g.("days", {:bool, false})
            invert = g.("invert", {:int, 0})

            out =
              Regex.replace(~r/%[YyMmDdaHhIiSsRr%]/, fmt, fn
                "%Y", _ ->
                  int_str(g.("y", {:int, 0}), 2)

                "%y", _ ->
                  int_str(g.("y", {:int, 0}), 0)

                "%M", _ ->
                  int_str(g.("m", {:int, 0}), 2)

                "%m", _ ->
                  int_str(g.("m", {:int, 0}), 0)

                "%D", _ ->
                  int_str(g.("d", {:int, 0}), 2)

                "%d", _ ->
                  int_str(g.("d", {:int, 0}), 0)

                "%a", _ ->
                  case days do
                    {:int, n} when n >= 0 -> Integer.to_string(n)
                    _ -> "false"
                  end

                "%H", _ ->
                  int_str(g.("h", {:int, 0}), 2)

                "%h", _ ->
                  int_str(g.("h", {:int, 0}), 0)

                "%I", _ ->
                  int_str(g.("i", {:int, 0}), 2)

                "%i", _ ->
                  int_str(g.("i", {:int, 0}), 0)

                "%S", _ ->
                  int_str(g.("s", {:int, 0}), 2)

                "%s", _ ->
                  int_str(g.("s", {:int, 0}), 0)

                "%R", _ ->
                  if invert == {:int, 1} or invert == 1, do: "-", else: "+"

                "%r", _ ->
                  if invert == {:int, 1} or invert == 1, do: "-", else: ""

                "%%", _ ->
                  "%"
              end)

            {:ok, {{:string, out}, obj}, i}
          end),
        "__construct" =>
          native_fn("__construct", fn obj, args, i ->
            spec = args |> Enum.at(0, {:string, "P1D"}) |> dt_s()

            case parse_interval(spec) do
              {:ok, %{y: y, mo: mo, d: d, h: h, mi: mi, s: s}} ->
                obj2 =
                  obj
                  |> dt_put("y", {:int, y})
                  |> dt_put("m", {:int, mo})
                  |> dt_put("d", {:int, d})
                  |> dt_put("h", {:int, h})
                  |> dt_put("i", {:int, mi})
                  |> dt_put("s", {:int, s})
                  |> dt_put("f", {:float, 0.0})
                  |> dt_put("invert", {:int, 0})
                  |> dt_put("days", {:bool, false})

                # mirror into real props so ->y reads work through the
                # standard property channel
                obj3 =
                  Enum.reduce(
                    [{"y", y}, {"m", mo}, {"d", d}, {"h", h}, {"i", mi}, {"s", s}],
                    obj2,
                    fn {k, v}, acc ->
                      case PArray.put(acc.props, {:string, k}, {:int, v}) do
                        {:ok, p} -> %{acc | props: p}
                        _ -> acc
                      end
                    end
                  )

                obj4 =
                  Enum.reduce(
                    [{"days", {:bool, false}}, {"invert", {:int, 0}}, {"f", {:float, 0.0}}],
                    obj3,
                    fn {k, v}, acc ->
                      case PArray.put(acc.props, {:string, k}, v) do
                        {:ok, p} -> %{acc | props: p}
                        _ -> acc
                      end
                    end
                  )

                {:ok, {:null, obj4}, i}

              :error ->
                {oref, i2} =
                  Eval.materialize_native(
                    {:native_error, "Exception",
                     "DateInterval::__construct(): Unknown or bad format (#{spec})"},
                    i
                  )

                {{:unwind, {:php_throw, oref}}, i2}
            end
          end)
      },
      file: ""
    }
  end

  # ISO 8601 duration: P[n]Y[n]M[n]DT[n]H[n]M[n]S (weeks W too)
  defp parse_interval("P" <> rest),
    do:
      parse_interval_parts(rest, false, %{
        "y" => 0,
        "m" => 0,
        "d" => 0,
        "h" => 0,
        "i" => 0,
        "s" => 0
      })

  defp parse_interval("PT" <> rest),
    do:
      parse_interval_parts(rest, false, %{
        "y" => 0,
        "m" => 0,
        "d" => 0,
        "h" => 0,
        "i" => 0,
        "s" => 0
      })

  defp parse_interval(_), do: :error

  defp parse_interval_parts("", _in_time, acc), do: {:ok, interval_result(acc)}

  defp parse_interval_parts("T" <> rest, _in_time, acc), do: parse_interval_parts(rest, true, acc)

  defp parse_interval_parts(part, in_time, acc) do
    case Regex.run(~r{(\d+(?:\.\d+)?)([YMWDHS])}i, part) do
      [full, num, unit] ->
        rest = String.replace_prefix(part, full, "")
        unit = String.downcase(unit)

        # ISO 8601: "M" is months before the T, minutes after it
        key =
          case {unit, in_time} do
            {"m", false} ->
              "m"

            {"m", true} ->
              "i"

            {u, _} ->
              %{"y" => "y", "w" => "d", "d" => "d", "h" => "h", "s" => "s"}[u] || "i"
          end

        mult = if unit == "w", do: 7, else: 1

        n =
          case Integer.parse(num) do
            {i2, ""} -> i2 * mult
            _ -> 0
          end

        parse_interval_parts(rest, in_time, Map.update(acc, key, n, &(&1 + n)))

      _ ->
        :error
    end
  end

  defp interval_result(acc) do
    %{y: acc["y"], mo: acc["m"], d: acc["d"], h: acc["h"], mi: acc["i"], s: acc["s"]}
  end

  # DatePeriod: constructed and stored; foreach iteration needs the prop
  # machinery to tolerate integer keys (find_prop assumes strings) —
  # registered in docs/matrix/deferred.md, expansion lands with B5's
  # Iterator protocol work
  defp native_dateperiod_class do
    %__MODULE__{
      name: "DatePeriod",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{
        "__construct" =>
          native_fn("__construct", fn obj, _args, i ->
            {:ok, {:null, obj}, i}
          end)
      },
      file: ""
    }
  end

  # ───────────────────────── metadata read API (L3 Reflection foundation) ─────────────────────────
  # Pure rendering of stored shapes — no semantics, hot paths untouched.
  # Storage (method maps, {:param,...} 6-tuples, prop maps) stays as-is;
  # these views are built on demand for consumers like Reflection.

  @doc "Method storage map → named view (declaring_class + file resolved via interp)"
  def method_meta(interp, m) do
    %{
      name: m.name,
      declaring_class: m.class,
      visibility: m.visibility,
      static?: m.static?,
      abstract?: m.abstract?,
      final?: m.final?,
      native?: m.native != nil,
      params: Enum.map(m.params || [], &param_meta/1),
      line: m.line,
      file:
        case get_class(interp, m.class) do
          %{file: f} -> f
          _ -> nil
        end
    }
  end

  @doc "Param tuple {:param, name, type, default, by_ref?, variadic?} → named view"
  def param_meta({:param, name, type, default, by_ref?, variadic?}) do
    %{
      name: name,
      type: type,
      default: default,
      by_ref?: by_ref?,
      variadic?: variadic?,
      optional?: default != nil
    }
  end

  @doc "Prop storage map → named view"
  def prop_meta(p) do
    %{
      name: p.display,
      visibility: p.visibility,
      static?: p.static?,
      readonly?: p.readonly? == true,
      type: Map.get(p, :type),
      default: p.default
    }
  end

  @doc """
  Class → named view with inheritance-aware member tables (child shadows
  ancestors; entries keyed by downcased name). nil when class unknown.
  """
  def class_meta(interp, key) do
    case get_class(interp, key) do
      nil ->
        nil

      class ->
        %{
          name: class.name,
          kind: class.kind,
          parent: class.parent,
          interfaces: class.interfaces,
          traits: class.traits,
          abstract?: class.abstract?,
          final?: "final" in (class.modifiers || []),
          readonly?: "readonly" in (class.modifiers || []),
          enum?: class.kind == :enum,
          backed?: class.backed? == true,
          file: class.file,
          ns: class.ns,
          methods: chain_methods_meta(interp, key),
          props: chain_props_meta(interp, key),
          consts: class.consts
        }
    end
  end

  defp chain_methods_meta(interp, key) do
    interp
    |> self_and_ancestors(key)
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn k, acc ->
      case get_class(interp, k) do
        nil -> acc
        c -> Map.merge(acc, Map.new(c.methods, fn {mk, m} -> {mk, method_meta(interp, m)} end))
      end
    end)
  end

  defp chain_props_meta(interp, key) do
    interp
    |> self_and_ancestors(key)
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn k, acc ->
      case get_class(interp, k) do
        nil ->
          acc

        c ->
          Map.merge(acc, Map.new(c.props, fn p -> {String.downcase(p.display), prop_meta(p)} end))
      end
    end)
  end

  # ───────────────────────── Reflection thin slice (L3 pre-work) ─────────────────────────
  # Purpose: validate the meta API with a real consumer. Full Reflection
  # (getMethods()/getParameters() object graphs) lands with L3; this slice
  # exposes only parity-safe members (probe-verified 2026-09-26).

  defp rc_state(obj), do: Map.get(obj, :dt_state) || %{}
  defp rc_put(obj, k, v), do: dt_put(obj, k, v)

  # php class-name resolution for the ctor argument (string or object)
  # php resolves DYNAMIC string class names verbatim — no namespace
  # prefixing (that is compile-time behavior for literal names only);
  # ReflectionClass('A\\B\\C') inside namespace Ns looks up A\\B\\C
  defp rc_resolve_key(_obj, [{:string, name} | _], _i), do: {:ok, String.downcase(name)}

  defp rc_resolve_key(_obj, [{:object, _} = oref | _], i),
    do: {:ok, Eval.get_object(i, oref).class}

  defp rc_resolve_key(obj, args, i),
    do:
      {{:unwind,
        {:php_throw,
         {:native_error, "ReflectionException",
          "Class \"" <> dt_s(Enum.at(args, 0, :null)) <> "\" does not exist"}}}, obj, i}

  defp rc_throw(obj, i, msg) do
    {obj_ref, i2} = Eval.materialize_native({:native_error, "ReflectionException", msg}, i)
    {{:unwind, {:php_throw, obj_ref}}, obj, i2}
  end

  # B4: ReflectionClass gains the property/constant surface from Reflection2
  defp patch_reflection_class(base) do
    %{
      base
      | methods: Map.merge(base.methods, PhpBeam.Classes.Reflection2.reflection_class_extras())
    }
  end

  # B4: ReflectionMethod gains return-type/parameter-count/name surface
  defp patch_reflection_method(base) do
    extras =
      Map.new(
        [
          native_fn("getReturnType", fn obj, _args, i ->
            m = rm_method(obj, i)
            rt = m && Map.get(m, :ret)

            case rt do
              nil ->
                {:ok, {:null, obj}, i}

              "" ->
                {:ok, {:null, obj}, i}

              _ ->
                {tref, i2} = PhpBeam.Classes.Reflection2.make_type_obj(rt, i)
                {:ok, {tref, obj}, i2}
            end
          end),
          native_fn("getNumberOfParameters", fn obj, _args, i ->
            m = rm_method(obj, i)
            {:ok, {{:int, length((m && m.params) || [])}, obj}, i}
          end),
          native_fn("getNumberOfRequiredParameters", fn obj, _args, i ->
            m = rm_method(obj, i)

            n =
              Enum.count((m && m.params) || [], fn
                {:param, _n, _t, d, _br, _v} -> d == nil
                _ -> false
              end)

            {:ok, {{:int, n}, obj}, i}
          end),
          native_fn("getName", fn obj, _args, i ->
            m = rm_method(obj, i)
            {:ok, {{:string, (m && m.name) || ""}, obj}, i}
          end),
          native_fn("getDeclaringClass", fn obj, _args, i ->
            key = obj.dt_state["ckey"] || obj.dt_state["key"]

            {cref, i2} = Eval.make_instance(i, "reflectionclass")
            co = Eval.get_object(i2, cref)

            co2 =
              co
              |> Map.put(:dt_state, %{"ckey" => key, "key" => key})

            i3 = Eval.put_object(i2, cref, co2)
            {:ok, {cref, obj}, i3}
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )

    %{base | methods: Map.merge(base.methods, extras)}
  end

  defp rm_method(obj, i) do
    key = obj.dt_state["ckey"] || obj.dt_state["key"]
    mname = obj.dt_state["mname"]
    PhpBeam.Classes.find_method(i, key, mname)
  end

  defp native_reflection_class do
    %__MODULE__{
      name: "ReflectionClass",
      kind: :class,
      methods:
        Map.new(
          [
            native_fn("__construct", fn obj, args, i ->
              case rc_resolve_key(obj, args, i) do
                {:ok, key} ->
                  # php's ReflectionClass autoloads before failing
                  {klass, i2} =
                    case get_class(i, key) do
                      nil -> Eval.fetch_class(i, key, dt_s(Enum.at(args, 0, {:string, ""})))
                      c -> {c, i}
                    end

                  case klass do
                    nil ->
                      rc_throw(
                        obj,
                        i2,
                        "Class \"" <> dt_s(Enum.at(args, 0, :null)) <> "\" does not exist"
                      )

                    _ ->
                      {:ok, {:null, rc_put(obj, "key", key)}, i2}
                  end

                thrown ->
                  thrown
              end
            end),
            native_fn("getName", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("key")
              {:ok, {{:string, Map.get(get_class(i, key) || %{name: ""}, :name)}, obj}, i}
            end),
            native_fn("isAbstract", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("key")
              c = get_class(i, key)
              {:ok, {{:bool, c != nil and c.abstract?}, obj}, i}
            end),
            native_fn("isFinal", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("key")
              c = get_class(i, key)
              {:ok, {{:bool, c != nil and "final" in (c.modifiers || [])}, obj}, i}
            end),
            native_fn("isInterface", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("key")
              c = get_class(i, key)
              {:ok, {{:bool, c != nil and c.kind == :interface}, obj}, i}
            end),
            native_fn("isEnum", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("key")
              c = get_class(i, key)
              {:ok, {{:bool, c != nil and c.kind == :enum}, obj}, i}
            end),
            native_fn("hasMethod", fn obj, args, i ->
              key = rc_state(obj) |> Map.get("key")
              name = args |> Enum.at(0, {:string, ""}) |> dt_s()
              {:ok, {{:bool, find_method(i, key, name) != nil}, obj}, i}
            end),
            native_fn("getAttributes", fn obj, _args, i ->
              {:ok, {{:array, PArray.new()}, obj}, i}
            end),
            native_fn("implementsInterface", fn obj, args, i ->
              key = rc_state(obj) |> Map.get("key")

              case rc_resolve_key(obj, args, i) do
                {:ok, ikey} ->
                  case get_class(i, ikey) do
                    %{kind: :interface} ->
                      {:ok, {{:bool, is_a?(i, key, ikey)}, obj}, i}

                    _ ->
                      rc_throw(
                        obj,
                        i,
                        "Interface \"" <> dt_s(Enum.at(args, 0, :null)) <> "\" does not exist"
                      )
                  end

                err ->
                  err
              end
            end),
            native_fn("isInstantiable", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("key")
              c = get_class(i, key)
              inst = c != nil and c.kind == :class and not c.abstract?

              inst =
                inst and
                  case find_method(i, key, "__construct") do
                    nil -> true
                    m -> m.visibility == :public
                  end

              {:ok, {{:bool, inst}, obj}, i}
            end),
            native_fn("getConstructor", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("key")

              case find_method(i, key, "__construct") do
                nil ->
                  {:ok, {:null, obj}, i}

                m ->
                  {oref, i2} = rc_make_method(i, key, m)
                  {:ok, {oref, obj}, i2}
              end
            end),
            native_fn("newInstance", fn obj, args, i ->
              rc_new_with_ctor(obj, rc_state(obj) |> Map.get("key"), args, i)
            end),
            native_fn("newInstanceArgs", fn obj, args, i ->
              key = rc_state(obj) |> Map.get("key")

              vals =
                case args |> Enum.at(0, {:array, PArray.new()}) do
                  {:array, a} -> PArray.values(a)
                  other -> [other]
                end

              rc_new_with_ctor(obj, key, vals, i)
            end),
            native_fn("getMethods", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("key")

              {arr, i2} =
                class_meta(i, key).methods
                |> Enum.reduce({PArray.new(), i}, fn {_k, mm}, {acc, it} ->
                  {oref, it2} = rc_make_method(it, key, find_method(it, key, mm.name))
                  a2 = PArray.push(acc, oref)
                  {a2, it2}
                end)

              {:ok, {{:array, arr}, obj}, i2}
            end),
            native_fn("getMethod", fn obj, args, i ->
              key = rc_state(obj) |> Map.get("key")
              name = args |> Enum.at(0, {:string, ""}) |> dt_s()
              m = find_method(i, key, name)

              if m do
                {{:object, mid}, i2} = Eval.make_instance(i, "reflectionmethod")
                mob = Eval.get_object(i2, {:object, mid})

                i3 =
                  Eval.put_object(
                    i2,
                    {:object, mid},
                    mob |> rc_put("ckey", key) |> rc_put("mname", String.downcase(name))
                  )

                {:ok, {{:object, mid}, obj}, i3}
              else
                display = (get_class(i, key) || %{name: ""}).name

                rc_throw(
                  obj,
                  i,
                  "Method " <>
                    display <> "::" <> dt_s(Enum.at(args, 0, :null)) <> "() does not exist"
                )
              end
            end)
          ],
          fn m -> {String.downcase(m.name), m} end
        ),
      file: ""
    }
  end

  # build a ReflectionMethod instance bound to (ckey, method-map)
  defp rc_make_method(i, ckey, m) do
    {{:object, mid}, i2} = Eval.make_instance(i, "reflectionmethod")
    mob = Eval.get_object(i2, {:object, mid})

    i3 =
      Eval.put_object(i2, {:object, mid}, mob |> rc_put("ckey", ckey) |> rc_put("mname", m.name))

    {{:object, mid}, i3}
  end

  defp native_reflection_method_class do
    %__MODULE__{
      name: "ReflectionMethod",
      kind: :class,
      methods:
        Map.new(
          [
            native_fn("__construct", fn obj, args, i ->
              case args do
                [{:object, _} = oref, {:string, mname} | _] ->
                  key = Eval.get_object(i, oref).class

                  {:ok,
                   {:null, obj |> rc_put("ckey", key) |> rc_put("mname", String.downcase(mname))},
                   i}

                [{:string, cname}, {:string, mname} | _] ->
                  # dynamic string class names resolve VERBATIM
                  key = String.downcase(cname)

                  {:ok,
                   {:null, obj |> rc_put("ckey", key) |> rc_put("mname", String.downcase(mname))},
                   i}

                _ ->
                  {:ok, {:null, obj}, i}
              end
            end),
            native_fn("getName", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("ckey")
              name = rc_state(obj) |> Map.get("mname")

              if key == nil or name == nil do
                {:ok, {{:string, ""}, obj}, i}
              else
                m = find_method(i, key, name)
                {:ok, {{:string, if(m, do: m.name, else: "")}, obj}, i}
              end
            end),
            native_fn("getNumberOfParameters", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("ckey")
              name = rc_state(obj) |> Map.get("mname")
              m = find_method(i, key, name)
              {:ok, {{:int, if(m, do: length(m.params || []), else: 0)}, obj}, i}
            end),
            native_fn("isPublic", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("ckey")
              name = rc_state(obj) |> Map.get("mname")
              m = find_method(i, key, name)
              {:ok, {{:bool, m != nil and m.visibility == :public}, obj}, i}
            end),
            native_fn("getAttributes", fn obj, _args, i ->
              {:ok, {{:array, PArray.new()}, obj}, i}
            end),
            native_fn("getParameters", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("ckey")
              name = rc_state(obj) |> Map.get("mname")
              m = find_method(i, key, name)

              if m == nil do
                {:ok, {{:array, PArray.new()}, obj}, i}
              else
                {arr, i2} =
                  (m.params || [])
                  |> Enum.with_index()
                  |> Enum.reduce({PArray.new(), i}, fn {p, idx}, {acc, it} ->
                    {oref, it2} = rc_make_parameter(it, key, name, p, idx)
                    a2 = PArray.push(acc, oref)
                    {a2, it2}
                  end)

                {:ok, {{:array, arr}, obj}, i2}
              end
            end),
            native_fn("isAbstract", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("ckey")
              name = rc_state(obj) |> Map.get("mname")
              m = find_method(i, key, name)
              {:ok, {{:bool, m && m.abstract?}, obj}, i}
            end),
            native_fn("isFinal", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("ckey")
              name = rc_state(obj) |> Map.get("mname")
              m = find_method(i, key, name)
              {:ok, {{:bool, m && m.final?}, obj}, i}
            end),
            native_fn("getDeclaringClass", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("ckey")
              {:ok, {{:string, (get_class(i, key) || %{name: key}).name}, obj}, i}
            end),
            native_fn("invoke", fn obj, args, i ->
              key = rc_state(obj) |> Map.get("ckey")
              name = rc_state(obj) |> Map.get("mname")
              m = find_method(i, key, name)
              [target | rest] = args

              {{:val, _} = r, _, i2} =
                Eval.call_php_method(
                  target,
                  m,
                  Enum.map(rest, &{:arg, {:lit_val, &1}, false, nil}),
                  %Env{},
                  i
                )

              {:ok, {elem(r, 1), obj}, i2}
            end),
            native_fn("isStatic", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("ckey")
              name = rc_state(obj) |> Map.get("mname")
              m = find_method(i, key, name)
              {:ok, {{:bool, m != nil and m.static?}, obj}, i}
            end)
          ],
          fn m -> {String.downcase(m.name), m} end
        ),
      file: ""
    }
  end

  # build a ReflectionParameter instance for (ckey, mname, param, idx)
  defp rc_make_parameter(i, ckey, mname, {:param, pname, ptype, pdefault, _br, _var}, idx) do
    {{:object, pid}, i2} = Eval.make_instance(i, "reflectionparameter")
    pob = Eval.get_object(i2, {:object, pid})

    pob =
      case PArray.put(pob.props, {:string, "name"}, {:string, pname}) do
        {:ok, pp} -> %{pob | props: pp}
        _ -> pob
      end

    st =
      pob
      |> rc_put("pname", pname)
      |> rc_put("name", pname)
      |> rc_put("ptype", ptype)
      |> rc_put("pdefault", pdefault)
      |> rc_put("pidx", {:int, idx})
      |> rc_put("ckey", ckey)
      |> rc_put("mname", mname)
      |> rc_put("pvariadic", {:bool, _var})

    {{:object, pid}, Eval.put_object(i2, {:object, pid}, st)}
  end

  defp native_reflection_parameter_class do
    %__MODULE__{
      name: "ReflectionParameter",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods:
        Map.new(
          [
            native_fn("getName", fn obj, _args, i ->
              {:ok, {{:string, rc_state(obj) |> Map.get("pname")}, obj}, i}
            end),
            native_fn("getAttributes", fn obj, _args, i ->
              {:ok, {{:array, PArray.new()}, obj}, i}
            end),
            native_fn("isVariadic", fn obj, _args, i ->
              {:ok,
               {{:bool,
                 rc_state(obj) |> Map.get("pvariadic", {:bool, false}) == {:bool, true} or
                   rc_state(obj) |> Map.get("pvariadic") == true}, obj}, i}
            end),
            native_fn("isArray", fn obj, _args, i ->
              t = rc_state(obj) |> Map.get("ptype")
              {:ok, {{:bool, is_binary(t) and t == "array"}, obj}, i}
            end),
            native_fn("isPassedByReference", fn obj, _args, i ->
              {:ok, {{:bool, false}, obj}, i}
            end),
            native_fn("getType", fn obj, _args, i ->
              ptype = rc_state(obj) |> Map.get("ptype")

              if ptype == nil or ptype == "" do
                {:ok, {:null, obj}, i}
              else
                # php bakes alias resolution into compiled types: getName()
                # returns the DECLARING class's resolved FQCN
                {bare, nullable?} =
                  if String.starts_with?(ptype, "?"),
                    do: {String.trim_leading(ptype, "?"), true},
                    else: {ptype, false}

                builtin? =
                  bare in ~w(int float string bool array callable iterable object mixed null false true self static)

                ckey = rc_state(obj) |> Map.get("ckey")

                resolved =
                  if builtin?,
                    do: bare,
                    else: resolve_type_cased(bare, get_class(i, ckey))

                {{:object, tid}, i2} = Eval.make_instance(i, "reflectionnamedtype")
                tob = Eval.get_object(i2, {:object, tid})

                st =
                  tob
                  |> rc_put("tname", if(nullable?, do: "?" <> resolved, else: resolved))
                  |> rc_put("tbuiltin", {:bool, builtin?})

                {:ok, {{:object, tid}, obj}, Eval.put_object(i2, {:object, tid}, st)}
              end
            end),
            native_fn("isOptional", fn obj, _args, i ->
              d = rc_state(obj) |> Map.get("pdefault")
              {:ok, {{:bool, d != nil}, obj}, i}
            end),
            native_fn("isDefaultValueAvailable", fn obj, _args, i ->
              d = rc_state(obj) |> Map.get("pdefault")
              {:ok, {{:bool, d != nil}, obj}, i}
            end),
            native_fn("getDefaultValue", fn obj, _args, i ->
              d = rc_state(obj) |> Map.get("pdefault")

              v =
                if is_tuple(d) or is_atom(d),
                  do: Eval.const_eval_quiet(d, nil, i),
                  else: :null

              {:ok, {v, obj}, i}
            end),
            native_fn("getPosition", fn obj, _args, i ->
              {:ok, {rc_state(obj) |> Map.get("pidx"), obj}, i}
            end),
            native_fn("getDeclaringClass", fn obj, _args, i ->
              key = rc_state(obj) |> Map.get("ckey")
              {:ok, {{:string, (get_class(i, key) || %{name: key}).name}, obj}, i}
            end),
            native_fn("hasType", fn obj, _args, i ->
              ptype = rc_state(obj) |> Map.get("ptype")
              {:ok, {{:bool, ptype != nil and ptype != ""}, obj}, i}
            end)
          ],
          fn m -> {String.downcase(m.name), m} end
        ),
      file: ""
    }
  end

  defp native_reflection_named_type_class do
    %__MODULE__{
      name: "ReflectionNamedType",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods:
        Map.new(
          [
            native_fn("getName", fn obj, _args, i ->
              t = rc_state(obj) |> Map.get("tname")

              name =
                case t do
                  "?" <> inner -> inner
                  other -> other
                end

              {:ok, {{:string, name}, obj}, i}
            end),
            native_fn("__tostring", fn obj, _args, i ->
              t = rc_state(obj) |> Map.get("tname")
              {:ok, {{:string, t || ""}, obj}, i}
            end),
            native_fn("isBuiltin", fn obj, _args, i ->
              {:ok, {rc_state(obj) |> Map.get("tbuiltin", {:bool, false}), obj}, i}
            end),
            native_fn("allowsNull", fn obj, _args, i ->
              t = rc_state(obj) |> Map.get("tname")

              {:ok,
               {{:bool, (is_binary(t) and String.starts_with?(t, "?")) or t == "mixed"}, obj}, i}
            end)
          ],
          fn m -> {String.downcase(m.name), m} end
        ),
      file: ""
    }
  end

  defp native_reflection_attribute_class do
    %__MODULE__{
      name: "ReflectionAttribute",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{
        "IS_FINAL" => {:int, 1},
        "IS_ISOLATED" => {:int, 2},
        "IS_INSTANCEOF" => {:int, 2},
        "IS_REPEATABLE" => {:int, 4}
      },
      props: [],
      methods: %{},
      file: ""
    }
  end

  # shared newInstance path: run __construct under the DECLARING class's
  # ns/uses (php binds names at compile time) — a bare %Env{} leaves ctor
  # bodies unable to resolve their own file's use-aliases
  defp rc_new_with_ctor(obj, key, vals, i) do
    {{:object, _} = oref, i2} = Eval.make_instance(i, key)

    case find_method(i2, key, "__construct") do
      nil ->
        {:ok, {oref, obj}, i2}

      m ->
        class = get_class(i2, key)

        i3 =
          %{
            i2
            | ns: (class && class.ns) || [],
              uses: (class && class.uses) || %{normal: %{}, function: %{}, const: %{}}
          }

        env = %Env{function: "__construct", called_class: key, scope_class: key, this: oref}

        res =
          Eval.call_php_method(
            oref,
            m,
            Enum.map(vals, &{:arg, {:lit_val, &1}, false, nil}),
            env,
            i3
          )

        case res do
          {{:val, _}, _, i4} ->
            {:ok, {oref, obj}, %{i4 | ns: i.ns, uses: i.uses}}

          other ->
            {:ok, {oref, obj}, i}
        end
    end
  end

  defp native_state(obj), do: Map.get(obj, :dt_state) || %{}

  defp dt_put(obj, k, v) do
    st = Map.get(obj, :dt_state) || %{}
    Map.put(obj, :dt_state, Map.put(st, k, v))
  end

  defp int_str({:int, n}, pad) do
    s = Integer.to_string(abs(n))
    s = if pad > 1, do: String.pad_leading(s, pad, "0"), else: s
    if n < 0, do: "-" <> s, else: s
  end

  defp dt_s({:string, s}), do: s
  defp dt_s(v), do: PhpBeam.Eval.php_to_string(v)

  defp dt_format(fmt, {:int, ts}, {:string, tz}) do
    offset = if tz in ~w(UTC GMT +00:00), do: 0, else: 0

    {{yr, mo, dy}, {hh, mm, ss}} =
      :calendar.gregorian_seconds_to_datetime(ts + offset * 3600 + 62_167_219_200)

    fmt
    |> String.to_charlist()
    |> Enum.map_join("", fn
      ?T ->
        if offset == 0, do: "UTC", else: dt_tz_abbr(offset)

      ?U ->
        Integer.to_string(ts)

      ?Y ->
        pad(yr, 4)

      ?m ->
        pad(mo, 2)

      ?d ->
        pad(dy, 2)

      ?H ->
        pad(hh, 2)

      ?i ->
        pad(mm, 2)

      ?s ->
        pad(ss, 2)

      ?c ->
        "#{pad(yr, 4)}-#{pad(mo, 2)}-#{pad(dy, 2)}T#{pad(hh, 2)}:#{pad(mm, 2)}:#{pad(ss, 2)}" <>
          dt_offset_str(offset)

      ?\\ ->
        ""

      ch ->
        <<ch>>
    end)
  end

  defp pad(n, w), do: String.pad_leading(Integer.to_string(n), w, "0")

  defp dt_offset_str(0), do: "+00:00"

  defp dt_offset_str(off) do
    sign = if off >= 0, do: "+", else: "-"
    a = abs(off)
    sign <> pad(div(a, 60), 2) <> ":" <> pad(rem(a, 60), 2)
  end

  defp dt_tz_abbr(off) do
    sign = if off >= 0, do: "+", else: "-"
    "#{sign}#{pad((abs(off) / 1) |> trunc, 2)}"
  end

  # Generator objects are created by Eval.start_generator; the state
  # (pid, caches) lives in a `gen_state` prop, the methods are native
  defp native_generator_class do
    %__MODULE__{
      name: "Generator",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{
        "current" => native_fn("current", &gen_native_current/3),
        "key" => native_fn("key", &gen_native_key/3),
        "valid" => native_fn("valid", &gen_native_valid/3),
        "next" => native_fn("next", &gen_native_next/3),
        "send" => native_fn("send", &gen_native_send/3),
        "rewind" => native_fn("rewind", &gen_native_rewind/3),
        "getreturn" => native_fn("getReturn", &gen_native_get_return/3)
      },
      abstract?: false,
      final?: true,
      file: ""
    }
  end

  defp gen_state_of(obj) do
    case PArray.get(obj.props, {:string, "gen_state"}) do
      {:gen_state, m} -> m
      _ -> %{pid: nil, started: false, done: false, k: :null, v: :null, ret: :null}
    end
  end

  defp put_gen_state(obj, st) do
    case PArray.put(obj.props, {:string, "gen_state"}, {:gen_state, st}) do
      {:ok, p2} -> %{obj | props: p2}
      _ -> obj
    end
  end

  defp gen_native_current(obj, _args, interp) do
    {obj2, interp2} = gen_autostart(obj, interp)
    st = gen_state_of(obj2)

    v = if st.done, do: :null, else: st.v
    {:ok, {v, obj2}, interp2}
  end

  defp gen_native_key(obj, _args, interp) do
    {obj2, interp2} = gen_autostart(obj, interp)
    st = gen_state_of(obj2)

    k = if st.done, do: :null, else: st.k
    {:ok, {k, obj2}, interp2}
  end

  defp gen_native_valid(obj, _args, interp) do
    {obj2, interp2} = gen_autostart(obj, interp)
    st = gen_state_of(obj2)
    {:ok, {{:bool, not st.done}, obj2}, interp2}
  end

  # php's current()/key()/valid() implicitly start (rewind) a fresh generator
  defp gen_autostart(obj, interp) do
    st = gen_state_of(obj)

    if st.started or st.done or st.pid == nil do
      {obj, interp}
    else
      case Eval.gen_resume({:object, obj.__ref__}, :start, interp) do
        {:yielded, _k, _v, i2} -> {Eval.get_object(i2, {:object, obj.__ref__}), i2}
        {:done, _ret, i2} -> {Eval.get_object(i2, {:object, obj.__ref__}), i2}
        {:thrown, _u, _i2} -> {obj, interp}
      end
    end
  end

  defp gen_native_next(obj, _args, interp) do
    st0 = gen_state_of(obj)

    if st0.done do
      {:ok, {:null, obj}, interp}
    else
      v = if st0.started, do: :null, else: :start

      case Eval.gen_resume({:object, obj.__ref__}, v, interp) do
        {:yielded, _k, _v, i2} ->
          obj2 = Eval.get_object(i2, {:object, obj.__ref__})
          {:ok, {:null, obj2}, i2}

        {:done, _ret, i2} ->
          obj2 = Eval.get_object(i2, {:object, obj.__ref__})
          {:ok, {:null, obj2}, i2}

        {:thrown, u, i2} ->
          {{:unwind, u}, nil, i2}
      end
    end
  end

  defp gen_native_send(obj, args, interp) do
    st0 = gen_state_of(obj)
    v = Enum.at(args, 0, :null)

    if st0.done do
      {:ok, {:null, obj}, interp}
    else
      # send() on an unstarted generator rewinds it first, then delivers
      resume_v =
        if st0.started do
          v
        else
          case Eval.gen_resume({:object, obj.__ref__}, :start, interp) do
            {:yielded, _, _, i1} -> v
            {:done, _r, i1} -> :done_no_more
            {:thrown, u, i1} -> {:thrown_early, u, i1}
          end
        end

      case resume_v do
        {:done_no_more} ->
          obj2 = Eval.get_object(interp, {:object, obj.__ref__})
          {:ok, {:null, obj2}, interp}

        {:thrown_early, u, i1} ->
          {{:unwind, u}, nil, i1}

        vv ->
          case Eval.gen_resume({:object, obj.__ref__}, vv, interp) do
            {:yielded, _k, _v, i2} ->
              obj2 = Eval.get_object(i2, {:object, obj.__ref__})
              st = gen_state_of(obj2)
              cur = if st.done, do: :null, else: st.v
              {:ok, {cur, obj2}, i2}

            {:done, _ret, i2} ->
              obj2 = Eval.get_object(i2, {:object, obj.__ref__})
              {:ok, {:null, obj2}, i2}

            {:thrown, u, i2} ->
              {{:unwind, u}, nil, i2}
          end
      end
    end
  end

  defp gen_native_rewind(obj, _args, interp) do
    st = gen_state_of(obj)

    if st.started do
      # php throws Exception "Cannot rewind a generator that was already run"
      native_gen_throw(
        interp,
        "Exception",
        "Cannot rewind a generator that was already run",
        "rewind"
      )
    else
      case Eval.gen_resume({:object, obj.__ref__}, :start, interp) do
        {:yielded, _k, _v, i2} ->
          obj2 = Eval.get_object(i2, {:object, obj.__ref__})
          {:ok, {:null, obj2}, i2}

        {:done, _ret, i2} ->
          obj2 = Eval.get_object(i2, {:object, obj.__ref__})
          {:ok, {:null, obj2}, i2}

        {:thrown, u, i2} ->
          {{:unwind, u}, nil, i2}
      end
    end
  end

  defp gen_native_get_return(obj, _args, interp) do
    st = gen_state_of(obj)

    if st.done do
      {:ok, {st.ret, obj}, interp}
    else
      native_gen_throw(
        interp,
        "Error",
        "Cannot get return value of a generator that hasn't returned",
        "getReturn"
      )
    end
  end

  # materialize + php-style Generator frame: catch bindings and get_class()
  # expect a real object in the registry
  defp native_gen_throw(interp, class, msg, meth) do
    i2 = PhpBeam.Interp.push_frame(interp, "Generator->#{meth}()")
    {obj_ref, i3} = Eval.materialize_native({:native_error, class, msg}, i2)
    {{:unwind, {:php_throw, obj_ref}}, nil, i3}
  end

  defp native_iface(name, parent \\ nil) do
    %__MODULE__{
      name: name,
      kind: :interface,
      parent: parent,
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{}
    }
  end

  # minimal native Closure: composer's ClassLoader uses Closure::bind()
  # (scope stripping only — our closures already carry their capture context)
  # WeakMap (v1: STRONG storage keyed "wk<objid>" in props — the weak
  # reaping needs liveness hooks; registered in docs/matrix/deferred.md.
  # foreach key shape (object keys) approximated: iterator yields values).
  defp native_weakmap_class do
    wk_key = fn {:object, id} -> {:string, "wk#{id}"} end

    %__MODULE__{
      name: "WeakMap",
      kind: :class,
      parent: nil,
      interfaces: ["arrayaccess", "countable", "traversable"],
      consts: %{},
      props: [],
      methods: %{
        "__construct" => native_fn("__construct", fn obj, _a, i -> {:ok, {:null, obj}, i} end),
        "offsetexists" =>
          native_fn("offsetExists", fn obj, args, i ->
            case args do
              [{:object, _} = ref | _] ->
                v = PArray.get(obj.props, wk_key.(ref))
                {:ok, {{:bool, v != nil and v != :null}, obj}, i}

              _ ->
                {:ok, {{:bool, false}, obj}, i}
            end
          end),
        "offsetget" =>
          native_fn("offsetGet", fn obj, args, i ->
            case args do
              [{:object, _} = ref | _] ->
                case PArray.get(obj.props, wk_key.(ref)) do
                  nil -> {:ok, {:null, obj}, i}
                  v -> {:ok, {v, obj}, i}
                end

              _ ->
                {:ok, {:null, obj}, i}
            end
          end),
        "offsetset" =>
          native_fn("offsetSet", fn obj, args, i ->
            case args do
              [{:object, _} = ref, v | _] ->
                case PArray.put(obj.props, wk_key.(ref), v) do
                  {:ok, p2} -> {:ok, {:null, %{obj | props: p2}}, i}
                  _ -> {:ok, {:null, obj}, i}
                end

              _ ->
                {:ok, {:null, obj}, i}
            end
          end),
        "offsetunset" =>
          native_fn("offsetUnset", fn obj, args, i ->
            case args do
              [{:object, _} = ref | _] ->
                case PArray.delete(obj.props, wk_key.(ref)) do
                  {:ok, p2} -> {:ok, {:null, %{obj | props: p2}}, i}
                  _ -> {:ok, {:null, obj}, i}
                end

              _ ->
                {:ok, {:null, obj}, i}
            end
          end),
        "count" =>
          native_fn("count", fn obj, _a, i ->
            n =
              obj.props
              |> PArray.to_pairs()
              |> Enum.count(fn {k, _} -> is_binary(k) and String.starts_with?(k, "wk") end)

            {:ok, {{:int, n}, obj}, i}
          end)
      }
    }
  end

  defp native_closure_class do
    %__MODULE__{
      name: "Closure",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{
        "bind" =>
          native_fn("bind", fn _obj, args, i ->
            case args do
              # Closure::bind($closure, $newThis, $newScope): rebind $this
              # and the SCOPE class (private/protected access of that class);
              # 'static' keeps the current scope, null/absent keeps old too
              [{:closure, _, _, caps, _, _, _, _} = cl, new_this, scope | _] ->
                old =
                  Map.get(caps, :__obj_ctx) || %{this: nil, called_class: nil, scope_class: nil}

                scope_key =
                  case scope do
                    {:string, s} when s != "static" ->
                      PhpBeam.Eval.resolve_class_string(s, i)

                    {:object, _} = oref ->
                      PhpBeam.Eval.get_object(i, oref).class

                    _ ->
                      nil
                  end

                ctx = %{
                  old
                  | this: keep_obj(new_this) || old.this,
                    scope_class: scope_key || old.scope_class,
                    called_class: scope_key || old.called_class
                }

                bound = put_elem(cl, 3, Map.put(caps, :__obj_ctx, ctx))
                {:ok, {bound, nil}, i}

              [cl | _] ->
                {:ok, {cl, nil}, i}

              _ ->
                {:ok, {:null, nil}, i}
            end
          end)
          |> Map.put(:static?, true),
        "fromcallable" => %{
          native_fn("fromCallable", fn _obj, args, i ->
            [cb | _] = args
            {:ok, {cb, nil}, i}
          end)
          | static?: true
        },
        "call" => %{
          native_fn("call", fn _obj, _args, i ->
            {:ok, {:null, nil}, i}
          end)
          | static?: true
        }
      },
      file: ""
    }
  end

  defp keep_obj({:object, _} = o), do: o
  defp keep_obj(_), do: nil

  defp native_stdclass do
    %__MODULE__{
      name: "stdClass",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{},
      file: ""
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
        readonly?: false,
        default: {:string, ""}
      },
      %{
        name: "code",
        display: "code",
        visibility: :protected,
        static?: false,
        readonly?: false,
        default: {:int, 0}
      },
      %{
        name: "file",
        display: "file",
        visibility: :protected,
        static?: false,
        readonly?: false,
        default: {:string, "php"}
      },
      %{
        name: "line",
        display: "line",
        visibility: :protected,
        static?: false,
        readonly?: false,
        default: {:int, 0}
      },
      %{
        name: "previous",
        display: "previous",
        visibility: :protected,
        static?: false,
        readonly?: false,
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

  defp native_fn_static(name, fun) do
    %{native_fn(name, fun) | static?: true}
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

  # object registry ops (instantiate/exception_info/instance_of?) live in
  # PhpBeam.Objects; interp.ex still reaches exception_info through here
  defdelegate exception_info(interp, ref), to: PhpBeam.Objects

  defp native_get(obj, name), do: PArray.get(obj.props, {:string, name}, :null)
end
