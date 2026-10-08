# Acceptance suites from the php-src distribution (PHP 8.4.25), run through
# the .phpt harness in PhpBeam.Test.Phpt. Point PHP_SRC at an unpacked
# php-src tree; without it every suite degrades to a single skipped test.
#
# Golden references on this machine (2026-10-03, spec 001-phpt-semantic-completion R1):
#   oracle php  = /opt/homebrew/bin/php 8.4.17   (was 8.4.2 on the old dev box)
#   suite source= php-src 8.4.25                 (was 8.4.24)
# Version drift between the two eras is quantified in docs/matrix/drift.md at
# baseline re-record time (R5); never silently absorbed.
#
#     mix test test/phpbeam/phpt_test.exs            # all suites
#     mix test --only phpt                           # anywhere
#     mix test --exclude phpt                        # interpreter dev loop
#
# Suits are chunked into many small async modules so phpx spawns run in
# parallel (~0.2s each, ~780 cases over tests/{lang,strings,func,classes,
# basic,output}).
php_src = System.get_env("PHP_SRC", "/Users/5i5j/Downloads/php-8.4.25")
escript = Path.expand("../../phpx", __DIR__)
php_bin = "/opt/homebrew/bin/php"

# dir_id => php-src-relative path. Flat ids keep the generated Module names
# valid unique atoms (spec 001 research U9): tests/* top level keep their
# plain name; future Zend/tests subdirs become zend-<sub>, root-level
# Zend/tests files become zend-root, ext/<mod>/tests becomes ext-<mod>.
# The failure line format "test <file>.phpt (PhpBeam.Phpt.<Flat>.G<N>)"
# then encodes the directory — the gate shards baselines on it.
suites = [
  {"lang", "tests/lang"},
  {"strings", "tests/strings"},
  {"func", "tests/func"},
  {"classes", "tests/classes"},
  {"basic", "tests/basic"},
  {"output", "tests/output"},
  {"security", "tests/security"},
  {"run-test", "tests/run-test"},
  {"zend-exit", "Zend/tests/exit"},
  {"zend-throw", "Zend/tests/throw"},
  {"zend-ast", "Zend/tests/ast"},
  {"zend-typehints", "Zend/tests/typehints"},
  {"zend-gh15976", "Zend/tests/gh15976"},
  {"zend-arrow", "Zend/tests/arrow_functions"},
  {"zend-closures", "Zend/tests/closures"},
  {"zend-list", "Zend/tests/list"},
  {"zend-anon", "Zend/tests/anon"},
  {"zend-numeric-strings", "Zend/tests/numeric_strings"},
  {"zend-multibyte", "Zend/tests/multibyte"}
]

# PHPT_DIRS="lang,basic" limits the compiled suites to those dir_ids
# (scripts/gate.sh --lane dirs). Unset/empty = all suites.
suites =
  case System.get_env("PHPT_DIRS") do
    nil ->
      suites

    wanted ->
      want = wanted |> String.split(",", trim: true) |> MapSet.new(&String.trim/1)

      unless MapSet.subset?(want, MapSet.new(suites, &elem(&1, 0))) do
        raise "PHPT_DIRS names unknown suites (typo in a dir id?): #{wanted}"
      end

      Enum.filter(suites, fn {dir_id, _} -> MapSet.member?(want, dir_id) end)
  end

groups =
  for {dir_id, rel} <- suites,
      dir = Path.join(php_src, rel),
      files = (File.dir?(dir) && Path.wildcard(Path.join(dir, "*.phpt")) |> Enum.sort()) || [],
      {chunk, idx} <- Enum.with_index(Enum.chunk_every(files, 40)) do
    {dir_id, idx, chunk}
  end

for {dir_id, idx, files} <- groups do
  # sanitize for the module atom: Macro.camelize leaves dashes in place
  # ("run-test" → "Run-test"), so fold them to underscores first
  mod_flat = dir_id |> String.replace("-", "_") |> Macro.camelize()

  defmodule Module.concat([PhpBeam.Phpt, mod_flat, "G#{idx}"]) do
    use ExUnit.Case, async: true

    for f <- files do
      @tag :phpt
      test "#{dir_id}/#{Path.basename(f)}" do
        case PhpBeam.Test.Phpt.run(unquote(f),
               escript: unquote(escript),
               php_bin: unquote(php_bin),
               suite: unquote(dir_id)
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
