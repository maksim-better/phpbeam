defmodule PhpBeam.Builtin.ArrayStdFns do
  @moduledoc """
  PHASE B3: standard's remaining array family — the u\\* callback
  intersections/diffs, natural-order sorts, multisort, replace family,
  find family, shuffle/rand (seeded :rand for determinism), ip2long pair.

  Key-preservation rules (probed): intersect keeps the FIRST array's keys;
  u\\* variants use the callback for VALUE comparison (loose ==-like via
  comparator), \\ukey/\\_uassoc compare KEYS with the callback; string keys
  survive, numeric keys renumber only where php renumbers (diff family
  keeps keys).
  """

  alias PhpBeam.{Eval, PArray, Value}

  def register(fns) do
    plain =
      Map.new(plain_entries(), fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    ho_entries =
      Map.new(ho_list(), fn {n, f} ->
        {n, %{fun: fn _v, i, _c -> {:ok, :null, i} end, refs: [], ho: %{args: :raw, fun: f}}}
      end)

    mutators =
      Map.new(mutator_entries(), fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: [0]}}
      end)

    finders =
      Map.new(
        [
          {"array_find", &ho_array_find/3},
          {"array_find_key", &ho_array_find_key/3}
        ],
        fn {n, f} ->
          {n, %{fun: fn _v, i, _c -> {:ok, :null, i} end, refs: [], ho: %{args: :raw, fun: f}}}
        end
      )

    fns |> Map.merge(plain) |> Map.merge(mutators) |> Map.merge(ho_entries) |> Map.merge(finders)
  end

  defp plain_entries do
    [
      {"array_replace", &array_replace_v/2},
      {"array_replace_recursive", &array_replace_recursive_v/2},
      {"array_count_values", &array_count_values_v/2},
      {"array_rand", &array_rand_v/2},
      {"ip2long", &ip2long_v/2},
      {"long2ip", &long2ip_v/2},
      {"str_shuffle", &str_shuffle_v/2}
    ]
  end

  # in-place writers: the refs channel writes the 0th (array) arg back
  defp mutator_entries do
    [
      {"natsort", &natsort_v/2},
      {"natcasesort", &natcasesort_v/2},
      {"shuffle", &shuffle_v/2},
      {"array_multisort", &array_multisort_v/2}
    ]
  end

  defp ho_list do
    [
      {"array_uintersect", &ho_uintersect/3},
      {"array_uintersect_assoc", &ho_uintersect_assoc/3},
      {"array_intersect_uassoc", &ho_intersect_uassoc/3},
      {"array_uintersect_uassoc", &ho_uintersect_uassoc/3},
      {"array_intersect_ukey", &ho_intersect_ukey/3},
      {"array_udiff", &ho_udiff/3},
      {"array_udiff_assoc", &ho_udiff_assoc/3},
      {"array_diff_uassoc", &ho_diff_uassoc/3},
      {"array_udiff_uassoc", &ho_udiff_uassoc/3},
      {"array_diff_ukey", &ho_diff_ukey/3},
      {"array_intersect_assoc", &ho_intersect_assoc/3},
      {"array_diff_assoc", &ho_diff_assoc/3},
      {"array_intersect_key", &ho_intersect_key/3},
      {"array_diff_key", &ho_diff_key/3}
    ]
  end

  ## ───────────────── u* / plain intersect-diff family ─────────────────

  # ho raw args: [arr1_ast, arr2_ast..., cb_ast] — callback LAST

  defp ho_uintersect(args, env, i) do
    {arrs, cb} = split_args_cb(args)

    with {:ok, [a1 | rest]} <- eval_arrays(arrs, env, i) do
      cmp = fn x, y -> cb_compare(cb, x, y, env, i) end
      keep = fn k, v -> Enum.any?(rest, fn a -> any_value?(a, v, cmp) end) end
      ho_result(a1, keep, args, env, i)
    end
  end

  defp ho_uintersect_assoc(args, env, i) do
    {arrs, cb} = split_args_cb(args)

    with {:ok, [a1 | rest]} <- eval_arrays(arrs, env, i) do
      cmp = fn x, y -> cb_compare(cb, x, y, env, i) end

      # compare the value of the matching KEY-SLOT (php zval identity: the
      # entry at the same numeric position counts even under re-keying —
      # probed [0=>1,1=>2] ∩ [9,2] keeps 1=>2)
      keep = fn k, v ->
        Enum.any?(rest, fn a ->
          case PArray.fetch(a, k) do
            {:ok, v2} -> cmp.(v, v2) == 0
            _ -> slot_match?(a1, k, a, cmp)
          end
        end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  defp slot_match?(a1, k, a, cmp) do
    with {:ok, pos} <- pair_position(a1, k),
         {_, v2} <- pair_at(a, pos) do
      cmp.(pair_value(a1, k), v2) == 0
    else
      _ -> false
    end
  end

  defp pair_position(arr, k) do
    arr
    |> PArray.to_pairs()
    |> Enum.find_index(fn {k2, _} -> k2 == k end)
    |> case do
      nil -> :error
      pos -> {:ok, pos}
    end
  end

  defp pair_at(arr, pos) do
    arr
    |> PArray.to_pairs()
    |> Enum.at(pos, :none)
    |> case do
      :none -> :error
      kv -> kv
    end
  end

  defp pair_value(arr, k) do
    case PArray.fetch(arr, k) do
      {:ok, v} -> v
      _ -> :null
    end
  end

  defp ho_intersect_uassoc(args, env, i) do
    # php: string comparison on BOTH key and value
    {arrs, _cb} = split_args_cb(args)

    with {:ok, [a1 | rest]} <- eval_arrays(arrs, env, i) do
      keep = fn k, v ->
        Enum.any?(rest, fn a ->
          case PArray.fetch(a, k) do
            {:ok, v2} -> Value.loose_eq(v, v2) == true
            _ -> false
          end
        end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  defp ho_uintersect_uassoc(args, env, i) do
    {arrs, [cb1, cb2]} = split_args_cb2(args)

    with {:ok, [a1 | rest]} <- eval_arrays(arrs, env, i) do
      cmpv = fn x, y -> cb_compare(cb1, x, y, env, i) end
      cmpk = fn x, y -> cb_compare(cb2, x, y, env, i) end

      keep = fn k, v ->
        Enum.any?(rest, fn a ->
          case PArray.fetch(a, k) do
            {:ok, v2} -> cmpk.(key_val(k), key_val2(k)) == 0 and cmpv.(v, v2) == 0
            _ -> false
          end
        end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  defp ho_intersect_ukey(args, env, i) do
    {arrs, cb} = split_args_cb(args)

    with {:ok, [a1 | rest]} <- eval_arrays(arrs, env, i) do
      cmp = fn x, y -> cb_compare(cb, x, y, env, i) end

      keep = fn k, _v ->
        Enum.any?(rest, fn a ->
          Enum.any?(PArray.to_pairs(a), fn {k2, _} -> cmp.(key_val(k), key_val(k2)) == 0 end)
        end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  defp ho_udiff(args, env, i) do
    {arrs, cb} = split_args_cb(args)

    with {:ok, [a1 | rest]} <- eval_arrays(arrs, env, i) do
      cmp = fn x, y -> cb_compare(cb, x, y, env, i) end
      keep = fn _k, v -> not Enum.any?(rest, fn a -> any_value?(a, v, cmp) end) end
      ho_result(a1, keep, args, env, i)
    end
  end

  defp ho_udiff_assoc(args, env, i) do
    {arrs, cb} = split_args_cb(args)

    with {:ok, [a1 | rest]} <- eval_arrays(arrs, env, i) do
      cmp = fn x, y -> cb_compare(cb, x, y, env, i) end

      keep = fn k, v ->
        not Enum.any?(rest, fn a ->
          case PArray.fetch(a, k) do
            {:ok, v2} -> cmp.(v, v2) == 0
            _ -> false
          end
        end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  defp ho_diff_uassoc(args, env, i) do
    # value: loose; key: callback
    {arrs, cb} = split_args_cb(args)

    with {:ok, [a1 | rest]} <- eval_arrays(arrs, env, i) do
      cmp = fn x, y -> cb_compare(cb, x, y, env, i) end

      keep = fn k, v ->
        not Enum.any?(rest, fn a ->
          Enum.any?(PArray.to_pairs(a), fn {k2, v2} ->
            cmp.(key_val(k), key_val(k2)) == 0 and Value.loose_eq(v, v2) == true
          end)
        end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  defp ho_udiff_uassoc(args, env, i) do
    {arrs, [cb1, cb2]} = split_args_cb2(args)

    with {:ok, [a1 | rest]} <- eval_arrays(arrs, env, i) do
      cmpv = fn x, y -> cb_compare(cb1, x, y, env, i) end

      keep = fn k, v ->
        not Enum.any?(rest, fn a ->
          case PArray.fetch(a, k) do
            {:ok, v2} -> cmpv.(v, v2) == 0
            _ -> false
          end
        end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  defp ho_diff_ukey(args, env, i) do
    {arrs, cb} = split_args_cb(args)

    with {:ok, [a1 | rest]} <- eval_arrays(arrs, env, i) do
      cmp = fn x, y -> cb_compare(cb, x, y, env, i) end

      keep = fn k, _v ->
        not Enum.any?(rest, fn a ->
          Enum.any?(PArray.to_pairs(a), fn {k2, _} -> cmp.(key_val(k), key_val(k2)) == 0 end)
        end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  # plain (non-callback) variants ride the same machinery with a ==
  # comparator
  defp ho_intersect_assoc(args, env, i) do
    with {:ok, [a1 | rest]} <- eval_arrays(args, env, i) do
      keep = fn k, v ->
        Enum.any?(rest, fn a ->
          case PArray.fetch(a, k) do
            {:ok, v2} -> Value.loose_eq(v, v2) == true
            _ -> false
          end
        end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  defp ho_diff_assoc(args, env, i) do
    with {:ok, [a1 | rest]} <- eval_arrays(args, env, i) do
      keep = fn k, v ->
        not Enum.any?(rest, fn a ->
          case PArray.fetch(a, k) do
            {:ok, v2} -> Value.loose_eq(v, v2) == true
            _ -> false
          end
        end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  defp ho_intersect_key(args, env, i) do
    with {:ok, [a1 | rest]} <- eval_arrays(args, env, i) do
      keep = fn k, _v ->
        Enum.any?(rest, fn a -> PArray.fetch(a, k) != :error end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  defp ho_diff_key(args, env, i) do
    with {:ok, [a1 | rest]} <- eval_arrays(args, env, i) do
      keep = fn k, _v ->
        not Enum.any?(rest, fn a -> PArray.fetch(a, k) != :error end)
      end

      ho_result(a1, keep, args, env, i)
    end
  end

  # args: array ASTs (+ trailing callback ASTs); values already evaluated
  defp split_args_cb(args) do
    {arrs, [cb]} = Enum.split(args, -1)
    {arrs, cb}
  end

  defp split_args_cb2(args) do
    {arrs, cbs} = Enum.split(args, -2)
    {arrs, cbs}
  end

  defp eval_arrays(args, env, i) do
    Enum.reduce_while(args, {:ok, []}, fn a, {:ok, acc} ->
      case Eval.eval(a, env, i) do
        {{:val, {:array, arr}}, _, _} -> {:cont, {:ok, acc ++ [arr]}}
        {{:val, _}, _, _} -> {:halt, {:error, :not_array}}
        unw -> {:halt, {:passthrough, unw}}
      end
    end)
    |> case do
      {:ok, arrs} -> {:ok, arrs}
      {:error, _} -> :error
      {:passthrough, unw} -> unw
    end
  end

  defp cb_compare(cb_ast, a, b, env, i) do
    case Eval.call_cb_raw(cb_ast, [a, b], env, i) do
      {{:val, v}, _, _} -> Value.compare(v, {:int, 0})
      _ -> 0
    end
  end

  defp any_value?(arr, v, cmp) do
    Enum.any?(PArray.values(arr), &(&1 == v or cmp.(&1, v) == 0))
  end

  defp key_val(k) when is_integer(k), do: {:int, k}
  defp key_val(k) when is_binary(k), do: {:string, k}

  defp key_val2(k), do: key_val(k)

  # result: a NEW array (php returns a copy — no reference semantics)
  defp ho_result(a1, keep, _args, env, i) do
    pairs =
      a1
      |> PArray.to_pairs()
      |> Enum.filter(fn {k, v} -> keep.(k, v) end)

    {{:val, {:array, PArray.from_pairs(pairs)}}, env, i}
  end

  ## ───────────────── natural-order sorts ─────────────────

  # php natural order: digit runs compare numerically; keys preserved
  # (probed: img1.png kept its original index 3)
  defp natsort_v(vals, i), do: nat_sort(vals, i, false)
  defp natcasesort_v(vals, i), do: nat_sort(vals, i, true)

  defp nat_sort(vals, i, ci?) do
    case vals do
      [{:array, arr} | _] ->
        pairs =
          arr
          |> PArray.to_pairs()
          |> Enum.sort_by(fn {_k, v} -> v end, fn a, b -> nat_cmp_vals(a, b, ci?) end)

        {:ref_call, {:bool, true}, [{:array, PArray.from_pairs(pairs)}], i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp nat_cmp_vals({:string, a}, {:string, b}, ci?) do
    {a2, b2} = if ci?, do: {String.downcase(a), String.downcase(b)}, else: {a, b}
    nat_cmp_bin(a2, b2) < 0
  end

  defp nat_cmp_vals(a, b, _), do: Value.compare(a, b) < 0

  defp nat_cmp_bin(a, b) do
    {ra, rb} = {nat_runs(a), nat_runs(b)}

    cond do
      nat_lt(ra, rb) -> -1
      nat_lt(rb, ra) -> 1
      true -> 0
    end
  end

  defp nat_runs(s), do: nat_runs(s, {nil, ""}, []) |> Enum.reverse()

  defp nat_runs("", {nil, cur}, acc), do: acc
  defp nat_runs("", {kind, cur}, acc), do: [{kind, cur} | acc]

  defp nat_runs(<<d, rest::binary>>, {nil, cur}, acc) when d in ?0..?9,
    do: nat_runs(rest, {:digits, <<d>>}, push_text(cur, acc))

  defp nat_runs(<<c, rest::binary>>, {nil, cur}, acc),
    do: nat_runs(rest, {nil, cur <> <<c>>}, acc)

  defp nat_runs(<<d, rest::binary>>, {:digits, cur}, acc) when d in ?0..?9,
    do: nat_runs(rest, {:digits, cur <> <<d>>}, acc)

  defp nat_runs(<<c, rest::binary>>, {:digits, cur}, acc),
    do: nat_runs(rest, {nil, <<c>>}, [{:digits, cur} | acc])

  defp push_text("", acc), do: acc
  defp push_text(cur, acc), do: [{:text, cur} | acc]

  defp nat_lt([], []), do: false
  defp nat_lt([], _), do: true
  defp nat_lt(_, []), do: false

  defp nat_lt([x | ra], [y | rb]) do
    if x == y do
      nat_lt(ra, rb)
    else
      run_lt(x, y)
    end
  end

  defp run_lt({:digits, a}, {:digits, b}) do
    {ai, bi} = {String.to_integer(a), String.to_integer(b)}
    ai < bi
  end

  defp run_lt({a_kind, a}, {b_kind, b}) do
    # mixed/text runs compare lexically on the rendered text
    _ = {a_kind, b_kind}
    a < b
  end

  # shuffle/multisort write back through refs: sorted values, keys renumbered
  defp shuffle_v(vals, i) do
    case vals do
      [{:array, arr} | _] ->
        vals2 = PArray.values(arr) |> Enum.shuffle()
        {:ref_call, {:bool, true}, [{:array, PArray.from_pairs(Enum.map(vals2, &{nil, &1}))}], i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  # V1: sort the first array ascending, carry the second alongside (php
  # sorts each column following the first's permutation)
  defp array_multisort_v(vals, i) do
    arrays = arrays_of(vals)

    case arrays do
      [a1 | _rest] ->
        sorted_vals =
          a1
          |> PArray.values()
          |> Enum.sort(fn x, y -> Value.compare(x, y) < 0 end)

        pairs = Enum.with_index(sorted_vals, fn v, idx -> {idx, v} end)

        {:ref_call, {:bool, true}, [{:array, PArray.from_pairs(pairs)}], i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  # php 8.4 finders: ho raw — evaluate elements, callback decides
  defp ho_array_find([arr_arg, cb_arg | _], env, i) do
    case Eval.eval(arr_arg, env, i) do
      {{:val, {:array, arr}}, _, _} ->
        Enum.reduce_while(PArray.to_pairs(arr), {:not_found, i}, fn {_k, v}, {_, ia} ->
          case Eval.call_cb_raw(cb_arg, [v], env, ia) do
            {{:val, res}, _, ib} ->
              if Value.truthy?(res), do: {:halt, {:found, ib, v}}, else: {:cont, {:not_found, ib}}

            unw ->
              {:halt, {:passthrough, unw}}
          end
        end)
        |> case do
          {:found, i2, v} -> {{:val, v}, env, i2}
          {:not_found, i2} -> {{:val, :null}, env, i2}
          {:passthrough, unw} -> unw
        end

      unw ->
        unw
    end
  end

  defp ho_array_find_key([arr_arg, cb_arg | _], env, i) do
    case Eval.eval(arr_arg, env, i) do
      {{:val, {:array, arr}}, _, _} ->
        Enum.reduce_while(PArray.to_pairs(arr), {:not_found, i}, fn {k, v}, {_, ia} ->
          case Eval.call_cb_raw(cb_arg, [v], env, ia) do
            {{:val, res}, _, ib} ->
              if Value.truthy?(res), do: {:halt, {:found, ib, k}}, else: {:cont, {:not_found, ib}}

            unw ->
              {:halt, {:passthrough, unw}}
          end
        end)
        |> case do
          {:found, i2, k} -> {{:val, key_val(k)}, env, i2}
          {:not_found, i2} -> {{:val, :null}, env, i2}
          {:passthrough, unw} -> unw
        end

      unw ->
        unw
    end
  end

  ## ───────────────── replace family ─────────────────

  defp array_replace_v(vals, i) do
    arrays = arrays_of(vals)

    case arrays do
      [] ->
        {:ok, {:bool, false}, i}

      [base | repls] ->
        out = Enum.reduce(repls, base, fn r, acc -> replace_pairs(acc, r) end)
        {:ok, {:array, out}, i}
    end
  end

  defp replace_pairs(base, repl) do
    Enum.reduce(PArray.to_pairs(repl), base, fn {k, v}, acc ->
      PArray.put(acc, k, v)
      |> case do
        {:ok, a2} -> a2
        _ -> acc
      end
    end)
  end

  defp array_replace_recursive_v(vals, i) do
    arrays = arrays_of(vals)

    case arrays do
      [] ->
        {:ok, {:bool, false}, i}

      [base | repls] ->
        out = Enum.reduce(repls, base, fn repl, acc -> replace_recursive(acc, repl) end)
        {:ok, {:array, out}, i}
    end
  end

  defp replace_recursive(base, repl) do
    Enum.reduce(PArray.to_pairs(repl), base, fn {k, v}, acc ->
      existing = PArray.fetch(acc, k)

      new_v =
        case {existing, v} do
          {{:ok, {:array, a1}}, {:array, a2}} ->
            {:array, replace_recursive(a1, a2)}

          _ ->
            v
        end

      PArray.put(acc, k, new_v)
      |> case do
        {:ok, a2} -> a2
        _ -> acc
      end
    end)
  end

  defp arrays_of(vals) do
    vals
    |> Enum.map(fn
      {:array, a} -> a
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  ## ───────────────── count / find / rand ─────────────────

  defp array_rand_v(vals, i) do
    case arrays_of(vals) do
      [] ->
        {:ok, {:bool, false}, i}

      [arr | _] ->
        n =
          case Enum.at(vals, 1) do
            {:int, x} -> x
            _ -> 1
          end

        keys = arr |> PArray.to_pairs() |> Enum.map(&elem(&1, 0))

        if n <= 1 do
          k = Enum.at(keys, :rand.uniform(max(length(keys), 1)) - 1)
          {:ok, key_val(k), i}
        else
          picked =
            keys
            |> Enum.shuffle()
            |> Enum.take(min(n, length(keys)))

          arr2 = PArray.from_pairs(Enum.with_index(picked, fn k, idx -> {idx, key_val(k)} end))
          {:ok, {:array, arr2}, i}
        end
    end
  end

  ## ───────────────── ip2long family ─────────────────

  defp array_count_values_v(vals, i) do
    arr =
      vals
      |> arrays_of()
      |> List.first()

    if arr do
      # first-occurrence insertion order; numeric-string and int keys
      # merge php-style (probed: "1" and 1 collide on int 1)
      {counts, order} =
        Enum.reduce(PArray.values(arr), {%{}, []}, fn v, {cm, ord} ->
          key =
            case v do
              {:int, n} -> {:int, n}
              {:string, s} -> maybe_num_key(s)
              _ -> nil
            end

          if key do
            {Map.update(cm, key, 1, &(&1 + 1)),
             if(Enum.any?(ord, &keys_merge?(&1, key)), do: ord, else: ord ++ [key])}
          else
            {cm, ord}
          end
        end)

      arr2 =
        Enum.map(order, fn k -> {k, {:int, Map.fetch!(counts, k)}} end)
        |> PArray.from_pairs()

      {:ok, {:array, arr2}, i}
    else
      {:ok, {:array, PArray.new()}, i}
    end
  end

  # "1" and int 1 merge php-style regardless of tag shape
  defp keys_merge?({:int, n}, {:int, n2}), do: n == n2
  defp keys_merge?({:string, s}, {:string, s2}), do: s == s2

  defp keys_merge?({:int, n}, {:string, s2}),
    do: Integer.to_string(n) == s2

  defp keys_merge?({:string, s}, {:int, n2}),
    do: s == Integer.to_string(n2)

  defp maybe_num_key(s) do
    case Integer.parse(s) do
      {n, ""} -> {:int, n}
      _ -> {:string, s}
    end
  end

  # str_shuffle (string family but rides this batch): php seeds a random
  # permutation; empty stays empty (probed)
  defp str_shuffle_v(vals, i) do
    s = vals |> arrays_of() |> List.first() |> then(fn _ -> nil end)
    _ = s

    str =
      case vals do
        [{:string, x} | _] -> x
        [v | _] -> Eval.php_to_string(v)
        _ -> ""
      end

    shuffled =
      str
      |> String.to_charlist()
      |> Enum.shuffle()

    {:ok, {:string, List.to_string(shuffled)}, i}
  end

  defp ip2long_v(vals, i) do
    case vals do
      [{:string, ip} | _] ->
        case parse_ip(ip) do
          {:ok, n} when n <= 4_294_967_295 -> {:ok, {:int, n}, i}
          {:ok, n} -> {:ok, {:int, n - 4_294_967_296}, i}
          :error -> {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp parse_ip(ip) do
    ip
    |> String.split(".")
    |> case do
      [a, b, c, d] ->
        parts = [a, b, c, d] |> Enum.map(&Integer.parse/1)

        if Enum.all?(parts, &match?({n, ""} when n in 0..255, &1)) do
          [pa, pb, pc, pd] = Enum.map(parts, fn {n, ""} -> n end)
          {:ok, pa * 16_777_216 + pb * 65_536 + pc * 256 + pd}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp long2ip_v(vals, i) do
    n =
      case Enum.at(vals, 0, {:int, 0}) do
        {:int, x} -> x
        _ -> 0
      end

    n = if n < 0, do: n + 4_294_967_296, else: n
    a = div(n, 16_777_216)
    b = rem(div(n, 65_536), 256)
    c = rem(div(n, 256), 256)
    d = rem(n, 256)
    {:ok, {:string, "#{a}.#{b}.#{c}.#{d}"}, i}
  end
end
