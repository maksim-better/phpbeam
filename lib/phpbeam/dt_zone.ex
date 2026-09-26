defmodule PhpBeam.DtZone do
  @moduledoc """
  Named timezones backed by the system TZif database (/usr/share/zoneinfo,
  macOS/Ubuntu paths probed). Parses the V2 block (64-bit transition
  times) and answers offset/abbreviation queries for any instant,
  DST-aware — the honest source php itself uses (timelib reads the same
  files).

  Zone resolution is cached in :persistent_term (a run touches a handful
  of zones; parse cost is ~µs after the first hit).
  """

  @zone_roots ["/usr/share/zoneinfo", "/usr/lib/zoneinfo", "/etc/zoneinfo"]

  defmodule Zone do
    @enforce_keys [:name]
    defstruct [:name, transitions: [], offsets: [], abbrs: %{}]
  end

  def valid?("UTC"), do: true
  def valid?("GMT"), do: true

  def valid?(name) when is_binary(name) do
    case resolve(name) do
      {:ok, _z} -> true
      _ -> false
    end
  end

  def valid?(_), do: false

  @doc "resolve a zone name (UTC/GMT aliases included) → {:ok, zone}"
  def resolve("UTC"), do: {:ok, %Zone{name: "UTC"}}

  def resolve("GMT"), do: {:ok, %Zone{name: "UTC"}}

  def resolve(name) when is_binary(name) do
    case :persistent_term.get({__MODULE__, name}, :none) do
      %Zone{} = z ->
        {:ok, z}

      :error ->
        :error

      :none ->
        case load(name) do
          {:ok, z} ->
            :persistent_term.put({__MODULE__, name}, z)
            {:ok, z}

          :error ->
            :persistent_term.put({__MODULE__, name}, :error)
            :error
        end
    end
  end

  def resolve(_), do: :error

  defp load(name) do
    if valid_path?(name) do
      @zone_roots
      |> Enum.find_value(&File.read(Path.join(&1, name)))
      |> case do
        {:ok, bin} -> parse_tzif(bin, name)
        _ -> :error
      end
    else
      :error
    end
  end

  # reject traversal / absolute / hidden names
  defp valid_path?("<<" <> _), do: false

  defp valid_path?(name) do
    Path.type(name) == :relative and
      not String.starts_with?(name, "/") and
      String.contains?(name, "/") !== false and
      !String.contains?(name, "..")
  end

  # TZif v2/v3: 44-byte header, V1 block, then a second header + 64-bit
  # block; we parse the 64-bit block. Falls back to V1 (32-bit) counts
  # when version is 0 (2\0).
  defp parse_tzif(bin, name) do
    with <<"TZif", ver, _::binary-size(15), counts::binary-size(24)>> <- bin,
         {isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt} = counts_bin(counts),
         v1_len <- v1_len(isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt),
         rest when byte_size(rest) > v1_len <- binary_part(bin, 44, byte_size(bin) - 44),
         <<_v1::binary-size(v1_len), "TZif", _ver2, _rsvd::binary-size(15),
           counts2::binary-size(24), body::binary>> <- rest,
         {isutcnt2, isstdcnt2, leapcnt2, timecnt2, typecnt2, charcnt2} = counts_bin(counts2),
         {:ok, zone} <-
           parse_block(body, name, timecnt2, typecnt2, charcnt2, leapcnt2, isstdcnt2, isutcnt2) do
      {:ok, zone}
    else
      _ -> parse_tzif_v1(bin, name)
    end
  end

  defp parse_tzif_v1(
         <<"TZif", _ver, _rsvd::binary-size(15), counts::binary-size(24), body::binary>>,
         name
       ) do
    {_isutcnt, _isstdcnt, _leapcnt, timecnt, typecnt, charcnt} = counts_bin(counts)
    # V1 block uses 4-byte transitions; isstd/isut counts follow the same
    # shape — pass the original counts
    {isutcnt, isstdcnt, leapcnt, _, _, _} = counts_bin(counts)
    parse_block_v1(body, name, timecnt, typecnt, charcnt, leapcnt, isstdcnt, isutcnt)
  end

  defp parse_tzif_v1(_, _), do: :error

  defp counts_bin(<<a::32, b::32, c::32, d::32, e::32, f::32>>),
    do: {a, b, c, d, e, f}

  defp v1_len(isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt) do
    timecnt * 5 + typecnt * 6 + charcnt + leapcnt * 8 + isstdcnt + isutcnt
  end

  # 64-bit block: transitions(int64) | indices(u8) | ttinfo(gmtoff i32,
  # isdst u8, abbrind u8) | chars | leap pairs | isstd | isut
  defp parse_block(body, name, timecnt, typecnt, charcnt, leapcnt, isstdcnt, _isutcnt) do
    trans_sz = timecnt * 8
    idx_sz = timecnt
    type_sz = typecnt * 6

    with <<trans::binary-size(trans_sz), idx::binary-size(idx_sz), ttinfo::binary-size(type_sz),
           chars::binary-size(charcnt), _rest::binary>> <- body do
      transitions =
        for <<t::signed-64 <- trans>>,
          do: t

      indices =
        for <<b::8 <- idx>>,
          do: b

      offsets =
        for <<gmtoff::signed-32, isdst::8, abbrind::8 <- ttinfo>>,
          do: {gmtoff, isdst != 0, abbrind}

      abbrs =
        chars
        |> parse_abbrs(0, %{})
        |> elem(1)

      {:ok,
       %Zone{
         name: name,
         transitions: Enum.zip(transitions, indices),
         offsets: offsets,
         abbrs: abbrs
       }}
    else
      _ -> :error
    end
  catch
    _, _ -> :error
  end

  defp parse_block_v1(body, name, timecnt, typecnt, charcnt, leapcnt, _isstdcnt, _isutcnt) do
    trans_sz = timecnt * 4
    idx_sz = timecnt
    type_sz = typecnt * 6

    with <<trans::binary-size(trans_sz), idx::binary-size(idx_sz), ttinfo::binary-size(type_sz),
           chars::binary-size(charcnt), _rest::binary>> <- body do
      transitions =
        for <<t::signed-32 <- trans>>,
          do: t * 1

      indices =
        for <<b::8 <- idx>>,
          do: b

      offsets =
        for <<gmtoff::signed-32, isdst::8, abbrind::8 <- ttinfo>>,
          do: {gmtoff, isdst != 0, abbrind}

      abbrs =
        chars
        |> parse_abbrs(0, %{})
        |> elem(1)

      {:ok,
       %Zone{
         name: name,
         transitions: Enum.zip(transitions, indices),
         offsets: offsets,
         abbrs: abbrs
       }}
    else
      _ -> :error
    end
  end

  defp parse_abbrs("", _pos, acc), do: {"", acc}

  defp parse_abbrs(bin, pos, acc) do
    case :binary.split(bin, "\0") do
      [abbr, rest] -> parse_abbrs(rest, pos + byte_size(abbr) + 1, Map.put(acc, pos, abbr))
      [abbr] -> {"", Map.put(acc, pos, abbr)}
    end
  end

  @doc """
  Offset in SECONDS at the given UTC instant: {offset_seconds, abbr, dst?}.
  Before the first transition TZif convention: the first non-DST type.
  """
  def offset_at(%Zone{name: "UTC"}, _utc), do: {0, "UTC", false}

  def offset_at(%Zone{} = z, utc) do
    case find_transition(z, utc) do
      nil ->
        first_std(z) || {0, "UTC", false}

      idx ->
        type_at(z, idx)
    end
  end

  defp find_transition(%Zone{transitions: ts}, utc) do
    find_ts(ts, utc, nil)
  end

  defp find_ts([{t, idx} | rest], utc, _acc) when utc >= t, do: find_ts(rest, utc, idx)

  defp find_ts([{_t, _idx} | _], _utc, acc), do: acc
  defp find_ts([], _utc, acc), do: acc

  defp first_std(%Zone{offsets: offsets, abbrs: abbrs}) do
    case Enum.find(offsets, fn {_off, dst, _} -> not dst end) || hd(offsets) do
      {off, dst, ai} -> {off, Map.get(abbrs, ai, ""), dst}
    end
  end

  defp type_at(%Zone{offsets: offsets, abbrs: abbrs}, idx) do
    case Enum.at(offsets, idx) do
      {off, dst, ai} -> {off, Map.get(abbrs, ai, ""), dst}
      nil -> {0, "UTC", false}
    end
  end

  @doc "wall-clock (naive) parts in the zone → UTC seconds (DST-aware)"
  def wall_to_utc(%Zone{name: "UTC"}, parts), do: naive_to_utc(parts, 0)

  def wall_to_utc(%Zone{} = z, parts) do
    guess = naive_to_utc(parts, 0)
    {off1, _, _} = offset_at(z, guess)
    utc1 = naive_to_utc(parts, off1)

    # crossing a transition between guess and utc1 shifts the offset —
    # refine once (php resolves ambiguity toward the later/DST side)
    {off2, _, _} = offset_at(z, utc1)

    if off2 == off1 do
      utc1
    else
      utc2 = naive_to_utc(parts, off2)
      {off3, _, _} = offset_at(z, utc2)
      naive_to_utc(parts, off3)
    end
  end

  @gregorian_epoch 62_167_219_200

  def naive_to_utc({y, mo, d, h, mi, s}, offset) do
    days = :calendar.date_to_gregorian_days({y, mo, d})
    days * 86_400 + h * 3600 + mi * 60 + s - @gregorian_epoch - offset
  end
end
