defmodule PhpBeam.Value do
  @moduledoc """
  PHP value model and type juggling (PHP 8 semantics).

  Values are tagged tuples: `{:int, i}` `{:float, f}` `{:string, binary}`
  `{:bool, b}` `:null` `{:array, %PhpBeam.PArray{}}` `{:object, map}`.

  All numeric-string, loose-comparison, arithmetic-coercion and float-format
  rules were pinned against PHP 8.4 (`php` differential probes).
  """

  alias PhpBeam.Error
  alias PhpBeam.PArray

  @type t ::
          {:int, integer()}
          | {:float, float()}
          | {:string, binary()}
          | {:bool, boolean()}
          | :null
          | {:array, PArray.t()}
          | {:object, map()}

  @int_min -9_223_372_036_854_775_808
  @int_max 9_223_372_036_854_775_807
  @float_precision 14

  # ─────────────────────────── classification ───────────────────────────

  # type/2-style defensive head: values are tagged tuples, but slips happen
  # (bare binaries from older code paths) — classify them as strings
  def type(v) when is_binary(v), do: :string
  def type(v) when is_integer(v), do: :int
  def type(v) when is_float(v), do: :float
  def type(v) when is_boolean(v), do: :bool
  def type(v) when is_atom(v) and not is_nil(v) and v != :null, do: :string
  def type({:ref, _}), do: :null
  def type({:int, _}), do: :int
  def type({:float, _}), do: :float
  def type({:string, _}), do: :string
  def type({:bool, _}), do: :bool
  def type(:null), do: :null
  def type({:resource, _}), do: :resource
  def type({:array, _}), do: :array
  def type({:object, _}), do: :object
  # runtime closures are Closure OBJECTS (php: gettype = "object")
  def type({:closure, _, _, _, _, _, _, _}), do: :object
  def type(_other), do: :string

  def gettype(v) do
    case type(foreign(v)) do
      :int -> "integer"
      :float -> "double"
      :string -> "string"
      :bool -> "boolean"
      :null -> "NULL"
      :array -> "array"
      :object -> "object"
      :resource -> "resource"
    end
  end

  # markers like :__null (mysql rows) or atoms should not crash gettype
  defp foreign({:int, _} = v), do: v
  defp foreign({:float, _} = v), do: v
  defp foreign({:string, _} = v), do: v
  defp foreign({:bool, _} = v), do: v
  defp foreign(:null), do: :null
  defp foreign({:array, _} = v), do: v
  defp foreign({:object, _} = v), do: v
  defp foreign({:resource, _} = v), do: v
  defp foreign(other) when is_atom(other), do: {:string, to_string(other)}
  defp foreign(other) when is_binary(other), do: {:string, other}
  defp foreign(other), do: {:string, inspect(other)}

  def truthy?({:int, 0}), do: false
  def truthy?({:float, 0.0}), do: false
  def truthy?({:string, ""}), do: false
  def truthy?({:string, "0"}), do: false
  def truthy?({:bool, b}), do: b
  def truthy?(:null), do: false
  def truthy?({:array, a}), do: PArray.size(a) > 0
  def truthy?({:object, _}), do: true
  def truthy?(_), do: true

  # ───────────────────────── numeric strings ───────────────────────────

  @ws ~r/^[\s]+|[\s]+$/ |> Regex.recompile!()

  @doc "`is_numeric()`: whitespace + optional sign + int/float syntax."
  def numeric_string?({:string, s}), do: numeric_string?(s)

  def numeric_string?(s) do
    case classify_string_number(s) do
      {:numeric, _} -> true
      _ -> false
    end
  end

  @doc """
  Classify a string for numeric contexts.

  * `{:numeric, n}` — fully numeric (int or float)
  * `{:leading, n}` — leading-numeric prefix (PHP 8: warning, then used)
  * `:non_numeric`
  """
  def classify_string_number({:string, s}), do: classify_string_number(s)

  def classify_string_number(s) do
    t = String.trim(s)

    case parse_number(t) do
      {:num, n} ->
        {:numeric, n}

      :none when t == "" ->
        :non_numeric

      :none ->
        # longest numeric prefix
        case leading_number(t) do
          {:ok, n} -> {:leading, n}
          :error -> :non_numeric
        end
    end
  end

  defp parse_number(<<c, rest::binary>>) when c in '+-' do
    case parse_number(rest) do
      {:num, n} -> {:num, negate_if(c, n)}
      :none -> :none
    end
  end

  defp parse_number(s) do
    {int_digits, rest} = take_digits(s)
    {frac_digits, rest2} = take_frac(rest)
    {exp, rest3} = take_exp(rest2)

    if rest3 != "" do
      :none
    else
      num_form(int_digits, frac_digits, exp)
    end
  end

  defp num_form(int_digits, frac_digits, exp) do
    cond do
      int_digits == "" and frac_digits == "" ->
        :none

      exp != "" or frac_digits != "" ->
        {:num,
         {:float,
          String.to_float(
            int_digits <> "." <> if(frac_digits == "", do: "0", else: frac_digits) <> exp
          )}}

      int_digits != "" ->
        i = String.to_integer(int_digits)

        if i > @int_max do
          {:num, {:float, i * 1.0}}
        else
          {:num, {:int, i}}
        end

      true ->
        :none
    end
  end

  defp take_digits(s), do: do_take_digits(s, "")

  defp do_take_digits(<<c, r::binary>>, acc) when c in ?0..?9,
    do: do_take_digits(r, <<acc::binary, c>>)

  defp do_take_digits(rest, acc), do: {acc, rest}

  defp take_frac("." <> rest), do: do_take_digits(rest, "")
  defp take_frac(rest), do: {"", rest}

  defp take_exp(<<e, s::binary>>) when e in 'eE' do
    {sign, s2} =
      case s do
        <<c, r::binary>> when c in '+-' -> {<<c>>, r}
        _ -> {"", s}
      end

    {d, rest} = take_digits(s2)

    if d == "" do
      {"", rest}
    else
      {"e" <> sign <> d, rest}
    end
  end

  defp take_exp(rest), do: {"", rest}

  defp leading_number(s), do: leading_number(s, "", false)

  defp leading_number(<<c, r::binary>>, acc, dot?) when c in ?0..?9 or (c == ?. and not dot?) do
    leading_number(r, <<acc::binary, c>>, dot? or c == ?.)
  end

  defp leading_number(rest, acc, _dot?) do
    case acc do
      "" ->
        :error

      "." ->
        :error

      _ ->
        with t <- String.trim(acc, "."),
             {:num, n} <- parse_number(t) do
          {:ok, n}
        else
          _ -> :error
        end
    end
  end

  defp negate_if(?-, {:int, i}), do: {:int, -i}
  defp negate_if(?-, {:float, f}), do: {:float, -f}
  defp negate_if(_, n), do: n

  # ─────────────────────────── casts ───────────────────────────

  @doc "(int) cast — never throws."
  def to_int({:int, i}), do: {:ok, {:int, i}}
  def to_int({:float, f}), do: {:ok, {:int, trunc_to_int(f)}}
  def to_int({:bool, b}), do: {:ok, {:int, if(b, do: 1, else: 0)}}
  def to_int(:null), do: {:ok, {:int, 0}}

  def to_int({:string, s}) do
    case classify_string_number(s) do
      {:numeric, {:int, i}} -> {:ok, {:int, i}}
      {:numeric, {:float, f}} -> {:ok, {:int, trunc_to_int(f)}}
      {:leading, {:int, i}} -> {:ok, {:int, i}}
      {:leading, {:float, f}} -> {:ok, {:int, trunc_to_int(f)}}
      :non_numeric -> {:ok, {:int, 0}}
    end
  end

  def to_int({:array, a}), do: {:ok, {:int, if(PArray.size(a) > 0, do: 1, else: 0)}}
  def to_int({:object, _}), do: {:ok, {:int, 1}}

  defp trunc_to_int(f) when f >= @int_max + 1, do: @int_max
  defp trunc_to_int(f) when f <= @int_min - 1, do: @int_min
  defp trunc_to_int(f), do: trunc(f)

  @doc "(float) cast."
  def to_float({:float, f}), do: {:ok, {:float, f}}
  def to_float({:int, i}), do: {:ok, {:float, i * 1.0}}

  def to_float({:string, s}) do
    case classify_string_number(s) do
      {:numeric, n} -> {:ok, {:float, num_f(n)}}
      {:leading, n} -> {:ok, {:float, num_f(n)}}
      :non_numeric -> {:ok, {:float, 0.0}}
    end
  end

  def to_float({:bool, b}), do: {:ok, {:float, if(b, do: 1.0, else: 0.0)}}
  def to_float(:null), do: {:ok, {:float, 0.0}}
  def to_float({:array, a}), do: {:ok, {:float, if(PArray.size(a) > 0, do: 1.0, else: 0.0)}}
  def to_float({:object, _}), do: {:ok, {:float, 1.0}}

  defp num_f({:int, i}), do: i * 1.0
  defp num_f({:float, f}), do: f

  @doc """
  (string) cast. Arrays warn and produce "Array"; objects need `__toString`
  (handled by the evaluator, which may return `{:error, ...}`) — here the
  default "Object" behaviour is delegated upward.
  """
  def cast_string(v)

  def cast_string({:string, s}), do: {:ok, s}
  def cast_string({:int, v}) when not is_integer(v), do: {:ok, "0"}
  def cast_string({:int, i}), do: {:ok, Integer.to_string(i)}
  def cast_string({:bool, true}), do: {:ok, "1"}
  def cast_string({:bool, false}), do: {:ok, ""}
  def cast_string(:null), do: {:ok, ""}
  def cast_string({:float, f}), do: {:ok, float_to_string(f)}

  def cast_string({:array, _}),
    do: {:warn_array, "Array"}

  def cast_string({:object, _}),
    do: {:error, Error.type_error("Object of class could not be converted to string")}

  def cast_string({:resource, _}),
    do: {:error, Error.type_error("Resource cannot be converted to string")}

  # foreign values (e.g. :__null markers leaked from result rendering)
  def cast_string(other), do: {:ok, inspect(other)}

  @doc "Like to_string/1 but used where PHP already warns (concat etc.)."
  def cast_string_unsafe(v) do
    case cast_string(v) do
      {:warn_array, s} ->
        IO.write(:stderr, "PHP Warning:  Array to string conversion\n")
        s

      {:ok, s} ->
        s

      {:error, e} ->
        throw(e)
    end
  end

  def to_bool(v), do: {:bool, truthy?(v)}

  @doc "(array) cast."
  def to_array({:array, _} = a), do: a
  def to_array(:null), do: {:array, PArray.new()}
  def to_array(v), do: {:array, PArray.push(PArray.new(), v)}

  # ─────────────────────────── equality ───────────────────────────

  @doc "`==` (loose equality), PHP 8 matrix."
  def loose_eq(a, b)

  def loose_eq(:null, b), do: false == truthy?(b)
  def loose_eq(a, :null), do: truthy?(a) == false

  # bool vs anything (except object): compare as bools
  def loose_eq({:bool, a}, b), do: a == truthy?(b)
  def loose_eq(a, {:bool, b}), do: truthy?(a) == b

  # array vs array: same count, same keys, values ==
  def loose_eq({:array, a}, {:array, b}) do
    PArray.size(a) == PArray.size(b) and
      Enum.all?(PArray.to_pairs(a), fn {k, v} ->
        case PArray.fetch(b, {:int, k}) do
          {:ok, v2} -> loose_eq(v, v2)
          _ -> false
        end
      end)
  end

  # array vs scalar (int/float/string): never equal
  def loose_eq({:array, _}, _), do: false
  def loose_eq(_, {:array, _}), do: false

  # object vs non-object: not equal (refined in M5 for instance identity)
  def loose_eq({:object, _}, _), do: false
  def loose_eq(_, {:object, _}), do: false

  # int/float vs string: numeric string → numeric compare, else string compare
  def loose_eq(a = {ta, _}, {:string, s}) when ta in [:int, :float],
    do: string_scalar_eq(s, a)

  def loose_eq({:string, s}, b = {tb, _}) when tb in [:int, :float],
    do: string_scalar_eq(s, b)

  # numeric
  def loose_eq({:int, a}, {:int, b}), do: a == b
  def loose_eq({:float, a}, {:float, b}), do: a == b
  def loose_eq({:int, a}, {:float, b}), do: a * 1.0 == b
  def loose_eq({:float, a}, {:int, b}), do: a == b * 1.0

  # string vs string
  def loose_eq({:string, a}, {:string, b}) do
    case {classify_string_number(a), classify_string_number(b)} do
      {{:numeric, {:int, x}}, {:numeric, {:int, y}}} -> x == y
      {{:numeric, x}, {:numeric, y}} -> to_float_v(x) == to_float_v(y)
      _ -> a == b
    end
  end

  defp to_float_v({:int, i}), do: i * 1.0
  defp to_float_v({:float, f}), do: f

  defp string_scalar_eq(s, num) do
    case classify_string_number(s) do
      {:numeric, n} -> num_eq(num, n)
      _ -> s == plain_to_string(num)
    end
  end

  defp num_eq({:int, a}, {:int, b}), do: a == b
  defp num_eq({:float, a}, {:int, b}), do: a == b * 1.0
  defp num_eq({:int, a}, {:float, b}), do: a * 1.0 == b
  defp num_eq({:float, a}, {:float, b}), do: a == b

  defp plain_to_string({:int, i}), do: Integer.to_string(i)
  defp plain_to_string({:float, f}), do: float_to_string(f)

  @doc "`===` (identity)."
  def strict_eq(a, b)

  def strict_eq({:int, a}, {:int, b}), do: a == b
  def strict_eq({:float, a}, {:float, b}), do: a == b
  def strict_eq({:string, a}, {:string, b}), do: a == b
  def strict_eq({:bool, a}, {:bool, b}), do: a == b
  def strict_eq(:null, :null), do: true
  def strict_eq({:resource, a}, {:resource, b}), do: a == b

  def strict_eq({:array, a}, {:array, b}) do
    PArray.size(a) == PArray.size(b) and
      PArray.to_pairs(a) == PArray.to_pairs(b) and
      strict_pairs_eq(PArray.to_pairs(a), PArray.to_pairs(b))
  end

  def strict_eq({:object, a}, {:object, b}), do: object_identity(a, b)
  def strict_eq(_, _), do: false

  defp strict_pairs_eq([{_, v1} | r1], [{_, v2} | r2]) do
    strict_eq(v1, v2) and strict_pairs_eq(r1, r2)
  end

  defp strict_pairs_eq([], []), do: true
  defp strict_pairs_eq(_, _), do: false

  # object handles carry the registry id directly (int) or the full map
  defp object_identity(r1, r2) when is_integer(r1) and is_integer(r2), do: r1 == r2
  defp object_identity(%{__ref__: r1}, %{__ref__: r2}), do: r1 == r2
  defp object_identity(_, _), do: false

  @doc """
  Three-way comparison for `<` `>` `<=` `>=` `<=>`: `-1 | 0 | 1`.
  """
  def compare(a, b)

  # defensive: bare binaries slip through some older conversion paths
  def compare(a, b) when is_binary(a) or is_binary(b),
    do: compare(wrap_bin(a), wrap_bin(b))

  defp wrap_bin(s) when is_binary(s), do: {:string, s}
  defp wrap_bin(v), do: v

  # strings: numeric strings compare numerically
  def compare({:string, a}, {:string, b}) do
    case {classify_string_number(a), classify_string_number(b)} do
      {{:numeric, x}, {:numeric, y}} -> num_compare(x, y)
      _ -> byte_compare(a, b)
    end
  end

  # array vs array: count first, then element-wise in order
  def compare({:array, a}, {:array, b}) do
    case PArray.size(a) - PArray.size(b) do
      d when d < 0 -> -1
      d when d > 0 -> 1
      0 -> compare_pairs(PArray.to_pairs(a), PArray.to_pairs(b))
    end
  end

  # array vs anything else: array is greater
  def compare({:array, _}, _), do: 1
  def compare(_, {:array, _}), do: -1

  # bool/null vs anything: compare as bools
  def compare({:bool, a}, b), do: bool_compare(a, truthy?(b))
  def compare(a, {:bool, b}), do: bool_compare(truthy?(a), b)
  def compare(:null, b), do: bool_compare(false, truthy?(b))
  def compare(a, :null), do: bool_compare(truthy?(a), false)

  # int/float vs string: numeric string → numeric, else cast number to string
  def compare(a = {ta, _}, {:string, s}) when ta in [:int, :float] do
    case classify_string_number(s) do
      {:numeric, n} -> num_compare_v(a, n)
      _ -> byte_compare(plain_to_string(a), s)
    end
  end

  def compare({:string, s}, b = {tb, _}) when tb in [:int, :float] do
    -compare(b, {:string, s})
  end

  # numeric
  def compare({:int, a}, {:int, b}), do: cmp(a, b)
  def compare({:float, a}, {:float, b}), do: cmp(a, b)
  def compare({:int, a}, {:float, b}), do: cmp(a * 1.0, b)
  def compare({:float, a}, {:int, b}), do: cmp(a, b * 1.0)

  # objects (M5): incomparable — treat as equal unless identity differs
  def compare({:object, _}, {:object, _}), do: 0
  def compare({:object, _}, _), do: 1
  def compare(_, {:object, _}), do: -1

  defp compare_pairs([{_, v1} | r1], [{_, v2} | r2]) do
    case compare(v1, v2) do
      0 -> compare_pairs(r1, r2)
      c -> c
    end
  end

  defp compare_pairs([], []), do: 0
  defp compare_pairs(_, _), do: 0

  defp bool_compare(a, b) when a == b, do: 0
  defp bool_compare(false, true), do: -1
  defp bool_compare(true, false), do: 1

  defp num_compare({:int, a}, {:int, b}), do: cmp(a, b)

  defp num_compare(x, y), do: cmp(to_float_v(x), to_float_v(y))

  defp num_compare_v(v, n), do: num_compare(unbox(v), n)

  defp unbox({:int, i}), do: {:int, i}
  defp unbox({:float, f}), do: {:float, f}

  defp byte_compare(a, b) do
    cond do
      a == b -> 0
      a < b -> -1
      true -> 1
    end
  end

  defp cmp(a, b) when a < b, do: -1
  defp cmp(a, b) when a > b, do: 1
  defp cmp(_, _), do: 0

  # ─────────────────────────── arithmetic ───────────────────────────

  @doc """
  Arithmetic coercion. Returns:

  * `{:num, {:int,i} | {:float,f}}` — operand usable directly
  * `{:leading, n}` — leading-numeric string (caller emits warning)
  * `{:error, error}` — TypeError for non-numeric string/array/object
  """
  def arith_operand(v)

  def arith_operand({:int, _} = v), do: {:num, v}
  def arith_operand({:float, _} = v), do: {:num, v}
  def arith_operand({:bool, true}), do: {:num, {:int, 1}}
  def arith_operand({:bool, false}), do: {:num, {:int, 0}}
  def arith_operand(:null), do: {:num, {:int, 0}}

  def arith_operand({:string, s}) do
    case classify_string_number(s) do
      {:numeric, n} -> {:num, n}
      {:leading, n} -> {:leading, n}
      :non_numeric -> {:error, Error.type_error("Unsupported operand types: string")}
    end
  end

  def arith_operand({:array, _}),
    do: {:error, Error.type_error("Unsupported operand types: array")}

  def arith_operand({:object, _}),
    do: {:error, Error.type_error("Unsupported operand types: object")}

  # reference cells are dereferenced by the caller before arithmetic; a bare
  # cell falling through here treats as null (0), never a crash
  def arith_operand({:ref, _}), do: {:num, {:int, 0}}

  @doc "+ - * — int stays int unless a float is involved or int overflows."
  def arith(op, a, b) when op in [:+, :-, :*] do
    with {:ok, x} <- coerced(a),
         {:ok, y} <- coerced(b) do
      case {x, y} do
        {{:int, i}, {:int, j}} ->
          r = raw(op, i, j)
          if r > @int_max or r < @int_min, do: {:ok, {:float, r * 1.0}}, else: {:ok, {:int, r}}

        {{:float, _}, {:int, _}} ->
          {:ok, {:float, raw(op, ff(x), ff(y))}}

        {{:int, _}, {:float, _}} ->
          {:ok, {:float, raw(op, ff(x), ff(y))}}

        {{:float, _}, {:float, _}} ->
          {:ok, {:float, raw(op, ff(x), ff(y))}}
      end
    end
  end

  defp coerced(v) do
    case arith_operand(v) do
      {:num, n} -> {:ok, n}
      {:leading, n} -> {:ok, n}
      {:error, e} -> {:error, e}
    end
  end

  defp raw(:+, a, b), do: a + b
  defp raw(:-, a, b), do: a - b
  defp raw(:*, a, b), do: a * b

  defp ff({:int, i}), do: i * 1.0
  defp ff({:float, f}), do: f

  @doc "`/`: int/int → int only when evenly divisible; DivisionByZeroError on 0."
  def divide({:int, a}, {:int, b}) do
    cond do
      b == 0 -> {:error, Error.division_by_zero()}
      rem(a, b) == 0 -> {:ok, {:int, div(a, b)}}
      true -> {:ok, {:float, a / b}}
    end
  end

  def divide(a, b) do
    with {:ok, x} <- coerced(a),
         {:ok, y} <- coerced(b) do
      if ff(y) == 0.0 do
        {:error, Error.division_by_zero()}
      else
        {:ok, {:float, ff(x) / ff(y)}}
      end
    end
  end

  @doc "`%`: operands cast to int, C-style truncation semantics."
  def modulo(a, b) do
    with {:ok, x} <- coerced(a),
         {:ok, y} <- coerced(b) do
      warn_lossy_int(x)
      warn_lossy_int(y)

      with {:ok, {:int, i}} <- to_int(x),
           {:ok, {:int, j}} <- to_int(y) do
        if j == 0 do
          {:error, %Error{kind: :division_by_zero_error, message: "Modulo by zero"}}
        else
          {:ok, {:int, :erlang.rem(i, j)}}
        end
      end
    else
      {:error, e} -> {:error, e}
    end
  end

  # Deprecation notice emitted through the interpreter's warning channel by
  # the caller; here we only signal lossiness via a message tuple.
  defp warn_lossy_int({:float, f}) when trunc(f) != f,
    do:
      {:deprecated, "Implicit conversion from float #{float_to_string(f)} to int loses precision"}

  defp warn_lossy_int(_), do: :ok

  @doc "intdiv()."
  def intdiv(a, b) do
    with {:ok, x} <- coerced(a),
         {:ok, y} <- coerced(b),
         {:ok, {:int, i}} <- to_int(x),
         {:ok, {:int, j}} <- to_int(y) do
      cond do
        j == 0 ->
          {:error, Error.division_by_zero()}

        i == @int_min and j == -1 ->
          {:error, Error.arithmetic_error("Division of PHP_INT_MIN by -1 is not an integer")}

        true ->
          {:ok, {:int, :erlang.div(i, j)}}
      end
    else
      {:error, e} -> {:error, e}
    end
  end

  @doc "`**`: int base, non-negative int exp → int (may overflow to float)."
  def power(a, b) do
    with {:ok, x} <- coerced(a),
         {:ok, y} <- coerced(b) do
      case {x, y} do
        {{:int, i}, {:int, e}} when e >= 0 ->
          r = Integer.pow(i, e)

          if is_integer(r) and r <= @int_max and r >= @int_min,
            do: {:ok, {:int, r}},
            else: {:ok, {:float, r * 1.0}}

        {{:int, i}, {:int, e}} when e < 0 ->
          {:ok, {:float, :math.pow(i * 1.0, e)}}

        {_, _} ->
          {:ok, {:float, :math.pow(ff(x), ff(y))}}
      end
    end
  end

  @doc "Unary minus."
  def negate({:int, i}), do: {:ok, {:int, -i}}
  def negate({:float, f}), do: {:ok, {:float, -f}}

  def negate(v) do
    case arith_operand(v) do
      {:num, n} -> negate(n)
      {:leading, n} -> negate(n)
      {:error, e} -> {:error, e}
    end
  end

  @doc "Bitwise on ints (operands cast to int)."
  def bitwise(op, a, b) do
    with {:ok, x} <- coerced(a),
         {:ok, y} <- coerced(b),
         {:ok, {:int, i}} <- to_int(x),
         {:ok, {:int, j}} <- to_int(y) do
      case op do
        :& -> {:ok, {:int, Bitwise.band(i, j)}}
        :| -> {:ok, {:int, Bitwise.bor(i, j)}}
        :^ -> {:ok, {:int, Bitwise.bxor(i, j)}}
        :shl -> {:ok, {:int, Bitwise.bsl(i, shift(j))}}
        :shr -> {:ok, {:int, Bitwise.bsr(i, shift(j))}}
      end
    else
      {:error, e} -> {:error, e}
    end
  end

  defp shift(j) when j > 1024, do: 1024
  defp shift(j) when j < -1024, do: -1024
  defp shift(j), do: trunc(j)

  def bnot({:int, i}), do: {:ok, {:int, Bitwise.bnot(i)}}

  def bnot(v) do
    with {:ok, x} <- coerced(v), {:int, i} <- to_int(x) do
      {:ok, {:int, Bitwise.bnot(i)}}
    else
      e -> e
    end
  end

  @doc "JSON float: shortest round-trip (json serialize_precision=-1)."
  def float_serialize_json(f), do: float_serialize(f)

  # ─────────────────────────── increment ───────────────────────────

  @doc "`++` on a value (decrement never applies to strings/null)."
  def increment({:int, i}), do: {:int, i + 1}
  def increment({:float, f}), do: {:float, f + 1.0}
  def increment(:null), do: {:int, 1}
  def increment({:bool, _} = b), do: b

  def increment({:string, s}) do
    case classify_string_number(s) do
      {:numeric, {:int, i}} -> {:int, i + 1}
      {:numeric, {:float, f}} -> {:float, f + 1.0}
      {:leading, _} -> string_increment(s)
      :non_numeric -> string_increment(s)
    end
  end

  def increment({:array, _} = a), do: a
  def increment(:null = n), do: increment(n)

  def decrement({:int, i}), do: {:int, i - 1}
  def decrement({:float, f}), do: {:float, f - 1.0}
  def decrement({:string, _} = s), do: s
  def decrement({:bool, _} = b), do: b
  def decrement(:null = n), do: n
  def decrement({:array, _} = a), do: a

  # PHP zend_increment_string: walk from the right, carry through z/Z/9,
  # stop after bumping a normal alnum; on full carry prepend a/A/1.
  defp string_increment(s) do
    case inc_from_right(:binary.bin_to_list(s)) do
      {:ok, s2} ->
        {:string, s2}

      {:carry, wrapped} ->
        case :binary.first(s) do
          c when c in ?a..?z -> {:string, "a" <> wrapped}
          c when c in ?A..?Z -> {:string, "A" <> wrapped}
          c when c in ?0..?9 -> {:string, "1" <> wrapped}
          _ -> {:string, s}
        end

      :unchanged ->
        {:string, s}
    end
  end

  defp inc_from_right(bytes) do
    case inc_rev(Enum.reverse(bytes)) do
      {:stop, rev} -> {:ok, :binary.list_to_bin(Enum.reverse(rev))}
      {:carry, rev} -> {:carry, :binary.list_to_bin(Enum.reverse(rev))}
      :unchanged -> :unchanged
    end
  end

  # work on reversed byte lists; carry_char wraps in place and keeps going left
  defp inc_rev([]), do: {:carry, []}

  defp inc_rev([c | rest]) when c in ?a..?y or c in ?A..?Y or c in ?0..?8,
    do: {:stop, [c + 1 | rest]}

  defp inc_rev([c | rest]) when c == ?z or c == ?Z or c == ?9 do
    case inc_rev(rest) do
      {:stop, r} -> {:stop, [carry_char(c) | r]}
      {:carry, r} -> {:carry, [carry_char(c) | r]}
      :unchanged -> :unchanged
    end
  end

  defp inc_rev([_ | _]), do: :unchanged

  defp carry_char(?z), do: ?a
  defp carry_char(?Z), do: ?A
  defp carry_char(?9), do: ?0

  # ─────────────────────────── float formatting ───────────────────────────

  @doc "Float → string like PHP echo (precision=14, gcvt style, round-half-even)."
  def float_to_string(f) do
    sign = if f < 0 or (f == 0 and sign_bit(f)), do: "-", else: ""
    format_gcvt(abs(f), @float_precision, sign)
  end

  @doc "Float → string for var_dump/json (serialize_precision=-1: shortest round-trip)."
  def float_serialize(f) do
    sign = if f < 0 or (f == 0 and sign_bit(f)), do: "-", else: ""
    {digits, e} = shortest_digits(abs(f))

    if e >= 16 or e < -4 do
      mant =
        case digits do
          [d] -> <<d + ?0>> <> ".0"
          [d | rest] -> <<d + ?0>> <> "." <> to_digits(rest)
        end

      sign <> mant <> "E" <> if(e >= 0, do: "+", else: "-") <> Integer.to_string(abs(e))
    else
      sign <> plain_format(digits, e)
    end
  end

  defp sign_bit(f) do
    <<s::1, _::63>> = <<f::float>>
    s == 1
  end

  defp format_gcvt(0.0, _p, sign), do: sign <> "0"

  defp format_gcvt(f, p, sign) do
    {digits, e} = shortest_digits(f)

    {digits, e} = round_half_even(digits, p, e)

    cond do
      e >= p or e < -4 ->
        mant =
          case digits do
            [d] -> <<d + ?0>> <> ".0"
            [d | rest] -> <<d + ?0>> <> "." <> to_digits(rest)
          end

        sign <> mant <> "E" <> if(e >= 0, do: "+", else: "-") <> Integer.to_string(abs(e))

      true ->
        sign <> plain_format(digits, e)
    end
  end

  defp to_digits(list), do: list |> Enum.map(&<<&1 + ?0>>) |> IO.iodata_to_binary()

  # decimal digits (as byte values) and the decimal exponent of the first digit
  defp shortest_digits(f) do
    s = Float.to_string(f)

    {mant, exp} =
      case :binary.match(s, "e") do
        {pos, 1} ->
          {binary_part(s, 0, pos),
           String.to_integer(binary_part(s, pos + 1, byte_size(s) - pos - 1))}

        :nomatch ->
          {s, 0}
      end

    {int_part, frac} =
      case :binary.match(mant, ".") do
        {pos, 1} ->
          {binary_part(mant, 0, pos), binary_part(mant, pos + 1, byte_size(mant) - pos - 1)}

        :nomatch ->
          {mant, ""}
      end

    raw = (int_part <> frac) |> :binary.bin_to_list() |> Enum.map(&(&1 - ?0))
    {digits, leading_zeros} = strip_leading_zeros(raw)

    digits =
      if digits == [] do
        [0]
      else
        digits
      end

    e = exp + byte_size(int_part) - 1 - leading_zeros
    {strip_trailing_zeros(digits), e}
  end

  defp strip_leading_zeros(digits), do: do_strip_leading(digits, 0)

  defp do_strip_leading([0 | rest], n), do: do_strip_leading(rest, n + 1)
  defp do_strip_leading(rest, n), do: {rest, n}

  defp strip_trailing_zeros(digits) do
    Enum.reverse(digits)
    |> Enum.drop_while(&(&1 == 0))
    |> Enum.reverse()
  end

  # round digit list to p significant digits, half-even on the exact value
  defp round_half_even(digits, p, e) do
    if length(digits) <= p do
      {digits, e}
    else
      {kept, dropped} = Enum.split(digits, p)
      last = List.last(kept)

      round_up? =
        case dropped do
          [d | _rest] when d > 5 -> true
          [5 | rest] when rest != [] -> true
          [5 | []] -> rem(last, 2) == 1
          _ -> false
        end

      if round_up? do
        case bump(kept) do
          {:ok, kept2} -> {strip_trailing_zeros(kept2), e}
          :carry -> {[1], e + 1}
        end
      else
        {strip_trailing_zeros(kept), e}
      end
    end
  end

  defp bump(kept) do
    Enum.reverse(kept)
    |> do_bump()
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      c -> c
    end
  end

  defp do_bump([d | rest]) when d < 9, do: {:ok, [d + 1 | rest]}

  defp do_bump([9 | rest]) do
    case do_bump(rest) do
      {:ok, r} -> {:ok, [0 | r]}
      :carry -> :carry
    end
  end

  defp do_bump([]), do: :carry

  defp plain_format(digits, e) do
    cond do
      e >= 0 ->
        n = e + 1

        int_part =
          if length(digits) <= n do
            to_digits(digits) <> String.duplicate("0", n - length(digits))
          else
            {i, f} = Enum.split(digits, n)
            to_digits(i) <> "." <> to_digits(strip_trailing_zeros(f))
          end

        String.trim_trailing(int_part, ".")

      true ->
        zeros = String.duplicate("0", -e - 1)
        "0." <> zeros <> to_digits(digits)
    end
  end
end
