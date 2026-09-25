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

  # one request per connection (Connection: close) — enough for curl and
  # browsers' first loads; keep-alive is a later refinement
  defp connection(sock, docroot) do
    with {:ok, req} <- read_request(sock),
         {:ok, method, target, headers, body} <- parse_request(req) do
      {status, rheaders, rbody} = dispatch(docroot, method, target, headers, body)
      send_response(sock, status, rheaders, rbody)
    else
      _ -> :ok
    end
  end

  defp read_request(sock, buf \\ "") do
    if String.contains?(buf, "\r\n\r\n") do
      {:ok, buf}
    else
      case :gen_tcp.recv(sock, 0, @timeout) do
        {:ok, data} -> read_request(sock, buf <> data)
        _ -> :error
      end
    end
  end

  defp parse_request(req) do
    [head, body] = :binary.split(req, "\r\n\r\n")
    [request_line | header_lines] = String.split(head, "\r\n")

    case String.split(request_line, " ") do
      [method, target, _proto] ->
        headers =
          header_lines
          |> Enum.map(fn line ->
            [k | rest] = String.split(line, ":", parts: 2)
            {String.downcase(String.trim(k)), String.trim(Enum.join(rest, ":"))}
          end)

        cl =
          headers
          |> List.keyfind("content-length", 0)
          |> case do
            {_, v} -> String.to_integer(v)
            nil -> 0
          end

        body = read_body(sock_body_pad(body), cl)

        # chunked bodies: not supported yet (Laravel forms use CL)
        {:ok, method, target, headers, body}

      _ ->
        {:error, :bad_request_line}
    end
  end

  defp sock_body_pad(body), do: body

  defp read_body(buf, cl) when byte_size(buf) >= cl, do: binary_part(buf, 0, cl)
  defp read_body(_, 0), do: ""

  defp read_body(buf, cl) do
    missing = cl - byte_size(buf)
    # oversize bodies are refused (php -S post_max_size analog)
    if missing > 8 * 1024 * 1024, do: binary_part(buf, 0, byte_size(buf)), else: buf
  end

  # ── dispatch ──

  defp dispatch(docroot, method, target, headers, body) do
    {path, query} =
      case String.split(target, "?", parts: 2) do
        [p, q] -> {p, q}
        [p] -> {p, ""}
      end

    rel = path |> URI.decode() |> sanitize_path()
    fs_path = Path.join(docroot, rel)

    cond do
      String.ends_with?(fs_path, ".php") and File.exists?(fs_path) ->
        run_php(fs_path, docroot, method, path, query, headers, body)

      File.dir?(fs_path) ->
        index = Path.join(fs_path, "index.php")

        if File.exists?(index) do
          run_php(index, docroot, method, path, query, headers, body)
        else
          not_found()
        end

      File.exists?(fs_path) ->
        serve_static(fs_path)

      true ->
        # php -S behavior: unmatched paths fall back to the docroot's
        # index.php (its presence implies a front controller — Laravel's
        # public/index.php routing depends on this)
        front = Path.join(docroot, "index.php")

        if File.exists?(front) do
          run_php(front, docroot, method, path, query, headers, body)
        else
          not_found()
        end
    end
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

  defp not_found, do: {404, [{"Content-type", "text/html; charset=UTF-8"}], "Not Found"}

  # ── PHP execution ──

  defp run_php(fs_path, docroot, method, uri_path, query, headers, body) do
    src = File.read!(fs_path)
    globals = seed_globals(fs_path, docroot, method, uri_path, query, headers, body)
    sapi = %{headers: [], status: 200}

    task =
      Task.async(fn ->
        try do
          PhpBeam.Interp.run_http(src, PhpBeam.Interp.real_path(fs_path), globals, sapi)
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
        {status, hdrs, out}

      {:exit, _} ->
        {500, [{"Content-Type", "text/plain"}], "phpbeam: script crashed"}

      nil ->
        {504, [{"Content-Type", "text/plain"}], "phpbeam: execution timed out"}
    end
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
  defp seed_globals(fs_path, docroot, method, uri_path, query, headers, body) do
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
    post = if method in ~w(POST PUT PATCH), do: parse_form(headers, body), else: %{}
    cookies = parse_cookies(header_or(headers, "cookie", ""))
    request = Map.merge(Map.new(get), Map.new(post))

    %{
      "_SERVER" => arr(server),
      "_GET" => arr(Enum.map(get, fn {k, v} -> {{:string, k}, {:string, v}} end)),
      "_POST" => arr(Enum.map(post, fn {k, v} -> {{:string, k}, {:string, v}} end)),
      "_COOKIE" => arr(Enum.map(cookies, fn {k, v} -> {{:string, k}, {:string, v}} end)),
      "_REQUEST" => arr(Enum.map(request, fn {k, v} -> {{:string, k}, {:string, v}} end)),
      "_FILES" => arr([])
    }
  end

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
        [k] -> {URI.decode_www_form(k), ""}
        [k, v] -> {URI.decode_www_form(k), URI.decode_www_form(v)}
      end
    end)
    |> Enum.reject(fn {k, _} -> k == "" end)
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

  defp send_response(sock, status, headers, body) do
    reason = reason_phrase(status)
    head = ["HTTP/1.1 #{status} #{reason}" | Enum.map(headers, fn {k, v} -> "#{k}: #{v}" end)]

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
