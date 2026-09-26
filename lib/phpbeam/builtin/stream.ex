defmodule PhpBeam.Builtin.StreamFns do
  @moduledoc """
  Resource-based file streams: fopen/fread/fwrite/fseek family backed by
  `interp.resources` (`{:resource, id}` values). Closed resources trigger
  php-style TypeErrors ("supplied resource is not a valid stream resource").
  """

  def register(fns) do
    entries = %{
      "fopen" => &fopen_v/2,
      "stream_isatty" => &stream_isatty/2,
      "stream_set_blocking" => &stream_nop/2,
      "stream_set_write_buffer" => &stream_nop/2,
      "fclose" => &fclose_v/2,
      "fread" => &fread_v/2,
      "fwrite" => &fwrite_v/2,
      "fputs" => &fwrite_v/2,
      "feof" => &feof_v/2,
      "fseek" => &fseek_v/2,
      "ftell" => &ftell_v/2,
      "rewind" => &rewind_v/2,
      "fflush" => &fflush_v/2,
      "ftruncate" => &ftruncate_v/2,
      "fgetc" => &fgetc_v/2,
      "fgets" => &fgets_v/2,
      "fpassthru" => &fpassthru_v/2,
      "stream_get_contents" => &stream_get_contents_v/2,
      "flock" => &flock_v/2,
      "tmpfile" => &tmpfile_v/2,
      "is_resource" => &is_resource_v/2
    }

    Enum.reduce(entries, fns, fn {name, fun}, acc ->
      Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
    end)
  end

  defp val(vals, n \\ 0), do: Enum.at(vals, n)

  defp s(vals, n \\ 0) do
    case val(vals, n) do
      {:string, x} -> x
      v -> PhpBeam.Value.cast_string_unsafe(v)
    end
  end

  defp int(vals, n, d) do
    case val(vals, n) do
      {:int, v} -> v
      {:bool, b} -> if b, do: 1, else: 0
      _ -> d
    end
  end

  # php TypeError for invalid/closed stream arguments; renders the given
  # value php-style ("false given") and becomes the innermost trace frame
  defp stream_type_error(fn_name, vals, i) do
    given =
      case val(vals) do
        {:bool, false} -> "false"
        {:bool, true} -> "true"
        :null -> "null"
        {:int, _} -> "int"
        {:float, _} -> "float"
        {:string, _} -> "string"
        {:array, _} -> "array"
        _ -> "unknown"
      end

    i2 = PhpBeam.Interp.push_frame(i, fn_name, Enum.take(vals, 2))

    # materialize eagerly — catch blocks and get_class() need a real object
    {obj_ref, i3} =
      PhpBeam.Eval.materialize_native(
        {:native_error, "TypeError",
         "#{fn_name}(): Argument #1 ($stream) must be of type resource, #{given} given"},
        i2
      )

    {:unwind, {:php_throw, obj_ref}, i3}
  end

  defp closed_type_error(fn_name, vals, i) do
    res_arg = resource_arg(vals)

    i2 = PhpBeam.Interp.push_frame(i, fn_name, [res_arg])

    {obj_ref, i3} =
      PhpBeam.Eval.materialize_native(
        {:native_error, "TypeError",
         "#{fn_name}(): supplied resource is not a valid stream resource"},
        i2
      )

    {:unwind, {:php_throw, obj_ref}, i3}
  end

  defp resource_arg(vals) do
    case val(vals) do
      {:resource, id} -> {:resource, id}
      v -> v
    end
  end

  # ops that implement real std-stream behavior; the rest stub out
  # (php: fseek on a pipe → -1, ftell/rewind → false)
  @std_aware ~w(fwrite fread fclose fflush feof)

  defp with_stream(fn_name, vals, i, f) do
    case val(vals) do
      {:resource, _} = r ->
        case PhpBeam.Interp.get_resource(i, r) do
          %{closed: false} = res ->
            if Map.has_key?(res, :std) and fn_name not in @std_aware do
              std_stub(fn_name, i)
            else
              f.(r, res)
            end

          _ ->
            closed_type_error(fn_name, vals, i)
        end

      _ ->
        stream_type_error(fn_name, vals, i)
    end
  end

  defp std_stub("fseek", i), do: {:ok, {:int, -1}, i}
  defp std_stub("ftell", i), do: {:ok, {:bool, false}, i}
  defp std_stub(_, i), do: {:ok, {:bool, false}, i}

  ## ───────────────────────── open/close ─────────────────────────

  @mode_opts %{
    "r" => [:read, :binary],
    "r+" => [:read, :write, :binary],
    "w" => [:write, :binary],
    "w+" => [:read, :write, :binary],
    "a" => [:append, :binary],
    "a+" => [:read, :append, :binary],
    "x" => [:exclusive, :write, :binary],
    "x+" => [:exclusive, :read, :write, :binary],
    "c" => [:write, :binary],
    "c+" => [:read, :write, :binary]
  }

  @truncating ~w(w w+)
  @appending ~w(a a+)

  # php: CLI std streams are TTYs when interactive; artisan only checks
  defp stream_isatty(vals, i) do
    case vals do
      [{:resource, id} | _] when id in [0, 1, 2] -> {:ok, {:bool, false}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp stream_nop(_vals, i), do: {:ok, {:int, 0}, i}

  defp fopen_v(vals, i) do
    path = s(vals)
    mode = s(vals, 1)

    # php:// std streams map onto the pre-seeded resource registry slots
    case path do
      "php://stdout" -> {:ok, {:resource, 1}, i}
      "php://stdin" -> {:ok, {:resource, 0}, i}
      "php://stderr" -> {:ok, {:resource, 2}, i}
      _ -> fopen_file(path, mode, vals, i)
    end
  end

  defp fopen_file(path, mode, vals, i) do
    case Map.fetch(@mode_opts, mode) do
      :error ->
        i2 = PhpBeam.Interp.warn(i, "fopen(#{path}): mode not supported")
        {:ok, {:bool, false}, i2}

      {:ok, opts} ->
        opts =
          if mode in @truncating, do: opts ++ [:truncate], else: opts

        if mode in @truncating do
          File.write(path, "", [:write])
        end

        case :file.open(String.to_charlist(path), opts) do
          {:ok, dev} ->
            PhpBeam.Interp.open_resource(i, %{
              device: dev,
              path: path,
              mode: mode,
              closed: false,
              eof: false
            })
            |> then(fn {res, i2} -> {:ok, res, i2} end)

          {:error, _} ->
            reason =
              if mode in ~w(x x+) do
                "File exists"
              else
                "No such file or directory"
              end

            i2 = PhpBeam.Interp.warn(i, "fopen(#{path}): Failed to open stream: #{reason}")

            {:ok, {:bool, false}, i2}
        end
    end
  end

  defp fclose_v(vals, i) do
    with_stream("fclose", vals, i, fn r, res ->
      unless Map.has_key?(res, :std), do: :file.close(res.device)
      i2 = PhpBeam.Interp.put_resource(i, r, %{res | closed: true})
      {:ok, {:bool, true}, i2}
    end)
  end

  defp tmpfile_v(_vals, i) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "phpbeam#{:erlang.unique_integer([:positive])}")

    case :file.open(String.to_charlist(path), [:read, :write, :binary]) do
      {:ok, dev} ->
        {res, i2} =
          PhpBeam.Interp.open_resource(i, %{
            device: dev,
            path: path,
            mode: "w+",
            closed: false,
            eof: false
          })

        {:ok, res, i2}

      {:error, _} ->
        {:ok, {:bool, false}, i}
    end
  end

  ## ───────────────────────── read ─────────────────────────

  defp fread_v(vals, i) do
    len = int(vals, 1, 8192)

    with_stream("fread", vals, i, fn r, res ->
      case res do
        # non-interactive stdin reads EOF immediately
        %{std: _} ->
          {:ok, {:string, ""}, i}

        _ ->
          case :file.read(res.device, len) do
            {:ok, data} ->
              eof? = byte_size(data) < len
              i2 = PhpBeam.Interp.put_resource(i, r, %{res | eof: eof?})
              {:ok, {:string, data}, i2}

            :eof ->
              i2 = PhpBeam.Interp.put_resource(i, r, %{res | eof: true})
              {:ok, {:string, ""}, i2}
          end
      end
    end)
  end

  defp fgetc_v(vals, i) do
    with_stream("fgetc", vals, i, fn r, res ->
      case :file.read(res.device, 1) do
        {:ok, data} ->
          {:ok, {:string, data}, i}

        :eof ->
          i2 = PhpBeam.Interp.put_resource(i, r, %{res | eof: true})
          {:ok, {:bool, false}, i2}
      end
    end)
  end

  defp fgets_v(vals, i) do
    max =
      case int(vals, 1, 8192) do
        n when n > 0 -> n
        _ -> 8192
      end

    with_stream("fgets", vals, i, fn r, res ->
      case :file.read_line(res.device) do
        {:ok, line} ->
          data =
            if byte_size(line) > max,
              do: binary_part(line, 0, max),
              else: line

          {:ok, {:string, data}, i}

        :eof ->
          i2 = PhpBeam.Interp.put_resource(i, r, %{res | eof: true})
          {:ok, {:bool, false}, i2}
      end
    end)
  end

  defp fpassthru_v(vals, i) do
    with_stream("fpassthru", vals, i, fn r, res ->
      {data, i2} = read_all(i, r, res, "")
      i3 = PhpBeam.Interp.write(i2, data)
      {:ok, {:int, byte_size(data)}, i3}
    end)
  end

  defp stream_get_contents_v(vals, i) do
    with_stream("stream_get_contents", vals, i, fn r, res ->
      {data, i2} = read_all(i, r, res, "")
      {:ok, {:string, data}, i2}
    end)
  end

  defp read_all(i, r, res, acc) do
    case :file.read(res.device, 65_536) do
      {:ok, data} ->
        i2 = PhpBeam.Interp.put_resource(i, r, %{res | eof: false})
        read_all(i2, r, res, acc <> data)

      :eof ->
        i2 = PhpBeam.Interp.put_resource(i, r, %{res | eof: true})
        {acc, i2}
    end
  end

  ## ───────────────────────── write ─────────────────────────

  defp fwrite_v(vals, i) do
    data = s(vals, 1)

    data =
      case val(vals, 2) do
        {:int, n} when n >= 0 and n < byte_size(data) -> binary_part(data, 0, n)
        _ -> data
      end

    with_stream("fwrite", vals, i, fn _r, res ->
      case res do
        # php-cli: STDOUT/STDERR are live process streams. We model STDOUT as
        # the program output buffer; STDERR bytes vanish (the differential
        # convention drops stderr on both sides)
        %{std: :stdout} ->
          {:ok, {:int, byte_size(data)}, PhpBeam.Interp.write(i, data)}

        # real stderr: immediate, unbuffered — the differential convention
        # drops stderr on both sides, so bytes written here never surface in
        # comparisons; it also makes engine debugging possible on hangs
        %{std: :stderr} ->
          IO.write(:standard_error, data)
          {:ok, {:int, byte_size(data)}, i}

        %{std: :stdin} ->
          {:ok, {:int, 0}, i}

        _ ->
          case :file.write(res.device, data) do
            :ok -> {:ok, {:int, byte_size(data)}, i}
            {:error, _} -> {:ok, {:int, 0}, i}
          end
      end
    end)
  end

  ## ───────────────────────── position ─────────────────────────

  defp feof_v(vals, i) do
    with_stream("feof", vals, i, fn _r, res ->
      {:ok, {:bool, res.eof}, i}
    end)
  end

  defp fseek_v(vals, i) do
    offset = int(vals, 1, 0)
    whence = int(vals, 2, 0)

    with_stream("fseek", vals, i, fn r, res ->
      pos =
        case whence do
          1 -> {:cur, offset}
          2 -> {:eof, offset}
          _ -> offset
        end

      case :file.position(res.device, pos) do
        {:ok, _} ->
          i2 = PhpBeam.Interp.put_resource(i, r, %{res | eof: false})
          {:ok, {:int, 0}, i2}

        {:error, _} ->
          {:ok, {:int, -1}, i}
      end
    end)
  end

  defp ftell_v(vals, i) do
    with_stream("ftell", vals, i, fn _r, res ->
      case :file.position(res.device, :cur) do
        {:ok, pos} -> {:ok, {:int, pos}, i}
        {:error, _} -> {:ok, {:bool, false}, i}
      end
    end)
  end

  defp rewind_v(vals, i) do
    with_stream("rewind", vals, i, fn r, res ->
      :file.position(res.device, 0)
      i2 = PhpBeam.Interp.put_resource(i, r, %{res | eof: false})
      {:ok, {:bool, true}, i2}
    end)
  end

  defp fflush_v(vals, i) do
    with_stream("fflush", vals, i, fn _r, res ->
      unless Map.has_key?(res, :std), do: :file.sync(res.device)
      {:ok, {:bool, true}, i}
    end)
  end

  defp ftruncate_v(vals, i) do
    size = int(vals, 1, 0)

    with_stream("ftruncate", vals, i, fn _r, res ->
      # this OTP lacks :file.truncate/2 — seek to size then truncate via write of empty at eof
      case :file.position(res.device, size) do
        {:ok, _} ->
          case :file.write(res.device, "") do
            :ok -> {:ok, {:bool, true}, i}
            {:error, _} -> {:ok, {:bool, false}, i}
          end

        {:error, _} ->
          {:ok, {:bool, false}, i}
      end
    end)
  end

  defp flock_v(_vals, i), do: {:ok, {:bool, true}, i}

  defp is_resource_v(vals, i), do: {:ok, {:bool, match?({:resource, _}, val(vals))}, i}
end
