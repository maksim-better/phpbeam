defmodule PhpBeam.Classes.Dom do
  @moduledoc """
  ext/dom: DOMDocument/DOMNode/DOMElement/DOMNodeList/DOMAttr/
  DOMXPath over PhpBeam.XmlTree. Each DOM object wraps a node reference
  in dt_state; document-level ops (loadXML/saveXML/createElement/
  getElementsByTagName) live on DOMDocument, node ops (nodeName/
  nodeValue/getAttribute/setAttribute/appendChild/childNodes) on the
  element shells. Mutations rebuild the wrapped tree (no parent
  pointers — the document node is the mutation root).
  """

  alias PhpBeam.Classes.Table
  alias PhpBeam.{Eval, PArray, XmlTree}

  def classes do
    %{
      "domdocument" => doc_class(),
      "domelement" => element_class(),
      "domnode" => element_class(),
      "domtext" => element_class(),
      "domattr" => element_class(),
      "domnodelist" => nodelist_class(),
      "domxpath" => xpath_class(),
      "domexception" => exception_class(),
      "domdocumentfragment" => element_class()
    }
  end

  defp doc_class do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, _a, i -> {:ok, :null, obj, i} end),
          nfn("__get", fn obj, a, i ->
            key = str0(a)
            st = Map.get(obj, :dt_state) || %{}

            case {key, Map.get(st, :node)} do
              {"documentElement", node} when node != nil ->
                {r2, i2} = wrap_doc(i, node, {:object, obj.__ref__})
                {:ok, r2, obj, i2}

              _ ->
                {:ok, :null, obj, i}
            end
          end),
          nfn("loadxml", fn obj, a, i ->
            case a do
              [{:string, xml} | _] ->
                case XmlTree.parse(xml) do
                  {:ok, tree} ->
                    {:ok, {:bool, true}, Map.put(obj, :dt_state, %{node: tree, root: tree, doc: true}), i}

                  _ ->
                    exc(i, "Start tag expected, '<' not found")
                end

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("load", fn obj, a, i ->
            case a do
              [{:string, path} | _] ->
                case File.read(path) do
                  {:ok, bin} ->
                    case XmlTree.parse(bin) do
                      {:ok, tree} ->
                        {:ok, {:bool, true}, Map.put(obj, :dt_state, %{node: tree, root: tree, doc: true}), i}

                      _ ->
                        {:ok, {:bool, false}, obj, i}
                    end

                  _ ->
                    {:ok, {:bool, false}, obj, i}
                end

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("savexml", fn obj, a, i ->
            st = obj.dt_state || %{}

            case Map.get(st, :node) do
              nil ->
                {:ok, {:bool, false}, obj, i}

              node ->
                case a do
                  [{:object, _} = ref | _] ->
                    n = Eval.get_object(i, ref) |> then(&Map.get(&1, :dt_state)) |> then(&Map.get(&1 || %{}, :node))

                    if n,
                      do: {:ok, {:string, XmlTree.render(n)}, obj, i},
                      else: {:ok, {:string, XmlTree.render_doc(node)}, obj, i}

                  _ ->
                    {:ok, {:string, XmlTree.render_doc(node)}, obj, i}
                end
            end
          end),
          nfn("save", fn obj, a, i ->
            st = obj.dt_state || %{}

            case {Map.get(st, :node), a} do
              {nil, _} -> {:ok, {:int, 0}, obj, i}
              {node, [{:string, path} | _]} ->
                bin = XmlTree.render_doc(node)
                File.write(path, bin)
                {:ok, {:int, byte_size(bin)}, obj, i}

              {node, _} ->
                {:ok, {:int, byte_size(XmlTree.render_doc(node))}, obj, i}
            end
          end),
          nfn("createelement", fn obj, a, i ->
            name = str0(a)
            value = str_at(a, 1, "")
            node = %{name: name, attrs: %{}, children: [], text: value}
            {ref, i2} = wrap(i, node, "domelement")
            {:ok, ref, obj, i2}
          end),
          nfn("createtextnode", fn obj, a, i ->
            node = %{name: "#text", attrs: %{}, children: [], text: str0(a)}
            {ref, i2} = wrap(i, node, "domtext")
            {:ok, ref, obj, i2}
          end),
          nfn("createattribute", fn obj, a, i ->
            node = %{name: str0(a), attrs: %{}, children: [], text: ""}
            {ref, i2} = wrap(i, node, "domattr")
            {:ok, ref, obj, i2}
          end),
          nfn("getelementsbytagname", fn obj, a, i ->
            st = obj.dt_state || %{}
            tag = str0(a)

            hits =
              case Map.get(st, :node) do
                nil -> []
                root -> XmlTree.descendants(root) |> Enum.filter(&(&1.name == tag or tag == "*"))
              end

            {arr, i2} = wrap_list(hits, i)
            {ref, i3} = nodelist(i2, arr)
            {:ok, ref, obj, i3}
          end),
          nfn("getelementbyid", fn obj, _a, i ->
            {:ok, {:bool, false}, obj, i}
          end),
          nfn("createxpath", fn obj, _a, i ->
            {:ok, {:bool, false}, obj, i}
          end),
          nfn("importnode", fn obj, a, i ->
            case a do
              [{:object, _} = ref | _] ->
                n = Eval.get_object(i, ref) |> then(&Map.get(&1, :dt_state)) |> then(&Map.get(&1 || %{}, :node))
                {r2, i2} = wrap(i, n || %{name: "", attrs: %{}, children: [], text: ""}, "domelement")
                {:ok, r2, obj, i2}

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("validatedocument", fn obj, _a, i -> {:ok, {:bool, true}, obj, i} end)
        ],
        &{&1.name, &1}
      )

    struct!(Table,
      name: "DOMDocument",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: methods,
      file: ""
    )
  end

  defp element_class do
    methods =
      Map.new(
        [
          nfn("__get", fn obj, a, i ->
            key = str0(a)
            node = node_of(obj)

            case key do
              "nodeName" -> {:ok, {:string, node.name}, obj, i}
              "nodeValue" -> {:ok, {:string, node.text}, obj, i}
              "textContent" -> {:ok, {:string, node.text}, obj, i}
              "firstChild" ->
                case node.children do
                  [] -> {:ok, :null, obj, i}
                  [c | _] -> {r2, i2} = wrap(i, c, "domelement"); {:ok, r2, obj, i2}
                end
              "lastChild" ->
                case Enum.reverse(node.children) do
                  [] -> {:ok, :null, obj, i}
                  [c | _] -> {r2, i2} = wrap(i, c, "domelement"); {:ok, r2, obj, i2}
                end
              "parentNode" -> {:ok, :null, obj, i}
              "nextSibling" -> {:ok, :null, obj, i}
              "attributes" ->
                arr = PArray.from_pairs(Enum.map(node.attrs, fn {k, v} -> {k, {:string, v}} end))
                {:ok, {:array, arr}, obj, i}
              _ -> {:ok, :null, obj, i}
            end
          end),
          nfn("getnodename", fn obj, _a, i -> {:ok, {:string, node_of(obj).name}, obj, i} end),
          nfn("getnodevalue", fn obj, _a, i -> {:ok, {:string, node_of(obj).text}, obj, i} end),
          nfn("getattributenode", fn obj, _a, i -> {:ok, {:bool, false}, obj, i} end),
          nfn("getattribute", fn obj, a, i ->
            {:ok, {:string, Map.get(node_of(obj).attrs, str0(a), "")}, obj, i}
          end),
          nfn("setattribute", fn obj, a, i ->
            node = node_of(obj)
            node2 = %{node | attrs: Map.put(node.attrs, str0(a), str_at(a, 1, ""))}
            {:ok, {:bool, true}, put_node(obj, node2), i}
          end),
          nfn("hasattribute", fn obj, a, i ->
            {:ok, {:bool, Map.has_key?(node_of(obj).attrs, str0(a))}, obj, i}
          end),
          nfn("removeattribute", fn obj, a, i ->
            node = node_of(obj)
            {:ok, {:bool, true}, put_node(obj, %{node | attrs: Map.delete(node.attrs, str0(a))}), i}
          end),
          nfn("appendchild", fn obj, a, i ->
            case a do
              [{:object, _} = child_ref | _] ->
                cn =
                  Eval.get_object(i, child_ref)
                  |> then(&Map.get(&1, :dt_state))
                  |> then(&Map.get(&1 || %{}, :node))

                node = node_of(obj)
                cn2 = cn || %{name: "", attrs: %{}, children: [], text: ""}
                node2 = %{node | children: node.children ++ [cn2]}

                obj2 = put_node(obj, node2)

                # wrappers created from documentElement carry the document
                # reference — mutations must write back through it
                case Map.get(Map.get(obj, :dt_state) || %{}, :doc_ref) do
                  nil ->
                    {:ok, child_ref, obj2, i}

                  ref ->
                    doc = Eval.get_object(i, ref)

                    doc_node =
                      replace_deep(node_of(doc), node.name, node2)

                    i2 =
                      Eval.put_object(
                        i,
                        ref,
                        Map.put(doc, :dt_state, Map.put(Map.get(doc, :dt_state) || %{}, :node, doc_node))
                      )

                    {:ok, child_ref, obj2, i2}
                end

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("removechild", fn obj, _a, i -> {:ok, {:bool, false}, obj, i} end),
          nfn("getelementsbytagname", fn obj, a, i ->
            tag = str0(a)
            hits = XmlTree.descendants(node_of(obj)) |> Enum.filter(&(&1.name == tag or tag == "*"))
            {arr, i2} = wrap_list(hits, i)
            {ref, i3} = nodelist(i2, arr)
            {:ok, ref, obj, i3}
          end),
          nfn("haschildnodes", fn obj, _a, i ->
            {:ok, {:bool, node_of(obj).children != []}, obj, i}
          end),
          nfn("getfirst", fn obj, _a, i ->
            case node_of(obj).children do
              [] -> {:ok, {:bool, false}, obj, i}
              [c | _] -> {ref, i2} = wrap(i, c, "domelement"); {:ok, ref, obj, i2}
            end
          end),
          nfn("gettextcontent", fn obj, _a, i ->
            {:ok, {:string, node_of(obj).text}, obj, i}
          end),
          nfn("clonenode", fn obj, _a, i ->
            {ref, i2} = wrap(i, node_of(obj), "domelement")
            {:ok, ref, obj, i2}
          end)
        ],
        &{&1.name, &1}
      )

    struct!(Table,
      name: "DOMElement",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: methods,
      file: ""
    )
  end

  defp nodelist_class do
    methods =
      Map.new(
        [
          nfn("__get", fn obj, a, i ->
            case str0(a) do
              "length" ->
                st = Map.get(obj, :dt_state) || %{}
                {:ok, {:int, length(Map.get(st, :refs, []))}, obj, i}

              _ ->
                {:ok, :null, obj, i}
            end
          end),
          nfn("item", fn obj, a, i ->
            idx = int0(a)
            st = Map.get(obj, :dt_state) || %{}
            refs = Map.get(st, :refs, [])

            case Enum.at(refs, idx) do
              nil -> {:ok, {:bool, false}, obj, i}
              r -> {:ok, r, obj, i}
            end
          end),
          nfn("count", fn obj, _a, i ->
            st = Map.get(obj, :dt_state) || %{}
            {:ok, {:int, length(Map.get(st, :refs, []))}, obj, i}
          end)
        ],
        &{&1.name, &1}
      )

    struct!(Table,
      name: "DOMNodeList",
      kind: :class,
      parent: nil,
      interfaces: ["countable"],
      consts: %{},
      props: [],
      methods: methods,
      file: ""
    )
  end

  defp xpath_class do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, a, i ->
            case a do
              [{:object, _} = doc_ref | _] ->
                node =
                  Eval.get_object(i, doc_ref)
                  |> then(&Map.get(&1, :dt_state))
                  |> then(&Map.get(&1 || %{}, :node))

                {:ok, :null, Map.put(obj, :dt_state, %{node: node}), i}

              _ ->
                {:ok, :null, obj, i}
            end
          end),
          nfn("query", fn obj, a, i ->
            path = str0(a)
            st = Map.get(obj, :dt_state) || %{}

            hits =
              case Map.get(st, :node) do
                nil -> []
                root -> XmlTree.xpath(root, path)
              end

            {arr, i2} = wrap_list(hits, i)
            {ref, i3} = nodelist(i2, arr)
            {:ok, ref, obj, i3}
          end),
          nfn("evaluate", fn obj, a, i ->
            {:ok, {:bool, false}, obj, i}
          end)
        ],
        &{&1.name, &1}
      )

    struct!(Table,
      name: "DOMXPath",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: methods,
      file: ""
    )
  end

  defp exception_class do
    struct!(Table,
      name: "DOMException",
      kind: :class,
      parent: "exception",
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{},
      file: ""
    )
  end

  # ────────────────────────── helpers ──────────────────────────

  def wrap_doc(i, node, doc_ref) do
    {ref, i2} = Eval.make_instance(i, "domelement")
    o = Eval.get_object(i2, ref)
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, %{node: node, doc_ref: doc_ref}))
    {ref, i3}
  end

  # swap the first node with the given name (document-level write-back);
  # the document node ITSELF may be the target
  def replace_deep(%{name: name} = parent, name, new_node), do: new_node

  def replace_deep(%{children: kids} = parent, name, new_node) do
    if Enum.any?(kids, &(&1.name == name)) do
      %{parent | children: Enum.map(kids, fn k -> if k.name == name, do: new_node, else: k end)}
    else
      %{parent | children: Enum.map(kids, &replace_deep(&1, name, new_node))}
    end
  end

  def wrap(i, node, class_key) do
    {ref, i2} = Eval.make_instance(i, class_key)
    o = Eval.get_object(i2, ref)
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, %{node: node}))
    {ref, i3}
  end

  def wrap_list(nodes, i) do
    {refs, i2} =
      Enum.map_reduce(nodes, i, fn n, acc ->
        wrap(acc, n, "domelement")
      end)

    arr = PArray.from_pairs(Enum.with_index(refs, fn r, k -> {k, r} end))
    {arr, i2}
  end

  def nodelist(i, arr) do
    {ref, i2} = Eval.make_instance(i, "domnodelist")
    o = Eval.get_object(i2, ref)
    refs = Enum.map(PArray.to_pairs(arr), &elem(&1, 1))
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, %{refs: refs}))
    {ref, i3}
  end

  # make an XPath bound to a document node
  def new_xpath(i, doc_ref) do
    o = Eval.get_object(i, doc_ref)
    node = Map.get(Map.get(o, :dt_state) || %{}, :node)

    {ref, i2} = Eval.make_instance(i, "domxpath")
    o2 = Eval.get_object(i2, ref)
    i3 = Eval.put_object(i2, ref, Map.put(o2, :dt_state, %{node: node}))
    {ref, i3}
  end

  defp node_of(obj) do
    case Map.get(obj, :dt_state) do
      %{node: n} -> n
      _ -> %{name: "", attrs: %{}, children: [], text: ""}
    end
  end

  defp put_node(obj, node) do
    Map.put(obj, :dt_state, Map.put(Map.get(obj, :dt_state) || %{}, :node, node))
  end

  defp nfn(name, fun) do
    %{
      name: name,
      visibility: :public,
      static?: false,
      abstract?: false,
      final?: false,
      params: [],
      body: [],
      class: "domelement",
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
    i2 = PhpBeam.Interp.push_frame(i, "DOMDocument::loadXML", [])

    {obj, i3} =
      Eval.materialize_native({:native_error, "DOMException", msg}, i2)

    {:unwind, {:php_throw, obj}, nil, i3}
  end

  defp str0(a), do: (a != [] && php_str(hd(a))) || ""

  defp str_at(a, pos, default) do
    case Enum.at(a, pos) do
      {:string, s} -> s
      _ -> default
    end
  end

  defp int0(a) do
    case a do
      [{:int, n} | _] -> n
      _ -> 0
    end
  end

  defp php_str({:string, s}), do: s
  defp php_str(_), do: ""
end
