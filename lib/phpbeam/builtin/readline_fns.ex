defmodule PhpBeam.Builtin.ReadlineFns do
  @moduledoc """
  ext/readline (libedit build — readline_list_history() does NOT exist in
  the local php 8.4 and is deliberately absent here so function_exists
  stays differential-identical). Non-interactive semantics: readline()
  returns false at EOF (phpx's stdin is EOF in one-shot runs); history is
  in-memory with real read/write history file I/O; callback handlers
  install/remove but never fire.
  """

  alias PhpBeam.Eval

  def register(fns) do
    entries = %{
      "readline" => &readline/2,
      "readline_add_history" => &readline_add_history/2,
      "readline_read_history" => &readline_read_history/2,
      "readline_write_history" => &readline_write_history/2,
      "readline_clear_history" => &readline_clear_history/2,
      "readline_completion_function" => &readline_completion_function/2,
      "readline_info" => &readline_info/2,
      "readline_callback_handler_install" => &readline_cb_install/2,
      "readline_callback_read_char" => &readline_cb_read_char/2,
      "readline_callback_handler_remove" => &readline_cb_remove/2,
      "readline_redisplay" => &readline_redisplay/2,
      "readline_on_new_line" => &readline_on_new_line/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, wrapped)
  end

  defp rl(i), do: i.readline || %{history: [], completion: nil, handler: false}

  defp put_rl(i, s), do: %{i | readline: s}

  defp readline([prompt | _], i) do
    _prompt = PhpBeam.Eval.php_to_string(prompt)
    read_line(i)
  end

  defp readline(_, i), do: read_line(i)

  defp read_line(_i) do
    case :io.get_line("") do
      :eof -> {:ok, {:bool, false}, nil}
      line -> {:ok, {:string, String.replace_suffix(line, "\n", "")}, nil}
    end
  rescue
    _ -> {:ok, {:bool, false}, nil}
  end

  defp readline_add_history([v | _], i) do
    line = PhpBeam.Eval.php_to_string(v)
    s = rl(i)
    {:ok, {:bool, true}, put_rl(i, %{s | history: s.history ++ [line]})}
  end

  defp readline_add_history(_, i), do: {:ok, {:bool, false}, i}

  defp readline_read_history(vals, i) do
    case vals do
      [v | _] ->
        path = PhpBeam.Eval.php_to_string(v)

        case File.read(path) do
          {:ok, data} ->
            lines =
              data
              |> String.split("\n", trim: true)

            {:ok, {:bool, true}, put_rl(i, %{rl(i) | history: lines})}

          _ ->
            {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, true}, put_rl(i, %{rl(i) | history: []})}
    end
  end

  defp readline_write_history(vals, i) do
    s = rl(i)

    path =
      case vals do
        [v | _] -> PhpBeam.Eval.php_to_string(v)
        _ -> nil
      end

    if is_binary(path) do
      case File.write(path, Enum.map_join(s.history, "", &(&1 <> "\n"))) do
        :ok -> {:ok, {:bool, true}, i}
        _ -> {:ok, {:bool, false}, i}
      end
    else
      {:ok, {:bool, true}, i}
    end
  end

  defp readline_clear_history(_vals, i) do
    {:ok, {:bool, true}, put_rl(i, %{rl(i) | history: []})}
  end

  defp readline_completion_function([cb | _], i) do
    case cb do
      :null ->
        i2 = PhpBeam.Interp.push_frame(i, "readline_completion_function", [cb])

        {obj, i3} =
          Eval.materialize_native(
            {:native_error, "TypeError",
             "readline_completion_function(): Argument #1 ($callback) must be a valid callback, no array or string given"},
            i2
          )

        {:unwind, {:php_throw, obj}, i3}

      _ ->
        {:ok, {:bool, true}, put_rl(i, %{rl(i) | completion: cb})}
    end
  end

  defp readline_completion_function(_, i), do: {:ok, {:bool, false}, i}

  defp readline_info(vals, i) do
    s = rl(i)

    named = %{
      "line_buffer" => {:string, ""},
      "point" => {:int, 0},
      "end" => {:int, 0},
      "library_version" => {:string, "EditLine wrapper"},
      "readline_name" => {:string, ""},
      "attempted_completion_over" => {:int, 0}
    }

    case vals do
      [v | _] ->
        name = PhpBeam.Eval.php_to_string(v)

        case Map.fetch(named, name) do
          {:ok, val} -> {:ok, val, i}
          :error -> {:ok, {:bool, false}, i}
        end

      _ ->
        # php reads live state; ours is all-zero with libedit's version tag
        arr = PhpBeam.PArray.from_pairs(Enum.to_list(named))

        {:ok, {:array, arr}, i}
    end
  end

  defp readline_cb_install([_prompt, cb | _], i) do
    {:ok, {:bool, true}, put_rl(i, %{rl(i) | handler: cb})}
  end

  defp readline_cb_install(_, i), do: {:ok, {:bool, false}, i}

  defp readline_cb_read_char(_vals, i), do: {:ok, :null, i}

  defp readline_cb_remove(_vals, i) do
    s = rl(i)

    if s.handler do
      {:ok, {:bool, true}, put_rl(i, %{s | handler: false})}
    else
      {:ok, {:bool, false}, i}
    end
  end

  defp readline_redisplay(_vals, i), do: {:ok, :null, i}
  defp readline_on_new_line(_vals, i), do: {:ok, :null, i}
end
