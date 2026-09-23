defmodule PhpBeam.Builtin do
  @moduledoc """
  Builtin function registry. Each builtin is `%{fun: fun(vals, interp, ctx), refs: []}`
  where `fun` returns `{:ok, v, interp}` (or `{:ref_call, v, vals', interp}` for
  functions that mutate by-reference arguments).
  """

  alias PhpBeam.Builtin.{ArrayFns, MathFns, StringFns, VarFns}
  alias PhpBeam.{PArray, Render, Value}

  def registry do
    %{}
    |> StringFns.register()
    |> MathFns.register()
    |> ArrayFns.register()
    |> VarFns.register()
    |> output_fns()
  end

  # ───────────────────────── output ─────────────────────────

  defp output_fns(fns0) do
    put = fn fns, name, fun -> Map.put(fns, name, %{fun: fun, refs: []}) end

    fns =
      put.(fns0, "var_dump", fn vals, interp, _ctx ->
        iodata = Enum.flat_map(vals, &Render.var_dump_lines(&1, interp))
        {:ok, :null, PhpBeam.Interp.write(interp, IO.iodata_to_binary(iodata))}
      end)

    fns =
      put.(fns, "print_r", fn vals, interp, _ctx ->
        case vals do
          [v, {:bool, true}] -> {:ok, {:string, Render.print_r(v, interp)}, interp}
          [v | _] -> {:ok, :null, PhpBeam.Interp.write(interp, Render.print_r(v, interp))}
          [] -> {:ok, {:bool, false}, interp}
        end
      end)

    fns =
      put.(fns, "var_export", fn vals, interp, _ctx ->
        case vals do
          [v, {:bool, true}] ->
            {:ok, {:string, Render.var_export(v, interp)}, interp}

          [v | _] ->
            {:ok, :null, PhpBeam.Interp.write(interp, Render.var_export(v, interp) <> "\n")}

          [] ->
            {:ok, :null, interp}
        end
      end)

    fns = put.(fns, "sprintf", fn vals, interp, _ctx -> php_sprintf(vals, interp) end)

    fns =
      put.(fns, "printf", fn vals, interp, _ctx ->
        case php_sprintf(vals, interp) do
          {:ok, {:string, s}, interp2} ->
            {:ok, {:int, byte_size(s)}, PhpBeam.Interp.write(interp2, s)}
        end
      end)

    fns =
      put.(fns, "json_encode", fn vals, interp, _ctx ->
        v =
          case vals do
            [first | _] -> first
            [] -> :null
          end

        {:ok, {:string, json_encode(v, interp)}, interp}
      end)

    fns =
      put.(fns, "json_decode", fn vals, interp, _ctx ->
        decoded =
          case vals do
            [{:string, s}, {:bool, true} | _] ->
              case Jason.decode(s) do
                {:ok, term} -> json_to_value_assoc(term)
                _ -> :null
              end

            [{:string, s} | _] ->
              case Jason.decode(s) do
                {:ok, term} -> json_to_value(term)
                _ -> :null
              end

            _ ->
              :null
          end

        {val, interp2} = register_json_objects(decoded, interp)
        {:ok, val, interp2}
      end)

    fns =
      put.(fns, "define", fn vals, interp, _ctx ->
        case vals do
          [{:string, name}, v | _] ->
            {:ok, {:bool, true}, %{interp | consts: Map.put(interp.consts, name, v)}}

          _ ->
            {:ok, {:bool, false}, interp}
        end
      end)

    fns =
      put.(fns, "defined", fn vals, interp, _ctx ->
        res =
          case vals do
            [{:string, name} | _] -> Map.has_key?(interp.consts, name)
            _ -> false
          end

        {:ok, {:bool, res}, interp}
      end)

    fns =
      put.(fns, "constant", fn vals, interp, _ctx ->
        v =
          case vals do
            [{:string, name} | _] -> Map.get(interp.consts, name, :null)
            _ -> :null
          end

        {:ok, v, interp}
      end)

    fns =
      put.(fns, "time", fn _vals, interp, _ctx ->
        {:ok, {:int, System.system_time(:second)}, interp}
      end)

    fns =
      put.(fns, "microtime", fn vals, interp, _ctx ->
        now = System.system_time(:microsecond)

        case vals do
          [{:bool, true} | _] -> {:ok, {:string, Float.to_string(now / 1.0e6)}, interp}
          _ -> {:ok, {:string, :erlang.float_to_binary(now / 1.0e6, decimals: 8)}, interp}
        end
      end)

    fns =
      put.(fns, "date", fn vals, interp, _ctx ->
        case vals do
          [{:string, fmt} | rest] ->
            ts =
              case rest do
                [{:int, t} | _] -> t
                _ -> System.system_time(:second)
              end

            {:ok, {:string, php_date(fmt, ts)}, interp}

          _ ->
            {:ok, {:string, ""}, interp}
        end
      end)

    fns
  end

  # walk decoded JSON, turning stdClass markers into registry objects
  # parents get ids before their children, matching PHP creation order
  defp register_json_objects({:obj_reg, props}, interp) do
    {ref, interp2} = PhpBeam.Eval.new_stdclass(interp, PArray.new())

    {props2, interp3} =
      Enum.reduce(PArray.to_pairs(props), {PArray.new(), interp2}, fn {k, v}, {acc, it} ->
        {v2, it2} = register_json_objects(v, it)
        {:ok, a2} = PArray.put(acc, {:string, k}, v2)
        {a2, it2}
      end)

    obj = PhpBeam.Eval.get_object(interp3, ref)
    {ref, PhpBeam.Eval.put_object(interp3, ref, %{obj | props: props2})}
  end

  defp register_json_objects({:array, arr}, interp) do
    {pairs, interp2} =
      Enum.reduce(PArray.to_pairs(arr), {[], interp}, fn {k, v}, {acc, it} ->
        {v2, it2} = register_json_objects(v, it)
        wrapped = if is_binary(k), do: {:string, k}, else: {:int, k}
        {[{wrapped, v2} | acc], it2}
      end)

    {{:array, PArray.from_pairs(Enum.reverse(pairs))}, interp2}
  end

  defp register_json_objects(v, interp), do: {v, interp}

  # ───────────────────────── sprintf ─────────────────────────

  def php_sprintf([{:string, fmt} | args], interp) do
    {out, _rest} = do_sprintf(fmt, args, interp)
    {:ok, {:string, out}, interp}
  end

  def php_sprintf(_, interp), do: {:ok, {:string, ""}, interp}

  defp sprintf(fmt, args, interp) do
    {out, _} = do_sprintf(fmt, args, interp)
    {:ok, {:string, out}, interp}
  end

  @sprintf_re ~r/%([-+0 ]*)(\d*)(?:\.(\d+))?([sdfFxXb%])/

  defp do_sprintf(fmt, args, interp) do
    case Regex.run(@sprintf_re, fmt) do
      nil ->
        {fmt, args}

      [full, flags, width_s, prec_s, type] ->
        {pre, rest} = split_on(fmt, full)

        {body, args2} =
          cond do
            type == "%" ->
              {"%", args}

            args == [] ->
              {"", args}

            true ->
              [a | more] = args
              {apply_spec(flags, width_s, prec_s, type, a), more}
          end

        {out, args3} = do_sprintf(rest, args2, interp)
        {pre <> body <> out, args3}
    end
  end

  defp split_on(fmt, sub) do
    idx = :binary.match(fmt, sub) |> elem(0)

    {binary_part(fmt, 0, idx),
     binary_part(fmt, idx + byte_size(sub), byte_size(fmt) - idx - byte_size(sub))}
  end

  defp apply_spec(flags, width_s, prec_s, type, a) do
    left? = String.contains?(flags, "-")
    plus? = String.contains?(flags, "+")
    zero? = String.contains?(flags, "0")
    space? = String.contains?(flags, " ")
    width = if width_s == "", do: 0, else: String.to_integer(width_s)
    prec = if prec_s == "", do: nil, else: String.to_integer(prec_s)

    body =
      case type do
        "s" ->
          str = PhpBeam.Eval.php_to_string(a)

          if prec,
            do: binary_part(str, 0, min(prec, byte_size(str))),
            else: str

        "d" ->
          {:ok, {:int, n}} = PhpBeam.Value.to_int(a)
          sign_num(Integer.to_string(n), n < 0, plus?, space?)

        "f" ->
          {:ok, {:float, f}} = PhpBeam.Value.to_float(a)
          :erlang.float_to_binary(f, decimals: prec || 6)

        "F" ->
          {:ok, {:float, f}} = PhpBeam.Value.to_float(f_or(a))
          :erlang.float_to_binary(f, decimals: prec || 6)

        "x" ->
          {:ok, {:int, n}} = PhpBeam.Value.to_int(a)
          Integer.to_string(n, 16)

        "X" ->
          {:ok, {:int, n}} = PhpBeam.Value.to_int(a)
          Integer.to_string(n, 16) |> String.upcase()

        "b" ->
          {:ok, {:int, n}} = PhpBeam.Value.to_int(a)
          Integer.to_string(n, 2)

        _ ->
          PhpBeam.Eval.php_to_string(a)
      end

    cond do
      byte_size(body) >= width -> body
      zero? and type != "s" -> pad_zero(body, width, left?)
      true -> pad_space(body, width, left?)
    end
  end

  defp f_or(v), do: v

  defp sign_num(digits, true, _plus?, _space?), do: "-" <> digits
  defp sign_num(digits, false, true, _space?), do: "+" <> digits
  defp sign_num(digits, false, false, true), do: " " <> digits
  defp sign_num(digits, false, _, _), do: digits

  defp pad_zero(body, width, left?) do
    {sign, digits} =
      case body do
        "-" <> rest -> {"-", rest}
        "+" <> rest -> {"+", rest}
        _ -> {"", body}
      end

    padded = sign <> String.pad_leading(digits, width - byte_size(sign), "0")

    if left?, do: body <> String.duplicate("0", max(width - byte_size(body), 0)), else: padded
  end

  defp pad_space(body, width, left?) do
    pad = String.duplicate(" ", max(width - byte_size(body), 0))
    if left?, do: body <> pad, else: pad <> body
  end

  # ───────────────────────── json ─────────────────────────

  def json_encode(v, interp), do: json_encode_ordered(v, interp)

  def json_encode_ordered({:ref, _} = r, interp),
    do: json_encode_ordered(PhpBeam.Eval.deref(r, interp), interp)

  def json_encode_ordered({:string, s}, _), do: Jason.encode!(s)
  def json_encode_ordered({:int, n}, _), do: Integer.to_string(n)
  def json_encode_ordered({:float, f}, _), do: Value.float_serialize_json(f)
  def json_encode_ordered({:bool, true}, _), do: "true"
  def json_encode_ordered({:bool, false}, _), do: "false"
  def json_encode_ordered(:null, _), do: "null"

  def json_encode_ordered({:array, arr}, interp) do
    pairs = PArray.to_pairs(arr)
    seq? = Enum.with_index(pairs) |> Enum.all?(fn {{k, _}, idx} -> k == idx end)

    if seq? do
      "[" <> Enum.map_join(pairs, ",", fn {_, v} -> json_encode_ordered(v, interp) end) <> "]"
    else
      "{" <>
        Enum.map_join(pairs, ",", fn {k, v} ->
          key = if is_integer(k), do: Integer.to_string(k), else: k
          Jason.encode!(key) <> ":" <> json_encode_ordered(v, interp)
        end) <> "}"
    end
  end

  def json_encode_ordered({:object, %{props: props}}, interp) do
    "{" <>
      Enum.map_join(props, ",", fn {k, v} ->
        Jason.encode!(k) <> ":" <> json_encode_ordered(v, interp)
      end) <> "}"
  end

  def json_encode_ordered(_, _), do: "null"

  defp json_term({:ref, _} = r, interp), do: json_term(PhpBeam.Eval.deref(r, interp), interp)
  defp json_term({:int, n}, _), do: n
  defp json_term({:float, f}, _), do: f
  defp json_term({:bool, b}, _), do: b
  defp json_term(:null, _), do: nil
  defp json_term({:string, s}, _), do: s

  defp json_term({:array, arr}, interp) do
    pairs = PArray.to_pairs(arr)

    seq? =
      Enum.with_index(pairs) |> Enum.all?(fn {{k, _}, idx} -> k == idx end)

    if seq? and pairs != [] do
      Enum.map(pairs, fn {_, v} -> json_term(v, interp) end)
    else
      Map.new(pairs, fn {k, v} ->
        key = if is_integer(k), do: Integer.to_string(k), else: k
        {key, json_term(v, interp)}
      end)
    end
  end

  defp json_term(_, _), do: nil

  def json_to_value(term) do
    case term do
      %{} ->
        # stdClass objects register into the object table (handle semantics)
        props =
          Enum.reduce(term, PArray.new(), fn {k, v}, acc ->
            {:ok, a2} = PArray.put(acc, {:string, k}, json_to_value(v))
            a2
          end)

        {:obj_reg, props}

      list when is_list(list) ->
        {:array, PArray.from_pairs(Enum.map(list, &{nil, json_to_value(&1)}))}

      n when is_integer(n) ->
        {:int, n}

      f when is_float(f) ->
        {:float, f}

      b when is_boolean(b) ->
        {:bool, b}

      nil ->
        :null

      s when is_binary(s) ->
        {:string, s}
    end
  end

  def json_to_value_assoc(term) do
    case term do
      list when is_list(list) ->
        {:array,
         PArray.from_pairs(Enum.with_index(list, fn v, i -> {i, json_to_value_assoc(v)} end))}

      other ->
        json_to_value(other)
    end
  end

  # ───────────────────────── date ─────────────────────────

  @weekday ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)
  @month ~w(January February March April May June July August September October November December)

  def php_date(fmt, ts) do
    dt = DateTime.from_unix!(ts)

    fmt
    |> String.graphemes()
    |> Enum.reduce({[], nil}, fn ch, {acc, prev} ->
      acc =
        case ch do
          "Y" -> [Integer.to_string(dt.year) | acc]
          "y" -> [dt.year |> Integer.to_string() |> String.slice(-2, 2) | acc]
          "m" -> [pad2(dt.month) | acc]
          "n" -> [Integer.to_string(dt.month) | acc]
          "d" -> [pad2(dt.day) | acc]
          "j" -> [Integer.to_string(dt.day) | acc]
          "H" -> [pad2(dt.hour) | acc]
          "G" -> [Integer.to_string(dt.hour) | acc]
          "i" -> [pad2(dt.minute) | acc]
          "s" -> [pad2(dt.second) | acc]
          "A" -> [if(dt.hour < 12, do: "AM", else: "PM") | acc]
          "a" -> [if(dt.hour < 12, do: "am", else: "pm") | acc]
          "l" -> [Enum.at(@weekday, day_of_week(dt)) | acc]
          "D" -> [Enum.at(@weekday, day_of_week(dt)) |> String.slice(0, 3) | acc]
          "F" -> [Enum.at(@month, dt.month - 1) | acc]
          "M" -> [Enum.at(@month, dt.month - 1) |> String.slice(0, 3) | acc]
          "N" -> [Integer.to_string(day_of_week(dt) + 1) | acc]
          "w" -> [Integer.to_string(day_of_week(dt)) | acc]
          "U" -> [Integer.to_string(ts) | acc]
          "\\" <> _ -> acc
          c when prev == "\\" -> [c | acc]
          c -> [c | acc]
        end

      {acc, ch}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp day_of_week(dt) do
    jd = :calendar.date_to_gregorian_days(dt.year, dt.month, dt.day)
    rem(jd + 5, 7)
  end
end
