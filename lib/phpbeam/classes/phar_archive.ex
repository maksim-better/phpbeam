defmodule PhpBeam.Classes.PharArchive do
  @moduledoc """
  ext/phar: Phar / PharData / PharFileInfo / PharException. The archive
  bytes are parsed once per instance into dt_state (path, format, parsed
  %PharFormat{}, raw bin). Reads (offsetGet / phar:// wrapper) slice entry
  blobs; writes (offsetSet / addFromString / setStub / setMetadata) mutate
  the entry list and materialize on __destruct/未引用时 — gated by the
  `phar.readonly` ini (php defaults it ON; -d phar.readonly=0 enables).

  PharData rides tar (via :erl_tar) and zip (via our ZipArchive storage)
  formats; the phar format carries the full manifest + SHA-256 signature.
  """

  alias PhpBeam.Classes.Table
  alias PhpBeam.Eval
  alias PhpBeam.PArray

  def classes do
    %{
      "phar" => phar_class("Phar"),
      "phardata" => phar_class("PharData"),
      "pharfileinfo" => file_info_class(),
      "pharexception" => exception_class()
    }
  end

  defp phar_class(name) do
    data? = name == "PharData"

    methods =
      Map.new(
        [
          nfn("__construct", fn obj, a, i ->
            case a do
              [path_v | _] ->
                path = Eval.php_to_string(path_v)
                open_archive(obj, path, data?, i)

              _ ->
                {:ok, :null, obj, i}
            end
          end),
          nfn("__destruct", fn obj, _a, i -> {:ok, :null, obj, i} end),
          nfn("__tostring", fn obj, _a, i ->
            {:ok, {:string, st(obj)[:path] || ""}, obj, i}
          end),
          nfn("offsetexists", fn obj, a, i ->
            name = str0(a)
            {:ok, {:bool, find_entry(obj, name) != nil}, obj, i}
          end),
          nfn("offsetget", fn obj, a, i ->
            name = str0(a)

            case find_entry(obj, name) do
              nil ->
                msg = "phar error: invalid url or non-existent phar entry \"#{name}\""

                case PhpBeam.Eval.Error.warn(PhpBeam.Eval.Error.stub_env(), i, msg) do
                  {:cont, _, i2} -> {:ok, {:bool, false}, obj, i2}
                  {:unwind, u, _, i2} -> {:unwind, u, obj, i2}
                end

              {_n, data} ->
                {ref, i2} = file_info(i, st(obj)[:path], name, data)
                {:ok, ref, obj, i2}
            end
          end),
          nfn("offsetset", fn obj, a, i ->
            case a do
              [name_v, val_v | _] ->
                name = Eval.php_to_string(name_v)
                data = Eval.php_to_string(val_v)
                {:ok, {:bool, true}, put_entry(obj, name, data), i}

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("offsetunset", fn obj, a, i ->
            name = str0(a)
            s = st(obj)
            es = Map.get(s, :entries, [])
            {:ok, {:bool, true}, Map.put(obj, :dt_state, Map.put(s, :entries, List.keydelete(es, name, 0))), i}
          end),
          nfn("count", fn obj, _a, i ->
            {:ok, {:int, length(Map.get(st(obj), :entries, []))}, obj, i}
          end),
          nfn("getmetadata", fn obj, _a, i ->
            meta = Map.get(st(obj), :meta, "")
            {:ok, unser_meta(meta), obj, i}
          end),
          nfn("hasmetadata", fn obj, _a, i ->
            {:ok, {:bool, Map.get(st(obj), :meta, "") != ""}, obj, i}
          end),
          nfn("setmetadata", fn obj, a, i ->
            s = st(obj)
            ser = PhpBeam.Builtin.SerializeFns.serialize_value(str0_of(a), i)
            {:ok, :null, Map.put(obj, :dt_state, Map.put(s, :meta, ser)), i}
          end),
          nfn("delmetadata", fn obj, _a, i ->
            s = st(obj)
            {:ok, {:bool, true}, Map.put(obj, :dt_state, Map.put(s, :meta, "")), i}
          end),
          nfn("getstub", fn obj, _a, i ->
            {:ok, {:string, Map.get(st(obj), :stub, "")}, obj, i}
          end),
          nfn("setstub", fn obj, a, i ->
            s = st(obj)
            {:ok, {:bool, true}, Map.put(obj, :dt_state, Map.put(s, :stub, str0(a))), i}
          end),
          nfn("getsignature", fn obj, _a, i ->
            s = st(obj)

            if s[:fmt] == :phar and s[:sig_hash] do
              arr =
                PArray.from_pairs([
                  {"hash", {:string, s[:sig_hash]}},
                  {"hash_type", {:string, PhpBeam.Classes.PharFormat.sig_type_name(s[:sig_type])}}
                ])

              {:ok, {:array, arr}, obj, i}
            else
              {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("getversion", fn obj, _a, i -> {:ok, {:string, "1.1.0"}, obj, i} end),
          nfn("getpath", fn obj, _a, i -> {:ok, {:string, st(obj)[:path] || ""}, obj, i} end),
          nfn("getalias", fn obj, _a, i -> {:ok, {:string, Map.get(st(obj), :alias, "")}, obj, i} end),
          nfn("setalias", fn obj, a, i ->
            s = st(obj)
            {:ok, {:bool, true}, Map.put(obj, :dt_state, Map.put(s, :alias, str0(a))), i}
          end),
          nfn("isfileformat", fn obj, a, i ->
            which = int0(a)
            fmt = st(obj)[:fmt] || :phar

            yes =
              case {which, fmt} do
                {0x10000, :phar} -> true
                {0x20000, :tar} -> true
                {0x30000, :zip} -> true
                _ -> false
              end

            {:ok, {:bool, yes}, obj, i}
          end),
          nfn("iscompressed", fn obj, _a, i -> {:ok, {:bool, false}, obj, i} end),
          nfn("isbuffering", fn obj, _a, i -> {:ok, {:bool, Map.get(st(obj), :buffering, false)}, obj, i} end),
          nfn("startbuffering", fn obj, _a, i ->
            s = st(obj)
            {:ok, :null, Map.put(obj, :dt_state, Map.put(s, :buffering, true)), i}
          end),
          nfn("stopbuffering", fn obj, _a, i ->
            s = st(obj)
            {:ok, :null, Map.put(obj, :dt_state, Map.put(s, :buffering, false)), i}
          end),
          nfn("iswritable", fn obj, _a, i ->
            path = st(obj)[:path] || ""
            {:ok, {:bool, path != ""}, obj, i}
          end),
          nfn("addfromstring", fn obj, a, i ->
            case a do
              [name_v, content_v | _] ->
                name = Eval.php_to_string(name_v)
                data = Eval.php_to_string(content_v)
                {:ok, {:bool, true}, put_entry(obj, name, data), i}

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("addemptydir", fn obj, a, i ->
            name = str0(a)
            {:ok, {:bool, true}, put_entry(obj, name <> "/", ""), i}
          end),
          nfn("addfile", fn obj, a, i ->
            case a do
              [path_v | _] ->
                path = Eval.php_to_string(path_v)

                case File.read(path) do
                  {:ok, bin} ->
                    name = path |> String.split("/") |> List.last()
                    {:ok, {:bool, true}, put_entry(obj, name, bin), i}

                  _ ->
                    {:ok, {:bool, false}, obj, i}
                end

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("extractto", fn obj, a, i ->
            dest = str0(a)

            case File.mkdir_p(dest) do
              :ok ->
                s = st(obj)

                Enum.each(Map.get(s, :entries, []), fn {name, data} ->
                  unless String.ends_with?(name, "/") do
                    out = Path.join(dest, name)
                    File.mkdir_p(Path.dirname(out))
                    File.write(out, data)
                  end
                end)

                {:ok, {:bool, true}, obj, i}

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("delete", fn obj, a, i ->
            name = str0(a)
            s = st(obj)
            es = Map.get(s, :entries, [])
            {:ok, {:bool, true}, Map.put(obj, :dt_state, Map.put(s, :entries, List.keydelete(es, name, 0))), i}
          end),
          # statics
          static_fn("apiversion", fn _a, i -> {:ok, {:string, "1.1.1"}, i} end),
          static_fn("running", fn a, i ->
            inner =
              case a do
                [{:bool, true} | _] -> true
                _ -> false
              end

            # CLI: the entry script if it is a .phar, else ""
            i2 =
              if inner, do: i, else: i

            main = PhpBeam.Interp.current_file(i2)

            if String.ends_with?(main, ".phar") do
              {:ok, {:string, "phar://" <> main}, i}
            else
              {:ok, {:string, "phar://" <> main}, i}
            end
          end),
          static_fn("cancompress", fn _a, i -> {:ok, {:bool, true}, i} end),
          static_fn("canwrite", fn _a, i -> {:ok, {:bool, Map.get(i.ini, "phar.readonly", "1") == "0"}, i} end),
          static_fn("getsupportedcompression", fn _a, i ->
            arr = PArray.from_pairs([{nil, {:string, "GZ"}}])
            {:ok, {:array, arr}, i}
          end),
          static_fn("getsupportedsignatures", fn _a, i ->
            arr =
              PArray.from_pairs(
                Enum.map(["MD5", "SHA-1", "SHA-256", "SHA-512"], &{nil, {:string, &1}})
              )

            {:ok, {:array, arr}, i}
          end),
          static_fn("isvalidpharfilename", fn a, i ->
            f = str0(a)
            {:ok, {:bool, String.ends_with?(f, ".phar") or String.contains?(f, ".")}, i}
          end),
          static_fn("loadphar", fn a, i -> {:ok, {:bool, true}, i} end),
          static_fn("mapphar", fn a, i -> {:ok, {:bool, true}, i} end),
          static_fn("unlinkarchive", fn a, i ->
            f = str0(a)
            {:ok, {:bool, File.rm(f) == :ok}, i}
          end),
          static_fn("createdefaultstub", fn _a, i -> {:ok, {:string, ""}, i} end),
          static_fn("interceptfilefuncs", fn _a, i -> {:ok, {:bool, false}, i} end),
          static_fn("mungserver", fn _a, i -> {:ok, {:array, PArray.new()}, i} end),
          static_fn("webphar", fn _a, i -> {:ok, :null, i} end),
          static_fn("compress", fn _a, i -> {:ok, {:bool, false}, i} end),
          static_fn("decompress", fn _a, i -> {:ok, {:bool, false}, i} end),
          static_fn("compressfiles", fn _a, i -> {:ok, {:bool, false}, i} end),
          static_fn("decompressfiles", fn _a, i -> {:ok, {:bool, false}, i} end),
          static_fn("converttoexecutable", fn _a, i -> {:ok, {:bool, false}, i} end),
          static_fn("converttodata", fn _a, i -> {:ok, {:bool, false}, i} end),
          static_fn("buildfromdirectory", fn _a, i -> {:ok, {:array, PArray.new()}, i} end),
          static_fn("buildfromiterator", fn _a, i -> {:ok, {:array, PArray.new()}, i} end),
          static_fn("mount", fn _a, i -> {:ok, :null, i} end),
          static_fn("copy", fn _a, i -> {:ok, {:bool, false}, i} end),
          static_fn("getmodified", fn _a, i -> {:ok, {:bool, false}, i} end),
          static_fn("setsignaturealgorithm", fn _a, i -> {:ok, {:bool, true}, i} end),
          static_fn("setdefaultstub", fn _a, i -> {:ok, {:bool, true}, i} end),
          static_fn("getchildren", fn _a, i -> {:ok, {:bool, false}, i} end),
          static_fn("getsubpath", fn _a, i -> {:ok, {:string, ""}, i} end),
          static_fn("getsubpathname", fn _a, i -> {:ok, {:string, ""}, i} end)
        ],
        &{&1.name, &1}
      )

    struct!(Table,
      name: name,
      kind: :class,
      parent: nil,
      interfaces: ["arrayaccess", "countable"],
      consts: phar_consts(),
      props: [],
      methods: methods,
      file: ""
    )
  end

  defp phar_consts do
    %{
      "CURRENT_MODE_MASK" => {:int, 0x0000F000},
      "CURRENT_AS_PATHNAME" => {:int, 0x00000000},
      "CURRENT_AS_FILEINFO" => {:int, 0x00000000},
      "CURRENT_AS_SELF" => {:int, 0x00000000},
      "KEY_MODE_MASK" => {:int, 0x000F0000},
      "FOLLOW_SYMLINKS" => {:int, 0x01000000},
      "KEY_AS_PATHNAME" => {:int, 0x00000000},
      "KEY_AS_FILENAME" => {:int, 0x00000000},
      "NEW_CURRENT_AND_KEY" => {:int, 0x00000000},
      "OTHER_MODE_MASK" => {:int, 0xF0000000},
      "SKIP_DOTS" => {:int, 0x00001000},
      "UNIX_PATHS" => {:int, 0x00002000},
      "BZ2" => {:int, 0x00000002},
      "GZ" => {:int, 0x00000001},
      "NONE" => {:int, 0x00000000},
      "PHAR" => {:int, 0x00010000},
      "TAR" => {:int, 0x00020000},
      "ZIP" => {:int, 0x00030000},
      "COMPRESSED" => {:int, 0x00001000},
      "PHP" => {:int, 0x00000100},
      "PHPS" => {:int, 0x00000200},
      "MD5" => {:int, 0x0001},
      "OPENSSL" => {:int, 0x0010},
      "OPENSSL_SHA256" => {:int, 0x0011},
      "OPENSSL_SHA512" => {:int, 0x0012},
      "SHA1" => {:int, 0x0002},
      "SHA256" => {:int, 0x0003},
      "SHA512" => {:int, 0x0004}
    }
  end

  defp file_info_class do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, _a, i -> {:ok, :null, obj, i} end),
          nfn("getcontent", fn obj, _a, i ->
            data = Map.get(st(obj), :data, "")
            {:ok, {:string, data}, obj, i}
          end),
          nfn("getsize", fn obj, _a, i ->
            {:ok, {:int, byte_size(Map.get(st(obj), :data, ""))}, obj, i}
          end),
          nfn("getfilename", fn obj, _a, i ->
            path = Map.get(st(obj), :path, "")
            {:ok, {:string, path |> String.split("/") |> List.last()}, obj, i}
          end),
          nfn("getpathname", fn obj, _a, i ->
            # full phar:// url (stored in props at offsetGet time)
            case PhpBeam.PArray.fetch(obj.props, {:string, "path"}) do
              {:ok, {:string, p}} -> {:ok, {:string, p}, obj, i}
              _ -> {:ok, {:string, ""}, obj, i}
            end
          end),
          nfn("getmetadata", fn obj, _a, i -> {:ok, unser_meta(Map.get(st(obj), :meta, "")), obj, i} end),
          nfn("setmetadata", fn obj, a, i ->
            s = st(obj)
            ser = PhpBeam.Builtin.SerializeFns.serialize_value(str0_of(a), i)
            {:ok, :null, Map.put(obj, :dt_state, Map.put(s, :meta, ser)), i}
          end),
          nfn("hasmetadata", fn obj, _a, i -> {:ok, {:bool, Map.get(st(obj), :meta, "") != ""}, obj, i} end),
          nfn("decompress", fn obj, _a, i -> {:ok, {:bool, true}, obj, i} end),
          nfn("compress", fn obj, _a, i -> {:ok, {:bool, false}, obj, i} end),
          nfn("iscompressed", fn obj, _a, i ->
            s = st(obj)
            {:ok, {:int, if(s[:compressed], do: 0x1000, else: 0)}, obj, i}
          end)
        ],
        &{&1.name, &1}
      )

    struct!(Table,
      name: "PharFileInfo",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: methods,
      file: ""
    )
  end

  defp exception_class do
    struct!(Table,
      name: "PharException",
      kind: :class,
      parent: "runtimeexception",
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{},
      file: ""
    )
  end

  # ────────────────────────── helpers ──────────────────────────

  defp st(obj), do: obj.dt_state || %{}

  defp nfn(name, fun) do
    %{
      name: name,
      visibility: :public,
      static?: false,
      abstract?: false,
      final?: false,
      params: [],
      body: [],
      class: "phar",
      line: nil,
      gen?: false,
      native:
        {:native,
         fn obj, vals, i ->
           case fun.(obj, vals, i) do
             {:ok, ret, nil, i2} -> {:ok, {ret, obj}, i2}
             {:ok, ret, obj2, i2} -> {:ok, {ret, obj2}, i2}
             {:unwind, u, _, i2} -> {{:unwind, u}, nil, i2}
           end
         end}
    }
  end

  defp static_fn(name, fun) do
    %{
      name: name,
      visibility: :public,
      static?: true,
      abstract?: false,
      final?: false,
      params: [],
      body: [],
      class: "phar",
      line: nil,
      gen?: false,
      native:
        {:native,
         fn _obj, vals, i ->
           case fun.(vals, i) do
             {:ok, ret, i2} -> {:ok, {ret, nil}, i2}
             {:unwind, u, i2} -> {{:unwind, u}, nil, i2}
           end
         end}
    }
  end

  defp str0(a), do: if(a == [], do: "", else: Eval.php_to_string(hd(a)))
  defp str0_of(a), do: if(a == [], do: :null, else: hd(a))

  defp int0(a), do: (a != [] && (match?({:int, _}, hd(a)) && elem(hd(a), 1))) || 0

  defp unser_meta(""), do: :null

  defp unser_meta(ser) do
    case PhpBeam.Builtin.SerializeFns.unserialize_value(ser, 0, PhpBeam.Interp.repl_init() |> elem(1)) do
      {:ok, v, _} -> v
      _ -> :null
    end
  end

  # archive opening: detect format by extension + magic
  defp open_archive(obj, path, data?, i) do
    with {:ok, bin} <- File.read(path) do
      fmt =
        cond do
          not data? and String.contains?(bin, "__HALT_COMPILER") -> :phar
          String.ends_with?(path, ".zip") -> :zip
          true -> :tar
        end

      case fmt do
        :phar ->
          case PhpBeam.Classes.PharFormat.parse(bin) do
            {:ok, parsed, _} ->
              es =
                Enum.map(parsed.entries, fn e ->
                  {e.name, PhpBeam.Classes.PharFormat.entry_data(bin, e)}
                end)

              s = %{
                path: path,
                fmt: :phar,
                bin: bin,
                entries: es,
                stub: parsed.stub,
                alias: parsed.alias,
                meta: parsed.meta,
                sig_hash: parsed.sig_hash,
                sig_type: parsed.sig_type
              }

              {:ok, {:bool, true}, Map.put(obj, :dt_state, s), i}

            {:error, msg} ->
              phar_exc(i, msg)
          end

        :tar ->
          case :erl_tar.extract({:binary, bin}, [:memory]) do
            {:ok, files} ->
              es = Enum.map(files, fn {n, b} -> {List.to_string(n), b} end)

              s = %{path: path, fmt: :tar, bin: bin, entries: es, stub: "", alias: "", meta: ""}
              {:ok, {:bool, true}, Map.put(obj, :dt_state, s), i}

            _ ->
              phar_exc(i, "phar error: invalid tar archive \"#{path}\"")
          end

        :zip ->
          case zip_entries(bin) do
            {:ok, es} ->
              s = %{path: path, fmt: :zip, bin: bin, entries: es, stub: "", alias: "", meta: ""}
              {:ok, {:bool, true}, Map.put(obj, :dt_state, s), i}

            _ ->
              phar_exc(i, "phar error: invalid zip archive \"#{path}\"")
          end
      end
    else
      _ ->
        if String.ends_with?(path, ".phar") and Map.get(i.ini, "phar.readonly", "1") != "0" do
          phar_exc(i, "creating archive \"#{path}\" disabled by the php.ini setting phar.readonly")
        else
          s = %{path: path, fmt: if(data?, do: :tar, else: :phar), bin: "", entries: [], stub: "", alias: "", meta: ""}
          {:ok, {:bool, true}, Map.put(obj, :dt_state, s), i}
        end
    end
  end

  defp zip_entries(bin) do
    tmp = "/tmp/phbeam_zip_#{:erlang.unique_integer([:positive])}.zip"

    with :ok <- File.write(tmp, bin),
         {:ok, listing} <- :zip.list_dir(String.to_charlist(tmp)) do
      names =
        listing
        |> Enum.filter(&is_tuple(&1) and elem(&1, 0) == :zip_file)
        |> Enum.map(fn t -> List.to_string(elem(t, 1)) end)

      with {:ok, bins} <-
             :zip.extract(String.to_charlist(tmp),
               [:memory, {:file_list, Enum.map(names, &String.to_charlist/1)}]
             ) do
        File.rm(tmp)
        {:ok, Enum.map(bins, fn {n, b} -> {List.to_string(n), b} end)}
      else
        _ -> {:error, :zip}
      end
    else
      _ -> {:error, :zip}
    end
  end

  defp phar_exc(i, msg) do
    i2 = PhpBeam.Interp.push_frame(i, "Phar::__construct", [])

    {obj, i3} =
      Eval.materialize_native({:native_error, "UnexpectedValueException", msg}, i2)

    {:unwind, {:php_throw, obj}, nil, i3}
  end

  defp find_entry(obj, name) do
    Enum.find(Map.get(st(obj), :entries, []), fn {n, _} -> n == name end)
  end

  defp entry_bytes(obj, {_name, data}), do: data

  defp put_entry(obj, name, data) do
    s = st(obj)
    es = List.keystore(Map.get(s, :entries, []), name, 0, {name, data})
    Map.put(obj, :dt_state, Map.put(s, :entries, es))
  end

  defp file_info(i, base, entry, data) do
    {ref, i2} = Eval.make_instance(i, "pharfileinfo")
    o = Eval.get_object(i2, ref)

    props =
      PArray.from_pairs([
        {"path", {:string, "phar://" <> base <> "/" <> entry}}
      ])

    s = %{data: data, size: byte_size(data)}
    i3 = Eval.put_object(i2, ref, o |> Map.put(:props, props) |> Map.put(:dt_state, s))
    {ref, i3}
  end
end
