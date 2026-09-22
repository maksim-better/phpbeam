defmodule PhpBeam.ValueTest do
  use ExUnit.Case, async: true
  import PhpBeam.Value

  defp eq(a, b), do: loose_eq(a, b)
  defp s(x), do: {:string, x}
  defp i(x), do: {:int, x}
  defp f(x), do: {:float, x}

  # ── numeric strings (probed against PHP 8.4) ──

  test "is_numeric" do
    assert numeric_string?(s("42"))
    assert numeric_string?(s("1.5"))
    assert numeric_string?(s("1e5"))
    assert numeric_string?(s("  42  "))
    assert numeric_string?(s("-13.2e+3"))
    assert numeric_string?(s("0"))
    refute numeric_string?(s("0x1A"))
    refute numeric_string?(s("42abc"))
    refute numeric_string?(s(""))
    refute numeric_string?(s("1_000"))
  end

  test "string number classification" do
    assert classify_string_number(s("1abc")) == {:leading, {:int, 1}}
    assert classify_string_number(s("abc")) == :non_numeric
    assert classify_string_number(s("  42  ")) == {:numeric, {:int, 42}}
    assert classify_string_number(s("1e2")) == {:numeric, {:float, 100.0}}
  end

  # ── casts ──

  test "to_int casts" do
    assert to_int(s("0x1A")) == {:ok, i(0)}
    assert to_int(s("")) == {:ok, i(0)}
    assert to_int(s(" 12abc")) == {:ok, i(12)}
    assert to_int({:bool, true}) == {:ok, i(1)}
    assert to_int({:array, PhpBeam.PArray.from_pairs([{nil, i(1)}, {nil, i(2)}])}) == {:ok, i(1)}
    assert to_int({:array, PhpBeam.PArray.new()}) == {:ok, i(0)}
    assert to_int(s("9223372036854775808")) == {:ok, i(9_223_372_036_854_775_807)}
    assert to_int(f(1.9)) == {:ok, i(1)}
    assert to_int(f(-1.9)) == {:ok, i(-1)}
  end

  test "cast_string basics" do
    assert cast_string({:bool, true}) == {:ok, "1"}
    assert cast_string(:null) == {:ok, ""}
    assert cast_string(f(0.5)) == {:ok, "0.5"}
    assert {:warn_array, "Array"} = cast_string({:array, PhpBeam.PArray.new()})
  end

  # ── == matrix (each line probed) ──

  test "loose equality" do
    refute eq(i(0), s(""))
    refute eq(i(0), s("a"))
    assert eq(i(42), s("42.0"))
    refute eq(i(42), s("42x"))
    assert eq(:null, i(0))
    assert eq(:null, {:bool, false})
    assert eq(:null, s(""))
    assert eq(:null, {:array, PhpBeam.PArray.new()})
    assert eq({:array, PhpBeam.PArray.new()}, {:bool, false})
    refute eq({:array, PhpBeam.PArray.new()}, i(0))
    assert eq({:array, PhpBeam.PArray.from_pairs([{nil, i(1)}])}, {:bool, true})
    refute eq({:array, PhpBeam.PArray.from_pairs([{nil, i(1)}])}, i(1))
    refute eq(f(0.0), s(""))
    refute eq(s(""), f(0.0))
    assert eq({:bool, true}, s("abc"))
    assert eq({:bool, false}, s("0"))
    assert eq(s("100"), s("1e2"))
    assert eq(s("abc"), s("abc"))
    assert eq(i(0), s("0.0"))
  end

  test "array equality" do
    a1 = PhpBeam.PArray.from_pairs([{s("a"), i(1)}, {s("b"), i(2)}])
    a2 = PhpBeam.PArray.from_pairs([{s("b"), i(2)}, {s("a"), i(1)}])
    assert eq({:array, a1}, {:array, a2})

    l1 = PhpBeam.PArray.from_pairs([{nil, i(1)}, {nil, i(2)}])
    l2 = PhpBeam.PArray.from_pairs([{nil, i(2)}, {nil, i(1)}])
    refute eq({:array, l1}, {:array, l2})
  end

  test "=== identity" do
    refute strict_eq(i(42), f(42.0))
    assert strict_eq(i(42), i(42))
    a1 = PhpBeam.PArray.from_pairs([{i(0), i(1)}])
    a2 = PhpBeam.PArray.from_pairs([{s("0"), i(1)}])
    assert strict_eq({:array, a1}, {:array, a2})

    o1 = PhpBeam.PArray.from_pairs([{s("a"), i(1)}, {s("b"), i(2)}])
    o2 = PhpBeam.PArray.from_pairs([{s("b"), i(2)}, {s("a"), i(1)}])
    refute strict_eq({:array, o1}, {:array, o2})
  end

  # ── comparison ──

  test "compare basics" do
    assert compare(i(1), i(2)) == -1
    assert compare(s("a"), s("b")) == -1
    assert compare(s("100"), s("1e2")) == 0
    assert compare(s("10"), s("9")) == 1
    assert compare(s("a"), i(0)) == 1
    assert compare(:null, s("a")) == -1
    assert compare(s(""), s("a")) == -1
    l12 = {:array, PhpBeam.PArray.from_pairs([{nil, i(1)}, {nil, i(2)}])}
    l123 = {:array, PhpBeam.PArray.from_pairs([{nil, i(1)}, {nil, i(2)}, {nil, i(3)}])}
    assert compare(l12, l123) == -1
  end

  # ── arithmetic (warnings/TypeErrors probed) ──

  test "string arithmetic" do
    assert arith(:+, s("1abc"), i(1)) == {:ok, i(2)}
    assert {:error, %{kind: :type_error}} = arith(:+, s("abc"), i(1))
    assert arith(:+, s("  42  "), i(1)) == {:ok, i(43)}
    assert arith(:+, s("1e2"), i(0)) == {:ok, f(100.0)}
    assert arith(:+, s("1abc"), i(1)) != {:leading, i(1)}
  end

  test "int overflow to float" do
    assert arith(:+, i(9_223_372_036_854_775_807), i(1)) == {:ok, f(9.223372036854776e18)}
  end

  test "division and modulo" do
    assert divide(i(7), i(2)) == {:ok, f(3.5)}
    assert divide(i(4), i(2)) == {:ok, i(2)}
    assert modulo(i(7), i(3)) == {:ok, i(1)}
    assert modulo(i(-7), i(3)) == {:ok, i(-1)}
    assert modulo(i(7), i(-3)) == {:ok, i(1)}
    assert {:error, %{kind: :division_by_zero_error}} = modulo(i(7), i(0))
    assert {:error, %{kind: :division_by_zero_error}} = divide(i(7), i(0))
    assert intdiv(i(7), i(2)) == {:ok, i(3)}

    assert {:error, %{kind: :arithmetic_error}} =
             intdiv(i(-9_223_372_036_854_775_808), i(-1))
  end

  test "power" do
    assert power(i(2), i(10)) == {:ok, i(1024)}
    assert power(i(2), i(-1)) == {:ok, f(0.5)}
  end

  test "increment/decrement" do
    assert increment(s("az")) == s("ba")
    assert increment(s("Zz")) == s("AAa")
    assert increment(s("a9")) == s("b0")
    assert increment(s("9")) == i(10)
    assert increment(:null) == i(1)
    assert increment(f(1.5)) == f(2.5)
    assert decrement(s("a")) == s("a")
    assert decrement(:null) == :null
  end

  # ── float formatting (all probed) ──

  test "float_to_string precision 14" do
    cases = [
      {0.1, "0.1"},
      {1.0 / 3, "0.33333333333333"},
      {1.0e15, "1.0E+15"},
      {1.0e14, "1.0E+14"},
      {0.5, "0.5"},
      {-0.0, "-0"},
      {1.0, "1"},
      {1.5e-7, "1.5E-7"},
      {0.0001, "0.0001"},
      {123_456_789_012_345.0, "1.2345678901234E+14"},
      {1.23456789012345678, "1.2345678901235"},
      {1.23456789012344, "1.2345678901234"},
      {0.3, "0.3"},
      {99_999_999_999_999.9, "1.0E+14"},
      {0.999999999999999999, "1"},
      {123_456.789012345678, "123456.78901235"},
      {1.0e-6, "1.0E-6"},
      {1.0e-5, "1.0E-5"},
      {1.0e100, "1.0E+100"},
      {4.2, "4.2"},
      {100.0, "100"},
      {1.0e13, "10000000000000"}
    ]

    for {f, expect} <- cases do
      assert float_to_string(f) == expect, "float_to_string(#{inspect(f)})"
    end
  end

  test "float_serialize shortest" do
    cases = [
      {1.0 / 3, "0.3333333333333333"},
      {0.1 + 0.2, "0.30000000000000004"},
      {1.0e14, "100000000000000"},
      {1.0e13, "10000000000000"},
      {123_456_789_012_345.0, "123456789012345"},
      {0.00001, "1.0E-5"},
      {0.0001, "0.0001"},
      {1.5e-7, "1.5E-7"},
      {1_234_567.8912345, "1234567.8912345"},
      {0.5, "0.5"},
      {1.0, "1"},
      {100.0, "100"},
      {1.0e15, "1000000000000000"},
      {999_999_999_999_999.9, "999999999999999.9"},
      {9_007_199_254_740_992.0, "9007199254740992"},
      {5.0e-324, "5.0E-324"},
      {1.7976931348623157e308, "1.7976931348623157E+308"}
    ]

    for {f, expect} <- cases do
      assert float_serialize(f) == expect, "float_serialize(#{inspect(f)})"
    end
  end

  test "truthiness" do
    refute truthy?(s("0"))
    refute truthy?(s(""))
    refute truthy?(i(0))
    refute truthy?(f(0.0))
    refute truthy?({:array, PhpBeam.PArray.new()})
    refute truthy?(:null)
    assert truthy?(s("00"))
    assert truthy?(s(" "))
    assert truthy?(i(-1))
  end
end
