defmodule PhpBeam.DiffTest do
  @moduledoc """
  Differential tests: every file in test/cases/*.php runs on both the local
  `php` CLI and `phpx`; stdout must match byte for byte.
  """

  use ExUnit.Case, async: false

  @php_bin "/opt/homebrew/bin/php"
  @cases_dir Path.expand("../cases", __DIR__)

  setup_all do
    # the escript is built by the developer (mix escript.build); rebuild only
    # when missing — running mix inside mix deadlocks on the build lock
    escript = Path.expand("../../phpx", __DIR__)

    unless File.exists?(escript) do
      flunk("phpx not built; run: mix escript.build")
    end

    {:ok, %{escript: escript}}
  end

  test "differential cases match php 8.4 byte-for-byte", %{escript: escript} do
    files =
      Path.wildcard(Path.join(@cases_dir, "*.php"))
      |> Enum.sort()

    assert length(files) > 0, "no cases found"

    failures =
      Enum.flat_map(files, fn file ->
        php_out = shell_cmd(~s(#{@php_bin} #{file} 2>/dev/null))
        px_out = shell_cmd(~s(#{escript} #{file} 2>/dev/null))

        if php_out == px_out do
          []
        else
          ["#{Path.basename(file)}:\n--- php ---\n#{php_out}\n--- phpx ---\n#{px_out}"]
        end
      end)

    assert failures == [],
           "differential mismatches:\n\n" <> Enum.join(failures, "\n\n============\n\n")
  end

  defp shell_cmd(cmd) do
    :os.cmd(String.to_charlist(cmd)) |> List.to_string()
  end
end
