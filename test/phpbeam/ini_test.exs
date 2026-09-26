defmodule PhpBeam.IniTest do
  @moduledoc """
  PHASE A2 loading-chain semantics: startup entries (the -c/-d layer),
  auto_prepend/auto_append execution order, disable_functions, perdir
  (.user.ini) filtering.
  """
  use ExUnit.Case, async: true

  alias PhpBeam.Ini

  defp run(src, entries), do: PhpBeam.Interp.run_quiet(src) |> then(fn _ -> run3(src, entries) end)

  defp run3(src, entries) do
    {out, code, _} = PhpBeam.Interp.run(src, nil, entries)
    {out, code}
  end

  test "php.ini file syntax: comments, sections, quotes" do
    parsed =
      Ini.parse_string("x=1\n; comment\n[Sect]\ny = \"quoted\"\nz='sq'\nbrokenline\n w=2 \n")

    assert parsed == [{"x", "1"}, {"y", "quoted"}, {"z", "sq"}, {"w", "2"}]
  end

  test "apply_entries drops unregistered names; perdir keeps PERDIR-level only" do
    entries = [
      {"memory_limit", "256M"},
      {"not_an_ini_entry", "x"},
      {"auto_prepend_file", "/tmp/x.php"}
    ]

    startup = Ini.apply_entries(%{}, entries, :startup)
    assert startup["memory_limit"] == "256M"
    assert startup["auto_prepend_file"] == "/tmp/x.php"
    refute Map.has_key?(startup, "not_an_ini_entry")

    perdir = Ini.apply_entries(%{}, entries, :perdir)
    # memory_limit is PHP_INI_ALL (perdir-allowed), extension_dir is not
    assert perdir["memory_limit"] == "256M"
    refute Map.has_key?(Ini.apply_entries(%{}, [{"extension_dir", "/x"}], :perdir), "extension_dir")
  end

  test "auto_prepend runs before main, auto_append after (normal end only)" do
    File.write!("/tmp/phpbeam_test_prepend.php", "<?php echo \"PRE\\n\";")
    File.write!("/tmp/phpbeam_test_append.php", "<?php echo \"APP\\n\";")

    entries = [
      {"auto_prepend_file", "/tmp/phpbeam_test_prepend.php"},
      {"auto_append_file", "/tmp/phpbeam_test_append.php"}
    ]

    assert {"PRE\nMAIN\nAPP\n", 0} = run3("<?php echo \"MAIN\\n\";", entries)
    # exit(): append skipped, exit code preserved
    assert {"PRE\nMAIN\n", 3} = run3("<?php echo \"MAIN\\n\"; exit(3);", entries)
  end

  test "prepend throw preempts the main script" do
    File.write!("/tmp/phpbeam_test_prepend2.php", "<?php throw new RuntimeException('p');")

    entries = [{"auto_prepend_file", "/tmp/phpbeam_test_prepend2.php"}]

    {out, code} = run3("<?php echo \"MAIN\\n\";", entries)
    assert out =~ "Uncaught RuntimeException: p"
    refute out =~ "MAIN"
    assert code == 255
  end

  test "disable_functions removes the functions outright" do
    entries = [{"disable_functions", "strlen"}]

    assert {"bool(false)\nbool(true)\n", 0} =
             run3(
               "<?php var_dump(function_exists('strlen'), function_exists('count'));",
               entries
             )
  end

  test "ini_restore returns to the startup value, not the compiled default" do
    entries = [{"memory_limit", "512M"}]

    assert {"512M\n64M\n512M\n", 0} =
             run3(
               "<?php ini_set('memory_limit','64M'); ini_restore('memory_limit'); echo ini_get('memory_limit'), \"\\n\"; ini_set('memory_limit','64M'); echo ini_get('memory_limit'), \"\\n\"; ini_restore('memory_limit'); echo ini_get('memory_limit'), \"\\n\";",
               entries
             )
  end

  test "the full registered table is seeded at boot" do
    assert {"128M\n", 0} = run3("<?php echo ini_get('memory_limit'), \"\\n\";", [])
    assert Ini.registered?("session.save_path")
    assert Ini.access("error_reporting") == 7
    assert Ini.access("extension_dir") == 4
  end
end
