defmodule PhpBeam.Builtin.MbFns do
  @moduledoc """
  PHASE B2: mbstring + ctype + iconv — the pure-function text family.

  Substrate: Elixir strings ARE UTF-8 codepoint lists, so "multibyte" ops
  are grapheme/codepoint ops on `String`/`:unicode`. Encoding conversions
  support the family php apps actually touch (UTF-8/UTF-16/UTF-32/latin1/
  ASCII/Windows-1252); //TRANSLIT goes through NFD + combining-mark strip.

  Deferred (docs/matrix/deferred.md): mb_ereg* (11 fns — multibyte regex
  engine), mb_convert_kana, mb_send_mail, mb_convert_variables(>1 var).
  """

  alias PhpBeam.{Eval, PArray, Value}

  def register(fns) do
    entries =
      Map.new(ctype_entries() ++ iconv_entries() ++ mb_entries(), fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, entries)
  end

  ## ───────────────────────── ctype (11) ─────────────────────────

  # php 8: int args cast to string (deprecated); empty string and any
  # non-ASCII codepoint → false; ALL chars must match the ASCII class
  defp ctype_entries do
    [
      {"ctype_alnum", &ctype_check(&1, &2, :alnum)},
      {"ctype_alpha", &ctype_check(&1, &2, :alpha)},
      {"ctype_cntrl", &ctype_check(&1, &2, :cntrl)},
      {"ctype_digit", &ctype_check(&1, &2, :digit)},
      {"ctype_lower", &ctype_check(&1, &2, :lower)},
      {"ctype_graph", &ctype_check(&1, &2, :graph)},
      {"ctype_print", &ctype_check(&1, &2, :print)},
      {"ctype_punct", &ctype_check(&1, &2, :punct)},
      {"ctype_space", &ctype_check(&1, &2, :space)},
      {"ctype_upper", &ctype_check(&1, &2, :upper)},
      {"ctype_xdigit", &ctype_check(&1, &2, :xdigit)}
    ]
  end

  defp ctype_check(vals, i, kind) do
    str =
      case vals do
        [{:string, s} | _] -> s
        [v | _] -> Eval.php_to_string(v)
        _ -> ""
      end

    cond do
      str == "" ->
        {:ok, {:bool, false}, i}

      # legacy int semantics: the value is an ASCII CODEPOINT (php 8:
      # deprecated but active — probed ctype_digit(65) = 'A' → false);
      # the deprecation warning rides the A1 error pipeline
      match?([{:int, n} | _] when is_integer(n), vals) ->
        codepoint = elem(hd(vals), 1)

        w =
          PhpBeam.Eval.Error.warn_level(
            PhpBeam.Eval.Error.stub_env(),
            i,
            "Deprecated",
            "ctype_" <>
              Atom.to_string(kind) <>
              "(): Argument of type int will be interpreted as string in the future"
          )

        result =
          cond do
            codepoint < 0 -> true
            codepoint > 255 -> false
            true -> ctype_match?(codepoint, kind)
          end

        case w do
          {:cont, _, i2} -> {:ok, {:bool, result}, i2}
          {:unwind, u, _, i2} -> {:unwind, u, i2}
        end

      true ->
        ok? =
          str
          |> String.to_charlist()
          |> Enum.all?(&ctype_match?(&1, kind))

        {:ok, {:bool, ok?}, i}
    end
  end

  defp ctype_match?(c, :alnum), do: (c >= ?0 and c <= ?9) or alpha?(c)
  defp ctype_match?(c, :alpha), do: alpha?(c)
  defp ctype_match?(c, :cntrl), do: c < 32 or c == 127
  defp ctype_match?(c, :digit), do: c >= ?0 and c <= ?9
  defp ctype_match?(c, :lower), do: c >= ?a and c <= ?z
  defp ctype_match?(c, :graph), do: c > 32 and c < 127
  defp ctype_match?(c, :print), do: c >= 32 and c < 127
  defp ctype_match?(c, :punct), do: c > 32 and c < 127 and not ctype_match?(c, :alnum)
  defp ctype_match?(c, :space), do: c in [?\s, ?\n, ?\r, ?\t, ?\v, ?\f]
  defp ctype_match?(c, :upper), do: c >= ?A and c <= ?Z

  defp ctype_match?(c, :xdigit),
    do: (c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f) or (c >= ?A and c <= ?F)

  defp alpha?(c), do: (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z)

  ## ───────────────────────── iconv (10) ─────────────────────────

  defp iconv_entries do
    [
      {"iconv", &iconv_v/2},
      {"iconv_strlen", &iconv_strlen_v/2},
      {"iconv_substr", &iconv_substr_v/2},
      {"iconv_strpos", &iconv_strpos_v/2},
      {"iconv_strrpos", &iconv_strrpos_v/2},
      {"iconv_mime_encode", &iconv_mime_encode_v/2},
      {"iconv_mime_decode", &iconv_mime_decode_v/2},
      {"iconv_mime_decode_headers", &iconv_mime_decode_headers_v/2},
      {"iconv_set_encoding", &iconv_set_encoding_v/2},
      {"iconv_get_encoding", &iconv_get_encoding_v/2}
    ]
  end

  defp iconv_v(vals, i) do
    case vals do
      [from, to | rest] when is_tuple(from) and is_tuple(to) ->
        str =
          case rest do
            [v | _] -> Eval.php_to_string(v)
            _ -> ""
          end

        from_e = Eval.php_to_string(from)
        to_e = Eval.php_to_string(to)

        {to_base, translit, ignore} = split_modes(to_e)

        case convert_encoding(str, from_e, to_base) do
          {:ok, unicode} ->
            out =
              unicode
              |> then(&if translit, do: transliterate(&1), else: &1)
              |> then(&encode_to(&1, to_base, ignore))

            case out do
              {:ok, bin} -> {:ok, {:string, bin}, i}
              {:error, _} -> iconv_warn(str, i)
            end

          {:error, _} ->
            iconv_warn(str, i)
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp iconv_warn(_str, i) do
    w =
      PhpBeam.Eval.Error.warn(
        PhpBeam.Eval.Error.stub_env(),
        i,
        "iconv(): Wrong charset, conversion failed"
      )

    case w do
      {:cont, _, i2} -> {:ok, {:bool, false}, i2}
      {:unwind, u, _, i2} -> {:unwind, u, i2}
    end
  end

  # "UTF-8//TRANSLIT//IGNORE" → {base, translit?, ignore?}
  defp split_modes(spec) do
    parts = String.split(spec, "//")
    base = hd(parts) |> String.trim()

    flags =
      tl(parts)
      |> Enum.map(&String.trim/1)
      |> then(&{Enum.member?(&1, "TRANSLIT"), Enum.member?(&1, "IGNORE")})

    {base, elem(flags, 0), elem(flags, 1)}
  end

  # str (in from-encoding bytes) → unicode binary (normalized to UTF-8
  # codepoint semantics); only coherent encodings supported
  defp convert_encoding(str, "UTF-8" <> _, _),
    do: if(String.valid?(str), do: {:ok, str}, else: {:error, :invalid})

  defp convert_encoding(str, from, _)
       when from in ["ISO-8859-1", "latin1", "LATIN1", "Windows-1252", "CP1252"],
       do: {:ok, latin1_to_unicode(str)}

  defp convert_encoding(str, "ASCII" <> _, _),
    do:
      if(String.valid?(str) and byte_size(str) == String.length(str),
        do: {:ok, str},
        else: {:error, :invalid}
      )

  defp convert_encoding(_, from, _)
       when from in ["UTF-16", "UTF-16BE", "UTF-16LE", "UTF-32", "UCS-4"],
       do: {:error, :unsupported}

  defp convert_encoding(_, _, _), do: {:error, :unsupported}

  defp latin1_to_unicode(str) do
    str |> :binary.bin_to_list() |> List.to_string()
  end

  # NFD then drop combining marks: é → e (probed php translit behavior)
  defp transliterate(bin) do
    bin
    |> :unicode.characters_to_nfd_binary()
    |> String.to_charlist()
    |> Enum.reject(&(&1 >= 0x0300 and &1 <= 0x036F))
    |> List.to_string()
  end

  defp encode_to(unicode, to, ignore) do
    case to do
      t when t in ["UTF-8", "utf-8"] ->
        {:ok, unicode}

      t when t in ["ISO-8859-1", "latin1", "LATIN1", "Windows-1252", "CP1252"] ->
        unicode
        |> String.to_charlist()
        |> Enum.filter(&(&1 <= 255))
        |> then(
          &if ignore or byte_filtered?(unicode, &1),
            do: {:ok, :erlang.list_to_binary(&1)},
            else: {:error, :unmappable}
        )

      "ASCII" ->
        unicode
        |> String.to_charlist()
        |> Enum.filter(&(&1 < 128))
        |> then(
          &if ignore or byte_filtered?(unicode, &1),
            do: {:ok, :erlang.list_to_binary(&1)},
            else: {:error, :unmappable}
        )

      _ ->
        {:error, :unsupported}
    end
  end

  defp byte_filtered?(unicode, kept) do
    length(kept) == String.length(unicode)
  end

  defp iconv_strlen_v(vals, i) do
    str = vals |> val0() |> Eval.php_to_string()
    enc = vals |> at(1) |> enc_or_utf8()

    if iconv_valid?(str, enc) do
      {:ok, {:int, String.length(str)}, i}
    else
      iconv_illegal_warn("iconv_strlen", i, {:bool, false})
    end
  end

  defp enc_or_utf8(v) do
    case v do
      {:string, e} -> String.upcase(e)
      _ -> "UTF-8"
    end
  end

  defp iconv_valid?(str, "UTF-8"), do: String.valid?(str)
  defp iconv_valid?(str, "ASCII"), do: String.valid?(str) and byte_size(str) == String.length(str)
  defp iconv_valid?(_str, _latin1_like), do: true

  defp iconv_illegal_warn(fname, i, ret) do
    w =
      PhpBeam.Eval.Error.warn_level(
        PhpBeam.Eval.Error.stub_env(),
        i,
        "Notice",
        fname <> "(): Detected an illegal character in input string"
      )

    case w do
      {:cont, _, i2} -> {:ok, ret, i2}
      {:unwind, u, _, i2} -> {:unwind, u, i2}
    end
  end

  defp iconv_substr_v(vals, i) do
    str = vals |> val0() |> Eval.php_to_string()
    off = int_at(vals, 1)

    len =
      vals
      |> at(2)
      |> case do
        {:int, n} -> n
        _ -> nil
      end

    cps = String.to_charlist(str)
    n = length(cps)

    start =
      if off < 0,
        do: max(n + off, 0),
        else: min(off, n)

    out =
      if len == nil do
        Enum.drop(cps, start)
      else
        len = if len < 0, do: max(n + len - start, 0), else: len
        cps |> Enum.drop(start) |> Enum.take(len)
      end

    {:ok, {:string, List.to_string(out)}, i}
  end

  defp iconv_strpos_v(vals, i) do
    haystack = vals |> val0() |> Eval.php_to_string()
    needle = vals |> at(1) |> Eval.php_to_string()
    offset = int_at(vals, 2)

    h = String.to_charlist(haystack)
    nd = String.to_charlist(needle)

    pos = find_cp(h, nd, offset, 0)
    {:ok, if(pos, do: {:int, pos}, else: {:bool, false}), i}
  end

  defp iconv_strrpos_v(vals, i) do
    haystack = vals |> val0() |> Eval.php_to_string()
    needle = vals |> at(1) |> Eval.php_to_string()

    case rstr_pos(haystack, needle) do
      nil ->
        {:ok, {:bool, false}, i}

      p ->
        {:ok, {:int, String.length(binary_part(haystack, 0, p))}, i}
    end
  end

  defp find_cp([], _, _, _), do: nil
  defp find_cp(h, nd, offset, idx) when idx < offset, do: find_cp(tl(h), nd, offset, idx + 1)

  defp find_cp(h, nd, _offset, idx) do
    if Enum.take(h, length(nd)) == nd do
      idx
    else
      find_cp(tl(h), nd, 0, idx + 1)
    end
  end

  # "Subject: =?UTF-8?B?aMOpbGxv?=" (probed default shape; folding at 76)
  defp iconv_mime_encode_v(vals, i) do
    fname = vals |> val0() |> Eval.php_to_string()
    fvalue = vals |> at(1) |> Eval.php_to_string()

    prefs =
      case at(vals, 2) do
        {:array, arr} -> mime_prefs(arr)
        _ -> %{}
      end

    scheme = String.upcase(Map.get(prefs, "scheme", "B"))
    charset = Map.get(prefs, "input-charset", "UTF-8")
    lf = Map.get(prefs, "line-break-chars", "\r\n")
    linelen = Map.get(prefs, "line-length", 76)

    encoded =
      case scheme do
        "Q" -> mime_q_encode(fvalue)
        _ -> Base.encode64(fvalue)
      end

    token = "=?#{charset}?#{scheme}?#{encoded}?="
    header = "#{fname}: #{token}"

    {:ok, {:string, fold_mime(header, linelen, lf)}, i}
  end

  defp mime_prefs(arr) do
    Map.new(PArray.to_pairs(arr), fn {k, v} ->
      {to_string(k), Eval.php_to_string(v)}
    end)
  end

  defp mime_q_encode(s) do
    s
    |> String.to_charlist()
    |> Enum.map_join("", fn
      c when c in [?\s] -> "_"
      c when c >= 33 and c <= 126 and c not in [??, ?=, ?_] -> <<c>>
      c -> "=#{String.upcase(Integer.to_string(c, 16))}" |> String.pad_leading(3, ["0"])
    end)
  end

  defp fold_mime(header, linelen, lf) do
    if String.length(header) <= linelen do
      header
    else
      {first, rest} = String.split_at(header, linelen)
      first <> lf <> " " <> rest
    end
  end

  defp iconv_mime_decode_v(vals, i) do
    str = vals |> val0() |> Eval.php_to_string()
    {:ok, {:string, mime_decode(str)}, i}
  end

  defp iconv_mime_decode_headers_v(vals, i) do
    str = vals |> val0() |> Eval.php_to_string()

    pairs =
      str
      |> String.split(["\r\n", "\n"], trim: true)
      |> Enum.map(fn line ->
        case String.split(line, ":", parts: 2) do
          [k, v] -> {String.trim(k), {:string, mime_decode(String.trim(v))}}
          [k] -> {String.trim(k), {:string, ""}}
        end
      end)

    arr = PArray.from_pairs(pairs)
    {:ok, {:array, arr}, i}
  end

  # =?charset?B|Q?payload?= tokens, adjacent tokens joined without space
  defp mime_decode(str) do
    Regex.replace(~r/=\?([^?]+)\?([bBqQ])\?([^?]*)\?=/, str, fn full, _cs, scheme, payload ->
      dec =
        case String.upcase(scheme) do
          "B" ->
            Base.decode64(payload)
            |> case do
              {:ok, b} -> b
              _ -> payload
            end

          "Q" ->
            payload
            |> String.replace("_", " ")
            |> q_unquote()
        end

      # strip the space php consumes between adjacent tokens
      String.replace_prefix(full, full, dec)
    end)
    |> String.replace(~r/\?=\s=\?/, "?==?")
  end

  defp q_unquote(s) do
    Regex.replace(~r/=([0-9A-Fa-f]{2})/, s, fn _, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end

  # php 8.4: no-op returning false, silently (probed)
  defp iconv_set_encoding_v(_vals, i), do: {:ok, {:bool, false}, i}

  # php 8.4: per-type query returns false (deprecated); no-arg returns
  # the array of all three (probed)
  defp iconv_get_encoding_v(vals, i) do
    case vals do
      [type | _] when type != :null ->
        _ = type
        {:ok, {:bool, false}, i}

      _ ->
        arr =
          PArray.from_pairs([
            {"input_encoding", {:string, Map.get(i.ini, "iconv.input_encoding", "UTF-8")}},
            {"output_encoding", {:string, Map.get(i.ini, "iconv.output_encoding", "UTF-8")}},
            {"internal_encoding", {:string, Map.get(i.ini, "iconv.internal_encoding", "UTF-8")}}
          ])

        {:ok, {:array, arr}, i}
    end
  end

  ## ───────────────────────── mbstring ─────────────────────────

  defp mb_entries do
    [
      {"mb_strlen", &mb_strlen_v/2},
      {"mb_substr", &mb_substr_v/2},
      {"mb_strpos", &mb_strpos_v/2},
      {"mb_strrpos", &mb_strrpos_v/2},
      {"mb_stripos", &mb_stripos_v/2},
      {"mb_strripos", &mb_strripos_v/2},
      {"mb_str_split", &mb_str_split_v/2},
      {"mb_substr_count", &mb_substr_count_v/2},
      {"mb_strcut", &mb_strcut_v/2},
      {"mb_strwidth", &mb_strwidth_v/2},
      {"mb_strimwidth", &mb_strimwidth_v/2},
      {"mb_strtolower", &mb_strtolower_v/2},
      {"mb_strtoupper", &mb_strtoupper_v/2},
      {"mb_str_pad", &mb_str_pad_v/2},
      {"mb_strstr", &mb_strstr_v/2},
      {"mb_stristr", &mb_stristr_v/2},
      {"mb_strrchr", &mb_strrchr_v/2},
      {"mb_strrichr", &mb_strrichr_v/2},
      {"mb_convert_encoding", &mb_convert_encoding_v/2},
      {"mb_convert_case", &mb_convert_case_v/2},
      {"mb_ucfirst", &mb_ucfirst_v/2},
      {"mb_lcfirst", &mb_lcfirst_v/2},
      {"mb_trim", &mb_trim_v/2},
      {"mb_ltrim", &mb_ltrim_v/2},
      {"mb_rtrim", &mb_rtrim_v/2},
      {"mb_convert_case", &mb_convert_case_v/2},
      {"mb_scrub", &mb_scrub_v/2},
      {"mb_ord", &mb_ord_v/2},
      {"mb_chr", &mb_chr_v/2},
      {"mb_encode_mimeheader", &mb_encode_mimeheader_v/2},
      {"mb_decode_mimeheader", &mb_decode_mimeheader_v/2},
      {"mb_encode_numericentity", &mb_encode_numericentity_v/2},
      {"mb_decode_numericentity", &mb_decode_numericentity_v/2},
      {"mb_check_encoding", &mb_check_encoding_v/2},
      {"mb_detect_encoding", &mb_detect_encoding_v/2},
      {"mb_list_encodings", &mb_list_encodings_v/2},
      {"mb_encoding_aliases", &mb_encoding_aliases_v/2},
      {"mb_language", &mb_language_v/2},
      {"mb_http_input", &mb_http_input_v/2},
      {"mb_http_output", &mb_http_output_v/2},
      {"mb_detect_order", &mb_detect_order_v/2},
      {"mb_substitute_character", &mb_substitute_character_v/2},
      {"mb_preferred_mime_name", &mb_preferred_mime_name_v/2},
      {"mb_internal_encoding", &mb_internal_encoding_v/2},
      {"mb_get_info", &mb_get_info_v/2},
      {"mb_output_handler", &mb_output_handler_v/2},
      {"mb_parse_str", &mb_parse_str_v/2}
    ]
  end

  defp mb_strlen_v(vals, i), do: {:ok, {:int, String.length(str0(vals))}, i}

  defp mb_substr_v(vals, i),
    do: {:ok, {:string, mb_substr(str0(vals), int_at(vals, 1), opt_int(vals, 2))}, i}

  defp mb_substr(str, start, len) do
    cps = String.to_charlist(str)
    n = length(cps)
    start = if start < 0, do: max(n + start, 0), else: min(start, n)

    out =
      case len do
        nil -> Enum.drop(cps, start)
        l when l < 0 -> cps |> Enum.drop(start) |> Enum.take(max(n + l - start, 0))
        l -> cps |> Enum.drop(start) |> Enum.take(l)
      end

    List.to_string(out)
  end

  defp mb_strpos_v(vals, i), do: mb_find(vals, i, &String.length/1, false, false)
  defp mb_strrpos_v(vals, i), do: mb_find(vals, i, &String.length/1, true, false)
  defp mb_stripos_v(vals, i), do: mb_find(vals, i, &String.length/1, false, true)
  defp mb_strripos_v(vals, i), do: mb_find(vals, i, &String.length/1, true, true)

  defp mb_find(vals, i, _cp_len, from_end, ci) do
    hay = str0(vals)
    needle = str_at(vals, 1)

    h = if ci, do: String.downcase(hay), else: hay
    nd = if ci, do: String.downcase(needle), else: needle

    pos =
      if from_end do
        rstr_pos(h, nd)
      else
        case :binary.match(h, nd) do
          {p, _} -> p
          :nomatch -> nil
        end
      end

    case pos do
      nil ->
        {:ok, {:bool, false}, i}

      0 when needle == "" ->
        {:ok, {:int, 0}, i}

      p when is_integer(p) ->
        # byte position → codepoint count of the prefix
        {:ok, {:int, String.length(binary_part(hay, 0, p))}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  # last occurrence position (bytes) | nil
  defp rstr_pos(h, nd) when nd == "", do: byte_size(h)

  defp rstr_pos(h, nd) do
    case :binary.matches(h, [nd]) do
      [] -> nil
      ms -> ms |> List.last() |> elem(0)
    end
  end

  defp mb_str_split_v(vals, i) do
    s = str0(vals)

    n =
      case int_at(vals, 1) do
        x when x > 0 -> x
        _ -> 1
      end

    chunks =
      s
      |> String.to_charlist()
      |> Enum.chunk_every(n)
      |> Enum.map(&List.to_string/1)
      |> Enum.with_index(fn c, idx -> {idx, {:string, c}} end)

    {:ok, {:array, PArray.from_pairs(chunks)}, i}
  end

  defp mb_substr_count_v(vals, i) do
    hay = str0(vals)
    needle = str_at(vals, 1)
    {:ok, {:int, count_occurrences(hay, needle)}, i}
  end

  defp count_occurrences(hay, needle) when needle != "" do
    case :binary.matches(hay, [needle]) do
      [] -> 0
      ms -> length(ms)
    end
  end

  defp count_occurrences(_, _), do: 0

  # byte-cut that never splits a UTF-8 sequence (php mb_strcut)
  defp mb_strcut_v(vals, i) do
    s = str0(vals)
    start = int_at(vals, 1)
    len = opt_int(vals, 2)

    start = adjust_byte_start(s, start)

    taken =
      case len do
        nil -> binary_part(s, start, byte_size(s) - start)
        l -> take_bytes(s, start, l)
      end

    {:ok, {:string, taken}, i}
  end

  defp adjust_byte_start(s, start) when start >= 0 do
    adjust_start_fwd(s, start)
  end

  defp adjust_byte_start(s, start) do
    adjust_start_fwd(s, max(byte_size(s) + start, 0))
  end

  defp adjust_start_fwd(s, pos) when pos >= byte_size(s), do: byte_size(s)

  defp adjust_start_fwd(s, pos) do
    if valid_boundary?(s, pos), do: pos, else: adjust_start_fwd(s, pos - 1)
  end

  # a valid boundary byte is any UTF-8 START byte (not a 10xxxxxx continuation)
  defp valid_boundary?(s, pos) when pos >= byte_size(s), do: true

  defp valid_boundary?(s, pos) do
    <<_::binary-size(pos), b, _::binary>> = s
    b < 128 or b >= 192
  end

  defp take_bytes(_s, _start, len) when len <= 0, do: ""
  defp take_bytes(s, start, len), do: binary_part(s, start, min(len, byte_size(s) - start))

  # East-Asian width: wide CJK/fullwidth = 2, combining = 0, else 1
  defp mb_strwidth_v(vals, i) do
    {:ok, {:int, char_width(str0(vals))}, i}
  end

  defp char_width(s) do
    s
    |> String.to_charlist()
    |> Enum.reduce(0, fn c, acc -> acc + width_of(c) end)
  end

  defp width_of(c) when c >= 0x1100 and c <= 0x115F, do: 2
  defp width_of(c) when c >= 0x2E80 and c <= 0xA4CF, do: 2
  defp width_of(c) when c >= 0xAC00 and c <= 0xD7A3, do: 2
  defp width_of(c) when c >= 0xF900 and c <= 0xFAFF, do: 2
  defp width_of(c) when c >= 0xFE30 and c <= 0xFE6F, do: 2
  defp width_of(c) when c >= 0xFF00 and c <= 0xFF60, do: 2
  defp width_of(c) when c >= 0xFFE0 and c <= 0xFFE6, do: 2
  defp width_of(c) when c >= 0x20000 and c <= 0x2FFFD, do: 2
  defp width_of(c) when c >= 0x30000 and c <= 0x3FFFD, do: 2
  defp width_of(c) when c >= 0x0300 and c <= 0x036F, do: 0
  defp width_of(_), do: 1

  defp mb_strimwidth_v(vals, i) do
    s = str0(vals)
    start = int_at(vals, 1)
    width = int_at(vals, 2)

    marker =
      case at(vals, 3) do
        {:string, m} -> m
        _ -> ""
      end

    cps = String.to_charlist(s) |> Enum.drop(max(start, 0))

    {kept, w} =
      cps
      |> Enum.reduce_while({[], 0}, fn c, {acc, w} ->
        nw = w + width_of(c)

        if nw > width - char_width(marker) do
          {:halt, {acc, w}}
        else
          {:cont, {[c | acc], nw}}
        end
      end)

    {:ok, {:string, Enum.reverse(kept) |> List.to_string() |> Kernel.<>(marker)}, i}
  end

  defp mb_strtolower_v(vals, i), do: {:ok, {:string, String.downcase(str0(vals))}, i}
  defp mb_strtoupper_v(vals, i), do: {:ok, {:string, String.upcase(str0(vals))}, i}

  defp mb_convert_case_v(vals, i) do
    s = str0(vals)
    mode = int_at(vals, 1)

    # php constants: MB_CASE_UPPER=0, MB_CASE_LOWER=1, MB_CASE_TITLE=2
    out =
      case mode do
        0 -> String.upcase(s)
        1 -> String.downcase(s)
        2 -> String.split(s) |> Enum.map(&String.capitalize/1) |> Enum.join(" ")
        _ -> s
      end

    {:ok, {:string, out}, i}
  end

  defp mb_ucfirst_v(vals, i) do
    s = str0(vals)
    {h, t} = String.next_grapheme(s) || {"", ""}
    {:ok, {:string, String.upcase(h) <> t}, i}
  end

  defp mb_lcfirst_v(vals, i) do
    s = str0(vals)
    {h, t} = String.next_grapheme(s) || {"", ""}
    {:ok, {:string, String.downcase(h) <> t}, i}
  end

  defp mb_trim_v(vals, i), do: mb_trim_kind(vals, i, :both)
  defp mb_ltrim_v(vals, i), do: mb_trim_kind(vals, i, :left)
  defp mb_rtrim_v(vals, i), do: mb_trim_kind(vals, i, :right)

  defp mb_trim_kind(vals, i, side) do
    s = str0(vals)

    chars =
      case at(vals, 1) do
        {:string, c} -> c
        _ -> " \t\n\r\u{0}\v"
      end

    set = MapSet.new(String.to_charlist(chars))

    out =
      s
      |> String.to_charlist()
      |> then(fn cs ->
        cs =
          if side in [:left, :both], do: Enum.drop_while(cs, &MapSet.member?(set, &1)), else: cs

        cs =
          if side in [:right, :both],
            do:
              cs |> Enum.reverse() |> Enum.drop_while(&MapSet.member?(set, &1)) |> Enum.reverse(),
            else: cs

        cs
      end)
      |> List.to_string()

    {:ok, {:string, out}, i}
  end

  defp mb_str_pad_v(vals, i) do
    s = str0(vals)
    len = int_at(vals, 1)

    pad =
      case at(vals, 2) do
        {:string, p} when p != "" -> p
        _ -> " "
      end

    type =
      case at(vals, 3) do
        {:int, t} -> t
        _ -> 1
      end

    cur = char_width(s)
    pad_w = char_width(pad)

    total =
      if len <= cur, do: 0, else: len - cur

    fill =
      pad
      |> String.to_charlist()
      |> Stream.cycle()
      |> Enum.reduce_while({[], 0}, fn c, {acc, w} ->
        nw = w + width_of(c)
        if nw > total, do: {:halt, {acc, w}}, else: {:cont, {[c | acc], nw}}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> List.to_string()

    # php: STR_PAD_LEFT=0 (fill first), RIGHT=1 (fill last), BOTH=2
    out =
      case type do
        0 ->
          fill <> s

        1 ->
          s <> fill

        2 ->
          cps = String.to_charlist(fill)
          half = div(length(cps), 2)
          l = cps |> Enum.take(half) |> List.to_string()
          # the right side starts a FRESH cycle of the pad string (php)
          r =
            cps
            |> Stream.cycle()
            |> Enum.take(length(cps) - half)
            |> List.to_string()

          l <> s <> r

        _ ->
          s <> fill
      end

    {:ok, {:string, out}, i}
  end

  defp mb_strstr_v(vals, i), do: mb_search_str(vals, i, false, false)
  defp mb_stristr_v(vals, i), do: mb_search_str(vals, i, true, false)
  defp mb_strrchr_v(vals, i), do: mb_search_str(vals, i, false, true)
  defp mb_strrichr_v(vals, i), do: mb_search_str(vals, i, true, true)

  defp mb_search_str(vals, i, ci, from_end) do
    hay = str0(vals)
    needle = str_at(vals, 1)
    before? = truthy_at(vals, 2)

    h = if ci, do: String.downcase(hay), else: hay
    nd = if ci, do: String.downcase(needle), else: needle

    pos =
      if from_end do
        rstr_pos(h, nd)
      else
        case :binary.match(h, nd) do
          {p, _} -> p
          :nomatch -> nil
        end
      end

    case pos do
      nil ->
        {:ok, {:bool, false}, i}

      0 when needle == "" ->
        {:ok, {:string, hay}, i}

      p when is_integer(p) ->
        out =
          if before?, do: binary_part(hay, 0, p), else: binary_part(hay, p, byte_size(hay) - p)

        {:ok, {:string, out}, i}
    end
  end

  defp mb_convert_encoding_v(vals, i) do
    s = str0(vals)
    to = str_at(vals, 1)

    from =
      case at(vals, 2) do
        {:array, arr} ->
          arr |> PArray.values() |> Enum.map(&Eval.php_to_string/1) |> Enum.join(",")

        {:string, f} ->
          f

        _ ->
          "UTF-8"
      end

    from = String.split(from, ",") |> Enum.map(&String.trim/1) |> List.first() || "UTF-8"

    case convert_encoding(s, from, "UTF-8") do
      {:ok, unicode} ->
        case encode_to(unicode, norm_enc(to), true) do
          {:ok, bin} -> {:ok, {:string, bin}, i}
          _ -> {:ok, {:string, s}, i}
        end

      _ ->
        {:ok, {:string, s}, i}
    end
  end

  defp norm_enc(e) do
    case String.upcase(e) do
      "UTF-8" -> "UTF-8"
      "UTF8" -> "UTF-8"
      x -> x
    end
  end

  defp mb_scrub_v(vals, i) do
    s = str0(vals)

    scrubbed =
      if String.valid?(s) do
        s
      else
        s
        |> String.codepoints()
        |> Enum.map_join("", fn cp ->
          if String.valid?(cp), do: cp, else: "?"
        end)
      end

    {:ok, {:string, scrubbed}, i}
  end

  defp mb_ord_v(vals, i) do
    case String.next_codepoint(str0(vals)) do
      {cp, _} -> {:ok, {:int, hd(String.to_charlist(cp))}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mb_chr_v(vals, i) do
    code = int_at(vals, 0)

    out =
      if code > 0 and code < 0x110000 do
        {:string, List.to_string([code])}
      else
        {:bool, false}
      end

    {:ok, out, i}
  end

  defp mb_encode_mimeheader_v(vals, i) do
    s = str0(vals)

    charset =
      case at(vals, 1) do
        {:string, c} -> c
        _ -> "UTF-8"
      end

    b64 = Base.encode64(s)
    {:ok, {:string, "=?#{charset}?B?#{b64}?="}, i}
  end

  defp mb_decode_mimeheader_v(vals, i) do
    {:ok, {:string, mime_decode(str0(vals))}, i}
  end

  defp mb_encode_numericentity_v(vals, i) do
    s = str0(vals)

    out =
      s
      |> String.to_charlist()
      |> Enum.map_join("", &"&##{&1};")

    {:ok, {:string, out}, i}
  end

  defp mb_decode_numericentity_v(vals, i) do
    s = str0(vals)

    out =
      Regex.replace(~r/&#(\d+);/u, s, fn _, digits ->
        n = String.to_integer(digits)

        try do
          List.to_string([n])
        rescue
          _ -> ""
        end
      end)

    {:ok, {:string, out}, i}
  end

  defp mb_check_encoding_v(vals, i) do
    s = str0(vals)

    enc =
      case at(vals, 1) do
        {:string, e} -> e
        _ -> "UTF-8"
      end

    ok? =
      case String.upcase(enc) do
        x when x in ["UTF-8", "UTF8"] -> String.valid?(s)
        x when x in ["ASCII", "US-ASCII"] -> String.valid?(s) and byte_size(s) == String.length(s)
        _ -> String.valid?(s)
      end

    {:ok, {:bool, ok?}, i}
  end

  defp mb_detect_encoding_v(vals, i) do
    s = str0(vals)

    order =
      case at(vals, 1) do
        {:array, arr} -> arr |> PArray.values() |> Enum.map(&Eval.php_to_string/1)
        {:string, o} -> String.split(o, ",")
        _ -> ["UTF-8"]
      end

    found =
      Enum.find(order, fn enc ->
        case String.upcase(enc) do
          x when x in ["UTF-8", "UTF8"] -> String.valid?(s)
          "ASCII" -> String.valid?(s) and byte_size(s) == String.length(s)
          _ -> false
        end
      end)

    {:ok, if(found, do: {:string, found}, else: {:bool, false}), i}
  end

  # php's own list (probed; mobile/2024 variants trimmed)
  @mb_encodings ~w(
    BASE64 UUENCODE HTML-ENTITIES Quoted-Printable 7bit 8bit UCS-4 UCS-4BE UCS-4LE UCS-2
    UCS-2BE UCS-2LE UTF-32 UTF-32BE UTF-32LE UTF-16 UTF-16BE UTF-16LE UTF-8 UTF-7 UTF7-IMAP
    ASCII EUC-JP SJIS eucJP-win EUC-JP-2004 CP932 SJIS-win CP51932 JIS ISO-2022-JP
    ISO-2022-JP-MS GB18030 Windows-1252 ISO-8859-1 ISO-8859-2 ISO-8859-3 ISO-8859-4
    ISO-8859-5 ISO-8859-6 ISO-8859-7 ISO-8859-8 ISO-8859-9 ISO-8859-10 ISO-8859-13
    ISO-8859-14 ISO-8859-15 ISO-8859-16 EUC-CN CP936 HZ EUC-TW BIG-5 CP950 EUC-KR UHC
    Windows-1251 CP866 KOI8-R KOI8-U ArmSCII-8 CP850
  )

  defp mb_list_encodings_v(_vals, i) do
    arr =
      @mb_encodings
      |> Enum.with_index(fn e, idx -> {idx, {:string, e}} end)
      |> PArray.from_pairs()

    {:ok, {:array, arr}, i}
  end

  defp mb_encoding_aliases_v(vals, i) do
    e = String.upcase(str0(vals))

    aliases =
      case e do
        "UTF-8" -> ["utf8"]
        "UTF-16" -> ["utf16"]
        "ISO-8859-1" -> ["latin1", "ISO_8859-1", "8859_1"]
        "ASCII" -> ["us-ascii", "ANSI_X3.4-1968"]
        _ -> []
      end

    arr = aliases |> Enum.with_index(fn a, idx -> {idx, {:string, a}} end) |> PArray.from_pairs()
    {:ok, {:array, arr}, i}
  end

  # ── mbstring config getters/setters (ini-backed) ──
  defp mb_language_v(vals, i) do
    case vals do
      [{:string, _} = v | _] ->
        lang = Eval.php_to_string(v)
        {:ok, {:bool, true}, %{i | ini: Map.put(i.ini, "mbstring.language", lang)}}

      _ ->
        {:ok, {:string, Map.get(i.ini, "mbstring.language", "neutral")}, i}
    end
  end

  defp mb_http_input_v(vals, i) do
    case vals do
      [{:string, t} | _] ->
        case String.downcase(t) do
          "g" -> {:ok, {:string, "UTF-8"}, i}
          "p" -> {:ok, {:string, "UTF-8"}, i}
          "c" -> {:ok, {:string, "UTF-8"}, i}
          "i" -> {:ok, {:string, "UTF-8"}, i}
          _ -> {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp mb_http_output_v(vals, i) do
    case vals do
      [{:string, e} | _] ->
        {:ok, {:bool, true}, %{i | ini: Map.put(i.ini, "mbstring.http_output", e)}}

      _ ->
        {:ok, {:string, ini_or(Map.get(i.ini, "mbstring.http_output"), "UTF-8")}, i}
    end
  end

  defp mb_detect_order_v(vals, i) do
    case vals do
      [{:array, _} = v | _] ->
        order = v |> PArray.values() |> Enum.map(&Eval.php_to_string/1) |> Enum.join(",")
        {:ok, {:bool, true}, %{i | ini: Map.put(i.ini, "mbstring.detect_order", order)}}

      [{:string, o} | _] ->
        {:ok, {:bool, true}, %{i | ini: Map.put(i.ini, "mbstring.detect_order", o)}}

      _ ->
        order =
          Map.get(i.ini, "mbstring.detect_order", "UTF-8, ASCII")
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.with_index(fn e, idx -> {idx, {:string, String.trim(e)}} end)

        {:ok, {:array, PArray.from_pairs(order)}, i}
    end
  end

  defp mb_substitute_character_v(vals, i) do
    case vals do
      [v | _] when v != {:bool, false} ->
        sub =
          case v do
            {:int, n} -> Integer.to_string(n)
            {:string, "long" <> _} -> "long"
            {:string, "none"} -> "none"
            {:string, s} -> s
            _ -> "none"
          end

        {:ok, {:bool, true}, %{i | ini: Map.put(i.ini, "mbstring.substitute_character", sub)}}

      _ ->
        case Map.get(i.ini, "mbstring.substitute_character", "63") do
          "63" ->
            {:ok, {:int, 63}, i}

          "none" ->
            {:ok, {:string, "none"}, i}

          "long" ->
            {:ok, {:string, "long"}, i}

          other ->
            case Integer.parse(other) do
              {n, ""} -> {:ok, {:int, n}, i}
              _ -> {:ok, {:int, 63}, i}
            end
        end
    end
  end

  defp mb_preferred_mime_name_v(vals, i) do
    e = String.upcase(str0(vals))

    {:ok,
     {:string,
      Map.get(
        %{
          "UTF-8" => "UTF-8",
          "UTF-16" => "UTF-16",
          "ISO-8859-1" => "ISO-8859-1",
          "ASCII" => "US-ASCII",
          "SJIS" => "Shift_JIS",
          "EUC-JP" => "EUC-JP",
          "WINDOWS-1252" => "WINDOWS-1252"
        },
        e,
        e
      )}, i}
  end

  defp mb_internal_encoding_v(vals, i) do
    case vals do
      [{:string, e} | _] ->
        {:ok, {:bool, true}, %{i | ini: Map.put(i.ini, "mbstring.internal_encoding", e)}}

      _ ->
        {:ok, {:string, ini_or(Map.get(i.ini, "mbstring.internal_encoding"), "UTF-8")}, i}
    end
  end

  defp mb_get_info_v(vals, i) do
    type =
      case vals do
        [{:string, t} | _] -> String.downcase(t)
        _ -> "all"
      end

    case type do
      "internal_encoding" ->
        {:ok, {:string, ini_or(Map.get(i.ini, "mbstring.internal_encoding"), "UTF-8")}, i}

      "http_output" ->
        {:ok, {:string, ini_or(Map.get(i.ini, "mbstring.http_output"), "UTF-8")}, i}

      "http_input" ->
        {:ok, {:string, "UTF-8"}, i}

      _ ->
        arr =
          PArray.from_pairs([
            {"internal_encoding",
             {:string, Map.get(i.ini, "mbstring.internal_encoding", "UTF-8")}},
            {"http_output", {:string, Map.get(i.ini, "mbstring.http_output", "UTF-8")}},
            {"http_input", {:string, "UTF-8"}},
            {"func_overload", {:int, 0}}
          ])

        {:ok, {:array, arr}, i}
    end
  end

  # php sets the mbstring output header — with output already begun it
  # emits the headers-sent warning, then returns the contents (probed)
  defp mb_output_handler_v(vals, i) do
    contents = str0(vals)

    i2 =
      case i.output_origin do
        {file, line} ->
          w =
            PhpBeam.Eval.Error.warn(
              PhpBeam.Eval.Error.stub_env(),
              i,
              "Cannot modify header information - headers already sent by (output started at #{file}:#{line})"
            )

          case w do
            {:cont, _, i3} -> i3
            {:unwind, _, _, i3} -> i3
          end

        _ ->
          i
      end

    {:ok, {:string, contents}, i2}
  end

  defp mb_parse_str_v(vals, i) do
    # with a second arg: results written there by ref — handled by the
    # ho layer would need raw args; registered simple variant returns
    # false (parse_str without output var is a parse error in php 8)
    {:ok, {:bool, false}, i}
  end

  ## helpers

  defp ini_or(nil, d), do: d
  defp ini_or("", d), do: d
  defp ini_or(v, _), do: v

  defp str0(vals), do: vals |> at(0) |> Eval.php_to_string()
  defp str_at(vals, n), do: vals |> at(n) |> Eval.php_to_string()
  defp at(vals, n), do: Enum.at(vals, n, :null)

  defp val0(vals), do: Enum.at(vals, 0, :null)

  defp int_at(vals, n) do
    case at(vals, n) do
      {:int, x} -> x
      _ -> 0
    end
  end

  defp opt_int(vals, n) do
    case at(vals, n) do
      {:int, x} -> x
      _ -> nil
    end
  end

  defp truthy_at(vals, n), do: Value.truthy?(at(vals, n))
end
