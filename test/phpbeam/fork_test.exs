defmodule PhpBeam.ForkTest do
  @moduledoc """
  Seam tests for fork_request (ARCHITECTURE_DESIGN §3.5): boot fields
  (class/function/const tables, ini, autoload chain) survive the fork;
  request-scoped state (statics, globals, refs, objects) resets.
  """
  use ExUnit.Case, async: true

  @warm_src """
  <?php
  class BootCls { public static $hits = 0; public static function hi() { return "boot"; } }
  function boot_fn() { return 99; }
  define("BOOT_CONST", 7);
  """

  defp warmed do
    {_, _, interp} = PhpBeam.Interp.run(@warm_src, "warm.php")
    interp
  end

  # run a snippet on a base interp; returns {printed_output, final_interp}
  defp run_on(interp, src) do
    {:ok, toks} = PhpBeam.Lexer.tokenize(src)
    {:ok, stmts} = PhpBeam.Parser.parse(toks)
    {_, _, i2} = PhpBeam.Interp.exec_stmts(stmts, PhpBeam.Env.global_scope([]), interp)
    {IO.iodata_to_binary(Enum.reverse(i2.out)), i2}
  end

  test "boot tables survive the fork" do
    forked = PhpBeam.Interp.fork_request(warmed())
    assert Map.has_key?(forked.classes, "bootcls")
    assert Map.has_key?(forked.functions, "boot_fn")
    assert Map.has_key?(forked.consts, "BOOT_CONST")
  end

  test "forked interp executes boot-defined code" do
    {out, _} = run_on(PhpBeam.Interp.fork_request(warmed()), "<?php echo boot_fn(), BootCls::hi();")
    assert out == "99boot"
  end

  test "statics do NOT leak: each fork starts from zero" do
    boot = warmed()
    f1 = PhpBeam.Interp.fork_request(boot)
    {_, f1b} = run_on(f1, "<?php BootCls::$hits += 1;")
    {out1, _} = run_on(f1b, "<?php echo BootCls::$hits;")
    assert out1 == "1"

    f2 = PhpBeam.Interp.fork_request(boot)
    {out2, _} = run_on(f2, "<?php echo BootCls::$hits;")
    assert out2 == "0"
  end

  test "std resources are re-seeded on every fork" do
    forked = PhpBeam.Interp.fork_request(warmed())
    assert Map.has_key?(forked.resources, 0)
    assert Map.has_key?(forked.resources, 1)
    assert Map.has_key?(forked.resources, 2)
  end
end
