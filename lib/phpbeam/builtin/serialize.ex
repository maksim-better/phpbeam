defmodule PhpBeam.Builtin.SerializeFns do
  @moduledoc """
  serialize()/unserialize() — the PHP wire format.

  Object property names carry visibility markers exactly like php:
  public `x`, protected `\\0*\\0x`, private `\\0DeclaringClass\\0x`.
  Floats use the shortest round-trip repr (serialize_precision=-1).
  """

  alias PhpBeam.{PArray}

  def register(fns) do
    entries = %{
      "serialize" => &serialize_v/2,
      "unserialize" => &unserialize_v/2
    }

    Enum.reduce(entries, fns, fn {name, fun}, acc ->
      Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
    end)
  end

  ## ─────────────────────────── serialize ───────────────────────────

  defp serialize_v([v | _], i), do: {:ok, {:string, ser(v, i)}, i}
  defp serialize_v(_, i), do: {:ok, {:bool, false}, i}

  defp ser({:int, n}, _i), do: "i:#{n};"

  defp ser({:bool, b}, _i), do: "b:#{if(b, do: "1", else: "0")};"

  defp ser(:null, _i), do: "N;"

  defp ser({:float, f}, _i), do: "d:" <> ser_float(f) <> ";"

  defp ser({:string, s}, _i), do: ~s(s:#{byte_size(s)}:") <> s <> ~s(";)

  defp ser({:array, arr}, i) do
    inner =
      arr
      |> PArray.to_pairs()
      |> Enum.map_join(fn {k, v} -> ser_key(k) <> ser(v, i) end)

    "a:#{PArray.size(arr)}:{" <> inner <> "}"
  end

  defp ser({:object, id}, i) do
    case Map.get(i.objects, id) do
      %{class: cls} = obj ->
        %{name: cls_name} = Map.get(i.classes, cls) || %{name: cls}

        inner =
          obj.props
          |> PArray.to_pairs()
          |> Enum.map_join(fn {k, v} ->
            name = mangle_prop(k, cls, i)
            ~s(s:#{byte_size(name)}:") <> name <> ~s(";) <> ser(v, i)
          end)

        "O:#{byte_size(cls_name)}:\"#{cls_name}\":#{PArray.size(obj.props)}:{" <>
          inner <> "}"

      _ ->
        "N;"
    end
  end

  defp ser_key(k) when is_integer(k), do: "i:#{k};"
  defp ser_key(k) when is_binary(k), do: ~s(s:#{byte_size(k)}:") <> k <> ~s(";)

  # php: serialize_precision=-1 → shortest round-trip ("1.0E+25" style);
  # INF/NAN are not representable as BEAM floats — nearest stand-ins
  defp ser_float(f) when f != f, do: "NAN"
  defp ser_float(:infinity), do: "INF"
  defp ser_float(:neg_infinity), do: "-INF"

  defp ser_float(f) do
    s = Float.to_string(f)

    if String.contains?(s, "e") do
      s |> String.replace("e", "E") |> then(&Regex.replace(~r/E([0-9])/, &1, "E+\\1"))
    else
      s
    end
  end

  # visibility marker + declared-case name from the defining class
  defp mangle_prop(k, cls, i) do
    name = if is_binary(k), do: k, else: to_string(k)

    case prop_decl(name, cls, i) do
      {:private, display, decl} -> "\0" <> decl <> "\0" <> display
      {:protected, display, _} -> "\0*\0" <> display
      {:public, display, _} -> display
      :dynamic -> name
    end
  end

  defp prop_decl(name, cls, i) do
    case i.classes[cls] do
      %{props: props, parent: parent, name: cname} ->
        case Enum.find(props, &(&1.name == name)) do
          %{visibility: :private, display: d} -> {:private, d, cname}
          %{visibility: :protected, display: d} -> {:protected, d, cname}
          %{visibility: _, display: d} -> {:public, d, cname}
          _ -> if parent, do: prop_decl(name, parent, i), else: :dynamic
        end

      _ ->
        :dynamic
    end
  end

  ## ────────────────────────── unserialize ──────────────────────────
  # offset parser; the returned interp is threaded because unserializing
  # objects registers them in interp.objects

  defp unserialize_v([{:string, s} | _], i) do
    case unser(s, 0, i) do
      {:ok, v, _off, i2} ->
        {:ok, v, i2 || i}

      {:error, off} ->
        i2 =
          PhpBeam.Interp.warn(
            i,
            "unserialize(): Error at offset #{off} of #{byte_size(s)} bytes"
          )

        {:ok, {:bool, false}, i2}
    end
  end

  defp unserialize_v(_, i), do: {:ok, {:bool, false}, i}

  defp unser(s, off, i) do
    rest = safe_part(s, off)

    cond do
      String.starts_with?(rest, "N;") -> {:ok, :null, off + 2, nil}
      String.starts_with?(rest, "b:1;") -> {:ok, {:bool, true}, off + 4, nil}
      String.starts_with?(rest, "b:0;") -> {:ok, {:bool, false}, off + 4, nil}
      String.starts_with?(rest, "i:") -> read_int_tail(s, off + 2, &{:int, &1})
      String.starts_with?(rest, "d:") -> read_double(s, off + 2)
      String.starts_with?(rest, "s:") -> read_string(s, off + 2)
      String.starts_with?(rest, "a:") -> read_array(s, off, i)
      String.starts_with?(rest, "O:") -> read_object(s, off, i)
      true -> {:error, off}
    end
  end

  defp read_int_tail(s, off, wrap) do
    case Regex.run(~r/\A(-?\d+);/, safe_part(s, off)) do
      [_, d] -> {:ok, wrap.(String.to_integer(d)), off + byte_size(d) + 1, nil}
      _ -> {:error, off}
    end
  end

  defp read_double(s, off) do
    case Regex.run(~r/\A([^;]+);/, safe_part(s, off)) do
      [_, num] -> {:ok, {:float, parse_float(num)}, off + byte_size(num) + 1, nil}
      _ -> {:error, off}
    end
  end

  # `LEN:"bytes";` — digits already consumed; off points at `:"`
  defp read_string(s, off) do
    case Regex.run(~r/\A(\d+):"/, safe_part(s, off)) do
      [_, d] ->
        len = String.to_integer(d)
        bs = byte_size(d)
        end_off = off + bs + 2 + len

        if end_off + 2 <= byte_size(s) and binary_part(s, end_off, 2) == ~s(";) do
          {:ok, {:string, binary_part(s, off + bs + 2, len)}, end_off + 2, nil}
        else
          {:error, off}
        end

      _ ->
        {:error, off}
    end
  end

  defp read_array(s, off, i) do
    case Regex.run(~r/\Aa:(\d+):\{/, safe_part(s, off)) do
      [_, d] ->
        count = String.to_integer(d)

        case read_pairs(s, off + byte_size(d) + 4, count, i, []) do
          {:error, o3} ->
            {:error, o3}

          {pairs, o3, i2} ->
            if String.starts_with?(safe_part(s, o3), "}") do
              {:ok, {:array, PArray.from_pairs(Enum.reverse(pairs))}, o3 + 1, i2}
            else
              {:error, o3}
            end
        end

      _ ->
        {:error, off}
    end
  end

  defp read_pairs(_s, off, 0, i, acc), do: {acc, off, i}

  defp read_pairs(s, off, n, i, acc) do
    with {:ok, k, o2, ia} <- unser(s, off, i),
         {:ok, v, o3, ib} <- unser(s, o2, ia || i) do
      read_pairs(s, o3, n - 1, ib || i, [{raw_key(k), v} | acc])
    else
      _ -> {:error, off}
    end
  end

  defp read_object(s, off, i) do
    case Regex.run(~r/\AO:(\d+):"/, safe_part(s, off)) do
      [_, ld] ->
        len = String.to_integer(ld)
        off2 = off + 2 + byte_size(ld) + 2

        if off2 + len <= byte_size(s) do
          cls = binary_part(s, off2, len)
          off3 = off2 + len + 1

          case Regex.run(~r/\A:(\d+):\{/, safe_part(s, off3)) do
            [_, cd] ->
              count = String.to_integer(cd)
              off4 = off3 + byte_size(cd) + 3

              {obj_ref, i2} = PhpBeam.Eval.make_instance(i, String.downcase(cls))

              {ref, i3, o5} = set_obj_props(s, off4, count, obj_ref, i2, i)

              if String.starts_with?(safe_part(s, o5), "}") do
                {:ok, ref, o5 + 1, i3}
              else
                {:error, o5}
              end

            _ ->
              {:error, off3}
          end
        else
          {:error, off}
        end

      _ ->
        {:error, off}
    end
  end

  defp set_obj_props(_s, off, 0, ref, ia, _i), do: {ref, ia, off}

  defp set_obj_props(s, off, n, ref, ia, i) do
    with {:ok, k, o2, _} <- unser(s, off, ia),
         {:ok, v, o3, _} <- unser(s, o2, ia) do
      name =
        case k do
          {:string, s2} -> s2
          {:int, num} -> Integer.to_string(num)
        end

      obj = Map.get(ia.objects, elem(ref, 1)) || %{class: "stdclass", props: PArray.new()}
      {:ok, props2} = PArray.put(obj.props, {:string, name}, v)
      ia2 = PhpBeam.Eval.put_object(ia, ref, %{obj | props: props2})
      set_obj_props(s, o3, n - 1, ref, ia2, i)
    else
      _ -> {ref, ia, off}
    end
  end

  defp safe_part(s, off) when off >= byte_size(s), do: ""
  defp safe_part(s, off), do: binary_part(s, off, byte_size(s) - off)

  defp parse_float("INF"), do: 1.7976931348623157e308
  defp parse_float("-INF"), do: -1.7976931348623157e308
  defp parse_float("NAN"), do: 0.0

  defp parse_float(num) do
    num |> String.replace("E", "e") |> String.replace("e+", "e") |> String.to_float()
  rescue
    _ -> 0.0
  end

  defp raw_key({:int, n}), do: {:int, n}
  defp raw_key({:string, s}), do: {:string, s}
end
