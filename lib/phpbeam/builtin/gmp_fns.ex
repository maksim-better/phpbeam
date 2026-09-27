defmodule PhpBeam.Builtin.GmpFns do
  @moduledoc """
  ext/gmp — 51 functions over arbitrary-precision integers (Elixir ints).
  Operand coercion: int | integer string (0x/0b/0 prefixes auto-detected at
  the default base) | GMP object; anything else raises the php TypeError.
  Numeric results are fresh GMP objects. Random-value fns use :rand — GMP's
  Mersenne stream is not replicated (registered deviation).
  """

  alias PhpBeam.Classes.Gmp
  alias PhpBeam.Eval
  alias PhpBeam.PArray

  def register(fns) do
    entries = %{
      "gmp_init" => &gmp_init/2,
      "gmp_intval" => &gmp_intval/2,
      "gmp_strval" => &gmp_strval/2,
      "gmp_abs" => &gmp_abs/2,
      "gmp_sign" => &gmp_sign/2,
      "gmp_neg" => &gmp_neg/2,
      "gmp_com" => &gmp_com/2,
      "gmp_add" => &gmp_add/2,
      "gmp_sub" => &gmp_sub/2,
      "gmp_mul" => &gmp_mul/2,
      "gmp_div" => &gmp_div_q/2,
      "gmp_div_q" => &gmp_div_q/2,
      "gmp_div_r" => &gmp_div_r/2,
      "gmp_div_qr" => &gmp_div_qr/2,
      "gmp_mod" => &gmp_mod/2,
      "gmp_divexact" => &gmp_divexact/2,
      "gmp_pow" => &gmp_pow/2,
      "gmp_powm" => &gmp_powm/2,
      "gmp_sqrt" => &gmp_sqrt/2,
      "gmp_sqrtrem" => &gmp_sqrtrem/2,
      "gmp_root" => &gmp_root/2,
      "gmp_rootrem" => &gmp_rootrem/2,
      "gmp_perfect_square" => &gmp_perfect_square/2,
      "gmp_perfect_power" => &gmp_perfect_power/2,
      "gmp_prob_prime" => &gmp_prob_prime/2,
      "gmp_nextprime" => &gmp_nextprime/2,
      "gmp_gcd" => &gmp_gcd/2,
      "gmp_lcm" => &gmp_lcm/2,
      "gmp_gcdext" => &gmp_gcdext/2,
      "gmp_invert" => &gmp_invert/2,
      "gmp_binomial" => &gmp_binomial/2,
      "gmp_fact" => &gmp_fact/2,
      "gmp_and" => &gmp_and/2,
      "gmp_or" => &gmp_or/2,
      "gmp_xor" => &gmp_xor/2,
      "gmp_testbit" => &gmp_testbit/2,
      "gmp_setbit" => &gmp_setbit/2,
      "gmp_clrbit" => &gmp_clrbit/2,
      "gmp_popcount" => &gmp_popcount/2,
      "gmp_hamdist" => &gmp_hamdist/2,
      "gmp_scan0" => &gmp_scan0/2,
      "gmp_scan1" => &gmp_scan1/2,
      "gmp_cmp" => &gmp_cmp/2,
      "gmp_jacobi" => &gmp_jacobi/2,
      "gmp_legendre" => &gmp_legendre/2,
      "gmp_kronecker" => &gmp_kronecker/2,
      "gmp_import" => &gmp_import/2,
      "gmp_export" => &gmp_export/2,
      "gmp_random_bits" => &gmp_random_bits/2,
      "gmp_random_range" => &gmp_random_range/2,
      "gmp_random_seed" => &gmp_random_seed/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, wrapped)
  end

  # ────────────────────────── coercion + errors ──────────────────────────

  defp given({:bool, true}), do: "true"
  defp given({:bool, false}), do: "false"
  defp given(:null), do: "null"
  defp given({:int, _}), do: "int"
  defp given({:float, _}), do: "float"
  defp given({:string, _}), do: "string"
  defp given({:array, _}), do: "array"
  defp given(_), do: "unknown"

  defp throw_err(class, fname, msg, vals, i) do
    i2 = PhpBeam.Interp.push_frame(i, fname, Enum.take(vals, 2))
    {obj, i3} = Eval.materialize_native({:native_error, class, msg}, i2)
    {:unwind, {:php_throw, obj}, i3}
  end

  defp arg_i(i, v, fname, pos, pname, vals) do
    case v do
      {:int, n} ->
        {:ok, n}

      {:string, s} ->
        case Gmp.parse_auto(s) do
          {:ok, n} ->
            {:ok, n}

          :error ->
            throw_err(
              "ValueError",
              fname,
              "#{fname}(): Argument ##{pos} ($#{pname}) is not an integer string",
              vals,
              i
            )
        end

      _ ->
        if Gmp.gmp?(i, v) do
          {:ok, Gmp.obj_int(i, v)}
        else
          throw_err(
            "TypeError",
            fname,
            "#{fname}(): Argument ##{pos} ($#{pname}) must be of type GMP|string|int, #{given(v)} given",
            vals,
            i
          )
        end
    end
  end

  # coerce operand positions [pos, ...] (names num1/num2/num...); returns
  # {:ok, [ints]} | {:unwind, u, i}
  defp coerce(i, vals, fname, positions) do
    positions
    |> Enum.reduce_while({:ok, []}, fn pos, {:ok, acc} ->
      v = Enum.at(vals, pos - 1, :null)
      pname = "num#{pos}"

      case arg_i(i, v, fname, pos, pname, vals) do
        {:ok, n} -> {:cont, {:ok, [n | acc]}}
        {:unwind, _, _} = u -> {:halt, u}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      u -> u
    end
  end

  defp ret_g(n, i) do
    {ref, i2} = Gmp.new(i, n)
    {:ok, ref, i2}
  end

  # ────────────────────────── init / conversion ──────────────────────────

  defp gmp_init([num_v | rest], i),
    do: gmp_init_impl(num_v, List.first(rest, {:int, 10}), i)

  defp gmp_init(_, i), do: {:ok, {:int, 0}, i}

  defp gmp_init_impl(num_v, base_v, i) do
    base = int_opt(base_v)

    with {:ok, s} <- string_arg(i, num_v, "gmp_init", 1, "num"),
         {:ok, n} <- parse_for_init(i, s, base) do
      ret_g(n, i)
    end
  end

  defp parse_for_init(i, s, 10) do
    case Gmp.parse_auto(s) do
      {:ok, n} -> {:ok, n}
      :error -> init_err(i, s)
    end
  end

  defp parse_for_init(i, s, base) do
    if base in 2..62 or base in -36..-2 do
      case Gmp.parse_radix(s, base) do
        {n, ""} -> {:ok, n}
        :error -> init_err(i, s)
      end
    else
      throw_err(
        "ValueError",
        "gmp_init",
        "gmp_init(): Argument #2 ($base) must be between 2 and 62, or -2 and -36",
        [s],
        i
      )
    end
  end

  defp init_err(i, _s) do
    throw_err("ValueError", "gmp_init", "gmp_init(): Argument #1 ($num) is not an integer string", [], i)
  end

  defp string_arg(i, {:string, s}, _f, _p, _n), do: {:ok, s}
  defp string_arg(_i, {:int, n}, _f, _p, _n), do: {:ok, Integer.to_string(n)}

  defp string_arg(i, v, fname, pos, pname) do
    if Gmp.gmp?(i, v) do
      {:ok, Integer.to_string(Gmp.obj_int(i, v))}
    else
      throw_err(
        "TypeError",
        fname,
        "#{fname}(): Argument ##{pos} ($#{pname}) must be of type string, #{given(v)} given",
        [],
        i
      )
    end
  end

  defp int_opt({:int, n}), do: n

  defp int_opt({:string, s}) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> 10
    end
  end

  defp int_opt(_), do: 10

  defp gmp_intval(vals, i) do
    case coerce(i, vals, "gmp_intval", [1]) do
      {:ok, [n]} ->
        # probed: sign applied separately, magnitude truncated mod 2^62
        # (gmp_intval("12345678901234567890") = 3122306864379792082)
        mag = rem(abs(n), 0x4000000000000000)
        {:ok, {:int, if(n < 0, do: -mag, else: mag)}, i}

      u ->
        u
    end
  end

  defp gmp_strval(vals, i) do
    {n_v, base} =
      case vals do
        [n_v, b_v] -> {n_v, int_opt(b_v)}
        [n_v] -> {n_v, 10}
        _ -> {:null, 10}
      end

    case coerce(i, [n_v], "gmp_strval", [1]) do
      {:ok, [n]} ->
        if base in 2..62 or base in -36..-2 do
          {:ok, {:string, Gmp.to_radix(n, base)}, i}
        else
          throw_err(
            "ValueError",
            "gmp_strval",
            "gmp_strval(): Argument #2 ($base) must be between 2 and 62, or -2 and -36",
            vals,
            i
          )
        end

      u ->
        u
    end
  end

  # ────────────────────────── arithmetic ──────────────────────────

  defp gmp_add(v, i), do: int2(v, i, "gmp_add", &+/2)
  defp gmp_sub(v, i), do: int2(v, i, "gmp_sub", &-/2)
  defp gmp_mul(v, i), do: int2(v, i, "gmp_mul", &*/2)
  defp gmp_gcd(v, i), do: int2(v, i, "gmp_gcd", fn a, b -> Integer.gcd(abs(a), abs(b)) end)
  defp gmp_lcm(v, i), do: int2(v, i, "gmp_lcm", &lcm/2)
  defp gmp_and(v, i), do: int2(v, i, "gmp_and", &Bitwise.band/2)
  defp gmp_or(v, i), do: int2(v, i, "gmp_or", &Bitwise.bor/2)
  defp gmp_xor(v, i), do: int2(v, i, "gmp_xor", &Bitwise.bxor/2)

  defp gmp_abs(vals, i), do: int1(vals, i, "gmp_abs", &abs/1)
  defp gmp_neg(vals, i), do: int1(vals, i, "gmp_neg", &-/1)
  defp gmp_com(vals, i), do: int1(vals, i, "gmp_com", &Bitwise.bnot/1)
  defp gmp_sqrt(vals, i), do: int1(vals, i, "gmp_sqrt", &isqrt/1)
  defp gmp_nextprime(vals, i), do: int1(vals, i, "gmp_nextprime", &next_prime/1)
  defp gmp_sign(vals, i) do
    case coerce(i, vals, "gmp_sign", [1]) do
      {:ok, [a]} -> {:ok, {:int, sign_of(a)}, i}
      u -> u
    end
  end

  defp gmp_popcount(vals, i) do
    case coerce(i, vals, "gmp_popcount", [1]) do
      {:ok, [a]} -> {:ok, {:int, popcount(a)}, i}
      u -> u
    end
  end

  defp gmp_div_q(vals, i), do: div_by(vals, i, "gmp_div_q", "Division by zero", &trunc_div/2)
  defp gmp_div_r(vals, i), do: div_by(vals, i, "gmp_div_r", "Modulo by zero", &rem/2)

  defp gmp_mod(vals, i), do: div_by(vals, i, "gmp_mod", "Modulo by zero", &Integer.mod/2)
  defp gmp_divexact(vals, i), do: div_by(vals, i, "gmp_divexact", "Division by zero", &div/2)

  defp div_by(vals, i, fname, zero_msg, op) do
    case coerce(i, vals, fname, [1, 2]) do
      {:ok, [a, 0]} -> throw_err("DivisionByZeroError", fname, zero_msg, vals, i)
      {:ok, [a, b]} -> ret_g(op.(a, b), i)
      u -> u
    end
  end

  defp gmp_div_qr(vals, i) do
    case coerce(i, vals, "gmp_div_qr", [1, 2]) do
      {:ok, [_, 0]} ->
        throw_err("DivisionByZeroError", "gmp_div_qr", "Division by zero", vals, i)

      {:ok, [a, b]} ->
        q = trunc_div(a, b)
        r = rem(a, b)
        {refs, i2} = obj_list([q, r], i)
        {:ok, {:array, pair_arr(refs)}, i2}

      u ->
        u
    end
  end

  defp gmp_pow(vals, i) do
    case coerce(i, vals, "gmp_pow", [1, 2]) do
      {:ok, [b, e]} when e >= 0 -> ret_g(b ** e, i)
      {:ok, [_, _]} ->
        throw_err(
          "ValueError",
          "gmp_pow",
          "gmp_pow(): Argument #2 ($exponent) must be greater than or equal to 0",
          vals,
          i
        )
      u -> u
    end
  end

  defp gmp_powm(vals, i) do
    case coerce(i, vals, "gmp_powm", [1, 2, 3]) do
      {:ok, [_, _, 0]} ->
        throw_err("DivisionByZeroError", "gmp_powm", "Modulo by zero", vals, i)

      {:ok, [b, e, m]} when e >= 0 ->
        ret_g(mod_pow(b, e, m), i)

      {:ok, [_, _, _]} ->
        throw_err(
          "ValueError",
          "gmp_powm",
          "gmp_powm(): Argument #2 ($exponent) must be greater than or equal to 0",
          vals,
          i
        )

      u ->
        u
    end
  end

  defp mod_pow(b, e, m) do
    b = Integer.mod(b, m)
    do_mod_pow(b, e, m, Integer.mod(1, m))
  end

  defp do_mod_pow(_b, 0, _m, acc), do: acc

  defp do_mod_pow(b, e, m, acc) do
    acc2 = if Bitwise.band(e, 1) == 1, do: Integer.mod(acc * b, m), else: acc
    do_mod_pow(Integer.mod(b * b, m), Bitwise.bsr(e, 1), m, acc2)
  end

  defp gmp_sqrtrem(vals, i) do
    case coerce(i, vals, "gmp_sqrtrem", [1]) do
      {:ok, [a]} ->
        s = isqrt(a)
        {refs, i2} = obj_list([s, a - s * s], i)
        {:ok, {:array, pair_arr(refs)}, i2}

      u ->
        u
    end
  end

  defp gmp_root(vals, i) do
    case coerce(i, vals, "gmp_root", [1, 2]) do
      {:ok, [a, b]} when b >= 1 -> ret_g(iroot(a, b), i)
      {:ok, [_, _]} -> root_bad(i, vals, "gmp_root")
      u -> u
    end
  end

  defp gmp_rootrem(vals, i) do
    case coerce(i, vals, "gmp_rootrem", [1, 2]) do
      {:ok, [a, b]} when b >= 1 ->
        r = iroot(a, b)
        {refs, i2} = obj_list([r, a - r ** b], i)
        {:ok, {:array, pair_arr(refs)}, i2}

      {:ok, [_, _]} ->
        root_bad(i, vals, "gmp_rootrem")

      u ->
        u
    end
  end

  defp root_bad(i, vals, fname) do
    throw_err(
      "ValueError",
      fname,
      "#{fname}(): Argument #2 ($nth) must be greater than or equal to 1",
      vals,
      i
    )
  end

  # truncating integer nth root (odd roots of negatives mirror to |n|)
  defp iroot(n, b) when n >= 0, do: iroot_pos(n, b)

  defp iroot(n, b) do
    if Bitwise.band(b, 1) == 1 do
      -iroot_pos(-n, b)
    else
      iroot_pos(-n, b)
    end
  end

  defp iroot_pos(n, 1), do: n

  defp iroot_pos(n, b) do
    hi = Bitwise.bsl(1, Bitwise.bsr(:erlang.integer_to_binary(n, 2) |> byte_size(), 1) + 1)
    iroot_iter(n, b, 0, hi)
  end

  defp iroot_iter(n, b, lo, hi) when lo + 1 < hi do
    mid = div(lo + hi, 2)

    if mid ** b <= n,
      do: iroot_iter(n, b, mid, hi),
      else: iroot_iter(n, b, lo, mid)
  end

  defp iroot_iter(_n, _b, lo, _hi), do: lo

  defp next_prime(n) do
    candidate = if n < 2, do: 2, else: n + 1
    candidate = if candidate > 2 and rem(candidate, 2) == 0, do: candidate + 1, else: candidate

    next_prime_iter(candidate)
  end

  defp next_prime_iter(c) do
    if prime?(c), do: c, else: next_prime_iter(c + 2)
  end

  defp gmp_prob_prime(vals, i) do
    case coerce(i, vals, "gmp_prob_prime", [1]) do
      {:ok, [n]} ->
        {:ok, {:int, prob_prime(n)}, i}

      u ->
        u
    end
  end

  # deterministic Miller-Rabin over the small-prime witness set → php's
  # 0 (composite) / 2 (prime); 1 ("probably") is unreachable deterministically
  defp prob_prime(n) when n < 2, do: 0
  defp prob_prime(n) when n in [2, 3], do: 2

  defp prob_prime(n) do
    small = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37]

    cond do
      Enum.any?(small, fn p -> rem(n, p) == 0 end) -> if n in small, do: 2, else: 0
      true -> if mr_prime?(n, small), do: 2, else: 0
    end
  end

  defp mr_prime?(n, witnesses) do
    d = n - 1
    r = trailing_zeros(d)
    d = Bitwise.bsr(d, r)

    Enum.all?(witnesses, fn a ->
      a = Integer.mod(a, n)
      if a == 0, do: true, else: mr_witness?(a, d, r, n)
    end)
  end

  defp mr_witness?(a, d, r, n) do
    x = mod_pow(a, d, n)

    if x in [1, n - 1] do
      true
    else
      mr_square(x, r - 1, n)
    end
  end

  defp mr_square(_x, r, _n) when r <= 0, do: false

  defp mr_square(x, r, n) do
    x = Integer.mod(x * x, n)
    if x == n - 1, do: true, else: mr_square(x, r - 1, n)
  end

  defp trailing_zeros(d) do
    if Bitwise.band(d, 1) == 0, do: 1 + trailing_zeros(Bitwise.bsr(d, 1)), else: 0
  end

  defp prime?(n) when n < 2, do: false
  defp prime?(n), do: prob_prime(n) == 2

  defp perfect_square(n) when n < 0, do: false
  defp perfect_square(n), do: isqrt(n) ** 2 == n

  defp perfect_power(0), do: true
  defp perfect_power(1), do: true

  defp perfect_power(n) do
    m = abs(n)

    2..bit_size_of(m)
    |> Enum.any?(fn b ->
      r = iroot_pos(m, b)
      r ** b == m and (n > 0 or Bitwise.band(b, 1) == 1)
    end)
  end

  defp bit_size_of(n) when n <= 1, do: 1
  defp bit_size_of(n), do: :erlang.integer_to_binary(n, 2) |> byte_size()

  defp gmp_fact(vals, i) do
    case coerce(i, vals, "gmp_fact", [1]) do
      {:ok, [n]} when n >= 0 -> ret_g(fact(n), i)
      {:ok, [_]} ->
        throw_err(
          "ValueError",
          "gmp_fact",
          "gmp_fact(): Argument #1 ($num) must be greater than or equal to 0",
          vals,
          i
        )
      u -> u
    end
  end

  defp fact(n) when n <= 1, do: 1
  defp fact(n), do: n * fact(n - 1)

  defp gmp_binomial(vals, i) do
    case coerce(i, vals, "gmp_binomial", [1, 2]) do
      {:ok, [n, k]} when k >= 0 -> ret_g(binomial(n, k), i)
      {:ok, [_, _]} ->
        throw_err(
          "ValueError",
          "gmp_binomial",
          "gmp_binomial(): Argument #2 ($k) must be greater than or equal to 0",
          vals,
          i
        )
      u -> u
    end
  end

  defp binomial(_n, 0), do: 1

  defp binomial(n, k) when k < 0 or k > n, do: 0

  defp binomial(n, k) do
    Enum.reduce(1..k, 1, fn j, acc -> div(acc * (n - j + 1), j) end)
  end

  defp gmp_gcdext(vals, i) do
    case coerce(i, vals, "gmp_gcdext", [1, 2]) do
      {:ok, [a, b]} ->
        {g, s, t} = egcd_signed(a, b)
        {refs, i2} = obj_list([g, s, t], i)
        {:ok, {:array, triple_arr(refs)}, i2}

      u ->
        u
    end
  end

  defp egcd_signed(a, 0), do: {a, 1, 0}

  defp egcd_signed(a, b) do
    {g, s, t} = egcd_signed(b, rem(a, b))
    {g, t, s - div(a, b) * t}
  end

  defp gmp_invert(vals, i) do
    case coerce(i, vals, "gmp_invert", [1, 2]) do
      {:ok, [a, m]} ->
        case egcd_signed(Integer.mod(a, m), m) do
          {1, s, _} -> ret_g(Integer.mod(s, m), i)
          _ -> {:ok, {:bool, false}, i}
        end

      u ->
        u
    end
  end

  # ────────────────────────── bit surface ──────────────────────────

  defp gmp_testbit(vals, i) do
    case coerce(i, vals, "gmp_testbit", [1, 2]) do
      {:ok, [n, idx]} -> {:ok, {:bool, Bitwise.band(Bitwise.bsr(n, idx), 1) == 1}, i}
      u -> u
    end
  end

  defp gmp_setbit(vals, i) do
    set_bit_impl(vals, i, true)
  end

  defp gmp_clrbit(vals, i) do
    set_bit_impl(vals, i, false)
  end

  # mutates the GMP object in place (reference-handle semantics)
  defp set_bit_impl(vals, i, set?) do
    v = Enum.at(vals, 0, :null)

    case coerce(i, vals, "gmp_setbit", [2]) do
      {:ok, [idx]} ->
        if Gmp.gmp?(i, v) do
          ref = v
          n = Gmp.obj_int(i, ref)

          n2 =
            if set? do
              Bitwise.bor(n, Bitwise.bsl(1, idx))
            else
              Bitwise.band(n, Bitwise.bnot(Bitwise.bsl(1, idx)))
            end

          obj = Eval.get_object(i, ref)
          props = PArray.put(obj.props, {:string, "num"}, {:string, Integer.to_string(n2)})

          case props do
            {:ok, p2} -> {:ok, {:bool, true}, Eval.put_object(i, ref, %{obj | props: p2})}
            _ -> {:ok, {:bool, true}, i}
          end
        else
          {:ok, {:bool, true}, i}
        end

      u ->
        u
    end
  end

  defp gmp_hamdist(vals, i) do
    case coerce(i, vals, "gmp_hamdist", [1, 2]) do
      {:ok, [a, b]} -> {:ok, {:int, popcount(Bitwise.bxor(a, b))}, i}
      u -> u
    end
  end

  defp gmp_scan0(vals, i), do: scan_impl(vals, i, 0, "gmp_scan0")
  defp gmp_scan1(vals, i), do: scan_impl(vals, i, 1, "gmp_scan1")

  defp scan_impl(vals, i, want, fname) do
    case coerce(i, vals, fname, [1, 2]) do
      {:ok, [n, start]} ->
        {:ok, {:int, scan_bits(n, start, want)}, i}

      u ->
        u
    end
  end

  # infinite two's complement: negatives read as all 1s above the magnitude
  defp scan_bits(n, start, want) do
    mag = bit_size_of(abs(n))
    scan_iter(n, max(start, 0), want, mag)
  end

  defp scan_iter(n, idx, want, mag) do
    bit = Bitwise.band(Bitwise.bsr(n, idx), 1)

    cond do
      bit == want ->
        idx

      idx >= mag + 2 ->
        # above the magnitude: 0s for non-negatives, 1s for negatives
        idx

      true ->
        scan_iter(n, idx + 1, want, mag)
    end
  end

  defp gmp_cmp(vals, i) do
    case coerce(i, vals, "gmp_cmp", [1, 2]) do
      {:ok, [a, b]} -> {:ok, {:int, cmp(a, b)}, i}
      u -> u
    end
  end

  defp gmp_jacobi(vals, i), do: jacobi_legendre_impl(vals, i, "gmp_jacobi")
  defp gmp_legendre(vals, i), do: jacobi_legendre_impl(vals, i, "gmp_legendre")

  defp jacobi_legendre_impl(vals, i, fname) do
    case coerce(i, vals, fname, [1, 2]) do
      {:ok, [a, n]} -> {:ok, {:int, kronecker(a, n)}, i}
      u -> u
    end
  end

  defp gmp_kronecker(vals, i) do
    case coerce(i, vals, "gmp_kronecker", [1, 2]) do
      {:ok, [a, n]} -> {:ok, {:int, kronecker(a, n)}, i}
      u -> u
    end
  end

  # Kronecker/Jacobi symbol (a|n) by quadratic reciprocity
  defp kronecker(a, 0), do: if(abs(a) == 1, do: 1, else: 0)

  defp kronecker(a, n) when n < 0, do: kronecker_neg(a, n)

  defp kronecker(a, n) do
    cond do
      Bitwise.band(n, 1) == 0 ->
        if Bitwise.band(a, 1) == 0, do: 0, else: kronecker_even(a, n)

      true ->
        jacobi_odd(Bitwise.band(Integer.mod(a, n), n), n)
    end
  end

  defp kronecker_neg(a, n) do
    base =
      cond do
        a < 0 -> -1
        Bitwise.band(a, 1) == 0 -> 0
        true -> 1
      end

    base * kronecker(a, -n)
  end

  defp kronecker_even(a, n) do
    twos = trailing_zeros(n)
    n2 = Bitwise.bsr(n, twos)

    # (2|a) — a odd: +1 when a ≡ ±1 (mod 8), -1 when a ≡ ±3 (mod 8)
    two_sym = if rem(abs(a), 8) in [1, 7], do: 1, else: -1
    base_sym = if Bitwise.band(twos, 1) == 0, do: 1, else: two_sym

    base_sym * jacobi_odd(Bitwise.band(Integer.mod(a, n2), n2), n2)
  end

  defp jacobi_odd(a, n) do
    cond do
      n == 1 ->
        1

      a == 0 ->
        0

      true ->
        a = Bitwise.bsr(a, trailing_zeros(a))

        sym = if Bitwise.band(Bitwise.band(a, n), 2) == 2, do: -1, else: 1

        sym * jacobi_odd(Integer.mod(n, a), a)
    end
  end

  # ────────────────────────── import / export ──────────────────────────

  # flags: 1=MSW_FIRST 2=LSW_FIRST 4=LITTLE_ENDIAN 8=BIG_ENDIAN 16=NATIVE
  @msw 1
  @lsw 2
  @big 8
  @native 16

  defp gmp_export(vals, i) do
    {n_v, w_v, f_v} =
      case vals do
        [n] -> {n, {:int, 1}, {:int, @msw + @native}}
        [n, w] -> {n, w, {:int, @msw + @native}}
        [n, w, f] -> {n, w, f}
        _ -> {:null, {:int, 1}, {:int, @msw + @native}}
      end

    case coerce(i, [n_v], "gmp_export", [1]) do
      {:ok, [n]} ->
        word = int_opt(w_v)
        flags = int_opt(f_v)
        {:ok, {:string, export_bytes(n, word, flags)}, i}

      u ->
        u
    end
  end

  defp export_bytes(n, word, flags) when word >= 1 do
    if n == 0 do
      ""
    else
      base = 256 ** word
      msw? = Bitwise.band(flags, @msw) != 0
      big? = Bitwise.band(flags, @big) != 0

      chunks = split_words(n, base)

      chunks =
        if msw? do
          chunks
        else
          Enum.reverse(chunks)
        end

      chunks
      |> Enum.map(fn c ->
        bytes = int_to_bytes(c, word)

        if big? do
          bytes
        else
          # native (little-endian) within the word
          Enum.reverse(bytes)
        end
      end)
      |> List.flatten()
      |> :erlang.list_to_binary()
    end
  end

  defp export_bytes(_n, _w, _f), do: ""

  defp split_words(n, base) do
    split_words_iter(n, base, [])
  end

  defp split_words_iter(0, _base, acc), do: acc
  defp split_words_iter(n, base, acc), do: split_words_iter(div(n, base), base, [rem(n, base) | acc])

  defp int_to_bytes(n, len) do
    int_to_bytes_iter(n, len, [])
  end

  defp int_to_bytes_iter(_n, 0, acc), do: acc

  defp int_to_bytes_iter(n, len, acc) do
    int_to_bytes_iter(Bitwise.bsr(n, 8), len - 1, [Bitwise.band(n, 255) | acc])
  end

  defp gmp_import(vals, i) do
    {d_v, w_v, f_v} =
      case vals do
        [d] -> {d, {:int, 1}, {:int, @msw + @native}}
        [d, w] -> {d, w, {:int, @msw + @native}}
        [d, w, f] -> {d, w, f}
        _ -> {:null, {:int, 1}, {:int, @msw + @native}}
      end

    case d_v do
      {:string, data} ->
        word = int_opt(w_v)
        flags = int_opt(f_v)

        if word >= 1 and rem(byte_size(data), word) == 0 do
          msw? = Bitwise.band(flags, @msw) != 0
          big? = Bitwise.band(flags, @big) != 0
          base = 256 ** word

          chunks =
            data
            |> chunk_bytes(word)
            |> Enum.map(fn bytes ->
              bytes = if big?, do: bytes, else: Enum.reverse(bytes)
              Enum.reduce(bytes, 0, fn b, acc -> acc * 256 + b end)
            end)

          chunks = if msw?, do: chunks, else: Enum.reverse(chunks)

          n = Enum.reduce(chunks, 0, fn c, acc -> acc * base + c end)
          ret_g(n, i)
        else
          {:ok, {:int, 0}, i}
        end

      _ ->
        {:ok, {:int, 0}, i}
    end
  end

  defp chunk_bytes(data, word) do
    bytes = :binary.bin_to_list(data)
    Enum.chunk_every(bytes, word)
  end

  # ────────────────────────── random (deviation: :rand stream) ──────────

  defp gmp_random_bits(vals, i) do
    bits =
      case vals do
        [{:int, b}] -> b
        _ -> 0
      end

    n = uniform(0, 2 ** max(bits, 1))
    ret_g(n, i)
  end

  defp gmp_random_range(vals, i) do
    case coerce(i, vals, "gmp_random_range", [1, 2]) do
      {:ok, [a, b]} -> ret_g(uniform(min(a, b), max(a, b)), i)
      u -> u
    end
  end

  defp uniform(lo, hi) when hi <= lo, do: lo

  defp uniform(lo, hi) do
    lo + :rand.uniform(hi - lo + 1) - 1
  end

  defp gmp_random_seed(vals, i) do
    seed =
      case vals do
        [{:int, s}] -> s
        [{:string, s}] -> String.to_integer(s)
        _ -> 0
      end

    :rand.seed(:exsss, {seed, seed, seed})
    {:ok, :null, i}
  end

  # ────────────────────────── shared bits ──────────────────────────

  defp int1(vals, i, fname, f) do
    case coerce(i, vals, fname, [1]) do
      {:ok, [a]} -> ret_g(f.(a), i)
      u -> u
    end
  end

  defp gmp_perfect_square(vals, i) do
    case coerce(i, vals, "gmp_perfect_square", [1]) do
      {:ok, [a]} -> {:ok, {:bool, perfect_square(a)}, i}
      u -> u
    end
  end

  defp gmp_perfect_power(vals, i) do
    case coerce(i, vals, "gmp_perfect_power", [1]) do
      {:ok, [a]} -> {:ok, {:bool, perfect_power(a)}, i}
      u -> u
    end
  end

  defp int2(vals, i, fname, f) do
    case coerce(i, vals, fname, [1, 2]) do
      {:ok, [a, b]} -> ret_g(f.(a, b), i)
      u -> u
    end
  end

  defp obj_list(ints, i) do
    Enum.map_reduce(ints, i, fn n, acc -> Gmp.new(acc, n) end)
  end

  defp pair_arr([q, r]) do
    PArray.from_pairs([{0, q}, {1, r}])
  end

  defp triple_arr([g, s, t]) do
    PArray.from_pairs([{"g", g}, {"s", s}, {"t", t}])
  end

  defp trunc_div(a, b) do
    q = div(abs(a), abs(b))
    if (a < 0) != (b < 0), do: -q, else: q
  end

  defp lcm(0, 0), do: 0
  defp lcm(a, b), do: div(abs(a * b), Integer.gcd(abs(a), abs(b)))

  defp sign_of(n) when n < 0, do: -1
  defp sign_of(0), do: 0
  defp sign_of(_), do: 1

  defp cmp(a, b) when a < b, do: -1
  defp cmp(a, b) when a > b, do: 1
  defp cmp(_, _), do: 0

  defp popcount(n) when n < 0, do: -1
  defp popcount(n), do: popcount_ex(n)

  defp popcount_ex(0), do: 0
  defp popcount_ex(n) when n > 0, do: popcount_ex(Bitwise.band(n, n - 1)) + 1

  defp isqrt(n) when n <= 0, do: 0

  defp isqrt(n) do
    bits = bit_size_of(n)
    x = Bitwise.bsl(1, Bitwise.bsr(bits + 1, 1) + 1)
    isqrt_iter(n, x)
  end

  defp isqrt_iter(n, x) do
    y = Bitwise.bsr(x + div(n, x), 1)
    if y < x, do: isqrt_iter(n, y), else: x
  end

  defp arg_count(fname, i) do
    throw_err(
      "ArgumentCountError",
      fname,
      "Too few arguments to function #{fname}(), 0 passed and at least 1 expected",
      [],
      i
    )
  end
end
