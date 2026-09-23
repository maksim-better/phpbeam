# Acceptance suites from the php-src distribution (PHP 8.4.24), run through
# the .phpt harness in PhpBeam.Test.Phpt. Point PHP_SRC at an unpacked
# php-src tree; without it every suite degrades to a single skipped test.
#
#     mix test test/phpbeam/phpt_test.exs            # all suites
#     mix test --only phpt                           # anywhere
#     mix test --exclude phpt                        # interpreter dev loop
#
# Suits are chunked into many small async modules so phpx spawns run in
# parallel (~0.2s each, ~780 cases over tests/{lang,strings,func,classes,
# basic,output}).
php_src = System.get_env("PHP_SRC", "/Users/guozhu/Downloads/php-8.4.24")
escript = Path.expand("../../phpx", __DIR__)
php_bin = "/opt/homebrew/bin/php"

groups =
  for suite <- ~w(lang strings func classes basic output),
      dir = Path.join(php_src, "tests/#{suite}"),
      files = (File.dir?(dir) && Path.wildcard(Path.join(dir, "*.phpt")) |> Enum.sort()) || [],
      {chunk, idx} <- Enum.with_index(Enum.chunk_every(files, 40)) do
    {suite, idx, chunk}
  end

for {suite, idx, files} <- groups do
  defmodule Module.concat([PhpBeam.Phpt, Macro.camelize(suite), "G#{idx}"]) do
    use ExUnit.Case, async: true

    for f <- files do
      @tag :phpt
      test "#{suite}/#{Path.basename(f)}" do
        case PhpBeam.Test.Phpt.run(unquote(f),
               escript: unquote(escript),
               php_bin: unquote(php_bin),
               suite: unquote(suite)
             ) do
          {:ok, _} ->
            assert true

          {:skip, reason} ->
            assert true, "(skipped: #{reason})"

          {:fail, class, message} ->
            flunk("class=#{inspect(class)}#{message}")
        end
      end
    end
  end
end

if groups == [] do
  defmodule PhpBeam.Phpt.NotAvailableTest do
    use ExUnit.Case, async: true

    @tag skip: "php-src tree not found at #{php_src} (set PHP_SRC to run .phpt suites)"
    test "phpt suites are available" do
      assert true
    end
  end
end
