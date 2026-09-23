defmodule PhpBeam.Builtin.VarFns do
  @moduledoc "Type/variable introspection functions."

  alias PhpBeam.Value

  def register(fns) do
    entries = %{
      "gettype" => &gettype/2,
      "intval" => &intval/2,
      "floatval" => &floatval/2,
      "doubleval" => &floatval/2,
      "strval" => &strval/2,
      "boolval" => &boolval/2,
      "is_int" => is_type(:int),
      "is_integer" => is_type(:int),
      "is_long" => is_type(:int),
      "is_float" => is_type(:float),
      "is_double" => is_type(:float),
      "is_string" => is_type(:string),
      "is_bool" => is_type(:bool),
      "is_null" => is_type(:null),
      "is_array" => is_type(:array),
      "is_object" => is_type(:object),
      "is_numeric" => &is_numeric/2,
      "is_scalar" => &is_scalar/2,
      "is_iterable" => &is_iterable/2,
      "is_countable" => &is_countable/2,
      "class_exists" => &false_v/2,
      "interface_exists" => &false_v/2,
      "method_exists" => &false_v/2,
      "property_exists" => &false_v/2,
      "function_exists" => &function_exists/2,
      "get_class" => &get_class/2,
      "get_object_vars" => &get_object_vars/2,
      "get_class_methods" => &get_class_methods/2,
      "spl_object_id" => &spl_object_id/2
    }

    Enum.reduce(entries, fns, fn {name, fun}, acc ->
      Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
    end)
  end

  defp first_val(vals), do: hd(vals ++ [:null])

  defp false_v(_vals, i), do: {:ok, {:bool, false}, i}

  defp gettype(vals, i), do: {:ok, {:string, Value.gettype(first_val(vals))}, i}

  defp intval(vals, i) do
    base =
      case vals do
        [_, {:int, b} | _] -> b
        _ -> 10
      end

    v = first_val(vals)

    out =
      case v do
        {:string, s} when base != 10 ->
          case Integer.parse(s, base) do
            {n, _} -> {:int, n}
            :error -> {:int, 0}
          end

        _ ->
          Value.to_int(v) |> elem(1)
      end

    {:ok, out, i}
  end

  defp floatval(vals, i), do: {:ok, Value.to_float(first_val(vals)) |> elem(1), i}

  defp strval(vals, i) do
    case Value.cast_string(first_val(vals)) do
      {:ok, s} -> {:ok, {:string, s}, i}
      {:warn_array, _} -> {:ok, {:string, "Array"}, i}
    end
  end

  defp boolval(vals, i), do: {:ok, {:bool, Value.truthy?(first_val(vals))}, i}

  defp is_type(type) do
    fn vals, i -> {:ok, {:bool, Value.type(first_val(vals)) == type}, i} end
  end

  defp is_numeric(vals, i) do
    v = first_val(vals)

    res =
      case v do
        {:int, _} -> true
        {:float, _} -> true
        {:string, s} -> Value.numeric_string?(s)
        _ -> false
      end

    {:ok, {:bool, res}, i}
  end

  defp is_scalar(vals, i) do
    case Value.type(first_val(vals)) do
      t when t in [:int, :float, :string, :bool] -> {:ok, {:bool, true}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp is_iterable(vals, i) do
    case Value.type(first_val(vals)) do
      t when t in [:array, :object] -> {:ok, {:bool, true}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp is_countable(vals, i) do
    case Value.type(first_val(vals)) do
      t when t in [:array, :object] -> {:ok, {:bool, true}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp function_exists([{:string, name} | _], i) do
    {:ok, {:bool, Map.has_key?(i.functions, String.downcase(name))}, i}
  end

  defp function_exists(_, i), do: {:ok, {:bool, false}, i}

  defp get_class(vals, i) do
    case vals do
      [{:object, %{class: cls}} | _] -> {:ok, {:string, cls}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp get_object_vars(vals, i) do
    case vals do
      [{:object, %{props: props}} | _] ->
        pairs =
          Enum.map(props, fn {k, v} -> {{:string, k}, v} end)

        {:ok, {:array, PhpBeam.PArray.from_pairs(pairs)}, i}

      _ ->
        {:ok, {:array, PhpBeam.PArray.new()}, i}
    end
  end

  defp get_class_methods(vals, i) do
    case vals do
      [{:object, %{class: cls}} | _] ->
        methods =
          cls
          |> then(fn _ -> [] end)

        {:ok, {:array, PhpBeam.PArray.new()}, i}

      _ ->
        {:ok, {:array, PhpBeam.PArray.new()}, i}
    end
  end

  defp spl_object_id(vals, i) do
    case vals do
      [{:object, %{__ref__: r}} | _] -> {:ok, {:int, r}, i}
      _ -> {:ok, {:int, 0}, i}
    end
  end
end
