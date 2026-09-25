defmodule PhpBeam.Builtin.PatternFns do
  @moduledoc """
  Pure preg_* builtins: preg_replace (arrays + `$N`/`${N}`/`\\N`/`$name`
  backreferences), preg_split (NO_EMPTY / DELIM_CAPTURE / OFFSET_CAPTURE,
  limits), preg_grep, preg_quote. The by-ref `$matches` family and the
  callback variant live in `Eval.dispatch_ho`.
  """

  alias PhpBeam.{PArray, Pattern, Value}

  @split_no_empty 1
  @split_delim_capture 2
  @split_offset_capture 4

  def register(fns) do
    entries = %{
      "preg_replace" => &preg_replace/2,
      "preg_filter" => &preg_replace/2,
      "preg_split" => &preg_split/2,
      "preg_grep" => &preg_grep/2,
      "preg_quote" => &preg_quote/2,
      "preg_last_error" => &preg_last_error/2
    }

    Enum.reduce(entries, fns, fn {name, fun}, acc ->
      Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
    end)
    |> Map.put("preg_replace", %{fun: fn v, i, _c -> preg_replace(v, i) end, refs: [4]})
    |> Map.merge(ho_entries())
  end

  # ── higher-order builtins (registry v2 ho: entries) ──
  # preg_match/match_all/replace_callback receive RAW argument ASTs: $matches
  # is written back through the lvalue gateway, PREG_* flag args evaluate here

  defp ho_entries do
    nofun = fn _v, i, _c -> {:ok, :null, i} end
    ho = fn fun -> %{fun: nofun, refs: [], ho: %{args: :raw, fun: fun}} end

    %{
      "preg_match" => ho.(&ho_impl_preg_match/3),
      "preg_match_all" => ho.(&ho_impl_preg_match_all/3),
      "preg_replace_callback" => ho.(&ho_impl_preg_replace_callback/3)
    }
  end

  ## ───────────────────────── preg_replace ─────────────────────────

  # args: (pattern, replacement, subject, limit?, &count?)
  defp preg_replace([pat, repl | rest], i) do
    limit =
      case Enum.at(rest, 1) do
        {:int, n} -> n
        _ -> -1
      end

    pats = list_of_strings(pat)
    repls = list_of_strings(repl)
    pairs = Enum.zip(pats, Stream.cycle(repls))

    subj =
      case rest do
        [s | _] -> s
        [] -> :null
      end

    case subj do
      {:string, s} ->
        {out, count} = replace_in(s, pairs, limit)
        count_ref({:string, out}, count, i)

      {:array, arr} ->
        {outs, counts} =
          Enum.reduce(PArray.to_pairs(arr), {[], 0}, fn {k, v}, {acc, c} ->
            {out2, c2} = replace_in(Value.cast_string_unsafe(v), pairs, limit)
            {[{wrap_key(k), {:string, out2}} | acc], c + c2}
          end)

        count_ref({:array, PArray.from_pairs(Enum.reverse(outs))}, counts, i)

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  # `&$count` is argument 4: write back through the by-ref channel
  defp count_ref(value, count, i),
    do: {:ref_call, value, [nil, nil, nil, nil, {:int, count}], i}

  defp preg_replace(_, i), do: {:ok, {:bool, false}, i}

  defp list_of_strings({:array, arr}), do: Enum.map(PArray.values(arr), &unwrap/1)

  defp list_of_strings(v), do: [unwrap(v)]

  defp unwrap({:string, s}), do: s
  defp unwrap(v), do: Value.cast_string_unsafe(v)

  defp wrap_key(k) when is_integer(k), do: {:int, k}
  defp wrap_key(k) when is_binary(k), do: {:string, k}

  defp replace_in(subject, pat_repl_pairs, limit) do
    Enum.reduce(pat_repl_pairs, {subject, 0}, fn {p, r}, {acc, n} ->
      case Pattern.parse(p) do
        {:ok, %Pattern{} = pat} ->
          {out2, n2} = replace_loop(acc, pat, r, limit, 0, 0, [])
          {out2, n + n2}

        _ ->
          {acc, n}
      end
    end)
  end

  defp replace_loop(subject, pat, repl, limit, pos, count, acc) do
    size = byte_size(subject)
    tail = fn p -> binary_part(subject, min(p, size), max(0, size - min(p, size))) end

    if limit >= 0 and count >= limit do
      {IO.iodata_to_binary(Enum.reverse([tail.(pos) | acc])), count}
    else
      case Pattern.run_at(pat, subject, pos) do
        {:ok, pairs, next} ->
          {s, _l} = hd(pairs)

          # zero-width matches can push pos past the next match start
          pre = binary_part(subject, pos, max(0, s - pos))
          piece = if repl == "", do: "", else: expand_refs(repl, pat, subject, pairs)

          replace_loop(subject, pat, repl, limit, max(next, pos + 1), count + 1, [
            piece,
            pre | acc
          ])

        _ ->
          {IO.iodata_to_binary(Enum.reverse([tail.(pos) | acc])), count}
      end
    end
  end

  @ref_re ~r/\$(\d+)|\$\{(\d+)\}|\\(\d+)|\$([a-zA-Z_][a-zA-Z0-9_]*)/

  defp expand_refs(repl, %Pattern{} = pat, subject, pairs) do
    Regex.replace(@ref_re, repl, fn full, d1, d2, d3, name ->
      idx =
        cond do
          d1 != "" -> String.to_integer(d1)
          d2 != "" -> String.to_integer(d2)
          d3 != "" -> String.to_integer(d3)
          true -> nil
        end

      cond do
        idx != nil and idx <= pat.ngroups ->
          Pattern.capture_bin(subject, pairs, idx)

        name != "" ->
          case Enum.find(pat.names, fn {_i, n} -> n == name end) do
            {gi, _} -> Pattern.capture_bin(subject, pairs, gi)
            nil -> full
          end

        true ->
          full
      end
    end)
  end

  ## ───────────────────────── preg_split ─────────────────────────

  defp preg_split([pat, subj | rest], i) do
    limit = int_at(rest, 0, -1)
    flags = int_at(rest, 1, 0)

    with {:string, p} <- pat,
         {:string, s} <- subj,
         {:ok, %Pattern{} = parsed} <- Pattern.parse(p) do
      parts = split_loop(s, parsed, limit, flags, 0, 0, [])
      {:ok, {:array, PArray.from_pairs(Enum.map(parts, &{nil, &1}))}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp preg_split(_, i), do: {:ok, {:bool, false}, i}

  defp int_at(list, n, default) do
    case Enum.at(list, n) do
      {:int, v} -> v
      _ -> default
    end
  end

  defp split_loop(subject, pat, limit, flags, pos, count, acc) do
    no_empty? = Bitwise.band(flags, @split_no_empty) != 0
    delim? = Bitwise.band(flags, @split_delim_capture) != 0
    off? = Bitwise.band(flags, @split_offset_capture) != 0

    wrap = fn bin, o ->
      if off?,
        do: {:array, PArray.from_pairs([{nil, {:string, bin}}, {nil, {:int, o}}])},
        else: {:string, bin}
    end

    if limit > 0 and count + 1 >= limit do
      tail = binary_part(subject, pos, byte_size(subject) - pos)
      finalize_split(Enum.reverse([wrap.(tail, pos) | acc]), no_empty?)
    else
      case Pattern.run_at(pat, subject, pos) do
        {:ok, pairs, next} ->
          {s, l} = hd(pairs)
          pre = wrap.(binary_part(subject, pos, s - pos), pos)

          caps =
            if delim? do
              for gi <- 1..pat.ngroups,
                  {cs, cl} <- [Pattern.span(pairs, gi)],
                  cs >= 0 do
                wrap.(binary_part(subject, cs, cl), cs)
              end
            else
              []
            end

          split_loop(
            subject,
            pat,
            limit,
            flags,
            max(next, pos + 1),
            count + 1,
            [pre | acc] ++ caps
          )

        _ ->
          tail = binary_part(subject, pos, byte_size(subject) - pos)
          finalize_split(Enum.reverse([wrap.(tail, pos) | acc]), no_empty?)
      end
    end
  end

  defp finalize_split(parts, false), do: parts
  defp finalize_split(parts, true), do: Enum.reject(parts, &empty_part?/1)

  defp empty_part?({:string, ""}), do: true
  defp empty_part?({:array, arr}), do: PArray.values(arr) == [{:string, ""}]
  defp empty_part?(_), do: false

  ## ───────────────────────── preg_grep / quote ─────────────────────────

  @grep_invert 1

  defp preg_grep([pat, {:array, arr} | rest], i) do
    invert? = int_at(rest, 0, 0) == @grep_invert

    with {:string, p} <- pat,
         {:ok, %Pattern{} = parsed} <- Pattern.parse(p) do
      kept =
        for {k, v} <- PArray.to_pairs(arr),
            s = Value.cast_string_unsafe(v),
            m = match_here?(parsed, s),
            if(invert?, do: not m, else: m) do
          {wrap_key(k), v}
        end

      {:ok, {:array, PArray.from_pairs(kept)}, i}
    else
      _ -> {:ok, {:array, PArray.new()}, i}
    end
  end

  defp preg_grep(_, i), do: {:ok, {:array, PArray.new()}, i}

  defp match_here?(%Pattern{} = pat, subject) do
    case Pattern.run_at(pat, subject, 0) do
      {:ok, _, _} -> true
      _ -> false
    end
  end

  @quote_special '.\+*?[^]$(){}=!<>|:-#/'

  defp preg_quote([{:string, s} | rest], i) do
    extra =
      case rest do
        [{:string, d} | _] -> d
        _ -> ""
      end

    escaped =
      for <<c <- s>>, into: "" do
        if c in @quote_special or String.contains?(extra, <<c>>) do
          "\\" <> <<c>>
        else
          <<c>>
        end
      end

    {:ok, {:string, escaped}, i}
  end

  defp preg_quote(_, i), do: {:ok, {:string, ""}, i}

  defp preg_last_error(_, i), do: {:ok, {:int, 0}, i}

  defp ho_impl_preg_match([pat_arg, subj_arg | rest], env, interp) do
    {{:val, pv}, _, i1} = PhpBeam.Eval.eval(pat_arg, env, interp)
    {{:val, sv}, _, i2} = PhpBeam.Eval.eval(subj_arg, env, i1)
    flags = int_arg(rest, 1, env, i2)
    offset = int_arg(rest, 2, env, i2)

    with {:string, p} <- pv,
         {:string, s} <- sv,
         {:ok, %Pattern{} = pat} <- Pattern.parse(p) do
      case Pattern.run_at(pat, s, max(0, offset)) do
        {:ok, pairs, _next} ->
          row = Pattern.row(pairs, pat, s, flags)
          {env2, i3} = assign_matches(rest, 0, {:array, row}, env, i2)
          {{:val, {:int, 1}}, env2, i3}

        _ ->
          {env2, i3} = assign_matches(rest, 0, {:array, PArray.new()}, env, i2)
          {{:val, {:int, 0}}, env2, i3}
      end
    else
      {:error, msg} ->
        i3 = PhpBeam.Eval.warn(env, i2, "preg_match(): #{msg}")
        {{:val, {:bool, false}}, env, i3}

      _ ->
        {{:val, {:bool, false}}, env, i2}
    end
  end

  defp ho_impl_preg_match_all([pat_arg, subj_arg | rest], env, interp) do
    {{:val, pv}, _, i1} = PhpBeam.Eval.eval(pat_arg, env, interp)
    {{:val, sv}, _, i2} = PhpBeam.Eval.eval(subj_arg, env, i1)
    flags = int_arg(rest, 1, env, i2)
    set_order? = Bitwise.band(flags, 2) != 0

    with {:string, p} <- pv,
         {:string, s} <- sv,
         {:ok, %Pattern{} = pat} <- Pattern.parse(p) do
      case Pattern.scan_all(pat, s, 0) do
        {:ok, all} ->
          row_count = length(all)

          arr =
            if set_order? do
              rows = Enum.map(all, &{:array, Pattern.row(&1, pat, s, flags)})
              PArray.from_pairs(Enum.map(rows, &{nil, &1}))
            else
              # PATTERN_ORDER: matches[0] = fulls, [i] = group i-1 per match
              fulls =
                Enum.map(all, fn pairs -> {nil, {:string, Pattern.capture_bin(s, pairs, 0)}} end)

              groups =
                for gi <- 1..pat.ngroups do
                  vals =
                    Enum.map(all, fn pairs ->
                      {cs, cl} = Pattern.span(pairs, gi)

                      if cs >= 0,
                        do: {nil, {:string, binary_part(s, cs, cl)}},
                        else: {nil, {:string, ""}}
                    end)

                  {{:int, gi}, {:array, PArray.from_pairs(vals)}}
                end

              named =
                for {gi, name} <- pat.names do
                  vals =
                    Enum.map(all, fn pairs ->
                      {cs, cl} = Pattern.span(pairs, gi)

                      if cs >= 0,
                        do: {nil, {:string, binary_part(s, cs, cl)}},
                        else: {nil, {:string, ""}}
                    end)

                  {{:string, name}, {:array, PArray.from_pairs(vals)}}
                end

              PArray.from_pairs(
                [{{:int, 0}, {:array, PArray.from_pairs(fulls)}}] ++ groups ++ named
              )
            end

          {env2, i3} = assign_matches(rest, 0, {:array, arr}, env, i2)
          {{:val, {:int, row_count}}, env2, i3}

        _ ->
          {env2, i3} = assign_matches(rest, 0, {:array, PArray.new()}, env, i2)
          {{:val, {:int, 0}}, env2, i3}
      end
    else
      {:error, msg} ->
        i3 = PhpBeam.Eval.warn(env, i2, "preg_match_all(): #{msg}")
        {{:val, {:bool, false}}, env, i3}

      _ ->
        {{:val, {:bool, false}}, env, i2}
    end
  end

  defp ho_impl_preg_replace_callback([pat_arg, cb_arg, subj_arg | rest], env, interp) do
    {{:val, pv}, _, i1} = PhpBeam.Eval.eval(pat_arg, env, interp)
    {{:val, sv}, _, i2} = PhpBeam.Eval.eval(subj_arg, env, i1)
    limit = int_arg(rest, 0, env, i2, -1)

    with {:string, p} <- pv,
         {:string, s} <- sv,
         {:ok, %Pattern{} = pat} <- Pattern.parse(p) do
      {out, _n} =
        cb_replace_loop(s, pat, cb_arg, limit, 0, 0, [], env, i2)

      {{:val, {:string, IO.iodata_to_binary(out)}}, env, i2}
    else
      {:error, msg} ->
        i3 = PhpBeam.Eval.warn(env, i2, "preg_replace_callback(): #{msg}")
        {{:val, {:bool, false}}, env, i3}

      _ ->
        {{:val, :null}, env, i2}
    end
  end

  defp cb_replace_loop(subject, pat, cb_arg, limit, pos, count, acc, env, interp) do
    if limit >= 0 and count >= limit do
      {Enum.reverse([binary_part(subject, pos, byte_size(subject) - pos) | acc]), count}
    else
      case Pattern.run_at(pat, subject, pos) do
        {:ok, pairs, next} ->
          {s, l} = hd(pairs)
          pre = binary_part(subject, pos, s - pos)
          row = {:array, Pattern.row(pairs, pat, subject, 0)}

          piece =
            case PhpBeam.Eval.call_cb_raw(cb_arg, [row], env, interp) do
              {{:val, v}, _, _} -> PhpBeam.Value.cast_string_unsafe(v)
              _ -> ""
            end

          cb_replace_loop(
            subject,
            pat,
            cb_arg,
            limit,
            max(next, pos + 1),
            count + 1,
            [piece, pre | acc],
            env,
            interp
          )

        _ ->
          {Enum.reverse([binary_part(subject, pos, byte_size(subject) - pos) | acc]), count}
      end
    end
  end

  # bare-AST arguments (the raw dispatch branch unwraps {:arg, ...}):
  # evaluate non-ref args like PREG_* constants; write $matches via lvalue

  defp int_arg(args, n, env, interp, default \\ 0)

  defp int_arg(args, n, env, interp, default) do
    case Enum.at(args, n) do
      nil ->
        default

      e ->
        case PhpBeam.Eval.eval(e, env, interp) do
          {{:val, {:int, v}}, _, _} -> v
          _ -> default
        end
    end
  end

  defp assign_matches(args, n, value, env, interp) do
    case Enum.at(args, n) do
      nil -> {env, interp}
      lval -> PhpBeam.Eval.assign(lval, value, env, interp)
    end
  end
end
