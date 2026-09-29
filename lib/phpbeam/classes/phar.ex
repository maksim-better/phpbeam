defmodule PhpBeam.Classes.PharFormat do
  @moduledoc """
  The .phar file format (php-src ext/phar/phar.c byte layout):

      stub (ends at `__HALT_COMPILER();` + optional `?>` + \\r\\n)
      manifest_len: u32le
      manifest:
        entry_count: u32le
        api_version: u16 (1.1.0)
        manifest_flags: u32le (bit 0x10000 = signed)
        alias_len: u32le + alias
        metadata_len: u32le + serialize()
        per entry:
          filename_len: u32le + name (trailing / marks a dir)
          uncompressed_size: u32le
          timestamp: u32le
          compressed_size: u32le
          crc32: u32le
          flags: u32le (0x1000 gz / 0x2000 bz2 + perm bits)
          metadata_len: u32le + serialize()
      entry data blobs (laid out in manifest order from
        halt_offset + manifest_len + 4)
      [signature when signed: hash + sig_flags u32le + "GBMB"]

  php 8.4 signs with SHA-256 by default (sig flag 0x0003). Reader verifies
  the hash and per-entry CRC lazily (signature match skips CRC, like php).
  """

  defstruct [
    :stub,
    :alias,
    :meta,
    :sig_hash,
    :sig_type,
    entries: [],
    signed?: false
  ]

  @halt_marker "__HALT_COMPILER();"

  @sig_types %{0x0001 => "MD5", 0x0002 => "SHA-1", 0x0003 => "SHA-256", 0x0004 => "SHA-512"}
  @sig_algos %{
    0x0001 => :md5,
    0x0002 => :sha,
    0x0003 => :sha256,
    0x0004 => :sha512
  }
  @sig_lens %{0x0001 => 16, 0x0002 => 20, 0x0003 => 32, 0x0004 => 64}

  def sig_type_name(0x0001), do: "MD5"
  def sig_type_name(0x0002), do: "SHA-1"
  def sig_type_name(0x0003), do: "SHA-256"
  def sig_type_name(0x0004), do: "SHA-512"
  def sig_type_name(_), do: "OpenSSL"

  # ────────────────────────── parse ──────────────────────────

  @doc "{:ok, %__MODULE__{}, halt_offset} | {:error, msg}"
  def parse(bin) when is_binary(bin) do
    with {:ok, halt_off} <- find_halt(bin),
         {:ok, base} <- parse_manifest(bin, halt_off) do
      {:ok, base, halt_off}
    end
  end

  # halt_offset lands right after the marker + optional `?>` + \r\n
  defp find_halt(bin) do
    case :binary.match(bin, @halt_marker) do
      {pos, len} ->
        rest = binary_part(bin, pos + len, byte_size(bin) - pos - len)
        {:ok, pos + len + tail_skip(rest)}

      :nomatch ->
        {:error, "internal corruption of phar (no __HALT_COMPILER() declaration)"}
    end
  end

  # after the marker php tolerates whitespace, one `?>`, more whitespace
  defp tail_skip(rest), do: do_tail_skip(rest, false)

  defp do_tail_skip("?>" <> rest, _seen_tag), do: 2 + do_tail_skip(rest, true)

  defp do_tail_skip(<<c, rest::binary>>, _) when c in [32, 9, 13, 10] do
    1 + do_tail_skip(rest, true)
  end

  defp do_tail_skip(_, _), do: 0

  defp parse_manifest(bin, halt_off) do
    base = halt_off

    with {:ok, manifest_len} <- u32(bin, base),
         manifest_start = base + 4,
         true <- manifest_len >= 18 or {:error, "internal corruption of phar (truncated manifest header)"},
         mbuf = binary_part(bin, manifest_start, manifest_len),
         true <- byte_size(mbuf) == manifest_len or
                   {:error, "internal corruption of phar (truncated manifest header)"},
         {:ok, count} <- u32(mbuf, 0),
         true <- count > 0 or {:error, "phar manifest claims to have zero entries"},
         <<api::16-little, flags::32-little>> = binary_part(mbuf, 4, 6),
         {:ok, alias_len} <- u32(mbuf, 10),
         alias = binary_part(mbuf, 14, alias_len),
         p0 = 14 + alias_len,
         {:ok, meta_len} <- u32(mbuf, p0),
         meta = binary_part(mbuf, p0 + 4, meta_len),
         {:ok, entries, entries_end} <- parse_entries(mbuf, p0 + 4 + meta_len, count, []) do
      data_off = manifest_start + manifest_len

      # absolute data offsets accumulate by compressed size in manifest order
      entries_abs = assign_offsets(entries, data_off)

      {sig_hash, sig_type, signed?} = read_signature(bin)

      phar = %__MODULE__{
        stub: binary_part(bin, 0, base),
        alias: alias,
        meta: meta,
        sig_hash: sig_hash,
        sig_type: sig_type,
        signed?: signed?,
        entries: entries_abs
      }

      verify_signature(bin, phar)
    else
      {:error, _} = e -> e
      false -> {:error, "internal corruption of phar (truncated manifest header)"}
    end
  end

  defp parse_entries(_mbuf, off, 0, acc), do: {:ok, Enum.reverse(acc), off}

  defp parse_entries(mbuf, off, n, acc) do
    with {:ok, name_len} <- u32(mbuf, off),
         name = binary_part(mbuf, off + 4, name_len),
         p = off + 4 + name_len,
         {:ok, usize} <- u32(mbuf, p),
         {:ok, ts} <- u32(mbuf, p + 4),
         {:ok, csize} <- u32(mbuf, p + 8),
         {:ok, crc} <- u32(mbuf, p + 12),
         {:ok, eflags} <- u32(mbuf, p + 16),
         {:ok, meta_len} <- u32(mbuf, p + 20),
         emeta = binary_part(mbuf, p + 24, meta_len),
         is_dir? = String.ends_with?(name, "/"),
         name2 = if(is_dir?, do: binary_part(name, 0, byte_size(name) - 1), else: name) do
      entry = %{
        name: name2,
        dir?: is_dir?,
        usize: usize,
        ts: ts,
        csize: csize,
        crc: crc,
        flags: eflags,
        meta: emeta,
        offset: 0
      }

      parse_entries(mbuf, p + 24 + meta_len, n - 1, [entry | acc])
    else
      _ -> {:error, "internal corruption of phar (truncated manifest entry)"}
    end
  end

  defp assign_offsets(entries, data_off) do
    {out, _} =
      Enum.map_reduce(entries, data_off, fn e, off ->
        {%{e | offset: off}, off + e.csize}
      end)

    out
  end

  defp read_signature(bin) do
    size = byte_size(bin)

    if size >= 8 do
      case u32(bin, size - 8) do
        {:ok, flags} ->
          len = Map.get(@sig_lens, flags)

          if len && size >= 8 + len do
            hash = binary_part(bin, size - 8 - len, len)
            {String.upcase(Base.encode16(hash)), flags, true}
          else
            {nil, nil, false}
          end

        :error ->
          {nil, nil, false}
      end
    else
      {nil, nil, false}
    end
  catch
    _, _ -> {nil, nil, false}
  end

  defp verify_signature(bin, phar) do
    if phar.signed? do
      algo = Map.get(@sig_algos, phar.sig_type)
      len = Map.get(@sig_lens, phar.sig_type)
      signed_len = byte_size(bin) - 8 - len

      computed =
        :crypto.hash(algo, binary_part(bin, 0, signed_len)) |> Base.encode16(case: :upper)

      if computed == phar.sig_hash do
        {:ok, phar}
      else
        {:error, "phar has a broken signature"}
      end
    else
      # phar.require_hash defaults on — unsigned phars fail to open
      {:error, "phar does not have a signature"}
    end
  end

  defp u32(bin, off) when off + 4 <= byte_size(bin) do
    <<v::32-little>> = binary_part(bin, off, 4)
    {:ok, v}
  rescue
    _ -> :error
  end

  defp u32(_, _), do: :error

  # ────────────────────────── build ──────────────────────────

  @doc """
  Serialize a phar archive: stub must end with `__HALT_COMPILER(); ?>\\r\\n`
  (stubify adds it when missing); entries are raw (no per-entry compression
  yet); signed with SHA-256 like php 8.4's default.
  """
  def build(stub, entries, meta \\ "", alias \\ "") do
    manifest = build_manifest(entries, meta, alias)
    data = Enum.map_join(entries, "", & &1.data)
    halt_off = byte_size(stub)
    signed_region = stub <> <<byte_size(manifest)::32-little>> <> manifest <> data
    hash = :crypto.hash(:sha256, signed_region)

    # tail: hash + sig_flags u32le + "GBMB" (php-src phar.c, no length field
    # for the hash-based signatures)
    signed_region <> hash <> <<0x0003::32-little>> <> "GBMB"
  end

  defp build_manifest(entries, meta, alias) do
    alias_b = to_string(alias)
    meta_b = to_string(meta)

    entry_bins =
      Enum.map_join(entries, fn e ->
        name_b = to_string(e.name) <> if(e[:dir?], do: "/", else: "")
        data = e[:data] || ""
        crc = :erlang.crc32(data)

        <<byte_size(name_b)::32-little>> <> name_b <> <<byte_size(data)::32-little>> <>
          <<e[:ts] || 0 |> then(&Kernel.max(&1, 0))::32-little>> <>
          <<byte_size(data)::32-little>> <> <<crc::32-little>> <>
          <<e[:flags] || 0x140::32-little>> <>
          <<byte_size(e[:meta] || "")::32-little>> <> (e[:meta] || "")
      end)

    body =
      <<length(entries)::32-little>> <> <<0x1110::16-little>> <>
        <<0x00010000::32-little>> <>
        <<byte_size(alias_b)::32-little>> <> alias_b <>
        <<byte_size(meta_b)::32-little>> <> meta_b <> entry_bins

    body
  end

  @doc "extract one entry's bytes (gz entries inflate on read)"
  def entry_data(bin, entry) when is_binary(bin) do
    raw = binary_part(bin, entry.offset, entry.csize)

    case Bitwise.band(entry.flags, 0xF000) do
      0x1000 ->
        z = :zlib.open()
        :ok = :zlib.inflateInit(z, -15)
        out = :zlib.inflate(z, raw)
        :zlib.close(z)
        IO.iodata_to_binary(out)

      0x2000 ->
        # bz2 deferred (no :bzip2 on this OTP)
        raw

      _ ->
        raw
    end
  rescue
    _ -> binary_part(bin, entry.offset, entry.csize)
  end
end
