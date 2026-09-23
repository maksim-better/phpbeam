defmodule PhpBeam.Builtin.FileFns do
  @moduledoc """
  Filesystem builtins (string-based). The fopen/fread resource-stream
  family needs a resource value type and comes later.
  """

  alias PhpBeam.{PArray, Value}

  @file_append 8

  def register(fns) do
    entries = %{
      "file_get_contents" => &file_get_contents/2,
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

  defp file_get_contents(vals, i) do
    case vals do
      [{:string, path} | _] ->
        case File.read(path) do
          {:ok, s} ->
            {:ok, {:string, s}, i}

          {:error, _} ->
            {:ok, {:bool, false},
             warn(
               i,
               "file_get_contents(#{path}): Failed to open stream: No such file or directory"
             )}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp file_put_contents(vals, i) do
    case vals do
      [{:string, path}, data | rest] ->
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
            {:ok, {:bool, false},
             warn(
               i,
               "file_put_contents(#{path}): Failed to open stream: No such file or directory"
             )}
        end

      _ ->
        {:ok, {:bool, false}, i}
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
    case File.stat(path) do
      {:ok, %{size: sz}} -> {:ok, {:int, sz}, i}
      {:error, _} -> {:ok, {:bool, false}, warn(i, "filesize(): stat failed for #{path}")}
    end
  end

  defp filesize_v(_, i), do: {:ok, {:bool, false}, i}

  defp realpath_v([{:string, path} | _], i) do
    if File.exists?(path),
      do: {:ok, {:string, Path.absname(path)}},
      else: {:ok, {:bool, false}, i}
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
      :ok -> {:ok, {:bool, true}, i}
      {:error, _} -> {:ok, {:bool, false}, warn(i, "unlink(#{path}): No such file or directory")}
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
