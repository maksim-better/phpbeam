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
    File.write!(@docroot <> "/page.html", "<html><body>static</body></html>")

    redirect = "<?php\nhttp_response_code(302);\nheader(\"Location: /landing\");\n"
    File.write!(@docroot <> "/redirect.php", redirect)

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
