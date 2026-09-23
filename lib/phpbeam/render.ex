defmodule PhpBeam.Render do
  @moduledoc """
  PHP-var rendering: `var_dump`, `print_r`, `var_export`, `json` — formatting
  pinned against PHP 8.4 output probes.
  """

  alias PhpBeam.{Eval, PArray, Value}

  def var_dump_lines(v, interp, indent \\ 0)

  def var_dump_lines({:int, n}, _interp, ind), do: [pad2(ind), "int(#{n})\n"]

  def var_dump_lines({:float, f}, _interp, ind),
    do: [pad2(ind), "float(#{Value.float_serialize(f)})\n"]

  def var_dump_lines({:bool, true}, _interp, ind), do: [pad2(ind), "bool(true)\n"]
  def var_dump_lines({:bool, false}, _interp, ind), do: [pad2(ind), "bool(false)\n"]
  def var_dump_lines(:null, _interp, ind), do: [pad2(ind), "NULL\n"]

  def var_dump_lines({:string, s}, _interp, ind),
    do: [pad2(ind), "string(#{byte_size(s)}) \"#{s}\"\n"]

  def var_dump_lines({:array, arr}, interp, ind) do
    pad = String.duplicate("  ", ind)
    inner = String.duplicate("  ", ind + 1)

    [
      pad2(ind),
      "array(#{PArray.size(arr)}) {\n"
      | Enum.flat_map(PArray.to_pairs(arr), fn {k, v} ->
          [
            "#{inner}[#{dump_key(k)}]=>\n"
            | var_dump_lines(deref(v, interp), interp, ind + 1)
          ]
        end)
    ] ++ ["#{pad}}\n"]
  end

  def var_dump_lines({:ref, _} = r, interp, ind),
    do: var_dump_lines(Eval.deref(r, interp), interp, ind)

  def var_dump_lines({:object, %{class: cls, props: props, __ref__: ref}}, interp, ind) do
    pad = pad2(ind)
    inner = pad2(ind + 1)

    [
      "#{pad}object(#{cls})##{ref} (#{PArray.size(props)}) {\n"
      | Enum.flat_map(PArray.to_pairs(props), fn {k, v} ->
          [
            "#{inner}[\"#{k}\"]=>\n"
            | var_dump_lines(deref(v, interp), interp, ind + 1)
          ]
        end)
    ] ++ ["#{pad}}\n"]
  end

  def var_dump_lines(_, _interp, _ind), do: ["object\n"]

  defp pad2(ind), do: String.duplicate("  ", ind)

  defp dump_key(k) when is_integer(k), do: Integer.to_string(k)
  defp dump_key(k) when is_binary(k), do: k

  defp deref({:ref, id}, interp), do: Map.get(interp.refs, id, :null)
  defp deref(v, _), do: v

  # ───────────────────────── print_r ─────────────────────────

  def print_r(v, interp, ind \\ 0)

  def print_r({:array, arr}, interp, ind) do
    pad = String.duplicate("    ", ind)

    inner =
      Enum.flat_map(PArray.to_pairs(arr), fn {k, v} ->
        key = if is_integer(k), do: Integer.to_string(k), else: k
        ["#{pad}    [#{key}] => " <> nested_or_scalar(v, interp, ind + 1)]
      end)

    inner_joined = Enum.join(inner)
    "Array\n(\n" <> inner_joined <> "#{pad})\n"
  end

  def print_r({:ref, _} = r, interp, ind), do: print_r(deref(r, interp), interp, ind)
  def print_r(v, _interp, _ind), do: scalar_string(v)

  defp nested_or_scalar({:array, _} = v, interp, ind_next) do
    "Array\n" <>
      String.duplicate("    ", ind_next + 1) <>
      "(\n" <>
      nested_entries(v, interp, ind_next) <>
      String.duplicate("    ", ind_next + 1) <> ")\n\n"
  end

  defp nested_or_scalar({:ref, _} = r, interp, ind_next),
    do: nested_or_scalar(deref(r, interp), interp, ind_next)

  defp nested_or_scalar(v, _interp, _ind), do: scalar_string(v) <> "\n"

  defp nested_entries({:array, arr}, interp, ind_next) do
    pad = String.duplicate("    ", ind_next + 2)

    Enum.map_join(PArray.to_pairs(arr), fn {k, v} ->
      key = if is_integer(k), do: Integer.to_string(k), else: k
      "#{pad}[#{key}] => " <> nested_or_scalar(v, interp, ind_next + 1)
    end)
  end

  def scalar_string({:int, n}), do: Integer.to_string(n)
  def scalar_string({:float, f}), do: Value.float_to_string(f)
  def scalar_string({:bool, true}), do: "1"
  def scalar_string({:bool, false}), do: ""
  def scalar_string(:null), do: ""
  def scalar_string({:string, s}), do: s

  # ───────────────────────── var_export ─────────────────────────

  def var_export(v, interp, ind \\ 0)

  def var_export({:int, n}, _i, _ind), do: Integer.to_string(n)
  def var_export({:float, f}, _i, _ind), do: Value.float_serialize(f)
  def var_export({:bool, true}, _i, _ind), do: "true"
  def var_export({:bool, false}, _i, _ind), do: "false"
  def var_export(:null, _i, _ind), do: "NULL"
  def var_export({:string, s}, _i, _ind), do: "'#{escape_sq(s)}'"

  def var_export({:array, arr}, interp, ind) do
    pad = String.duplicate("  ", ind + 1)

    body =
      Enum.map_join(PArray.to_pairs(arr), ",\n", fn {k, v} ->
        key = if is_integer(k), do: Integer.to_string(k), else: "'#{escape_sq(k)}'"
        "#{pad}#{key} => " <> var_export(deref(v, interp), interp, ind + 1)
      end)

    if body == "" do
      "array (\n#{pad})"
    else
      "array (\n#{body},\n#{String.duplicate("  ", ind)})"
    end
  end

  def var_export({:ref, _} = r, interp, ind), do: var_export(deref(r, interp), interp, ind)

  defp escape_sq(s), do: String.replace(s, "'", "\\'")
end
