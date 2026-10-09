defmodule PhpBeam.CLI do
  @moduledoc """
  `phpx` command line: `phpx script.php`, `phpx -r 'code'`, `phpx --repl`.
  """

  @usage """
  phpx — PHP on the BEAM (PHP 8 subset interpreter)

  Usage:
    phpx [opts] file.php [args...] run a script
    phpx [opts] -r '<code>'        run inline code
    phpx --repl                    interactive shell
    phpx --version                 version info

  INI options (php-compatible):
    -c <path>     load php.ini from file or directory (<dir>/php.ini)
    -n            no php.ini
    -d key[=val]  set INI entry (repeatable; without = sets "1")
  """

  def main(args) do
    {ini_entries, rest} = ini_options(args)

    case rest do
      ["--version"] ->
        IO.puts("phpx #{version()} (PHP 8.4 subset, BEAM/#{:erlang.system_info(:otp_release)})")

      ["--help" | _] ->
        IO.puts(@usage)

      ["-r", code | rest] ->
        run_code("<?php " <> code, "Command line code", ini_entries, ["Standard input code" | strip_dd(rest)])

      ["--repl"] ->
        PhpBeam.Repl.start()

      ["serve" | srv_rest] ->
        {docroot, port} = serve_opts(srv_rest)
        PhpBeam.Http.serve(docroot, port)

      [file | rest] ->
        case File.read(file) do
          {:ok, src} ->
            # __FILE__ is the canonicalized path; $argv[0] and the $_SERVER
            # SCRIPT keys keep the spelling as invoked — both probed against php
            run_code(src, script_path(file), ini_entries, [file | strip_dd(rest)], file)

          {:error, _} ->
            IO.puts(:stderr, "Could not open input file: #{file}")
            System.halt(1)
        end

      [] ->
        IO.puts(:stderr, @usage)
        System.halt(1)
    end
  end

  # php-style startup INI flags; stops at the first non-flag argument
  defp ini_options(args), do: ini_options(args, [])

  # `php script.php -- a b` / `php -r code -- a b`: one leading `--` separates
  # SAPI args from script args; without it the extras still go to $argv
  defp strip_dd(["--" | rest]), do: rest
  defp strip_dd(rest), do: rest

  defp ini_options(["-n" | rest], _acc), do: ini_options(rest, [])

  # long spelling used by php-src's own test suite when it re-invokes the
  # binary ($php . ' --no-php-ini ' …)
  defp ini_options(["--no-php-ini" | rest], _acc), do: ini_options(rest, [])

  defp ini_options(["-c" | rest], acc) do
    case rest do
      [path | rest2] -> ini_options(rest2, ini_file_entries(path) ++ acc)
      [] -> ini_options([], acc)
    end
  end

  defp ini_options(["-d" | rest], acc) do
    case rest do
      [kv | rest2] ->
        entry = d_entry(kv)
        ini_options(rest2, [entry | acc])

      [] ->
        ini_options([], acc)
    end
  end

  defp ini_options(["-c" <> path | rest], acc) when path != "",
    do: ini_options(rest, ini_file_entries(path) ++ acc)

  defp ini_options(["-d" <> kv = other | rest], acc) do
    if other != "-d" and kv != "" do
      ini_options(rest, [d_entry(kv) | acc])
    else
      {Enum.reverse(acc), [other | rest]}
    end
  end

  defp ini_options([other | rest], acc), do: {Enum.reverse(acc), [other | rest]}
  defp ini_options([], acc), do: {Enum.reverse(acc), []}

  defp d_entry(kv) do
    case String.split(kv, "=", parts: 2) do
      [k, v] -> {k, v}
      [k] -> {k, "1"}
    end
  end

  defp ini_file_entries(path) do
    full = if File.dir?(path), do: Path.join(path, "php.ini"), else: path
    PhpBeam.Ini.parse_file(full)
  end

  def run_code(src, file \\ nil, ini_entries \\ [], argv \\ [], display \\ nil) do
    {out, code} = run_and_capture(src, file, ini_entries, argv, display)
    # php stdout is a BYTE stream — the io server in its default unicode mode
    # re-encodes even binwrite's latin1 payload (probed: ~"1.5" echo → c3 8e…,
    # and :file.write(1, …) is not an fd write). latin1 GL mode passes bytes
    # through untouched — UTF-8 text rides along byte-identically.
    :io.setopts(:standard_io, encoding: :latin1)
    IO.binwrite(out)
    if code != 0, do: System.halt(code)
  end

  def run_and_capture(src, file \\ nil, ini_entries \\ [], argv \\ [], display \\ nil) do
    task =
      Task.async(fn ->
        try do
          PhpBeam.Interp.run(src, file, ini_entries, argv, display)
        catch
          :exit, r ->
            {"PHP Fatal error:  internal exit " <> inspect(r, limit: 6) <> "\n", 255, nil}

          kind, reason ->
            msg =
              case reason do
                %_{message: m} -> m
                _ ->
                  depth = String.to_integer(System.get_env("PHPX_TRACE_DEPTH") || "4")

                  inspect(reason, limit: 12) <>
                    " ST " <>
                    (__STACKTRACE__
                     |> Enum.take(depth)
                     |> Enum.map(fn {mm, ff, _, opts} ->
                       case Keyword.get(opts, :line) do
                         nil -> "#{mm}.#{ff}"
                         l -> "#{mm}.#{ff}:#{l}"
                       end
                     end)
                     |> Enum.join(","))
              end

            IO.write(:stderr, "phpx internal error (#{kind}): #{msg}\n")
            {"", 255, nil}
        end
      end)

    # Laravel-scale boots need minutes under the tree-walker; the hard 30s
    # CLI guard only makes sense for runaway scripts — raise to 10 minutes
    case Task.yield(task, 600_000) || Task.shutdown(task, :brutal_kill) do
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
