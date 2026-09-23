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
        run_code("<?php " <> code)

      ["--repl"] ->
        PhpBeam.Repl.start()

      [file | _rest] ->
        case File.read(file) do
          {:ok, src} ->
            run_code(src)

          {:error, _} ->
            IO.puts(:stderr, "Could not open input file: #{file}")
            System.halt(1)
        end

      [] ->
        IO.puts(:stderr, @usage)
        System.halt(1)
    end
  end

  def run_code(src) do
    {out, code} = run_and_capture(src)
    IO.write(out)
    if code != 0, do: System.halt(code)
  end

  def run_and_capture(src) do
    task =
      Task.async(fn ->
        try do
          PhpBeam.Interp.run(src)
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

  defp version do
    case :application.get_key(:phpbeam, :vsn) do
      {:ok, v} -> List.to_string(v)
      _ -> "0.1.0"
    end
  end
end

defmodule PhpBeam.Repl do
  @moduledoc "Minimal read-eval-print loop."

  def start do
    IO.puts("phpx repl — PHP on BEAM (type a statement, :q to quit)")
    loop("", 1)
  end

  defp loop(buffer, line_no) do
    prompt = if buffer == "", do: "phpx> ", else: "...   > "
    input = IO.gets(prompt)

    case input do
      :eof ->
        :ok

      :error ->
        :ok

      line when line in [":q\n", ":q\r\n"] ->
        :ok

      line ->
        buffer2 = buffer <> line

        if complete?(buffer2) do
          {out, _code} = PhpBeam.CLI.run_and_capture("<?php " <> buffer2)
          IO.write(out)
          loop("", line_no + 1)
        else
          loop(buffer2, line_no + 1)
        end
    end
  end

  defp complete?(buf) do
    src = "<?php " <> buf

    case PhpBeam.Lexer.tokenize(src) do
      {:ok, toks} ->
        case PhpBeam.Parser.parse(toks) do
          {:ok, _} -> true
          {:error, _msg, _line} -> false
        end

      {:error, _, _} ->
        false
    end
  end
end
