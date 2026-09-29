defmodule PhpBeam.XmlTree do
  @moduledoc """
  The shared XML core: parse into a normalized tree and render it back.
  Node shape: %{name: binary, attrs: %{binary => binary}, children: [node],
  text: binary}. The expat struct view (xml_parse_into_struct) and the
  DOM/SimpleXML surfaces all consume this tree.
  """

  @type xmlnode :: %{name: String.t(), attrs: %{String.t() => String.t()}, children: [xmlnode()], text: String.t()}

  def parse(bin) do
    # xmerl signals malformed input as an EXIT (:fatal tuples from the
    # scanner), which uncatchable-crashes the interpreter — isolate
    parent = self()

    spawn(fn ->
      send(parent, scan_result(bin))
    end)

    receive do
      {:xml_ok, el} -> {:ok, strip_ws(el)}
      {:xml_err, _} -> :error
    after
      3000 -> :error
    end
  end

  defp scan_result(bin) do
    case :xmerl_scan.string(:erlang.binary_to_list(bin), quiet: true) do
      {el, _} -> {:xml_ok, el}
      _ -> {:xml_err, :bad}
    end
  catch
    _, _ -> {:xml_err, :bad}
  end

  # xmerl element: {:xmlElement, tag, _parents, _pos, _nsinfo, _ns,
  # attrs, content, ...}; text: {:xmlText, ..., value}
  defp strip_ws({:xmlElement, tag, _, _, _, _, _, attrs, content, _, _, _}) do
    kids =
      content
      |> Enum.filter(&is_tuple/1)
      |> Enum.reject(fn
        {:xmlText, _, _, _, value, _} -> String.trim(List.to_string(value)) == ""
        _ -> false
      end)

    {children, texts} = Enum.split_with(kids, &match?({:xmlElement, _, _, _, _, _, _, _, _, _, _, _}, &1))

    text =
      texts
      |> Enum.map(fn {:xmlText, _, _, _, v, _} -> List.to_string(v) end)
      |> Enum.join()

    %{
      name: Atom.to_string(tag),
      attrs: parse_attrs(attrs),
      children: Enum.map(children, &strip_ws/1),
      text: text
    }
  end

  defp strip_ws(other) do
    # unhandled xmerl node shape — surface it once instead of swallowing
    File.write!("/tmp/xml_dbg.txt", Integer.to_string(tuple_size(other)) <> "|" <> inspect(other, limit: 8, printable_limit: 10))
    %{name: "#other", attrs: %{}, children: [], text: ""}
  end

  defp parse_attrs(attrs) do
    Map.new(attrs || [], fn {:xmlAttribute, k, _, _, _, _, _, _, v, _} ->
      {Atom.to_string(k), List.to_string(v)}
    end)
  end

  # ────────────────────────── expat struct view ──────────────────────────

  @doc """
  php xml_parse_into_struct value rows: open/complete/close triples with
  uppercased tags, level, attributes and value; plus the index map of
  tag → [row numbers] (probed shape).
  """
  def to_struct_rows(root) do
    {rows, _} = walk(root, 1, [], [])
    rows = Enum.reverse(rows)

    index =
      rows
      |> Enum.with_index()
      |> Enum.group_by(fn {%{tag: t}, _} -> t end, fn {_, i} -> i end)

    {rows, index}
  end

  defp walk(node, level, acc, idx) do
    a = node.attrs

    attrs =
      if map_size(a) == 0 do
        []
      else
        [attributes: a]
      end

    case node.children do
      [] ->
        row = %{tag: String.upcase(node.name), type: "complete", level: level}
        # php's key order: attributes BEFORE value (probed)
        row = if attrs != [], do: Map.merge(row, Map.new(attrs)), else: row
        row = if node.text != "", do: Map.put(row, :value, node.text), else: row
        {[row | acc], idx}

      kids ->
        open = %{tag: String.upcase(node.name), type: "open", level: level}
        open = if attrs != [], do: Map.merge(open, Map.new(attrs)), else: open
        close = %{tag: String.upcase(node.name), type: "close", level: level}

        # document order: children rows between open and close
        {inner, _} =
          Enum.reduce(kids, {[], idx}, fn k, {a2, i2} ->
            walk(k, level + 1, a2, i2)
          end)

        # acc is head-accumulated and the CALLER reverses the whole chain
        # at the end — children keep their head-insert (reversed) order here
        acc2 = [close | inner ++ [open]] ++ acc

        {acc2, idx}
    end
  end

  # ────────────────────────── rendering ──────────────────────────

  @doc "serialize with php's formatting (attributes as-is, no self-close unless empty)"
  def render(node), do: render_node(node)

  defp render_node(n) do
    attrs =
      Enum.map_join(n.attrs, "", fn {k, v} -> " #{k}=\"#{v}\"" end)

    inner = n.text <> Enum.map_join(n.children, "", &render_node/1)

    if inner == "" do
      "<#{n.name}#{attrs}/>"
    else
      "<#{n.name}#{attrs}>#{inner}</#{n.name}>"
    end
  end

  @doc "the asXML() full-document form (php prepends the xml declaration)"
  def render_doc(node) do
    "<?xml version=\"1.0\"?>\n" <> render_node(node) <> "\n"
  end

  # ────────────────────────── query helpers ──────────────────────────

  @doc "find children by name (case-sensitive like php DOM, exact)"
  def children_named(node, name), do: Enum.filter(node.children, &(&1.name == name))

  @doc "collect all descendant nodes (document order)"
  def descendants(node) do
    Enum.flat_map(node.children, fn c -> [c | descendants(c)] end)
  end

  @doc "a minimal xpath subset: //tag, /root/tag, //tag[@attr] — enough for
  library probing; full XPath is deferred"
  def xpath(node, path) do
    cond do
      String.starts_with?(path, "//") ->
        rest = String.trim_leading(path, "/")
        {tag, attr} = split_pred(rest)

        descendants(node)
        |> Enum.filter(&match_tag(&1, tag))
        |> Enum.filter(&(attr == nil or Map.has_key?(&1.attrs, attr)))

      String.starts_with?(path, "/") ->
        [root | segs] = String.split(String.trim_leading(path, "/"), "/")

        if root == node.name do
          follow(node, segs)
        else
          []
        end

      true ->
        children_named(node, path)
    end
  end

  defp split_pred(s) do
    case Regex.run(~r/^(.*?)\[@(.+?)\]$/, s) do
      [_, tag, attr] -> {tag, attr}
      _ -> {s, nil}
    end
  end

  defp match_tag(_, "*"), do: true
  defp match_tag(n, t), do: n.name == t

  defp follow(node, []), do: [node]

  defp follow(node, [seg | rest]) do
    {tag, attr} = split_pred(seg)

    children_named(node, tag)
    |> Enum.filter(&(attr == nil or Map.has_key?(&1.attrs, attr)))
    |> Enum.flat_map(&follow(&1, rest))
  end
end
