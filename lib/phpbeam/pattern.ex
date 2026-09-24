defmodule PhpBeam.Pattern do
  @moduledoc """
  PHP preg_* on top of PCRE (:re.compile/:re.run — Erlang's regex IS PCRE).

  Owns `/pattern/flags` parsing (any non-alphanumeric delimiter, paired for
  `{} () [] <>`), modifier translation, named-group index extraction, and
  `$matches` array construction (numeric groups, named string keys next to
  their index, OFFSET_CAPTURE `["str", off]` pairs, UNMATCHED_AS_NULL).
  """

  alias PhpBeam.PArray

  @mod_map %{
    "i" => :caseless,
    "m" => :multiline,
    "s" => :dotall,
    "x" => :extended,
    "U" => :ungreedy,
    "u" => :unicode,
    "A" => :anchored,
    "D" => :dollar_endonly,
    "J" => :dupnames,
    "n" => :no_auto_capture
  }

  @pairs %{?{ => ?}, ?( => ?), ?[ => ?], ?< => ?>}
  @offset_capture 256
  @unmatched_as_null 512

  defstruct [:re, :ngroups, :names, :source]

  @doc "Compile `/pat/flags` → `{:ok, %__MODULE__{}}` | `{:error, php_style_msg}`."
  def parse(<<d, rest::binary>> = pattern) do
    cond do
      d in ?a..?z or d in ?A..?Z or d in ?0..?9 or d == ?\\ or d == ?\s ->
        {:error, "Delimiter must not be alphanumeric or backslash"}

      true ->
        close = Map.get(@pairs, d, d)

        case split_body(rest, d, close, "") do
          {:ok, body, flags} -> build(body, flags, pattern)
          :error -> {:error, "No ending delimiter '#{<<close>>}' found"}
        end
    end
  end

  def parse(_), do: {:error, "Empty regular expression"}

  defp split_body("", _d, _close, _acc), do: :error

  defp split_body(<<c, rest::binary>>, d, close, acc) do
    open? = <<c>> == <<d>> and Map.has_key?(@pairs, d) and not escaped?(acc)

    if <<c>> == <<close>> and not escaped?(acc) and not open? do
      {:ok, acc, rest}
    else
      split_body(rest, d, close, acc <> <<c>>)
    end
  end

  defp escaped?(acc), do: byte_size(acc) > 0 and binary_part(acc, byte_size(acc) - 1, 1) == "\\"

  defp build(body, flags, source) do
    with {:ok, opts} <- translate_modifiers(flags),
         {:ok, {:re_pattern, n, _, _, _} = re} <- compile(body, opts) do
      {:ok, %__MODULE__{re: re, ngroups: n, names: scan_names(body), source: source}}
    end
  end

  defp translate_modifiers(flags) do
    flags
    |> String.graphemes()
    |> Enum.reduce_while({:ok, []}, fn f, {:ok, acc} ->
      case Map.fetch(@mod_map, f) do
        {:ok, opt} -> {:cont, {:ok, [opt | acc]}}
        :error -> {:halt, {:error, "Unknown modifier '#{f}'"}}
      end
    end)
    |> case do
      {:ok, opts} -> {:ok, Enum.reverse(opts)}
      error -> error
    end
  end

  defp compile(body, opts) do
    case :re.compile(body, opts) do
      {:ok, _} = ok -> ok
      {:error, {msg, pos}} -> {:error, "Compilation failed: #{msg} at offset #{pos}"}
      {:error, msg} -> {:error, "Compilation failed: #{msg}"}
    end
  end

  # ───────────────────────── execution ─────────────────────────

  @doc """
  One :re.run at `offset` → `{:ok, [{start, len}...] padded, next_offset}` |
  `:nomatch` | `{:error, msg}`. Groups list is full + all groups (padded
  with {-1, 0} for trailing unmatched).
  """
  def run_at(%__MODULE__{re: re, ngroups: n}, subject, offset) do
    # :re.run errors with :internal_error when the offset exceeds the subject
    cond do
      offset > byte_size(subject) ->
        :nomatch

      offset < 0 ->
        :nomatch

      true ->
        run_at_guarded(re, n, subject, offset)
    end
  end

  defp run_at_guarded(re, n, subject, offset) do
    case :re.run(subject, re, [{:capture, :all, :index}, {:offset, offset}]) do
      {:match, idx_pairs} ->
        padded = pad_groups(idx_pairs, n + 1)
        {s, l} = hd(padded)
        next_off = if l == 0, do: s + 1, else: s + l
        {:ok, padded, next_off}

      :nomatch ->
        :nomatch

      {:error, msg} ->
        {:error, "Internal error (#{inspect(msg)})"}
    end
  end

  defp pad_groups(pairs, wanted) when length(pairs) >= wanted, do: pairs
  defp pad_groups(pairs, wanted), do: pairs ++ List.duplicate({-1, 0}, wanted - length(pairs))

  @doc "All matches (padded group lists) from `offset`."
  def scan_all(%__MODULE__{} = pat, subject, offset) do
    case run_at(pat, subject, offset) do
      {:ok, pairs, next} when next <= byte_size(subject) ->
        case scan_all(pat, subject, next) do
          {:ok, rest} -> {:ok, [pairs | rest]}
          :nomatch -> {:ok, [pairs]}
        end

      {:ok, pairs, _next} ->
        {:ok, [pairs]}

      :nomatch ->
        :nomatch

      {:error, _} = e ->
        e
    end
  end

  # ───────────────────────── $matches building ─────────────────────────

  @doc "One match row: trailing unmatched groups trimmed (php), named string keys BEFORE their numeric index."
  def row(pairs, %__MODULE__{names: names} = pat, subject, flags) do
    offset? = Bitwise.band(flags, @offset_capture) != 0
    null? = Bitwise.band(flags, @unmatched_as_null) != 0
    name_by_index = Map.new(names, fn {idx, n} -> {idx, n} end)

    trimmed = trim_trailing_unmatched(pairs)

    trimmed
    |> Enum.with_index()
    |> Enum.reduce([], fn {{s, l}, idx}, acc ->
      entry = capture_value(subject, s, l, offset?, null? and idx > 0)

      acc =
        case Map.get(name_by_index, idx) do
          nil -> acc
          name -> acc ++ [{{:string, name}, entry}]
        end

      acc ++ [{pair_key(idx), entry}]
    end)
    |> PArray.from_pairs()
  end

  defp trim_trailing_unmatched([{0, _} = full]), do: [full]

  defp trim_trailing_unmatched([{s, l} | rest] = pairs) do
    if s < 0 do
      trim_trailing_unmatched(Enum.drop(pairs, -1))
    else
      [{s, l} | trim_trailing_unmatched(rest)]
    end
  end

  defp trim_trailing_unmatched([]), do: []

  defp pair_key(0), do: {:int, 0}
  defp pair_key(i), do: {:int, i}

  defp capture_value(_subject, -1, _l, false = _off?, true = _null?), do: :null
  defp capture_value(_subject, -1, _l, true = _off?, _null?), do: offset_cell("", 0)

  defp capture_value(_subject, -1, _l, _off?, _null?), do: {:string, ""}

  defp capture_value(subject, s, l, false = _off?, _null?),
    do: {:string, binary_part(subject, s, l)}

  defp capture_value(subject, s, l, true = _off?, _null?),
    do: offset_cell(binary_part(subject, s, l), s)

  defp offset_cell(str, off),
    do: {:array, PArray.from_pairs([{nil, {:string, str}}, {nil, {:int, off}}])}

  @doc "Plain capture binary at index i (0 = full) from a padded pair list."
  def capture_bin(subject, pairs, i) do
    case Enum.at(pairs, i) do
      {s, l} when s >= 0 -> binary_part(subject, s, l)
      _ -> ""
    end
  end

  @doc "Byte span {start, length} of entry i."
  def span(pairs, i), do: Enum.at(pairs, i) || {-1, 0}

  # ─────────────────── named-group index scanning ───────────────────
  # walks the pattern body counting capturing groups; recognizes the
  # common markers (?<name> (?'name' (?P<name> and the non-capturing (?:
  # (?= (?! (?<= (?<! (?# (?| (?P= (?P> forms; skips [...] classes

  def scan_names(body), do: do_scan_names(body, 0, [])

  defp do_scan_names("", _idx, names), do: Enum.reverse(names)

  defp do_scan_names(<<?\\, _x, rest::binary>>, idx, names), do: do_scan_names(rest, idx, names)

  defp do_scan_names(<<?[, rest::binary>>, idx, names), do: skip_class(rest, idx, names)

  defp do_scan_names("(?<=" <> rest, idx, names), do: do_scan_names(rest, idx, names)
  defp do_scan_names("(?<!" <> rest, idx, names), do: do_scan_names(rest, idx, names)
  defp do_scan_names("(?<" <> rest, idx, names), do: take_name(rest, ">", idx + 1, names)
  defp do_scan_names("(?'" <> rest, idx, names), do: take_name(rest, "'", idx + 1, names)
  defp do_scan_names("(?P<" <> rest, idx, names), do: take_name(rest, ">", idx + 1, names)
  defp do_scan_names("(?P=" <> rest, idx, names), do: do_scan_names(rest, idx, names)
  defp do_scan_names("(?P>" <> rest, idx, names), do: do_scan_names(rest, idx, names)

  defp do_scan_names("(?#" <> rest, idx, names), do: skip_comment(rest, idx, names)

  for pre <- ["?:", "?=", "?!", "?|", "?+", "?-", "?&"] do
    defp do_scan_names(unquote("(?") <> unquote(pre) <> rest, idx, names),
      do: do_scan_names(rest, idx, names)
  end

  defp do_scan_names("(" <> rest, idx, names), do: do_scan_names(rest, idx + 1, names)
  defp do_scan_names(<<_c, rest::binary>>, idx, names), do: do_scan_names(rest, idx, names)

  defp skip_class(<<>>, idx, names), do: do_scan_names("", idx, names)

  defp skip_class(<<?\\, _x, rest::binary>>, idx, names), do: skip_class(rest, idx, names)
  defp skip_class(<<?], rest::binary>>, idx, names), do: do_scan_names(rest, idx, names)
  defp skip_class(<<_c, rest::binary>>, idx, names), do: skip_class(rest, idx, names)

  defp skip_comment(<<?), rest::binary>>, idx, names), do: do_scan_names(rest, idx, names)
  defp skip_comment(<<_c, rest::binary>>, idx, names), do: skip_comment(rest, idx, names)
  defp skip_comment(<<>>, idx, names), do: do_scan_names("", idx, names)

  defp take_name(rest, closer, idx, names) do
    case :binary.split(rest, closer) do
      [name, rest2] when name != "" ->
        scan_and_keep(rest2, idx, [{idx, name} | names])

      _ ->
        do_scan_names("", idx, names)
    end
  end

  defp scan_and_keep(rest, idx, names) do
    rest
    |> do_scan_names(idx, names)
    |> Enum.reverse()
    |> Enum.map(fn
      {i, n} when is_integer(i) -> {i, n}
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
  end
end
