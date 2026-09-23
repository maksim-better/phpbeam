defmodule PhpBeam.Builtin.RuntimeFns do
  @moduledoc """
  Runtime/introspection builtins: ini settings, error reporting level,
  error-handler/autoloader/shutdown bookkeeping.

  These are state stores on the interpreter for now — handlers/autoloaders
  are registered but not yet invoked (no warning dispatch, no class-not-found
  hook yet).
  """

  alias PhpBeam.{PArray, Value}

  def register(fns) do
    entries = %{
      "ini_get" => &ini_get/2,
      "ini_set" => &ini_set/2,
      "ini_restore" => &ini_restore/2,
      "error_reporting" => &error_reporting/2,
      "set_error_handler" => &set_error_handler/2,
      "restore_error_handler" => &restore_error_handler/2,
      "register_shutdown_function" => &register_shutdown_function/2,
      "spl_autoload_register" => &spl_autoload_register/2,
      "spl_autoload_unregister" => &spl_autoload_unregister/2,
      "spl_autoload_functions" => &spl_autoload_functions/2,
      "set_time_limit" => &set_time_limit/2,
      "zend_version" => &zend_version/2,
      "sys_get_temp_dir" => &sys_get_temp_dir/2,
      "setlocale" => &setlocale/2,
      "get_defined_functions" => &get_defined_functions/2,
      "set_include_path" => &set_include_path/2,
      "get_include_path" => &get_include_path/2,
      "restore_include_path" => &restore_include_path/2,
      "error_get_last" => &error_get_last/2,
      "error_clear_last" => &error_clear_last/2,
      "gc_collect_cycles" => &gc_collect_cycles/2
    }

    Enum.reduce(entries, fns, fn {name, fun}, acc ->
      Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
    end)
  end

  ## ─────────────────────────── ini ───────────────────────────

  defp ini_get(vals, i) do
    case vals do
      [{:string, k} | _] ->
        case Map.fetch(i.ini, k) do
          {:ok, v} -> {:ok, {:string, ini_to_string(v)}, i}
          :error -> {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp ini_set(vals, i) do
    case vals do
      [{:string, k}, v | _] ->
        old = ini_get([{:string, k}], i)
        str = value_to_ini_string(v)
        {:ok, elem(old, 1), %{i | ini: Map.put(i.ini, k, str)}}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp ini_restore(vals, i) do
    case vals do
      [{:string, k} | _] -> {:ok, :null, %{i | ini: Map.delete(i.ini, k)}}
      _ -> {:ok, :null, i}
    end
  end

  defp set_include_path(vals, i) do
    old = ini_get([{:string, "include_path"}], i)

    case vals do
      [v | _] ->
        {:ok, elem(old, 1), %{i | ini: Map.put(i.ini, "include_path", value_to_ini_string(v))}}

      [] ->
        {:ok, {:bool, false}, i}
    end
  end

  defp get_include_path(_vals, i), do: ini_get([{:string, "include_path"}], i)

  defp restore_include_path(_vals, i),
    do: {:ok, :null, %{i | ini: Map.delete(i.ini, "include_path")}}

  defp value_to_ini_string(v) do
    case Value.cast_string(v) do
      {:ok, s} -> s
      _ -> ""
    end
  end

  defp ini_to_string(v) when is_binary(v), do: v
  defp ini_to_string(v) when is_integer(v), do: Integer.to_string(v)

  ## ───────────────────── error reporting ─────────────────────

  defp error_reporting(vals, i) do
    cur = int_ini(i, "error_reporting", 0)

    case vals do
      [] ->
        {:ok, {:int, cur}, i}

      [v | _] ->
        n =
          case Value.to_int(v) do
            {:ok, {:int, n}} -> n
            _ -> cur
          end

        {:ok, {:int, cur}, %{i | ini: Map.put(i.ini, "error_reporting", Integer.to_string(n))}}
    end
  end

  defp set_error_handler(vals, i) do
    case vals do
      [cb | _] ->
        {:ok, i.error_handler || :null, %{i | error_handler: cb}}

      [] ->
        {:ok, :null, i}
    end
  end

  defp restore_error_handler(_vals, i), do: {:ok, {:bool, true}, %{i | error_handler: nil}}

  defp error_get_last(_vals, i), do: {:ok, :null, i}
  defp error_clear_last(_vals, i), do: {:ok, :null, i}

  ## ─────────────── autoload / shutdown bookkeeping ───────────────

  defp spl_autoload_register(vals, i) do
    case vals do
      [cb | _] -> {:ok, {:bool, true}, %{i | autoload_fns: i.autoload_fns ++ [cb]}}
      [] -> {:ok, {:bool, false}, i}
    end
  end

  defp spl_autoload_unregister(vals, i) do
    case vals do
      [cb | _] ->
        if cb in i.autoload_fns do
          {:ok, {:bool, true}, %{i | autoload_fns: List.delete(i.autoload_fns, cb)}}
        else
          {:ok, {:bool, false}, i}
        end

      [] ->
        {:ok, {:bool, false}, i}
    end
  end

  defp spl_autoload_functions(_vals, i) do
    arr = PArray.from_pairs(Enum.map(i.autoload_fns, &{nil, &1}))
    {:ok, {:array, arr}, i}
  end

  defp register_shutdown_function(vals, i) do
    case vals do
      [cb | _] -> {:ok, :null, %{i | shutdown_fns: i.shutdown_fns ++ [cb]}}
      [] -> {:ok, :null, i}
    end
  end

  ## ───────────────────── misc runtime info ─────────────────────

  defp set_time_limit(_vals, i), do: {:ok, {:bool, true}, i}

  defp zend_version(_vals, i), do: {:ok, {:string, "4.4.0"}, i}

  defp sys_get_temp_dir(_vals, i), do: {:ok, {:string, System.tmp_dir!() || "/tmp"}, i}

  defp gc_collect_cycles(_vals, i), do: {:ok, {:int, 0}, i}

  # no locale support: report the requested locale as active (non-empty),
  # matching the common `setlocale(...) === false` guards
  defp setlocale(vals, i) do
    case Enum.drop(vals, 1) do
      [] ->
        {:ok, {:bool, false}, i}

      locales ->
        case Enum.find(locales, fn
               {:string, s} -> s != "" and s != "0"
               _ -> false
             end) do
          {:string, s} -> {:ok, {:string, s}, i}
          _ -> {:ok, {:bool, false}, i}
        end
    end
  end

  defp get_defined_functions(_vals, i) do
    {builtin, user} =
      i.functions
      |> Enum.split_with(fn {_k, v} -> match?(%{fun: _}, v) end)

    arr =
      PArray.from_pairs([
        {{:string, "internal"},
         {:array, PArray.from_pairs(Enum.map(Enum.sort(builtin), &{nil, {:string, elem(&1, 0)}}))}},
        {{:string, "user"},
         {:array, PArray.from_pairs(Enum.map(Enum.sort(user), &{nil, {:string, elem(&1, 0)}}))}}
      ])

    {:ok, {:array, arr}, i}
  end

  defp int_ini(i, key, default) do
    case Map.fetch(i.ini, key) do
      {:ok, v} when is_integer(v) -> v
      {:ok, v} when is_binary(v) -> String.to_integer(v)
      _ -> default
    end
  end
end
