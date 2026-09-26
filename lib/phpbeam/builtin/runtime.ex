defmodule PhpBeam.Builtin.RuntimeFns do
  @moduledoc """
  Runtime/introspection builtins: ini settings, error reporting level,
  error-handler/exception-handler/shutdown/autoloader bookkeeping.

  Shutdown callbacks run at script termination (Eval.Finalize); error
  handlers are stored as a stack with their level masks — warning dispatch
  happens at the Eval layer (Eval.Error), which calls back into PHP.
  """

  alias PhpBeam.{Ini, PArray, Value}
  alias PhpBeam.Eval.Error
  import Bitwise

  def register(fns) do
    entries = %{
      "ini_get" => &ini_get/2,
      "ini_set" => &ini_set/2,
      "ini_restore" => &ini_restore/2,
      "error_reporting" => &error_reporting/2,
      "ini_get_all" => &ini_get_all/2,
      "ini_parse_quantity" => &ini_parse_quantity/2,
      "set_error_handler" => &set_error_handler/2,
      "restore_error_handler" => &restore_error_handler/2,
      "set_exception_handler" => &set_exception_handler/2,
      "restore_exception_handler" => &restore_exception_handler/2,
      "register_shutdown_function" => &register_shutdown_function/2,
      "spl_autoload_register" => &spl_autoload_register/2,
      "spl_autoload_unregister" => &spl_autoload_unregister/2,
      "spl_autoload_functions" => &spl_autoload_functions/2,
      "set_time_limit" => &set_time_limit/2,
      "zend_version" => &zend_version/2,
      "sys_get_temp_dir" => &sys_get_temp_dir/2,
      "getmypid" => &getmypid/2,
      "setlocale" => &setlocale/2,
      "get_defined_functions" => &get_defined_functions/2,
      "debug_backtrace" => &debug_backtrace/2,
      "set_include_path" => &set_include_path/2,
      "get_include_path" => &get_include_path/2,
      "restore_include_path" => &restore_include_path/2,
      "error_get_last" => &error_get_last/2,
      "error_clear_last" => &error_clear_last/2,
      "gc_collect_cycles" => &gc_collect_cycles/2,
      "date_default_timezone_set" => &tz_set/2,
      "date_default_timezone_get" => &tz_get/2,
      "date" => &date_v/2,
      "gmdate" => &gmdate_v/2,
      "time" => &time_v/2,
      "strtotime" => &strtotime_v/2,
      "timezone_version_get" => &tz_version/2,
      "mktime" => &mktime_v/2,
      "gmmktime" => &gmmktime_v/2,
      "checkdate" => &checkdate_v/2,
      "date_create" => &date_create_v/2,
      "date_create_immutable" => &date_create_immutable_v/2,
      "date_create_from_format" => &date_create_from_format_v/2,
      "date_format" => &date_format_v/2,
      "date_modify" => &date_modify_v/2,
      "date_add" => &date_add_v/2,
      "date_sub" => &date_sub_v/2,
      "date_diff" => &date_diff_v/2,
      "date_timestamp_get" => &date_timestamp_get_v/2,
      "date_timestamp_set" => &date_timestamp_set_v/2,
      "timezone_open" => &tz_open/2,
      "header_remove" => &header_remove_v/2,
      "headers_list" => &headers_list_v/2,
      "http_response_code" => &http_response_code_v/2,
      "set_time_limit" => &set_time_limit/2
    }

    entries
    |> Enum.reduce(fns, fn {name, fun}, acc ->
      Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
    end)
    |> Map.merge(ho_entries())
  end

  # ── higher-order builtins (registry v2 ho: entries) ──
  # call_user_func family re-enters the evaluator via the Eval.Call gateway;
  # exit/die surface the halt signal through the unwind channel

  defp ho_entries do
    nofun = fn _v, i, _c -> {:ok, :null, i} end

    %{
      "call_user_func" => %{
        fun: nofun,
        refs: [],
        ho: %{
          args: :eval,
          fun: fn vals, env, interp ->
            case vals do
              [cb | rest] ->
                # php names the caller in TypeError callback messages and
                # shows it in traces — keep a frame for the duration
                it2 = PhpBeam.Interp.push_frame(interp, "call_user_func", vals)

                case PhpBeam.Eval.call_cb(cb, rest, env, it2) do
                  {{:val, _v} = r, e, i3} -> {r, e, PhpBeam.Interp.pop_frame(i3)}
                  other -> other
                end

              _ ->
                {{:unwind, {:fatal, "Call to undefined function call_user_func()"}}, env, interp}
            end
          end
        }
      },
      "call_user_func_array" => %{
        fun: nofun,
        refs: [],
        ho: %{
          args: :eval,
          fun: fn vals, env, interp ->
            case vals do
              [cb, {:array, arr}] ->
                it2 = PhpBeam.Interp.push_frame(interp, "call_user_func_array", vals)

                case PhpBeam.Eval.call_cb(cb, PArray.values(arr), env, it2) do
                  {{:val, _v} = r, e, i3} -> {r, e, PhpBeam.Interp.pop_frame(i3)}
                  other -> other
                end

              _ ->
                {{:unwind, {:fatal, "Call to undefined function call_user_func_array()"}}, env,
                 interp}
            end
          end
        }
      },
      "exit" => %{fun: nofun, refs: [], ho: %{args: :eval, fun: &exit_call/3}},
      "die" => %{fun: nofun, refs: [], ho: %{args: :eval, fun: &exit_call/3}}
    }
  end

  defp exit_call(vals, env, interp) do
    case Enum.at(vals, 0) do
      {:int, code} ->
        {{:unwind, {:halt, code}}, env, interp}

      {:string, msg} ->
        interp2 = PhpBeam.Interp.write(interp, msg)
        {{:unwind, {:halt, 0}}, env, interp2}

      _ ->
        {{:unwind, {:halt, 0}}, env, interp}
    end
  end

  ## ─────────────────────────── ini ───────────────────────────

  defp ini_get(vals, i) do
    case vals do
      [{:string, k} | _] ->
        case Map.fetch(i.ini, k) do
          {:ok, v} -> {:ok, {:string, ini_to_string(v)}, i}
          :error -> {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp ini_set(vals, i) do
    case vals do
      [{:string, k}, v | _] ->
        # php: ini_set needs the USER access bit; unregistered names return
        # false silently
        if Ini.registered?(k) and Ini.settable_at_runtime?(k) do
          old = ini_get([{:string, k}], i)
          str = value_to_ini_string(v)
          {:ok, elem(old, 1), %{i | ini: Map.put(i.ini, k, str)}}
        else
          {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  # restore to the startup-loaded value (php.ini/-c/-d), falling back to the
  # registered default
  defp ini_restore(vals, i) do
    case vals do
      [{:string, k} | _] ->
        if Ini.registered?(k) do
          restored = Map.get(i.ini_global, k, Ini.default(k))
          {:ok, :null, %{i | ini: Map.put(i.ini, k, restored)}}
        else
          {:ok, :null, i}
        end

      _ ->
        {:ok, :null, i}
    end
  end

  # php: global_value = php.ini layer (startup-loaded or compiled default),
  # local_value = current runtime value, access = PHP_INI_* bits; details=false
  # collapses to name => local string. Module filter is case-insensitive.
  defp ini_get_all(vals, i) do
    {module_filter, details} =
      case vals do
        [{:string, m} | rest] -> {String.downcase(m), rest == [] or truthy?(rest)}
        [v | rest] when v != :null -> {"", rest == [] or truthy?(rest)}
        _ -> {"", true}
      end

    names =
      Ini.table()
      |> Map.keys()
      |> Enum.sort()
      |> Enum.filter(fn n ->
        module_filter == "" or String.downcase(Ini.module(n)) == module_filter
      end)

    arr =
      if details do
        PArray.from_pairs(
          Enum.map(names, fn n ->
            entry =
              PArray.from_pairs([
                {"global_value", {:string, Map.get(i.ini_global, n, Ini.default(n))}},
                {"local_value", {:string, Map.get(i.ini, n, Ini.default(n))}},
                {"access", {:int, Ini.access(n)}}
              ])

            {n, {:array, entry}}
          end)
        )
      else
        PArray.from_pairs(
          Enum.map(names, fn n -> {n, {:string, Map.get(i.ini, n, Ini.default(n))}} end)
        )
      end

    {:ok, {:array, arr}, i}
  end

  defp truthy?([v | _]), do: Value.truthy?(v)
  defp truthy?(_), do: true

  defp ini_parse_quantity(vals, i) do
    case vals do
      [{:string, s} | _] ->
        {value, warning} = Ini.parse_quantity(s)

        i2 =
          if warning,
            do: warn_dispatch(i, warning),
            else: i

        {:ok, {:int, value}, i2}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp warn_dispatch(i, msg) do
    case Error.warn(Error.stub_env(), i, msg) do
      {:cont, _, i2} -> i2
      {:unwind, _, _, i2} -> i2
    end
  end

  defp set_include_path(vals, i) do
    old = ini_get([{:string, "include_path"}], i)

    case vals do
      [v | _] ->
        {:ok, elem(old, 1), %{i | ini: Map.put(i.ini, "include_path", value_to_ini_string(v))}}

      [] ->
        {:ok, {:bool, false}, i}
    end
  end

  defp get_include_path(_vals, i), do: ini_get([{:string, "include_path"}], i)

  defp restore_include_path(_vals, i),
    do: {:ok, :null, %{i | ini: Map.delete(i.ini, "include_path")}}

  defp value_to_ini_string(v) do
    case Value.cast_string(v) do
      {:ok, s} -> s
      _ -> ""
    end
  end

  defp ini_to_string(v) when is_binary(v), do: v
  defp ini_to_string(v) when is_integer(v), do: Integer.to_string(v)

  ## ───────────────────── error reporting ─────────────────────

  # while @ is active, error_reporting() reads the masked value (zend
  # php_mask_error: only the always-fatal bits survive — probed 4437)
  @fatal_bits 4437

  defp error_reporting(vals, i) do
    cur = int_ini(i, "error_reporting", 30719)

    case vals do
      [] ->
        {:ok, {:int, masked_reporting(cur, i)}, i}

      [v | _] ->
        n =
          case Value.to_int(v) do
            {:ok, {:int, n}} -> n
            _ -> cur
          end

        {:ok, {:int, cur}, %{i | ini: Map.put(i.ini, "error_reporting", Integer.to_string(n))}}
    end
  end

  defp masked_reporting(cur, %{suppress: s}) when s > 0, do: cur &&& @fatal_bits
  defp masked_reporting(cur, _), do: cur

  defp set_error_handler(vals, i) do
    case vals do
      [cb | rest] ->
        levels =
          case rest do
            [v | _] ->
              case Value.to_int(v) do
                {:ok, {:int, n}} -> n
                _ -> 30719
              end

            [] ->
              30719
          end

        prev =
          case List.first(i.error_handlers) do
            {nil, _} -> :null
            {prev_cb, _} -> prev_cb
            nil -> :null
          end

        {:ok, prev, %{i | error_handlers: [{cb, levels} | i.error_handlers]}}

      [] ->
        {:ok, :null, i}
    end
  end

  defp restore_error_handler(_vals, i),
    do: {:ok, {:bool, true}, %{i | error_handlers: tl(i.error_handlers)}}

  defp set_exception_handler(vals, i) do
    case vals do
      [cb | _] ->
        prev = List.first(i.exception_handlers) || :null
        {:ok, prev, %{i | exception_handlers: [cb | i.exception_handlers]}}

      [] ->
        {:ok, :null, i}
    end
  end

  defp restore_exception_handler(_vals, i),
    do: {:ok, {:bool, true}, %{i | exception_handlers: tl(i.exception_handlers)}}

  defp error_get_last(_vals, i) do
    case i.last_error do
      nil ->
        {:ok, :null, i}

      e ->
        arr =
          PArray.from_pairs([
            {"type", {:int, e.type}},
            {"message", {:string, e.message}},
            {"file", {:string, e.file}},
            {"line", {:int, e.line}}
          ])

        {:ok, {:array, arr}, i}
    end
  end

  defp error_clear_last(_vals, i), do: {:ok, :null, %{i | last_error: nil}}

  ## ─────────────── autoload / shutdown bookkeeping ───────────────

  defp spl_autoload_register(vals, i) do
    case vals do
      [cb | _] -> {:ok, {:bool, true}, %{i | autoload_fns: i.autoload_fns ++ [cb]}}
      [] -> {:ok, {:bool, false}, i}
    end
  end

  defp spl_autoload_unregister(vals, i) do
    case vals do
      [cb | _] ->
        if cb in i.autoload_fns do
          {:ok, {:bool, true}, %{i | autoload_fns: List.delete(i.autoload_fns, cb)}}
        else
          {:ok, {:bool, false}, i}
        end

      [] ->
        {:ok, {:bool, false}, i}
    end
  end

  defp spl_autoload_functions(_vals, i) do
    arr = PArray.from_pairs(Enum.map(i.autoload_fns, &{nil, &1}))
    {:ok, {:array, arr}, i}
  end

  # extra args are captured at registration and passed to the callback at
  # shutdown (Eval.Finalize consumes {cb, args} tuples FIFO)
  defp register_shutdown_function(vals, i) do
    case vals do
      [cb | args] -> {:ok, :null, %{i | shutdown_fns: i.shutdown_fns ++ [{cb, args}]}}
      [] -> {:ok, :null, i}
    end
  end

  ## ───────────────────── misc runtime info ─────────────────────

  defp set_time_limit(_vals, i), do: {:ok, {:bool, true}, i}

  defp zend_version(_vals, i), do: {:ok, {:string, "4.4.0"}, i}

  defp sys_get_temp_dir(_vals, i) do
    # php returns WITHOUT the trailing slash (macOS System.tmp_dir! has one)
    dir = System.tmp_dir!() || "/tmp"
    {:ok, {:string, String.trim_trailing(dir, "/")}, i}
  end

  defp getmypid(_vals, i), do: {:ok, {:int, :os.getpid() |> List.to_integer()}, i}

  defp gc_collect_cycles(_vals, i), do: {:ok, {:int, 0}, i}

  # real connections come with the database milestone; for now the presence
  # of these satisfies WP's function_exists() bootstrap gates
  defp mysqli_stub(vals, i), do: {:ok, {:bool, false}, i}

  defp mysqli_client_info(_vals, i), do: {:ok, {:string, "mysqlnd 8.4.2"}, i}

  # claiming the sodium extension (matching the reference php-cli) means the
  # function entry points must exist too — WP's compat.php polyfills on
  # function_exists('sodium_crypto_box')
  defp sodium_stub(_vals, i), do: {:ok, {:bool, false}, i}

  # ───────────────────────── date/time (UTC, gmdate-parity) ─────────────────────────

  defp header_remove_v(vals, i), do: {:ok, :null, PhpBeam.Interp.sapi_remove_header(i, vals)}

  defp headers_list_v(_vals, i), do: {:ok, {:array, PhpBeam.Interp.sapi_list_headers(i)}, i}

  defp http_response_code_v(vals, i) do
    {code, i2} = PhpBeam.Interp.sapi_status(i, vals)
    {:ok, {:int, code}, i2}
  end

  defp tz_set(vals, i) do
    case vals do
      [{:string, tz} | _] ->
        if PhpBeam.DtZone.valid?(tz) do
          {:ok, {:bool, true}, %{i | ini: Map.put(i.ini, "date.timezone", tz)}}
        else
          {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  ## ───────────────────────── mktime family ─────────────────────────

  # php arg order (h, i, s, m, d, y); missing parts default from local
  # now; overflow rolls (month 13, day 30-of-Feb all normalize)
  defp mktime_v(vals, i) do
    {ok?, utc} = mk_parts(vals, dt_zone(i), PhpBeam.Dt.now("UTC"))
    if ok?, do: {:ok, {:int, utc}, i}, else: {:ok, {:bool, false}, i}
  end

  defp gmmktime_v(vals, i) do
    {ok?, utc} = mk_parts(vals, {:utc}, PhpBeam.Dt.now("UTC"))
    if ok?, do: {:ok, {:int, utc}, i}, else: {:ok, {:bool, false}, i}
  end

  defp mk_parts(vals, zone, now_dt) do
    now_parts = PhpBeam.Dt.local(%{now_dt | zone: zone})

    {y, mo, d, h, mi, s} =
      case vals do
        [hh, ii, ss, mm, dd, yy | _] ->
          {pint(yy, now_parts), pint(mm, now_parts), pint(dd, now_parts), pint(hh, now_parts),
           pint(ii, now_parts), pint(ss, now_parts)}

        [hh, ii, ss, mm, dd | _] ->
          {elem(now_parts, 0), pint(mm, now_parts), pint(dd, now_parts), pint(hh, now_parts),
           pint(ii, now_parts), pint(ss, now_parts)}

        _ ->
          {elem(now_parts, 0), elem(now_parts, 1), elem(now_parts, 2), elem(now_parts, 3),
           elem(now_parts, 4), elem(now_parts, 5)}
      end

    # two-digit years: 00-68 → 20xx, 69-99 → 19xx (php rule)
    y = if y < 100, do: if(y < 69, do: 2000 + y, else: 1900 + y), else: y

    # month/day overflow rolls over gregorian-style (month 13 → Jan+1y)
    {{ry, rmo}, rd} = month_roll(y, mo, d)

    case PhpBeam.Dt.parse(
           "#{ry}-#{pad2(rmo)}-#{pad2(rd)} #{pad2(clamp0(h))}:#{pad2(clamp0(mi))}:#{pad2(clamp0(s))}",
           "UTC"
         ) do
      {:ok, %PhpBeam.Dt{utc: utc}} ->
        # wall-clock was zone-local: shift by wall→utc in that zone
        {true, wall_shift(utc, zone)}

      :error ->
        {false, 0}
    end
  end

  defp pint({:int, n}, _), do: n
  defp pint({:null, _}, parts), do: parts
  defp pint(_, parts), do: parts

  defp clamp0(n) when is_integer(n) and n >= 0, do: n
  defp clamp0(n) when is_integer(n), do: 0

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp month_roll(y, mo, d) do
    total = y * 12 + (mo - 1)
    {ny, nm} = {div(total, 12), rem(total, 12) + 1}
    # day overflow rolls into the next month (Feb 30 → Mar 2)
    nd = :calendar.date_to_gregorian_days({ny, nm, 1}) + (d - 1)
    {{yy, mm, dd}, _} = {:calendar.gregorian_days_to_date(nd), nil}
    {{yy, mm}, dd}
  end

  # The parse above produced UTC-interpreted seconds for a wall clock that
  # was actually zone-local; adjust by the zone's offset at that instant.
  defp wall_shift(utc_as_if_utc, {:utc}), do: utc_as_if_utc
  defp wall_shift(utc_as_if_utc, {:offset, _off}), do: utc_as_if_utc

  defp wall_shift(wall_as_utc, {:named, z}) do
    # parse interpreted the wall clock as UTC; the real UTC is wall − offset
    {off, _, _} = PhpBeam.DtZone.offset_at(z, wall_as_utc)
    wall_as_utc - off
  end

  defp checkdate_v(vals, i) do
    case vals do
      [{:int, m}, {:int, d}, {:int, y} | _] ->
        ok? =
          m in 1..12 and y >= 1 and y <= 32767 and d >= 1 and d <= PhpBeam.Dt.days_in_month(y, m)

        {:ok, {:bool, ok?}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  ## ───────────────────────── procedural date helpers ─────────────────────────

  defp date_create_v(vals, i) do
    make_datetime(Enum.at(vals, 0, {:string, "now"}), Enum.at(vals, 1), "datetime", i)
  end

  defp date_create_immutable_v(vals, i) do
    make_datetime(Enum.at(vals, 0, {:string, "now"}), Enum.at(vals, 1), "datetimeimmutable", i)
  end

  defp date_create_from_format_v(vals, i) do
    fmt = PhpBeam.Eval.php_to_string(Enum.at(vals, 0, {:string, ""}))

    val =
      case Enum.at(vals, 1) do
        {:null, _} -> ""
        v -> PhpBeam.Eval.php_to_string(v)
      end

    base_tz = Map.get(i.ini, "date.timezone", "UTC")

    case PhpBeam.Dt.create_from_format(fmt, val, base_tz) do
      {:ok, dt} ->
        {oref, i2} = PhpBeam.Eval.make_instance(i, "datetime")
        o = PhpBeam.Eval.get_object(i2, oref)
        i3 = PhpBeam.Objects.put_object(i2, oref, dt_state_put(o, dt))
        {:ok, oref, i3}

      :error ->
        {:ok, {:bool, false}, i}
    end
  end

  defp make_datetime(time_v, tz_arg, class_key, i) do
    time = PhpBeam.Eval.php_to_string(time_v)

    tz_name =
      case tz_arg do
        {:object, _} = zref ->
          zobj = PhpBeam.Eval.get_object(i, zref)

          case Map.get(zobj, :dt_state) do
            %{"name" => {:string, n}} -> n
            _ -> "UTC"
          end

        _ ->
          case Map.get(i.ini, "date.timezone", "UTC") do
            "" -> "UTC"
            tz -> tz
          end
      end

    case PhpBeam.Dt.parse(time, tz_name) do
      {:ok, dt} ->
        {oref, i2} = PhpBeam.Eval.make_instance(i, class_key)
        o = PhpBeam.Eval.get_object(i2, oref)
        i3 = PhpBeam.Objects.put_object(i2, oref, dt_state_put(o, dt))
        {:ok, oref, i3}

      :error ->
        {oref2, i4} =
          PhpBeam.Eval.materialize_native(
            {:native_error, "Exception",
             "Failed to parse time string (#{time}) at position 0 (n): The timezone could not be found in the database"},
            i
          )

        {:ok, oref2, i4}
    end
  end

  defp dt_state_put(obj, %PhpBeam.Dt{} = dt),
    do: Map.put(obj, :dt_state, %{"dt" => dt})

  defp date_format_v(vals, i) do
    case vals do
      [{:object, _} = ref, {:string, fmt} | _] ->
        o = PhpBeam.Eval.get_object(i, ref)

        case dt_state_get(o) do
          %PhpBeam.Dt{} = dt -> {:ok, {:string, PhpBeam.Dt.format(dt, fmt)}, i}
          _ -> {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp dt_state_get(o) do
    case Map.get(o, :dt_state) do
      %{"dt" => %PhpBeam.Dt{} = dt} -> dt
      _ -> nil
    end
  end

  defp date_modify_v(vals, i) do
    case vals do
      [{:object, _} = ref, {:string, mod} | _] ->
        o = PhpBeam.Eval.get_object(i, ref)

        case dt_state_get(o) do
          %PhpBeam.Dt{} = dt ->
            case PhpBeam.Dt.apply_relative(dt, mod) do
              {:ok, dt2} ->
                i2 = PhpBeam.Objects.put_object(i, ref, dt_state_put(o, dt2))
                {:ok, ref, i2}

              :error ->
                {:ok, {:bool, false}, i}
            end

          _ ->
            {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp date_add_v(vals, i), do: date_shift(vals, i, 1)
  defp date_sub_v(vals, i), do: date_shift(vals, i, -1)

  defp date_shift(vals, i, sign) do
    case vals do
      [{:object, _} = ref, {:object, _} = iref | _] ->
        o = PhpBeam.Eval.get_object(i, ref)
        io = PhpBeam.Eval.get_object(i, iref)

        g = fn k, obj ->
          case PhpBeam.PArray.fetch(obj.props, {:string, k}) do
            {:ok, {:int, n}} -> n
            _ -> 0
          end
        end

        months = g.("y", io) * 12 + g.("m", io)
        secs = g.("h", io) * 3600 + g.("i", io) * 60 + g.("s", io) + g.("d", io) * 86_400

        case dt_state_get(o) do
          %PhpBeam.Dt{} = dt ->
            dt2 =
              dt
              |> then(fn d ->
                if months != 0, do: PhpBeam.Dt.add_months(d, sign * months), else: d
              end)
              |> then(fn d -> %{d | utc: d.utc + sign * secs} end)

            i2 = PhpBeam.Objects.put_object(i, ref, dt_state_put(o, dt2))
            {:ok, ref, i2}

          _ ->
            {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp date_diff_v(vals, i) do
    case vals do
      [{:object, _} = a, {:object, _} = b | _] ->
        oa = PhpBeam.Eval.get_object(i, a)
        ob = PhpBeam.Eval.get_object(i, b)

        with %PhpBeam.Dt{} = dta <- dt_state_get(oa),
             %PhpBeam.Dt{} = dtb <- dt_state_get(ob) do
          iv = PhpBeam.Dt.diff(dta, dtb)
          {iref, i2} = PhpBeam.Eval.make_instance(i, "dateinterval")
          iobj = PhpBeam.Eval.get_object(i2, iref)

          iobj2 =
            Enum.reduce(
              [
                {"y", {:int, iv.y}},
                {"m", {:int, iv.m}},
                {"d", {:int, iv.d}},
                {"h", {:int, iv.h}},
                {"i", {:int, iv.i}},
                {"s", {:int, iv.s}},
                {"days", {:int, iv.days}},
                {"invert", {:int, iv.invert}},
                {"f", {:float, 0.0}}
              ],
              iobj,
              fn {k, v}, acc ->
                case PhpBeam.PArray.put(acc.props, {:string, k}, v) do
                  {:ok, pr} -> %{acc | props: pr}
                  _ -> acc
                end
              end
            )

          i3 = PhpBeam.Objects.put_object(i2, iref, iobj2)
          {:ok, iref, i3}
        else
          _ -> {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp date_timestamp_get_v(vals, i) do
    case vals do
      [{:object, _} = ref | _] ->
        o = PhpBeam.Eval.get_object(i, ref)

        case dt_state_get(o) do
          %PhpBeam.Dt{utc: u} -> {:ok, {:int, u}, i}
          _ -> {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp date_timestamp_set_v(vals, i) do
    case vals do
      [{:object, _} = ref, {:int, ts} | _] ->
        o = PhpBeam.Eval.get_object(i, ref)

        case dt_state_get(o) do
          %PhpBeam.Dt{} = dt ->
            i2 = PhpBeam.Objects.put_object(i, ref, dt_state_put(o, %{dt | utc: ts, us: 0}))
            {:ok, ref, i2}

          _ ->
            {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp tz_version(_vals, i), do: {:ok, {:string, "2024.1"}, i}

  defp tz_open(vals, i) do
    case vals do
      [{:string, tz} | _] ->
        if PhpBeam.DtZone.valid?(tz) do
          {oref, i2} = PhpBeam.Eval.make_instance(i, "datetimezone")
          o = PhpBeam.Eval.get_object(i2, oref)
          o2 = Map.put(o, :dt_state, %{"name" => {:string, tz}})
          i3 = PhpBeam.Objects.put_object(i2, oref, o2)
          {:ok, oref, i3}
        else
          {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp tz_get(_vals, i) do
    case Map.get(i.ini, "date.timezone", "UTC") do
      "" -> {:ok, {:string, "UTC"}, i}
      tz -> {:ok, {:string, tz}, i}
    end
  end

  defp time_v(_vals, i), do: {:ok, {:int, System.system_time(:second)}, i}

  # common-format date(): Y-m-d H:i:s and friends (php-format matrix subset)
  @date_formats %{
    "Y-m-d H:i:s" => :ymd_his,
    "Y-m-d" => :ymd,
    "H:i:s" => :his,
    "Y" => :y,
    "c" => :iso8601,
    "U" => :epoch
  }

  defp date_v(vals, i) do
    fmt =
      case vals do
        [{:string, f} | _] -> f
        _ -> "Y-m-d H:i:s"
      end

    ts =
      case Enum.at(vals, 1) do
        {:int, t} -> t
        _ -> System.system_time(:second)
      end

    {:ok, {:string, PhpBeam.Dt.format(%PhpBeam.Dt{utc: ts, zone: dt_zone(i)}, fmt)}, i}
  end

  defp gmdate_v(vals, i) do
    fmt =
      case vals do
        [{:string, f} | _] -> f
        _ -> "Y-m-d H:i:s"
      end

    ts =
      case Enum.at(vals, 1) do
        {:int, t} -> t
        _ -> System.system_time(:second)
      end

    {:ok, {:string, PhpBeam.Dt.format(%PhpBeam.Dt{utc: ts, zone: {:utc}}, fmt)}, i}
  end

  defp dt_zone(i) do
    case Map.get(i.ini, "date.timezone", "UTC") do
      "" -> PhpBeam.Dt.zone_of("UTC")
      tz -> PhpBeam.Dt.zone_of(tz)
    end
  end

  defp calendar(ts) do
    {{y, mo, d}, {h, mi, s}} =
      :calendar.gregorian_seconds_to_datetime(ts + 62_167_219_200)

    {{y, mo, d}, {h, mi, s}}
  end

  defp cal2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp strtotime_v(vals, i) do
    str =
      case vals do
        [{:string, s} | _] -> s
        [v | _] -> PhpBeam.Eval.php_to_string(v)
        _ -> ""
      end

    base =
      case Enum.at(vals, 1) do
        {:int, t} -> %PhpBeam.Dt{utc: t, zone: dt_zone(i)}
        _ -> PhpBeam.Dt.now("UTC")
      end

    res =
      case PhpBeam.Dt.parse(str, "UTC") do
        {:ok, _} = ok -> ok
        :error -> PhpBeam.Dt.apply_relative(base, str)
      end

    case res do
      {:ok, dt} -> {:ok, {:int, dt.utc}, i}
      :error -> {:ok, {:bool, false}, i}
    end
  end

  defp setlocale(vals, i) do
    case Enum.drop(vals, 1) do
      [] ->
        {:ok, {:bool, false}, i}

      locales ->
        case Enum.find(locales, fn
               {:string, s} -> s != "" and s != "0"
               _ -> false
             end) do
          {:string, s} -> {:ok, {:string, s}, i}
          _ -> {:ok, {:bool, false}, i}
        end
    end
  end

  defp get_defined_functions(_vals, i) do
    {builtin, user} =
      i.functions
      |> Enum.split_with(fn {_k, v} -> match?(%{fun: _}, v) end)

    arr =
      PArray.from_pairs([
        {{:string, "internal"},
         {:array, PArray.from_pairs(Enum.map(Enum.sort(builtin), &{nil, {:string, elem(&1, 0)}}))}},
        {{:string, "user"},
         {:array, PArray.from_pairs(Enum.map(Enum.sort(user), &{nil, {:string, elem(&1, 0)}}))}}
      ])

    {:ok, {:array, arr}, i}
  end

  defp int_ini(i, key, default) do
    case Map.fetch(i.ini, key) do
      {:ok, v} when is_integer(v) -> v
      {:ok, v} when is_binary(v) -> String.to_integer(v)
      _ -> default
    end
  end

  defp debug_backtrace(_vals, i) do
    # frames mirror php's: file, line, function, args (approximated)
    frames =
      i.call_stack
      |> Enum.reverse()
      |> Enum.map(fn f ->
        {:array,
         PArray.from_pairs([
           {{:string, "file"}, {:string, f.file}},
           {{:string, "line"}, {:int, f.line}},
           {{:string, "function"},
            {:string, String.replace(PhpBeam.Interp.frame_func(f, i), ~r/\(.*\)/, "")}}
         ])}
      end)

    {:ok, {:array, PArray.from_pairs([{nil, {:array, PArray.new()}} | frames] |> tl)}, i}
  end
end
