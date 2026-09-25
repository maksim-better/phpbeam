defmodule PhpBeam.Builtin.MathFns do
  @moduledoc "Math functions."

  alias PhpBeam.Value

  def register(fns) do
    entries = %{
      "abs" => &abs_v/2,
      "ceil" => &ceil_v/2,
      "floor" => &floor_v/2,
      "round" => &round_v/2,
      "intdiv" => &intdiv_v/2,
      "pow" => &pow_v/2,
      "sqrt" => &sqrt_v/2,
      "max" => &max_v/2,
      "min" => &min_v/2,
      "fmod" => &fmod_v/2,
      "mt_rand" => &rand_v/2,
      "rand" => &rand_v/2,
      "random_int" => &rand_v/2,
      "random_bytes" => &random_bytes_v/2,
      "number_format" => nil,
      "is_finite" => &is_finite/2,
      "is_infinite" => &is_infinite/2,
      "is_nan" => &is_nan/2,
      "sin" => trig(:sin),
      "cos" => trig(:cos),
      "tan" => trig(:tan),
      "log" => &log_v/2,
      "log10" => &log10_v/2,
      "exp" => &exp_v/2,
      "deg2rad" => &deg2rad/2,
      "rad2deg" => &rad2deg/2,
      "pi" => &pi_v/2,
      "fdiv" => &fdiv_v/2,
      "hypot" => &hypot/2,
      "decbin" => base_convert2(2, :to),
      "bindec" => base_convert2(2, :from),
      "dechex" => base_convert2(16, :to),
      "hexdec" => base_convert2(16, :from),
      "decoct" => base_convert2(8, :to),
      "octdec" => base_convert2(8, :from),
      "base_convert" => &base_convert/2
    }

    Enum.reduce(entries, fns, fn
      {_k, nil}, acc -> acc
      {name, fun}, acc -> Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
    end)
  end

  defp num(v) do
    case v do
      {:int, _} -> v
      {:float, _} -> v
      _ -> Value.to_float(v) |> elem(1)
    end
  end

  defp abs_v([v | _], i), do: {:ok, num_abs(v), i}

  defp num_abs({:int, n}), do: {:int, abs(n)}
  defp num_abs({:float, f}), do: {:float, abs(f)}
  defp num_abs(v), do: v

  defp ceil_v([v | _], i) do
    case num(v) do
      {:int, n} -> {:ok, {:int, n}, i}
      {:float, f} -> {:ok, {:int, Float.ceil(f)}, i}
    end
  end

  defp floor_v([v | _], i) do
    case num(v) do
      {:int, n} -> {:ok, {:int, n}, i}
      {:float, f} -> {:ok, {:int, Float.floor(f)}, i}
    end
  end

  defp round_v([v | rest], i) do
    case num(v) do
      {:int, n} ->
        {:ok, {:int, n}, i}

      {:float, f} ->
        precision =
          case rest do
            [{:int, p} | _] -> p
            _ -> 0
          end

        if precision > 0 do
          {:ok, {:float, round_f(f, precision)}, i}
        else
          {:ok, {:int, round_half_away(f)}, i}
        end
    end
  end

  # PHP rounds half away from zero
  defp round_half_away(f) do
    cond do
      f >= 0 -> trunc(f + 0.5)
      true -> trunc(f - 0.5)
    end
  end

  defp round_f(f, p), do: Float.round(f, p)

  defp intdiv_v([a, b | _], i) do
    case Value.intdiv(a, b) do
      {:ok, v} ->
        {:ok, v, i}

      {:error, err} ->
        {:ok, {:unwind, {:php_throw, {:native_error, PhpBeam.Error.php_class(err), err.message}}},
         i}
    end
  end

  defp pow_v([a, b | _], i) do
    case Value.power(a, b) do
      {:ok, v} ->
        {:ok, v, i}

      {:error, err} ->
        {:ok, {:unwind, {:php_throw, {:native_error, PhpBeam.Error.php_class(err), err.message}}},
         i}
    end
  end

  defp sqrt_v([v | _], i), do: {:ok, {:float, :math.sqrt(fval(v))}, i}

  defp fval(v) do
    case num(v) do
      {:int, n} -> n * 1.0
      {:float, f} -> f
    end
  end

  defp max_v(vals, i) do
    items = flatten_variadic(vals)

    if items == [] do
      {:ok, :null, i}
    else
      {:ok,
       Enum.reduce(tl(items), hd(items), fn a, best ->
         if Value.compare(a, best) >= 0, do: a, else: best
       end), i}
    end
  end

  defp min_v(vals, i) do
    items = flatten_variadic(vals)

    if items == [] do
      {:ok, :null, i}
    else
      {:ok,
       Enum.reduce(tl(items), hd(items), fn a, best ->
         if Value.compare(a, best) <= 0, do: a, else: best
       end), i}
    end
  end

  defp flatten_variadic([{:array, arr}]), do: PhpBeam.PArray.values(arr)
  defp flatten_variadic(vals), do: vals

  defp fmod_v([a, b | _], i) do
    fa = fval(a)
    fb = fval(b)
    {:ok, {:float, fa - fb * trunc(fa / fb)}, i}
  end

  defp fdiv_v([a, b | _], i) do
    if fval(b) == 0.0 do
      # PHP returns INF; approximated by the largest float
      {:ok, {:float, 1.7976931348623157e308}, i}
    else
      {:ok, {:float, fval(a) / fval(b)}, i}
    end
  end

  defp hypot([a, b | _], i) do
    x = fval(a)
    y = fval(b)
    {:ok, {:float, :math.sqrt(x * x + y * y)}, i}
  end

  defp rand_v(vals, i) do
    case vals do
      [{:int, a}, {:int, b} | _] when a <= b ->
        {:ok, {:int, a + :rand.uniform(b - a + 1) - 1}, i}

      [{:int, a}, {:int, _b} | _] ->
        {:ok, {:int, a}, i}

      [] ->
        {:ok, {:int, :rand.uniform(2_147_483_647)}, i}

      _ ->
        {:ok, {:int, :rand.uniform(2_147_483_647)}, i}
    end
  end

  defp is_finite([v | _], i),
    do: {:ok, {:bool, is_float_val(v) and abs(fval(v)) <= 1.7976931348623157e308}, i}

  defp is_infinite([v | _], i),
    do: {:ok, {:bool, is_float_val(v) and abs(fval(v)) > 1.7976931348623157e308}, i}

  defp is_nan([_v | _], i), do: {:ok, {:bool, false}, i}

  defp is_float_val({:float, _}), do: true
  defp is_float_val(_), do: false

  defp trig(which) do
    f =
      case which do
        :sin -> &:math.sin/1
        :cos -> &:math.cos/1
        :tan -> &:math.tan/1
      end

    fn vals, i ->
      arg =
        case vals do
          [v | _] -> fval(v)
          [] -> 0.0
        end

      {:ok, {:float, f.(arg)}, i}
    end
  end

  defp log_v([v | rest], i) do
    base =
      case rest do
        [{:int, b} | _] -> fval({:int, b})
        [{:float, b} | _] -> b
        _ -> nil
      end

    case base do
      nil ->
        {:ok, {:float, :math.log(fval(v))}, i}

      2.0 ->
        {:ok, {:float, :math.log2(fval(v))}, i}

      10.0 ->
        {:ok, {:float, :math.log10(fval(v))}, i}

      b when is_float(b) or is_integer(b) ->
        {:ok, {:float, :math.log(fval(v)) / :math.log(b + 0.0)}, i}

      _ ->
        {:ok, {:float, :math.log(fval(v))}, i}
    end
  end

  defp log10_v([v | _], i), do: {:ok, {:float, :math.log10(fval(v))}, i}
  defp exp_v([v | _], i), do: {:ok, {:float, :math.exp(fval(v))}, i}
  defp deg2rad([v | _], i), do: {:ok, {:float, :math.pi() * fval(v) / 180}, i}
  defp rad2deg([v | _], i), do: {:ok, {:float, fval(v) * 180 / :math.pi()}, i}
  defp pi_v([], i), do: {:ok, {:float, :math.pi()}, i}

  defp base_convert2(base, dir) do
    fn vals, i ->
      v =
        case vals do
          [v0 | _] -> v0
          [] -> {:int, 0}
        end

      case dir do
        :to -> {:ok, {:string, Integer.to_string(nval(v), base)}, i}
        :from -> {:ok, {:int, String.to_integer(sval(v), base)}, i}
      end
    end
  end

  defp nval({:int, n}), do: n
  defp nval(v), do: Value.to_int(v) |> elem(1) |> elem(1)

  defp sval({:string, s}), do: s
  defp sval(v), do: PhpBeam.Eval.php_to_string(v)

  defp base_convert([v, {:int, from}, {:int, to} | _], i) do
    n = String.to_integer(sval(v), from)
    {:ok, {:string, Integer.to_string(n, to)}, i}
  end

  defp base_convert(_, i), do: {:ok, {:string, "0"}, i}

  # php: cryptographically secure random bytes as a raw binary string;
  # length 0 throws ValueError (php 8)
  defp random_bytes_v([{:int, n} | _], i) when n > 0 do
    {:ok, {:string, :crypto.strong_rand_bytes(n)}, i}
  end

  defp random_bytes_v([{:int, _n} | _], i) do
    {:ok,
     {:unwind,
      {:php_throw,
       {:native_error, "ValueError",
        "random_bytes(): Argument #1 ($length) must be greater than 0"}}}, i}
  end

  defp random_bytes_v(_, i), do: {:ok, {:string, ""}, i}
end
