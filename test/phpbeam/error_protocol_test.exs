defmodule PhpBeam.ErrorProtocolTest do
  @moduledoc """
  PHASE A1 error-protocol semantics the stdout diff harness can't see:
  exit codes, shutdown ordering vs uncaught rendering, handler stacks.
  """
  use ExUnit.Case, async: true

  defp run(src), do: PhpBeam.Interp.run_quiet(src)

  test "shutdown functions run FIFO with captured args, output in order" do
    src = """
    <?php
    register_shutdown_function(function () { echo "S1\\n"; });
    register_shutdown_function(function ($x) { echo "S2 {$x}\\n"; }, "tail");
    echo "main\\n";
    """

    assert {out, 0} = run(src)
    assert out == "main\nS1\nS2 tail\n"
  end

  test "shutdown output appends AFTER the uncaught render, exit stays 255" do
    src = """
    <?php
    register_shutdown_function(function () { echo "SHUTDOWN\\n"; });
    throw new RuntimeException("u");
    """

    {out, code} = run(src)
    assert out =~ "Fatal error: Uncaught RuntimeException: u"
    assert out =~ "SHUTDOWN\n"
    assert String.ends_with?(out, "SHUTDOWN\n")
    assert code == 255
  end

  test "shutdown functions registered during shutdown also run" do
    src = """
    <?php
    register_shutdown_function(function () {
      echo "first\\n";
      register_shutdown_function(function () { echo "late\\n"; });
    });
    """

    assert {out, 0} = run(src)
    assert out == "first\nlate\n"
  end

  test "set_exception_handler replaces the Uncaught render, exit 0" do
    src = """
    <?php
    set_exception_handler(function ($e) {
      echo "EXH ", get_class($e), " ", $e->getMessage(), "\\n";
    });
    throw new LogicException("lexp");
    """

    assert {out, 0} = run(src)
    assert out == "EXH LogicException lexp\n"
  end

  test "exception handler stack: restore pops back to the previous handler" do
    src = """
    <?php
    set_exception_handler(function ($e) { echo "H1\\n"; });
    set_exception_handler(function ($e) { echo "H2\\n"; });
    restore_exception_handler();
    throw new LogicException("x");
    """

    assert {out, 0} = run(src)
    assert out == "H1\n"
  end

  test "error_reporting filters display; @ masks the read value" do
    src = """
    <?php
    echo $u;
    var_dump(error_reporting(E_ALL & ~E_WARNING));
    echo $u;
    """

    {out, 0} = run(src)
    # first warning displays (default E_ALL), then the set returns the old
    # level, then the same warning is filtered
    assert out == "\nWarning: Undefined variable $u in Command line code on line 2\nint(30719)\n"
  end

  test "trigger_error invalid level throws a catchable ValueError" do
    src = """
    <?php
    try { trigger_error("x", E_ERROR); } catch (ValueError $e) { echo $e->getMessage(), "\\n"; }
    """

    assert {out, 0} = run(src)

    assert out ==
             "trigger_error(): Argument #2 ($error_level) must be one of E_USER_ERROR, E_USER_WARNING, E_USER_NOTICE, or E_USER_DEPRECATED\n"
  end
end
