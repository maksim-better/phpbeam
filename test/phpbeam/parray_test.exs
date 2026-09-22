defmodule PhpBeam.PArrayTest do
  use ExUnit.Case, async: true
  alias PhpBeam.PArray

  defmacrop i(x), do: quote(do: {:int, unquote(x)})
  defmacrop s(x), do: quote(do: {:string, unquote(x)})

  test "insertion order preserved; replace keeps position" do
    a =
      PArray.new()
      |> PArray.put(s("x"), i(1))
      |> ok!
      |> PArray.put(s("y"), i(2))
      |> ok!
      |> PArray.put(s("z"), i(3))
      |> ok!
      |> PArray.put(s("x"), i(9))
      |> ok!

    assert PArray.to_pairs(a) == [{"x", i(9)}, {"y", i(2)}, {"z", i(3)}]
  end

  test "numeric string keys normalize; 01 / -0 / 1.5 stay strings" do
    a = PArray.from_pairs([{s("123"), i(1)}, {s("01"), i(2)}, {s("-0"), i(3)}, {s("1.5"), i(4)}])
    assert PArray.keys(a) == [123, "01", "-0", "1.5"]
    assert PArray.fetch(a, i(123)) == {:ok, i(1)}
    assert PArray.fetch(a, s("123")) == {:ok, i(1)}
  end

  test "int64-range string keys normalize" do
    a = PArray.from_pairs([{s("9223372036854775807"), i(1)}, {s("-9223372036854775808"), i(2)}])
    assert PArray.keys(a) == [9_223_372_036_854_775_807, -9_223_372_036_854_775_808]
  end

  test "overflow string keys stay strings" do
    a = PArray.from_pairs([{s("9223372036854775808"), i(1)}])
    assert PArray.keys(a) == ["9223372036854775808"]
  end

  test "auto index: max int key + 1 (even negative), high-water survives unset" do
    a = PArray.from_pairs([{i(5), i(1)}]) |> PArray.delete(i(5)) |> ok!
    a2 = PArray.push(a, i(9))
    assert PArray.keys(a2) == [6]

    b = PArray.from_pairs([{i(-5), i(1)}]) |> PArray.push(i(9))
    assert PArray.keys(b) == [-5, -4]
  end

  test "delete and order stability" do
    a = PArray.from_pairs([{nil, i(1)}, {nil, i(2)}, {nil, i(3)}])
    a2 = a |> PArray.delete(i(1)) |> ok!
    assert PArray.values(a2) == [i(1), i(3)]
    a3 = PArray.put(a2, i(0), i(10)) |> ok!
    assert PArray.to_pairs(a3) == [{0, i(10)}, {2, i(3)}]
    # high-water: keys were 0,1,2 so the next auto index is 3
    a4 = PArray.push(a3, i(4))
    assert PArray.keys(a4) == [0, 2, 3]
  end

  test "shift and pop" do
    # PHP: [1, "k" => 2, 3] has keys 0, "k", 1 (max int key was 0)
    a = PArray.from_pairs([{nil, i(1)}, {s("k"), i(2)}, {nil, i(3)}])
    assert PArray.keys(a) == [0, "k", 1]
    {:ok, {0, i(1)}, a2} = PArray.shift(a)
    {:ok, {1, i(3)}, a3} = PArray.pop(a2)
    assert PArray.to_pairs(a3) == [{"k", i(2)}]
    assert PArray.pop(PArray.new()) == :error
  end

  test "union keeps left first, adds missing right keys" do
    l = PArray.from_pairs([{i(5), i(1)}])
    r = PArray.from_pairs([{i(1), i(2)}, {i(5), i(99)}])
    u = PArray.union(l, r)
    assert PArray.to_pairs(u) == [{5, i(1)}, {1, i(2)}]
  end

  test "renumber" do
    a = PArray.from_pairs([{s("a"), i(1)}, {s("b"), i(2)}])
    assert PArray.to_pairs(PArray.renumber(a)) == [{0, i(1)}, {1, i(2)}]
  end

  defp ok!({:ok, a}), do: a
end
