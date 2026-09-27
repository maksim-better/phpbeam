defmodule PhpBeam.Classes.Gmp do
  @moduledoc """
  The GMP arbitrary-precision integer class. The integer lives in the object's
  single visible prop `"num"` (decimal string) — var_dump/serialize parity —
  and every operation reads/parses it through `gmp_val/3`. Operators on GMP
  are hooked in Eval.apply_binop/5 and the unop/cast paths (php overloads
  +,-,*,/,%,**,<<,>>,&,|,^,~,==,!=,<,<=,>,>=,<=> on GMP).

  Probed php 8.4 semantics: mutable reference handles (`$b=$a` shares, clone
  copies), default-base parsing auto-detects 0x/0b/0 prefixes while explicit
  bases are strict, `/` truncates toward zero, `%` follows the divisor sign,
  bitwise ops use infinite two's complement, popcount(-n) = -1.
  """

  alias PhpBeam.Classes.Table
  alias PhpBeam.Eval
  alias PhpBeam.Error
  alias PhpBeam.PArray

  # ────────────────────────── class registration ──────────────────────────

  def classes do
    %{"gmp" => gmp_class()}
  end

  defp gmp_class do
    methods = %{
      "__construct" =>
        nfn("__construct", fn obj, _a, i -> {:ok, {:null, obj}, i} end),
      "__serialize" =>
        nfn("__serialize", fn obj, _a, i ->
          num = prop_num(obj)

          {:ok,
           {{:array, PArray.from_pairs([{0, {:string, Integer.to_string(num)}}])},
            obj, i}}
        end),
      "__unserialize" =>
        nfn("__unserialize", fn obj, a, i ->
          num =
            case a do
              [v | _] ->
                case v do
                  {:string, s} -> parse_radix(s, 10) |> elem(1)
                  {:int, n} -> n
                  _ -> 0
                end

              _ ->
                0
            end

          {:ok, {:null, put_num(obj, num)}, i}
        end)
    }

    struct!(Table,
      name: "GMP",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: methods,
      file: ""
    )
  end

  defp nfn(name, fun) do
    %{
      name: name,
      visibility: :public,
      static?: false,
      abstract?: false,
      final?: false,
      params: [],
      body: [],
      class: "gmp",
      line: nil,
      gen?: false,
      native: {:native, fun}
    }
  end

  # ────────────────────────── object construction ──────────────────────────

  @doc "new GMP instance holding n (fresh object, interp threaded)"
  def new(interp, n) do
    {ref, i2} = Eval.make_instance(interp, "gmp")
    obj = Eval.get_object(i2, ref)
    i3 = Eval.put_object(i2, ref, put_num(obj, n))
    {ref, i3}
  end

  defp put_num(obj, n) do
    arr =
      case PArray.put(obj.props, {:string, "num"}, {:string, Integer.to_string(n)}) do
        {:ok, p} -> p
        _ -> obj.props
      end

    %{obj | props: arr}
  end

  @doc "the integer inside a GMP object (assumes class checked)"
  def prop_num(obj) do
    case PArray.fetch(obj.props, {:string, "num"}) do
      {:ok, {:string, s}} -> String.to_integer(s)
      {:ok, {:int, n}} -> n
      _ -> 0
    end
  end

  @doc "is this value a GMP object? (registry read)"
  def gmp?(interp, {:object, _} = ref) do
    obj = Eval.get_object(interp, ref)
    obj.class == "gmp"
  end

  def gmp?(_, _), do: false

  @doc "unwrap int from GMP object"
  def obj_int(interp, {:object, _} = ref), do: prop_num(Eval.get_object(interp, ref))

  # ────────────────────────── operator overloading ──────────────────────────

  @gmp_ops [:+, :-, :*, :/, :%, :**, :shl, :shr, :&, :|, :^, :==, :!=, :<, :<=, :>, :>=, :"<=>", :.]

  @doc """
  GMP operator hook for Eval.apply_binop/5: if either operand is a GMP
  object (and the other side coerces like php would — int or integer
  string), compute the overloaded op. :no_gmp falls back to std binop.
  """
  def binop(interp, op, l, r) when op in @gmp_ops do
    # engage ONLY when an actual GMP object participates — plain int/string
    # arithmetic must keep taking the std path (no fresh-object allocation)
    if gmp_obj?(interp, l) or gmp_obj?(interp, r) do
      lg = as_int(interp, l)
      rg = as_int(interp, r)

      case {lg, rg} do
        {{:ok, a}, {:ok, b}} -> compute(op, a, b)
        _ -> :no_gmp
      end
    else
      :no_gmp
    end
  end

  def binop(_interp, _op, _l, _r), do: :no_gmp

  defp gmp_obj?(interp, {:object, _} = ref), do: gmp?(interp, ref)
  defp gmp_obj?(_, _), do: false

  defp as_int(interp, v) do
    case v do
      {:int, n} ->
        {:ok, n}

      {:string, s} ->
        case parse_auto(s) do
          {:ok, n} -> {:ok, n}
          :error -> :no
        end

      _ ->
        if gmp?(interp, v), do: {:ok, obj_int(interp, v)}, else: :no
    end
  end

  defp compute(op, a, b) do
    case op do
      :+ -> gmp_res(a + b)
      :- -> gmp_res(a - b)
      :* -> gmp_res(a * b)
      :/ -> gmp_res(trunc_div(a, b))
      :% -> gmp_res(Integer.mod(a, b))
      :** -> gmp_res(a ** b)
      :shl -> gmp_res(Bitwise.bsl(a, b))
      :shr -> gmp_res(Bitwise.bsr(a, b))
      :& -> gmp_res(Bitwise.band(a, b))
      :| -> gmp_res(Bitwise.bor(a, b))
      :^ -> gmp_res(Bitwise.bxor(a, b))
      :== -> {:gmp, {:bool, a == b}}
      :!= -> {:gmp, {:bool, a != b}}
      :< -> {:gmp, {:bool, a < b}}
      :<= -> {:gmp, {:bool, a <= b}}
      :> -> {:gmp, {:bool, a > b}}
      :>= -> {:gmp, {:bool, a >= b}}
      :"<=>" -> {:gmp, {:int, int_cmp(a, b)}}
      :. -> {:gmp, {:string, Integer.to_string(a) <> Integer.to_string(b)}}
      _ -> :no_gmp
    end
  end

  defp gmp_res(n), do: {:gmp, {:object_new, n}}

  defp int_cmp(a, b) when a < b, do: -1
  defp int_cmp(a, b) when a > b, do: 1
  defp int_cmp(_, _), do: 0

  defp trunc_div(a, b) do
    q = div(abs(a), abs(b))
    if (a < 0) != (b < 0), do: -q, else: q
  end

  # ────────────────────────── parse / format ──────────────────────────

  @doc """
  Parse with an explicit base (strict digits, 2..62 / -2..-36; negative
  bases treat the input as unsigned). Returns {n, ""} | :error.
  """
  def parse_radix(s, base) do
    {mag_s, sign} =
      case s do
        "-" <> rest -> {rest, -1}
        "+" <> rest -> {rest, 1}
        _ -> {s, 1}
      end

    {digits, signed} =
      if base < 0 do
        {mag_s, 1}
      else
        {mag_s, sign}
      end

    base = abs(base)

    case digits_to_int(digits, base) do
      {:ok, n} -> {signed * n, ""}
      :error -> :error
    end
  end

  # 2-36: case-insensitive; 37-62: uppercase 10-35, lowercase 36-61 (gmp order)
  defp digits_to_int(digits, base) do
    if base < 2 or base > 62 or digits == "" do
      :error
    else
      vals =
        digits
        |> String.to_charlist()
        |> Enum.map(&digit_val(&1, base))

      if Enum.any?(vals, &(&1 == :bad)) do
        :error
      else
        Enum.reduce(vals, 0, fn d, acc -> acc * base + d end) |> then(&{:ok, &1})
      end
    end
  end

  defp digit_val(c, base) when base <= 36 do
    cond do
      c in ?0..?9 -> c - ?0
      c in ?a..?z -> c - ?a + 10
      c in ?A..?Z -> c - ?A + 10
      true -> :bad
    end
  end

  defp digit_val(c, base) do
    cond do
      c in ?0..?9 -> c - ?0
      c in ?A..?Z -> c - ?A + 10
      c in ?a..?z -> c - ?a + 36
      true -> :bad
    end
  end

  @doc "format n in base (2..62 or -2..-36)"
  def to_radix(n, base) do
    {digits_s, signed} =
      if base < 0 do
        {abs(n), n < 0}
      else
        {n, n < 0}
      end

    sign = if signed, do: "-", else: ""
    sign <> int_to_digits(abs(n), abs(base), [])
  end

  defp int_to_digits(0, _base, []), do: "0"
  defp int_to_digits(0, _base, acc), do: List.to_string(acc)

  defp int_to_digits(n, base, acc) do
    int_to_digits(div(n, base), base, [digit_char(rem(n, base)) | acc])
  end

  defp digit_char(d) when d < 10, do: ?0 + d
  defp digit_char(d) when d < 36 and d >= 10, do: ?A + (d - 10)
  defp digit_char(d), do: ?a + (d - 36)

  @doc """
  Default-base parse (gmp_init/2 with base 10): auto-detects 0x/0b/0
  prefixes after the sign; rejects empty/whitespace. {:ok, n} | :error.
  """
  def parse_auto(s) do
    case s do
      "" ->
        :error

      " " <> _ ->
        :error

      _ ->
        {mag, sign} =
          case s do
            "-" <> rest -> {rest, -1}
            "+" <> rest -> {rest, 1}
            _ -> {s, 1}
          end

        {body, base} =
          cond do
            mag in ["0x", "0X", "0b", "0B"] -> {mag, nil}
            String.starts_with?(mag, "0x") or String.starts_with?(mag, "0X") ->
              {String.slice(mag, 2..-1//1), 16}

            String.starts_with?(mag, "0b") or String.starts_with?(mag, "0B") ->
              {String.slice(mag, 2..-1//1), 2}

            String.length(mag) > 1 and String.starts_with?(mag, "0") ->
              {String.slice(mag, 1..-1//1), 8}

            true ->
              {mag, 10}
          end

        case body do
          "" ->
            # bare "0x"/"0b"/"0" — "0" is 0, bare prefixes are invalid
            if mag == "0", do: {:ok, 0}, else: :error

          _ ->
            case digits_to_int(body, base) do
              {:ok, n} -> {:ok, sign * n}
              :error -> :error
            end
        end
    end
  end
end
