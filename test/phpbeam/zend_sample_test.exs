# Zend regression sampling: Zend/tests exercises corners the curated suites
# don't, and historically exposed engine crashes (M23: the push_frame crash
# family). A deterministic ~200-case sample runs each milestone; the pass-rate
# floor guards against regressions without gating on individual cases.
#
#     mix test test/phpbeam/zend_sample_test.exs
#     mix test --only zend
#
# The floor sits a step below the CURRENT rate on purpose — raise it as the
# interpreter improves (see PLAN.md M23). M23 measured 25/199 = 12.6% (baseline
# before the fix: ~11%); remaining sample crashes are the yield/__NAMESPACE__/
# nullsafe/attributes families, not engine-crash regressions.
php_src = System.get_env("PHP_SRC", "/Users/guozhu/Downloads/php-8.4.24")
zend_dir = Path.join(php_src, "Zend/tests")
escript = Path.expand("../../phpx", __DIR__)
php_bin = "/opt/homebrew/bin/php"

sample_size = 200

files =
  if File.dir?(zend_dir) do
    all =
      zend_dir
      |> Path.join("**/*.phpt")
      |> Path.wildcard()
      |> Enum.sort()

    step = max(1, div(length(all), sample_size))
    all |> Enum.take_every(step) |> Enum.take(sample_size)
  else
    []
  end

defmodule PhpBeam.ZendSampleTest do
  use ExUnit.Case, async: false

  @tag :phpt
  @tag :zend
  test "zend sample pass rate stays above the floor" do
    files = unquote(files)
    zend_dir = unquote(zend_dir)

    if files == [] do
      ExUnit.flunk("php-src tree not found at #{zend_dir} (set PHP_SRC)")
    else
      {ok, skipped, failed} = run_sample(files)

      total = ok + failed
      rate = if total == 0, do: 0.0, else: ok / total

      assert rate >= unquote(0.12),
             "zend sample rate #{Float.round(rate, 3)} (#{ok}/#{total} passed, " <>
               "#{skipped} skipped) dropped below the floor"
    end
  end

  defp run_sample(files) do
    files
    |> Task.async_stream(
      fn f ->
        PhpBeam.Test.Phpt.run(f,
          escript: unquote(escript),
          php_bin: unquote(php_bin),
          suite: "zend"
        )
      end,
      timeout: 60_000,
      max_concurrency: 10
    )
    |> Enum.reduce({0, 0, 0}, fn
      {:ok, {:ok, _}}, {o, s, f} -> {o + 1, s, f}
      {:ok, {:skip, _}}, {o, s, f} -> {o, s + 1, f}
      {:ok, {:fail, _, _}}, {o, s, f} -> {o, s, f + 1}
    end)
  end
end
