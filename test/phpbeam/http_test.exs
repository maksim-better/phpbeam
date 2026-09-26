# L0 acceptance: the HTTP SAPI differential matrix against `php -S`.
# Boots both servers on scratch docroots and compares curl responses
# (body byte-exact; Host/Date/Connection/Content-Length/X-Powered-By and
# port numbers normalized away — those are server-injected).
#
#     mix test test/phpbeam/http_test.exs
defmodule PhpBeam.HttpTest do
  use ExUnit.Case, async: false

  @docroot "/tmp/phpbeam_http_docroot"
  @bport 18_899
  @pport 18_898

  setup_all do
    File.rm_rf(@docroot)
    File.mkdir_p!(@docroot <> "/sub")

    File.write!(@docroot <> "/index.php", """
    <?php
    header("X-Powered-By: phpbeam");
    http_response_code(201);
    echo "method=", $_SERVER["REQUEST_METHOD"], " uri=", $_SERVER["REQUEST_URI"], "\\n";
    echo "name=", $_GET["name"] ?? "-", " post=", $_POST["value"] ?? "-", "\\n";
    setcookie("sid", "abc123");
    echo "ctype=", $_SERVER["CONTENT_TYPE"] ?? "-", "\\n";
    """)

    File.write!(@docroot <> "/sub/index.php", ~S(<?php echo "sub-index";))

    # A4 fixtures: nested POST dumps, multipart uploads (tmp names
    # normalized in-script), chunked + raw input echo
    nest =
      "<?php\n" <>
        "echo \"post=\"; var_export($_POST); echo \"\\n\";\n" <>
        "echo \"input_len=\", strlen(file_get_contents(\"php://input\")), \"\\n\";\n"

    File.write!(@docroot <> "/nest.php", nest)

    up =
      "<?php\n" <>
        "function __norm($a) {\n" <>
        "  foreach ($a as $k => $v) {\n" <>
        "    if ($k === \"tmp_name\") { $a[$k] = is_array($v) ? array_map(function ($s) { return preg_replace(\"#/php[^/]*$#\", \"/TMP\", $s); }, $v) : preg_replace(\"#/php[^/]*$#\", \"/TMP\", $v); }\n" <>
        "    elseif (is_array($v)) { $a[$k] = __norm($v); }\n" <>
        "  }\n" <>
        "  return $a;\n" <>
        "}\n" <>
        "$__F = __norm($_FILES);\n" <>
        "echo \"post=\"; var_export($_POST); echo \"\\n\";\n" <>
        "echo \"files=\"; var_export($__F); echo \"\\n\";\n" <>
        "$k = array_key_first($__F);\n" <>
        "if ($k && isset($__F[$k][\"tmp_name\"])) {\n" <>
        "  $t = is_array($_FILES[$k][\"tmp_name\"]) ? $_FILES[$k][\"tmp_name\"][0] : $_FILES[$k][\"tmp_name\"];\n" <>
        "  echo \"is_up=\", var_export(is_uploaded_file($t), true), \" content=\", file_get_contents($t), \"\\n\";\n" <>
        "}\n"

    File.write!(@docroot <> "/up.php", up)
    File.write!(@docroot <> "/a.txt", "plain text file")

    beam = spawn_serve()
    php = spawn_php_s()
    wait_listening(@bport)
    wait_listening(@pport)

    on_exit(fn ->
      kill(beam)
      kill(php)
      File.rm_rf(@docroot)
    end)

    :ok
  end

  # :nouse_stdio — the server's IO.puts must reach the real terminal, not a
  # port pipe (a linked stdio blocks the spawned escript's group leader)
  defp spawn_serve do
    Port.open(
      {:spawn_executable, Path.expand("../../phpx", __DIR__)},
      [
        :exit_status,
        :nouse_stdio,
        args: ["serve", @docroot, "--port=#{@bport}"],
        cd: Path.expand("../..", __DIR__)
      ]
    )
  end

  defp spawn_php_s do
    Port.open(
      {:spawn_executable, "/opt/homebrew/bin/php"},
      [
        :exit_status,
        :nouse_stdio,
        args: ["-S", "127.0.0.1:#{@pport}"],
        cd: @docroot
      ]
    )
  end

  defp kill(port) do
    # Port.close alone does not terminate :nouse_stdio children on this
    # platform — the servers outlived the suite and held pipes open
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> System.cmd("kill", [Integer.to_string(os_pid)])
      _ -> :ok
    end

    if Port.info(port) != nil, do: Port.close(port)
  catch
    _, _ -> :ok
  end

  defp wait_listening(port, tries \\ 50) do
    if tries == 0 do
      raise "server on #{port} never listened"
    else
      case System.cmd("curl", [
             "-s",
             "-o",
             "/dev/null",
             "--max-time",
             "1",
             "http://127.0.0.1:#{port}/"
           ]) do
        {_out, 0} ->
          :ok

        _ ->
          Process.sleep(100)
          wait_listening(port, tries - 1)
      end
    end
  end

  defp curl(port, method, uri, data \\ nil) do
    args = ["-s", "-D", "-", "--max-time", "10", "-X", method]

    args =
      if data,
        do: args ++ ["-H", "Content-Type: application/x-www-form-urlencoded", "-d", data],
        else: args

    {out, 0} = System.cmd("curl", args ++ ["http://127.0.0.1:#{port}#{uri}"])
    normalize(port, out)
  end

  defp normalize(port, resp) do
    resp
    |> String.replace(Integer.to_string(port), "PORT")
    |> String.split("\n")
    |> Enum.reject(
      &(&1 == "" or
          String.starts_with?(&1, ~w(Host: Date: Connection: Content-Length: X-Powered-By:)))
    )
    |> Enum.join("\n")
  end

  # raw curl args (multipart/chunked/keep-alive can't express via curl/4)
  defp raw(port, extra) do
    args = Enum.map(extra, &String.replace(&1, "URL", "http://127.0.0.1:#{port}"))
    {out, 0} = System.cmd("curl", ["-s", "--max-time", "10" | args])
    normalize(port, out)
  end

  @tag :http
  test "php -S parity: nested POST keys (a[b][] c[d][] dots/spaces)" do
    q = "c[d][]=z&tags[]=x&tags[]=y&a.b c=1"

    extra = ["-d", q, "URL/nest.php"]
    assert raw(@pport, extra) == raw(@bport, extra)
  end

  @tag :http
  test "php -S parity: multipart single file + field" do
    extra = ["-F", "name=Gu", "-F", "f=@#{@docroot}/a.txt", "URL/up.php"]
    assert raw(@pport, extra) == raw(@bport, extra)
  end

  @tag :http
  test "php -S parity: multipart multi upload (up[]) + nested fields" do
    extra = [
      "-F",
      "tags[]=x",
      "-F",
      "tags[]=y",
      "-F",
      "up[]=@#{@docroot}/a.txt",
      "-F",
      "up[]=@#{@docroot}/a.txt;type=text/x-custom",
      "URL/up.php"
    ]

    assert raw(@pport, extra) == raw(@bport, extra)
  end

  @tag :http
  test "php -S parity: chunked body" do
    extra = [
      "-H",
      "Transfer-Encoding: chunked",
      "--data-binary",
      "hello chunked body",
      "URL/nest.php"
    ]

    assert raw(@pport, extra) == raw(@bport, extra)
  end

  @tag :http
  test "php -S parity: keep-alive two requests one connection" do
    extra = ["URL/nest.php?r=1", "-d", "a=1", "URL/nest.php?r=2", "-d", "b=2"]
    assert raw(@pport, extra) == raw(@bport, extra)
  end

  @tag :http
  test "php -S parity: HTTP/1.0 request" do
    extra = [
      "--http1.0",
      "-d",
      "a=1",
      "-w",
      "|proto=%{http_version} code=%{response_code}",
      "URL/nest.php"
    ]

    assert raw(@pport, extra) == raw(@bport, extra)
  end

  @cases [
    {"root GET with query", "GET", "/?name=world", nil},
    {"root POST form", "POST", "/index.php", "value=42"},
    {"static file", "GET", "/page.html", nil},
    {"directory index", "GET", "/sub/", nil},
    {"redirect", "GET", "/redirect.php", nil},
    {"front-controller fallback", "GET", "/missing.png", nil}
  ]

  for {label, method, uri, data} <- @cases do
    @tag :http
    test "php -S parity: " <> label do
      assert curl(@pport, unquote(method), unquote(uri), unquote(data)) ==
               curl(@bport, unquote(method), unquote(uri), unquote(data)),
             "response diverged from php -S for #{unquote(method)} #{unquote(uri)}"
    end
  end
end
