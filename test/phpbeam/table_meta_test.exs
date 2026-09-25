defmodule PhpBeam.TableMetaTest do
  @moduledoc """
  Seam tests for Classes.Table's metadata read API (ARCHITECTURE_DESIGN §3.3):
  named views over stored shapes, inheritance-aware member tables.
  ReflectionClass (26_reflection.php) is the byte-level consumer.
  """
  use ExUnit.Case, async: true

  alias PhpBeam.Classes.Table

  @src """
  <?php
  class Base { public function bm($a, int $b = 2) {} }
  class Kid extends Base {
    public int $x = 1;
    private $hidden;
    const K = 5;
    public function km(string ...$rest) {}
    public function bm($a, int $b = 2) {}
  }
  """

  defp meta do
    {_, _, interp} = PhpBeam.Interp.run(@src, "meta_test.php")
    Table.class_meta(interp, "kid")
  end

  test "class_meta renders the declaration" do
    m = meta()
    assert m.name == "Kid"
    assert m.kind == :class
    assert m.parent == "base"
    assert m.abstract? == false
    assert Map.has_key?(m.consts, "K")
  end

  test "methods merge along the chain with child shadowing" do
    m = meta()
    # inherited base method visible
    assert Map.has_key?(m.methods, "km")
    # Kid::bm shadows Base::bm
    assert m.methods["bm"].declaring_class == "kid"
    # the base copy is gone (shadowed, php getMethods() would show one entry)
    bm_params = m.methods["bm"].params
    assert length(bm_params) == 2
  end

  test "param_meta carries type spelling, defaults, variadic" do
    m = meta()
    [p1, p2] = m.methods["bm"].params
    assert p1.name == "a"
    assert p1.type == nil
    assert p1.optional? == false
    assert p2.type == "int"
    assert p2.optional? == true

    var = m.methods["km"].params |> hd()
    assert var.variadic? == true
    assert var.type == "string"
  end

  test "prop_meta merges and keeps visibility/default" do
    m = meta()
    assert m.props["x"].visibility == :public
    assert m.props["x"].readonly? == false
    assert m.props["hidden"].visibility == :private
    assert m.props["hidden"].default == :null
  end

  test "unknown class renders nil" do
    {_, _, interp} = PhpBeam.Interp.run("<?php ", "meta_test.php")
    assert Table.class_meta(interp, "nope") == nil
  end
end
