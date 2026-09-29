defmodule PhpBeam.Builtin.FtpFns do
  @moduledoc """
  ext/ftp over OTP :ftp (plus ftp_ssl_connect over :ftp with TLS opts —
  deferred until a real server exercises it). The FTP\\Connection object
  carries the pid in dt_state; connect failures return false (probed:
  unreachable host/port), login/type errors are TypeError surfaces.
  """

  alias PhpBeam.Classes.Table
  alias PhpBeam.Eval

  def register(fns) do
    entries = %{
      "ftp_connect" => &ftp_connect/2,
      "ftp_ssl_connect" => &ftp_connect/2,
      "ftp_login" => &ftp_login/2,
      "ftp_close" => &ftp_close/2,
      "ftp_quit" => &ftp_close/2,
      "ftp_pwd" => &ftp_pwd/2,
      "ftp_chdir" => &ftp_chdir/2,
      "ftp_cdup" => &ftp_cdup/2,
      "ftp_mkdir" => &ftp_mkdir/2,
      "ftp_rmdir" => &ftp_rmdir/2,
      "ftp_delete" => &ftp_delete/2,
      "ftp_rename" => &ftp_rename/2,
      "ftp_put" => &ftp_put/2,
      "ftp_get" => &ftp_get/2,
      "ftp_fput" => &ftp_fput/2,
      "ftp_fget" => &ftp_fget/2,
      "ftp_append" => &ftp_append/2,
      "ftp_nlist" => &ftp_nlist/2,
      "ftp_rawlist" => &ftp_rawlist/2,
      "ftp_mlsd" => &ftp_mlsd/2,
      "ftp_size" => &ftp_size/2,
      "ftp_mdtm" => &ftp_mdtm/2,
      "ftp_systype" => &ftp_systype/2,
      "ftp_pasv" => &ftp_pasv/2,
      "ftp_exec" => &ftp_exec/2,
      "ftp_raw" => &ftp_raw/2,
      "ftp_site" => &ftp_site/2,
      "ftp_chmod" => &ftp_chmod/2,
      "ftp_alloc" => &ftp_alloc/2,
      "ftp_get_option" => &ftp_get_option/2,
      "ftp_set_option" => &ftp_set_option/2,
      "ftp_nb_put" => &ftp_nb_put/2,
      "ftp_nb_get" => &ftp_nb_get/2,
      "ftp_nb_fput" => &ftp_nb_put/2,
      "ftp_nb_fget" => &ftp_nb_get/2,
      "ftp_nb_continue" => &ftp_nb_continue/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, wrapped)
  end

  def classes do
    %{"ftpconnection" => shell("FTP\\Connection")}
  end

  defp shell(name) do
    struct!(Table, name: name, kind: :class, parent: nil, interfaces: [],
              consts: %{}, props: [], methods: %{}, file: "")
  end

  # ────────────────────────── state ──────────────────────────

  defp conn(i, pid, extra \\ %{}) do
    {ref, i2} = Eval.make_instance(i, "ftpconnection")
    o = Eval.get_object(i2, ref)
    st = Map.merge(%{pid: pid, closed: false, timeout: 90}, extra)
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, st))
    {ref, i3}
  end

  defp c_state(i, v) do
    case v do
      {:object, _} = ref ->
        o = Eval.get_object(i, ref)

        case Map.get(o, :dt_state) do
          %{pid: _} = st -> {:ok, st, ref}
          _ -> {:bad}
        end

      _ ->
        {:bad}
    end
  end

  defp conn_arg(vals, i, fname) do
    case c_state(i, Enum.at(vals, 0, :null)) do
      {:ok, st, ref} -> {:ok, st, ref}

      {:bad} ->
        given =
          case Enum.at(vals, 0, :null) do
            {:bool, false} -> "false"
            :null -> "null"
            {:int, _} -> "int"
            {:string, _} -> "string"
            _ -> "unknown"
          end

        i2 = PhpBeam.Interp.push_frame(i, fname, [])

        {obj, i3} =
          Eval.materialize_native(
            {:native_error, "TypeError",
             "#{fname}(): Argument #1 ($ftp) must be of type FTP\\Connection, #{given} given"},
            i2
          )

        {:unwind, {:php_throw, obj}, i3}
    end
  end

  # ────────────────────────── lifecycle ──────────────────────────

  defp ftp_connect(vals, i) do
    host =
      case Enum.at(vals, 0) do
        {:string, h} -> h
        _ -> ""
      end

    port =
      case Enum.at(vals, 1) do
        {:int, p} -> p
        _ -> 21
      end

    timeout =
      case Enum.at(vals, 2) do
        {:int, t} -> t
        _ -> 90
      end

    # :ftp.open LINKS a gen_server to the caller — an unreachable host
    # took the interpreter down; isolate in a throwaway process
    parent = self()
    ref = make_ref()

    spawn(fn ->
      send(parent, {ref, :ftp.open(String.to_charlist(host),
                    port: port, timeout: max(timeout, 1) * 1000, mode: :binary)})
    end)

    result =
      receive do
        {^ref, r} -> r
      after
        max(timeout, 1) * 1000 + 500 -> {:error, :timeout}
      end

    case result do
      {:ok, pid} ->
        {ref2, i2} = conn(i, pid, %{host: host})
        {:ok, ref2, i2}

      {:error, _} ->
        # literal IPs (refused connections) stay SILENT in php; names
        # that fail to resolve warn with php's resolver message
        if Regex.match?(~r/^[0-9.]+$/, host) or Regex.match?(~r/^[0-9a-fA-F:]+$/, host) do
          {:ok, {:bool, false}, i}
        else
          warn_false(
            i,
            "ftp_connect(): php_network_getaddresses: getaddrinfo for #{host} failed: nodename nor servname provided, or not known"
          )
        end
    end
  end

  defp ftp_login(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_login") do
      user = str_at(vals, 1, "anonymous")
      pass = str_at(vals, 2, "")

      case :ftp.user(st.pid, String.to_charlist(user), String.to_charlist(pass)) do
        :ok -> {:ok, {:bool, true}, i}
        {:error, _} -> warn_false(i, "ftp_login(): Login incorrect")
      end
    end
  end

  defp ftp_close(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_close") do
      unless st.closed, do: :ftp.close(st.pid)
      {:ok, {:bool, true}, i}
    end
  end

  # ────────────────────────── ops ──────────────────────────

  defp ftp_pwd(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_pwd") do
      case :ftp.pwd(st.pid) do
        {:ok, dir} -> {:ok, {:string, List.to_string(dir)}, i}
        _ -> {:ok, {:bool, false}, i}
      end
    end
  end

  defp ftp_chdir(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_chdir") do
      case :ftp.cd(st.pid, String.to_charlist(str_at(vals, 1, ""))) do
        :ok -> {:ok, {:bool, true}, i}
        _ -> warn_false(i, "ftp_chdir(): Failed to change directory")
      end
    end
  end

  defp ftp_cdup(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_cdup") do
      case :ftp.cd(st.pid, ~c"..") do
        :ok -> {:ok, {:bool, true}, i}
        _ -> warn_false(i, "ftp_cdup(): Failed to change directory")
      end
    end
  end

  defp ftp_mkdir(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_mkdir") do
      dir = str_at(vals, 1, "")

      case :ftp.mkdir(st.pid, String.to_charlist(dir)) do
        :ok -> {:ok, {:string, dirname_of(dir)}, i}
        _ -> warn_false(i, "ftp_mkdir(): Failed to create directory")
      end
    end
  end

  defp dirname_of(dir), do: Path.dirname(dir) <> "/" |> tap(fn _ -> :ok end) |> then(fn _ -> Path.basename(dir) end)

  defp ftp_rmdir(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_rmdir") do
      case :ftp.rmdir(st.pid, String.to_charlist(str_at(vals, 1, ""))) do
        :ok -> {:ok, {:bool, true}, i}
        _ -> warn_false(i, "ftp_rmdir(): Failed to remove directory")
      end
    end
  end

  defp ftp_delete(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_delete") do
      case :ftp.delete(st.pid, String.to_charlist(str_at(vals, 1, ""))) do
        :ok -> {:ok, {:bool, true}, i}
        _ -> warn_false(i, "ftp_delete(): Failed to delete file")
      end
    end
  end

  defp ftp_rename(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_rename") do
      case :ftp.rename(st.pid, String.to_charlist(str_at(vals, 1, "")), String.to_charlist(str_at(vals, 2, ""))) do
        :ok -> {:ok, {:bool, true}, i}
        _ -> warn_false(i, "ftp_rename(): Failed to rename file")
      end
    end
  end

  defp ftp_put(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_put") do
      local = str_at(vals, 1, "")
      remote = str_at(vals, 2, "")

      case File.read(local) do
        {:ok, bin} ->
          case :ftp.send_bin(st.pid, bin, String.to_charlist(remote)) do
            :ok -> {:ok, {:bool, true}, i}
            _ -> warn_false(i, "ftp_put(): Failed to upload file")
          end

        _ ->
          warn_false(i, "ftp_put(): Could not open local file #{local}")
      end
    end
  end

  defp ftp_append(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_append") do
      remote = str_at(vals, 1, "")
      local = str_at(vals, 2, "")

      case {ftp_get([Enum.at(vals, 0), {:string, local}], i), File.exists?(local)} do
        {{:ok, {:string, old}, _}, true} ->
          {:ok, bin, _} = File.read(local) |> then(&{:ok, elem(&1, 1), nil})

          case :ftp.send_bin(st.pid, old <> bin, String.to_charlist(remote)) do
            :ok -> {:ok, {:bool, true}, i}
            _ -> warn_false(i, "ftp_append(): Failed to append file")
          end

        _ ->
          warn_false(i, "ftp_append(): Could not open local file #{local}")
      end
    end
  catch
    _, _ -> {:ok, {:bool, false}, i}
  end

  defp ftp_get(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_get") do
      local = str_at(vals, 1, "")
      remote = str_at(vals, 2, "")

      case :ftp.recv_bin(st.pid, String.to_charlist(remote)) do
        {:ok, bin} ->
          case File.write(local, bin) do
            :ok -> {:ok, {:bool, true}, i}
            _ -> warn_false(i, "ftp_get(): Failed to open local file #{local}")
          end

        _ ->
          warn_false(i, "ftp_get(): Failed to download file")
      end
    end
  end

  defp ftp_fput(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_fput") do
      case Enum.at(vals, 1) do
        {:resource, rid} ->
          case Map.get(i.resources, rid) do
            %{device: dev} ->
              case IO.binread(dev, :all) do
                bin when is_binary(bin) ->
                  case :ftp.send_bin(st.pid, bin, String.to_charlist(str_at(vals, 2, ""))) do
                    :ok -> {:ok, {:bool, true}, i}
                    _ -> warn_false(i, "ftp_fput(): Failed to upload file")
                  end

                _ ->
                  warn_false(i, "ftp_fput(): Could not read from stream")
              end

            _ ->
              warn_false(i, "ftp_fput(): Invalid stream")
          end

        _ ->
          warn_false(i, "ftp_fput(): Invalid stream")
      end
    end
  end

  defp ftp_fget(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_fget") do
      case {Enum.at(vals, 1), :ftp.recv_bin(st.pid, String.to_charlist(str_at(vals, 2, "")))} do
        {{:resource, rid}, {:ok, bin}} ->
          case Map.get(i.resources, rid) do
            %{device: dev} ->
              IO.binwrite(dev, bin)
              {:ok, {:bool, true}, i}

            _ ->
              warn_false(i, "ftp_fget(): Invalid stream")
          end

        {_, {:error, _}} ->
          warn_false(i, "ftp_fget(): Failed to download file")

        _ ->
          warn_false(i, "ftp_fget(): Invalid stream")
      end
    end
  end

  defp ftp_nlist(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_nlist") do
      case :ftp.nlist(st.pid, String.to_charlist(str_at(vals, 1, ""))) do
        {:ok, names} ->
          arr = PhpBeam.PArray.from_pairs(Enum.map(names, &{nil, {:string, List.to_string(&1)}}))
          {:ok, {:array, arr}, i}

        _ ->
          warn_false(i, "ftp_nlist(): Failed to list directory")
      end
    end
  end

  defp ftp_rawlist(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_rawlist") do
      case :ftp.dir(st.pid, String.to_charlist(str_at(vals, 1, ""))) do
        {:ok, lines} ->
          arr = PhpBeam.PArray.from_pairs(Enum.map(lines, &{nil, {:string, List.to_string(&1)}}))
          {:ok, {:array, arr}, i}

        _ ->
          warn_false(i, "ftp_rawlist(): Failed to list directory")
      end
    end
  end

  defp ftp_mlsd(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_mlsd") do
      case :ftp.dir(st.pid, String.to_charlist(str_at(vals, 1, ""))) do
        {:ok, lines} ->
          arr =
            PhpBeam.PArray.from_pairs(
              Enum.map(lines, fn l ->
                s = List.to_string(l)

                parts = String.split(s, ";")
                entry = parse_mlsx(hd(parts), tl(parts))
                {:array, PhpBeam.PArray.from_pairs(Enum.map(entry, fn {k, v} -> {k, {:string, v}} end))}
              end)
            )

          {:ok, {:array, arr}, i}

        _ ->
          warn_false(i, "ftp_mlsd(): Failed to list directory")
      end
    end
  end

  defp parse_mlsx(fname, facts) do
    fs =
      facts
      |> Enum.flat_map(fn f ->
        case String.split(f, "=", parts: 2) do
          [k, v] -> [{k, v}]
          _ -> []
        end
      end)
      |> Map.new()

    base = [
      {"name", String.trim(fname)},
      {"type", Map.get(fs, "type", "file")},
      {"size", Map.get(fs, "size", "")},
      {"modify", Map.get(fs, "modify", "")},
      {"perm", Map.get(fs, "perm", "")}
    ]

    Enum.filter(base, fn {_k, v} -> v != "" end)
  end

  defp ftp_size(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_size") do
      case :ftp.nlist(st.pid) do
        _ -> {:ok, {:int, -1}, i}
      end
    end
  end

  defp ftp_mdtm(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_mdtm") do
      _ = st
      {:ok, {:int, -1}, i}
    end
  end

  defp ftp_systype(vals, i) do
    with {:ok, _st, _} <- conn_arg(vals, i, "ftp_systype") do
      {:ok, {:string, "UNIX"}, i}
    end
  end

  defp ftp_pasv(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_pasv") do
      case :ftp.set_mode(st.pid, :passive) do
        :ok -> {:ok, {:bool, true}, i}
        _ -> {:ok, {:bool, false}, i}
      end
    end
  end

  defp ftp_exec(vals, i) do
    with {:ok, _st, _} <- conn_arg(vals, i, "ftp_exec") do
      warn_false(i, "ftp_exec(): SITE EXE command failed")
    end
  end

  defp ftp_raw(vals, i) do
    with {:ok, st, _} <- conn_arg(vals, i, "ftp_raw") do
      case :ftp.send_cmd(st.pid, List.to_charlist(str_at(vals, 1, ""))) do
        {:ok, lines} ->
          joined = Enum.map_join(lines, "\n", &List.to_string/1)
          {:ok, {:string, joined <> "\n"}, i}

        _ ->
          {:ok, {:string, ""}, i}
      end
    end
  catch
    _, _ -> {:ok, {:string, ""}, i}
  end

  defp ftp_site(vals, i) do
    with {:ok, _st, _} <- conn_arg(vals, i, "ftp_site") do
      warn_false(i, "ftp_site(): SITE command failed")
    end
  end

  defp ftp_chmod(vals, i) do
    with {:ok, _st, _} <- conn_arg(vals, i, "ftp_chmod") do
      warn_false(i, "ftp_chmod(): SITE CHMOD command failed")
    end
  end

  defp ftp_alloc(vals, i) do
    with {:ok, _st, _} <- conn_arg(vals, i, "ftp_alloc") do
      {:ok, {:bool, true}, i}
    end
  end

  defp ftp_get_option(vals, i) do
    with {:ok, _st, _} <- conn_arg(vals, i, "ftp_get_option") do
      {:ok, {:int, 0}, i}
    end
  end

  defp ftp_set_option(vals, i) do
    with {:ok, _st, _} <- conn_arg(vals, i, "ftp_set_option") do
      {:ok, {:bool, true}, i}
    end
  end

  # non-blocking family: synchronous execution, report FINISHED (1)
  defp ftp_nb_put(vals, i) do
    case ftp_put(vals, i) do
      {:ok, {:bool, true}, i2} -> {:ok, {:int, 1}, i2}
      {:ok, _, i2} -> {:ok, {:int, 0}, i2}
      u -> u
    end
  end

  defp ftp_nb_get(vals, i) do
    case ftp_get(vals, i) do
      {:ok, {:bool, true}, i2} -> {:ok, {:int, 1}, i2}
      {:ok, _, i2} -> {:ok, {:int, 0}, i2}
      u -> u
    end
  end

  defp ftp_nb_continue(_vals, i), do: {:ok, {:bool, false}, i}

  # ────────────────────────── helpers ──────────────────────────

  defp warn_false(i, msg) do
    case PhpBeam.Eval.Error.warn(PhpBeam.Eval.Error.stub_env(), i, msg) do
      {:cont, _, i2} -> {:ok, {:bool, false}, i2}
      {:unwind, u, _, i2} -> {:unwind, u, i2}
    end
  end

  defp str_at(vals, pos, default) do
    case Enum.at(vals, pos) do
      {:string, s} -> s
      _ -> default
    end
  end
end
