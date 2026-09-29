defmodule PhpBeam.Builtin.ZipFns do
  @moduledoc """
  ext/zlib's legacy zip_* function API (deprecated since php 8.0 — every
  entry emits its exact `Deprecated: Function X() is deprecated since 8.0,
  use Y instead` warning, probed). Resources: the archive handle and the
  entry handle both live in interp.resources.
  """

  alias PhpBeam.Eval

  # the probed deprecation texts
  @depr %{
    "zip_open" => "zip_open() is deprecated since 8.0, use ZipArchive::open() instead",
    "zip_read" => "zip_read() is deprecated since 8.0, use ZipArchive::statIndex() instead",
    "zip_entry_name" => "zip_entry_name() is deprecated since 8.0, use ZipArchive::statIndex() instead",
    "zip_entry_filesize" => "zip_entry_filesize() is deprecated since 8.0, use ZipArchive::statIndex() instead",
    "zip_entry_compressedsize" =>
      "zip_entry_compressedsize() is deprecated since 8.0, use ZipArchive::statIndex() instead",
    "zip_entry_compressionmethod" =>
      "zip_entry_compressionmethod() is deprecated since 8.0, use ZipArchive::statIndex() instead",
    "zip_entry_open" => "zip_entry_open() is deprecated since 8.0",
    "zip_entry_read" => "zip_entry_read() is deprecated since 8.0, use ZipArchive::getFromIndex() instead",
    "zip_entry_close" => "zip_entry_close() is deprecated since 8.0",
    "zip_close" => "zip_close() is deprecated since 8.0, use ZipArchive::close() instead"
  }

  def register(fns) do
    entries = %{
      "zip_open" => &zip_open/2,
      "zip_read" => &zip_read/2,
      "zip_entry_name" => &zip_entry_name/2,
      "zip_entry_filesize" => &zip_entry_filesize/2,
      "zip_entry_compressedsize" => &zip_entry_compressedsize/2,
      "zip_entry_compressionmethod" => &zip_entry_compressionmethod/2,
      "zip_entry_open" => &zip_entry_open/2,
      "zip_entry_read" => &zip_entry_read/2,
      "zip_entry_close" => &zip_entry_close/2,
      "zip_close" => &zip_close/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, wrapped)
  end

  defp deprecate(i, fname) do
    case PhpBeam.Eval.Error.warn_level(
           PhpBeam.Eval.Error.stub_env(),
           i,
           "Deprecated",
           "Function " <> Map.get(@depr, fname)
         ) do
      {:cont, _, i2} -> {:ok, i2}
      {:unwind, u, _, i2} -> {:unwind, u, i2}
    end
  end

  # archive resource: %{zip_entries: [{name, bin}], zip_idx: 0, closed: false}
  # entry resource: %{zip_ent: {name, bin}, zip_open?: true, closed: false}

  defp zip_open(vals, i) do
    with {:ok, i} <- deprecate(i, "zip_open") do
      path = Eval.php_to_string(hd(vals || [:null]))

      case :zip.list_dir(String.to_charlist(path)) do
        {:ok, listing} ->
          names =
            listing
            # :zip_file arity varies by OTP; match on the tag only
            |> Enum.filter(&is_tuple(&1) and elem(&1, 0) == :zip_file)
            |> Enum.map(fn t -> List.to_string(elem(t, 1)) end)

          with {:ok, bins} <-
                 :zip.extract(String.to_charlist(path),
                   [:memory, {:file_list, Enum.map(names, &String.to_charlist/1)}]
                 ) do
            es = Enum.map(bins, fn {n, b} -> {List.to_string(n), b} end)

            {{:resource, id}, i2} =
              PhpBeam.Interp.open_resource(i, %{zip_entries: es, zip_idx: 0, closed: false})

            {:ok, {:resource, id}, i2}
          else
            _ -> {:ok, {:int, 19}, i}
          end

        _ ->
          # probed: missing archive yields the libzip error CODE (int 9),
          # not false
          {:ok, {:int, 9}, i}
      end
    end
  end

  defp zip_read(vals, i) do
    with {:ok, i} <- deprecate(i, "zip_read") do
      case vals do
        [{:resource, id} | _] ->
          case Map.get(i.resources, id) do
            %{zip_entries: es, zip_idx: idx, closed: false} = res ->
              case Enum.at(es, idx) do
                nil ->
                  {:ok, {:bool, false}, i}

                {name, bin} ->
                  i2 =
                    PhpBeam.Interp.put_resource(
                      i,
                      id,
                      res |> Map.put(:zip_idx, idx + 1) |> Map.put(:zip_last, {name, bin})
                    )

                  {{:resource, eid}, i3} =
                    PhpBeam.Interp.open_resource(i2, %{zip_ent: {name, bin}, closed: false})

                  {:ok, {:resource, eid}, i3}
              end

            _ ->
              {:ok, {:bool, false}, i}
          end

        _ ->
          {:ok, {:bool, false}, i}
      end
    end
  end

  defp entry_of(vals, i) do
    case vals do
      [{:resource, id} | _] ->
        case Map.get(i.resources, id) do
          %{zip_ent: {_, _} = e, closed: false} -> {:ok, e}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp zip_entry_name(vals, i) do
    with {:ok, i} <- deprecate(i, "zip_entry_name"),
         {:ok, {name, _}} <- entry_of(vals, i) do
      {:ok, {:string, name}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp zip_entry_filesize(vals, i) do
    with {:ok, i} <- deprecate(i, "zip_entry_filesize"),
         {:ok, {_, bin}} <- entry_of(vals, i) do
      {:ok, {:int, byte_size(bin)}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp zip_entry_compressedsize(vals, i) do
    with {:ok, i} <- deprecate(i, "zip_entry_compressedsize"),
         {:ok, {_, bin}} <- entry_of(vals, i) do
      {:ok, {:int, byte_size(bin)}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp zip_entry_compressionmethod(vals, i) do
    with {:ok, i} <- deprecate(i, "zip_entry_compressionmethod") do
      # :zip stores uncompressed (deviation note: libzip reports deflate
      # for compressed members; entry contents are kept verbatim)
      {:ok, {:string, "stored"}, i}
    end
  end

  defp zip_entry_open(vals, i) do
    # signature: zip_entry_open(resource $zip, resource $zip_entry) — the
    # entry is the SECOND argument
    with {:ok, i} <- deprecate(i, "zip_entry_open"),
         {:ok, _e} <- entry_of(Enum.drop(vals, 1), i) do
      {:ok, {:bool, true}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp zip_entry_read(vals, i) do
    with {:ok, i} <- deprecate(i, "zip_entry_read"),
         {:ok, {_, bin}} <- entry_of(vals, i) do
      len =
        case Enum.at(vals, 1) do
          {:int, n} when n >= 0 -> n
          _ -> byte_size(bin)
        end

      {:ok, {:string, binary_part(bin, 0, min(len, byte_size(bin)))}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp zip_entry_close(vals, i) do
    with {:ok, i} <- deprecate(i, "zip_entry_close") do
      case vals do
        [{:resource, id} | _] ->
          i2 =
            PhpBeam.Interp.put_resource(
              i,
              id,
              Map.put(Map.get(i.resources, id, %{}), :closed, true)
            )

          {:ok, {:bool, true}, i2}

        _ ->
          {:ok, {:bool, false}, i}
      end
    end
  end

  defp zip_close(vals, i) do
    with {:ok, i} <- deprecate(i, "zip_close") do
      case vals do
        [{:resource, id} | _] ->
          i2 =
            PhpBeam.Interp.put_resource(
              i,
              id,
              Map.put(Map.get(i.resources, id, %{}), :closed, true)
            )

          {:ok, :null, i2}

        _ ->
          {:ok, :null, i}
      end
    end
  end
end
