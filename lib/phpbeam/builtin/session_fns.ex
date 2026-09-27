defmodule PhpBeam.Builtin.SessionFns do
  @moduledoc """
  ext/session — 23 functions with real file-backed storage (sess_<id> files
  in session.save_path, `key|serialize(value)` wire format). State rides the
  new `interp.session` map (request-scoped; fork_request resets it).

  Probed php 8.4 semantics: any output before session_start() fails it with
  the headers-sent warning; $_SESSION is UNDEFINED until start; re-start is
  a Notice + true; id/name/cookie-param setters refuse once headers are out
  or the session is active; session_unset() is false without a session.
  Custom save-handler objects are accepted but the files backend stays
  (registered deviation).
  """

  alias PhpBeam.Eval
  alias PhpBeam.Eval.Error
  alias PhpBeam.Interp
  alias PhpBeam.PArray

  @id_re ~r/\A[A-Za-z0-9,\-]{1,128}\z/

  def register(fns) do
    entries = %{
      "session_start" => &session_start/2,
      "session_status" => &session_status/2,
      "session_id" => &session_id/2,
      "session_name" => &session_name/2,
      "session_module_name" => &session_module_name/2,
      "session_save_path" => &session_save_path/2,
      "session_destroy" => &session_destroy/2,
      "session_write_close" => &session_write_close/2,
      "session_commit" => &session_write_close/2,
      "session_abort" => &session_abort/2,
      "session_reset" => &session_reset/2,
      "session_unset" => &session_unset/2,
      "session_encode" => &session_encode/2,
      "session_decode" => &session_decode/2,
      "session_regenerate_id" => &session_regenerate_id/2,
      "session_create_id" => &session_create_id/2,
      "session_gc" => &session_gc/2,
      "session_get_cookie_params" => &session_get_cookie_params/2,
      "session_set_cookie_params" => &session_set_cookie_params/2,
      "session_cache_limiter" => &session_cache_limiter/2,
      "session_cache_expire" => &session_cache_expire/2,
      "session_register_shutdown" => &session_register_shutdown/2,
      "session_set_save_handler" => &session_set_save_handler/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, wrapped)
  end

  # ────────────────────────── state ──────────────────────────

  def default_state do
    %{active: false, id: "", start_pos: nil, ever_started: false}
  end

  defp st(i), do: i.session || default_state()

  defp put_st(i, s), do: %{i | session: s}

  # ────────────────────────── warnings ──────────────────────────

  defp warn_ret(i, msg, ret) do
    case Error.warn(Error.stub_env(), i, msg) do
      {:cont, _, i2} -> {:ok, ret, i2}
      {:unwind, u, _, i2} -> {:unwind, u, i2}
    end
  end

  defp notice_ret(i, msg, ret) do
    case Error.warn_level(Error.stub_env(), i, "Notice", msg) do
      {:cont, _, i2} -> {:ok, ret, i2}
      {:unwind, u, _, i2} -> {:unwind, u, i2}
    end
  end

  # ────────────────────────── ini plumbing ──────────────────────────

  defp ini(i, key, default), do: Map.get(i.ini, key, default)

  defp save_path(i) do
    case ini(i, "session.save_path", "") do
      "" -> System.tmp_dir() || "/tmp"
      p -> p
    end
  end

  defp sess_file(i, id), do: Path.join(save_path(i), "sess_" <> id)

  # ────────────────────────── encode / decode ──────────────────────────

  defp encode_session(i) do
    case Map.get(i.globals, "_SESSION") do
      {:array, arr} ->
        PArray.to_pairs(arr)
        |> Enum.map_join(fn {k, v} ->
          to_string(k) <>
            key_sep(i) <> PhpBeam.Builtin.SerializeFns.serialize_value(v, i)
        end)

      _ ->
        ""
    end
  end

  defp key_sep(_i), do: "|"

  defp decode_into_session(i, data) do
    {pairs0, i2} = decode_pairs(data, 0, i, [])
    pairs = Enum.reverse(pairs0)

    globals = Map.get(i.globals, "_SESSION") || {:array, PArray.new()}

    arr =
      Enum.reduce(pairs, elem(globals, 1), fn {k, v}, acc ->
        case PArray.put(acc, {:string, k}, v) do
          {:ok, a} -> a
          _ -> acc
        end
      end)

    {:ok, %{i2 | globals: Map.put(i2.globals, "_SESSION", {:array, arr})}}
  end

  defp decode_pairs(data, off, i, acc) when off < byte_size(data) do
    case :binary.match(data, "|", scope: {off, byte_size(data) - off}) do
      {k_off, 1} ->
        key = binary_part(data, off, k_off - off)

        case PhpBeam.Builtin.SerializeFns.unserialize_value_at(data, k_off + 1, i) do
          {:ok, v, next, i2} ->
            decode_pairs(data, next, i2, [{key, v} | acc])

          {:error, _} ->
            {acc, i}
        end

      :nomatch ->
        {acc, i}
    end
  end

  defp decode_pairs(_data, _off, i, acc), do: {acc, i}

  # ────────────────────────── functions ──────────────────────────

  defp session_status(_vals, i) do
    s = if st(i).active, do: 2, else: 1
    {:ok, {:int, s}, i}
  end

  defp session_id(vals, i) do
    s = st(i)

    case vals do
      [v | _] ->
        new_id = id_str(v)

        cond do
          s.active ->
            warn_ret(i, "session_id(): Session ID cannot be changed when a session is active", {:bool, false})

          i.output_origin != nil ->
            warn_ret(i, "session_id(): Session ID cannot be changed after headers have already been sent", {:bool, false})

          true ->
            {:ok, {:string, s.id}, put_st(i, %{s | id: new_id})}
        end

      _ ->
        {:ok, {:string, s.id}, i}
    end
  end

  defp id_str(v) do
    case v do
      {:string, s} -> s
      {:int, n} -> Integer.to_string(n)
      _ -> ""
    end
  end

  defp session_name(vals, i) do
    s = st(i)

    case vals do
      [v | _] ->
        new_name =
          case v do
            {:string, n} -> n
            _ -> ini(i, "session.name", "PHPSESSID")
          end

        cond do
          s.active ->
            warn_ret(i, "session_name(): Session name cannot be changed when a session is active", {:bool, false})

          i.output_origin != nil ->
            warn_ret(i, "session_name(): Session name cannot be changed after headers have already been sent", {:bool, false})

          true ->
            {:ok, {:string, ini(i, "session.name", "PHPSESSID")},
             %{i | ini: Map.put(i.ini, "session.name", new_name)}}
        end

      _ ->
        {:ok, {:string, ini(i, "session.name", "PHPSESSID")}, i}
    end
  end

  defp session_module_name(vals, i) do
    case vals do
      [_v | _] ->
        if i.output_origin != nil do
          warn_ret(i, "session_module_name(): Session save handler module cannot be changed after headers have already been sent", {:bool, false})
        else
          {:ok, {:string, "files"}, i}
        end

      _ ->
        {:ok, {:string, "files"}, i}
    end
  end

  defp session_save_path(vals, i) do
    case vals do
      [v | _] ->
        new_path =
          case v do
            {:string, p} -> p
            _ -> ""
          end

        if i.output_origin != nil do
          warn_ret(i, "session_save_path(): Session save path cannot be changed after headers have already been sent", {:bool, false})
        else
          {:ok, {:string, ini(i, "session.save_path", "")},
           %{i | ini: Map.put(i.ini, "session.save_path", new_path)}}
        end

      _ ->
        {:ok, {:string, ini(i, "session.save_path", "")}, i}
    end
  end

  defp session_start(vals, i) do
    s = st(i)

    cond do
      s.active ->
        {f, l} = s.start_pos || {Interp.current_file(i), i.cur_line}
        notice_ret(i, "session_start(): Ignoring session_start() because a session is already active (started from #{f} on line #{l})", {:bool, true})

      i.output_origin != nil ->
        warn_ret(i, "session_start(): Session cannot be started after headers have already been sent", {:bool, false})

      true ->
        id = s.id

        if id != "" and not Regex.match?(@id_re, id) do
          i1 =
            case Error.warn(Error.stub_env(), i, "session_start(): Session ID is too long or contains illegal characters. Only the A-Z, a-z, 0-9, \"-\", and \",\" characters are allowed") do
              {:cont, _, i2} -> i2
              {:unwind, _, _, i2} -> i2
            end

          warn_ret(i1, "session_start(): Failed to read session data: files (path: #{save_path(i)})", {:bool, false})
        else
          do_start(i, s, id, vals)
        end
    end
  end

  defp do_start(i, s, id, vals) do
    id = if id == "", do: session_new_id(i), else: id
    path = sess_file(i, id)

    i0 =
      case Map.get(i.globals, "_SESSION") do
        nil -> %{i | globals: Map.put(i.globals, "_SESSION", {:array, PArray.new()})}
        _ -> i
      end

    i1 =
      if File.exists?(path) do
        case File.read(path) do
          {:ok, data} ->
            case decode_into_session(i0, data) do
              {:ok, i2} -> i2
              _ -> i0
            end

          _ ->
            i0
        end
      else
        i0
      end

    s2 = %{s | active: true, id: id, start_pos: {Interp.current_file(i1), i1.cur_line}, ever_started: true}
    i2 = put_st(i1, s2)

    # read_and_close: start then immediately persist + close
    read_and_close? = start_option(vals, "read_and_close")

    if read_and_close? do
      File.mkdir_p(save_path(i2))
      File.write(path, encode_session(i2))
      s3 = %{s2 | active: false}
      {:ok, {:bool, true}, put_st(i2, s3)}
    else
      {:ok, {:bool, true}, i2}
    end
  end

  defp start_option([{:array, arr} | _], key) do
    case PArray.fetch(arr, {:string, key}) do
      {:ok, v} -> PhpBeam.Value.truthy?(v)
      _ -> false
    end
  end

  defp start_option(_, _), do: false

  defp session_new_id(i) do
    charset = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ,-"

    1..32
    |> Enum.map_join(fn _ -> String.at(charset, :rand.uniform(String.length(charset)) - 1) end)
  end

  defp session_destroy(_vals, i) do
    s = st(i)

    if s.active do
      File.rm(sess_file(i, s.id))

      i2 =
        case Map.get(i.globals, "_SESSION") do
          nil -> i
          _ -> %{i | globals: Map.put(i.globals, "_SESSION", {:array, PArray.new()})}
        end

      {:ok, {:bool, true}, put_st(i2, %{s | active: false, id: ""})}
    else
      warn_ret(i, "session_destroy(): Trying to destroy uninitialized session", {:bool, false})
    end
  end

  defp write_file(i) do
    s = st(i)

    if s.active do
      File.mkdir_p(save_path(i))
      File.write(sess_file(i, s.id), encode_session(i))
    end

    :ok
  end

  defp session_write_close(_vals, i) do
    s = st(i)

    if s.active do
      write_file(i)
      {:ok, {:bool, true}, put_st(i, %{s | active: false})}
    else
      {:ok, {:bool, false}, i}
    end
  end

  defp session_abort(_vals, i) do
    s = st(i)

    if s.active do
      i2 =
        case Map.get(i.globals, "_SESSION") do
          nil -> i
          _ -> %{i | globals: Map.put(i.globals, "_SESSION", {:array, PArray.new()})}
        end

      {:ok, {:bool, true}, put_st(i2, %{s | active: false})}
    else
      {:ok, {:bool, false}, i}
    end
  end

  defp session_reset(_vals, i) do
    s = st(i)

    if s.active do
      path = sess_file(i, s.id)

      i2 =
        if File.exists?(path) do
          case File.read(path) do
            {:ok, data} ->
              i_empty = %{i | globals: Map.put(i.globals, "_SESSION", {:array, PArray.new()})}

              case decode_into_session(i_empty, data) do
                {:ok, i3} -> i3
                _ -> i
              end

            _ ->
              i
          end
        else
          %{i | globals: Map.put(i.globals, "_SESSION", {:array, PArray.new()})}
        end

      {:ok, {:bool, true}, i2}
    else
      {:ok, {:bool, false}, i}
    end
  end

  defp session_unset(_vals, i) do
    s = st(i)

    if s.active do
      i2 = %{i | globals: Map.put(i.globals, "_SESSION", {:array, PArray.new()})}
      {:ok, {:bool, true}, i2}
    else
      {:ok, {:bool, false}, i}
    end
  end

  defp session_encode(_vals, i) do
    s = st(i)

    if s.active do
      {:ok, {:string, encode_session(i)}, i}
    else
      if s.ever_started do
        # started-then-closed: php returns false silently (the warning only
        # fires when no session was ever started this request)
        {:ok, {:bool, false}, i}
      else
        warn_ret(i, "session_encode(): Cannot encode non-existent session", {:bool, false})
      end
    end
  end

  defp session_decode(vals, i) do
    s = st(i)

    case vals do
      [{:string, data} | _] ->
        if s.active do
          case decode_into_session(i, data) do
            {:ok, i2} -> {:ok, {:bool, true}, i2}
            _ -> {:ok, {:bool, false}, i}
          end
        else
          warn_ret(i, "session_decode(): Session data cannot be decoded when there is no active session", {:bool, false})
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp session_regenerate_id(vals, i) do
    s = st(i)

    if s.active do
      delete_old? =
        case vals do
          [v | _] -> PhpBeam.Value.truthy?(v)
          _ -> false
        end

      if delete_old?, do: File.rm(sess_file(i, s.id))

      new_id = session_new_id(i)
      s2 = %{s | id: new_id}
      i2 = put_st(i, s2)
      write_file(i2)
      {:ok, {:bool, true}, i2}
    else
      warn_ret(i, "session_regenerate_id(): Session ID cannot be regenerated when there is no active session", {:bool, false})
    end
  end

  defp session_create_id(_vals, i) do
    {:ok, {:string, session_new_id(i)}, i}
  end

  defp session_gc(_vals, i) do
    s = st(i)

    if s.active do
      max_life = ini_int(i, "session.gc_maxlifetime", 1440)
      now = System.system_time(:second)

      deleted = gc_scan(save_path(i), now - max_life)
      {:ok, {:int, deleted}, i}
    else
      warn_ret(i, "session_gc(): Session cannot be garbage collected when there is no active session", {:bool, false})
    end
  end

  defp gc_scan(path, cutoff) do
    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "sess_"))
        |> Enum.count(fn f ->
          p = Path.join(path, f)

          case File.stat(p, time: :posix) do
            {:ok, %{mtime: m}} when m < cutoff ->
              File.rm(p)
              true

            _ ->
              false
          end
        end)

      _ ->
        0
    end
  end

  defp session_get_cookie_params(_vals, i) do
    arr =
      PArray.from_pairs([
        {"lifetime", {:int, ini_int(i, "session.cookie_lifetime", 0)}},
        {"path", {:string, ini(i, "session.cookie_path", "/")}},
        {"domain", {:string, ini(i, "session.cookie_domain", "")}},
        {"secure", {:bool, ini(i, "session.cookie_secure", "") != "" and PhpBeam.Value.truthy?({:string, ini(i, "session.cookie_secure", "")})}},
        {"httponly", {:bool, ini(i, "session.cookie_httponly", "") != "" and PhpBeam.Value.truthy?({:string, ini(i, "session.cookie_httponly", "")})}},
        {"samesite", {:string, ini(i, "session.cookie_samesite", "")}}
      ])

    {:ok, {:array, arr}, i}
  end

  defp session_set_cookie_params(vals, i) do
    if i.output_origin != nil do
      warn_ret(i, "session_set_cookie_params(): Session cookie parameters cannot be changed after headers have already been sent", {:bool, false})
    else
      case vals do
        [{:array, arr} | _] ->
          i2 = apply_cookie_ini(i, arr)
          {:ok, {:bool, true}, i2}

        _ ->
          {:ok, {:bool, true}, i}
      end
    end
  end

  defp apply_cookie_ini(i, arr) do
    mapping = %{
      "lifetime" => "session.cookie_lifetime",
      "path" => "session.cookie_path",
      "domain" => "session.cookie_domain",
      "secure" => "session.cookie_secure",
      "httponly" => "session.cookie_httponly",
      "samesite" => "session.cookie_samesite"
    }

    ini2 =
      Enum.reduce(mapping, i.ini, fn {arr_key, ini_key}, acc ->
        case PArray.fetch(arr, {:string, arr_key}) do
          {:ok, v} ->
            Map.put(acc, ini_key, ini_val_str(v))

          _ ->
            acc
        end
      end)

    %{i | ini: ini2}
  end

  defp session_cache_limiter(vals, i) do
    case vals do
      [{:string, v} | _] ->
        if i.output_origin != nil do
          warn_ret(i, "session_cache_limiter(): Session cache limiter cannot be changed after headers have already been sent", {:bool, false})
        else
          {:ok, {:string, ini(i, "session.cache_limiter", "nocache")},
           %{i | ini: Map.put(i.ini, "session.cache_limiter", v)}}
        end

      _ ->
        {:ok, {:string, ini(i, "session.cache_limiter", "nocache")}, i}
    end
  end

  defp session_cache_expire(vals, i) do
    case vals do
      [v | _] ->
        if i.output_origin != nil do
          warn_ret(i, "session_cache_expire(): Session cache expiration cannot be changed after headers have already been sent", {:bool, false})
        else
          n =
            case v do
              {:int, n} -> n
              _ -> ini_int(i, "session.cache_expire", 180)
            end

          {:ok, {:int, ini_int(i, "session.cache_expire", 180)},
           %{i | ini: Map.put(i.ini, "session.cache_expire", Integer.to_string(n))}}
        end

      _ ->
        {:ok, {:int, ini_int(i, "session.cache_expire", 180)}, i}
    end
  end

  defp session_register_shutdown(_vals, i) do
    # the write itself happens for every active session at shutdown via
    # Finalize -> shutdown_write/1 (php's session RINIT registers it)
    {:ok, :null, i}
  end

  @doc "called from Eval.Finalize before user shutdown fns: persist if active"
  def shutdown_write(i) do
    s = st(i)

    if s.active do
      write_file(i)
      put_st(i, %{s | active: false})
    else
      i
    end
  end

  defp session_set_save_handler(vals, i) do
    case vals do
      [{:object, _} = ref | _] ->
        obj = Eval.get_object(i, ref)

        if is_map(obj) and Map.get(obj, :class) == "sessionhandler" do
          # custom handler stored but files backend stays (deviation)
          {:ok, {:bool, true}, put_st(i, Map.put(st(i), :handler, ref))}
        else
          type_error(i, "session_set_save_handler", "SessionHandlerInterface", "object")
        end

      _ ->
        type_error(i, "session_set_save_handler", "SessionHandlerInterface", "array")
    end
  end

  defp type_error(i, fname, want, got) do
    i2 = PhpBeam.Interp.push_frame(i, fname, [])

    {obj, i3} =
      Eval.materialize_native(
        {:native_error, "TypeError",
         "#{fname}(): Argument #1 ($open) must be of type #{want}, #{got} given"},
        i2
      )

    {:unwind, {:php_throw, obj}, i3}
  end

  # ────────────────────────── helpers ──────────────────────────

  defp ini_val_str(v) do
    case v do
      {:string, s} -> s
      {:int, n} -> Integer.to_string(n)
      {:bool, b} -> if b, do: "1", else: ""
      _ -> ""
    end
  end

  defp ini_int(i, key, default) do
    case Integer.parse(to_string(ini(i, key, Integer.to_string(default)))) do
      {n, _} -> n
      :error -> default
    end
  end
end
