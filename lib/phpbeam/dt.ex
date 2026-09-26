defmodule PhpBeam.Dt do
  @moduledoc """
  The date/time engine: instants as {utc_seconds, microseconds, zone}
  with php's full `format()` specifier matrix, the compound parse grammar
  (ISO family / m-d-Y / @epoch / now / relative strings), calendar
  arithmetic (month-add with day overflow carry), ISO-8601 week numbers,
  and the diff algorithm (y/m/d/h/i/s + total days + invert).

  Zone handling: `{:named, zone}` (DtZone-backed, DST-aware),
  `{:offset, seconds}` (+05:00 style), `{:utc}`. `@epoch` timestamps
  force UTC (probed php behavior).
  """

  alias PhpBeam.DtZone

  defstruct utc: 0, us: 0, zone: {:utc}

  @gregorian_epoch 62_167_219_200
  @type zone_ref :: {:named, DtZone.Zone.t()} | {:offset, integer()} | {:utc}

  ## ───────────────────────── construction ─────────────────────────

  def now(default_tz \\ "UTC") do
    sys = System.system_time(:second)
    us = System.system_time(:microsecond) |> rem(1_000_000)
    %__MODULE__{utc: sys, us: us, zone: zone_of(default_tz)}
  end

  def from_timestamp(ts, tz \\ "UTC"),
    do: %__MODULE__{utc: ts, us: 0, zone: zone_of(tz)}

  def zone_of("UTC"), do: {:utc}
  def zone_of("GMT"), do: {:utc}

  def zone_of(name) when is_binary(name) do
    case DtZone.resolve(name) do
      {:ok, z} -> {:named, z}
      :error -> {:utc}
    end
  end

  def offset_zone(offset_seconds), do: {:offset, offset_seconds}

  @doc "parse php's datetime grammar; returns {:ok, dt} | :error (base = now for relative parts)"
  def parse(str, base_tz \\ "UTC") do
    case String.trim(str) do
      "now" ->
        {:ok, now(base_tz)}

      "@" <> ts ->
        case Integer.parse(ts) do
          {n, ""} -> {:ok, %__MODULE__{utc: n, us: 0, zone: {:offset, 0}}}
          _ -> :error
        end

      trimmed ->
        parse_compound(trimmed, base_tz)
    end
  end

  # compound: whitespace/T-separated pieces, each a date, a time, a zone,
  # or relative — php tokenizes and combines (later pieces override)
  defp parse_compound(str, base_tz) do
    # multiword month-name forms must be matched whole before splitting
    case whole_month_date(str) do
      {:ok, y, mo, d} -> assemble(%{y: y, mo: mo, d: d, h: 0, mi: 0, s: s0(), us: 0}, base_tz)
      :error -> parse_compound_split(str, base_tz)
    end
  end

  defp s0, do: 0

  defp whole_month_date(s) do
    case Regex.run(~r|^(\d{1,2}) ([A-Za-z]{3,9}) (\d{4})$|, s) do
      [_, d, mon, y] ->
        if mo = month_index(mon),
          do: {:ok, String.to_integer(y), mo, String.to_integer(d)},
          else: :error

      _ ->
        case Regex.run(~r|^([A-Za-z]{3,9}) (\d{1,2}),? (\d{4})$|, s) do
          [_, mon, d, y] ->
            if mo = month_index(mon),
              do: {:ok, String.to_integer(y), mo, String.to_integer(d)},
              else: :error

          _ ->
            :error
        end
    end
  end

  defp parse_compound_split(str, base_tz) do
    str
    |> split_pieces()
    |> Enum.reduce({:parts, %{}}, fn piece, {_, acc} ->
      case classify_piece(piece, acc) do
        {:date, y, mo, d} -> {:parts, Map.merge(acc, %{y: y, mo: mo, d: d})}
        {:time, h, mi, s, us} -> {:parts, Map.merge(acc, %{h: h, mi: mi, s: s, us: us || 0})}
        {:us, us} -> {:parts, Map.put(acc, :us, us)}
        {:ampm, which} -> {:parts, apply_ampm(acc, which)}
        {:zone, z} -> {:parts, Map.put(acc, :zone, z)}
        {:offset, off} -> {:parts, Map.put(acc, :explicit_offset, off)}
        :skip -> {:parts, acc}
        :error -> {:error, %{}}
      end
    end)
    |> case do
      {:error, _} ->
        :error

      {:parts, acc} ->
        assemble(acc, base_tz)
    end
  end

  defp split_pieces(str) do
    str
    |> String.replace("T", " ")
    |> String.split(~r/\s+/, trim: true)
  end

  defp classify_piece(p, acc) do
    cond do
      # 2026-01-02[.5] / 2026/01/02 / 2026.01.02
      Regex.match?(~r'^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}$', p) ->
        [y, mo, d] = match_ints(p, ~r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$')
        {:date, y, mo, d}

      # 20260102 (compact) / 20260102T030405 handled by T-split
      Regex.match?(~r/^\d{8}$/, p) ->
        <<y::binary-size(4), mo::binary-size(2), d::binary-size(2)>> = p
        {:date, String.to_integer(y), String.to_integer(mo), String.to_integer(d)}

      # 01/02/2026 (m/d/Y, US order — probed) / 01.02.2026? php: m/d/Y or d-m-Y
      Regex.match?(~r'^(\d{1,2})/(\d{1,2})/(\d{4})$', p) ->
        [mo, d, y] = match_ints(p, ~r'^(\d{1,2})/(\d{1,2})/(\d{4})$')
        {:date, y, mo, d}

      # 15 March 2026 / 15 March (d F [Y]) and March 15, 2026 (F d, Y)
      Regex.match?(~r/^\d{1,2} [A-Za-z]{3,9}( \d{4})?$/, p) ->
        [d, mon | yrest] = String.split(p, " ")
        mo = month_index(mon)
        y = yrest |> List.first() |> then(&if(&1, do: String.to_integer(&1), else: 1970))

        if mo,
          do: {:date, y, mo, String.to_integer(d)},
          else: :skip

      Regex.match?(~r/^[A-Za-z]{3,9} \d{1,2},? \d{4}$/, p) ->
        [mon, d, y] = String.split(p, " ")
        mo = month_index(mon)

        if mo,
          do:
            {:date, String.to_integer(String.trim_trailing(y, ",")), mo,
             String.to_integer(String.trim_trailing(d, ","))},
          else: :skip

      # 02-01-2026 → d-m-Y (probed php ambiguity rules: with 4-digit year
      # last and dashes, php reads d-m-Y)
      Regex.match?(~r/^(\d{1,2})-(\d{1,2})-(\d{4})$/, p) ->
        [d, mo, y] = match_ints(p, ~r/^(\d{1,2})-(\d{1,2})-(\d{4})$/)
        {:date, y, mo, d}

      # 03:04[:05[.678901]] with optional am/pm / a.m./p.m.
      Regex.match?(~r/^\d{1,2}:\d{2}(:\d{2}(\.\d{1,6})?)?\s*(am|pm|a\.m\.|p\.m\.)?$/i, p) ->
        parse_time(p)

      p in ["am", "a.m.", "pm", "p.m."] ->
        {:ampm, if(p in ["am", "a.m."], do: :am, else: :pm)}

      # zone offsets +05:00 / -0500 / +05 / Z
      Regex.match?(~r/^[+-]\d{2}:?\d{2}$/, p) ->
        {:offset, parse_offset(p)}

      p == "Z" ->
        {:offset, 0}

      # named zone (only when it looks like one and resolves)
      Regex.match?(~r/^[A-Za-z_]+\/[A-Za-z_\/]+$/, p) ->
        if DtZone.valid?(p), do: {:zone, p}, else: :error

      Regex.match?(~r/^(UTC|GMT|EST|EDT|CST|CDT|MST|MDT|PST|PDT)$/, p) ->
        case p do
          ab when ab in ["UTC", "GMT"] -> {:zone, "UTC"}
          _ -> {:zone, "UTC"}
        end

      true ->
        :skip
    end
  end

  @month_names ~w(january february march april may june july august september october november december)

  defp month_index(name) do
    dn = String.downcase(name)

    Enum.find_index(@month_names, fn m ->
      String.starts_with?(m, dn) or String.starts_with?(dn, m)
    end)
    |> then(&if(&1 == nil, do: nil, else: &1 + 1))
  end

  defp match_ints(s, re) do
    Regex.run(re, s) |> tl() |> Enum.map(&String.to_integer/1)
  end

  defp parse_time(p) do
    down = String.downcase(p)

    {time_part, ampm} =
      cond do
        String.ends_with?(down, "am") or String.ends_with?(down, "a.m.") ->
          {String.trim_trailing(down, String.split(down, " ") |> List.last()), :am}

        String.ends_with?(down, "pm") or String.ends_with?(down, "p.m.") ->
          {String.trim_trailing(down, String.split(down, " ") |> List.last()), :pm}

        true ->
          {down, nil}
      end

    [h, mi | rest] = String.split(time_part, ":")

    {s, us} =
      case rest do
        [sec] ->
          case String.split(sec, ".") do
            [si, usi] ->
              {String.to_integer(si), String.to_integer(String.pad_trailing(usi, 6, "0"))}

            [si] ->
              {String.to_integer(si), nil}
          end

        [] ->
          {0, nil}
      end

    h = String.to_integer(h)
    mi = String.to_integer(mi)

    h =
      case ampm do
        :pm when h < 12 -> h + 12
        :am when h == 12 -> 0
        _ -> h
      end

    {:time, h, mi, s, us}
  end

  defp parse_offset("Z"), do: 0

  defp parse_offset(p) do
    {sign, rest} =
      case p do
        "+" <> r -> {1, r}
        "-" <> r -> {-1, r}
      end

    {h, m} =
      case String.split(rest, ":") do
        [hh, mm] ->
          {String.to_integer(hh), String.to_integer(mm)}

        [<<hh::binary-size(2), mm::binary-size(2)>>] ->
          {String.to_integer(hh), String.to_integer(mm)}
      end

    sign * (h * 3600 + m * 60)
  end

  # "03:04:05 pm" parses the time first; the bare pm token then shifts it
  defp apply_ampm(acc, which) do
    case acc do
      %{h: h} ->
        h2 =
          case {which, h} do
            {:pm, h} when h < 12 -> h + 12
            {:am, 12} -> 0
            _ -> h
          end

        %{acc | h: h2}

      _ ->
        acc
    end
  end

  defp assemble(acc, base_tz) do
    y = Map.get(acc, :y)
    mo = Map.get(acc, :mo)
    d = Map.get(acc, :d)

    if y == nil or mo == nil or d == nil do
      :error
    else
      h = Map.get(acc, :h, 0)
      mi = Map.get(acc, :mi, 0)
      s = Map.get(acc, :s, 0)
      us = Map.get(acc, :us, 0)

      zone =
        cond do
          Map.has_key?(acc, :explicit_offset) -> {:offset, acc.explicit_offset}
          Map.has_key?(acc, :zone) -> zone_of(acc.zone)
          true -> zone_of(base_tz)
        end

      if mo in 1..12 and h in 0..23 and mi in 0..59 and s in 0..60 do
        # overflow days roll over (php: 2023-02-29 → 2023-03-01)
        {ny, nm, nd} = normalize_day(y, mo, d)

        utc =
          case zone do
            {:named, z} -> DtZone.wall_to_utc(z, {ny, nm, nd, h, mi, s})
            {:offset, off} -> DtZone.naive_to_utc({ny, nm, nd, h, mi, s}, off)
            {:utc} -> DtZone.naive_to_utc({ny, nm, nd, h, mi, s}, 0)
          end

        {:ok, %__MODULE__{utc: utc, us: us, zone: zone}}
      else
        :error
      end
    end
  end

  defp normalize_day(y, m, d) do
    if d >= 1 and d <= days_in_month(y, m) do
      {y, m, d}
    else
      days = :calendar.date_to_gregorian_days({y, m, 1}) + (d - 1)
      :calendar.gregorian_days_to_date(days)
    end
  end

  ## ───────────────────────── local parts ─────────────────────────

  @doc "{y, m, d, h, i, s, offset_seconds, abbr, dst?} in the dt's zone"
  def local(%__MODULE__{utc: utc, zone: zone}) do
    {off, abbr, dst} = zone_offset(zone, utc)
    gs = utc + off + @gregorian_epoch
    {{y, mo, d}, {h, mi, s}} = :calendar.gregorian_seconds_to_datetime(gs)
    {y, mo, d, h, mi, s, off, abbr, dst}
  end

  def zone_offset({:utc}, _utc), do: {0, "UTC", false}
  def zone_offset({:offset, off}, _utc), do: {off, offset_abbr(off), false}
  def zone_offset({:named, z}, utc), do: DtZone.offset_at(z, utc)

  defp offset_abbr(off), do: "GMT" <> offset_str(off, "")

  ## ───────────────────────── format ─────────────────────────

  def format(%__MODULE__{} = dt, fmt) do
    {y, mo, d, h, mi, s, off, abbr, dst} = local(dt)

    fmt
    |> String.to_charlist()
    |> Enum.map_reduce(false, fn
      ?\\, _esc -> {"", true}
      ch, true -> {<<ch>>, false}
      ch, false -> {format_char(ch, {y, mo, d, h, mi, s, off, abbr, dst, dt}), false}
    end)
    |> elem(0)
    |> Enum.join()
  end

  defp format_char(ch, {y, mo, d, h, mi, s, off, abbr, dst, dt}) do
    case ch do
      ?d -> pad(d, 2)
      ?D -> weekday_name(:calendar.day_of_the_week(date_of(y, mo, d)), :short)
      ?j -> Integer.to_string(d)
      ?l -> weekday_name(:calendar.day_of_the_week(date_of(y, mo, d)), :long)
      ?N -> Integer.to_string(:calendar.day_of_the_week(date_of(y, mo, d)))
      ?S -> ordinal_suffix(d)
      ?w -> Integer.to_string(rem(:calendar.day_of_the_week(date_of(y, mo, d)), 7))
      ?z -> Integer.to_string(day_of_year(y, mo, d) - 1)
      ?W -> pad(iso_week(y, mo, d), 2)
      ?F -> month_name(mo, :long)
      ?m -> pad(mo, 2)
      ?M -> month_name(mo, :short)
      ?n -> Integer.to_string(mo)
      ?t -> Integer.to_string(days_in_month(y, mo))
      ?L -> if leap?(y), do: "1", else: "0"
      ?o -> Integer.to_string(iso_week_year(y, mo, d))
      ?Y -> pad(y, 4)
      ?y -> pad(rem(y, 100), 2)
      ?a -> if h < 12, do: "am", else: "pm"
      ?A -> if h < 12, do: "AM", else: "PM"
      ?B -> swatch_beat(dt)
      ?g -> Integer.to_string(h12(h))
      ?G -> Integer.to_string(h)
      ?h -> pad(h12(h), 2)
      ?H -> pad(h, 2)
      ?i -> pad(mi, 2)
      ?s -> pad(s, 2)
      ?u -> pad(dt.us, 6)
      ?v -> pad(div(dt.us, 1000), 3)
      ?e -> zone_display_name(dt.zone, abbr)
      ?I -> if dst, do: "1", else: "0"
      ?O -> offset_str(off, "")
      ?P -> offset_str(off, ":")
      ?T -> abbr
      ?Z -> Integer.to_string(off)
      ?c -> format(dt, "Y-m-d\\TH:i:sP")
      ?r -> format(dt, "D, d M Y H:i:s O")
      ?U -> Integer.to_string(dt.utc)
      ch2 -> <<ch2>>
    end
  end

  defp date_of(y, mo, d), do: {y, mo, d}

  defp h12(h) when h == 0, do: 12
  defp h12(h) when h > 12, do: h - 12
  defp h12(h), do: h

  defp zone_display_name({:utc}, _), do: "UTC"
  defp zone_display_name({:offset, off}, _), do: offset_str(off, ":")
  defp zone_display_name({:named, z}, _), do: z.name

  def offset_str(off, sep) do
    sign = if off < 0, do: "-", else: "+"
    a = abs(off)
    sign <> pad(div(a, 3600), 2) <> sep <> pad(rem(div(a, 60), 60), 2)
  end

  # Swatch internet time: BMT = UTC+1; beats = floor(bmt_secs / 86.4)
  defp swatch_beat(%__MODULE__{utc: utc}) do
    bmt = Integer.mod(utc + 3600, 86_400)
    beats = div(bmt * 1000, 86_400)
    String.pad_leading(Integer.to_string(beats), 3, "0")
  end

  defp ordinal_suffix(d) do
    cond do
      rem(d, 100) in 11..13 -> "th"
      true -> %{1 => "st", 2 => "nd", 3 => "rd"}[rem(d, 10)] || "th"
    end
  end

  defp weekday_name(1, :short), do: "Mon"
  defp weekday_name(2, :short), do: "Tue"
  defp weekday_name(3, :short), do: "Wed"
  defp weekday_name(4, :short), do: "Thu"
  defp weekday_name(5, :short), do: "Fri"
  defp weekday_name(6, :short), do: "Sat"
  defp weekday_name(7, :short), do: "Sun"
  defp weekday_name(1, :long), do: "Monday"
  defp weekday_name(2, :long), do: "Tuesday"
  defp weekday_name(3, :long), do: "Wednesday"
  defp weekday_name(4, :long), do: "Thursday"
  defp weekday_name(5, :long), do: "Friday"
  defp weekday_name(6, :long), do: "Saturday"
  defp weekday_name(7, :long), do: "Sunday"

  defp month_name(m, :short),
    do: Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), m - 1)

  defp month_name(m, :long),
    do:
      Enum.at(
        ~w(January February March April May June July August September October November December),
        m - 1
      )

  defp pad(n, w), do: String.pad_leading(Integer.to_string(n), w, "0")

  ## ───────────────────────── calendar math ─────────────────────────

  def leap?(y), do: rem(y, 4) == 0 and (rem(y, 100) != 0 or rem(y, 400) == 0)

  def days_in_month(y, m) do
    case m do
      2 -> if leap?(y), do: 29, else: 28
      m when m in [1, 3, 5, 7, 8, 10, 12] -> 31
      _ -> 30
    end
  end

  defp day_of_year(y, m, d),
    do:
      :calendar.date_to_gregorian_days({y, m, d}) - :calendar.date_to_gregorian_days({y, 1, 1}) +
        1

  # ISO-8601 week: week 1 owns the year's first Thursday
  defp iso_week(y, m, d) do
    days = :calendar.date_to_gregorian_days({y, m, d})
    dow = :calendar.day_of_the_week({y, m, d})
    # Thursday of this ISO week
    thursday = days + (4 - dow)
    iso_year = iso_week_year(y, m, d)
    jan1 = :calendar.date_to_gregorian_days({iso_year, 1, 1})
    div(thursday - jan1, 7) + 1
  end

  def iso_week_year(y, m, d) do
    days = :calendar.date_to_gregorian_days({y, m, d})
    dow = :calendar.day_of_the_week({y, m, d})
    thursday = days + (4 - dow)
    {iso_y, _, _} = :calendar.gregorian_days_to_date(thursday)
    iso_y
  end

  @doc "add months with php's day-overflow carry (Jan 31 +1mo = Mar 3)"
  def add_months(%__MODULE__{} = dt, months) do
    {y, mo, d, h, mi, s, _off, _, _} = local(dt)
    {ny, nm} = shift_month(y, mo, months)

    # overflow: clamp to the month, spilling extra days into the next one
    {fy, fm, fd} =
      if d > days_in_month(ny, nm) do
        days = :calendar.date_to_gregorian_days({ny, nm, 1}) + (d - 1)
        :calendar.gregorian_days_to_date(days)
      else
        {ny, nm, d}
      end

    rebuild_local(dt, {fy, fm, fd}, {h, mi, s})
  end

  defp shift_month(y, m, delta) do
    total = y * 12 + (m - 1) + delta
    {div(total, 12), rem(total, 12) + 1}
  end

  def rebuild_local(%__MODULE__{} = dt, {y, mo, d}, {h, mi, s}) do
    utc =
      case dt.zone do
        {:named, z} -> DtZone.wall_to_utc(z, {y, mo, d, h, mi, s})
        {:offset, off} -> DtZone.naive_to_utc({y, mo, d, h, mi, s}, off)
        {:utc} -> DtZone.naive_to_utc({y, mo, d, h, mi, s}, 0)
      end

    %{dt | utc: utc}
  end

  ## ───────────────────────── relative modification ─────────────────────────

  @weekdays %{
    "sunday" => 7,
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6,
    "sun" => 7,
    "mon" => 1,
    "tue" => 2,
    "tues" => 2,
    "wed" => 3,
    "thu" => 4,
    "thurs" => 4,
    "fri" => 5,
    "sat" => 6,
    "sundays" => 7,
    "mondays" => 1,
    "tuesdays" => 2,
    "wednesdays" => 3,
    "thursdays" => 4,
    "fridays" => 5,
    "saturdays" => 6
  }

  @doc """
  php relative-modification grammar (modify()/strtotime's heart).
  Probed subtleties: next/last <weekday> = NEXT/PREV week's occurrence with
  time reset to 00:00; "<n> <weekday>s" counts today inclusively and keeps
  the time; tomorrow/yesterday reset the clock; month arithmetic carries
  day overflow (Mar 31 -1 month = Mar 3).
  """
  def apply_relative(%__MODULE__{} = dt, str) do
    parts = str |> String.downcase() |> String.split(~r/\s+/, trim: true)
    apply_parts(dt, parts, [])
  end

  defp apply_parts(dt, [], _pending), do: {:ok, dt}

  defp apply_parts(dt, parts, _) do
    case take_action(dt, parts) do
      {dt2, rest} -> apply_parts(dt2, rest, [])
      :error -> absolute_fallback(dt, parts)
    end
  end

  # php modify() accepts absolute datetimes: merge the parsed calendar
  # fields, keep the clock for fields the string omits
  defp absolute_fallback(dt, parts) do
    case parse(Enum.join(parts, " ")) do
      {:ok, %__MODULE__{utc: new_utc}} ->
        {_, _, _, h, mi, s, _, _, _} = local(dt)
        {{y, mo, d}, _} = :calendar.gregorian_seconds_to_datetime(new_utc + @gregorian_epoch)
        {:ok, rebuild_local(dt, {y, mo, d}, {h, mi, s})}

      :error ->
        :error
    end
  end

  # "(first..fifth|last) <weekday> of <month> [year]" — nth weekday of month
  defp take_action(dt, [ord, wd, "of" | rest])
       when ord in ["first", "second", "third", "fourth", "fifth", "last"] and
              is_map_key(@weekdays, wd) do
    nth_weekday_of_month(dt, ord_word(ord), @weekdays[wd], rest)
  end

  # "(first|last) day of <this|next|last month spec>"
  defp take_action(dt, [which, "day", "of" | rest]) when which in ["first", "last"] do
    month_shift =
      case rest do
        ["this" | _] -> 0
        ["next" | _] -> 1
        ["previous" | _] -> -1
        ["last" | _] -> -1
        _ -> 0
      end

    {y, mo, _d, h, mi, s, _, _, _} = local(dt)
    {ny, nm} = month_shift_op(y, mo, month_shift)
    nd = if which == "last", do: days_in_month(ny, nm), else: 1
    dt2 = reset_time(rebuild_local(dt, {ny, nm, nd}, {h, mi, s}))
    # first/last day of … keeps the clock (probe kept 00:00 from date-only)
    {dt2, tl_drop(rest)}
  end

  # "+N unit", "-N unit", "N unit", "N unit ago"
  defp take_action(dt, [sign, num, unit | rest]) when sign in ["+", "-"] do
    case {Integer.parse(num), unit_seconds(unit) || unit_months(unit)} do
      {{n, ""}, secs} when is_integer(secs) ->
        {%__MODULE__{dt | utc: dt.utc + if(sign == "-", do: -n, else: n) * secs}, rest}

      {{n, ""}, :month} ->
        {add_months(dt, if(sign == "-", do: -n, else: n) * 1 * month_mult(unit)), rest}

      _ ->
        :error
    end
  end

  defp take_action(dt, [num, unit | rest]) do
    case Integer.parse(num) do
      {n, ""} ->
        take_signed(dt, n, unit, rest)

      _ ->
        word_action(dt, [num, unit | rest])
    end
  end

  defp take_action(dt, parts), do: word_action(dt, parts)

  # two-word month phrases first ("next month" consumes both tokens)
  defp tl_drop(["this", "month" | r]), do: r
  defp tl_drop(["next", "month" | r]), do: r
  defp tl_drop(["previous", "month" | r]), do: r
  defp tl_drop(["last", "month" | r]), do: r
  defp tl_drop(["this" | r]), do: r
  defp tl_drop(["next" | r]), do: r
  defp tl_drop(["previous" | r]), do: r
  defp tl_drop(["last" | r]), do: r
  defp tl_drop(r), do: r

  defp month_shift_op(y, m, delta) do
    total = y * 12 + (m - 1) + delta
    {div(total, 12), rem(total, 12) + 1}
  end

  defp take_signed(dt, n, unit, rest) do
    {ago?, rest2} =
      case rest do
        ["ago" | r2] -> {true, r2}
        _ -> {false, rest}
      end

    n = if ago?, do: -n, else: n

    cond do
      secs = unit_seconds(unit) ->
        {%__MODULE__{dt | utc: dt.utc + n * secs}, rest2}

      unit_months(unit) == :month ->
        {add_months(dt, n * month_mult(unit)), rest2}

      wd = @weekdays[unit] ->
        # "3 fridays": nth occurrence counting today; keeps the clock
        {nth_weekday_forward(dt, n, wd), rest2}

      true ->
        :error
    end
  end

  defp word_action(dt, ["ago" | rest]), do: {dt, rest}

  defp word_action(dt, ["next", wd | rest]) when is_map_key(@weekdays, wd) do
    {next_week_weekday(dt, @weekdays[wd]), rest}
  end

  defp word_action(dt, ["last", wd | rest]) when is_map_key(@weekdays, wd) do
    {prev_week_weekday(dt, @weekdays[wd]), rest}
  end

  defp word_action(dt, ["next", "week" | rest]), do: {start_of_week(dt, 1), rest}
  defp word_action(dt, ["last", "week" | rest]), do: {start_of_week(dt, -1), rest}
  defp word_action(dt, ["next", "month" | rest]), do: {month_add_reset(dt, 1, 1), rest}
  defp word_action(dt, ["last", "month" | rest]), do: {month_add_reset(dt, -1, 1), rest}
  defp word_action(dt, ["next", "year" | rest]), do: {month_add_reset(dt, 12, 1), rest}
  defp word_action(dt, ["last", "year" | rest]), do: {month_add_reset(dt, -12, 1), rest}

  defp word_action(dt, ["tomorrow" | rest]),
    do: {reset_time(%__MODULE__{dt | utc: dt.utc + 86_400}), rest}

  defp word_action(dt, ["yesterday" | rest]),
    do: {reset_time(%__MODULE__{dt | utc: dt.utc - 86_400}), rest}

  defp word_action(dt, ["today" | rest]), do: {reset_time(dt), rest}
  defp word_action(dt, ["midnight" | rest]), do: {set_time(dt, 0, 0, 0), rest}
  defp word_action(dt, ["noon" | rest]), do: {set_time(dt, 12, 0, 0), rest}
  defp word_action(dt, ["sec" | rest]), do: {dt, rest}

  # bare weekday in strtotime context: next occurrence (not today)
  defp word_action(dt, [wd | rest]) when is_map_key(@weekdays, wd) do
    {next_occurrence(dt, @weekdays[wd]), rest}
  end

  defp word_action(_dt, _), do: :error

  defp unit_seconds(u) do
    %{
      "sec" => 1,
      "secs" => 1,
      "second" => 1,
      "seconds" => 1,
      "min" => 60,
      "mins" => 60,
      "minute" => 60,
      "minutes" => 60,
      "hour" => 3600,
      "hours" => 3600,
      "day" => 86_400,
      "days" => 86_400,
      "week" => 604_800,
      "weeks" => 604_800,
      "fortnight" => 1_209_600,
      "fortnights" => 1_209_600
    }[u]
  end

  defp unit_months(u) when u in ["month", "months"], do: :month
  defp unit_months(u) when u in ["year", "years"], do: :month
  defp unit_months(_), do: nil

  defp month_mult(u) when u in ["month", "months"], do: 1
  defp month_mult(_), do: 12

  defp ord_word("first"), do: 1
  defp ord_word("second"), do: 2
  defp ord_word("third"), do: 3
  defp ord_word("fourth"), do: 4
  defp ord_word("fifth"), do: 5
  defp ord_word("last"), do: :last

  # "next month/year": month shift, day reset to 1 (php behavior for the
  # bare next-month form; time-of-day kept)
  defp month_add_reset(dt, months, day) do
    {y, mo, _d, h, mi, s, _, _, _} = local(dt)
    {ny, nm} = month_shift_op(y, mo, months)
    rebuild_local(dt, {ny, nm, day}, {h, mi, s})
  end

  defp set_time(dt, h, mi, s) do
    {y, mo, d, _, _, _, _, _, _} = local(dt)
    rebuild_local(dt, {y, mo, d}, {h, mi, s})
  end

  defp reset_time(dt), do: set_time(dt, 0, 0, 0)

  # Monday-start week containing (dt + weeks*7), clock reset
  defp start_of_week(dt, weeks) do
    {y, mo, d, _, _, _, _, _, _} = local(dt)
    days = :calendar.date_to_gregorian_days({y, mo, d})
    dow = :calendar.day_of_the_week({y, mo, d})
    monday = days - (dow - 1) + weeks * 7
    {yy, mm, dd} = :calendar.gregorian_days_to_date(monday)
    rebuild_local(dt, {yy, mm, dd}, {0, 0, 0})
  end

  # next/last <weekday>: the occurrence in the FOLLOWING/PREVIOUS week
  defp next_week_weekday(dt, wd) do
    dt2 = next_occurrence(dt, wd)
    reset_time(dt2)
  end

  defp prev_week_weekday(dt, wd) do
    next_week_weekday(dt, wd)
    |> then(fn %__MODULE__{utc: u} = d ->
      # previous occurrence: back off 7 from the next one, then once more
      # if that lands on today
      {y, mo, dd, _, _, _, _, _, _} = local(%{d | utc: u - 7 * 86_400})
      {y0, m0, d0, _, _, _, _, _, _} = local(d)

      if {y, mo, dd} == {y0, m0, d0} do
        %{d | utc: u - 14 * 86_400}
      else
        %{d | utc: u - 7 * 86_400}
      end
    end)
  end

  defp next_occurrence(dt, wd) do
    {y, mo, d, _, _, _, _, _, _} = local(dt)
    dow = :calendar.day_of_the_week({y, mo, d})
    delta = rem(wd - dow + 7 - 1, 7) + 1

    {%__MODULE__{dt | utc: dt.utc + delta * 86_400} |> then(&set_time(&1, 0, 0, 0)), :ok}
    |> elem(0)
  end

  # nth weekday forward counting today (php "3 fridays")
  defp nth_weekday_forward(dt, n, wd) do
    {y, mo, d, h, mi, s, _, _, _} = local(dt)
    dow = :calendar.day_of_the_week({y, mo, d})
    delta = rem(wd - dow + 7, 7) + (n - 1) * 7
    days = :calendar.date_to_gregorian_days({y, mo, d}) + delta
    {yy, mm, dd} = :calendar.gregorian_days_to_date(days)
    rebuild_local(dt, {yy, mm, dd}, {h, mi, s})
  end

  # "(second) sunday of march 2026" → that month's nth weekday
  defp nth_weekday_of_month(dt, n, wd, rest) do
    {y, mo, d, h, mi, s, _, _, _} = local(dt)
    {month_name, year} = month_of_phrase(rest, mo, y)

    first_dow = :calendar.day_of_the_week({year, month_name, 1})
    first_hit = 1 + rem(wd - first_dow + 7, 7)

    day =
      if n == :last do
        # last occurrence: first + 7k within the month
        last_hit(first_hit, days_in_month(year, month_name))
      else
        first_hit + (n - 1) * 7
      end

    consumed =
      case Enum.at(rest, 1) do
        ys ->
          case Integer.parse(ys || "") do
            {_, ""} -> 2
            _ -> 1
          end
      end

    if day <= days_in_month(year, month_name) do
      {rebuild_local(dt, {year, month_name, day}, {0, 0, 0}), Enum.drop(rest, consumed)}
    else
      # overflow: php normalizes by rolling
      nd = :calendar.date_to_gregorian_days({year, month_name, 1}) + (day - 1)
      {yy, mm, dd} = :calendar.gregorian_days_to_date(nd)
      {rebuild_local(dt, {yy, mm, dd}, {h, mi, s}), Enum.drop(rest, consumed)}
    end
  end

  defp last_hit(first_hit, dim) do
    first_hit + div(dim - first_hit, 7) * 7
  end

  defp month_of_phrase(rest, default_mo, default_y) do
    months =
      ~w(january february march april may june july august september october november december)

    mo =
      Enum.find_index(months, &(hd(rest) == &1)) ||
        Enum.find_index(months, fn m -> hd(rest) != nil and String.starts_with?(m, hd(rest)) end)

    mo = if mo, do: mo + 1, else: default_mo

    y =
      case Enum.at(rest, 1) do
        nil ->
          default_y

        ys ->
          case Integer.parse(ys) do
            {yy, ""} -> yy
            _ -> default_y
          end
      end

    {mo, y}
  end

  ## ---------------- diff & createFromFormat ----------------

  # componentwise calendar diff (php DateInterval): y/m/d/h/i/s + total
  # days + invert (1 when a > b). Simplified carry: time-of-day diff is
  # computed on seconds-of-day; days on gregorian distance; months/years
  # by anchor-month walk-back.
  def diff(%__MODULE__{} = a, %__MODULE__{} = b) do
    invert = if a.utc > b.utc, do: 1, else: 0
    {lo, hi} = if a.utc <= b.utc, do: {a, b}, else: {b, a}
    {y1, mo1, d1, h1, mi1, s1, _, _, _} = local(lo)
    {y2, mo2, d2, h2, mi2, s2, _, _, _} = local(hi)

    sec1 = h1 * 3600 + mi1 * 60 + s1
    sec2 = h2 * 3600 + mi2 * 60 + s2

    {day_carry, sec_diff} = if sec2 >= sec1, do: {0, sec2 - sec1}, else: {1, sec2 + 86_400 - sec1}

    days_total =
      :calendar.date_to_gregorian_days({y2, mo2, d2}) -
        :calendar.date_to_gregorian_days({y1, mo1, d1}) - day_carry

    # months/years: walk from (y1,mo1,d1) forward month by month while the
    # anchor day still fits — the php "has the day been reached" rule
    {months, anchor_day} = count_months({y1, mo1, d1}, {y2, mo2, d2}, 0)

    days =
      :calendar.date_to_gregorian_days({y2, mo2, d2}) -
        :calendar.date_to_gregorian_days(anchor_day)

    h = div(sec_diff, 3600)
    mi = div(rem(sec_diff, 3600), 60)
    s = rem(sec_diff, 60)

    %{
      y: div(months, 12),
      m: rem(months, 12),
      d: max(days, 0),
      h: h,
      i: mi,
      s: s,
      days: max(days_total, 0),
      invert: invert
    }
  end

  defp count_months({y, mo, d} = start, {y2, mo2, _d2} = stop, n) do
    {ny, nm} = month_add({y, mo}, 1)

    cond do
      {ny, nm} > {y2, mo2} ->
        {n, start}

      true ->
        # anchor (y,mo,d) advanced one month, clamped to month length
        nd = min(d, days_in_month(ny, nm))
        count_months({ny, nm, nd}, stop, n + 1)
    end
  end

  defp month_add({y, mo}, 1) do
    if mo == 12, do: {y + 1, 1}, else: {y, mo + 1}
  end

  # createFromFormat: common specifier subset (Y y m n d j H G i s u a A)
  # plus literal separators; unmatched input → :error
  def create_from_format(fmt, val, base_tz) do
    cf(String.to_charlist(fmt), String.to_charlist(val), [], base_tz)
  end

  defp cf([], [], parts, tz), do: assemble_pairs(parts, tz)

  defp cf([?Y | fs], [a, b, c, d | vs], parts, tz),
    do: cf(fs, vs, [{:y, digits4([a, b, c, d])} | parts], tz)

  defp cf([?y | fs], [a, b | vs], parts, tz),
    do: cf(fs, vs, [{:y, 2000 + digits4([a, b])} | parts], tz)

  defp cf([?m | fs], [a, b | vs], parts, tz),
    do: cf(fs, vs, [{:mo, digits4([a, b])} | parts], tz)

  defp cf([?d | fs], [a, b | vs], parts, tz),
    do: cf(fs, vs, [{:d, digits4([a, b])} | parts], tz)

  defp cf([?H | fs], [a, b | vs], parts, tz),
    do: cf(fs, vs, [{:h, digits4([a, b])} | parts], tz)

  defp cf([?i | fs], [a, b | vs], parts, tz),
    do: cf(fs, vs, [{:mi, digits4([a, b])} | parts], tz)

  defp cf([?s | fs], [a, b | vs], parts, tz),
    do: cf(fs, vs, [{:s, digits4([a, b])} | parts], tz)

  defp cf([f | fs], [f | vs], parts, tz), do: cf(fs, vs, parts, tz)
  defp cf(_f, _v, _p, _t), do: :error

  defp digits4(chars), do: Enum.reduce(chars, 0, &(&2 * 10 + (&1 - ?0)))

  defp assemble_pairs(parts, tz) do
    acc =
      parts
      |> Enum.map(fn {k, v} -> {k, v} end)
      |> Map.new()

    if Map.has_key?(acc, :y) and Map.has_key?(acc, :mo) and Map.has_key?(acc, :d) do
      assemble(
        %{
          y: acc.y,
          mo: acc.mo,
          d: acc.d,
          h: Map.get(acc, :h, 0),
          mi: Map.get(acc, :mi, 0),
          s: Map.get(acc, :s, 0),
          us: 0
        },
        tz
      )
    else
      :error
    end
  end

  def offset_str(off, sep) do
    sign = if off < 0, do: "-", else: "+"
    a = abs(off)

    sign <>
      String.pad_leading(Integer.to_string(div(a, 3600)), 2, "0") <>
      sep <> String.pad_leading(Integer.to_string(rem(div(a, 60), 60)), 2, "0")
  end
end
