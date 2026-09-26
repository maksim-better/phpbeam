defmodule PhpBeam.Http do
  @moduledoc """
  Minimal HTTP SAPI server (L0): `PhpBeam.Http.serve(docroot, port)` listens
  on gen_tcp — zero extra dependencies (hex is TLS-blocked on this network,
  so Plug is unavailable; a later milestone can swap this module for Plug
  without touching the interpreter, which only sees the request seeding and
  the SAPI response area).

  Per connection one BEAM process accepts, parses, and answers; each PHP
  execution gets a fresh interpreter seeded with CGI-style superglobals.
  Static files are served directly (never reach PHP). Directory requests
  resolve to index.php, php -S style.
  """

  require Logger

  @timeout 60_000

  def serve(docroot, port) do
    docroot = Path.absname(docroot)

    case :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true]) do
      {:ok, l} ->
        IO.puts("phpbeam serving #{docroot} on http://0.0.0.0:#{port}")
        accept_loop(l, docroot)

      {:error, :eaddrinuse} ->
        IO.puts(:stderr, "port #{port} already in use")
        System.halt(1)
    end
  end

  defp accept_loop(l, docroot) do
    case :gen_tcp.accept(l) do
      {:ok, sock} ->
        spawn(fn ->
          connection(sock, docroot)
          :gen_tcp.close(sock)
        end)

        accept_loop(l, docroot)

      {:error, :closed} ->
        :ok
    end
  end

  # keep-alive loop: HTTP/1.1 defaults persistent unless Connection: close;
  # HTTP/1.0 defaults close unless Connection: keep-alive (probed php -S)
  defp connection(sock, docroot, buf \\ "") do
    case read_request(sock, buf) do
      {:ok, head, rest} ->
        case parse_request(sock, head, rest) do
          {:ok, method, target, proto, headers, body, leftover} ->
            {status, rheaders, rbody, uploaded} =
              dispatch(docroot, method, target, proto, headers, body)

            keep? =
              case {proto, List.keyfind(headers, "connection", 0)} do
                {"HTTP/1.1", {_, v}} -> not String.contains?(String.downcase(v), "close")
                {"HTTP/1.1", _} -> true
                {_, {_, v}} -> String.contains?(String.downcase(v), "keep-alive")
                _ -> false
              end

            send_response(sock, status, rheaders, rbody, proto, keep?)
            cleanup_uploads(uploaded)

            if keep?, do: connection(sock, docroot, leftover)

          :error ->
            :ok
        end

      :error ->
        :ok
    end
  end

  # reads until the header terminator; returns {head, rest_after_headers}
  defp read_request(sock, buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_] ->
        case :gen_tcp.recv(sock, 0, @timeout) do
          {:ok, data} -> read_request(sock, buf <> data)
          _ -> :error
        end
    end
  end

  defp parse_request(sock, head, rest) do
    [request_line | header_lines] = String.split(head, "\r\n")

    case String.split(request_line, " ") do
      [method, target, proto] ->
        headers =
          header_lines
          |> Enum.map(fn line ->
            [k | rest2] = String.split(line, ":", parts: 2)
            {String.downcase(String.trim(k)), String.trim(Enum.join(rest2, ":"))}
          end)

        chunked? =
          headers
          |> List.keyfind("transfer-encoding", 0)
          |> case do
            {_, v} -> String.contains?(String.downcase(v), "chunked")
            nil -> false
          end

        cl =
          headers
          |> List.keyfind("content-length", 0)
          |> case do
            {_, v} -> String.to_integer(v)
            _ -> 0
          end

        if chunked? do
          case read_chunked(sock, rest) do
            {:ok, body, leftover} ->
              {:ok, method, target, proto, headers, body, leftover}

            :error ->
              :error
          end
        else
          {body, leftover} = read_body(sock, rest, cl)
          {:ok, method, target, proto, headers, body, leftover}
        end

      _ ->
        :error
    end
  end

  # full body read: keeps recv-ing until CL bytes arrived (long bodies
  # spanning packets were silently truncated pre-A4)
  defp read_body(sock, buf, cl) when byte_size(buf) >= cl,
    do: {binary_part(buf, 0, cl), binary_part(buf, cl, byte_size(buf) - cl)}

  defp read_body(sock, buf, cl) when cl > 8 * 1024 * 1024,
    # oversize bodies are refused (php -S post_max_size analog)
    do: {buf, ""}

  defp read_body(sock, buf, cl) do
    case :gen_tcp.recv(sock, 0, @timeout) do
      {:ok, data} -> read_body(sock, buf <> data, cl)
      _ -> {buf, ""}
    end
  end

  # chunked transfer decoding: size-line (hex; ignore extensions), chunk,
  # CRLF; terminal 0-chunk + optional trailers + CRLF
  defp read_chunked(sock, buf) do
    case decode_chunk(buf, "") do
      {:ok, body, rest} ->
        {:ok, body, rest}

      :more ->
        case :gen_tcp.recv(sock, 0, @timeout) do
          {:ok, data} -> read_chunked(sock, buf <> data)
          _ -> :error
        end

      :error ->
        :error
    end
  end

  defp decode_chunk(buf, acc) do
    case :binary.split(buf, "\r\n") do
      [size_line, rest] ->
        size =
          size_line
          |> String.split(";")
          |> hd()
          |> String.trim()
          |> Integer.parse(16)

        case size do
          {0, _} ->
            # no trailers: "0\r\n" is followed directly by "\r\n";
            # with trailers: lines then the blank line
            cond do
              rest == "\r\n" ->
                {:ok, acc, ""}

              String.starts_with?(rest, "\r\n") ->
                {:ok, acc, binary_part(rest, 2, byte_size(rest) - 2)}

              true ->
                case :binary.split(rest, "\r\n\r\n") do
                  [_, after_trailers] -> {:ok, acc, after_trailers}
                  _ -> :more
                end
            end

          {n, _} ->
            need = n + 2

            case rest do
              <<chunk::binary-size(n), "\r\n", rest2::binary>> ->
                decode_chunk(rest2, acc <> chunk)

              _ when byte_size(rest) < need ->
                :more

              _ ->
                :error
            end

          :error ->
            :error
        end

      [_] ->
        :more
    end
  end

  # ── dispatch ──

  # returns {status, headers, body, uploaded_tmp_paths} — the connection
  # loop cleans the uploaded temp files after the response is sent
  defp dispatch(docroot, method, target, proto, headers, body) do
    {path, query} =
      case String.split(target, "?", parts: 2) do
        [p, q] -> {p, q}
        [p] -> {p, ""}
      end

    rel = path |> URI.decode() |> sanitize_path()
    fs_path = Path.join(docroot, rel)

    cond do
      String.ends_with?(fs_path, ".php") and File.exists?(fs_path) ->
        run_php(fs_path, docroot, method, path, query, headers, body, proto)

      File.dir?(fs_path) ->
        index = Path.join(fs_path, "index.php")

        if File.exists?(index) do
          run_php(index, docroot, method, path, query, headers, body, proto)
        else
          not_found()
        end

      File.exists?(fs_path) ->
        {status, h, b} = serve_static(fs_path)
        {status, h, b, []}

      true ->
        # php -S behavior: unmatched paths fall back to the docroot's
        # index.php (its presence implies a front controller — Laravel's
        # public/index.php routing depends on this)
        front = Path.join(docroot, "index.php")

        if File.exists?(front) do
          run_php(front, docroot, method, path, query, headers, body, proto)
        else
          not_found()
        end
    end
  end

  defp not_found do
    {404, h, b} = {404, [{"Content-type", "text/html; charset=UTF-8"}], "Not Found"}
    {404, h, b, []}
  end

  defp cleanup_uploads(paths) do
    Enum.each(paths, &File.rm/1)
  end

  defp sanitize_path(p) do
    p
    |> String.split("/")
    |> Enum.reject(&(&1 in ["", "."]))
    |> Enum.flat_map(fn
      ".." -> []
      seg -> [seg]
    end)
    |> Enum.join("/")
  end

  defp serve_static(fs_path) do
    case File.read(fs_path) do
      {:ok, bin} ->
        {200,
         [
           {"Content-Type", static_mime(fs_path)},
           {"Content-Length", Integer.to_string(byte_size(bin))}
         ], bin}

      _ ->
        not_found()
    end
  end

  defp static_mime(path) do
    case Path.extname(path) |> String.downcase() do
      ".html" -> "text/html; charset=UTF-8"
      ".css" -> "text/css"
      ".js" -> "application/javascript"
      ".json" -> "application/json"
      ".svg" -> "image/svg+xml"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".ico" -> "image/x-icon"
      ".woff" -> "font/woff"
      ".woff2" -> "font/woff2"
      ".map" -> "application/json"
      ".txt" -> "text/plain; charset=UTF-8"
      _ -> "application/octet-stream"
    end
  end

  # php per-dir INI: .user.ini files apply from docroot down to the script's
  # directory (later files override), PERDIR-level entries only
  # (user_ini.filename default ".user.ini")
  defp user_ini_entries(fs_path, docroot) do
    doc_parts = Path.split(docroot)
    script_parts = Path.split(Path.dirname(fs_path))

    dirs =
      if List.starts_with?(script_parts, doc_parts) and length(script_parts) > length(doc_parts) do
        Enum.map(
          length(doc_parts)..(length(script_parts) - 1),
          &Path.join(Enum.take(script_parts, &1 + 1))
        )
      else
        [docroot]
      end

    entries =
      Enum.flat_map(dirs, fn dir ->
        path = Path.join(dir, ".user.ini")

        if File.exists?(path) do
          PhpBeam.Ini.parse_file(path)
        else
          []
        end
      end)

    %{}
    |> PhpBeam.Ini.apply_entries(entries, :perdir)
    |> Map.to_list()
  end

  # ── PHP execution ──

  defp run_php(fs_path, docroot, method, uri_path, query, headers, body, proto) do
    src = File.read!(fs_path)

    {post_pairs, file_entries} =
      if method in ~w(POST PUT PATCH) do
        case multipart_boundary(headers) do
          nil -> {parse_form(headers, body), []}
          boundary -> parse_multipart(body, boundary)
        end
      else
        {[], []}
      end

    {file_globals, uploaded_paths} = materialize_uploads(file_entries)

    globals =
      seed_globals(
        fs_path,
        docroot,
        method,
        uri_path,
        query,
        headers,
        body,
        post_pairs,
        file_globals,
        proto
      )

    sapi = %{headers: [], status: 200}
    user_ini = user_ini_entries(fs_path, docroot)

    task =
      Task.async(fn ->
        try do
          PhpBeam.Interp.run_http(
            src,
            PhpBeam.Interp.real_path(fs_path),
            globals,
            sapi,
            {:perdir, user_ini}
          )
        catch
          kind, reason ->
            msg = (match?(%_{message: m} when true, reason) && reason.message) || inspect(reason)
            IO.puts(:stderr, "phpbeam http internal (#{inspect(kind)}): #{msg}")
            {"", 255, nil}
        end
      end)

    case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, _exit, interp}} ->
        sapi_out = if interp, do: interp.sapi, else: sapi
        status = sapi_out.status
        # php always sends Content-Type for pages unless the script set one
        hdrs = normalize_headers(sapi_out.headers, out)
        {status, hdrs, out, uploaded_paths}

      {:exit, _} ->
        {500, [{"Content-Type", "text/plain"}], "phpbeam: script crashed", []}

      nil ->
        {504, [{"Content-Type", "text/plain"}], "phpbeam: execution timed out", []}
    end
  end

  defp multipart_boundary(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, ct} ->
        ct
        |> String.split(";")
        |> Enum.map(&String.trim/1)
        |> Enum.find_value(fn
          "boundary=" <> b -> b
          _ -> nil
        end)

      nil ->
        nil
    end
  end

  # multipart/form-data: parts split on --boundary; fields with filename
  # become $_FILES entries (written to sys temp, php naming shape), the
  # rest become $_POST pairs. name="a[b][]" nesting is preserved.
  defp parse_multipart(body, boundary) do
    delim = "--" <> boundary

    parts =
      body
      |> String.split(delim)
      |> Enum.reject(&(String.trim_leading(&1) == "--" or String.trim_leading(&1) == ""))
      |> Enum.map(&String.trim_leading(&1, "\r\n"))
      |> Enum.map(&trim_crlf_tail/1)

    Enum.reduce(parts, {[], []}, fn part, {posts, files} ->
      case :binary.split(part, "\r\n\r\n") do
        [part_headers, content] ->
          hs = parse_part_headers(part_headers)
          cd = hs["content-disposition"] || ""

          {name, filename, full_path, ctype} = part_meta(cd, hs["content-type"])

          case {name, filename} do
            {nil, _} ->
              {posts, files}

            {n, nil} ->
              {posts ++ [{n, content}], files}

            {n, fname} ->
              {posts,
               files ++
                 [
                   {n,
                    %{
                      name: fname,
                      full_path: fname,
                      type: ctype || "application/octet-stream",
                      size: byte_size(content),
                      content: content
                    }}
                 ]}
          end

        [_] ->
          {posts, files}
      end
    end)
  end

  defp trim_crlf_tail(s) do
    if String.ends_with?(s, "\r\n"), do: binary_part(s, 0, byte_size(s) - 2), else: s
  end

  defp parse_part_headers(hs) do
    hs
    |> String.split("\r\n")
    |> Map.new(fn line ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> {String.downcase(String.trim(k)), String.trim(v)}
        [k] -> {String.downcase(String.trim(k)), ""}
      end
    end)
  end

  # content-disposition: form-data; name="x"; filename="y" (+ full_path)
  # → {name, filename, full_path, content_type}
  defp part_meta(cd, ctype) do
    {name, filename, full_path} =
      cd
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reduce({nil, nil, nil}, fn seg, acc ->
        case seg do
          ~s(name=) <> quoted -> put_elem(acc, 0, unq(quoted))
          ~s(filename=) <> quoted -> put_elem(acc, 1, unq(quoted))
          ~s(full_path=) <> quoted -> put_elem(acc, 2, unq(quoted))
          _ -> acc
        end
      end)

    {name, filename, full_path || filename, ctype}
  end

  defp unq(~s(") <> rest), do: String.trim_trailing(rest, ~s("))
  defp unq(s), do: s

  # writes each upload to a php-shaped temp file; returns the $_FILES seed
  # structure (nested per php: same-name files fan out into parallel
  # name/type/tmp_name/... arrays) and the temp paths for cleanup
  defp materialize_uploads(entries) do
    dir = PhpBeam.Interp.real_path(System.tmp_dir!() || "/tmp")

    entries =
      Enum.map(entries, fn {name, meta} ->
        tmp = Path.join(dir, "php" <> php_tmp_suffix())
        File.write(tmp, meta.content)

        {name,
         %{
           name: meta.name,
           full_path: meta.full_path,
           type: meta.type,
           tmp_name: tmp,
           error: 0,
           size: meta.size
         }}
      end)

    tmp_paths = Enum.map(entries, fn {_n, m} -> m.tmp_name end)
    {build_files_global(entries), tmp_paths}
  end

  # php's shape: "php" + ~22 random chars (tests normalize tmp_name)
  defp php_tmp_suffix do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false) |> String.slice(0, 22)
  end

  # group entries by their name path: single file → flat field map;
  # multiple files under one name fan out php-style: each of
  # name/full_path/type/tmp_name/error/size becomes an indexed array
  defp build_files_global(entries) do
    grouped = Enum.group_by(entries, fn {name, _m} -> name end)

    Enum.map(grouped, fn {name, pairs} ->
      name = strip_trailing_brackets(name)
      metas = Enum.map(pairs, &elem(&1, 1))

      value =
        case metas do
          [one] ->
            {:array, files_field_map(one)}

          many ->
            {:array,
             PhpBeam.PArray.from_pairs(
               Enum.map([:name, :full_path, :type, :tmp_name, :error, :size], fn k ->
                 inner =
                   Enum.with_index(many, fn m, idx ->
                     v =
                       case k do
                         kk when kk in [:error, :size] -> {:int, Map.get(m, k)}
                         _ -> {:string, to_string(Map.get(m, k))}
                       end

                     {idx, v}
                   end)

                 {Atom.to_string(k), {:array, PhpBeam.PArray.from_pairs(inner)}}
               end)
             )}
        end

      {name, value}
    end)
  end

  # "up[]" groups into "up" (the parallel-arrays fan-out below carries the
  # multiplicity); "a[b][]" → "a[b]"
  defp strip_trailing_brackets(name) do
    if String.ends_with?(name, "[]"), do: binary_part(name, 0, byte_size(name) - 2), else: name
  end

  defp files_field_map(m) do
    PhpBeam.PArray.from_pairs([
      {"name", {:string, m.name}},
      {"full_path", {:string, m.full_path}},
      {"type", {:string, m.type}},
      {"tmp_name", {:string, m.tmp_name}},
      {"error", {:int, m.error}},
      {"size", {:int, m.size}}
    ])
  end

  defp normalize_headers(raw, body) do
    typed =
      raw
      |> Enum.map(fn h ->
        case :binary.split(h, ":") do
          [name, value] -> {String.trim(name), String.trim(value)}
          [name] -> {name, ""}
        end
      end)

    typed =
      if List.keyfind(typed, "Content-Type", 0) || List.keyfind(typed, "Content-type", 0) do
        typed
      else
        # php -S emits the script's headers first, defaults appended after
        typed ++ [{"Content-type", "text/html; charset=UTF-8"}]
      end

    typed ++ [{"Content-Length", Integer.to_string(byte_size(body))}]
  end

  # CGI-style superglobals, matching php -S closely enough for frameworks:
  # Laravel reads REQUEST_METHOD/REQUEST_URI/QUERY_STRING/HTTP_* primarily
  defp seed_globals(
         fs_path,
         docroot,
         method,
         uri_path,
         query,
         headers,
         body,
         post_pairs,
         file_globals,
         proto
       ) do
    docreal = PhpBeam.Interp.real_path(docroot)
    script = String.replace_prefix(PhpBeam.Interp.real_path(fs_path), docreal <> "/", "/")
    host = header_or(headers, "host", "localhost")
    now = System.system_time(:second)

    http_pairs =
      for {k, v} <- headers,
          k =~ ~r/^http[-_]/ or
            k in [
              "host",
              "content-type",
              "content-length",
              "cookie",
              "user-agent",
              "accept",
              "authorization"
            ] do
        case k do
          "host" -> {"HTTP_HOST", v}
          "content-type" -> {"CONTENT_TYPE", v}
          "content-length" -> {"CONTENT_LENGTH", v}
          other -> {String.upcase(String.replace(other, "-", "_")), v}
        end
      end

    server =
      [
        {"REQUEST_METHOD", {:string, method}},
        {"REQUEST_URI", {:string, uri_path <> if(query != "", do: "?" <> query, else: "")}},
        {"QUERY_STRING", {:string, query}},
        {"PATH_INFO", {:string, script}},
        {"SCRIPT_NAME", {:string, script}},
        {"SCRIPT_FILENAME", {:string, PhpBeam.Interp.real_path(fs_path)}},
        {"DOCUMENT_ROOT", {:string, docreal}},
        {"SERVER_NAME", {:string, hd(String.split(host, ":"))}},
        {"SERVER_PORT", {:string, String.split(host, ":") |> Enum.at(1) || "80"}},
        {"SERVER_PROTOCOL", {:string, "HTTP/1.1"}},
        {"SERVER_SOFTWARE", {:string, "phpbeam/http"}},
        {"REQUEST_TIME", {:int, now}},
        {"GATEWAY_INTERFACE", {:string, "CGI/1.1"}}
      ] ++
        Enum.map(http_pairs, fn {k, v} -> {k, {:string, v}} end)

    get = parse_query(query)
    post = if method in ~w(POST PUT PATCH), do: post_pairs, else: []
    cookies = parse_cookies(header_or(headers, "cookie", ""))

    %{
      "_SERVER" =>
        arr(
          List.keyreplace(
            server,
            "SERVER_PROTOCOL",
            0,
            {"SERVER_PROTOCOL", {:string, proto}}
          )
        ),
      "_GET" => nested_pairs(get),
      "_POST" => nested_pairs(post),
      "_COOKIE" => arr(Enum.map(cookies, fn {k, v} -> {{:string, k}, {:string, v}} end)),
      "_REQUEST" => nested_pairs(get ++ post),
      "_FILES" => nested_php_values(file_globals),
      # internal keys (NUL prefix: unreachable as PHP variable names);
      # php://input is EMPTY for multipart bodies (probed)
      "\0uploaded_files" => {:array, uploaded_tmp_paths(file_globals)},
      "\0input_body" =>
        {:string,
         if multipart_input_empty(headers) do
           ""
         else
           body
         end}
    }
  end

  defp multipart_input_empty(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, ct} -> String.starts_with?(String.downcase(String.trim(ct)), "multipart/")
      nil -> false
    end
  end

  # the request's uploaded tmp paths, as an internal (non-superglobal)
  # registry for is_uploaded_file/move_uploaded_file
  # nesting for pre-built PHP values ($_FILES): same key grammar
  defp nested_php_values(pairs) do
    pairs
    |> Enum.reduce([], fn {k, v}, acc -> php_nested_put(acc, split_key(k), v) end)
    |> nested_to_array()
  end

  # flat tmp-path strings (one entry per uploaded file); the globals map
  # wraps this in {:array, ...} exactly once
  defp uploaded_tmp_paths(file_globals) do
    paths =
      file_globals
      |> Enum.map(fn {_n, v} -> v end)
      |> Enum.flat_map(fn
        {:array, fm} = whole ->
          case PhpBeam.PArray.fetch(fm, {:string, "tmp_name"}) do
            # single file: field map holds the path directly
            {:ok, {:string, t}} ->
              [t]

            # multi file: tmp_name is an indexed array of paths
            {:ok, {:array, inner}} ->
              inner
              |> PhpBeam.PArray.values()
              |> Enum.map(fn {:string, t} -> t end)

            _ ->
              []
          end

        _ ->
          []
      end)

    PhpBeam.PArray.from_pairs(Enum.map(paths, &{nil, {:string, &1}}))
  end

  # php parse_str nesting: a=1 (last wins), a[]=1 (append), a[b]=1,
  # a[b][]=1 — insertion order preserved via an assoc list (Elixir maps
  # would scramble it)
  defp nested_pairs(pairs) do
    pairs
    |> Enum.reduce([], fn {k, v}, acc -> php_nested_put(acc, split_key(k), {:string, v}) end)
    |> nested_to_array()
  end

  defp assoc_put(list, k, v) do
    case List.keyfind(list, k, 0) do
      {^k, _} -> List.keyreplace(list, k, 0, {k, v})
      nil -> list ++ [{k, v}]
    end
  end

  defp split_key(k) do
    case :binary.split(k, "[") do
      [base] ->
        [base]

      [base, rest] ->
        # grammar: [seg][seg]… — split on ] leaves the next bracket's "["
        # prefixed to interior segments ("d][]" → ["d", "[", ""] before
        # stripping); the trailing artifact after the final ] is dropped
        segs =
          rest
          |> String.split("]")
          |> Enum.drop(-1)
          |> Enum.map(&String.trim_leading(&1, "["))

        [base | segs]
    end
  end

  defp php_nested_put(acc, [""], v) do
    # a[]=v appends at the next integer index
    next =
      acc
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> -1 end)
      |> Kernel.+(1)

    acc ++ [{next, v}]
  end

  defp php_nested_put(acc, [k], v), do: assoc_put(acc, k, v)

  defp php_nested_put(acc, [k | rest], v) do
    inner =
      List.keyfind(acc, k, 0)
      |> case do
        {^k, existing} -> existing
        nil -> []
      end

    assoc_put(acc, k, php_nested_put(inner, rest, v))
  end

  # assoc-list form; php arrays keep int and string keys side by side,
  # pure-int groups re-key to 0..n-1 by ascending value (a[]=… appends)
  defp nested_to_array([]), do: {:array, PhpBeam.PArray.new()}

  defp nested_to_array(list) do
    all_int? = Enum.all?(list, fn {k, _} -> is_integer(k) end)

    pairs =
      if all_int? do
        list
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.with_index(fn {_k, v}, idx -> {idx, nested_value(v)} end)
      else
        Enum.map(list, fn {k, v} -> {to_string(k), nested_value(v)} end)
      end

    {:array, PhpBeam.PArray.from_pairs(pairs)}
  end

  defp nested_value(v) when is_list(v), do: nested_to_array(v)
  defp nested_value(v), do: v

  defp header_or(headers, name, default) do
    case List.keyfind(headers, name, 0) do
      {_, v} -> v
      nil -> default
    end
  end

  defp arr(pairs), do: {:array, PhpBeam.PArray.from_pairs(pairs)}

  defp parse_query(q) do
    q
    |> String.split("&", trim: true)
    |> Enum.map(fn kv ->
      case String.split(kv, "=", parts: 2) do
        [k] -> {var_name(URI.decode_www_form(k)), ""}
        [k, v] -> {var_name(URI.decode_www_form(k)), URI.decode_www_form(v)}
      end
    end)
    |> Enum.reject(fn {k, _} -> k == "" end)
  end

  # php request-var names: outside the [] nesting, dots and spaces are
  # rewritten to underscores (parse_str legacy)
  defp var_name(k) do
    case :binary.split(k, "[") do
      [base] ->
        String.replace(base, [".", " "], "_")

      [base, _rest] ->
        String.replace(base, [".", " "], "_") <> String.slice(k, String.length(base)..-1//1)
    end
  end

  defp parse_form(headers, body) do
    case header_or(headers, "content-type", "") |> String.split(";") |> hd() |> String.trim() do
      "application/x-www-form-urlencoded" -> parse_query(body)
      _ -> []
    end
  end

  defp parse_cookies(""), do: []

  defp parse_cookies(cookie_hdr) do
    cookie_hdr
    |> String.split(";", trim: true)
    |> Enum.map(fn kv ->
      case String.split(kv, "=", parts: 2) do
        [k] -> {String.trim(k), ""}
        [k, v] -> {String.trim(k), String.trim(v)}
      end
    end)
  end

  # ── response ──

  defp send_response(sock, status, headers, body, proto, keep?) do
    reason = reason_phrase(status)
    proto = if proto == "HTTP/1.0", do: "HTTP/1.0", else: "HTTP/1.1"

    headers =
      if List.keyfind(headers, "Connection", 0) do
        headers
      else
        headers ++ [{"Connection", if(keep?, do: "keep-alive", else: "close")}]
      end

    head = ["#{proto} #{status} #{reason}" | Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end)]

    packet =
      Enum.join(head, "\r\n") <> "\r\n\r\n" <> body

    :gen_tcp.send(sock, packet)
  end

  defp reason_phrase(code) do
    %{
      200 => "OK",
      201 => "Created",
      204 => "No Content",
      301 => "Moved Permanently",
      302 => "Found",
      303 => "See Other",
      304 => "Not Modified",
      400 => "Bad Request",
      401 => "Unauthorized",
      403 => "Forbidden",
      404 => "Not Found",
      405 => "Method Not Allowed",
      419 => "Page Expired",
      422 => "Unprocessable Entity",
      500 => "Internal Server Error",
      502 => "Bad Gateway",
      504 => "Gateway Timeout"
    }[code] || "Status"
  end
end
