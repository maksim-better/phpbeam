defmodule PhpBeam.CLI do
  @moduledoc """
  `phpx` command line: `phpx script.php`, `phpx -r 'code'`, `phpx --repl`.
  """

  @usage """
  phpx — PHP on the BEAM (PHP 8 subset interpreter)

  Usage:
    phpx file.php [args...]      run a script
    phpx -r '<code>'             run inline code
    phpx --repl                  interactive shell
    phpx --version               version info
  """

  def main(args) do
    case args do
      ["--version"] ->
        IO.puts("phpx #{version()} (PHP 8.4 subset, BEAM/#{:erlang.system_info(:otp_release)})")

      ["--help" | _] ->
        IO.puts(@usage)

      ["-r", code | _] ->
        run_code("<?php " <> code, "Command line code")

      ["--repl"] ->
        PhpBeam.Repl.start()

      ["serve" | rest] ->
        {docroot, port} = serve_opts(rest)
        PhpBeam.Http.serve(docroot, port)

      [file | _rest] ->
        case File.read(file) do
          {:ok, src} ->
            run_code(src, script_path(file))

          {:error, _} ->
            IO.puts(:stderr, "Could not open input file: #{file}")
            System.halt(1)
        end

      [] ->
        IO.puts(:stderr, @usage)
        System.halt(1)
    end
  end

  def run_code(src, file \\ nil) do
    {out, code} = run_and_capture(src, file)
    IO.write(out)
    if code != 0, do: System.halt(code)
  end

  def run_and_capture(src, file \\ nil) do
    task =
      Task.async(fn ->
        try do
          PhpBeam.Interp.run(src, file)
        catch
          :exit, _ ->
            {"PHP Fatal error:  internal exit\n", 255, nil}

          kind, reason ->
            msg =
              case reason do
                %_{message: m} -> m
                _ -> inspect(reason)
              end

            IO.write(:stderr, "phpx internal error (#{kind}): #{msg}\n")
            {"", 255, nil}
        end
      end)

    case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, code, _interp}} ->
        {out, code}

      {:exit, _} ->
        {"", 255}

      nil ->
        {"PHP Fatal error:  execution timed out\n", 255}
    end
  end

  defp serve_opts(rest) do
    {flags, pos} = Enum.split_with(rest, &String.starts_with?(&1, "--"))

    docroot =
      case pos do
        [d | _] -> d
        [] -> "."
      end

    port =
      Enum.find_value(flags, 8080, fn f ->
        case String.split(f, "=", parts: 2) do
          ["--port", p] -> String.to_integer(p)
          _ -> nil
        end
      end)

    {docroot, port}
  end

  # php canonicalizes the main script path (symlinks) in errors/__FILE__
  defp script_path(file) do
    abs = Path.absname(file)

    PhpBeam.Interp.real_path(abs)
  end

  defp version do
    case :application.get_key(:phpbeam, :vsn) do
      {:ok, v} -> List.to_string(v)
      _ -> "0.1.0"
    end
  end
end
