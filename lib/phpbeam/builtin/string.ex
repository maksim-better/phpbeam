defmodule PhpBeam.Builtin.StringFns do
  @moduledoc "String functions."

  alias PhpBeam.{PArray, Value}

  def register(fns) do
    entries = %{
      "strlen" => &strlen/2,
      "strtolower" => &low/2,
      "strtoupper" => &up/2,
      "lcfirst" => &lcfirst/2,
      "ucfirst" => &ucfirst/2,
      "ucwords" => &ucwords/2,
      "trim" => &trim/2,
      "ltrim" => &ltrim/2,
      "rtrim" => &rtrim/2,
      "chop" => &rtrim/2,
      "substr" => &substr/2,
      "strpos" => &strpos/2,
      "strrpos" => &strrpos/2,
      "str_contains" => &str_contains/2,
      "str_starts_with" => &str_starts_with/2,
      "str_ends_with" => &str_ends_with/2,
      "str_replace" => &str_replace/2,
      "str_repeat" => &str_repeat/2,
      "str_pad" => &str_pad/2,
      "strrev" => &strrev/2,
      "str_split" => &str_split/2,
      "substr_count" => &substr_count/2,
      "strcmp" => &strcmp/2,
      "strcasecmp" => &strcasecmp/2,
      "strncmp" => &strncmp/2,
      "str_word_count" => &str_word_count/2,
      "nl2br" => &nl2br/2,
      "htmlspecialchars" => &htmlspecialchars/2,
      "htmlentities" => &htmlspecialchars/2,
      "number_format" => &number_format/2,
      "implode" => &implode/2,
      "join" => &implode/2,
      "explode" => &explode/2,
      "sprintf" => nil,
      "wordwrap" => &wordwrap/2,
      "str_pad_both" => &str_pad/2
    }

    entries = Enum.reject(entries, fn {_k, v} -> is_nil(v) end)

    fns
    |> Map.drop(["sprintf", "str_pad_both"])
    |> Map.merge(
      Map.new(entries, fn {name, fun} ->
        {name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []}}
      end)
    )
  end

  defp s({:string, s}), do: s
  defp s(v), do: PhpBeam.Eval.php_to_string(v)

  defp strlen([v | _], i), do: {:ok, {:int, byte_size(s(v))}, i}
  defp strlen([], i), do: {:ok, {:int, 0}, i}

  defp low([v | _], i), do: {:ok, {:string, downcase_ascii(s(v))}, i}
  defp up([v | _], i), do: {:ok, {:string, upcase_ascii(s(v))}, i}

  defp lcfirst([v | _], i), do: {:ok, {:string, lcfirst_s(s(v))}, i}
  defp ucfirst([v | _], i), do: {:ok, {:string, ucfirst_s(s(v))}, i}

  defp ucwords([v | _], i), do: {:ok, {:string, ucwords_s(s(v))}, i}

  defp trim([v, {:string, chars} | _], i),
    do: {:ok, {:string, trim_chars(s(v), chars, :both)}, i}

  defp trim([v | _], i), do: {:ok, {:string, String.trim(s(v))}, i}

  defp ltrim([v, {:string, chars} | _], i),
    do: {:ok, {:string, trim_chars(s(v), chars, :leading)}, i}

  defp ltrim([v | _], i), do: {:ok, {:string, String.trim_leading(s(v))}, i}

  defp rtrim([v, {:string, chars} | _], i),
    do: {:ok, {:string, trim_chars(s(v), chars, :trailing)}, i}

  defp rtrim([v | _], i), do: {:ok, {:string, String.trim_trailing(s(v))}, i}

  defp substr([v, {:int, start} | rest], i) do
    str = s(v)
    len = byte_size(str)

    start2 = if start < 0, do: max(len + start, 0), else: start

    case rest do
      [] ->
        if start2 > len,
          do: {:ok, {:string, ""}, i},
          else: {:ok, {:string, binary_part(str, start2, len - start2)}, i}

      [{:int, l} | _] ->
        l2 = if l < 0, do: max(len + l - start2, 0), else: l
        {:ok, {:string, binary_part(str, start2, min(l2, len - start2))}, i}

      [_] ->
        {:ok, {:string, ""}, i}
    end
  end

  defp substr(_, i), do: {:ok, {:string, ""}, i}

  defp strpos([hay, needle | _], i), do: pos_result(:binary.match(s(hay), s(needle)), i)
  defp strrpos([hay, needle | _], i), do: pos_result(last_match(s(hay), s(needle)), i)

  defp pos_result(:nomatch, i), do: {:ok, {:bool, false}, i}
  defp pos_result({pos, _}, i), do: {:ok, {:int, pos}, i}

  defp last_match(bin, needle) do
    case :binary.matches(bin, needle) do
      [] -> :nomatch
      matches -> List.last(matches)
    end
  end

  defp str_contains([hay, needle | _], i),
    do: {:ok, {:bool, String.contains?(s(hay), s(needle))}, i}

  defp str_starts_with([hay, n | _], i), do: {:ok, {:bool, String.starts_with?(s(hay), s(n))}, i}
  defp str_ends_with([hay, n | _], i), do: {:ok, {:bool, String.ends_with?(s(hay), s(n))}, i}

  defp str_replace([search, replace, subject | _], i) do
    {se, rp} = {maybe_list(search), maybe_list(replace)}

    out =
      Enum.reduce(Enum.with_index(se), s(subject), fn {needle, idx}, acc ->
        rep =
          case Enum.at(rp, idx) do
            nil -> if(rp == [], do: s(replace), else: "")
            r -> s(r)
          end

        String.replace(acc, s(needle), rep)
      end)

    {:ok, {:string, out}, i}
  end

  defp maybe_list({:array, arr}), do: PArray.values(arr)
  defp maybe_list(v), do: [v]

  defp str_repeat([v, {:int, n} | _], i),
    do: {:ok, {:string, String.duplicate(s(v), max(n, 0))}, i}

  defp str_pad([v, {:int, w} | rest], i) do
    str = s(v)

    pad_char =
      case rest do
        [{:string, p} | _] when byte_size(p) > 0 -> binary_part(p, 0, 1)
        _ -> " "
      end

    type =
      case rest do
        [_, {:int, t} | _] -> t
        _ -> 1
      end

    diff = max(w - byte_size(str), 0)

    out =
      cond do
        type == 2 ->
          half = div(diff, 2)
          String.duplicate(pad_char, diff - half) <> str <> String.duplicate(pad_char, half)

        type == 0 ->
          String.duplicate(pad_char, diff) <> str

        true ->
          str <> String.duplicate(pad_char, diff)
      end

    {:ok, {:string, out}, i}
  end

  defp strrev([v | _], i), do: {:ok, {:string, String.reverse(s(v))}, i}

  defp str_split([v | rest], i) do
    len =
      case rest do
        [{:int, l} | _] when l > 0 -> l
        _ -> 1
      end

    chunks = for <<chunk::binary-size(len) <- s(v)>>, do: {:string, chunk}

    {:ok, {:array, PArray.from_pairs(Enum.map(chunks, &{nil, &1}))}, i}
  end

  defp substr_count([hay, needle | _], i),
    do: {:ok, {:int, length(:binary.matches(s(hay), s(needle)))}, i}

  defp strcmp([a, b | _], i), do: cmp_result(Value.compare({:string, s(a)}, {:string, s(b)}), i)

  defp strcasecmp([a, b | _], i),
    do:
      cmp_result(
        Value.compare({:string, downcase_ascii(s(a))}, {:string, downcase_ascii(s(b))}),
        i
      )

  defp strncmp([a, b, {:int, n} | _], i),
    do:
      cmp_result(
        Value.compare(
          {:string, binary_part(s(a), 0, min(n, byte_size(s(a))))},
          {:string, binary_part(s(b), 0, min(n, byte_size(s(b))))}
        ),
        i
      )

  defp cmp_result(0, i), do: {:ok, {:int, 0}, i}
  defp cmp_result(x, i), do: {:ok, {:int, if(x < 0, do: -1, else: 1)}, i}

  defp str_word_count([v | _], i) do
    words = Regex.scan(~r/[A-Za-z'-]+/, s(v))
    {:ok, {:int, length(words)}, i}
  end

  defp nl2br([v | rest], i) do
    double? =
      case rest do
        [_, {:bool, true} | _] -> true
        _ -> false
      end

    br = if(double?, do: "<br />\n", else: "<br />")
    {:ok, {:string, String.replace(s(v), "\n", br)}, i}
  end

  @html_escape [{"&", "&amp;"}, {"\"", "&quot;"}, {"'", "&#039;"}, {"<", "&lt;"}, {">", "&gt;"}]

  defp htmlspecialchars([v | _], i) do
    out = Enum.reduce(@html_escape, s(v), fn {from, to}, acc -> String.replace(acc, from, to) end)
    {:ok, {:string, out}, i}
  end

  defp number_format([v | rest], i) do
    {:ok, {:float, f}} = Value.to_float(v)

    {decimals, dec_sep, thou_sep} =
      case rest do
        [{:int, d}, {:string, ds}, {:string, ts} | _] -> {d, ds, ts}
        [{:int, d}, {:string, ds} | _] -> {d, ds, ","}
        [{:int, d} | _] -> {d, ".", ","}
        _ -> {0, ".", ","}
      end

    formatted = :erlang.float_to_binary(f, decimals: max(0, decimals))
    {int_part, frac_part} = split_float_str(formatted)

    grouped =
      int_part
      |> String.to_charlist()
      |> Enum.reverse()
      |> Enum.chunk_every(3)
      |> Enum.map(&Enum.reverse/1)
      |> Enum.reverse()
      |> Enum.join(thou_sep)

    out = if decimals > 0, do: grouped <> dec_sep <> frac_part, else: grouped
    {:ok, {:string, out}, i}
  end

  defp split_float_str(str) do
    case String.split(str, ".") do
      [i] -> {String.trim_leading(i, "-"), ""}
      [i, f] -> {String.trim_leading(i, "-"), f}
    end
  end

  defp implode([sep, {:array, arr} | _], i),
    do: {:ok, {:string, Enum.map_join(PArray.values(arr), s(sep), &deref_str(&1, i))}, i}

  defp implode([{:array, arr}, sep | _], i),
    do: {:ok, {:string, Enum.map_join(PArray.values(arr), s(sep), &deref_str(&1, i))}, i}

  defp deref_str({:ref, _} = r, i), do: PhpBeam.Eval.php_to_string(PhpBeam.Eval.deref(r, i))
  defp deref_str(v, _i), do: PhpBeam.Eval.php_to_string(v)

  defp explode([sep, v | rest], i) do
    {str, sep_str} = {s(v), s(sep)}

    parts =
      if sep_str == "" do
        for <<c <- str>>, do: {:string, <<c>>}
      else
        String.split(str, sep_str)
      end

    parts =
      case rest do
        [{:int, n} | _] when n > 0 ->
          {head, tail} = Enum.split(parts, n - 1)
          head ++ [Enum.join(tail, sep_str)]

        _ ->
          parts
      end

    {:ok, {:array, PArray.from_pairs(Enum.map(parts, &{nil, {:string, &1}}))}, i}
  end

  defp wordwrap([v, {:int, width} | rest], i) do
    brk =
      case rest do
        [{:string, b} | _] -> b
        _ -> "\n"
      end

    words = String.split(s(v), " ")

    out =
      Enum.reduce(words, {"", 0}, fn w, {line, len} ->
        wlen = byte_size(w)

        cond do
          len == 0 -> {w, wlen}
          len + 1 + wlen > width -> {line <> brk <> w, wlen}
          true -> {line <> " " <> w, len + 1 + wlen}
        end
      end)
      |> elem(0)

    {:ok, {:string, out}, i}
  end

  defp downcase_ascii(s), do: String.downcase(s)
  defp upcase_ascii(s), do: String.upcase(s)

  defp lcfirst_s(<<c, rest::binary>>) when c >= ?A and c <= ?Z,
    do: <<c + 32>> <> rest

  defp lcfirst_s(s), do: s

  defp ucfirst_s(<<c, rest::binary>>) when c >= ?a and c <= ?z,
    do: <<c - 32>> <> rest

  defp ucfirst_s(s), do: s

  defp ucwords_s(s), do: Regex.replace(~r/\b[a-z]/, s, &String.upcase/1)

  defp trim_chars(str, chars, side) do
    set = MapSet.new(:binary.bin_to_list(chars))

    case side do
      :both -> trim_both(str, set)
      :leading -> trim_lead(str, set)
      :trailing -> trim_trail(str, set)
    end
  end

  defp trim_both(str, set) do
    str |> trim_lead(set) |> trim_trail(set)
  end

  defp trim_lead(<<c, rest::binary>>, set) do
    if MapSet.member?(set, c), do: trim_lead(rest, set), else: <<c, rest::binary>>
  end

  defp trim_lead(str, _), do: str

  defp trim_trail(str, set) do
    str
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> drop_while_set(set)
    |> Enum.reverse()
    |> List.to_string()
  end

  defp drop_while_set(list, set) do
    Enum.drop_while(list, &MapSet.member?(set, &1))
  end
end
