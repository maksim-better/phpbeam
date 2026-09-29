defmodule PhpBeam.Classes.Zip do
  @moduledoc """
  ext/zip: the ZipArchive class over OTP :zip plus the deprecated legacy
  function API. Instance state lives in dt_state: `%{path:, entries:
  [{name, bin}], index:, mode:, open:, new_names: MapSet, comment:}` —
  entries accumulate while open; close() materializes the archive with
  :zip.create (name order = insertion order, matching libzip's behavior
  for fresh archives). numFiles/status props are synced onto obj.props at
  every mutation so property reads stay engine-native.
  """

  alias PhpBeam.Classes.Table
  alias PhpBeam.Eval
  alias PhpBeam.PArray

  # ────────────────────────── class + registration ──────────────────────────

  # probed from php 8.4's libzip 1.11.2 binding
  @consts %{
    "CREATE" => {:int, 1},
    "EXCL" => {:int, 2},
    "CHECKCONS" => {:int, 4},
    "OVERWRITE" => {:int, 8},
    "FL_NOCASE" => {:int, 1},
    "FL_NODIR" => {:int, 2},
    "FL_ENC_RAW" => {:int, 64},
    "FL_ENC_GUESS" => {:int, 0},
    "FL_ENC_UTF_8" => {:int, 2048},
    "FL_ENC_CP437" => {:int, 4096},
    "FL_OPEN_FILE_NOW" => {:int, 1073741824},
    "FL_OVERWRITE" => {:int, 8192},
    "FL_LOCAL" => {:int, 256},
    "FL_CENTRAL" => {:int, 512},
    "FL_UNCHANGED" => {:int, 8},
    "CM_DEFAULT" => {:int, -1},
    "CM_STORE" => {:int, 0},
    "CM_DEFLATE" => {:int, 8},
    "CM_BZIP2" => {:int, 12},
    "CM_XZ" => {:int, 95},
    "OPSYS_DEFAULT" => {:int, 3},
    "OPSYS_UNIX" => {:int, 3},
    "OPSYS_DOS" => {:int, 0},
    "OPSYS_MACOS" => {:int, 7},
    "OPSYS_NTFS" => {:int, 10},
    "OPSYS_VMS" => {:int, 2},
    "LIBZIP_VERSION" => {:string, "1.11.2"},
    "ER_OK" => {:int, 0},
    "ER_MULTIDISK" => {:int, 1},
    "ER_RENAME" => {:int, 2},
    "ER_CLOSE" => {:int, 3},
    "ER_SEEK" => {:int, 4},
    "ER_READ" => {:int, 5},
    "ER_WRITE" => {:int, 6},
    "ER_CRC" => {:int, 7},
    "ER_ZIPCLOSED" => {:int, 8},
    "ER_NOENT" => {:int, 9},
    "ER_EXISTS" => {:int, 10},
    "ER_OPEN" => {:int, 11},
    "ER_TMPOPEN" => {:int, 12},
    "ER_ZLIB" => {:int, 13},
    "ER_MEMORY" => {:int, 14},
    "ER_CHANGED" => {:int, 15},
    "ER_COMPNOTSUPP" => {:int, 16},
    "ER_EOF" => {:int, 17},
    "ER_INVAL" => {:int, 18},
    "ER_NOZIP" => {:int, 19},
    "ER_INTERNAL" => {:int, 20},
    "ER_INCONS" => {:int, 21},
    "ER_REMOVE" => {:int, 22},
    "ER_DELETED" => {:int, 23},
    "ER_ENCRNOTSUPP" => {:int, 24},
    "ER_RDONLY" => {:int, 25},
    "ER_NOPASSWD" => {:int, 26},
    "ER_WRONGPASSWD" => {:int, 27},
    "ER_OPNOTSUPP" => {:int, 28},
    "ER_INUSE" => {:int, 29},
    "ER_TELL" => {:int, 30}
  }

  def classes do
    %{"ziparchive" => zip_archive_class()}
  end

  defp zip_archive_class do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, _a, i -> {:ok, :null, obj, i} end),
          nfn("open", fn obj, a, i ->
            case do_open(a, i) do
              {:ok, ret, nil, i2} -> {:ok, ret, obj, i2}
              {:ok, ret, state, i2} -> {:ok, ret, put_st(obj, state) |> sync_props(), i2}
              {:unwind, u, nil, i2} -> {:unwind, u, nil, i2}
            end
          end),
          nfn("close", fn obj, a, i -> do_close(obj, a, i) end),
          nfn("count", fn obj, _a, i -> {:ok, {:int, num_files(obj)}, obj, i} end),
          nfn("addemptydir", fn obj, a, i -> add_entry(obj, dir_name(a), "", i) end),
          nfn("addfromstring", fn obj, a, i ->
            case a do
              [name_v, content_v | _] ->
                add_entry(obj, Eval.php_to_string(name_v), Eval.php_to_string(content_v), i)

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("addfile", fn obj, a, i ->
            case a do
              [path_v | _] ->
                path = Eval.php_to_string(path_v)

                case File.read(path) do
                  {:ok, bin} ->
                    name = base_name(path)
                    add_entry(obj, name, bin, i)

                  _ ->
                    warn_zip(i, "ZipArchive::addFile(): Unable to open file: #{path}")
                end

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("getnameindex", fn obj, a, i ->
            idx = int0(a)

            cond do
              MapSet.member?(deleted(obj), idx) -> {:ok, {:bool, false}, obj, i}
              true ->
                case Enum.at(entries(obj), idx) do
                  {name, _} -> {:ok, {:string, name}, obj, i}
                  nil -> {:ok, {:bool, false}, obj, i}
                end
            end
          end),
          nfn("statindex", fn obj, a, i ->
            if MapSet.member?(deleted(obj), int0(a)) do
              {:ok, {:bool, false}, obj, i}
            else
              stat_at(obj, int0(a), i)
            end
          end),
          nfn("statname", fn obj, a, i ->
            name = str0(a)

            idx =
              entries(obj)
              |> Enum.find_index(fn {n, _} -> n == name end)

            case idx do
              nil -> {:ok, {:bool, false}, obj, i}
              k -> stat_at(obj, k, i)
            end
          end),
          nfn("locatename", fn obj, a, i ->
            name = str0(a)
            del = deleted(obj)

            idx =
              entries(obj)
              |> Enum.with_index()
              |> Enum.find_index(fn {{n, _}, k} -> n == name and not MapSet.member?(del, k) end)

            case idx do
              nil -> {:ok, {:bool, false}, obj, i}
              k -> {:ok, {:int, k}, obj, i}
            end
          end),
          nfn("getfromname", fn obj, a, i ->
            name = str0(a)
            del = deleted(obj)

            hit =
              entries(obj)
              |> Enum.with_index()
              |> Enum.find(fn {{n, _}, k} -> n == name and not MapSet.member?(del, k) end)

            case hit do
              {{_, bin}, _} -> {:ok, {:string, bin}, obj, i}
              nil -> {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("getfromindex", fn obj, a, i ->
            case Enum.at(entries(obj), int0(a)) do
              {_, bin} -> {:ok, {:string, bin}, obj, i}
              nil -> {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("renameindex", fn obj, a, i ->
            case a do
              [idx_v, new_v | _] ->
                new = Eval.php_to_string(new_v)

                es =
                  entries(obj)
                  |> List.update_at(int_arg(idx_v), fn {_, bin} -> {new, bin} end)

                {:ok, {:bool, true}, put_entries(obj, es), i}

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("renamename", fn obj, a, i ->
            case a do
              [old_v, new_v | _] ->
                old = Eval.php_to_string(old_v)
                new = Eval.php_to_string(new_v)

                if List.keymember?(entries(obj), old, 0) do
                  es =
                    entries(obj)
                    |> Enum.map(fn
                      {^old, bin} -> {new, bin}
                      e -> e
                    end)

                  {:ok, {:bool, true}, put_entries(obj, es), i}
                else
                  {:ok, {:bool, false}, obj, i}
                end

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("deleteindex", fn obj, a, i ->
            s0 = st(obj)
            d2 = MapSet.put(deleted(obj), int0(a))
            {:ok, {:bool, true}, put_st(obj, Map.put(s0, :deleted, d2)) |> sync_props(), i}
          end),
          nfn("deletename", fn obj, a, i ->
            name = str0(a)
            s0 = st(obj)

            d2 =
              entries(obj)
              |> Enum.with_index()
              |> Enum.filter(fn {{n, _}, _} -> n == name end)
              |> Enum.map(fn {_, k} -> k end)
              |> Enum.reduce(deleted(obj), &MapSet.put(&2, &1))

            {:ok, {:bool, true}, put_st(obj, Map.put(s0, :deleted, d2)) |> sync_props(), i}
          end),
          nfn("getstatusstring", fn obj, _a, i ->
            {:ok, {:string, "No error"}, obj, i}
          end),
          nfn("getarchivecomment", fn obj, _a, i ->
            {:ok, {:string, st(obj)[:comment] || ""}, obj, i}
          end),
          nfn("setarchivecomment", fn obj, a, i ->
            s = st(obj)
            s2 = Map.put(s, :comment, str0(a))
            {:ok, {:bool, true}, put_st(obj, s2), i}
          end),
          nfn("setcompressionname", fn obj, _a, i ->
            # deflate accepted; stored/deflate64 deltas are deferred
            {:ok, {:bool, true}, obj, i}
          end),
          nfn("setcompressionindex", fn obj, _a, i -> {:ok, {:bool, true}, obj, i} end),
          nfn("extractto", fn obj, a, i ->
            dest = str0(a)

            case File.mkdir_p(dest) do
              :ok ->
                results =
                  Enum.map(entries(obj), fn {name, bin} ->
                    out = Path.join(dest, name)
                    File.mkdir_p(Path.dirname(out))
                    File.write(out, bin)
                  end)

                if Enum.all?(results, &(&1 == :ok)),
                  do: {:ok, {:bool, true}, obj, i},
                  else: {:ok, {:bool, false}, obj, i}

              _ ->
                {:ok, {:bool, false}, obj, i}
            end
          end),
          nfn("unchangeall", fn obj, _a, i -> {:ok, {:bool, true}, obj, i} end),
          nfn("clearerror", fn obj, _a, i -> {:ok, {:null, obj}, i} end),
          nfn("getstreamname", fn obj, a, i -> get_stream(obj, str0(a), i) end),
          nfn("getstreamindex", fn obj, a, i ->
            case Enum.at(entries(obj), int0(a)) do
              {name, _} -> get_stream(obj, name, i)
              nil -> {:ok, {:bool, false}, obj, i}
            end
          end)
        ],
        &{&1.name, &1}
      )

    struct!(Table,
      name: "ZipArchive",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: @consts,
      # the two live instance props php exposes (synced by sync_props)
      props: [
        %{name: "numFiles", display: "numFiles", visibility: :public, static?: false,
          readonly?: false, default: {:int, 0}, type: nil},
        %{name: "status", display: "status", visibility: :public, static?: false,
          readonly?: false, default: {:int, 0}, type: nil},
        %{name: "statusSys", display: "statusSys", visibility: :public, static?: false,
          readonly?: false, default: {:int, 0}, type: nil},
        %{name: "filename", display: "filename", visibility: :public, static?: false,
          readonly?: false, default: {:string, ""}, type: nil},
        %{name: "comment", display: "comment", visibility: :public, static?: false,
          readonly?: false, default: :null, type: nil}
      ],
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
      class: "ziparchive",
      line: nil,
      gen?: false,
      native:
        {:native,
         fn obj, vals, i ->
           case fun.(obj, vals, i) do
             {:ok, ret, nil, i2} -> {:ok, {ret, obj}, i2}
             {:ok, ret, obj2, i2} -> {:ok, {ret, obj2}, i2}
             {:unwind, u, nil, i2} -> {{:unwind, u}, nil, i2}
             {:unwind, u, obj2, i2} -> {{:unwind, u}, obj2, i2}
           end
         end}
    }
  end

  # ────────────────────────── state helpers ──────────────────────────

  defp st(obj), do: obj.dt_state || %{open: false}
  defp entries(obj), do: Map.get(st(obj), :entries, [])
  # php's delete is a TOMBSTONE until close: numFiles stays put, slot reads
  # yield false, locateName misses, close compacts (probed)
  defp deleted(obj), do: Map.get(st(obj), :deleted, MapSet.new())
  defp num_files(obj), do: length(entries(obj))

  defp put_st(obj, s), do: Map.put(obj, :dt_state, s)

  defp put_entries(obj, es) do
    obj2 = put_st(obj, Map.put(st(obj), :entries, es))
    sync_props(obj2)
  end

  # numFiles/status mirror onto props for plain property reads
  defp sync_props(obj) do
    props =
      obj.props
      |> put_kv("numFiles", {:int, num_files(obj)})
      |> put_kv("status", {:int, if(st(obj)[:open], do: 0, else: 0)})

    %{obj | props: props}
  end

  # instance_defaults seeds {:string, downcased} keys — property reads go
  # through the same shape, so live values must write that exact slot
  defp put_kv(props, k, v) do
    case PArray.put(props, {:string, String.downcase(k)}, v) do
      {:ok, p} -> p
      _ -> props
    end
  end

  # ────────────────────────── open / close ──────────────────────────

  defp do_open(args, i) do
    case args do
      [path_v, flags_v | _] ->
        path = Eval.php_to_string(path_v)
        flags = int_arg(flags_v)
        open_path(path, flags, i)

      [path_v | _] ->
        open_path(Eval.php_to_string(path_v), 0, i)

      _ ->
        {:ok, {:int, 5}, nil, i}
    end
  end

  defp open_path(path, flags, i) do
    cond do
      File.exists?(path) and Bitwise.band(flags, 2) != 0 ->
        # EXCL on an existing archive
        {:ok, {:int, 10}, nil, i}

      File.exists?(path) ->
        case read_archive(path) do
          {:ok, es} ->
            # status prop set on instance — but open() is static-ish here; the
            # instance binding happens through the caller (obj threading)
            {:ok, {:bool, true}, %{path: path, entries: es, open: true, mode: :rw}, i}

          :error ->
            {:ok, {:int, 19}, nil, i}
        end

      Bitwise.band(flags, 1) != 0 or Bitwise.band(flags, 8) != 0 ->
        {:ok, {:bool, true}, %{path: path, entries: [], open: true, mode: :create}, i}

      true ->
        # ER_NOENT
        {:ok, {:int, 9}, nil, i}
    end
  end

  defp do_close(obj, _a, i) do
    s = st(obj)

    if s[:open] do
      del = Map.get(s, :deleted, MapSet.new())

      live =
        entries(obj)
        |> Enum.with_index()
        |> Enum.reject(fn {_, k} -> MapSet.member?(del, k) end)
        |> Enum.map(fn {e, _} -> e end)

      case :zip.create(String.to_charlist(s.path), Enum.map(live, fn {n, b} -> {String.to_charlist(n), b} end)) do
        {:ok, _} ->
          obj2 = put_st(obj, Map.put(s, :open, false)) |> sync_props()
          {:ok, {:bool, true}, obj2, i}

        {:error, _} ->
          {:ok, {:bool, false}, obj, i}
      end
    else
      {:ok, {:bool, false}, obj, i}
    end
  end

  defp read_archive(path) do
    case :zip.list_dir(String.to_charlist(path)) do
      {:ok, listing} ->
        names =
          listing
          |> Enum.filter(&is_tuple(&1) and elem(&1, 0) == :zip_file)
          |> Enum.map(fn t -> List.to_string(elem(t, 1)) end)
          |> Enum.reject(&String.ends_with?(&1, "/"))

        with {:ok, bins} <-
               :zip.extract(String.to_charlist(path),
                 [:memory, {:file_list, Enum.map(names, &String.to_charlist/1)}]
               ) do
          es =
            Enum.map(bins, fn {cname, bin} ->
              {List.to_string(cname), bin}
            end)

          {:ok, es}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp add_entry(obj, name, bin, i) do
    es = entries(obj) ++ [{name, bin}]
    {:ok, {:bool, true}, put_entries(obj, es), i}
  end

  defp dir_name(a) do
    case a do
      [v | _] -> Eval.php_to_string(v) <> "/"
      _ -> "/"
    end
  end

  defp stat_at(obj, idx, i) do
    case Enum.at(entries(obj), idx) do
      {name, bin} ->
        arr =
          PArray.from_pairs([
            {"name", {:string, name}},
            {"index", {:int, idx}},
            {"crc", {:int, 0}},
            {"size", {:int, byte_size(bin)}},
            {"mtime", {:int, 0}},
            {"comp_size", {:int, byte_size(bin)}},
            {"comp_method", {:int, 0}}
          ])

        {:ok, {:array, arr}, obj, i}

      nil ->
        {:ok, {:bool, false}, obj, i}
    end
  end

  defp get_stream(obj, name, i) do
    case List.keyfind(entries(obj), name, 0) do
      {_, bin} ->
        {{:resource, id}, i2} =
          PhpBeam.Interp.open_resource(i, %{zip_data: bin, zip_pos: 0, closed: false})

        {:ok, {:resource, id}, obj, i2}

      nil ->
        {:ok, {:bool, false}, obj, i}
    end
  end

  defp warn_zip(i, msg) do
    case PhpBeam.Eval.Error.warn(PhpBeam.Eval.Error.stub_env(), i, msg) do
      {:cont, _, i2} -> {:ok, {:bool, false}, nil, i2}
      {:unwind, u, _, i2} -> {:unwind, u, nil, i2}
    end
  end

  defp str0(a), do: (a != [] && Eval.php_to_string(hd(a))) || ""
  defp int0(a), do: int_arg(hd(a || []))

  defp int_arg({:int, n}), do: n
  defp int_arg(_), do: 0

  defp base_name(path), do: Path.basename(path)
end
