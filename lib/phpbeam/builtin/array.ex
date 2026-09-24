defmodule PhpBeam.Builtin.ArrayFns do
  @moduledoc """
  Array functions. Mutating functions (sort/push/pop/…) return
  `{:ref_call, return_value, [new_array], interp}`; the evaluator writes the
  new array back into the argument lvalue.
  """

  alias PhpBeam.{PArray, Value}

  def register(fns) do
    entries = %{
      "count" => &count_v/2,
      "sizeof" => &count_v/2,
      "array_keys" => &array_keys/2,
      "in_array" => &in_array/2,
      "array_search" => &array_search/2,
      "array_key_exists" => &array_key_exists/2,
      "key_exists" => &array_key_exists/2,
      "array_merge" => &array_merge/2,
      "array_slice" => &array_slice/2,
      "array_sum" => &array_sum/2,
      "array_product" => &array_product/2,
      "array_reverse" => &array_reverse/2,
      "array_flip" => &array_flip/2,
      "array_unique" => &array_unique/2,
      "array_combine" => &array_combine/2,
      "array_fill" => &array_fill/2,
      "array_pad" => &array_pad/2,
      "array_chunk" => &array_chunk/2,
      "array_column" => &array_column/2,
      "array_diff" => &array_diff/2,
      "array_intersect" => &array_intersect/2,
      "range" => &range_v/2,
      "array_change_key_case" => &array_change_key_case_v/2,
      "array_key_first" => &array_key_first_v/2,
      "array_key_last" => &array_key_last_v/2,
      "array_column" => &array_column_v/2
    }

    mutators = %{
      "array_push" => {&array_push/2, [0]},
      "array_pop" => {&array_pop/2, [0]},
      "array_shift" => {&array_shift/2, [0]},
      "array_unshift" => {&array_unshift/2, [0]},
      "array_splice" => {&array_splice/2, [0]},
      "sort" => {sort_entry(:values, :renumber, :asc), [0]},
      "rsort" => {sort_entry(:values, :renumber, :desc), [0]},
      "asort" => {sort_entry(:values, :keep, :asc), [0]},
      "arsort" => {sort_entry(:values, :keep, :desc), [0]},
      "ksort" => {sort_entry(:keys, :keep, :asc), [0]},
      "krsort" => {sort_entry(:keys, :keep, :desc), [0]}
    }

    fns =
      Enum.reduce(entries, fns, fn {name, fun}, acc ->
        Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
      end)

    fns =
      Enum.reduce(mutators, fns, fn {name, entry}, acc ->
        {fun, refs} = normalize_entry(entry)
        Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: refs})
      end)

    fns
  end

  defp arr([{:array, a} | _]), do: a
  defp arr(_), do: PArray.new()

  defp wrap_key(k) when is_integer(k), do: {:int, k}
  defp wrap_key(k) when is_binary(k), do: {:string, k}

  defp count_v(vals, i) do
    case vals do
      [{:array, a} | _] ->
        {:ok, {:int, PArray.size(a)}, i}

      # Countable objects delegate to their count() method
      [{:object, _} = oref | _] ->
        obj = PhpBeam.Eval.get_object(i, oref)

        if PhpBeam.Classes.find_method(i, obj.class, "count") do
          case PhpBeam.Eval.call_count_method(oref, i) do
            {{:val, v}, _, i2} -> {:ok, v, i2}
            _ -> {:ok, {:int, 1}, i}
          end
        else
          {:ok, {:int, 1}, i}
        end

      [v | _] when v != :null ->
        {:ok, {:int, 1}, i}

      _ ->
        {:ok, {:int, 0}, i}
    end
  end

  defp array_keys(vals, i) do
    a = arr(vals)

    keys =
      case vals do
        [_, search | _] ->
          PArray.to_pairs(a)
          |> Enum.filter(fn {_, v} -> Value.loose_eq(v, search) end)
          |> Enum.map(fn {k, _} -> k end)

        _ ->
          PArray.keys(a)
      end

    {:ok, {:array, PArray.from_pairs(Enum.map(keys, &{nil, wrap_key(&1)}))}, i}
  end

  defp array_values(vals, i) do
    {:ok, {:array, PArray.from_pairs(Enum.map(PArray.values(arr(vals)), &{nil, &1}))}, i}
  end

  defp array_push([{:array, a} | more], i) do
    a2 = Enum.reduce(more, a, fn v, acc -> PArray.push(acc, v) end)
    {:ref_call, {:int, PArray.size(a2)}, [{:array, a2}], i}
  end

  defp array_pop([{:array, a} | _], i) do
    case PArray.pop(a) do
      {:ok, {_k, v}, a2} -> {:ref_call, v, [{:array, a2}], i}
      :error -> {:ref_call, :null, [{:array, a}], i}
    end
  end

  defp array_shift([{:array, a} | _], i) do
    case PArray.shift(a) do
      {:ok, {_k, v}, a2} -> {:ref_call, v, [{:array, a2}], i}
      :error -> {:ref_call, :null, [{:array, a}], i}
    end
  end

  defp array_unshift([{:array, a} | more], i) do
    all_list? = PArray.keys(a) |> Enum.all?(&is_integer/1)

    merged =
      if all_list? or PArray.size(a) == 0 do
        PArray.from_pairs(Enum.map(Enum.concat(more, PArray.values(a)), &{nil, &1}))
      else
        # assoc array: PHP preserves keys, prepending is best-effort (insert then reorder)
        base = Enum.reduce(Enum.reverse(more), PArray.new(), fn v, acc -> PArray.push(acc, v) end)

        Enum.reduce(PArray.to_pairs(a), base, fn {k, v}, acc ->
          {:ok, a2} = PArray.put(acc, wrap_key(k), v)
          a2
        end)
      end

    {:ref_call, {:int, PArray.size(merged)}, [{:array, merged}], i}
  end

  defp in_array([needle, {:array, a} | rest], i) do
    strict? =
      case rest do
        [{:bool, true} | _] -> true
        _ -> false
      end

    eq = if strict?, do: &Value.strict_eq/2, else: &Value.loose_eq/2
    {:ok, {:bool, Enum.any?(PArray.values(a), &eq.(needle, &1))}, i}
  end

  defp array_search([needle, {:array, a} | rest], i) do
    strict? =
      case rest do
        [{:bool, true} | _] -> true
        _ -> false
      end

    eq = if strict?, do: &Value.strict_eq/2, else: &Value.loose_eq/2

    case Enum.find(PArray.to_pairs(a), fn {_, v} -> eq.(needle, v) end) do
      {k, _} -> {:ok, wrap_key(k), i}
      nil -> {:ok, {:bool, false}, i}
    end
  end

  defp array_key_exists([key, {:array, a} | _], i),
    do: {:ok, {:bool, PArray.has_key?(a, key)}, i}

  # PHP array_merge: string keys overwrite in place; integer keys are
  # renumbered and appended; original order otherwise preserved.
  defp array_merge(vals, i) do
    arrays = Enum.filter(vals, &match?({:array, _}, &1))

    merged =
      Enum.flat_map(arrays, fn {:array, a} -> PArray.to_pairs(a) end)
      |> Enum.reduce(PArray.new(), fn
        {k, v}, acc when is_binary(k) ->
          {:ok, a2} = PArray.put(acc, {:string, k}, v)
          a2

        {_k, v}, acc ->
          PArray.push(acc, v)
      end)

    {:ok, {:array, merged}, i}
  end

  defp array_slice([{:array, a}, {:int, offset} | rest], i) do
    pairs = PArray.to_pairs(a)
    n = length(pairs)
    offset2 = if offset < 0, do: max(n + offset, 0), else: offset

    items =
      case rest do
        [{:int, len} | _] when len < 0 ->
          take_upto(Enum.drop(pairs, offset2), max(n + len - offset2, 0))

        [{:int, len} | _] ->
          Enum.take(Enum.drop(pairs, offset2), len)

        _ ->
          Enum.drop(pairs, offset2)
      end

    preserve? =
      case rest do
        [_, {:bool, true} | _] -> true
        _ -> false
      end

    out =
      if preserve? do
        PArray.from_pairs(Enum.map(items, fn {k, v} -> {wrap_key(k), v} end))
      else
        PArray.from_pairs(Enum.map(items, fn {_, v} -> {nil, v} end))
      end

    {:ok, {:array, out}, i}
  end

  defp take_upto(list, n) when n <= 0, do: []
  defp take_upto(list, n), do: Enum.take(list, n)

  defp array_splice([{:array, a}, {:int, offset} | rest], i) do
    pairs = PArray.to_pairs(a)
    n = length(pairs)
    offset2 = if offset < 0, do: max(n + offset, 0), else: min(offset, n)

    len =
      case rest do
        [{:int, l} | _] when l < 0 -> max(n + l - offset2, 0)
        [{:int, l} | _] -> l
        _ -> n - offset2
      end

    {head, tail_full} = Enum.split(pairs, offset2)
    {removed, tail} = Enum.split(tail_full, len)

    replacements =
      case Enum.drop(rest, 1) do
        [{:array, rep} | _] -> PArray.values(rep)
        _ -> []
      end

    out_vals = PArray.values_from_pairs(head) ++ replacements ++ PArray.values_from_pairs(tail)
    out = PArray.from_pairs(Enum.map(out_vals, &{nil, &1}))
    removed_arr = PArray.from_pairs(Enum.map(PArray.values_from_pairs(removed), &{nil, &1}))

    {:ref_call, {:array, removed_arr}, [{:array, out}], i}
  end

  defp array_sum([{:array, a} | _], i) do
    sum =
      Enum.reduce(PArray.values(a), {:int, 0}, fn v, acc ->
        case Value.arith(:+, acc, v) do
          {:ok, r} -> r
          _ -> acc
        end
      end)

    {:ok, sum, i}
  end

  defp array_product([{:array, a} | _], i) do
    product =
      Enum.reduce(PArray.values(a), {:int, 1}, fn v, acc ->
        case Value.arith(:*, acc, v) do
          {:ok, r} -> r
          _ -> acc
        end
      end)

    {:ok, product, i}
  end

  defp array_reverse([{:array, a} | rest], i) do
    preserve? =
      case rest do
        [{:bool, true} | _] -> true
        _ -> false
      end

    pairs = Enum.reverse(PArray.to_pairs(a))

    out =
      if preserve? do
        PArray.from_pairs(Enum.map(pairs, fn {k, v} -> {wrap_key(k), v} end))
      else
        PArray.from_pairs(Enum.map(pairs, fn {_, v} -> {nil, v} end))
      end

    {:ok, {:array, out}, i}
  end

  defp array_flip([{:array, a} | _], i) do
    out =
      Enum.reduce(PArray.to_pairs(a), PArray.new(), fn {k, v}, acc ->
        case PArray.put(acc, flip_key(v), wrap_key(k)) do
          {:ok, a2} -> a2
          _ -> acc
        end
      end)

    {:ok, {:array, out}, i}
  end

  defp flip_key({:int, n}), do: {:int, n}
  defp flip_key(v), do: {:string, PhpBeam.Eval.php_to_string(v)}

  defp array_unique([{:array, a} | _], i) do
    {kept_rev, _} =
      Enum.reduce(PArray.to_pairs(a), {[], []}, fn {k, v}, {pairs, seen} ->
        if Enum.any?(seen, &Value.loose_eq(&1, v)) do
          {pairs, seen}
        else
          {[{k, v} | pairs], [v | seen]}
        end
      end)

    out =
      Enum.reduce(Enum.reverse(kept_rev), PArray.new(), fn {k, v}, acc ->
        {:ok, a2} = PArray.put(acc, wrap_key(k), v)
        a2
      end)

    {:ok, {:array, out}, i}
  end

  defp array_combine([{:array, ks}, {:array, vs} | _], i) do
    out =
      PArray.values(ks)
      |> Enum.zip(PArray.values(vs))
      |> Enum.reduce(PArray.new(), fn {key_val, v}, acc ->
        case PArray.put(acc, key_val, v) do
          {:ok, a2} -> a2
          _ -> acc
        end
      end)

    {:ok, {:array, out}, i}
  end

  defp array_fill([{:int, start}, {:int, num}, v | _], i) do
    pairs = for idx <- start..(start + num - 1), do: {{:int, idx}, v}
    {:ok, {:array, PArray.from_pairs(pairs)}, i}
  end

  defp array_pad([{:array, a}, {:int, size}, v | _], i) do
    values = PArray.values(a)
    n = length(values)

    out =
      if abs(size) <= n do
        a
      else
        fill = abs(size) - n

        vals =
          if size > 0,
            do: values ++ List.duplicate(v, fill),
            else: List.duplicate(v, fill) ++ values

        PArray.from_pairs(Enum.map(vals, &{nil, &1}))
      end

    {:ok, {:array, out}, i}
  end

  defp array_chunk([{:array, a}, {:int, size} | rest], i) do
    preserve? =
      case rest do
        [{:bool, true} | _] -> true
        _ -> false
      end

    chunks =
      PArray.to_pairs(a)
      |> Enum.chunk_every(max(size, 1))
      |> Enum.map(fn chunk ->
        if preserve? do
          {:array, PArray.from_pairs(Enum.map(chunk, fn {k, v} -> {wrap_key(k), v} end))}
        else
          {:array, PArray.from_pairs(Enum.map(chunk, fn {_, v} -> {nil, v} end))}
        end
      end)

    {:ok, {:array, PArray.from_pairs(Enum.map(chunks, &{nil, &1}))}, i}
  end

  defp array_column([{:array, a}, key | rest], i) do
    key_v =
      case key do
        {:string, s} -> s
        {:int, n} -> n
      end

    key_tagged = wrap_key(key_v)
    idx_key = if is_binary(key_v), do: {:string, key_v}, else: {:int, key_v}

    out =
      PArray.values(a)
      |> Enum.filter(&match?({:array, _}, &1))
      |> Enum.flat_map(fn {:array, row} ->
        case PArray.fetch(row, idx_key) do
          {:ok, v} -> [v]
          :error -> []
        end
      end)

    {:ok, {:array, PArray.from_pairs(Enum.map(out, &{nil, &1}))}, i}
  end

  defp array_diff(vals, i) do
    case Enum.filter(vals, &match?({:array, _}, &1)) do
      [{:array, first} | others] ->
        out =
          PArray.to_pairs(first)
          |> Enum.filter(fn {_, v} ->
            not Enum.any?(others, fn {:array, o} ->
              Enum.any?(PArray.values(o), &Value.loose_eq(&1, v))
            end)
          end)
          |> Enum.reduce(PArray.new(), fn {k, v}, acc ->
            {:ok, a2} = PArray.put(acc, wrap_key(k), v)
            a2
          end)

        {:ok, {:array, out}, i}

      [] ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  defp array_intersect(vals, i) do
    case Enum.filter(vals, &match?({:array, _}, &1)) do
      [{:array, first} | others] ->
        out =
          PArray.to_pairs(first)
          |> Enum.filter(fn {_, v} ->
            Enum.all?(others, fn {:array, o} ->
              Enum.any?(PArray.values(o), &Value.loose_eq(&1, v))
            end)
          end)
          |> Enum.reduce(PArray.new(), fn {k, v}, acc ->
            {:ok, a2} = PArray.put(acc, wrap_key(k), v)
            a2
          end)

        {:ok, {:array, out}, i}

      [] ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  defp array_key_first([{:array, a} | _], i) do
    case PArray.keys(a) do
      [k | _] -> {:ok, wrap_key(k), i}
      [] -> {:ok, :null, i}
    end
  end

  defp array_key_last([{:array, a} | _], i) do
    case Enum.reverse(PArray.keys(a)) do
      [k | _] -> {:ok, wrap_key(k), i}
      [] -> {:ok, :null, i}
    end
  end

  defp range_v([first, last | rest], i) do
    step =
      case rest do
        [{:int, s} | _] when s != 0 -> s
        _ -> nil
      end

    items =
      case {first, last} do
        {{:int, a}, {:int, b}} ->
          case step do
            nil -> if(a <= b, do: Enum.to_list(a..b), else: Enum.to_list(a..b//-1))
            s -> Enum.to_list(a..b//s)
          end

        {{:string, <<ca, _::binary>>}, {:string, <<cb, _::binary>>}} ->
          if ca <= cb, do: Enum.to_list(ca..cb), else: Enum.to_list(ca..cb//-1)

        _ ->
          {:ok, {:float, fa}} = Value.to_float(first)
          {:ok, {:float, fb}} = Value.to_float(last)
          s = (step && step * 1.0) || 1.0

          Enum.take_while(Stream.iterate(fa, &(&1 + s)), fn x ->
            if(s > 0, do: x <= fb + 1.0e-9, else: x >= fb - 1.0e-9)
          end)
      end

    {:ok, {:array, PArray.from_pairs(Enum.map(items, &{nil, num_val(&1)}))}, i}
  end

  defp num_val(n) when is_integer(n), do: {:int, n}
  defp num_val(c) when is_integer(c), do: {:string, <<c>>}
  defp num_val(v), do: v

  # ───────────────────────── sorting ─────────────────────────

  defp sort_entry(axis, renumber, dir) do
    fn vals, i ->
      case vals do
        [{:array, a} | _] ->
          # boolean sorter for :lists.sort (true = keep order)
          cmp =
            case axis do
              :values ->
                fn {_, v1}, {_, v2} -> ordered?(Value.compare(v1, v2), dir) end

              :keys ->
                fn {k1, _}, {k2, _} ->
                  ordered?(Value.compare(wrap_key(k1), wrap_key(k2)), dir)
                end
            end

          sorted = Enum.sort(PArray.to_pairs(a), cmp)

          out =
            case renumber do
              :renumber -> PArray.from_pairs(Enum.map(sorted, fn {_, v} -> {nil, v} end))
              :keep -> PArray.from_pairs(Enum.map(sorted, fn {k, v} -> {wrap_key(k), v} end))
            end

          {:ref_call, {:bool, true}, [{:array, out}], i}

        _ ->
          {:ref_call, {:bool, false}, vals, i}
      end
    end
  end

  defp ordered?(c, :asc) when c <= 0, do: true
  defp ordered?(_, :asc), do: false
  defp ordered?(c, :desc) when c >= 0, do: true
  defp ordered?(_, :desc), do: false

  defp array_change_key_case_v(vals, i) do
    case Enum.at(vals, 0) do
      {:array, arr} ->
        upper? =
          case Enum.at(vals, 1) do
            {:int, n} -> n == 1
            _ -> false
          end

        pairs =
          Enum.map(PArray.to_pairs(arr), fn {k, v} ->
            k2 =
              cond do
                not is_binary(k) -> k
                upper? -> String.upcase(k)
                true -> String.downcase(k)
              end

            {if(is_binary(k2), do: {:string, k2}, else: {:int, k2}), v}
          end)

        {:ok, {:array, PArray.from_pairs(pairs)}, i}

      _ ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  defp array_key_first_v(vals, i) do
    case Enum.at(vals, 0) do
      {:array, arr} ->
        case PArray.to_pairs(arr) do
          [{k, _} | _] -> {:ok, wrap_key(k), i}
          [] -> {:ok, :null, i}
        end

      _ ->
        {:ok, :null, i}
    end
  end

  defp array_key_last_v(vals, i) do
    case Enum.at(vals, 0) do
      {:array, arr} ->
        case PArray.to_pairs(arr) |> Enum.reverse() do
          [{k, _} | _] -> {:ok, wrap_key(k), i}
          [] -> {:ok, :null, i}
        end

      _ ->
        {:ok, :null, i}
    end
  end

  defp array_column_v(vals, i) do
    case Enum.at(vals, 0) do
      {:array, arr} ->
        col =
          case Enum.at(vals, 1) do
            {:int, n} -> {:int, n}
            other -> {:string, PhpBeam.Value.cast_string_unsafe(other || :null)}
          end

        out =
          Enum.flat_map(PArray.values(arr), fn
            {:array, row} ->
              case PArray.fetch(row, col) do
                {:ok, v} -> [v]
                :error -> []
              end

            _ ->
              []
          end)

        {:ok, {:array, PArray.from_pairs(Enum.map(out, &{nil, &1}))}, i}

      _ ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  defp wrap_key(k) when is_integer(k), do: {:int, k}
  defp wrap_key(k) when is_binary(k), do: {:string, k}
  # plain fns arrive as &name/2; mutators as {fun, refs}
  defp normalize_entry({fun, refs}) when is_function(fun, 2), do: {fun, refs || []}
  defp normalize_entry(fun) when is_function(fun, 2), do: {fun, []}
end
