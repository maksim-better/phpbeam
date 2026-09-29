defmodule PhpBeam.Classes.SimpleXml do
  @moduledoc """
  ext/simplexml: SimpleXMLElement over PhpBeam.XmlTree nodes (dt_state
  %{node:, doc_root:}). Child-element reads ride __get (name → first
  child or repeated-name set), attribute reads through ArrayAccess
  ($e["attr"]), asXML/attributes/children/count/xpath, and the
  simplexml_load_string/file builtin entries.
  """

  alias PhpBeam.Classes.Table
  alias PhpBeam.{Eval, PArray, XmlTree}

  def classes do
    methods =
      Map.new(
        [
          nfn("offsetget", fn obj, a, i ->
            st = Map.get(obj, :dt_state) || %{}

            case a do
              [{:int, idx} | _] ->
                case Map.get(st, :sibs) do
                  sibs when is_list(sibs) ->
                    case Enum.at(sibs, idx) do
                      nil -> {:ok, :null, obj, i}
                      n -> {r2, i2} = sxe(i, n, Map.get(st, :root)); {:ok, r2, obj, i2}
                    end

                  _ ->
                    {:ok, :null, obj, i}
                end

              _ ->
                key = str0(a)
                node = node_of(obj)

                case Map.get(node.attrs, key) do
                  nil -> {:ok, :null, obj, i}
                  v -> {:ok, {:string, v}, obj, i}
                end
            end
          end),
          nfn("offsetexists", fn obj, a, i ->
            {:ok, {:bool, Map.has_key?(node_of(obj).attrs, str0(a))}, obj, i}
          end),
          nfn("offsetset", fn obj, a, i ->
            node = node_of(obj)

            node2 = %{node | attrs: Map.put(node.attrs, str0(a), str_at(a, 1, ""))}
            {:ok, :null, Map.put(obj, :dt_state, Map.put(obj.dt_state, :node, node2)), i}
          end),
          nfn("offsetunset", fn obj, a, i ->
            node = node_of(obj)
            node2 = %{node | attrs: Map.delete(node.attrs, str0(a))}
            {:ok, :null, Map.put(obj, :dt_state, Map.put(obj.dt_state, :node, node2)), i}
          end),
          nfn("rewind", fn obj, _a, i ->
            st = Map.get(obj, :dt_state) || %{}
            list = Map.get(st, :sibs) || node_of(obj).children
            st2 = Map.put(st, :iter, 0) |> Map.put(:iter_list, list)
            {:ok, :null, Map.put(obj, :dt_state, st2), i}
          end),
          nfn("valid", fn obj, _a, i ->
            st = Map.get(obj, :dt_state) || %{}
            n = Map.get(st, :iter, 0)
            list = Map.get(st, :iter_list) || []
            {:ok, {:bool, n < length(list)}, obj, i}
          end),
          nfn("current", fn obj, _a, i ->
            st = Map.get(obj, :dt_state) || %{}
            n = Map.get(st, :iter, 0)
            list = Map.get(st, :iter_list) || []

            case Enum.at(list, n) do
              nil -> {:ok, :null, obj, i}
              node -> {r2, i2} = sxe(i, node, Map.get(st, :root)); {:ok, r2, obj, i2}
            end
          end),
          nfn("key", fn obj, _a, i ->
            st = Map.get(obj, :dt_state) || %{}
            {:ok, {:int, Map.get(st, :iter, 0)}, obj, i}
          end),
          nfn("next", fn obj, _a, i ->
            st = Map.get(obj, :dt_state) || %{}
            st2 = Map.put(st, :iter, Map.get(st, :iter, 0) + 1)
            {:ok, :null, Map.put(obj, :dt_state, st2), i}
          end),
          nfn("__get", fn obj, a, i ->
            name = str0(a)

            case child_get(i, {:object, obj.__ref__}, name) do
              {nil, i2} ->
                {:ok, :null, obj, i2}

              {{:object_val, r}, i2} ->
                {:ok, r, obj, i2}
            end
          end),
          nfn("__construct", fn obj, a, i ->
            case a do
              [{:string, data} | _] ->
                case XmlTree.parse(data) do
                  {:ok, tree} ->
                    {:ok, :null, Map.put(obj, :dt_state, %{node: tree, root: tree}), i}

                  _ ->
                    exc(i, "String could not be parsed as XML")
                end

              _ ->
                {:ok, :null, obj, i}
            end
          end),
          nfn("asxml", fn obj, _a, i ->
            st = obj.dt_state || %{}

            case Map.get(st, :node) do
              nil -> {:ok, {:bool, false}, obj, i}
              node -> {:ok, {:string, XmlTree.render_doc(node)}, obj, i}
            end
          end),
          nfn("savexml", fn obj, _a, i ->
            st = obj.dt_state || %{}

            case Map.get(st, :node) do
              nil -> {:ok, {:bool, false}, obj, i}
              node -> {:ok, {:string, XmlTree.render(node)}, obj, i}
            end
          end),
          nfn("attributes", fn obj, _a, i ->
            node = node_of(obj)

            arr =
              PArray.from_pairs(Enum.map(node.attrs, fn {k, v} -> {k, {:string, v}} end))

            {:ok, {:array, arr}, obj, i}
          end),
          nfn("children", fn obj, _a, i ->
            node = node_of(obj)

            arr =
              PArray.from_pairs(Enum.map(node.children, &{nil, wrap_node(i, &1)}))

            {:ok, {:array, arr}, obj, elem(i, 2) |> then(fn _ -> i end)}
          end),
          nfn("count", fn obj, _a, i ->
            st = Map.get(obj, :dt_state) || %{}

            # repeated-name proxies count their sibling set (php: count($x->child))
            n =
              case Map.get(st, :sibs) do
                sibs when is_list(sibs) -> length(sibs)
                _ -> length(node_of(obj).children)
              end

            {:ok, {:int, n}, obj, i}
          end),
          nfn("xpath", fn obj, a, i ->
            node = node_of(obj)
            hits = XmlTree.xpath(node, str0(a))

            {refs, i2} =
              Enum.map_reduce(hits, i, fn n, acc ->
                {ref, a2} = Eval.make_instance(acc, "simplexmlelement")
                o = Eval.get_object(a2, ref)
                a3 = Eval.put_object(a2, ref, Map.put(o, :dt_state, %{node: n, root: n}))
                {ref, a3}
              end)

            arr = PArray.from_pairs(Enum.map(refs, &{nil, &1}))
            {:ok, {:array, arr}, obj, i2}
          end),
          nfn("getname", fn obj, _a, i ->
            {:ok, {:string, node_of(obj).name}, obj, i}
          end),
          nfn("tostring", fn obj, _a, i ->
            {:ok, {:string, node_of(obj).text}, obj, i}
          end),
          nfn("__tostring", fn obj, _a, i ->
            {:ok, {:string, node_of(obj).text}, obj, i}
          end),
          nfn("addchild", fn obj, a, i ->
            node = node_of(obj)
            name = str0(a)
            value = str_at(a, 1, "")
            child = %{name: name, attrs: %{}, children: [], text: value}
            node2 = %{node | children: node.children ++ [child]}
            obj2 = Map.put(obj, :dt_state, Map.put(obj.dt_state, :node, node2))
            {ref, i2} = Eval.make_instance(i, "simplexmlelement")
            o = Eval.get_object(i2, ref)
            i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, %{node: child, root: child}))
            {:ok, ref, obj2, i3}
          end),
          nfn("addattribute", fn obj, a, i ->
            node = node_of(obj)
            node2 = %{node | attrs: Map.put(node.attrs, str0(a), str_at(a, 1, ""))}
            {:ok, :null, Map.put(obj, :dt_state, Map.put(obj.dt_state, :node, node2)), i}
          end)
        ],
        &{&1.name, &1}
      )

    %{
      "simplexmlelement" =>
        struct(Table,
        name: "SimpleXMLElement",
        kind: :class,
        parent: nil,
        interfaces: ["arrayaccess", "countable", "iterator", "traversable"],
        consts: %{},
        props: [],
        methods: methods,
        file: ""
      )
    }
  end

  # the load entries (registered by XmlFns into the function table)
  def load_entries do
    %{
      "simplexml_load_string" => %{
        fun: fn v, i, _c ->
          case v do
            [{:string, data} | _] ->
              case XmlTree.parse(data) do
                {:ok, tree} ->
                  {ref, i2} = Eval.make_instance(i, "simplexmlelement")
                  o = Eval.get_object(i2, ref)
                  i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, %{node: tree, root: tree}))
                  {:ok, ref, i3}

                _ ->
                  msg = "simplexml_load_string(): Entity: line 1: parser error : Start tag expected, '<' not found"

                  i2 =
                    case PhpBeam.Eval.Error.warn(PhpBeam.Eval.Error.stub_env(), i, msg) do
                      {:cont, _, ix} -> ix
                      {:unwind, _, _, ix} -> ix
                    end

                  # php emits the offending data THEN the caret marker
                  i3 =
                    case PhpBeam.Eval.Error.warn_level(
                           PhpBeam.Eval.Error.stub_env(),
                           i2,
                           "Warning",
                           "simplexml_load_string(): " <> String.slice(data, 0, 12)
                         ) do
                      {:cont, _, ix} -> ix
                      {:unwind, _, _, ix} -> ix
                    end

                  case PhpBeam.Eval.Error.warn_level(
                         PhpBeam.Eval.Error.stub_env(),
                         i3,
                         "Warning",
                         "simplexml_load_string(): ^"
                       ) do
                    {:cont, _, ix2} -> {:ok, {:bool, false}, ix2}
                    {:unwind, u, _, ix2} -> {:unwind, u, ix2}
                  end
              end

            _ ->
              {:ok, {:bool, false}, i}
          end
        end,
        refs: []
      },
      "simplexml_load_file" => %{
        fun: fn v, i, _c ->
          case v do
            [{:string, path} | _] ->
              case File.read(path) do
                {:ok, bin} ->
                  case XmlTree.parse(bin) do
                    {:ok, tree} ->
                      {ref, i2} = Eval.make_instance(i, "simplexmlelement")
                      o = Eval.get_object(i2, ref)
                      i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, %{node: tree, root: tree}))
                      {:ok, ref, i3}

                    _ ->
                      {:ok, {:bool, false}, i}
                  end

                _ ->
                  {:ok, {:bool, false}, i}
              end

            _ ->
              {:ok, {:bool, false}, i}
          end
        end,
        refs: []
      },
      "simplexml_import_dom" => %{
        fun: fn v, i, _c ->
          case v do
            [{:object, _} = ref | _] ->
              o = Eval.get_object(i, ref)

              case Map.get(o, :dt_state) do
                %{node: node} ->
                  {r2, i2} = Eval.make_instance(i, "simplexmlelement")
                  o2 = Eval.get_object(i2, r2)
                  i3 = Eval.put_object(i2, r2, Map.put(o2, :dt_state, %{node: node, root: node}))
                  {:ok, r2, i3}

                _ ->
                  {:ok, {:bool, false}, i}
              end

            _ ->
              {:ok, {:bool, false}, i}
          end
        end,
        refs: []
      }
    }
  end

  # __get: child-element access ($x->child)
  def child_get(i, ref, name) do
    o = Eval.get_object(i, ref)
    node = node_of(o)
    hits = XmlTree.children_named(node, name)

    case hits do
      [] ->
        {nil, i}

      [only] ->
        {r2, i2} = Eval.make_instance(i, "simplexmlelement")
        o2 = Eval.get_object(i2, r2)
        i3 = Eval.put_object(i2, r2, Map.put(o2, :dt_state, %{node: only, root: node}))
        {{:object_val, r2}, i3}

      many when length(many) > 1 ->
        # multiple children: the element proxies the SET (child[0] works
        # through the array-access machinery); represent as a wrapped array
        {r2, i2} = Eval.make_instance(i, "simplexmlelement")
        o2 = Eval.get_object(i2, r2)
        i3 = Eval.put_object(i2, r2, Map.put(o2, :dt_state, %{node: hd(many), root: node, sibs: many}))
        {{:object_val, r2}, i3}
    end
  end

  defp wrap_node(_i, n), do: {:lit_node, n}

  defp sxe(i, n, root) do
    {ref, i2} = Eval.make_instance(i, "simplexmlelement")
    o = Eval.get_object(i2, ref)
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, %{node: n, root: root}))
    {ref, i3}
  end

  defp node_of(%{dt_state: %{node: n}}), do: n
  defp node_of(_), do: %{name: "", attrs: %{}, children: [], text: ""}

  defp nfn(name, fun) do
    %{
      name: name,
      visibility: :public,
      static?: false,
      abstract?: false,
      final?: false,
      params: [],
      body: [],
      class: "simplexmlelement",
      line: nil,
      gen?: false,
      native:
        {:native,
         fn obj, vals, i ->
           case fun.(obj, vals, i) do
             {:ok, ret, nil, i2} -> {:ok, {ret, obj}, i2}
             {:ok, ret, obj2, i2} -> {:ok, {ret, obj2}, i2}
             {:unwind, u, nil, i2} -> {{:unwind, u}, nil, i2}
           end
         end}
    }
  end

  defp exc(i, msg) do
    i2 = PhpBeam.Interp.push_frame(i, "SimpleXMLElement::__construct", [])

    {obj, i3} =
      Eval.materialize_native({:native_error, "Exception", msg}, i2)

    {:unwind, {:php_throw, obj}, nil, i3}
  end

  defp warn(i, msg) do
    case PhpBeam.Eval.Error.warn(PhpBeam.Eval.Error.stub_env(), i, msg) do
      {:cont, _, i2} -> {:ok, {:bool, false}, i2}
      {:unwind, u, _, i2} -> {:unwind, u, i2}
    end
  end

  defp str0(a), do: if(a == [], do: "", else: php_str(hd(a)))

  defp str_at(a, pos, default) do
    case Enum.at(a, pos) do
      {:string, s} -> s
      _ -> default
    end
  end

  defp php_str({:string, s}), do: s
  defp php_str(_), do: ""
end
