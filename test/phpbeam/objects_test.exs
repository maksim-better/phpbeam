defmodule PhpBeam.ObjectsTest do
  @moduledoc """
  Seam tests for the object registry authority (ARCHITECTURE_DESIGN §3.4):
  handle identity, write-through, stdclass shape, instance defaults.
  """
  use ExUnit.Case, async: true

  alias PhpBeam.Objects

  defp cls(props \\ []) do
    %{
      props: props,
      parent: nil,
      modifiers: []
    }
  end

  test "make_instance registers a handle and assigns sequential ids" do
    {{:object, 1}, i2} = Objects.make_instance(%PhpBeam.Interp{classes: %{"foo" => cls()}}, "foo")
    {{:object, 2}, _} = Objects.make_instance(i2, "foo")
    assert i2.next_obj == 2
  end

  test "put_object is visible through every holder of the handle (reference semantics)" do
    {ref, i2} = Objects.make_instance(%PhpBeam.Interp{}, "stdclass")
    obj = Objects.get_object(i2, ref)
    i3 = Objects.put_object(i2, ref, %{obj | class: "updated"})
    # the same handle read again sees the write
    assert Objects.get_object(i3, ref).class == "updated"
  end

  test "new_stdclass marks the map and starts with given props" do
    {ref, i2} = Objects.new_stdclass(%PhpBeam.Interp{}, PhpBeam.PArray.new())
    obj = Objects.get_object(i2, ref)
    assert obj.class == "stdclass"
    assert obj.stdclass? == true
  end

  test "instantiate seeds declared prop defaults, skipping static/readonly" do
    classes = %{
      "base" => cls([%{display: "b", default: {:int, 1}, static?: false}]),
      "kid" =>
        cls([
          %{display: "plain", default: {:int, 5}, static?: false},
          %{display: "st", default: {:int, 9}, static?: true},
          %{display: "ro", default: {:int, 9}, static?: false, readonly?: true}
        ])
        |> Map.put(:parent, "base")
    }

    obj = Objects.instantiate(%PhpBeam.Interp{classes: classes}, "kid", 7)
    assert obj.__ref__ == 7
    assert PhpBeam.PArray.get(obj.props, {:string, "plain"}) == {:int, 5}
    # inherited default comes along
    assert PhpBeam.PArray.get(obj.props, {:string, "b"}) == {:int, 1}
    # static and readonly props do NOT start initialized
    assert PhpBeam.PArray.get(obj.props, {:string, "st"}) == :null_value
    assert PhpBeam.PArray.get(obj.props, {:string, "ro"}) == :null_value
  end

  test "get_object on a non-handle returns the value unchanged" do
    assert Objects.get_object(%PhpBeam.Interp{}, {:int, 3}) == {:int, 3}
  end
end

defmodule PhpBeam.ClosureTest do
  @moduledoc "Seam tests: the two closure shapes discriminate by arity only via Closure"
  use ExUnit.Case, async: true

  test "runtime/7 constructs the 8-elem value; ast?/runtime? discriminate" do
    v = PhpBeam.Closure.runtime([], {:int, 1}, %{}, false, "f.php", 3, false)
    assert PhpBeam.Closure.runtime?(v)
    refute PhpBeam.Closure.ast?(v)
    # parser shape stays 6-elem
    assert PhpBeam.Closure.ast?({:closure, [], [], false, {:int, 1}, false})
    refute PhpBeam.Closure.runtime?({:closure, [], [], false, {:int, 1}, false})
  end
end
