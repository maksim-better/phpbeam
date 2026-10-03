defmodule PhpBeam.Builtin.StreamFns do
  @moduledoc """
  Resource-based file streams: fopen/fread/fwrite/fseek family backed by
  `interp.resources` (`{:resource, id}` values). Closed resources trigger
  php-style TypeErrors ("supplied resource is not a valid stream resource").
  """

  alias PhpBeam.{Eval.Error, PArray}

  def register(fns) do
    entries = %{
      "fopen" => &fopen_v/2,
      "fstat" => &fstat_v/2,
      "stream_context_create" => &stream_context_create/2,
      "stream_context_set_option" => &stream_context_set_option/2,
      "stream_context_get_options" => &stream_context_get_options/2,
      "stream_context_get_default" => &stream_context_get_default/2,
      "stream_context_set_default" => &stream_context_set_default/2,
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
  @read_only_modes ~w(r)

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

    case PhpBeam.StreamWrapper.parse(path) do
      # std streams map onto the pre-seeded resource registry slots
      {:std, which} ->
        {:ok, {:resource, %{stdin: 0, stdout: 1, stderr: 2}[which]}, i}

      {:memory, _max} ->
        open_memory(path, mode, "", i)

      {:data, payload} ->
        open_memory(path, "r", payload, i)

      {:input} ->
        open_memory(path, "r", input_body(i), i)

      {:output} ->
        open_wrapper(path, :output, i)

      {:filter, rchain, wchain, inner_uri} ->
        open_filter(path, mode, rchain, wchain, inner_uri, i)

      {:file, fpath} ->
        fopen_file(fpath, mode, vals, i)

      {:unsupported, scheme} ->
        wrapper_disabled("fopen", path, scheme, i)
    end
  end

  # CLI: php://input is the request body — empty outside HTTP; the HTTP
  # driver materializes it into globals later
  defp input_body(i) do
    Map.get(i.globals, "\0input_body")
    |> case do
      {:string, b} -> b
      _ -> ""
    end
  end

  defp open_memory(path, mode, initial, i) do
    {data, pos} =
      case mode do
        m when m in @truncating -> {initial, 0}
        m when m in @appending -> {initial, byte_size(initial)}
        _ -> {initial, 0}
      end

    PhpBeam.Interp.open_resource(i, %{
      mem: %{data: data, pos: pos},
      path: path,
      mode: mode,
      closed: false,
      eof: false
    })
    |> then(fn {res, i2} -> {:ok, res, i2} end)
  end

  defp open_wrapper(path, kind, i) do
    PhpBeam.Interp.open_resource(i, %{
      wr: kind,
      path: path,
      mode: "w",
      closed: false,
      eof: false
    })
    |> then(fn {res, i2} -> {:ok, res, i2} end)
  end

  # php://filter opens the inner resource and layers the chains on top
  defp open_filter(path, mode, rchain, wchain, inner_uri, i) do
    case fopen_v([{:string, inner_uri}, {:string, mode}], i) do
      {:ok, {:resource, inner_id}, i2} ->
        PhpBeam.Interp.open_resource(i2, %{
          filt: %{read: rchain, write: wchain, inner: inner_id},
          path: path,
          mode: mode,
          closed: false,
          eof: false
        })
        |> then(fn {res, i3} -> {:ok, res, i3} end)

      other ->
        other
    end
  end

  defp wrapper_disabled(fname, path, scheme, i) do
    msg =
      fname <>
        "(): " <>
        scheme <>
        ":// wrapper is disabled in the server configuration by allow_url_fopen=0"

    case Error.warn(Error.stub_env(), i, msg) do
      {:cont, _, i2} -> {:ok, {:bool, false}, i2}
      {:unwind, u, _, i2} -> {:unwind, u, i2}
    end
  end

  defp fopen_file(path, mode, vals, i) do
    case Map.fetch(@mode_opts, mode) do
      :error ->
        case Error.warn(Error.stub_env(), i, "fopen(#{path}): mode not supported") do
          {:cont, _, i2} -> {:ok, {:bool, false}, i2}
          {:unwind, u, _, i2} -> {:unwind, u, i2}
        end

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

            case Error.warn(
                   Error.stub_env(),
                   i,
                   "fopen(#{path}): Failed to open stream: #{reason}"
                 ) do
              {:cont, _, i2} -> {:ok, {:bool, false}, i2}
              {:unwind, u, _, i2} -> {:unwind, u, i2}
            end
        end
    end
  end

  defp fclose_v(vals, i) do
    with_stream("fclose", vals, i, fn r, res ->
      i2 = close_resource(i, r, res)
      {:ok, {:bool, true}, i2}
    end)
  end

  defp close_resource(i, r, %{filt: f} = res) do
    inner = PhpBeam.Interp.get_resource(i, f.inner)
    i2 = close_resource(i, f.inner, inner)
    PhpBeam.Interp.put_resource(i2, r, %{res | closed: true})
  end

  defp close_resource(i, r, %{std: _} = res),
    do: PhpBeam.Interp.put_resource(i, r, %{res | closed: true})

  defp close_resource(i, r, res) do
    if Map.has_key?(res, :device), do: :file.close(res.device)
    PhpBeam.Interp.put_resource(i, r, %{res | closed: true})
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
      {data, i2} = unified_read(i, r, res, len)
      {:ok, {:string, data}, i2}
    end)
  end

  # unified resource reads: file device | memory/data/input | filter layer.
  # Returns {data, interp}; EOF yields "" (and sets eof on plain resources)
  defp unified_read(i, _r, %{std: _}, _len), do: {"", i}

  # proc_open pipes (fd1 = port stdout, fd2 = redirected temp file)
  defp unified_read(i, r, %{proc_pipe: _} = res, len),
    do: PhpBeam.Builtin.ProcFns.pipe_read(i, r, res, len)

  defp unified_read(i, r, %{filt: f}, len) do
    inner = PhpBeam.Interp.get_resource(i, f.inner)

    {data, i2} =
      unified_read(i, f.inner, inner, len)

    {PhpBeam.StreamWrapper.apply_chain(data, f.read), i2}
  end

  defp unified_read(i, r, %{mem: m} = res, len) do
    size = byte_size(m.data)
    start = min(m.pos, size)
    take = max(0, min(len, size - start))
    data = binary_part(m.data, start, take)
    i2 = PhpBeam.Interp.put_resource(i, r, %{res | mem: %{m | pos: start + take}, eof: take == 0})
    {data, i2}
  end

  defp unified_read(i, r, %{device: _} = res, len) do
    case :file.read(res.device, len) do
      {:ok, data} ->
        eof? = byte_size(data) < len
        i2 = PhpBeam.Interp.put_resource(i, r, %{res | eof: eof?})
        {data, i2}

      :eof ->
        i2 = PhpBeam.Interp.put_resource(i, r, %{res | eof: true})
        {"", i2}
    end
  end

  defp fgetc_v(vals, i) do
    with_stream("fgetc", vals, i, fn r, res ->
      case unified_read(i, r, res, 1) do
        {"", i2} -> {:ok, {:bool, false}, i2}
        {data, i2} -> {:ok, {:string, data}, i2}
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
      {line, i2} = unified_read_line(i, r, res, max)

      case line do
        nil -> {:ok, {:bool, false}, i2}
        l -> {:ok, {:string, l}, i2}
      end
    end)
  end

  # line read across resource kinds: scan bytes until \n (kept, php keeps
  # the terminator) or EOF
  defp unified_read_line(i, r, %{filt: f}, max) do
    inner = PhpBeam.Interp.get_resource(i, f.inner)

    {line, i2} = unified_read_line(i, f.inner, inner, max)

    case line do
      nil -> {nil, i2}
      l -> {PhpBeam.StreamWrapper.apply_chain(l, f.read), i2}
    end
  end

  defp unified_read_line(i, r, %{std: _}, _max), do: {nil, i}

  defp unified_read_line(i, r, %{mem: m} = res, max) do
    size = byte_size(m.data)
    start = min(m.pos, size)

    case find_nl(m.data, start) do
      nil ->
        {rest, i2} =
          if start < size do
            {binary_part(m.data, start, size - start),
             PhpBeam.Interp.put_resource(i, r, %{res | mem: %{m | pos: size}, eof: true})}
          else
            {nil, i}
          end

        clip_line(rest, max, i2)

      nl_pos ->
        len = nl_pos - start + 1
        len2 = if max > 0 and len > max, do: max, else: len
        line = binary_part(m.data, start, len2)
        i2 = PhpBeam.Interp.put_resource(i, r, %{res | mem: %{m | pos: start + len}})
        {line, i2}
    end
  end

  defp unified_read_line(i, r, %{device: _} = res, max) do
    case :file.read_line(res.device) do
      {:ok, line} -> clip_line(line, max, i)
      :eof -> {nil, PhpBeam.Interp.put_resource(i, r, %{res | eof: true})}
    end
  end

  defp clip_line(nil, _max, i), do: {nil, i}

  defp clip_line(line, max, i) do
    if max > 0 and byte_size(line) > max,
      do: {binary_part(line, 0, max), i},
      else: {line, i}
  end

  defp find_nl(data, from) do
    case :binary.match(data, "\n", scope: {from, byte_size(data) - from}) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
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
    case unified_read(i, r, res, 65_536) do
      {"", i2} ->
        {acc, i2}

      {data, i2} ->
        res2 = PhpBeam.Interp.get_resource(i2, r)
        read_all(i2, r, res2, acc <> data)
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

    with_stream("fwrite", vals, i, fn r, res ->
      unified_write(i, r, res, data)
    end)
  end

  # unified resource writes; returns the byte count php would report
  defp unified_write(_i, _r, %{std: :stdout} = _res, data),
    do: {:ok, {:int, byte_size(data)}, PhpBeam.Interp.write(_i, data)}

  defp unified_write(i, _r, %{std: :stderr} = _res, data) do
    IO.write(:standard_error, data)
    {:ok, {:int, byte_size(data)}, i}
  end

  defp unified_write(i, _r, %{std: :stdin}, _data), do: {:ok, {:int, 0}, i}

  # proc_open fd0 pipe: fwrite feeds the child's stdin
  defp unified_write(i, r, %{proc_pipe: _} = res, data),
    do: PhpBeam.Builtin.ProcFns.pipe_write(i, res, data)

  # php://output rides the output-buffering machinery (probed: interleaves
  # with ob content); php://stdout BYPASSES ob — write_direct appends to the
  # real out list so ordering matches php
  defp unified_write(i, _r, %{wr: :output}, data),
    do: {:ok, {:int, byte_size(data)}, PhpBeam.Interp.write(i, data)}

  defp unified_write(i, r, %{filt: f}, data) do
    inner = PhpBeam.Interp.get_resource(i, f.inner)

    unified_write(i, f.inner, inner, PhpBeam.StreamWrapper.apply_chain(data, f.write))
  end

  defp unified_write(i, r, %{mem: m} = res, data) do
    if res.mode in @read_only_modes do
      {:ok, {:int, 0}, i}
    else
      pos =
        if res.mode in @appending,
          do: byte_size(m.data),
          else: m.pos

      data2 =
        binary_part(m.data, 0, pos) <>
          data <>
          binary_part(m.data, min(pos, byte_size(m.data)), max(0, byte_size(m.data) - pos))

      i2 =
        PhpBeam.Interp.put_resource(i, r, %{
          res
          | mem: %{m | data: data2, pos: pos + byte_size(data)}
        })

      {:ok, {:int, byte_size(data)}, i2}
    end
  end

  defp unified_write(i, _r, %{device: _} = res, data) do
    case :file.write(res.device, data) do
      :ok -> {:ok, {:int, byte_size(data)}, i}
      {:error, _} -> {:ok, {:int, 0}, i}
    end
  end

  ## ───────────────────────── position ─────────────────────────

  defp feof_v(vals, i) do
    with_stream("feof", vals, i, fn _r, res ->
      {:ok, {:bool, unified_eof?(i, res)}, i}
    end)
  end

  defp unified_eof?(_i, %{mem: m}), do: m.pos >= byte_size(m.data)
  defp unified_eof?(_i, %{wr: _}), do: true

  defp unified_eof?(i, %{filt: f}) do
    inner = PhpBeam.Interp.get_resource(i, f.inner)
    unified_eof?(i, inner)
  end

  defp unified_eof?(_i, %{std: _}), do: true
  defp unified_eof?(_i, res), do: res.eof

  defp fseek_v(vals, i) do
    offset = int(vals, 1, 0)
    whence = int(vals, 2, 0)

    with_stream("fseek", vals, i, fn r, res ->
      case unified_seek(i, r, res, offset, whence) do
        {:ok, i2} -> {:ok, {:int, 0}, i2}
        :error -> {:ok, {:int, -1}, i}
      end
    end)
  end

  defp unified_seek(i, r, %{filt: f}, offset, whence) do
    inner = PhpBeam.Interp.get_resource(i, f.inner)
    unified_seek(i, f.inner, inner, offset, whence)
  end

  defp unified_seek(i, r, %{mem: m} = res, offset, whence) do
    size = byte_size(m.data)

    base =
      case whence do
        1 -> m.pos
        2 -> size
        _ -> 0
      end

    pos = base + offset

    # php allows seeking past EOF (reads yield ""); only negative fails
    if pos < 0 do
      :error
    else
      i2 = PhpBeam.Interp.put_resource(i, r, %{res | mem: %{m | pos: pos}, eof: false})
      {:ok, i2}
    end
  end

  defp unified_seek(_i, _r, %{std: _}, _o, _w), do: :error

  defp unified_seek(i, r, %{device: _} = res, offset, whence) do
    pos =
      case whence do
        1 -> {:cur, offset}
        2 -> {:eof, offset}
        _ -> offset
      end

    case :file.position(res.device, pos) do
      {:ok, _} ->
        i2 = PhpBeam.Interp.put_resource(i, r, %{res | eof: false})
        {:ok, i2}

      {:error, _} ->
        :error
    end
  end

  defp ftell_v(vals, i) do
    with_stream("ftell", vals, i, fn _r, res ->
      case unified_tell(i, res) do
        {:ok, pos} -> {:ok, {:int, pos}, i}
        :error -> {:ok, {:bool, false}, i}
      end
    end)
  end

  defp unified_tell(_i, %{mem: m}), do: {:ok, m.pos}
  defp unified_tell(_i, %{wr: _}), do: :error
  defp unified_tell(_i, %{std: _}), do: :error

  defp unified_tell(i, %{filt: f}) do
    inner = PhpBeam.Interp.get_resource(i, f.inner)
    unified_tell(i, inner)
  end

  defp unified_tell(_i, %{device: _} = res) do
    case :file.position(res.device, :cur) do
      {:ok, pos} -> {:ok, pos}
      {:error, _} -> :error
    end
  end

  defp rewind_v(vals, i) do
    with_stream("rewind", vals, i, fn r, res ->
      case unified_seek(i, r, res, 0, 0) do
        {:ok, i2} -> {:ok, {:bool, true}, i2}
        :error -> {:ok, {:bool, false}, i}
      end
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

  # php fstat: stat-style array with numeric + named keys (probed on
  # php://memory: mode 33206, nlink 1, rdev/blksize/blocks -1, size=bytes)
  defp fstat_v(vals, i) do
    with_stream("fstat", vals, i, fn _r, res ->
      stat = resource_stat(res)
      arr = PArray.from_pairs(stat_pairs(stat))
      {:ok, {:array, arr}, i}
    end)
  end

  defp resource_stat(%{mem: m}), do: %{size: byte_size(m.data), mtime: 0}

  defp resource_stat(%{device: _} = res) do
    case :file.read_file_info(res.device) do
      {:ok, info} ->
        %{
          size: info.size,
          mtime: System.system_time(:second),
          mode: 33188
        }

      _ ->
        %{size: 0, mtime: 0, mode: 0}
    end
  end

  defp resource_stat(_), do: %{size: 0, mtime: 0, mode: 0}

  @stat_fields [
    {:dev, 0},
    {:ino, 0},
    {:mode, 33_206},
    {:nlink, 1},
    {:uid, 0},
    {:gid, 0},
    {:rdev, -1},
    {:size, :dynamic},
    {:atime, 0},
    {:mtime, :dynamic},
    {:ctime, 0},
    {:blksize, -1},
    {:blocks, -1}
  ]

  defp stat_pairs(stat) do
    @stat_fields
    |> Enum.with_index()
    |> Enum.flat_map(fn {{name, default}, idx} ->
      v =
        case default do
          :dynamic -> Map.get(stat, name, 0)
          d -> Map.get(stat, name, d)
        end

      # numeric keys first (php order), then the named key
      [{idx, {:int, v}}, {Atom.to_string(name), {:int, v}}]
    end)
  end

  ## ───────────────────────── stream contexts ─────────────────────────

  # contexts are resources carrying an options map: wrapper => option => val
  defp stream_context_create(vals, i) do
    opts = context_options(val(vals))

    PhpBeam.Interp.open_resource(i, %{ctx: opts, path: "stream context", closed: false})
    |> then(fn {res, i2} -> {:ok, res, i2} end)
  end

  defp context_options({:array, arr}) do
    arr
    |> PArray.to_pairs()
    |> Map.new(fn {wrapper, {:array, opt_arr}} ->
      {to_string(wrapper), Map.new(PArray.to_pairs(opt_arr), fn {k, v} -> {to_string(k), v} end)}
    end)
  end

  defp context_options(_), do: %{}

  defp stream_context_set_option(vals, i) do
    case val(vals) do
      {:resource, _} = r ->
        case PhpBeam.Interp.get_resource(i, r) do
          %{ctx: opts} = res ->
            opts2 =
              case vals do
                [_, {:string, w}, {:string, k}, v | _] ->
                  Map.update(opts, w, %{k => v}, fn m -> Map.put(m, k, v) end)

                _ ->
                  opts
              end

            {:ok, {:bool, true}, PhpBeam.Interp.put_resource(i, r, %{res | ctx: opts2})}

          _ ->
            {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp stream_context_get_options(vals, i) do
    case val(vals) do
      {:resource, _} = r ->
        case PhpBeam.Interp.get_resource(i, r) do
          %{ctx: opts} ->
            arr =
              PArray.from_pairs(
                Enum.map(opts, fn {w, kv} ->
                  {w, {:array, PArray.from_pairs(Enum.map(kv, fn {k, v} -> {k, v} end))}}
                end)
              )

            {:ok, {:array, arr}, i}

          _ ->
            {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  # the default context lives as resource 3 (a stable id below the open
  # stream range, created lazily like php's)
  defp stream_context_get_default(_vals, i) do
    case Map.get(i.resources, 3) do
      %{ctx: _} = res ->
        {:ok, {:resource, 3}, i}

      _ ->
        {res, i2} =
          PhpBeam.Interp.open_resource_at(i, 3, %{
            ctx: %{},
            path: "default context",
            closed: false
          })

        _ = res
        {:ok, {:resource, 3}, i2}
    end
  end

  defp stream_context_set_default(vals, i) do
    opts = context_options(val(vals))

    case Map.get(i.resources, 3) do
      %{ctx: old} = res ->
        merged = Map.merge(old, opts, fn _k, _a, b -> b end)
        {:ok, {:resource, 3}, PhpBeam.Interp.put_resource(i, 3, %{res | ctx: merged})}

      _ ->
        {_, i2} =
          PhpBeam.Interp.open_resource_at(i, 3, %{
            ctx: opts,
            path: "default context",
            closed: false
          })

        {:ok, {:resource, 3}, i2}
    end
  end

  defp is_resource_v(vals, i), do: {:ok, {:bool, match?({:resource, _}, val(vals))}, i}
end
