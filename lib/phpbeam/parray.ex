defmodule PhpBeam.PArray do
  @moduledoc """
  PHP arrays: ordered hash maps with int/string keys.

  Semantics mirrored from PHP 8:

    * insertion order is preserved (including order of re-inserted values:
      setting an existing key replaces the value in place)
    * decimal-canonical numeric string keys normalize to int keys
      (`"123"` → `123`, but `"01"` / `"-0"` / `"1.5"` stay strings)
    * auto-append (`$a[] = v`) uses `max(int keys) + 1`, or `0` when no
      integer keys exist; the high-water mark survives `unset`
    * floats/bools/null as keys coerce (`(int)` / `""`)

  Implementation: slot ids are handed out monotonically; iteration order is
  ascending slot id. Deletions leave holes, which keeps order stable.
  """

  defstruct keys: %{}, slots: %{}, next_slot: 0, next_index: nil

  @type key :: integer() | binary()
  @type t :: %__MODULE__{
          keys: %{key() => integer()},
          slots: %{integer() => {key(), PhpBeam.Value.value()}},
          next_slot: non_neg_integer(),
          next_index: integer()
        }

  alias PhpBeam.Value

  def new, do: %__MODULE__{}

  @doc "Build from `[{key_or_nil, value}]` pairs; nil key auto-appends."
  def from_pairs(pairs) do
    Enum.reduce(pairs, new(), fn
      {nil, v}, acc ->
        push(acc, v)

      {k, v}, acc ->
        case normalize_key(k) do
          {:ok, key} ->
            {:ok, arr} = do_put(acc, key, v)
            arr

          {:error, msg} ->
            raise ArgumentError, msg
        end
    end)
  end

  def size(%__MODULE__{slots: slots}), do: map_size(slots)

  @doc "Key lookup after normalization: `{:ok, value}` | `:error`."
  def fetch(%__MODULE__{keys: keys, slots: slots}, raw_key) do
    case normalize_key(raw_key) do
      {:ok, k} ->
        case keys do
          %{^k => slot} ->
            {_, v} = Map.fetch!(slots, slot)
            {:ok, v}

          _ ->
            :error
        end

      {:error, _} = e ->
        e
    end
  end

  def get(arr, raw_key, default \\ :null_value)

  def get(%__MODULE__{} = arr, raw_key, default) do
    case fetch(arr, raw_key) do
      {:ok, v} -> v
      :error -> default
      {:error, _} -> default
    end
  end

  @doc "Insert or update. Returns updated array or `{:error, illegal offset}`."
  def put(%__MODULE__{} = arr, raw_key, value) do
    case normalize_key(raw_key) do
      {:ok, k} -> do_put(arr, k, value)
      {:error, msg} -> {:error, msg}
    end
  end

  defp do_put(%__MODULE__{keys: keys, slots: slots, next_slot: next_slot} = arr, k, value) do
    case keys do
      %{^k => slot} ->
        # replace value, keep original position
        {^k, _} = Map.fetch!(slots, slot)
        {:ok, %__MODULE__{arr | slots: Map.put(slots, slot, {k, value})}}

      _ ->
        slots = Map.put(slots, next_slot, {k, value})
        keys = Map.put(keys, k, next_slot)

        {:ok,
         %__MODULE__{
           arr
           | keys: keys,
             slots: slots,
             next_slot: next_slot + 1,
             next_index: bump_index(arr, k)
         }}
    end
  end

  # PHP 8: next auto index = max(ever-inserted int key) + 1; starts at 0
  defp bump_index(%__MODULE__{next_index: nil}, k) when is_integer(k), do: k + 1

  defp bump_index(%__MODULE__{next_index: ni}, k) when is_integer(k),
    do: if(k + 1 > ni, do: k + 1, else: ni)

  defp bump_index(%__MODULE__{next_index: ni}, _k), do: ni

  @doc "Append at the next auto index (`$a[] = v`)."
  def push(%__MODULE__{next_index: ni, next_slot: ns, keys: keys, slots: slots} = arr, value) do
    k = ni || 0

    %__MODULE__{
      arr
      | keys: Map.put(keys, k, ns),
        slots: Map.put(slots, ns, {k, value}),
        next_slot: ns + 1,
        next_index: k + 1
    }
  end

  @doc "Remove a key; missing keys are no-ops."
  def delete(%__MODULE__{keys: keys, slots: slots} = arr, raw_key) do
    case normalize_key(raw_key) do
      {:ok, k} ->
        case keys do
          %{^k => slot} ->
            {:ok,
             %__MODULE__{arr | keys: Map.delete(keys, k), slots: Map.delete(slots, slot)}}

          _ ->
            {:ok, arr}
        end

      {:error, _} ->
        {:ok, arr}
    end
  end

  @doc "All normalized keys in insertion order."
  def keys(%__MODULE__{slots: slots}) do
    slots
    |> Enum.sort_by(fn {slot, _} -> slot end)
    |> Enum.map(fn {_, {k, _}} -> k end)
  end

  @doc "All values in insertion order."
  def values(%__MODULE__{slots: slots}) do
    slots
    |> Enum.sort_by(fn {slot, _} -> slot end)
    |> Enum.map(fn {_, {_, v}} -> v end)
  end

  @doc "`[{key, value}]` in insertion order."
  def to_pairs(%__MODULE__{slots: slots}) do
    slots
    |> Enum.sort_by(fn {slot, _} -> slot end)
    |> Enum.map(fn {_, kv} -> kv end)
  end

  @doc "First element value or `:error` when empty (array_shift drops it)."
  def first(%__MODULE__{slots: slots}) do
    case min_slot(slots) do
      nil -> :error
      slot -> {_, v} = Map.fetch!(slots, slot)
      {:ok, v}
    end
  end

  defp min_slot(slots) when slots == %{}, do: nil

  defp min_slot(slots) do
    Enum.reduce(Map.keys(slots), fn a, b -> if a <= b, do: a, else: b end)
  end

  @doc "Remove and return first `{key, value}` (array_shift)."
  def shift(%__MODULE__{} = arr) do
    shift_pop(arr, :min)
  end

  @doc "Remove and return last `{key, value}` (array_pop)."
  def pop(%__MODULE__{} = arr) do
    shift_pop(arr, :max)
  end

  defp shift_pop(%__MODULE__{keys: keys, slots: slots} = arr, side) do
    if slots == %{} do
      :error
    else
      slot =
        case side do
          :min -> Enum.min(Map.keys(slots))
          :max -> Enum.max(Map.keys(slots))
        end

      {k, v} = Map.fetch!(slots, slot)

      {:ok, {k, v},
       %__MODULE__{arr | keys: Map.delete(keys, k), slots: Map.delete(slots, slot)}}
    end
  end

  @doc "Whether a normalized key exists (isset on arrays)."
  def has_key?(%__MODULE__{keys: keys}, raw_key) do
    case normalize_key(raw_key) do
      {:ok, k} -> Map.has_key?(keys, k)
      _ -> false
    end
  end

  @doc "Renumber 0..n-1 in current order (used by sort())."
  def renumber(%__MODULE__{} = arr) do
    from_pairs(Enum.map(to_pairs(arr), fn {_, v} -> {nil, v} end))
  end

  @doc "`+` union: left entries first, then right entries whose keys are absent."
  def union(%__MODULE__{keys: lk} = left, %__MODULE__{} = right) do
    extra = Enum.filter(to_pairs(right), fn {k, _} -> not Map.has_key?(lk, k) end)

    Enum.reduce(extra, left, fn {k, v}, acc ->
      {:ok, a} = do_put(acc, k, v)
      a
    end)
  end

  @doc "Key normalization: int stays; canonical decimal strings → int; bool/null/float coerce."
  def normalize_key(raw_key)

  def normalize_key({:int, i}), do: {:ok, i}

  def normalize_key({:string, s}) do
    case canonical_int_key(s) do
      {:ok, i} -> {:ok, i}
      :no -> {:ok, s}
    end
  end

  def normalize_key({:bool, b}), do: {:ok, if(b, do: 1, else: 0)}
  def normalize_key(:null), do: {:ok, ""}
  def normalize_key({:float, f}), do: {:ok, trunc(f) |> wrap_int()}
  def normalize_key({:array, _}), do: {:error, "Illegal offset type (array)"}
  def normalize_key({:object, _}), do: {:error, "Illegal offset type (object)"}

  defp wrap_int(i) when i > 9_223_372_036_854_775_807, do: 9_223_372_036_854_775_807
  defp wrap_int(i) when i < -9_223_372_036_854_775_808, do: -9_223_372_036_854_775_808
  defp wrap_int(i), do: i

  @int_key_max 9_223_372_036_854_775_807

  # "123" / "-123" / "0" become int keys (when within int64 range);
  # "01", "-0", "1.5", " 1", overflow digits stay strings
  defp canonical_int_key(s) do
    if Regex.match?(~r/^(0|-?[1-9][0-9]*)$/, s) do
      i = String.to_integer(s)

      if i in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 do
        {:ok, i}
      else
        :no
      end
    else
      :no
    end
  end
end
