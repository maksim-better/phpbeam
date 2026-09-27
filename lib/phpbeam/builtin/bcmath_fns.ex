defmodule PhpBeam.Builtin.BcmathFns do
  @moduledoc """
  ext/bcmath — 14 functions over arbitrary-precision decimal strings.

  Probed php 8.4 semantics: scale TRUNCATES toward zero (never rounds);
  bcmod truncates both operands to integer part (10.5 -> 1, -10.5 -> -1);
  bcpow with negative exponent yields "0"; division by zero raises
  DivisionByZeroError; scale state rides ini `bcmath.scale` (bcscale()
  returns the OLD scale). bcround takes a RoundingMode enum case.
  """

  alias PhpBeam.Eval
  alias PhpBeam.Error

  @well_formed ~r/^[+-]?(\d+(\.\d*)?|\.\d+)$/

  def register(fns) do
    entries = %{
      "bcadd" => &bcadd/2,
      "bcsub" => &bcsub/2,
      "bcmul" => &bcmul/2,
      "bcdiv" => &bcdiv/2,
      "bcdivmod" => &bcdivmod/2,
      "bcmod" => &bcmod/2,
      "bcpow" => &bcpow/2,
      "bcpowmod" => &bcpowmod/2,
      "bcsqrt" => &bcsqrt/2,
      "bccomp" => &bccomp/2,
      "bcscale" => &bcscale/2,
      "bcfloor" => &bcfloor/2,
      "bcceil" => &bcceil/2,
      "bcround" => &bcround/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, wrapped)
  end

  # ────────────────────────── number core ──────────────────────────

  @type bcn :: %{mag: non_neg_integer(), scale: non_neg_integer(), neg?: boolean()}

  @doc "parse a well-formed decimal string; nil when malformed"
  @spec parse(String.t()) :: bcn() | nil
  def parse(s) do
    if Regex.match?(@well_formed, s) do
      {sign, body} =
        case s do
          "-" <> rest -> {true, rest}
          "+" <> rest -> {false, rest}
          _ -> {false, s}
        end

      {int_part, frac} =
        case String.split(body, ".") do
          [i] -> {i, ""}
          [i, f] -> {i, f}
          _ -> {body, ""}
        end

      int_part = if int_part == "", do: "0", else: int_part
      mag = String.to_integer(int_part <> frac)
      %{mag: mag, scale: String.length(frac), neg?: sign and mag != 0}
    end
  end

  @doc "value = signed integer / 10^scale"
  def from_scaled(n, scale) do
    %{mag: abs(n), scale: scale, neg?: n < 0}
  end

  def to_scaled(%{mag: m, scale: s, neg?: neg?}, target_scale) do
    # caller guarantees target_scale >= s (rescale first otherwise)
    v = m * pow10(target_scale - s)
    if neg?, do: -v, else: v
  end

  # truncate from `scale` down to `target` (toward zero), pad up if needed
  def rescale(%{mag: m, scale: s, neg?: neg?}, target) do
    cond do
      target >= s ->
        %{from_scaled(m * pow10(target - s), target) | neg?: neg?}

      true ->
        m2 = div(m, pow10(s - target))
        %{from_scaled(m2, target) | neg?: neg? and m2 != 0}
    end
  end

  def format(%{mag: m, scale: s, neg?: neg?}) do
    str = Integer.to_string(m)
    neg = if neg? and m != 0, do: "-", else: ""

    cond do
      s == 0 ->
        neg <> str

      byte_size(str) <= s ->
        neg <> "0." <> String.pad_leading(str, s, "0")

      true ->
        {i, f} = String.split_at(str, byte_size(str) - s)
        neg <> i <> "." <> f
    end
  end

  defp pow10(n), do: List.duplicate(0, n) |> Enum.reduce(1, fn _, a -> a * 10 end)

  # ────────────────────────── argument plumbing ──────────────────────────

  defp throw_err(class, fname, msg, i) do
    i2 = PhpBeam.Interp.push_frame(i, fname, [])
    {obj, i3} = Eval.materialize_native({:native_error, class, msg}, i2)
    {:unwind, {:php_throw, obj}, i3}
  end

  # operand fetch: string (or coercible) → bcn; unwind on malformed/error
  defp arg_bcn(i, vals, pos, fname, pname) do
    v = Enum.at(vals, pos - 1, :null)

    s =
      case v do
        {:string, s} -> s
        {:int, n} -> Integer.to_string(n)
        {:float, f} -> PhpBeam.Value.float_to_string(f)
        _ -> nil
      end

    if is_binary(s) do
      case parse(s) do
        nil ->
          throw_err("ValueError", fname, "#{fname}(): Argument ##{pos} ($#{pname}) is not well-formed", i)

        bcn ->
          {:ok, bcn}
      end
    else
      given =
        case v do
          {:bool, true} -> "true"
          {:bool, false} -> "false"
          :null -> "null"
          {:int, _} -> "int"
          {:float, _} -> "float"
          {:array, _} -> "array"
          _ -> "unknown"
        end

      throw_err(
        "TypeError",
        fname,
        "#{fname}(): Argument ##{pos} ($#{pname}) must be of type string, #{given} given",
        i
      )
    end
  end

  defp arg_scale(i, vals, pos, fname, default) do
    case Enum.at(vals, pos - 1) do
      nil ->
        {:ok, default}

      v ->
        case v do
          {:int, n} ->
            {:ok, n}

          {:string, s} ->
            case Integer.parse(s) do
              {n, _} -> {:ok, n}
              :error -> scale_err(i, pos, fname)
            end

          _ ->
            scale_err(i, pos, fname)
        end
    end
  end

  defp scale_err(i, pos, fname) do
    throw_err("TypeError", fname, "#{fname}(): Argument ##{pos} ($scale) must be of type ?int", i)
  end

  # resolve the effective scale: explicit arg wins, else ini bcmath.scale
  defp current_scale(i) do
    case Map.get(i.ini, "bcmath.scale") do
      nil -> 0
      s ->
        case Integer.parse(to_string(s)) do
          {n, _} -> n
          :error -> 0
        end
    end
  end

  # ────────────────────────── functions ──────────────────────────

  defp bcadd(vals, i), do: add_sub(vals, i, "bcadd", &+/2)
  defp bcsub(vals, i), do: add_sub(vals, i, "bcsub", &-/2)

  defp add_sub(vals, i, fname, op) do
    sc = current_scale(i)

    with {:ok, s0} <- arg_scale(i, vals, 3, fname, sc),
         {:ok, a} <- arg_bcn(i, vals, 1, fname, "num1"),
         {:ok, b} <- arg_bcn(i, vals, 2, fname, "num2") do
      common = max(a.scale, b.scale)
      av = to_scaled(rescale(a, common), common)
      bv = to_scaled(rescale(b, common), common)
      r = op.(av, bv)
      out = rescale(from_scaled(r, common), s0)
      {:ok, {:string, format(out)}, i}
    end
  end

  defp bcmul(vals, i) do
    sc = current_scale(i)

    with {:ok, s0} <- arg_scale(i, vals, 3, "bcmul", sc),
         {:ok, a} <- arg_bcn(i, vals, 1, "bcmul", "num1"),
         {:ok, b} <- arg_bcn(i, vals, 2, "bcmul", "num2") do
      av = to_scaled(a, a.scale)
      bv = to_scaled(b, b.scale)
      out = rescale(from_scaled(av * bv, a.scale + b.scale), s0)
      {:ok, {:string, format(out)}, i}
    end
  end

  defp bcdiv(vals, i), do: divide(vals, i, "bcdiv", "num1", "num2")

  defp divide(vals, i, fname, p1, p2) do
    sc = current_scale(i)

    with {:ok, s0} <- arg_scale(i, vals, 3, fname, sc),
         {:ok, a} <- arg_bcn(i, vals, 1, fname, p1),
         {:ok, b} <- arg_bcn(i, vals, 2, fname, p2) do
      if b.mag == 0 do
        throw_err("DivisionByZeroError", fname, "Division by zero", i)
      else
        av = to_scaled(a, a.scale)
        bv = to_scaled(b, b.scale)
        # a/b at s0 decimals, truncating toward zero
        q = av * pow10(b.scale + s0)
        q = trunc_div(q, bv * pow10(a.scale))
        {:ok, {:string, format(from_scaled(q, s0))}, i}
      end
    end
  end

  defp bcdivmod(vals, i) do
    sc = current_scale(i)

    with {:ok, _s0} <- arg_scale(i, vals, 3, "bcdivmod", sc),
         {:ok, a} <- arg_bcn(i, vals, 1, "bcdivmod", "num1"),
         {:ok, b} <- arg_bcn(i, vals, 2, "bcdivmod", "num2") do
      if b.mag == 0 do
        throw_err("DivisionByZeroError", "bcdivmod", "Division by zero", i)
      else
        ai = int_part_scaled(a)
        bi = int_part_scaled(b)
        q = trunc_div(ai, bi)
        r = rem(ai, bi)
        arr = PhpBeam.PArray.from_pairs([{0, {:string, Integer.to_string(q)}}, {1, {:string, Integer.to_string(r)}}])
        {:ok, {:array, arr}, i}
      end
    end
  end

  defp bcmod(vals, i) do
    sc = current_scale(i)

    with {:ok, _s0} <- arg_scale(i, vals, 3, "bcmod", sc),
         {:ok, a} <- arg_bcn(i, vals, 1, "bcmod", "num1"),
         {:ok, b} <- arg_bcn(i, vals, 2, "bcmod", "num2") do
      if b.mag == 0 do
        throw_err("DivisionByZeroError", "bcmod", "Modulo by zero", i)
      else
        r = rem(int_part_scaled(a), int_part_scaled(b))
        {:ok, {:string, Integer.to_string(r)}, i}
      end
    end
  end

  defp bcpow(vals, i) do
    sc = current_scale(i)

    with {:ok, s0} <- arg_scale(i, vals, 3, "bcpow", sc),
         {:ok, base} <- arg_bcn(i, vals, 1, "bcpow", "num"),
         {:ok, exp} <- arg_bcn(i, vals, 2, "bcpow", "exponent") do
      e = trunc_exp(exp)

      r =
        if e < 0 do
          from_scaled(0, 0)
        else
          # full scaled magnitude participates: 2.5^2 = 6.25 (mag 25^2 @ scale 2)
          v = to_scaled(base, base.scale)
          from_scaled(int_pow(v, e), base.scale * e)
        end

      out = rescale(r, s0)
      {:ok, {:string, format(out)}, i}
    end
  end

  defp bcpowmod(vals, i) do
    sc = current_scale(i)

    with {:ok, _s0} <- arg_scale(i, vals, 4, "bcpowmod", sc),
         {:ok, base} <- arg_bcn(i, vals, 1, "bcpowmod", "num"),
         {:ok, exp} <- arg_bcn(i, vals, 2, "bcpowmod", "exponent"),
         {:ok, m} <- arg_bcn(i, vals, 3, "bcpowmod", "modulus") do
      cond do
        m.mag == 0 ->
          throw_err("DivisionByZeroError", "bcpowmod", "Modulo by zero", i)

        exp.neg? or exp.scale > 0 ->
          throw_err(
            "ValueError",
            "bcpowmod",
            "bcpowmod(): Argument #2 ($exponent) must be greater than or equal to 0",
            i
          )

        true ->
          b = int_part_scaled(base) |> Integer.mod(int_part_scaled(m))
          r = mod_pow(b, int_part_scaled(exp), int_part_scaled(m))
          {:ok, {:string, Integer.to_string(r)}, i}
      end
    end
  end

  defp bcsqrt(vals, i) do
    sc = current_scale(i)

    with {:ok, s0} <- arg_scale(i, vals, 2, "bcsqrt", sc),
         {:ok, a} <- arg_bcn(i, vals, 1, "bcsqrt", "num") do
      cond do
        a.neg? ->
          throw_err("ValueError", "bcsqrt", "bcsqrt(): Argument #1 ($num) cannot be negative", i)

        true ->
          v = to_scaled(a, a.scale) * pow10(2 * s0)
          r = isqrt(v)
          {:ok, {:string, format(from_scaled(r, s0))}, i}
      end
    end
  end

  defp bccomp(vals, i) do
    sc = current_scale(i)

    with {:ok, s0} <- arg_scale(i, vals, 3, "bccomp", sc),
         {:ok, a} <- arg_bcn(i, vals, 1, "bccomp", "num1"),
         {:ok, b} <- arg_bcn(i, vals, 2, "bccomp", "num2") do
      av = to_scaled(rescale(a, s0), s0)
      bv = to_scaled(rescale(b, s0), s0)
      cmp = cond do
        av < bv -> -1
        av > bv -> 1
        true -> 0
      end
      {:ok, {:int, cmp}, i}
    end
  end

  defp bcscale(vals, i) do
    old = current_scale(i)

    case vals do
      [v] ->
        n =
          case v do
            {:int, n} -> n
            {:string, s} -> String.to_integer(s)
            _ -> old
          end

        i2 = %{i | ini: Map.put(i.ini, "bcmath.scale", Integer.to_string(n))}
        {:ok, {:int, old}, i2}

      _ ->
        {:ok, {:int, old}, i}
    end
  end

  defp bcfloor(vals, i) do
    with {:ok, a} <- arg_bcn(i, vals, 1, "bcfloor", "num") do
      v = to_scaled(a, a.scale)
      f = Integer.floor_div(v, pow10(a.scale))
      {:ok, {:string, Integer.to_string(f)}, i}
    end
  end

  defp bcceil(vals, i) do
    with {:ok, a} <- arg_bcn(i, vals, 1, "bcceil", "num") do
      v = to_scaled(a, a.scale)
      p = pow10(a.scale)
      c = -Integer.floor_div(-v, p)
      {:ok, {:string, Integer.to_string(c)}, i}
    end
  end

  defp bcround(vals, i) do
    sc = current_scale(i)

    with {:ok, p0} <- arg_scale(i, vals, 2, "bcround", sc),
         {:ok, a} <- arg_bcn(i, vals, 1, "bcround", "num") do
      mode = enum_mode(i, Enum.at(vals, 2, :null))

      case mode do
        {:ok, m} ->
          {:ok, {:string, round_format(a, p0, m)}, i}

        u ->
          u
      end
    end
  end

  defp enum_mode(i, v) do
    case v do
      :null ->
        {:ok, :half_away}

      {:object, _} = ref ->
        case PhpBeam.Eval.get_object(i, ref) do
            %{class: "roundingmode"} = obj ->
              case PhpBeam.PArray.fetch(obj.props, {:string, "name"}) do
                {:ok, {:string, name}} -> {:ok, mode_from_name(name)}
                _ -> {:ok, :half_away}
              end

            _ ->
              {:unwind,
               {:php_throw,
                {:native_error, "TypeError",
                 "bcround(): Argument #3 ($mode) must be of type ?RoundingMode"}},
               i}
          end

      _ ->
        {:unwind,
         {:php_throw,
          {:native_error, "TypeError",
           "bcround(): Argument #3 ($mode) must be of type ?RoundingMode"}},
         i}
    end
  end

  defp mode_from_name(name) do
    case name do
      "HalfAwayFromZero" -> :half_away
      "HalfTowardsZero" -> :half_towards
      "HalfEven" -> :half_even
      "HalfOdd" -> :half_odd
      "TowardsZero" -> :towards
      "AwayFromZero" -> :away
      "NegativeInfinity" -> :neg_inf
      "PositiveInfinity" -> :pos_inf
      _ -> :half_away
    end
  end

  # magnitude-based rounding: q whole parts, r remainder vs factor
  defp round_format(a, p, mode) do
    if p >= a.scale do
      format(rescale(a, p))
    else
      v = to_scaled(a, a.scale)
      factor = pow10(a.scale - p)
      mag = abs(v)
      q = div(mag, factor)
      r = rem(mag, factor)
      half = div(factor, 2)

      bump =
        case mode do
          :half_away -> r >= half
          :half_towards -> r > half
          :half_even -> r > half or (r == half and rem(q, 2) == 1)
          :half_odd -> r > half or (r == half and rem(q, 2) == 0)
          :towards -> false
          :away -> r > 0
          :neg_inf -> v < 0
          :pos_inf -> v > 0
        end

      q2 = if bump, do: q + 1, else: q
      signed = if v < 0, do: -q2, else: q2
      format(from_scaled(signed, p))
    end
  end

  # ────────────────────────── helpers ──────────────────────────

  defp int_part_scaled(%{mag: m, scale: s, neg?: neg?}) do
    v = div(m, pow10(s))
    if neg?, do: -v, else: v
  end

  defp trunc_exp(%{mag: m, scale: s, neg?: neg?}) do
    e = div(m, pow10(s))
    if neg?, do: -e, else: e
  end

  defp trunc_div(a, b) do
    q = div(abs(a), abs(b))
    if (a < 0) != (b < 0), do: -q, else: q
  end

  defp int_pow(_b, 0), do: 1
  defp int_pow(b, e) when e > 0, do: int_pow_iter(b, e, 1)

  defp int_pow_iter(_b, 0, acc), do: acc

  defp int_pow_iter(b, e, acc) do
    acc2 = if rem(e, 2) == 1, do: acc * b, else: acc
    int_pow_iter(b * b, div(e, 2), acc2)
  end

  defp mod_pow(_b, 0, m), do: Integer.mod(1, m)

  defp mod_pow(b, e, m) do
    b = Integer.mod(b, m)
    do_mod_pow(b, e, m, Integer.mod(1, m))
  end

  defp do_mod_pow(_b, 0, _m, acc), do: acc

  defp do_mod_pow(b, e, m, acc) do
    acc2 = if rem(e, 2) == 1, do: Integer.mod(acc * b, m), else: acc
    do_mod_pow(Integer.mod(b * b, m), div(e, 2), m, acc2)
  end

  defp isqrt(0), do: 0
  defp isqrt(1), do: 1

  defp isqrt(n) when n > 0 do
    bits = :erlang.integer_to_binary(n, 2) |> byte_size()
    x = 2 ** (div(bits + 1, 2) + 1)
    isqrt_iter(n, x)
  end

  defp isqrt_iter(n, x) do
    y = div(x + div(n, x), 2)
    if y < x, do: isqrt_iter(n, y), else: x
  end
end
