defmodule PhpBeam.Builtin.ZlibFns do
  @moduledoc """
  ext/zlib — 30 functions over OTP :zlib. The php `encoding` argument maps
  to zlib windowBits verbatim (RAW=-15 raw stream, DEFLATE=15 zlib wrapper,
  GZIP=31 gzip frame with header+CRC32+ISIZE — probed byte-identical).

  Context objects (deflate_init/inflate_init) hold the :zlib port in
  dt_state; deflate_add/inflate_add return REAL incremental chunks via the
  port (byte-identical to php's stream chunks). gz* file ops materialize
  the decompressed payload once (EOF-at-open semantics for writes is
  buffered; gzclose flushes the encoded frame).
  """

  alias PhpBeam.Classes.Table
  alias PhpBeam.Eval
  alias PhpBeam.PArray

  def register(fns) do
    entries = %{
      "gzcompress" => &gzcompress/2,
      "gzuncompress" => &gzuncompress/2,
      "gzdeflate" => &gzdeflate/2,
      "gzinflate" => &gzinflate/2,
      "gzencode" => &gzencode/2,
      "gzdecode" => &gzdecode/2,
      "zlib_encode" => &zlib_encode/2,
      "zlib_decode" => &zlib_decode/2,
      "zlib_get_coding_type" => &zlib_get_coding_type/2,
      "deflate_init" => &deflate_init/2,
      "deflate_add" => &deflate_add/2,
      "inflate_init" => &inflate_init/2,
      "inflate_add" => &inflate_add/2,
      "inflate_get_read_len" => &inflate_get_read_len/2,
      "inflate_get_status" => &inflate_get_status/2,
      "ob_gzhandler" => &ob_gzhandler/2,
      "gzopen" => &gzopen/2,
      "gzclose" => &gzclose/2,
      "gzread" => &gzread/2,
      "gzwrite" => &gzwrite/2,
      "gzputs" => &gzwrite/2,
      "gzgets" => &gzgets/2,
      "gzgetc" => &gzgetc/2,
      "gzeof" => &gzeof/2,
      "gztell" => &gztell/2,
      "gzseek" => &gzseek/2,
      "gzrewind" => &gzrewind/2,
      "gzpassthru" => &gzpassthru/2,
      "gzfile" => &gzfile/2,
      "readgzfile" => &readgzfile/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, wrapped)
  end

  # ────────────────────────── context classes ──────────────────────────

  def classes do
    %{
      "deflatecontext" => ctx_class("DeflateContext"),
      "inflatecontext" => ctx_class("InflateContext")
    }
  end

  defp ctx_class(name) do
    struct!(Table,
      name: name,
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{},
      enum_cases: [],
      file: ""
    )
  end

  defp new_ctx(i, class_key, state) do
    {ref, i2} = Eval.make_instance(i, class_key)
    obj = Eval.get_object(i2, ref)
    i3 = Eval.put_object(i2, ref, Map.put(obj, :dt_state, state))
    {ref, i3}
  end

  defp ctx_state(i, v, class_key, fname) do
    case v do
      {:object, _} = ref ->
        obj = Eval.get_object(i, ref)

        if obj.class == class_key do
          {:ok, obj.dt_state || %{}, ref}
        else
          ctx_type_error(i, fname, display_class(i, class_key), given_name(v))
        end

      _ ->
        ctx_type_error(i, fname, display_class(i, class_key), given_name(v))
    end
  end

  # php TypeError renders scalar args by TYPE name ("string given"), not value
  defp given_name(v) do
    case v do
      {:string, _} -> "string"
      {:int, _} -> "int"
      {:float, _} -> "float"
      {:bool, true} -> "true"
      {:bool, false} -> "false"
      :null -> "null"
      {:array, _} -> "array"
      _ -> "unknown"
    end
  end

  defp display_class(_i, "deflatecontext"), do: "DeflateContext"
  defp display_class(_i, "inflatecontext"), do: "InflateContext"

  defp ctx_type_error(i, fname, want, got) do
    i2 = PhpBeam.Interp.push_frame(i, fname, [])

    {obj, i3} =
      Eval.materialize_native(
        {:native_error, "TypeError", "#{fname}(): Argument #1 ($context) must be of type #{want}, #{got} given"},
        i2
      )

    {:unwind, {:php_throw, obj}, i3}
  end

  # ────────────────────────── one-shot codecs ──────────────────────────

  # php `encoding` values pass through as zlib windowBits
  defp enc_wbits({:int, n}, _i) when n in [-15, 15, 31], do: {:ok, n}
  defp enc_wbits(_v, i), do: bad_encoding(i)

  defp bad_encoding(i) do
    i2 = PhpBeam.Interp.push_frame(i, "deflate_init", [])

    {obj, i3} =
      Eval.materialize_native(
        {:native_error, "ValueError",
         "deflate_init(): Argument #1 ($encoding) must be one of ZLIB_ENCODING_RAW, ZLIB_ENCODING_GZIP, or ZLIB_ENCODING_DEFLATE"},
        i2
      )

    {:unwind, {:php_throw, obj}, i3}
  end

  defp level_of(vals, pos, default) do
    case Enum.at(vals, pos) do
      {:int, n} when n in -1..9 -> n
      :null -> default
      nil -> default
      _ -> default
    end
  end

  defp enc_of(vals, pos, default) do
    case Enum.at(vals, pos) do
      {:int, n} when n in [-15, 15, 31] -> n
      _ -> default
    end
  end

  defp zdeflate(data, level, wbits) do
    level = if level < 0, do: 6, else: level
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, level, :deflated, wbits, 8, :default)
    out = :zlib.deflate(z, data, :finish)
    :zlib.close(z)
    IO.iodata_to_binary(out)
  end

  defp zinflate(data, wbits) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, wbits)

    try do
      out = :zlib.inflate(z, data)
      :zlib.close(z)
      {:ok, IO.iodata_to_binary(out)}
    catch
      :error, _ ->
        try do
          :zlib.close(z)
        catch
          _, _ -> :ok
        end

        :error
    end
  end

  defp gzcompress(vals, i) do
    data = str0(vals)
    level = level_of(vals, 1, 6)
    {:ok, {:string, zdeflate(data, level, 15)}, i}
  end

  defp gzuncompress(vals, i) do
    case zinflate(str0(vals), 15) do
      {:ok, out} -> {:ok, {:string, out}, i}
      :error -> warn_false(i, "gzuncompress(): data error")
    end
  end

  defp gzdeflate(vals, i) do
    data = str0(vals)
    level = level_of(vals, 1, 6)
    {:ok, {:string, zdeflate(data, level, -15)}, i}
  end

  defp gzinflate(vals, i) do
    case zinflate(str0(vals), -15) do
      {:ok, out} -> {:ok, {:string, out}, i}
      :error -> warn_false(i, "gzinflate(): data error")
    end
  end

  defp gzencode(vals, i) do
    data = str0(vals)
    level = level_of(vals, 1, -1)
    enc = enc_of(vals, 2, 31)
    {:ok, {:string, zdeflate(data, level, enc)}, i}
  end

  defp gzdecode(vals, i) do
    case zinflate(str0(vals), 31) do
      {:ok, out} -> {:ok, {:string, out}, i}
      :error -> warn_false(i, "gzdecode(): data error")
    end
  end

  defp zlib_encode(vals, i) do
    data = str0(vals)
    enc = enc_of(vals, 1, 15)
    level = level_of(vals, 2, 6)
    {:ok, {:string, zdeflate(data, level, enc)}, i}
  end

  defp zlib_decode(vals, i) do
    data = str0(vals)

    max =
      case Enum.at(vals, 1) do
        {:int, n} when n > 0 -> n
        _ -> nil
      end

    case zinflate(data, 15) do
      {:ok, out} ->
        out =
          if max && byte_size(out) > max,
            do: binary_part(out, 0, max),
            else: out

        {:ok, {:string, out}, i}

      :error ->
        warn_false(i, "zlib_decode(): data error")
    end
  end

  defp zlib_get_coding_type(_vals, i), do: {:ok, {:bool, false}, i}

  defp ob_gzhandler(vals, i) do
    # CLI carries no Accept-Encoding header: content passes through
    {:ok, {:string, str0(vals)}, i}
  end

  # ────────────────────────── incremental contexts ──────────────────────────

  defp deflate_init(vals, i) do
    with {:ok, wbits} <- enc_wbits(Enum.at(vals, 0, {:int, 15}), i) do
      level = level_of(vals, 1, 6)

      z = :zlib.open()
      :ok = :zlib.deflateInit(z, level, :deflated, wbits, 8, :default)

      {ref, i2} = new_ctx(i, "deflatecontext", %{"z" => z, "mode" => wbits, "done" => false})
      {:ok, ref, i2}
    end
  end

  @flush_map %{0 => :none, 1 => :partial, 2 => :sync, 3 => :full, 4 => :finish, 5 => :block}

  defp deflate_add(vals, i) do
    case ctx_state(i, Enum.at(vals, 0, :null), "deflatecontext", "deflate_add") do
      {:ok, state, ref} ->
        data = str_at(vals, 1)
        flush = flush_of(vals, 2)

        if state["done"] do
          warn_false(i, "deflate_add(): The context is already finished")
        else
          out = :zlib.deflate(state["z"], data, flush)

          i2 =
            if flush == :finish,
              do: put_state(i, ref, %{"z" => state["z"], "mode" => state["mode"], "done" => true}),
              else: i

          {:ok, {:string, IO.iodata_to_binary(out)}, i2}
        end

      u ->
        u
    end
  end

  defp inflate_init(vals, i) do
    with {:ok, wbits} <- enc_wbits(Enum.at(vals, 0, {:int, 15}), i) do
      z = :zlib.open()
      :ok = :zlib.inflateInit(z, wbits)

      {ref, i2} =
        new_ctx(i, "inflatecontext", %{"z" => z, "mode" => wbits, "read" => 0, "status" => 0})

      {:ok, ref, i2}
    end
  end

  defp inflate_add(vals, i) do
    case ctx_state(i, Enum.at(vals, 0, :null), "inflatecontext", "inflate_add") do
      {:ok, state, ref} ->
        data = str_at(vals, 1)
        flush = flush_of(vals, 2)

        case safe_inflate(state["z"], data) do
          {:ok, out, complete?} ->
            state2 =
              %{
                "z" => state["z"],
                "mode" => state["mode"],
                "read" => (state["read"] || 0) + byte_size(data),
                "status" => if(complete?, do: 1, else: 0)
              }

            i2 = put_state(i, ref, state2)
            {:ok, {:string, out}, i2}

          {:error, _} ->
            warn_false(i, "inflate_add(): data error")
        end

      u ->
        u
    end
  end

  # safeInflate's `complete` flag is exactly php's Z_STREAM_END (probed:
  # inflate_get_status -> 1 right after the frame's final chunk)
  defp safe_inflate(z, data) do
    try do
      case :zlib.safeInflate(z, data) do
        {finished, out} when finished in [:finished, :complete] ->
          {:ok, IO.iodata_to_binary(out), true}

        {continue, out} when continue in [:continue, :ok] ->
          {:ok, IO.iodata_to_binary(out), false}
      end
    catch
      :error, _ -> {:error, :data}
    end
  end

  defp inflate_get_read_len(vals, i) do
    case ctx_state(i, Enum.at(vals, 0, :null), "inflatecontext", "inflate_get_read_len") do
      {:ok, state, _ref} -> {:ok, {:int, state["read"] || 0}, i}
      u -> u
    end
  end

  defp inflate_get_status(vals, i) do
    case ctx_state(i, Enum.at(vals, 0, :null), "inflatecontext", "inflate_get_status") do
      {:ok, state, _ref} ->
        # 1 = Z_STREAM_END after the frame completed; 0 otherwise (probed)
        {:ok, {:int, if(state["status"] == 1, do: 1, else: 0)}, i}

      u ->
        u
    end
  end

  defp flush_of(vals, pos) do
    case Enum.at(vals, pos) do
      {:int, n} -> Map.get(@flush_map, n, :none)
      _ -> :none
    end
  end

  defp put_state(i, ref, state) do
    obj = Eval.get_object(i, ref)
    Eval.put_object(i, ref, Map.put(obj, :dt_state, state))
  end

  # ────────────────────────── gz file family ──────────────────────────

  # resource layout: %{gz_mode:, gz_path:, gz_data: (read: full plaintext |
  # write: buffer), gz_pos:, closed:, gz_level:, gz_enc:}
  defp gzopen(vals, i) do
    path = str_at(vals, 0)
    mode = str_at(vals, 1)

    # the compression level rides INSIDE the mode string ("wb9"); php's
    # third arg is use_include_path, not level
    {base, lvl_s} =
      case Regex.run(~r/\A([rwxab]+)([0-9]*)\z/, mode) do
        [_, b, l] -> {b, l}
        nil -> {mode, ""}
      end

    level =
      case Integer.parse(lvl_s) do
        {n, ""} -> n
        _ -> -1
      end

    # strip the binary flag: "rb"->"r", "wb9"->"w"
    base = String.replace_suffix(base, "b", "")

    {m, read?} =
      case base do
        "r" -> {"r", true}
        "w" -> {"w", false}
        "a" -> {"a", false}
        "x" -> {"x", false}
        _ -> {"r", true}
      end

    cond do
      read? ->
        case File.read(path) do
          {:ok, bin} ->
            data =
              case zinflate(bin, 31) do
                {:ok, out} -> out
                :error -> ""
              end

            open_resource(i, %{gz_mode: m, gz_path: path, gz_data: data, gz_pos: 0, closed: false})

          {:error, _} ->
            open_resource(i, %{gz_mode: m, gz_path: path, gz_data: "", gz_pos: 0, closed: true,
                               gz_missing: true})

        end

      true ->
        # real incremental stream: every gzwrite flushes (SYNC_FLUSH — php's
        # gzwrite emits 00 00 FF FF separators, probed), gzclose finishes
        {:ok, dev} = File.open(path, [:write])

        z = :zlib.open()
        :ok = :zlib.deflateInit(z, if(level < 0, do: 6, else: level), :deflated, 31, 8, :default)

        open_resource(i, %{
          gz_mode: m,
          gz_path: path,
          gz_data: "",
          gz_pos: 0,
          closed: false,
          gz_write: true,
          gz_level: level,
          gz_dev: dev,
          gz_z: z
        })
    end
  end

  defp open_resource(i, state) do
    # open_resource starts ids at 5 (php-cli numbering parity)
    {{:resource, id}, i2} = PhpBeam.Interp.open_resource(i, Map.put(state, :id, 0))
    {:ok, {:resource, id},
     %{i2 | resources: Map.put(i2.resources, id, Map.put(state, :id, id))}}
  end

  defp gz_stream(vals, i, fname \\ "gzread") do
    case Enum.at(vals, 0, :null) do
      {:resource, id} ->
        case Map.get(i.resources, id) do
          %{closed: false} = st -> {:ok, st}
          _ -> {:ok, %{closed: true}}
        end

      _ ->
        stream_type_error(i, fname)
    end
  end

  defp stream_type_error(i, fname) do
    # callers only reach here with non-resources; the common php renderings
    given = "int"

    i2 = PhpBeam.Interp.push_frame(i, fname, [])

    {obj, i3} =
      Eval.materialize_native(
        {:native_error, "TypeError", "#{fname}(): Argument #1 ($stream) must be of type resource, #{given} given"},
        i2
      )

    {:unwind, {:php_throw, obj}, i3}
  end

  defp gzclose(vals, i) do
    case Enum.at(vals, 0, :null) do
      {:resource, id} ->
        case Map.get(i.resources, id) do
          %{gz_write: true, gz_z: z, gz_dev: dev} = st ->
            IO.binwrite(dev, :zlib.deflate(z, <<>>, :sync))
            IO.binwrite(dev, :zlib.deflate(z, <<>>, :finish))
            :zlib.close(z)
            File.close(dev)
            i2 = %{i | resources: Map.put(i.resources, id, %{st | closed: true})}
            {:ok, {:bool, true}, i2}

          %{gz_write: true, gz_data: buf, gz_path: path, gz_level: lvl} = st ->
            :ok = File.write(path, zdeflate(buf, lvl, 31))
            i2 = %{i | resources: Map.put(i.resources, id, %{st | closed: true})}
            {:ok, {:bool, true}, i2}

          st when is_map(st) ->
            i2 = %{i | resources: Map.put(i.resources, id, %{st | closed: true})}
            {:ok, {:bool, true}, i2}

          _ ->
            {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp gzread(vals, i) do
    case gz_stream(vals, i) do
      {:ok, %{closed: false} = st} ->
    n =
      case Enum.at(vals, 1) do
        {:int, n} when n > 0 -> n
        _ -> 0
      end

    data = binary_part(st.gz_data, min(st.gz_pos, byte_size(st.gz_data)), max(0, min(n, byte_size(st.gz_data) - st.gz_pos)))
    i2 = seek_res(i, st, st.gz_pos + byte_size(data))
    {:ok, {:string, data}, i2}

      {:ok, _} ->
        {:ok, {:bool, false}, i}

      u ->
        u
    end
  end

  defp gzwrite(vals, i) do
    case gz_stream(vals, i) do
      {:ok, %{closed: false} = st} ->
        data = str_at(vals, 1)

        if st.gz_write and Map.has_key?(st, :gz_z) do
          # writes accumulate (NO_FLUSH — bit stream stays continuous);
          # the close-time SYNC+FINISH emits the 00 00 FF FF + final block
          out = :zlib.deflate(st.gz_z, data, :none)
          IO.binwrite(st.gz_dev, out)
          st2 = %{st | gz_pos: st.gz_pos + byte_size(data)}
          i2 = put_res(i, st2)
          {:ok, {:int, byte_size(data)}, i2}
        else
          buf = Map.get(st, :gz_data, "") <> data
          st2 = %{st | gz_data: buf, gz_pos: Map.get(st, :gz_pos, 0) + byte_size(data)}
          i2 = put_res(i, st2)
          {:ok, {:int, byte_size(data)}, i2}
        end

      {:ok, _} ->
        {:ok, {:bool, false}, i}

      u ->
        u
    end
  end

  defp gzgets(vals, i) do
    case gz_stream(vals, i) do
      {:ok, %{closed: false} = st} ->
    rest = binary_part(st.gz_data, st.gz_pos, byte_size(st.gz_data) - st.gz_pos)

    line =
      case :binary.match(rest, "\n") do
        {p, 1} -> binary_part(rest, 0, p + 1)
        :nomatch -> rest
      end

    i2 = seek_res(i, st, st.gz_pos + byte_size(line))
    {:ok, {:string, line}, i2}

      {:ok, _} ->
        {:ok, {:bool, false}, i}

      u ->
        u
    end
  end

  defp gzgetc(vals, i) do
    case gz_stream(vals, i) do
      {:ok, %{closed: false} = st} ->
    if st.gz_pos < byte_size(st.gz_data) do
      c = binary_part(st.gz_data, st.gz_pos, 1)
      i2 = seek_res(i, st, st.gz_pos + 1)
      {:ok, {:string, c}, i2}
    else
      {:ok, {:bool, false}, i}
    end

      {:ok, _} ->
        {:ok, {:bool, false}, i}

      u ->
        u
    end
  end

  defp gzeof(vals, i) do
    case gz_stream(vals, i) do
      {:ok, %{closed: false} = st} ->
    {:ok, {:bool, st.gz_pos >= byte_size(st.gz_data)}, i}

      {:ok, _} ->
        {:ok, {:bool, false}, i}

      u ->
        u
    end
  end

  defp gztell(vals, i) do
    case gz_stream(vals, i) do
      {:ok, %{closed: false} = st} ->
    {:ok, {:int, st.gz_pos}, i}

      {:ok, _} ->
        {:ok, {:bool, false}, i}

      u ->
        u
    end
  end

  defp gzseek(vals, i) do
    case gz_stream(vals, i) do
      {:ok, %{closed: false} = st} ->
    off =
      case Enum.at(vals, 1) do
        {:int, n} -> n
        _ -> 0
      end

    off = max(0, min(off, byte_size(st.gz_data)))
    i2 = seek_res(i, st, off)
    {:ok, {:int, 0}, i2}

      {:ok, _} ->
        {:ok, {:bool, false}, i}

      u ->
        u
    end
  end

  defp gzrewind(vals, i) do
    case gz_stream(vals, i) do
      {:ok, %{closed: false} = st} ->
    {:ok, {:bool, true}, seek_res(i, st, 0)}

      {:ok, _} ->
        {:ok, {:bool, false}, i}

      u ->
        u
    end
  end

  defp gzpassthru(vals, i) do
    case gz_stream(vals, i) do
      {:ok, %{closed: false} = st} ->
    rest = binary_part(st.gz_data, st.gz_pos, byte_size(st.gz_data) - st.gz_pos)
    i2 = seek_res(i, st, byte_size(st.gz_data))

    i3 = PhpBeam.Interp.write(i2, rest)
    {:ok, {:int, byte_size(rest)}, i3}

      {:ok, _} ->
        {:ok, {:bool, false}, i}

      u ->
        u
    end
  end

  defp gzfile(vals, i) do
    path = str_at(vals, 0)

    lines =
      with {:ok, bin} <- File.read(path),
           {:ok, out} <- zinflate(bin, 31) do
        out |> String.split("\n") |> lines_keep_nl()
      else
        _ -> []
      end


    {:ok, {:array, PArray.from_pairs(Enum.map(lines, &{nil, {:string, &1}}))}, i}
  end

  defp lines_keep_nl([]), do: []

  defp lines_keep_nl([last]), do: if(last == "", do: [], else: [last])

  defp lines_keep_nl([h | t]), do: [h <> "\n" | lines_keep_nl(t)]

  defp readgzfile(vals, i) do
    path = str_at(vals, 0)

    case File.read(path) do
      {:ok, bin} ->
        out =
          case zinflate(bin, 31) do
            {:ok, o} -> o
            :error -> ""
          end

        i2 = PhpBeam.Interp.write(i, out)
        {:ok, {:int, byte_size(out)}, i2}

      :error ->
        warn_false(i, "readgzfile(): failed to open stream: #{path}")
    end
  end

  # ────────────────────────── helpers ──────────────────────────

  defp str0(vals), do: str_at(vals, 0)

  defp str_at(vals, pos) do
    case Enum.at(vals, pos) do
      {:string, s} -> s
      :null -> ""
      _ -> ""
    end
  end

  defp warn_false(i, msg) do
    case PhpBeam.Eval.Error.warn(PhpBeam.Eval.Error.stub_env(), i, msg) do
      {:cont, _, i2} -> {:ok, {:bool, false}, i2}
      {:unwind, u, _, i2} -> {:unwind, u, i2}
    end
  end

  defp put_res(i, st) do
    %{i | resources: Map.put(i.resources, st.id, st)}
  end

  defp seek_res(i, st, pos) do
    %{i | resources: Map.put(i.resources, st.id, %{st | gz_pos: pos})}
  end
end
