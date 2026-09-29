defmodule PhpBeam.Builtin.XmlFns do
  @moduledoc """
  ext/xml (the expat layer) over PhpBeam.XmlTree: parser-create/free
  bookkeeping, xml_parse_into_struct producing php's probed row shape
  (uppercased tags, open/complete/close levels, attributes maps, value
  text, plus the tag → row-index map), utf8_encode/decode passthroughs.
  """

  alias PhpBeam.{Eval, PArray, XmlTree}

  def register(fns) do
    entries = %{
      "xml_parser_create" => &parser_create/2,
      "xml_parser_create_ns" => &parser_create/2,
      "xml_parser_free" => &noop_true/2,
      "xml_parser_set_option" => &noop_true/2,
      "xml_parser_get_option" => &get_option/2,
      "xml_parse" => &xml_parse/2,
      "xml_parse_into_struct" => &parse_into_struct/2,
      "xml_error_string" => &error_string/2,
      "xml_get_error_code" => &get_error_code/2,
      "xml_get_current_line_number" => &line_number/2,
      "xml_get_current_column_number" => &zero/2,
      "xml_get_current_byte_index" => &zero/2,
      "xml_get_current_byte_count" => &zero/2,
      "xml_set_character_data_handler" => &noop_true/2,
      "xml_set_element_handler" => &noop_true/2,
      "xml_set_default_handler" => &noop_true/2,
      "xml_set_object" => &noop_true/2,
      "xml_utf8_encode" => &utf8_encode/2,
      "xml_utf8_decode" => &utf8_decode/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)
      |> Map.merge(%{
        "xml_parse_into_struct" => %{
          fun: fn v, i, _c -> parse_into_struct(v, i) end,
          refs: [2, 3],
          skip_eval_refs: [2, 3]
        }
      })

    Map.merge(fns, wrapped)
    |> Map.merge(PhpBeam.Classes.SimpleXml.load_entries())
  end

  def classes do
    %{"xmlparser" => shell("XMLParser")}
  end

  defp shell(name) do
    alias PhpBeam.Classes.Table

    struct(Table,
      name: name,
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{},
      file: ""
    )
  end

  defp noop_true(_v, i), do: {:ok, {:bool, true}, i}
  defp zero(_v, i), do: {:ok, {:int, 0}, i}

  defp parser_create(_vals, i) do
    {ref, i2} = Eval.make_instance(i, "xmlparser")
    o = Eval.get_object(i2, ref)
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, %{}))
    {:ok, ref, i3}
  end

  defp get_option(_vals, i), do: {:ok, {:int, 1}, i}

  defp xml_parse(vals, i) do
    data = str_at(vals, 0, "")

    case XmlTree.parse(data) do
      {:ok, _} -> {:ok, {:int, 1}, i}
      _ -> {:ok, {:int, 0}, i}
    end
  end

  defp parse_into_struct(vals, i) do
    # signature: ($parser, $data, &$values, &$index) — outputs at 2/3
    data = str_at(vals, 1, "")

    case XmlTree.parse(data) do
      {:ok, tree} ->
        {rows, index} = XmlTree.to_struct_rows(tree)

        rows_arr =
          PArray.from_pairs(
            rows
            |> Enum.with_index()
            |> Enum.map(fn {r, k} ->
              pairs =
                [{"tag", {:string, r.tag}}, {"type", {:string, r.type}}, {"level", {:int, r.level}}] ++
                  (case r do
                    %{attributes: a} ->
                      [{"attributes", {:array, PArray.from_pairs(Enum.map(a, fn {ak, av} -> {String.upcase(ak), {:string, av}} end))}}]

                    _ ->
                      []
                  end) ++
                  (case r do
                    %{value: v} -> [{"value", {:string, v}}]
                    _ -> []
                  end)

              {k, {:array, PArray.from_pairs(pairs)}}
            end)
          )

        idx_arr =
          PArray.from_pairs(
            Enum.map(index, fn {tag, ks} ->
              {tag, {:array, PArray.from_pairs(Enum.map(ks, &{nil, {:int, &1}}))}}
            end)
          )

        nv =
          vals
          |> Enum.take(4)
          |> List.replace_at(2, {:array, rows_arr})
          |> List.replace_at(3, {:array, idx_arr})

        {:ref_call, {:int, 1}, nv, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp error_string(vals, i) do
    case int_at(vals, 0, 0) do
      0 -> {:ok, {:string, ""}, i}
      _ -> {:ok, {:string, "Not well-formed (invalid token)"}, i}
    end
  end

  defp get_error_code(_vals, i), do: {:ok, {:int, 0}, i}
  defp line_number(_vals, i), do: {:ok, {:int, 1}, i}

  defp utf8_encode(vals, i), do: {:ok, {:string, str_at(vals, 0, "")}, i}
  defp utf8_decode(vals, i), do: {:ok, {:string, str_at(vals, 0, "")}, i}

  defp str_at(vals, pos, default) do
    case Enum.at(vals, pos) do
      {:string, s} -> s
      _ -> default
    end
  end

  defp int_at(vals, pos, default) do
    case Enum.at(vals, pos) do
      {:int, n} -> n
      _ -> default
    end
  end
end
