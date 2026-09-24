defmodule PhpBeam.Builtin.MiscFns do
  @moduledoc """
  The misc sweep: strings (ord/chr/strtr/strspn/natural compare/substr_*),
  paths (dirname/basename/pathinfo), digests (md5/sha1/crc32), URL codecs,
  parse_url/http_build_query, class checks (is_a/is_callable), runtime
  no-ops (header/setcookie/headers_sent), and friends — the ~3000-call
  WordPress tail behind the big families.
  """

  alias PhpBeam.{PArray, Value}

  def register(fns) do
    entries = %{
      "ord" => &ord_v/2,
      "chr" => &chr_v/2,
      "strstr" => &strstr_v/2,
      "stristr" => &stristr_v/2,
      "stripos" => &stripos_v/2,
      "strripos" => &strripos_v/2,
      "strnatcmp" => &strnatcmp_v/2,
      "strnatcasecmp" => &strnatcasecmp_v/2,
      "strspn" => &strspn_v/2,
      "strcspn" => &strcspn_v/2,
      "strtr" => &strtr_v/2,
      "substr_replace" => &substr_replace_v/2,
      "substr_compare" => &substr_compare_v/2,
      "version_compare" => &version_compare_v/2,
      "bin2hex" => &bin2hex_v/2,
      "hex2bin" => &hex2bin_v/2,
      "base64_encode" => &base64_encode_v/2,
      "base64_decode" => &base64_decode_v/2,
      "urlencode" => &urlencode_v/2,
      "urldecode" => &urldecode_v/2,
      "rawurlencode" => &rawurlencode_v/2,
      "rawurldecode" => &rawurldecode_v/2,
      "html_entity_decode" => &html_entity_decode_v/2,
      "escapeshellarg" => &escapeshellarg_v/2,
      "uniqid" => &uniqid_v/2,
      "dirname" => &dirname_v/2,
      "basename" => &basename_v/2,
      "pathinfo" => &pathinfo_v/2,
      "parse_url" => &parse_url_v/2,
      "md5" => &md5_v/2,
      "sha1" => &sha1_v/2,
      "crc32" => &crc32_v/2,
      "crc32b" => &crc32b_v/2,
      "hash" => &hash_v/2,
      "hash_hmac" => &hash_hmac_v/2,
      "hash_equals" => &hash_equals_v/2,
      "hash_algos" => &hash_algos_v/2,
      "is_resource" => &is_resource_v/2,
      "is_callable" => &is_callable_v/2,
      "is_a" => &is_a_v/2,
      "is_subclass_of" => &is_subclass_of_v/2,
      "extension_loaded" => &extension_loaded_v/2,
      "getenv" => &getenv_v/2,
      "json_last_error" => &json_last_error_v/2,
      "json_last_error_msg" => &json_last_error_msg_v/2,
      "trigger_error" => &trigger_error_v/2,
      "assert" => &assert_v/2,
      "header" => &header_v/2,
      "setcookie" => &setcookie_v/2,
      "headers_sent" => &headers_sent_v/2,
      "error_log" => &error_log_v/2,
      "http_build_query" => &http_build_query_v/2,
      "glob" => &glob_v/2,
      "file" => &file_v/2,
      "filemtime" => &filemtime_v/2,
      "chmod" => &chmod_v/2,
      "chdir" => &chdir_v/2,
      "clearstatcache" => &clearstatcache_v/2,
      "vsprintf" => &vsprintf_v/2,
      "array_intersect_key" => &array_intersect_key_v/2,
      "array_diff_key" => &array_diff_key_v/2,
      "array_is_list" => &array_is_list_v/2,
      "array_merge_recursive" => &array_merge_recursive_v/2
    }

    Enum.reduce(entries, fns, fn {name, fun}, acc ->
      Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
    end)
    |> Map.put("is_callable", %{fun: fn v, i, _c -> is_callable_v(v, i) end, refs: [2], skip_eval_refs: [2]})
    |> Map.put("headers_sent", %{fun: fn v, i, _c -> headers_sent_v(v, i) end, refs: [0, 1], skip_eval_refs: [0, 1]})
  end

  defp val(vals, n \\ 0), do: Enum.at(vals, n)
  defp s(vals, n \\ 0), do: val(vals, n) |> Value.cast_string_unsafe()

  defp int(vals, n, d) do
    case val(vals, n) do
      {:int, v} -> v
      {:bool, b} -> if b, do: 1, else: 0
      _ -> d
    end
  end

  ## ───────────────────────── strings ─────────────────────────

  defp ord_v(vals, i) do
    case s(vals) do
      <<c, _::binary>> -> {:ok, {:int, c}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp chr_v(vals, i) do
    case val(vals) do
      {:int, c} when c >= 0 and c < 256 -> {:ok, {:string, <<c>>}, i}
      {:int, c} when c < 0 -> {:ok, {:string, <<rem(c + 256, 256)>>}, i}
      {:int, c} -> {:ok, {:string, <<rem(c, 256)>>}, i}
      _ -> {:ok, {:string, ""}, i}
    end
  end

  defp strstr_v(vals, i) do
    hay = s(vals)
    needle = s(vals, 1)

    cond do
      needle == "" ->
        {:ok, {:bool, false}, i}

      true ->
        case binary_match(down(hay), down(needle)) do
          :nomatch ->
            {:ok, {:bool, false}, i}

          idx ->
            {:ok, {:string, binary_part(hay, idx, byte_size(hay) - idx)}, i}
        end
    end
  end

  defp stristr_v(vals, i), do: strstr_v(vals, i)

  defp stripos_v(vals, i), do: strpos_family(vals, i, true, :first)
  defp strripos_v(vals, i), do: strpos_family(vals, i, true, :last)

  defp strpos_family(vals, i, ci?, dir) do
    hay = s(vals)
    needle = s(vals, 1)
    offset = max(0, int(vals, 2, 0))

    if needle == "" or offset > byte_size(hay) do
      {:ok, {:bool, false}, i}
    else
      subj = binary_part(hay, offset, byte_size(hay) - offset)

      finder = fn h, n -> if ci?, do: binary_match(down(h), down(n)), else: binary_match(h, n) end

      found =
        case dir do
          :first -> finder.(subj, needle)
          :last -> find_last(subj, needle, finder)
        end

      case found do
        :nomatch -> {:ok, {:bool, false}, i}
        idx -> {:ok, {:int, idx + offset}, i}
      end
    end
  end

  defp find_last(subj, needle, finder) do
    case finder.(subj, needle) do
      :nomatch -> :nomatch
      idx -> walk_last(subj, needle, finder, idx + 1, idx)
    end
  end

  defp walk_last(subj, needle, finder, from, best) do
    case finder.(binary_part(subj, from, byte_size(subj) - from), needle) do
      :nomatch -> best
      idx -> walk_last(subj, needle, finder, from + idx + 1, from + idx)
    end
  end

  defp binary_match(h, n) do
    case :binary.match(h, n) do
      {pos, _len} -> pos
      :nomatch -> :nomatch
    end
  end

  defp down(b), do: String.downcase(b)

  defp strnatcmp_v(vals, i), do: nat_cmp(vals, i, false)
  defp strnatcasecmp_v(vals, i), do: nat_cmp(vals, i, true)

  defp nat_cmp(vals, i, ci?) do
    a = s(vals)
    b = s(vals, 1)
    {a2, b2} = if ci?, do: {down(a), down(b)}, else: {a, b}
    {:ok, {:int, compare_chunks(nat_chunks(a2), nat_chunks(b2))}, i}
  end

  defp nat_chunks(""), do: []

  defp nat_chunks(str) do
    <<c, rest::binary>> = str
    digit? = c in ?0..?9
    {chunk, remaining} = take_kind(rest, digit?)
    [{digit?, <<c>> <> chunk} | nat_chunks(remaining)]
  end

  defp take_kind(<<c, rest::binary>>, digit?) do
    if c in ?0..?9 == digit? do
      {more, r} = take_kind(rest, digit?)
      {<<c>> <> more, r}
    else
      {"", <<c, rest::binary>>}
    end
  end

  defp take_kind("", _digit?), do: {"", ""}

  defp compare_chunks([], []), do: 0
  defp compare_chunks([], _), do: -1
  defp compare_chunks(_, []), do: 1

  defp byte_compare(a, b) do
    cond do
      a == b -> :eq
      a < b -> :lt
      true -> :gt
    end
  end

  defp compare_chunks([{true, a} | ra], [{true, b} | rb]) do
    {na, nb} = {String.to_integer(a), String.to_integer(b)}

    if na == nb,
      do: compare_chunks(ra, rb),
      else: if(na < nb, do: -1, else: 1)
  end

  defp compare_chunks([{false, a} | ra], [{false, b} | rb]) do
    case byte_compare(a, b) do
      :eq -> compare_chunks(ra, rb)
      :lt -> -1
      :gt -> 1
    end
  end

  defp compare_chunks([{ta, _} | _], [{tb, _} | _]) when ta != tb,
    do: if(ta, do: -1, else: 1)

  defp strspn_v(vals, i), do: span_fn(vals, i, true)
  defp strcspn_v(vals, i), do: span_fn(vals, i, false)

  defp span_fn(vals, i, in_mask?) do
    subj = s(vals)
    mask = s(vals, 1)
    start = max(0, int(vals, 2, 0))

    len =
      case int(vals, 3, byte_size(subj)) do
        n when n < 0 -> byte_size(subj)
        n -> n
      end

    subj2 =
      binary_part(subj, min(start, byte_size(subj)), max(0, min(len, byte_size(subj) - start)))

    count =
      Enum.reduce_while(String.to_charlist(subj2), 0, fn c, acc ->
        if String.contains?(mask, <<c>>) == in_mask?,
          do: {:cont, acc + 1},
          else: {:halt, acc}
      end)

    {:ok, {:int, count}, i}
  end

  # strtr(str, from, to): byte-wise mapping
  defp strtr_v([subj, {:array, arr} | _], i) do
    pairs =
      arr
      |> PArray.to_pairs()
      |> Enum.map(fn {k, v} -> {raw_str(k), Value.cast_string_unsafe(v)} end)
      |> Enum.sort_by(fn {k, _} -> -byte_size(k) end)

    {:ok, {:string, strtr_pairs(Value.cast_string_unsafe(subj), pairs, "")}, i}
  end

  defp strtr_v(vals, i) do
    subj = s(vals)
    from = s(vals, 1)
    to = s(vals, 2)

    map = Enum.zip(String.to_charlist(from), String.to_charlist(to)) |> Map.new()

    out =
      for <<c <- subj>>, into: "" do
        case Map.get(map, c) do
          nil -> <<c>>
          r -> <<r>>
        end
      end

    {:ok, {:string, out}, i}
  end

  defp raw_str(k) when is_binary(k), do: k
  defp raw_str(k) when is_integer(k), do: Integer.to_string(k)

  defp strtr_pairs("", _pairs, acc), do: acc

  defp strtr_pairs(subj, pairs, acc) do
    case Enum.find(pairs, fn {k, _} -> String.starts_with?(subj, k) end) do
      {k, v} ->
        strtr_pairs(
          binary_part(subj, byte_size(k), byte_size(subj) - byte_size(k)),
          pairs,
          acc <> v
        )

      _ ->
        strtr_pairs(
          binary_part(subj, 1, byte_size(subj) - 1),
          pairs,
          acc <> binary_part(subj, 0, 1)
        )
    end
  end

  defp substr_replace_v(vals, i) do
    repl = s(vals, 1)
    from = int(vals, 2, 0)

    len =
      case val(vals, 3) do
        {:int, n} -> n
        _ -> 1_000_000_000
      end

    case val(vals) do
      {:array, arr} ->
        out =
          arr
          |> PArray.values()
          |> Enum.map(fn v ->
            {:string, substr_replace_one(Value.cast_string_unsafe(v), repl, from, len)}
          end)

        {:ok, {:array, PArray.from_pairs(Enum.map(out, &{nil, &1}))}, i}

      v ->
        {:ok, {:string, substr_replace_one(Value.cast_string_unsafe(v), repl, from, len)}, i}
    end
  end

  defp substr_replace_one(str, repl, from, len) do
    size = byte_size(str)
    start = if from < 0, do: max(0, size + from), else: min(from, size)

    stop =
      cond do
        len < 0 -> max(start, size + len)
        true -> min(size, start + len)
      end

    binary_part(str, 0, start) <>
      repl <>
      binary_part(str, stop, max(0, size - stop))
  end

  defp substr_compare_v(vals, i) do
    a = s(vals)
    b = s(vals, 1)
    offset = int(vals, 2, 0)
    len = int(vals, 3, byte_size(a) - offset)
    ci? = int(vals, 4, 0) != 0

    if offset > byte_size(a) do
      {:ok, {:bool, false}, i}
    else
      a2 = binary_part(a, offset, byte_size(a) - offset)
      len2 = if len < 0, do: byte_size(a2), else: min(len, max(byte_size(a2), byte_size(b)))
      a3 = binary_part(a2, 0, min(len2, byte_size(a2)))
      b3 = binary_part(b, 0, min(len2, byte_size(b)))

      {x, y} = if ci?, do: {down(a3), down(b3)}, else: {a3, b3}

      result =
        cond do
          x < y -> -1
          x > y -> 1
          true -> 0
        end

      {:ok, {:int, result}, i}
    end
  end

  @special_rank %{
    "dev" => -6,
    "alpha" => -5,
    "a" => -5,
    "beta" => -4,
    "b" => -4,
    "rc" => -3,
    "#" => -2,
    "pl" => -2,
    "p" => -2
  }

  defp version_compare_v(vals, i) do
    a = s(vals)
    b = s(vals, 1)

    split = fn v ->
      v
      |> String.replace(["_", "+", "-"], ".")
      |> String.split(".", trim: true)
      |> Enum.map(fn part ->
        case Integer.parse(part) do
          {n, ""} -> {:num, n}
          _ -> {:special, Map.get(@special_rank, down(part), -1)}
        end
      end)
    end

    pa = split.(a)
    pb = split.(b)
    n = max(length(pa), length(pb))
    pad = fn list -> list ++ List.duplicate(:missing, n - length(list)) end

    result =
      Enum.zip(pad.(pa), pad.(pb))
      |> Enum.reduce_while(0, fn
        {x, x}, _ ->
          {:cont, 0}

        {x, y}, _ ->
          {:halt, if(rank(x) < rank(y), do: -1, else: 1)}
      end)

    case val(vals, 2) do
      {:string, op} ->
        {:ok, {:bool, apply_op(normalize_op(op), result)}, i}

      _ ->
        {:ok, {:int, result}, i}
    end
  end

  defp normalize_op("lt"), do: "<"
  defp normalize_op("le"), do: "<="
  defp normalize_op("gt"), do: ">"
  defp normalize_op("ge"), do: ">="
  defp normalize_op("eq"), do: "=="
  defp normalize_op("="), do: "=="
  defp normalize_op("ne"), do: "!="
  defp normalize_op("<>"), do: "!="

  defp normalize_op(op) when op in ["<", "<=", ">", ">=", "==", "!="], do: op
  defp normalize_op(_), do: nil

  defp apply_op(nil, _), do: false
  defp apply_op("<", r), do: r == -1
  defp apply_op("<=", r), do: r <= 0
  defp apply_op(">", r), do: r == 1
  defp apply_op(">=", r), do: r >= 0
  defp apply_op("==", r), do: r == 0
  defp apply_op("!=", r), do: r != 0

  defp rank(:missing), do: {-1, 1}
  defp rank({:num, n}), do: {0, n}
  defp rank({:special, r}), do: {-1, r}

  ## ───────────────────────── codecs ─────────────────────────

  defp bin2hex_v(vals, i), do: {:ok, {:string, Base.encode16(s(vals), case: :lower)}, i}

  defp hex2bin_v(vals, i) do
    case Base.decode16(s(vals), case: :mixed) do
      {:ok, b} -> {:ok, {:string, b}, i}
      :error -> {:ok, {:bool, false}, i}
    end
  end

  defp base64_encode_v(vals, i), do: {:ok, {:string, Base.encode64(s(vals))}, i}

  defp base64_decode_v(vals, i) do
    strict? = int(vals, 1, 0) != 0

    case Base.decode64(s(vals)) do
      {:ok, b} -> {:ok, {:string, b}, i}
      :error -> if strict?, do: {:ok, {:bool, false}, i}, else: {:ok, {:string, ""}, i}
    end
  end

  defp urlencode_v(vals, i), do: {:ok, {:string, URI.encode_www_form(s(vals))}, i}
  defp urldecode_v(vals, i), do: {:ok, {:string, URI.decode_www_form(s(vals))}, i}

  defp rawurlencode_v(vals, i),
    do: {:ok, {:string, URI.encode(s(vals), &URI.char_unreserved?/1)}, i}

  defp rawurldecode_v(vals, i), do: {:ok, {:string, URI.decode(s(vals))}, i}

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => ~s("),
    "apos" => "'",
    "nbsp" => <<194, 160>>,
    "copy" => "©",
    "reg" => "®",
    "trade" => "™",
    "hellip" => "…",
    "mdash" => "—",
    "ndash" => "–",
    "lsquo" => "‘",
    "rsquo" => "’",
    "ldquo" => "“",
    "rdquo" => "”",
    "laquo" => "«",
    "raquo" => "»",
    "euro" => "€",
    "pound" => "£",
    "yen" => "¥",
    "cent" => "¢",
    "sect" => "§",
    "para" => "¶",
    "middot" => "·",
    "bull" => "•",
    "dagger" => "†",
    "permil" => "‰",
    "larr" => "←",
    "uarr" => "↑",
    "rarr" => "→",
    "darr" => "↓",
    "harr" => "↔",
    "times" => "×",
    "divide" => "÷",
    "plusmn" => "±",
    "deg" => "°",
    "frac14" => "¼",
    "frac12" => "½",
    "frac34" => "¾",
    "iquest" => "¿",
    "iexcl" => "¡",
    "szlig" => "ß"
  }

  defp html_entity_decode_v(vals, i) do
    out =
      Regex.replace(~r/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/, s(vals), fn
        full, "#" <> dec ->
          case Integer.parse(dec) do
            {cp, ""} -> <<cp::utf8>>
            _ -> full
          end

        full, "#" <> hex ->
          case Integer.parse(
                 hex |> String.replace_leading("#x", "") |> String.replace_leading("#X", ""),
                 16
               ) do
            {cp, ""} -> <<cp::utf8>>
            _ -> full
          end

        full, name ->
          Map.get(@entities, down(name), full)
      end)

    {:ok, {:string, out}, i}
  end

  defp escapeshellarg_v(vals, i) do
    str = s(vals) |> String.replace("'", "'\\''")
    {:ok, {:string, "'" <> str <> "'"}, i}
  end

  defp uniqid_v(vals, i) do
    prefix = s(vals)

    base =
      System.system_time(:microsecond)
      |> rem(0xF_FFFF_FFFF_FFFF)
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(13, "0")
      |> binary_part(0, 13)

    {:ok, {:string, prefix <> base}, i}
  end

  @url_re ~r/^(?:([a-zA-Z][a-zA-Z0-9+.-]*):\/\/|\/\/)?(?:([^:@\/]*)(?::([^@\/]*))?@)?([^:\/?#]*)(?::(\d+))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/

  defp parse_url_v(vals, i) do
    url = s(vals)

    case Regex.run(@url_re, url) do
      nil ->
        {:ok, {:bool, false}, i}

      [_ | caps_raw] ->
        # trailing unmatched groups are truncated by :re — pad with nil
        caps = caps_raw ++ List.duplicate(nil, max(0, 8 - length(caps_raw)))
        [scheme, user, pass, host, port, path, query, fragment] = caps

        parts = [
          {"scheme", str_part(scheme)},
          {"host", str_part(host)},
          {"port", port_part(port)},
          {"user", str_part(user)},
          {"pass", str_part(pass)},
          {"path", str_part(path)},
          {"query", str_part(query)},
          {"fragment", str_part(fragment)}
        ]

        case val(vals, 1) do
          {:int, n} when n in 0..7 ->
            key = Enum.at(~w(scheme host port user pass path query fragment), n)
            found = List.keyfind(parts, key, 0)
            v = if(found, do: elem(found, 1), else: :null)
            {:ok, v || :null, i}

          _ ->
            {:ok,
             {:array,
              PArray.from_pairs(
                for {k, v} <- parts, v != nil do
                  {{:string, k}, v}
                end
              )}, i}
        end
    end
  end

  # unmatched groups come back as nil; "" counts as absent like php
  defp str_part(nil), do: nil
  defp str_part(""), do: nil
  defp str_part(x), do: {:string, x}

  defp port_part(nil), do: nil
  defp port_part(""), do: nil
  defp port_part(x), do: {:int, String.to_integer(x)}

  ## ───────────────────────── paths ─────────────────────────

  defp dirname_v(vals, i) do
    levels = max(1, int(vals, 1, 1))
    p = s(vals)

    out = Enum.reduce(1..levels, p, fn _, acc -> Path.dirname(acc) end)
    {:ok, {:string, out}, i}
  end

  defp basename_v(vals, i) do
    suffix = s(vals, 1)
    base = Path.basename(s(vals))

    base =
      if suffix != "" and String.ends_with?(base, suffix) and base != suffix,
        do: binary_part(base, 0, byte_size(base) - byte_size(suffix)),
        else: base

    {:ok, {:string, base}, i}
  end

  defp pathinfo_v(vals, i) do
    p = s(vals)

    info = [
      {"dirname", Path.dirname(p)},
      {"basename", Path.basename(p)},
      {"extension", path_ext(p)},
      {"filename", path_filename(p)}
    ]

    case val(vals, 1) do
      {:int, n} when n in 1..4 ->
        key = %{1 => "dirname", 2 => "basename", 3 => "filename", 4 => "extension"}
        name = Map.get(key, n)
        found = List.keyfind(info, name, 0)
        {:ok, {:string, if(found, do: elem(found, 1), else: "")}, i}

      _ ->
        {:ok,
         {:array,
          PArray.from_pairs(Enum.map(info, fn {k, v} -> {{:string, k}, {:string, v}} end))}, i}
    end
  end

  defp path_ext(p) do
    case Path.extname(p) do
      "." <> ext -> ext
      _ -> ""
    end
  end

  defp path_filename(p) do
    base = Path.basename(p)
    ext = Path.extname(p)
    binary_part(base, 0, byte_size(base) - byte_size(ext))
  end

  ## ───────────────────────── digests ─────────────────────────

  defp md5_v(vals, i), do: digest(:md5, vals, i)
  defp sha1_v(vals, i), do: digest(:sha, vals, i)

  # hash('sha256', data, raw?) / hash_hmac — the WP salt machinery's core
  defp hash_v(vals, i) do
    algo = down(s(vals))
    raw? = int(vals, 2, 0) != 0

    with {:ok, kind} <- hash_algo(algo) do
      bin = :crypto.hash(kind, s(vals, 1))
      {:ok, {:string, if(raw?, do: bin, else: Base.encode16(bin, case: :lower))}, i}
    else
      _ -> {:ok, {:bool, false}, warn(i, "hash(): Unknown hashing algorithm: #{algo}")}
    end
  end

  defp hash_algo("md5"), do: {:ok, :md5}
  defp hash_algo("sha1"), do: {:ok, :sha}
  defp hash_algo("sha256"), do: {:ok, :sha256}
  defp hash_algo("sha384"), do: {:ok, :sha384}
  defp hash_algo("sha512"), do: {:ok, :sha512}
  defp hash_algo(_), do: :error

  defp hash_hmac_v(vals, i) do
    algo = down(s(vals))
    raw? = int(vals, 3, 0) != 0

    with {:ok, kind} <- hash_algo(algo) do
      bin = :crypto.mac(:hmac, kind, s(vals, 2), s(vals, 1))
      {:ok, {:string, if(raw?, do: bin, else: Base.encode16(bin, case: :lower))}, i}
    else
      _ -> {:ok, {:bool, false}, warn(i, "hash_hmac(): Unknown hashing algorithm: #{algo}")}
    end
  end

  defp hash_equals_v(vals, i) do
    a = s(vals)
    b = s(vals, 1)
    # constant-time in php; plain comparison preserves observable behavior
    {:ok, {:bool, byte_size(a) == byte_size(b) and a == b}, i}
  end

  defp hash_algos_v(_vals, i) do
    algos = ~w(md5 sha1 sha256 sha384 sha512)
    {:ok, {:array, PArray.from_pairs(Enum.map(algos, &{nil, {:string, &1}}))}, i}
  end

  defp crc32b_v(vals, i), do: crc32_v(vals, i)

  defp warn(i, msg), do: PhpBeam.Interp.warn(i, msg)

  defp digest(kind, vals, i) do
    raw? = int(vals, 1, 0) != 0
    bin = :crypto.hash(kind, s(vals))
    out = if raw?, do: bin, else: Base.encode16(bin, case: :lower)
    {:ok, {:string, out}, i}
  end

  defp crc32_v(vals, i), do: {:ok, {:int, :erlang.crc32(s(vals))}, i}

  ## ───────────────────── var / class checks ─────────────────────

  defp is_resource_v(_vals, i), do: {:ok, {:bool, false}, i}

  defp is_callable_v(vals, i) do
    ok? = callable?(val(vals), i)
    name = if ok?, do: callable_name(val(vals)), else: ""
    # &$name is argument 2
    {:ref_call, {:bool, ok?}, [nil, nil, {:string, name}], i}
  end

  defp callable_name({:string, n}), do: n
  defp callable_name({:closure, _, _, _, _, _}), do: "Closure"
  defp callable_name({:array, _}), do: ""
  defp callable_name(_), do: ""

  defp callable?({:closure, _, _, _, _, _}, _i), do: true

  defp callable?({:string, name}, i),
    do: Map.has_key?(i.functions, down(name))

  defp callable?({:array, arr}, i) do
    case PArray.values(arr) do
      [{:object, id}, {:string, m}] ->
        obj = Map.get(i.objects, id) || %{class: ""}
        PhpBeam.Classes.find_method(i, obj.class, m) != nil

      [{:string, c}, {:string, m}] ->
        PhpBeam.Classes.find_method(i, down(c), m) != nil

      _ ->
        false
    end
  end

  defp callable?(_, _i), do: false

  defp is_a_v(vals, i) do
    case val(vals) do
      {:object, id} ->
        obj = Map.get(i.objects, id) || %{class: ""}
        cls = down(s(vals, 1))
        {:ok, {:bool, down(obj.class) == cls or subclass?(obj.class, cls, i)}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp is_subclass_of_v(vals, i) do
    subject =
      case val(vals) do
        {:string, c} -> down(c)
        {:object, id} -> down((Map.get(i.objects, id) || %{class: ""}).class)
        _ -> ""
      end

    parent = down(s(vals, 1))
    {:ok, {:bool, subject != parent and subclass?(subject, parent, i)}, i}
  end

  defp subclass?(key, cls, i) do
    Stream.unfold(key, fn k ->
      case i.classes[k] do
        %{parent: p} when p != nil -> {p, p}
        _ -> nil
      end
    end)
    |> Enum.any?(&(&1 == down(cls)))
  end

  @known_exts ~w(core date pcre spl standard json session filter hash iconv mbstring
                  xml openssl curl dom simplexml xmlreader xmlwriter fileinfo ctype
                  posix pdo mysqli mysqlnd reflection zlib sqlite3 pdo_sqlite phar sodium)

  defp extension_loaded_v(vals, i), do: {:ok, {:bool, down(s(vals)) in @known_exts}, i}

  defp getenv_v(vals, i) do
    case System.get_env(s(vals)) do
      nil -> {:ok, {:bool, false}, i}
      v -> {:ok, {:string, v}, i}
    end
  end

  defp json_last_error_v(_vals, i), do: {:ok, {:int, 0}, i}
  defp json_last_error_msg_v(_vals, i), do: {:ok, {:string, "No error"}, i}

  @user_error_deprecated "Passing E_USER_ERROR to trigger_error() is deprecated since 8.4, throw an exception or call exit with a string message instead"

  defp trigger_error_v(vals, i) do
    msg = s(vals)
    level = int(vals, 1, 1024)

    case level do
      256 ->
        i2 = PhpBeam.Interp.warn_level(i, "Deprecated", @user_error_deprecated)
        {:unwind, {:engine_fatal, msg}, i2}

      512 ->
        {:ok, :null, PhpBeam.Interp.warn_level(i, "Warning", msg)}

      16_384 ->
        {:ok, :null, PhpBeam.Interp.warn_level(i, "Deprecated", msg)}

      _ ->
        {:ok, :null, PhpBeam.Interp.warn_level(i, "Notice", msg)}
    end
  end

  defp assert_v(vals, i) do
    desc =
      case val(vals, 1) do
        {:string, d} -> d
        _ -> "assertion failed"
      end

    if Value.truthy?(val(vals)) do
      {:ok, {:bool, true}, i}
    else
      {:unwind, {:php_throw, {:native_error, "AssertionError", desc}}, i}
    end
  end

  ## ───────────────────── runtime no-ops ─────────────────────

  defp header_v(_vals, i) do
    case i.output_origin do
      {file, line} when file != nil ->
        i2 =
          PhpBeam.Interp.warn(
            i,
            "Cannot modify header information - headers already sent by (output started at #{file}:#{line})"
          )

        {:ok, :null, i2}

      _ ->
        {:ok, :null, i}
    end
  end

  defp setcookie_v(_vals, i), do: {:ok, {:bool, true}, i}

  defp headers_sent_v(_vals, i),
    do: {:ref_call, {:bool, false}, [{:string, ""}, {:int, 0}], i}

  defp error_log_v(vals, i) do
    msg = String.replace_trailing(s(vals), "\n", "")

    case int(vals, 1, 0) do
      3 ->
        path = s(vals, 2)
        File.write(path, msg <> "\n", [:append])
        {:ok, {:bool, true}, i}

      _ ->
        IO.puts(:stderr, msg)
        {:ok, {:bool, true}, i}
    end
  end

  defp http_build_query_v(vals, i) do
    rfc3986? = int(vals, 2, 1_738) == 3_986
    {:ok, {:string, build_query(val(vals), "", rfc3986?)}, i}
  end

  # prefix/keys stay RAW here; the whole key is encoded once in query_part
  defp build_query({:array, arr}, prefix, rfc?) do
    arr
    |> PArray.to_pairs()
    |> Enum.map_join("&", fn {k, v} ->
      key = raw_str(k)
      full_key = if prefix == "", do: key, else: prefix <> "[" <> key <> "]"
      query_part(v, full_key, rfc?)
    end)
  end

  defp query_part({:array, arr}, key, rfc?),
    do: build_query({:array, arr}, key, rfc?)

  defp query_part(v, key, rfc?),
    do: qenc(key, rfc?) <> "=" <> qenc(Value.cast_string_unsafe(v), rfc?)

  defp qenc(str, true), do: URI.encode(str, &URI.char_unreserved?/1)
  defp qenc(str, false), do: URI.encode_www_form(str)

  ## ───────────────────────── files ─────────────────────────

  defp glob_v(vals, i) do
    files = s(vals) |> Path.wildcard() |> Enum.sort()
    {:ok, {:array, PArray.from_pairs(Enum.map(files, &{nil, {:string, &1}}))}, i}
  end

  defp file_v(vals, i) do
    flags = int(vals, 1, 0)

    case File.read(s(vals)) do
      {:ok, content} ->
        keep_nl? = Bitwise.band(flags, 2) == 0
        skip_empty? = Bitwise.band(flags, 4) != 0

        lines =
          content
          |> String.split("\n")
          |> Enum.drop(-1)
          |> Enum.reject(&(&1 == "" and skip_empty?))
          |> Enum.map(fn l -> if keep_nl?, do: l <> "\n", else: l end)

        {:ok, {:array, PArray.from_pairs(Enum.map(lines, &{nil, {:string, &1}}))}, i}

      {:error, _} ->
        {:ok, {:bool, false}, i}
    end
  end

  defp filemtime_v(vals, i) do
    case File.stat(s(vals)) do
      {:ok, %{mtime: dt}} ->
        secs = :calendar.datetime_to_gregorian_seconds(dt) - 62_167_219_200
        {:ok, {:int, secs}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp chmod_v(vals, i) do
    mode =
      case val(vals, 1) do
        {:int, m} -> m
        _ -> 0o644
      end

    case :file.change_mode(String.to_charlist(s(vals)), mode) do
      :ok -> {:ok, {:bool, true}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp chdir_v(vals, i) do
    case File.cd(s(vals)) do
      :ok -> {:ok, {:bool, true}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp clearstatcache_v(_vals, i), do: {:ok, :null, i}

  defp vsprintf_v(vals, i) do
    case val(vals, 1) do
      {:array, arr} ->
        PhpBeam.Builtin.registry()["sprintf"].fun.([val(vals) | PArray.values(arr)], i, %{})

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  ## ───────────────────────── arrays (pure) ─────────────────────────

  defp array_intersect_key_v(vals, i) do
    with [{:array, a} | rest] <- vals do
      other_keys =
        rest
        |> Enum.flat_map(fn
          {:array, b} -> b |> PArray.to_pairs() |> Enum.map(&elem(&1, 0))
          _ -> []
        end)
        |> MapSet.new()

      kept =
        PArray.to_pairs(a)
        |> Enum.filter(fn {k, _} -> MapSet.member?(other_keys, k) end)
        |> Enum.map(fn {k, v} -> {wrap(k), v} end)

      {:ok, {:array, PArray.from_pairs(kept)}, i}
    else
      _ -> {:ok, {:array, PArray.new()}, i}
    end
  end

  defp array_diff_key_v(vals, i) do
    with [{:array, a} | rest] <- vals do
      other_keys =
        rest
        |> Enum.flat_map(fn
          {:array, b} -> b |> PArray.to_pairs() |> Enum.map(&elem(&1, 0))
          _ -> []
        end)
        |> MapSet.new()

      kept =
        PArray.to_pairs(a)
        |> Enum.reject(fn {k, _} -> MapSet.member?(other_keys, k) end)
        |> Enum.map(fn {k, v} -> {wrap(k), v} end)

      {:ok, {:array, PArray.from_pairs(kept)}, i}
    else
      _ -> {:ok, {:array, PArray.new()}, i}
    end
  end

  defp wrap(k) when is_integer(k), do: {:int, k}
  defp wrap(k) when is_binary(k), do: {:string, k}

  defp array_is_list_v([{:array, arr} | _], i) do
    keys = arr |> PArray.to_pairs() |> Enum.map(&elem(&1, 0))
    {:ok, {:bool, keys == Enum.to_list(0..(length(keys) - 1)//1)}, i}
  end

  defp array_is_list_v(_, i), do: {:ok, {:bool, false}, i}

  defp array_merge_recursive_v(vals, i) do
    arrays = Enum.filter(vals, &match?({:array, _}, &1))

    merged =
      Enum.reduce(arrays, PArray.new(), fn {:array, b}, acc ->
        b
        |> PArray.to_pairs()
        |> Enum.reduce(acc, fn {k, v}, acc2 ->
          case PArray.fetch(acc2, k) do
            {:ok, {:array, inner_a}} when is_list(k) == false and is_map(inner_a) ->
              # both sides arrays → recursive merge
              case v do
                {:array, inner_b} ->
                  {:ok, merged_inner} = merge_inner(inner_a, inner_b)
                  {:ok, acc3} = PArray.put(acc2, k, {:array, merged_inner})
                  acc3

                _ ->
                  append_value(acc2, k, v)
              end

            {:ok, _existing} ->
              append_value(acc2, k, v)

            :error ->
              {:ok, acc3} = PArray.put(acc2, k, v)
              acc3
          end
        end)
      end)

    {:ok, {:array, merged}, i}
  end

  defp merge_inner(a, b) do
    {:ok,
     Enum.reduce(PArray.to_pairs(b), a, fn {k, v}, acc ->
       case PArray.fetch(acc, k) do
         {:ok, {:array, ia}} ->
           case v do
             {:array, ib} ->
               {:ok, m} = merge_inner(ia, ib)
               {:ok, acc2} = PArray.put(acc, k, {:array, m})
               acc2

             _ ->
               append_value(acc, k, v)
           end

         _ ->
           append_value(acc, k, v)
       end
     end)}
  end

  defp append_value(arr, k, v) do
    # numeric keys renumber; string keys become [orig, new] arrays
    if is_integer(k) do
      {:ok, arr2} = PArray.push(arr, v)
      arr2
    else
      case PArray.fetch(arr, k) do
        {:ok, {:array, _} = existing} ->
          {:ok, arr2} = PArray.push(existing, v)
          {:ok, arr3} = PArray.put(arr, k, arr2)
          arr3

        {:ok, existing} ->
          list = PArray.from_pairs([{nil, existing}, {nil, v}])
          {:ok, arr3} = PArray.put(arr, k, {:array, list})
          arr3

        :error ->
          {:ok, arr2} = PArray.put(arr, k, v)
          arr2
      end
    end
  end
end
