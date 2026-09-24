defmodule PhpBeam.Builtin.CursorFns do
  @moduledoc """
  Array cursor functions. `current`/`key` are read-only; the movers
  (`next`/`prev`/`reset`/`end`) are by-ref: they write the moved array
  back through `{:ref_call, _, [new_array], _}`.
  """

  alias PhpBeam.PArray

  def register(fns) do
    read_only =
      %{
        "current" => &current_v/2,
        "pos" => &current_v/2,
        "key" => &key_v/2
      }
      |> Enum.map(fn {name, fun} -> {name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []}} end)

    movers =
      %{
        "next" => {:mover, 1},
        "prev" => {:mover, -1},
        "reset" => :first,
        "end" => :last
      }
      |> Enum.map(fn {name, mode} ->
        {name,
         %{
           fun: fn v, i, _c -> move(mode, v, i) end,
           refs: [0]
         }}
      end)

    Enum.reduce(read_only ++ movers, fns, fn {name, entry}, acc ->
      Map.put(acc, name, entry)
    end)
  end

  defp current_v([{:array, arr} | _], i) do
    case PArray.cursor_entry(arr) do
      {:ok, _k, v} -> {:ok, v, i}
      :error -> {:ok, {:bool, false}, i}
    end
  end

  defp current_v(_, i), do: {:ok, {:bool, false}, i}

  defp key_v([{:array, arr} | _], i) do
    case PArray.cursor_entry(arr) do
      {:ok, k, _v} -> {:ok, wrap_key(k), i}
      :error -> {:ok, :null, i}
    end
  end

  defp key_v(_, i), do: {:ok, :null, i}

  defp wrap_key(k) when is_integer(k), do: {:int, k}
  defp wrap_key(k) when is_binary(k), do: {:string, k}

  defp move(mode, [{:array, arr} | _], i) do
    {entry, arr2} =
      case mode do
        {:mover, delta} -> PArray.cursor_move(arr, delta)
        :first -> PArray.cursor_first(arr)
        :last -> PArray.cursor_last(arr)
      end

    case entry do
      {:ok, _k, v} -> {:ref_call, v, [{:array, arr2}], i}
      :error -> {:ref_call, {:bool, false}, [{:array, arr2}], i}
    end
  end

  defp move(_, _, i), do: {:ok, {:bool, false}, i}
end
