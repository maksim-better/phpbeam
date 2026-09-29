defmodule PhpBeam.Builtin.SocketsFns do
  @moduledoc """
  ext/sockets over OTP's :socket NIF (the closest analogue of BSD sockets).
  Socket objects carry the handle in dt_state. The loopback semantics are
  probed end-to-end (create_listen 0 → ephemeral port, connect/accept in
  one process, socketpair over a unix-domain temp path, binary vs normal
  read). macOS errno strings embedded for strerror.
  """

  alias PhpBeam.Classes.Table
  alias PhpBeam.Eval
  alias PhpBeam.PArray

  def register(fns) do
    entries = %{
      "socket_create" => &socket_create/2,
      "socket_create_listen" => &create_listen/2,
      "socket_create_pair" => &create_pair/2,
      "socket_bind" => &socket_bind/2,
      "socket_listen" => &socket_listen/2,
      "socket_accept" => &socket_accept/2,
      "socket_connect" => &socket_connect/2,
      "socket_close" => &socket_close/2,
      "socket_write" => &socket_write/2,
      "socket_send" => &socket_write/2,
      "socket_read" => &socket_read/2,
      "socket_recv" => &recv/2,
      "socket_sendto" => &sendto/2,
      "socket_recvfrom" => &recvfrom/2,
      "socket_shutdown" => &sock_shutdown/2,
      "socket_getpeername" => &getpeername/2,
      "socket_getsockname" => &getsockname/2,
      "socket_set_option" => &set_option/2,
      "socket_get_option" => &get_option/2,
      "socket_setopt" => &set_option/2,
      "socket_getopt" => &get_option/2,
      "socket_set_block" => &set_block/2,
      "socket_set_nonblock" => &set_nonblock/2,
      "socket_last_error" => &last_error/2,
      "socket_clear_error" => &clear_error/2,
      "socket_strerror" => &strerror/2,
      "socket_select" => &socket_select/2,
      "socket_export_stream" => &export_stream/2,
      "socket_import_stream" => &import_stream/2,
      "socket_addrinfo_lookup" => &addrinfo_stub/2,
      "socket_addrinfo_bind" => &addrinfo_stub/2,
      "socket_addrinfo_connect" => &addrinfo_stub/2,
      "socket_addrinfo_explain" => &addrinfo_stub/2,
      "socket_atmark" => &addrinfo_stub/2,
      "socket_cmsg_space" => &addrinfo_stub/2,
      "socket_recvmsg" => &addrinfo_stub/2,
      "socket_sendmsg" => &addrinfo_stub/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)
      |> Map.merge(%{
        "socket_getsockname" => %{
          fun: fn v, i, _c -> getsockname(v, i) end, refs: [1, 2], skip_eval_refs: [1, 2]
        },
        "socket_getpeername" => %{
          fun: fn v, i, _c -> getpeername(v, i) end, refs: [1, 2], skip_eval_refs: [1, 2]
        },
        "socket_recv" => %{fun: fn v, i, _c -> recv(v, i) end, refs: [1], skip_eval_refs: [1]},
        "socket_recvfrom" => %{
          fun: fn v, i, _c -> recvfrom(v, i) end, refs: [1, 2, 4], skip_eval_refs: [1, 2, 4]
        },
        "socket_create_pair" => %{
          fun: fn v, i, _c -> create_pair(v, i) end, refs: [3], skip_eval_refs: [3]
        }
      })

    Map.merge(fns, wrapped)
  end

  def classes do
    %{"socket" => shell("Socket")}
  end

  defp shell(name) do
    struct!(Table,
      name: name,
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{},
      file: ""
    )
  end

  # ────────────────────────── object plumbing ──────────────────────────

  # :socket accept/recv are blocking NIFs on the calling scheduler — run
  # them in a helper process and await with a timeout so the interpreter
  # can always make progress (php blocks the whole process; we cannot)
  defp sock_recv(st, want) do
    r = sock_async(fn -> :socket.recv(st.sock, want, 2500) end)
    if elem(r, 0) == :error, do: File.write!("/tmp/recv_err.txt", inspect(r))
    r
  end

  defp sock_async(fun, timeout \\ 5000) do
    parent = self()
    ref = make_ref()
    pid = spawn(fn -> send(parent, {ref, fun.()}) end)

    receive do
      {^ref, result} -> result
    after
      timeout -> {:error, :etimedout}
    end
  end

  defp new_socket(i, sock, extra \\ %{}) do
    {ref, i2} = Eval.make_instance(i, "socket")
    o = Eval.get_object(i2, ref)
    st = Map.merge(%{sock: sock, closed: false, err: 0, nonblock: false}, extra)
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, st))
    {ref, i3}
  end

  defp sock_state(i, v) do
    case v do
      {:object, _} = ref ->
        o = Eval.get_object(i, ref)

        case Map.get(o, :dt_state) do
          %{sock: sock} = st -> {:ok, st, ref}
          _ -> {:bad, ref}
        end

      _ ->
        {:bad, v}
    end
  end

  defp socket_bind(vals, i), do: sock_run(vals, i, &do_bind/3)
  defp socket_listen(vals, i), do: sock_run(vals, i, &do_listen/3)

  defp sock_run(vals, i, inner) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      inner.(st, vals, i)
    else
      u -> u
    end
  end

  defp check_sock(vals, i) do
    case sock_state(i, Enum.at(vals, 0, :null)) do
      {:ok, st, ref} -> {:ok, st, ref}
      {:bad, v} -> sock_type_error(i, v)
    end
  end

  defp sock_type_error(i, v) do
    given =
      case v do
        {:object, _} -> "Socket"
        {:int, _} -> "int"
        {:string, _} -> "string"
        :null -> "null"
        _ -> "unknown"
      end

    i2 = PhpBeam.Interp.push_frame(i, "socket", [])

    {obj, i3} =
      Eval.materialize_native(
        {:native_error, "TypeError", "socket(): Argument #1 ($socket) must be of type Socket, #{given} given"},
        i2
      )

    {:unwind, {:php_throw, obj}, i3}
  end

  # ────────────────────────── lifecycle ──────────────────────────

  @domains %{2 => :inet, 30 => :inet6, 1 => :local}
  @types %{1 => :stream, 2 => :dgram, 3 => :raw, 5 => :seqpacket}

  defp socket_create(vals, i) do
    dom = int_at(vals, 0)
    typ = int_at(vals, 1)

    with {:ok, d} <- dom_of(dom, i),
         {:ok, t} <- type_of(typ, i) do
      # lazy: the handle materializes at bind/listen/connect time
      {ref, i2} = new_socket(i, nil, %{domain: d, type: t})
      {:ok, ref, i2}
    end
  end

  defp dom_of(dom, i) do
    case Map.get(@domains, dom) do
      nil -> value_error(i, "socket_create(): Argument #1 ($domain) must be one of AF_UNIX, AF_INET6, or AF_INET")
      d -> {:ok, d}
    end
  end

  defp type_of(t, i) do
    case Map.get(@types, t) do
      nil -> value_error(i, "socket_create(): Argument #2 ($type) must be one of SOCK_STREAM, SOCK_DGRAM, SOCK_SEQPACKET, SOCK_RAW, or SOCK_RDM")
      x -> {:ok, x}
    end
  end

  defp value_error(i, msg) do
    i2 = PhpBeam.Interp.push_frame(i, "socket", [])
    {obj, i3} = Eval.materialize_native({:native_error, "ValueError", msg}, i2)
    {:unwind, {:php_throw, obj}, i3}
  end

  defp create_listen(vals, i) do
    port = int_at(vals, 0)

    with {:ok, :inet} <- dom_of(2, i),
         {:ok, :stream} <- type_of(1, i) do
      case :gen_tcp.listen(port, [:binary, {:active, false}, {:backlog, 128}, {:reuseaddr, true}]) do
        {:ok, srv} ->
          {ref, i2} = new_socket(i, srv, %{domain: :inet, type: :stream, listening: true})
          {:ok, ref, i2}

        {:error, _} ->
          warn_false(i, "socket_create_listen(): Unable to listen on socket")
      end
    else
      _ -> warn_false(i, "socket_create_listen(): protocol not supported")
    end
  end

  # socketpair via a unix-domain temp path (gen_tcp local sockets)
  defp create_pair(vals, i) do
    dom = int_at(vals, 0)
    typ = int_at(vals, 1)

    path = '/tmp/phpbeam_sp_' ++ :erlang.integer_to_list(:erlang.unique_integer([:positive]))

    with {:ok, :local} <- pair_dom(dom, i),
         {:ok, :stream} <- type_of(typ, i) do
      case :gen_tcp.listen(0, [:binary, {:active, false}, {:ifaddr, {:local, path}}]) do
        {:ok, srv} ->
          {:ok, port} = :inet.port(srv)

          case :gen_tcp.connect({:local, path}, 0, [:binary, {:active, false}], 3000) do
            {:ok, a} ->
              case :gen_tcp.accept(srv, 3000) do
                {:ok, b} ->
                  :gen_tcp.close(srv)
                  File.rm(List.to_string(path))

                  {ra, i2} = new_socket(i, a, %{domain: :local, type: :stream})
                  {rb, i3} = new_socket(i2, b, %{domain: :local, type: :stream})
                  arr = PArray.from_pairs([{0, ra}, {1, rb}])
                  {:ref_call, {:bool, true}, [nil, nil, nil, {:array, arr}], i3}

                {:error, _} ->
                  :gen_tcp.close(srv)
                  File.rm(List.to_string(path))
                  warn_false(i, "socket_create_pair(): Unable to create socket pair")
              end

            {:error, _} ->
              :gen_tcp.close(srv)
              File.rm(List.to_string(path))
              warn_false(i, "socket_create_pair(): Unable to create socket pair")
          end

        {:error, _} ->
          File.rm(List.to_string(path))
          warn_false(i, "socket_create_pair(): Unable to create socket pair")
      end
    end
  end

  defp pair_dom(1, i), do: {:ok, :local}

  defp pair_dom(_, i),
    do: value_error(i, "socket_create_pair(): Argument #1 ($domain) must be AF_UNIX")

  defp do_bind(st, vals, i) do
    addr = str_at(vals, 1, "0.0.0.0")
    port = int_at(vals, 2)

    with {:ok, srv} <-
           :gen_tcp.listen(port, [:binary, {:active, false}, {:ip, parse_addr(addr)}]) do
      o = note_sock(i, st, srv, %{listening: true})
      {:ok, {:bool, true}, o}
    else
      _ -> warn_false(i, "socket_bind(): Unable to bind address")
    end
  end

  defp do_listen(_st, _vals, i), do: {:ok, {:bool, true}, i}

  defp socket_accept(vals, i) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      case :gen_tcp.accept(st.sock, 4000) do
        {:ok, sock} ->
          {ref, i2} = new_socket(i, sock, %{domain: st.domain, type: st.type})
          {:ok, ref, i2}

        {:error, _} ->
          warn_false(i, "socket_accept(): Unable to accept incoming connection")
      end
    end
  end

  defp socket_connect(vals, i) do
    with {:ok, st, ref} <- check_sock(vals, i) do
      addr = str_at(vals, 1, "127.0.0.1")
      port = int_at(vals, 2)

      case :gen_tcp.connect(parse_addr(addr), port, [:binary, {:active, false}], 4000) do
        {:ok, sock} ->
          i2 = note_sock(i, st, sock, %{}, ref)
          {:ok, {:bool, true}, i2}

        {:error, _} ->
          warn_false(i, "socket_connect(): Unable to connect to address")
      end
    end
  end

  defp note_sock(i, st, sock, extra, ref \\ nil) do
    ref = ref || st.ref
    o = Eval.get_object(i, ref)
    st2 = Map.merge(Map.merge(st, %{sock: sock, closed: false}), extra)
    Eval.put_object(i, ref, Map.put(o, :dt_state, st2))
  end

  defp socket_close(vals, i) do
    with {:ok, st, ref} <- check_sock(vals, i) do
      if st.sock && !st.closed, do: :gen_tcp.close(st.sock)
      o = Eval.get_object(i, ref)
      i2 = Eval.put_object(i, ref, Map.put(o, :dt_state, Map.put(st, :closed, true)))
      {:ok, :null, i2}
    end
  end

  # ────────────────────────── io ──────────────────────────

  defp socket_write(vals, i) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      data = str_at(vals, 1, "")

      cond do
        st.sock == nil ->
          warn_false(i, "socket_write(): Unable to write to socket")

        true ->
          case :gen_tcp.send(st.sock, data) do
            :ok -> {:ok, {:int, byte_size(data)}, i}
            {:error, _} -> warn_false(i, "socket_write(): Unable to write to socket")
          end
      end
    end
  end

  defp socket_read(vals, i) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      len = int_at(vals, 1, 1024)
      mode = int_at(vals, 2, 1)

      if st.sock == nil do
        warn_false(i, "socket_read(): Unable to read from socket")
      else
        read_tcp(st, len, mode, <<>>, i)
      end
    end
  end

  defp read_tcp(st, len, mode, acc, i) do
    want = if(mode == 2, do: 0, else: len)

    case :gen_tcp.recv(st.sock, want, 2500) do
      {:ok, data} ->
        acc2 = acc <> data

        done? =
          case mode do
            2 -> String.contains?(acc2, "
") or String.contains?(acc2, "
")
            _ -> byte_size(acc2) >= len
          end

        if done? or byte_size(acc2) >= len do
          {:ok, {:string, trim_normal(acc2, mode)}, i}
        else
          read_tcp(st, len, mode, acc2, i)
        end

      {:error, :closed} ->
        if acc == "" do
          {:ok, {:bool, false}, i}
        else
          {:ok, {:string, trim_normal(acc, mode)}, i}
        end

      {:error, _} ->
        if acc == "" do
          {:ok, {:bool, false}, i}
        else
          {:ok, {:string, trim_normal(acc, mode)}, i}
        end
    end
  end

  defp trim_normal(s, 2), do: String.replace_suffix(String.replace_suffix(s, "
"), "
", "")
  defp trim_normal(s, _), do: s

  defp recv(vals, i) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      len = max(int_at(vals, 1, 0), 1)

      case :gen_tcp.recv(st.sock, 0, 2500) do
        {:ok, data} ->
          nv = List.replace_at(Enum.take(vals, 2), 1, {:string, data})
          {:ref_call, {:int, byte_size(data)}, nv, i}

        {:error, _} ->
          nv = List.replace_at(Enum.take(vals, 2), 1, {:string, ""})
          {:ref_call, {:bool, false}, nv, i}
      end
    end
  end

  defp sendto(vals, i) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      data = str_at(vals, 1, "")
      addr = str_at(vals, 3, "127.0.0.1")
      port = int_at(vals, 4, 0)

      # udp sendto via a one-shot socket (php udp sockets deferred)
      case :gen_udp.open(0, [:binary]) do
        {:ok, us} ->
          r = :gen_udp.send(us, parse_addr(addr), port, data)
          :gen_udp.close(us)

          case r do
            :ok -> {:ok, {:int, byte_size(data)}, i}
            _ -> warn_false(i, "socket_sendto(): Unable to send to address")
          end

        _ ->
          warn_false(i, "socket_sendto(): Unable to send to address")
      end
    end
  end

  defp recvfrom(vals, i) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      len = max(int_at(vals, 1, 0), 1)

      case :gen_tcp.recv(st.sock, 0, 2500) do
        {:ok, data} ->
          {:ok, {:string, data}, i}

        {:error, _} ->
          {:ok, {:bool, false}, i}
      end
    end
  end

  # ────────────────────────── options / names ──────────────────────────

  defp set_option(vals, i) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      opt = int_at(vals, 2, 0)
      val = Enum.at(vals, 3, :null)

      iopts =
        case {sol(int_at(vals, 1, 0)), sockopt(opt), val} do
          {:socket, :reuseaddr, v} -> [{:reuseaddr, PhpBeam.Value.truthy?(v)}]
          {:socket, :keepalive, v} -> [{:keepalive, PhpBeam.Value.truthy?(v)}]
          {:socket, :sndbuf, {:int, n}} -> [{:sndbuf, n}]
          {:socket, :rcvbuf, {:int, n}} -> [{:rcvbuf, n}]
          {:tcp, :nodelay, v} -> [{:nodelay, PhpBeam.Value.truthy?(v)}]
          _ -> []
        end

      case :inet.setopts(st.sock, iopts) do
        :ok -> {:ok, {:bool, true}, i}
        {:error, _} -> warn_false(i, "socket_set_option(): Unable to set socket option")
      end
    end
  end

  defp get_option(vals, i) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      iopt =
        case {sol(int_at(vals, 1, 0)), sockopt(int_at(vals, 2, 0))} do
          {:socket, :reuseaddr} -> :reuseaddr
          {:socket, :keepalive} -> :keepalive
          {:socket, :sndbuf} -> :sndbuf
          {:socket, :rcvbuf} -> :rcvbuf
          {:tcp, :nodelay} -> :nodelay
          _ -> nil
        end

      case iopt && :inet.getopts(st.sock, [iopt]) do
        [{^iopt, v}] -> {:ok, opt_val(v), i}
        :ok -> {:ok, {:int, 0}, i}
        nil -> {:ok, {:int, 0}, i}
        {:error, _} -> warn_false(i, "socket_get_option(): Unable to retrieve socket option")
        _ -> {:ok, {:int, 0}, i}
      end
    end
  end

  defp sol(65535), do: :socket
  defp sol(6), do: :tcp
  defp sol(17), do: :udp
  defp sol(_), do: :socket

  defp sockopt(opt) do
    case opt do
      4 -> :reuseaddr
      8 -> :keepalive
      16 -> :dontroute
      32 -> :broadcast
      128 -> :linger
      4097 -> :sndbuf
      4098 -> :rcvbuf
      4103 -> :error
      4104 -> :type
      1 -> :nodelay
      _ -> :error
    end
  end

  defp opt_val({on, sec}) do
    {:array,
     PArray.from_pairs([
       {"l_onoff", {:int, if(on, do: 1, else: 0)}},
       {"l_linger", {:int, sec}}
     ])}
  end

  defp opt_val(v) when is_integer(v), do: {:int, v}
  defp opt_val(v) when is_boolean(v), do: {:int, if(v, do: 1, else: 0)}
  defp opt_val(_), do: {:int, 0}

  defp getsockname(vals, i) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      case :inet.sockname(st.sock) do
        {:ok, sa} -> name_ref_call(vals, sa, i)
        {:error, _} -> warn_false(i, "socket_getsockname(): Unable to retrieve socket name")
      end
    end
  end

  defp getpeername(vals, i) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      case :inet.peername(st.sock) do
        {:ok, sa} -> name_ref_call(vals, sa, i)
        {:error, _} -> warn_false(i, "socket_getpeername(): Unable to retrieve peer name")
      end
    end
  end

  # php signature: getsockname($sock, &$addr, &$port) — :inet returns
  # {{a,b,c,d}, port} tuples
  defp name_ref_call(vals, sa, i) do
    {addr, port} = sa

    nv =
      vals
      |> Enum.take(3)
      |> List.replace_at(1, {:string, render_addr(addr)})
      |> List.replace_at(2, {:int, port})

    {:ref_call, {:bool, true}, nv, i}
  end

  defp parse_addr("0.0.0.0"), do: :any

  defp parse_addr(a) when is_binary(a) do
    case :inet.getaddr(String.to_charlist(a), :inet) do
      {:ok, t} -> t
      _ -> :any
    end
  end

  defp parse_addr(a), do: a

  defp render_addr(addr) do
    case addr do
      :any -> "0.0.0.0"
      :loopback -> "127.0.0.1"
      a when is_tuple(a) -> :inet.ntoa(a) |> List.to_string()
      a when is_binary(a) -> a
      _ -> "0.0.0.0"
    end
  catch
    _, _ -> "0.0.0.0"
  end

  defp sock_shutdown(vals, i) do
    with {:ok, st, _ref} <- check_sock(vals, i) do
      how =
        case int_at(vals, 1, 2) do
          0 -> :read
          1 -> :write
          _ -> :read_write
        end

      if st.sock == nil do
        warn_false(i, "socket_shutdown(): Unable to shutdown socket")
      else
        case :gen_tcp.shutdown(st.sock, how) do
          :ok -> {:ok, {:bool, true}, i}
          {:error, _} -> warn_false(i, "socket_shutdown(): Unable to shutdown socket")
        end
      end
    end
  end

  defp set_block(_vals, i), do: {:ok, {:bool, true}, i}
  defp set_nonblock(_vals, i), do: {:ok, {:bool, true}, i}

  defp last_error(vals, i) do
    case sock_state(i, Enum.at(vals, 0, :null)) do
      {:ok, st, _ref} -> {:ok, {:int, st.err || 0}, i}
      _ -> {:ok, {:int, 0}, i}
    end
  end

  defp clear_error(vals, i) do
    case sock_state(i, Enum.at(vals, 0, :null)) do
      {:ok, st, ref} ->
        o = Eval.get_object(i, ref)
        i2 = Eval.put_object(i, ref, Map.put(o, :dt_state, Map.put(st, :err, 0)))
        {:ok, :null, i2}

      _ ->
        {:ok, :null, i}
    end
  end

  @errno %{
    0 => "Undefined error: 0",
    1 => "Operation not permitted",
    2 => "No such file or directory",
    3 => "No such process",
    4 => "Interrupted system call",
    5 => "Input/output error",
    6 => "Device not configured",
    9 => "Bad file descriptor",
    11 => "Resource deadlock avoided",
    13 => "Permission denied",
    17 => "File exists",
    19 => "Operation not supported by device",
    22 => "Invalid argument",
    24 => "Too many open files",
    32 => "Broken pipe",
    35 => "Resource temporarily unavailable",
    36 => "Operation now in progress",
    37 => "Operation already in progress",
    38 => "Socket operation on non-socket",
    39 => "Destination address required",
    40 => "Message too long",
    41 => "Protocol wrong type for socket",
    42 => "Protocol not available",
    43 => "Protocol not supported",
    44 => "Socket type not supported",
    46 => "Protocol family not supported",
    47 => "Address family not supported by protocol family",
    48 => "Address already in use",
    49 => "Can't assign requested address",
    50 => "Network is down",
    51 => "Network is unreachable",
    52 => "Network dropped connection on reset",
    53 => "Software caused connection abort",
    54 => "Connection reset by peer",
    55 => "No buffer space available",
    56 => "Socket is already connected",
    57 => "Socket is not connected",
    58 => "Can't send after socket shutdown",
    60 => "Operation timed out",
    61 => "Connection refused",
    63 => "File name too long",
    64 => "Host is down",
    65 => "No route to host",
    100 => "Network is down",
    104 => "State not recoverable"
  }

  defp strerror(vals, i) do
    e = int_at(vals, 0, 0)
    {:ok, {:string, "Unknown error: " <> Integer.to_string(e) |> then(&Map.get(@errno, e, &1))}, i}
  end

  defp socket_select(_vals, i), do: {:ok, {:int, 0}, i}

  defp export_stream(_vals, i), do: {:ok, {:bool, false}, i}
  defp import_stream(_vals, i), do: {:ok, {:bool, false}, i}
  defp addrinfo_stub(_vals, i), do: {:ok, {:bool, false}, i}

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

  defp int_at(vals, pos, default \\ 0) do
    case Enum.at(vals, pos) do
      {:int, n} -> n
      _ -> default
    end
  end
end
