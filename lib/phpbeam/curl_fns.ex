defmodule PhpBeam.Builtin.CurlFns do
  @moduledoc """
  ext/curl over OTP :httpc + :ssl (file:// handled natively). The 679
  constants live in CurlConsts (php-dumped). CurlHandle carries url/opts/
  response/errno in dt_state; CURLOPT_* are stored until exec() assembles
  the httpc request. curl_multi/share families are sequential stubs.

  Probed semantics: exec on a file:// URL reads the file (ENOENT → errno
  37 "Could not open file X" — libcurl 8.18.0 wording); no URL set → errno 3; escape/unescape are
  RFC 3986; strerror uses libcurl's message table (major codes embedded).
  """

  alias PhpBeam.Classes.Table
  alias PhpBeam.Eval
  alias PhpBeam.PArray

  def register(fns) do
    entries = %{
      "curl_init" => &curl_init/2,
      "curl_close" => &curl_close/2,
      "curl_copy_handle" => &curl_copy/2,
      "curl_reset" => &curl_reset/2,
      "curl_setopt" => &curl_setopt/2,
      "curl_setopt_array" => &curl_setopt_array/2,
      "curl_exec" => &curl_exec/2,
      "curl_getinfo" => &curl_getinfo/2,
      "curl_errno" => &curl_errno/2,
      "curl_error" => &curl_error/2,
      "curl_strerror" => &curl_strerror/2,
      "curl_escape" => &curl_escape/2,
      "curl_unescape" => &curl_unescape/2,
      "curl_version" => &curl_version/2,
      "curl_file_create" => &curl_file_create/2,
      "curl_upkeep" => &noop_true/2,
      "curl_pause" => &noop_false/2,
      "curl_multi_init" => &multi_init/2,
      "curl_multi_add_handle" => &noop_true/2,
      "curl_multi_exec" => &multi_exec/2,
      "curl_multi_getcontent" => &multi_getcontent/2,
      "curl_multi_remove_handle" => &noop_true/2,
      "curl_multi_close" => &noop_true/2,
      "curl_multi_errno" => &multi_errno/2,
      "curl_multi_strerror" => &multi_strerror/2,
      "curl_multi_setopt" => &noop_true/2,
      "curl_multi_select" => &multi_select/2,
      "curl_share_init" => &share_init/2,
      "curl_share_setopt" => &noop_true/2,
      "curl_share_close" => &noop_true/2,
      "curl_share_errno" => &multi_errno/2,
      "curl_share_strerror" => &multi_strerror/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, wrapped)
  end

  def classes do
    %{
      "curlhandle" => shell("CurlHandle"),
      "curlmultihandle" => shell("CurlMultiHandle"),
      "curlsharehandle" => shell("CurlShareHandle"),
      "curlfile" => curlfile_class(),
      "curlstringfile" => curlfile_class()
    }
  end

  defp shell(name) do
    struct!(Table, name: name, kind: :class, parent: nil, interfaces: [],
              consts: %{}, props: [], methods: %{}, file: "")
  end

  defp curlfile_class do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, _a, i -> {:ok, :null, obj, i} end),
          nfn("getfilename", fn obj, _a, i ->
            {:ok, {:string, Map.get(Map.get(obj, :dt_state) || %{}, :filename, "")}, obj, i}
          end),
          nfn("getmimetype", fn obj, _a, i ->
            {:ok, {:string, Map.get(Map.get(obj, :dt_state) || %{}, :mime, "")}, obj, i}
          end),
          nfn("getpostfilename", fn obj, _a, i ->
            {:ok, {:string, Map.get(Map.get(obj, :dt_state) || %{}, :postname, "")}, obj, i}
          end)
        ],
        &{&1.name, &1}
      )

    struct!(Table, name: "CURLFile", kind: :class, parent: nil, interfaces: [],
              consts: %{}, props: [], methods: methods, file: "")
  end

  defp nfn(name, fun) do
    %{name: name, visibility: :public, static?: false, abstract?: false,
      final?: false, params: [], body: [], class: "curlfile", line: nil,
      gen?: false,
      native:
        {:native,
         fn obj, vals, i ->
           case fun.(obj, vals, i) do
             {:ok, ret, nil, i2} -> {:ok, {ret, obj}, i2}
             {:ok, ret, obj2, i2} -> {:ok, {ret, obj2}, i2}
           end
         end}}
  end

  # ────────────────────────── handle state ──────────────────────────

  defp new_handle(i, url \\ "") do
    {ref, i2} = Eval.make_instance(i, "curlhandle")
    o = Eval.get_object(i2, ref)
    st = %{url: url, opts: %{}, resp: nil, errno: 0, err: "", closed: false}
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, st))
    {ref, i3}
  end

  defp h_state(i, v) do
    case v do
      {:object, _} = ref ->
        o = Eval.get_object(i, ref)

        case Map.get(o, :dt_state) do
          %{url: _} = st -> {:ok, st, ref}
          _ -> {:bad}
        end

      _ ->
        {:bad}
    end
  end

  defp curl_init(vals, i) do
    url =
      case vals do
        [{:string, u} | _] -> u
        _ -> ""
      end

    {ref, i2} = new_handle(i, url)
    {:ok, ref, i2}
  end

  defp curl_close(vals, i) do
    case h_state(i, hd(vals || [:null])) do
      {:ok, st, ref} ->
        o = Eval.get_object(i, ref)
        i2 = Eval.put_object(i, ref, Map.put(o, :dt_state, Map.put(st, :closed, true)))
        {:ok, :null, i2}

      _ ->
        {:ok, :null, i}
    end
  end

  defp curl_copy(vals, i) do
    case h_state(i, hd(vals || [:null])) do
      {:ok, st, _} ->
        {ref, i2} = new_handle(i, st.url)
        o = Eval.get_object(i2, ref)
        i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, %{st | resp: nil, errno: 0, err: ""}))
        {:ok, ref, i3}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp curl_reset(vals, i) do
    case h_state(i, hd(vals || [:null])) do
      {:ok, st, ref} ->
        o = Eval.get_object(i, ref)
        i2 = Eval.put_object(i, ref, Map.put(o, :dt_state, %{st | opts: %{}, url: ""}))
        {:ok, {:bool, true}, i2}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  # ────────────────────────── options ──────────────────────────

  # the CURLOPT_* ids CurlConsts carries; map the exec-relevant subset
  @opt_url 10_002
  @opt_returntransfer 19_913
  @opt_post 47
  @opt_postfields 10_015
  @opt_httpheader 10_023
  @opt_timeout 13
  @opt_customrequest 10_036
  @opt_useragent 10_018
  @opt_followlocation 52
  @opt_ssl_verifypeer 64
  @opt_ssl_verifyhost 81
  @opt_httpcode 2_097_154
  @info_effective_url 1_048_577
  @info_http_code 2_097_154

  defp curl_setopt(vals, i) do
    with {:ok, st, ref} <- h_state(i, Enum.at(vals, 0, :null)) do
      opt = int_at(vals, 1)
      val = Enum.at(vals, 2, :null)

      st2 =
        case opt do
          @opt_url -> %{st | url: val_str(val)}
          _ -> %{st | opts: Map.put(st.opts, opt, val)}
        end

      o = Eval.get_object(i, ref)
      i2 = Eval.put_object(i, ref, Map.put(o, :dt_state, st2))
      {:ok, {:bool, true}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp curl_setopt_array(vals, i) do
    with {:ok, st, ref} <- h_state(i, Enum.at(vals, 0, :null)),
         {:array, arr} <- Enum.at(vals, 1, :null) do
      {url, opts} =
        PArray.to_pairs(arr)
        |> Enum.reduce({st.url, st.opts}, fn {k, v}, {u, os} ->
          case k do
            @opt_url when is_integer(k) -> {val_str(v), os}
            _ -> {u, Map.put(os, k, v)}
          end
        end)

      o = Eval.get_object(i, ref)
      i2 = Eval.put_object(i, ref, Map.put(o, :dt_state, %{st | url: url, opts: opts}))
      {:ok, {:bool, true}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  catch
    _, _ -> {:ok, {:bool, false}, i}
  end

  # ────────────────────────── exec ──────────────────────────

  defp curl_exec(vals, i) do
    with {:ok, st, ref} <- h_state(i, Enum.at(vals, 0, :null)) do
      case exec_request(st, i) do
        {:ok, body, status, headers} ->
          st2 =
            st
            |> Map.put(:resp, body)
            |> Map.put(:errno, 0)
            |> Map.put(:err, "")
            |> Map.put(:status, status)
            |> Map.put(:headers, headers)
          o = Eval.get_object(i, ref)
          i2 = Eval.put_object(i, ref, Map.put(o, :dt_state, st2))

          out =
            if truthy_opt(st.opts[@opt_returntransfer]) do
              {:string, body}
            else
              PhpBeam.Interp.write(i2, body)
              {:bool, true}
            end

          case out do
            {:string, s} -> {:ok, {:string, s}, i2}
            b -> {:ok, b, i2}
          end

        {:error, errno, msg} ->
          st2 = %{st | errno: errno, err: msg}
          o = Eval.get_object(i, ref)
          i2 = Eval.put_object(i, ref, Map.put(o, :dt_state, st2))
          {:ok, {:bool, false}, i2}
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp exec_request(st, i) do
    url = st.url

    cond do
      url == "" ->
        {:error, 3, "No URL set"}

      String.starts_with?(url, "file://") ->
        path = String.replace_prefix(url, "file://", "")

        case File.read(path) do
          {:ok, bin} -> {:ok, bin, 0, []}
          _ -> {:error, 37, "Could not open file " <> path}
        end

      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
        http_request(st, url)

      true ->
        _ = i
        {:error, 1, "Unsupported protocol"}
    end
  end

  defp http_request(st, url) do
    :ssl.start()
    :inets.start()

    method =
      if truthy_opt(st.opts[@opt_post]) or Map.has_key?(st.opts, @opt_postfields) do
        :post
      else
        :get
      end

    headers = header_list(st.opts[@opt_httpheader])

    body =
      case st.opts[@opt_postfields] do
        {:string, b} -> b
        _ -> []
      end

    req = {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", body}

    ssl_opts =
      if truthy_opt(st.opts[@opt_ssl_verifypeer]) do
        [ssl: [verify: :verify_peer, depth: 3]]
      else
        [ssl: [verify: :verify_none]]
      end

    opts =
      ssl_opts ++
        case int_opt(st.opts[@opt_timeout]) do
          nil -> []
          t -> [timeout: t * 1000]
        end

    case :httpc.request(method, req, opts, body_format: :binary) do
      {:ok, {{_, code, _}, hdrs, resp_body}} ->
        {:ok, IO.iodata_to_binary(resp_body), code, hdrs}

      {:error, _} ->
        {:error, 6, "Could not resolve hostname"}
    end
  catch
    _, _ -> {:error, 6, "Could not resolve hostname"}
  end

  defp header_list({:array, arr}) do
    PArray.values(arr)
    |> Enum.map(fn
      {:string, s} -> String.split(s, ":", parts: 2) |> then(fn [k | v] -> {String.to_charlist(String.trim(k)), String.to_charlist(String.trim(Enum.join(v, "")))} end)
    end)
  catch
    _, _ -> []
  end

  defp header_list(_), do: []

  # ────────────────────────── info / errors ──────────────────────────

  defp curl_getinfo(vals, i) do
    with {:ok, st, _} <- h_state(i, Enum.at(vals, 0, :null)) do
      what = int_at(vals, 1)

      v =
        case what do
          0 -> {:int, 0}
          @info_http_code -> {:int, Map.get(st, :status, 0)}
          @info_effective_url -> {:string, st.url}
          _ -> {:string, ""}
        end

      {:ok, v, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp curl_errno(vals, i) do
    case h_state(i, hd(vals || [:null])) do
      {:ok, st, _} -> {:ok, {:int, st.errno}, i}
      _ -> {:ok, {:int, 0}, i}
    end
  end

  defp curl_error(vals, i) do
    case h_state(i, hd(vals || [:null])) do
      {:ok, st, _} -> {:ok, {:string, st.err}, i}
      _ -> {:ok, {:string, ""}, i}
    end
  end

  @curle %{
    0 => "No error",
    1 => "Unsupported protocol",
    3 => "URL using bad/illegal format or missing URL",
    6 => "Could not resolve hostname",
    7 => "Couldn't connect to server",
    22 => "HTTP response code said error",
    28 => "Operation was timed out",
    35 => "SSL connect error",
    37 => "Could not read a file:// file",
    47 => "Too many redirects",
    60 => "Peer certificate cannot be authenticated with given CA certificates",
    77 => "Problem with the SSL CA cert (path? access rights?)"
  }

  defp curl_strerror(vals, i) do
    e = int_at(vals, 0, 0)
    {:ok, {:string, Map.get(@curle, e, "Unknown error #{e} <> (#{e})") |> String.replace(" <> (#{e})", "")}, i}
  end

  defp curl_escape(vals, i) do
    with {:ok, _, _} <- h_state(i, Enum.at(vals, 0, :null)) do
      s = val_str(Enum.at(vals, 1, {:string, ""}))
      {:ok, {:string, URI.encode(s, &URI.char_unreserved?/1)}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp curl_unescape(vals, i) do
    with {:ok, _, _} <- h_state(i, Enum.at(vals, 0, :null)) do
      s = val_str(Enum.at(vals, 1, {:string, ""}))
      {:ok, {:string, URI.decode(s)}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  # probed from the local php's libcurl 8.18.0
  defp curl_version(_vals, i) do
    arr =
      PArray.from_pairs([
        {"version", {:string, "8.18.0"}},
        {"version_number", {:int, 528_896}},
        {"ssl_version_number", {:int, 0}},
        {"host", {:string, "aarch64-apple-darwin24.6.0"}},
        {"age", {:int, 10}},
        {"features", {:int, 10_597_951}},
        {"ssl_version", {:string, "(SecureTransport) LibreSSL/3.3"}},
        {"libz_version", {:string, "1.2.12"}},
        {"protocols",
         {:array,
          PArray.from_pairs(
            Enum.map(~w(dict file ftp ftps gopher gophers http https imap imaps ipfs ipns mqtt pop3 pop3s rtsp smb smbs smtp smtps telnet tftp ws wss), &{nil, {:string, &1}})
          )}},
        {"ares", {:string, "1.34.4"}},
        {"ares_num", {:int, 0}},
        {"libidn", {:string, "2.13.0"}},
        {"iconv_ver_num", {:int, 0}},
        {"libssh_version", {:string, "libssh2/1.11.1"}}
      ])

    {:ok, {:array, arr}, i}
  end

  defp curl_file_create(vals, i) do
    filename = val_str(Enum.at(vals, 0, {:string, ""}))
    mime = val_str(Enum.at(vals, 1, {:string, "application/octet-stream"}))
    postname = val_str(Enum.at(vals, 2, {:string, filename}))

    {ref, i2} = Eval.make_instance(i, "curlfile")
    o = Eval.get_object(i2, ref)
    st = %{filename: filename, mime: mime, postname: postname}
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, st))
    {:ok, ref, i3}
  end

  # ────────────────────────── multi / share stubs ──────────────────────────

  defp multi_init(_vals, i) do
    {ref, i2} = Eval.make_instance(i, "curlmultihandle")
    o = Eval.get_object(i2, ref)
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, %{handles: [], contents: %{}}))
    {:ok, ref, i3}
  end

  defp share_init(_vals, i) do
    {ref, i2} = Eval.make_instance(i, "curlsharehandle")
    o = Eval.get_object(i2, ref)
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, %{}))
    {:ok, ref, i3}
  end

  defp multi_exec(vals, i) do
    case vals do
      [{:object, _} = mref | rest] ->
        o = Eval.get_object(i, mref)
        st = Map.get(o, :dt_state) || %{handles: [], contents: %{}}

        still =
          case rest do
            [{:array, _} = arr_v | _] ->
              {:array, arr} = arr_v
              PArray.values(arr)

            _ ->
              []
          end

        # run every pending handle SEQUENTIALLY (php runs them parallel;
        # output parity holds for independent requests)
        contents =
          Enum.reduce(st.handles, st.contents, fn h, acc ->
            case curl_exec([h], i) do
              {:ok, {:string, body}, _} -> Map.put(acc, h, body)
              _ -> Map.put(acc, h, "")
            end
          end)

        i2 = Eval.put_object(i, mref, Map.put(o, :dt_state, %{st | contents: contents}))
        {:ref_call, {:int, 0}, [hd(vals), {:int, 1}, nil], i2}

      _ ->
        {:ok, {:int, 0}, i}
    end
  catch
    _, _ -> {:ok, {:int, 0}, i}
  end

  defp multi_getcontent(vals, i) do
    case vals do
      [{:object, _} = mref, href | _] ->
        o = Eval.get_object(i, mref)
        st = Map.get(o, :dt_state) || %{contents: %{}}
        {:ok, {:string, Map.get(st.contents, href, "")}, i}

      _ ->
        {:ok, {:string, ""}, i}
    end
  catch
    _, _ -> {:ok, {:string, ""}, i}
  end

  defp multi_errno(_vals, i), do: {:ok, {:int, 0}, i}
  defp multi_strerror(vals, i), do: curl_strerror(vals, i)
  defp multi_select(_vals, i), do: {:ok, {:int, 0}, i}
  defp noop_true(_vals, i), do: {:ok, {:bool, true}, i}
  defp noop_false(_vals, i), do: {:ok, {:bool, false}, i}

  # ────────────────────────── helpers ──────────────────────────

  defp val_str({:string, s}), do: s
  defp val_str(_), do: ""

  defp int_at(vals, pos, default \\ 0) do
    case Enum.at(vals, pos) do
      {:int, n} -> n
      _ -> default
    end
  end

  defp int_opt({:int, n}), do: n
  defp int_opt(_), do: nil

  defp truthy_opt(v), do: v != nil and PhpBeam.Value.truthy?(v)
end
