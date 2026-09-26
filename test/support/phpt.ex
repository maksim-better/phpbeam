defmodule PhpBeam.Test.Phpt do
  @moduledoc """
  Minimal .phpt runner modelled on php-src `run-tests.php`.

  Parses the section format (`--FILE--`, `--EXPECT--`, `--EXPECTF--`, ...),
  executes `--FILE--` with ./phpx under a timeout, and compares stdout with
  run-tests' semantics:

  * both sides go through PHP `trim()` (leading/trailing whitespace) before
    `--EXPECT--` byte comparison — phpt files conventionally end with a
    newline that the script output may or may not produce;
  * `--EXPECTF--` uses the exact `expectf_to_regex` code table from
    run-tests.php (`%s` → `[^\r\n]+`, `%d` → `\d+`, `%r...%r` raw chunks
    wrapped in a group, applied after escaping the non-`%r` parts);
  * `--EXPECTREGEX--` is anchored raw regex.

  Not modelled: `--GET--`/`--POST--`/... SAPI sections (skipped), `--INI--`
  (ignored — the defaults match phpx), `--CLEAN--` (ignored).
  """

  @timeout_s 10
  @trim ~r/^[ \t\n\r\x0B\x00]+|[ \t\n\r\x0B\x00]+$/

  # run-tests.php expectf_to_regex strtr table, same order-independence
  # guarantees (no code is a prefix of another)
  @expectf_codes [
    {"%e", "/"},
    {"%s", "[^\r\n]+"},
    {"%S", "[^\r\n]*"},
    {"%a", ".+"},
    {"%A", ".*"},
    {"%w", "\\s*"},
    {"%i", "[+-]?\\d+"},
    {"%d", "\\d+"},
    {"%x", "[0-9a-fA-F]+"},
    {"%f", "[+-]?(?:\\d+|(?=\\.\\d))(?:\\.\\d+)?(?:[Ee][+-]?\\d+)?"},
    {"%c", "."},
    {"%0", "\\x00"}
  ]

  @sapi_sections ~w(GET POST POST_RAW PUT COOKIE EXPECTHEADERS CGI)

  ## ───────────────────────────── parsing ─────────────────────────────

  def parse(path) do
    src = path |> File.read!() |> String.replace("\r\n", "\n")

    case Regex.split(~r/^--[A-Z0-9_]+--$/m, src, include_captures: true) do
      [_preamble | parts] -> build_sections(parts, %{})
    end
  end

  defp build_sections([], acc), do: acc
  defp build_sections([_preamble], acc), do: acc

  defp build_sections([marker, body | rest], acc) do
    build_sections(
      rest,
      Map.put(acc, String.trim(marker, "-"), String.replace_prefix(body, "\n", ""))
    )
  end

  ## ───────────────────────────── running ─────────────────────────────

  @doc """
  Runs one .phpt file. Returns `{:ok, name}`, `{:skip, reason}` or
  `{:fail, class, message}` — `class` is a triage bucket for the failure
  (missing builtin, parse gap, output mismatch, timeout, ...).
  """
  def run(path, opts \\ []) do
    escript = Keyword.fetch!(opts, :escript)
    php_bin = Keyword.get(opts, :php_bin, "/opt/homebrew/bin/php")
    suite = Keyword.get(opts, :suite, "misc")

    secs = parse(path)
    file = secs["FILE"] || secs["FILEEOF"]

    cond do
      is_nil(file) ->
        {:skip, "no --FILE-- section"}

      Enum.any?(@sapi_sections, &Map.has_key?(secs, &1)) ->
        {:skip, "requires SAPI section"}

      true ->
        case skipif(secs["SKIPIF"], php_bin, suite, path) do
          {:skip, _} = skip ->
            skip

          false ->
            # run-tests convention: the runnable copy lives next to the .phpt
            # so sibling fixtures (`include 'x.inc'`) and __DIR__ resolve
            dir = Path.dirname(path)
            tmp = Path.join(dir, Path.basename(path, ".phpt") <> ".phpbeam.php")
            File.write!(tmp, file)
            out = run_escript(escript, tmp, dir)
            File.rm(tmp)

            # php's run-tests names the runnable copy `<name>php`, and
            # EXPECTF patterns spell the script as `%s<base>.php`; our
            # `.phpbeam.php` suffix breaks those literals (path may be
            # realpath'd, so normalize on basename only)
            stem = Path.basename(path, ".phpt")
            out = String.replace(out, stem <> ".phpbeam.php", stem <> ".php")

            case verify(secs, out) do
              :ok -> {:ok, Path.basename(path)}
              {:fail, expected} -> {:fail, classify(out), failure_message(expected, out)}
            end
        end
    end
  end

  defp skipif(nil, _php_bin, _suite, _path), do: false

  defp skipif(code, php_bin, suite, path) do
    tmp = tmp_file(suite, "skipif_" <> Path.basename(path) <> ".php")
    File.mkdir_p!(Path.dirname(tmp))
    File.write!(tmp, code)
    out = shell("#{php_bin} -n #{q(tmp)} 2>/dev/null")

    case Regex.run(~r/^skip\s*(.*)/, out) do
      [_, reason] -> {:skip, "SKIPIF: " <> String.trim(reason)}
      _ -> false
    end
  end

  defp run_escript(escript, file, dir) do
    shell(
      "cd #{q(dir)} && perl -e 'alarm #{@timeout_s}; exec @ARGV' #{q(escript)} #{q(file)} 2>&1"
    )
  end

  defp verify(secs, out) do
    cond do
      out =~ "Alarm clock" ->
        {:fail, "(timed out after #{@timeout_s}s)"}

      secs["EXPECT"] ->
        if php_trim(out) == php_trim(secs["EXPECT"]),
          do: :ok,
          else: {:fail, php_trim(secs["EXPECT"])}

      secs["EXPECTF"] ->
        if match_anchored?(expectf_to_regex(php_trim(secs["EXPECTF"])), out),
          do: :ok,
          else: {:fail, php_trim(secs["EXPECTF"])}

      secs["EXPECTREGEX"] ->
        if match_anchored?(php_trim(secs["EXPECTREGEX"]), out),
          do: :ok,
          else: {:fail, php_trim(secs["EXPECTREGEX"])}

      true ->
        # no expectation section means the run must produce no stdout
        if php_trim(out) == "", do: :ok, else: {:fail, ""}
    end
  end

  defp match_anchored?(regex_source, out) do
    case Regex.compile!("^(?:#{regex_source})$", "s") do
      %Regex{} = re -> Regex.match?(re, php_trim(out))
    end
  end

  ## ─────────────────────────── comparison ───────────────────────────

  defp php_trim(s), do: String.replace(s, @trim, "")

  # php-src: preg_quote the non-%r parts, wrap %r innards in a group
  # unescaped, then strtr the code table over the whole assembly (so
  # %d etc. inside %r chunks are also expanded — replicated on purpose)
  defp expectf_to_regex(wanted) do
    wanted
    |> assemble_r_sections("")
    |> replace_codes()
  end

  defp assemble_r_sections("", acc), do: acc

  defp assemble_r_sections(s, acc) do
    case :binary.split(s, "%r") do
      [^s] ->
        acc <> Regex.escape(s)

      [pre, rest] ->
        case :binary.split(rest, "%r") do
          [inner, rest2] ->
            assemble_r_sections(rest2, acc <> Regex.escape(pre) <> "(" <> inner <> ")")

          [_] ->
            acc <> Regex.escape(s)
        end
    end
  end

  defp replace_codes(assembled) do
    Enum.reduce(@expectf_codes, assembled, fn {code, replacement}, acc ->
      String.replace(acc, code, replacement)
    end)
  end

  ## ───────────────────────── triage helpers ─────────────────────────

  defp classify(out) do
    case Regex.run(~r/Call to undefined function '?\\?([\w\\]+)'?\(\)?/, out) do
      [_, name] -> {:undef_fn, name}
      nil -> classify_rest(out)
    end
  end

  defp classify_rest(out) do
    cond do
      out =~ "Alarm clock" ->
        :timeout

      out =~ "not found" or out =~ "does not exist" ->
        :undef_symbol

      out =~ "Parse error" or out =~ "syntax error" ->
        :parse_error

      out =~ "Fatal error" or out =~ "Uncaught" ->
        :fatal

      true ->
        :mismatch
    end
  end

  defp failure_message(expected, actual) do
    "\n--- expected ---\n#{truncate(expected)}\n--- actual ---\n#{truncate(actual)}"
  end

  # PHP test output can contain arbitrary bytes (binary junk from string
  # tests); ExUnit's CLI formatter crashes on invalid UTF-8 chardata, so
  # escape it and keep truncation grapheme-safe
  defp truncate(s) do
    s = if String.valid?(s), do: s, else: inspect(s)

    if String.length(s) > 600,
      do: String.slice(s, 0, 600) <> "... (truncated)",
      else: s
  end

  ## ────────────────────────── shell helpers ─────────────────────────

  defp shell(cmd), do: :os.cmd(String.to_charlist(cmd)) |> List.to_string()

  defp q(s), do: "'#{String.replace(s, "'", "'\\''")}'"

  defp tmp_file(suite, name) do
    ext = Path.extname(name)
    base = Path.basename(name, ext)
    Path.join([File.cwd!(), "tmp", "phpt", suite, "#{base}.php"])
  end
end
