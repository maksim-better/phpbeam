defmodule PhpBeam.Builtin.FileFns do
  @moduledoc """
  Filesystem builtins (string-based). The fopen/fread resource-stream
  family needs a resource value type and comes later.
  """

  alias PhpBeam.{PArray, Value}
  alias PhpBeam.Eval.Error

  @file_append 8

  def register(fns) do
    entries = %{
      "stream_resolve_include_path" => &resolve_include_path/2,
      "file_get_contents" => &file_get_contents/2,
      "is_uploaded_file" => &is_uploaded_file_v/2,
      "move_uploaded_file" => &move_uploaded_file_v/2,
      "file_put_contents" => &file_put_contents/2,
      "file_exists" => &file_exists/2,
      "is_file" => &is_file_v/2,
      "is_dir" => &is_dir_v/2,
      "is_readable" => &is_readable/2,
      "is_writable" => &is_writable/2,
      "is_writeable" => &is_writable/2,
      "filesize" => &filesize_v/2,
      "unlink" => &unlink_v/2,
      "mkdir" => &mkdir_v/2,
      "rmdir" => &rmdir_v/2,
      "touch" => &touch_v/2,
      "realpath" => &realpath_v/2,
      "tempnam" => &tempnam/2,
      "copy" => &copy_v/2,
      "rename" => &rename_v/2,
      "getcwd" => &getcwd/2,
      "scandir" => &scandir/2
    }

    Enum.reduce(entries, fns, fn {name, fun}, acc ->
      Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
    end)
  end

  ## ─────────────────────────── contents ───────────────────────────

  # php: search include_path entries for the file; false when absent
  defp resolve_include_path(vals, i) do
    case vals do
      [{:string, rel} | _] ->
        dirs =
          (i.ini["include_path"] || ".")
          |> String.split(":", trim: true)

        hit =
          Enum.find_value(dirs, fn d ->
            full = if d == ".", do: rel, else: Path.join(d, rel)

            if File.exists?(full),
              do: {:string, PhpBeam.Interp.real_path(full)}
          end)

        {:ok, hit || {:bool, false}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp file_get_contents(vals, i) do
    case vals do
      [{:string, path} | _] ->
        case read_wrapper_uri(path, i) do
          {:ok, s} when is_binary(s) ->
            {:ok, {:string, s}, i}

          :error ->
            case File.read(path) do
              {:ok, s} ->
                {:ok, {:string, s}, i}

              {:error, _} ->
                case Error.warn(
                       Error.stub_env(),
                       i,
                       "file_get_contents(#{path}): Failed to open stream: No such file or directory"
                     ) do
                  {:cont, _, i2} -> {:ok, {:bool, false}, i2}
                  {:unwind, u, _, i2} -> {:unwind, u, i2}
                end
            end
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  # public gateway for sibling builtins (md5_file & co.)
  def read_wrapper_public(path, i), do: read_wrapper_uri(path, i)

  # wrapper dispatch for full-read builtins; :error falls back to the
  # filesystem arm (which renders php's warning)
  defp read_wrapper_uri(path, i) do
    case PhpBeam.StreamWrapper.parse(path) do
      {:data, payload} -> {:ok, payload}
      {:memory, _} -> {:ok, ""}
      {:input} -> {:ok, input_body(i)}
      {:filter, rchain, _wchain, inner} -> read_filtered(rchain, inner, i)
      {:phar_file, phar, entry} -> read_phar_entry(phar, entry)
      {:zlib_file, file} -> read_zlib_file(file)
      {:zip_file, zip, entry} -> read_zip_entry(zip, entry)
      _ -> :error
    end
  end

  defp read_phar_entry(phar, entry) do
    with {:ok, bin} <- File.read(phar),
         {:ok, parsed, _} <- PhpBeam.Classes.PharFormat.parse(bin),
         e when e != nil <- Enum.find(parsed.entries, &(&1.name == entry)) do
      {:ok, PhpBeam.Classes.PharFormat.entry_data(bin, e)}
    else
      _ -> :error
    end
  end

  defp read_zlib_file(file) do
    with {:ok, bin} <- File.read(file) do
      z = :zlib.open()
      :ok = :zlib.inflateInit(z, 31)

      out =
        try do
          IO.iodata_to_binary(:zlib.inflate(z, bin))
        catch
          _, _ -> ""
        after
          :zlib.close(z)
        end

      {:ok, out}
    else
      _ -> :error
    end
  end

  defp read_zip_entry(zip, entry) do
    with {:ok, listing} <- :zip.list_dir(String.to_charlist(zip)) do
      names =
        listing
        |> Enum.filter(&is_tuple(&1) and elem(&1, 0) == :zip_file)
        |> Enum.map(fn t -> List.to_string(elem(t, 1)) end)

      if entry == "" do
        # bare zip:// lists nothing readable; php needs the #entry part
        :error
      else
        with {:ok, bins} <-
               :zip.extract(String.to_charlist(zip),
                 [:memory, {:file_list, [String.to_charlist(entry)]}]
               ) do
          case bins do
            [{_, data}] -> {:ok, data}
            _ -> :error
          end
        else
          _ -> :error
        end
      end
    else
      _ -> :error
    end
  end

  defp read_filtered(rchain, inner_uri, i) do
    case read_wrapper_uri(inner_uri, i) do
      {:ok, data} -> {:ok, PhpBeam.StreamWrapper.apply_chain(data, rchain)}
      :error -> :error
    end
  end

  defp input_body(i) do
    case Map.get(i.globals, "\0input_body") do
      {:string, b} -> b
      _ -> ""
    end
  end

  # upload validation rides the request's tmp-file registry (\0uploaded_files)
  defp is_uploaded_file_v(vals, i) do
    case vals do
      [{:string, path} | _] -> {:ok, {:bool, uploaded?(path, i)}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp uploaded?(path, i) do
    case Map.get(i.globals, "\0uploaded_files") do
      {:array, arr} ->
        arr |> PhpBeam.PArray.values() |> Enum.any?(&match?({:string, ^path}, &1))

      _ ->
        false
    end
  end

  defp move_uploaded_file_v(vals, i) do
    case vals do
      [{:string, from}, {:string, to} | _] ->
        if uploaded?(from, i) and File.exists?(from) do
          case File.cp(from, to) do
            :ok -> {:ok, {:bool, true}, i}
            _ -> {:ok, {:bool, false}, i}
          end
        else
          case Error.warn(
                 Error.stub_env(),
                 i,
                 "move_uploaded_file(): Argument #1 ($from) is not a valid upload"
               ) do
            {:cont, _, i2} -> {:ok, {:bool, false}, i2}
            {:unwind, u, _, i2} -> {:unwind, u, i2}
          end
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  # php://output rides ob; php://stdout BYPASSES it (write_direct);
  # php://memory/data write to a fresh discarded stream — php still reports
  # the byte count
  defp write_wrapper_uri(path) do
    case PhpBeam.StreamWrapper.parse(path) do
      {:output} -> :written
      {:memory, _} -> :discarded
      {:std, :stdout} -> :direct
      {:std, :stderr} -> :stderr
      {:data, _} -> {:ok, :discarded}
      {:filter, _r, _w, _inner} -> :discarded
      _ -> :fs
    end
  end

  defp put_contents_str({:array, arr}),
    do: arr |> PArray.values() |> Enum.map_join(&Value.cast_string_unsafe/1)

  defp put_contents_str(other), do: Value.cast_string_unsafe(other)

  defp apply_wrapper_write(path, data, i) do
    contents = put_contents_str(data)

    case write_wrapper_uri(path) do
      :written -> PhpBeam.Interp.write(i, contents)
      :direct -> PhpBeam.Interp.write_direct(i, contents)
      :stderr -> IO.write(:standard_error, contents)
      _ -> i
    end
  end

  defp file_put_contents(vals, i) do
    case vals do
      [{:string, path}, data | rest] ->
        case write_wrapper_uri(path) do
          kind when kind in [:written, :direct, :discarded, :stderr] ->
            {:ok, {:int, byte_size(put_contents_str(data))}, apply_wrapper_write(path, data, i)}

          :fs ->
            file_put_contents_fs(path, data, rest, i)
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp file_put_contents_fs(path, data, rest, i) do
    append? =
      case rest do
        [{:int, flags} | _] -> Bitwise.band(flags, @file_append) != 0
        _ -> false
      end

    contents =
      case data do
        {:array, arr} ->
          arr |> PArray.values() |> Enum.map_join(&Value.cast_string_unsafe/1)

        other ->
          Value.cast_string_unsafe(other)
      end

    result =
      if append? and File.exists?(path) do
        File.write(path, contents, [:append])
      else
        File.write(path, contents)
      end

    case result do
      :ok ->
        {:ok, {:int, byte_size(contents)}, i}

      {:error, _} ->
        case Error.warn(
               Error.stub_env(),
               i,
               "file_put_contents(#{path}): Failed to open stream: No such file or directory"
             ) do
          {:cont, _, i2} -> {:ok, {:bool, false}, i2}
          {:unwind, u, _, i2} -> {:unwind, u, i2}
        end
    end
  end

  ## ─────────────────────────── queries ───────────────────────────

  defp file_exists([{:string, path} | _], i), do: {:ok, {:bool, File.exists?(path)}, i}
  defp file_exists(_, i), do: {:ok, {:bool, false}, i}

  defp is_file_v([{:string, path} | _], i), do: {:ok, {:bool, File.regular?(path)}, i}
  defp is_file_v(_, i), do: {:ok, {:bool, false}, i}

  defp is_dir_v([{:string, path} | _], i), do: {:ok, {:bool, File.dir?(path)}, i}
  defp is_dir_v(_, i), do: {:ok, {:bool, false}, i}

  defp is_readable([{:string, path} | _], i), do: {:ok, {:bool, File.exists?(path)}, i}
  defp is_readable(_, i), do: {:ok, {:bool, false}, i}

  defp is_writable([{:string, path} | _], i), do: {:ok, {:bool, File.exists?(path)}, i}
  defp is_writable(_, i), do: {:ok, {:bool, false}, i}

  defp filesize_v([{:string, path} | _], i) do
    # wrapper targets (phar:// etc.) measure the wrapper content
    case read_wrapper_uri(path, i) do
      {:ok, data} when is_binary(data) ->
        {:ok, {:int, byte_size(data)}, i}

      :error ->
        filesize_plain(path, i)
    end
  end

  defp filesize_plain(path, i) do
    case File.stat(path) do
      {:ok, %{size: sz}} ->
        {:ok, {:int, sz}, i}

      {:error, _} ->
        case Error.warn(Error.stub_env(), i, "filesize(): stat failed for #{path}") do
          {:cont, _, i2} -> {:ok, {:bool, false}, i2}
          {:unwind, u, _, i2} -> {:unwind, u, i2}
        end
    end
  end

  defp filesize_v(_, i), do: {:ok, {:bool, false}, i}

  defp realpath_v([{:string, path} | _], i) do
    if File.exists?(path) do
      {:ok, {:string, PhpBeam.Interp.real_path(Path.absname(path))}, i}
    else
      {:ok, {:bool, false}, i}
    end
  end

  defp realpath_v(_, i), do: {:ok, {:bool, false}, i}

  defp getcwd(_vals, i), do: {:ok, {:string, File.cwd!()}, i}

  defp scandir([{:string, path} | _], i) do
    case File.ls(path) do
      {:ok, names} ->
        arr = PArray.from_pairs(Enum.map(Enum.sort([".", ".." | names]), &{nil, {:string, &1}}))
        {:ok, {:array, arr}, i}

      {:error, _} ->
        {:ok, {:bool, false}, i}
    end
  end

  defp scandir(_, i), do: {:ok, {:bool, false}, i}

  ## ─────────────────────────── mutations ───────────────────────────

  defp unlink_v([{:string, path} | _], i) do
    case File.rm(path) do
      :ok ->
        {:ok, {:bool, true}, i}

      {:error, _} ->
        case Error.warn(Error.stub_env(), i, "unlink(#{path}): No such file or directory") do
          {:cont, _, i2} -> {:ok, {:bool, false}, i2}
          {:unwind, u, _, i2} -> {:unwind, u, i2}
        end
    end
  end

  defp unlink_v(_, i), do: {:ok, {:bool, false}, i}

  defp mkdir_v([{:string, path} | rest], i) do
    recursive? =
      case rest do
        [_, _, {:bool, true} | _] -> true
        [_, _, {:int, n} | _] when n != 0 -> true
        _ -> false
      end

    result = if recursive?, do: File.mkdir_p(path), else: File.mkdir(path)

    case result do
      :ok -> {:ok, {:bool, true}, i}
      {:error, _} -> {:ok, {:bool, false}, i}
    end
  end

  defp mkdir_v(_, i), do: {:ok, {:bool, false}, i}

  defp rmdir_v([{:string, path} | _], i) do
    case File.rmdir(path) do
      :ok -> {:ok, {:bool, true}, i}
      {:error, _} -> {:ok, {:bool, false}, i}
    end
  end

  defp rmdir_v(_, i), do: {:ok, {:bool, false}, i}

  defp touch_v([{:string, path} | _], i) do
    case File.touch(path) do
      :ok -> {:ok, {:bool, true}, i}
      {:error, _} -> {:ok, {:bool, false}, i}
    end
  end

  defp touch_v(_, i), do: {:ok, {:bool, false}, i}

  defp copy_v([{:string, from}, {:string, to} | _], i) do
    case File.cp(from, to) do
      :ok -> {:ok, {:bool, true}, i}
      {:error, _} -> {:ok, {:bool, false}, i}
    end
  end

  defp copy_v(_, i), do: {:ok, {:bool, false}, i}

  defp rename_v([{:string, from}, {:string, to} | _], i) do
    case File.rename(from, to) do
      :ok -> {:ok, {:bool, true}, i}
      {:error, _} -> {:ok, {:bool, false}, i}
    end
  end

  defp rename_v(_, i), do: {:ok, {:bool, false}, i}

  defp tempnam([{:string, dir}, {:string, prefix} | _], i) do
    dir = if dir == "", do: System.tmp_dir!(), else: dir
    path = Path.join(dir, "#{prefix}#{:erlang.unique_integer([:positive])}")

    case File.write(path, "") do
      :ok -> {:ok, {:string, path}, i}
      {:error, _} -> {:ok, {:bool, false}, i}
    end
  end

  defp tempnam(_, i), do: {:ok, {:bool, false}, i}

  defp warn(i, msg), do: PhpBeam.Interp.warn(i, msg)
end
