defmodule PhpBeam.Builtin.ObFns do
  @moduledoc """
  Output buffering: an ob stack on the interpreter. `Interp.write/2`
  diverts into the innermost open buffer; flush functions write through
  to the enclosing layer (or stdout at level 0).

  Callbacks passed to `ob_start(callable, ...)` are stored but not yet
  invoked at close time.
  """

  alias PhpBeam.PArray

  def register(fns) do
    entries = %{
      "ob_start" => &ob_start/2,
      "ob_get_clean" => &ob_get_clean/2,
      "ob_end_clean" => &ob_end_clean/2,
      "ob_get_contents" => &ob_get_contents/2,
      "ob_clean" => &ob_clean/2,
      "ob_get_length" => &ob_get_length/2,
      "ob_get_level" => &ob_get_level/2,
      "ob_end_flush" => &ob_end_flush/2,
      "ob_flush" => &ob_flush/2,
      "ob_get_flush" => &ob_get_flush/2,
      "ob_list_handlers" => &ob_list_handlers/2,
      "ob_implicit_flush" => &ob_implicit_flush/2,
      "flush" => &flush_v/2
    }

    Enum.reduce(entries, fns, fn {name, fun}, acc ->
      Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
    end)
  end

  ## ─────────────────────────── stack ops ───────────────────────────

  defp ob_start(vals, i) do
    cb =
      case vals do
        [c | _] when c != :null and c != {:bool, false} -> c
        _ -> nil
      end

    {:ok, {:bool, true},
     %{i | ob_stack: [%{buf: [], cb: cb, name: "default output handler"} | i.ob_stack]}}
  end

  defp ob_get_clean(_vals, i) do
    case pop(i) do
      {top, i2} -> {:ok, {:string, contents(top)}, i2}
      nil -> {:ok, {:bool, false}, i}
    end
  end

  defp ob_end_clean(_vals, i) do
    case pop(i) do
      {_top, i2} -> {:ok, {:bool, true}, i2}
      nil -> {:ok, {:bool, false}, i}
    end
  end

  defp ob_get_contents(_vals, i) do
    case i.ob_stack do
      [top | _] -> {:ok, {:string, contents(top)}, i}
      [] -> {:ok, {:bool, false}, i}
    end
  end

  defp ob_clean(_vals, i) do
    case i.ob_stack do
      [top | rest] -> {:ok, {:bool, true}, %{i | ob_stack: [%{top | buf: []} | rest]}}
      [] -> {:ok, {:bool, false}, i}
    end
  end

  defp ob_get_length(_vals, i) do
    case i.ob_stack do
      [top | _] -> {:ok, {:int, byte_size(contents(top))}, i}
      [] -> {:ok, {:bool, false}, i}
    end
  end

  defp ob_get_level(_vals, i), do: {:ok, {:int, length(i.ob_stack)}, i}

  defp ob_end_flush(_vals, i) do
    case pop(i) do
      {top, i2} -> {:ok, {:bool, true}, PhpBeam.Interp.write(i2, contents(top))}
      nil -> {:ok, {:bool, false}, i}
    end
  end

  # flush the innermost buffer's contents to the enclosing layer; the
  # buffer stays open and empty
  defp ob_flush(_vals, i) do
    case i.ob_stack do
      [top | rest] ->
        i2 = PhpBeam.Interp.write(%{i | ob_stack: rest}, contents(top))
        {:ok, {:bool, true}, %{i2 | ob_stack: [%{top | buf: []} | i2.ob_stack]}}

      [] ->
        {:ok, {:bool, false}, i}
    end
  end

  # PHP's ob_get_flush: return contents, then end+flush
  defp ob_get_flush(_vals, i) do
    case pop(i) do
      {top, i2} -> {:ok, {:string, contents(top)}, PhpBeam.Interp.write(i2, contents(top))}
      nil -> {:ok, {:bool, false}, i}
    end
  end

  defp ob_list_handlers(_vals, i) do
    names = PArray.from_pairs(Enum.map(i.ob_stack, &{nil, {:string, &1.name}}))
    {:ok, {:array, names}, i}
  end

  defp ob_implicit_flush(_vals, i), do: {:ok, :null, i}

  defp flush_v(_vals, i), do: {:ok, {:bool, true}, i}

  ## ─────────────────────────── helpers ───────────────────────────

  defp pop(%{ob_stack: [top | rest]} = i), do: {top, %{i | ob_stack: rest}}
  defp pop(%{ob_stack: []}), do: nil

  defp contents(top), do: top.buf |> Enum.reverse() |> IO.iodata_to_binary()
end
