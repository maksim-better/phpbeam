defmodule PhpBeam.StreamWrapper do
  @moduledoc """
  URL-wrapper parsing for the stream layer (`fopen`, `file_get_contents`,
  `file_put_contents`, `readfile`): resolves a URI onto a wrapper target.

  Implemented wrappers: `file` (default, no scheme or file://), `php://`
  (memory/temp/stdin/stdout/stderr/output/input/fd/N/filter chains), and
  `data://` (text/plain with optional ;base64). Everything else is
  `{:unsupported, scheme}` — callers render php's warning (unknown wrapper
  vs disabled-by-allow_url_fopen, probed wording) and return false.

  php://filter chains look like
  `php://filter/read=string.toupper|convert.base64-encode/resource=<uri>`
  (read= applied in order on reads, write= on writes).
  """

  @type filter :: String.t()

  @spec parse(String.t()) ::
          {:file, String.t()}
          | {:memory, non_neg_integer() | nil}
          | {:std, :stdin | :stdout | :stderr}
          | {:output}
          | {:input}
          | {:data, String.t()}
          | {:filter, [filter], [filter], String.t()}
          | {:unsupported, String.t() | nil}

  def parse("php://" <> rest), do: parse_php(rest)
  def parse("data://" <> rest), do: parse_data(rest)
  # RFC2397 short form: data:,payload (default media type)
  def parse("data:" <> "," <> payload), do: {:data, payload}
  def parse("file://" <> path), do: {:file, path}

  def parse(uri) do
    case String.split(uri, "://", parts: 2) do
      [scheme, _rest] -> {:unsupported, String.downcase(scheme)}
      _ -> {:file, uri}
    end
  end

  defp parse_php(rest) do
    case String.split(rest, "/", parts: 2) do
      [s] ->
        php_target(String.downcase(s), nil)

      [s, tail] ->
        cond do
          String.downcase(s) == "fd" and tail in ["0", "1", "2"] ->
            {:std, %{0 => :stdin, 1 => :stdout, 2 => :stderr}[String.to_integer(tail)]}

          String.downcase(s) == "filter" ->
            parse_filter(s <> "/" <> tail)

          true ->
            maxmem =
              case Regex.run(~r/^maxmemory:(\d+)$/i, tail) do
                [_, n] -> String.to_integer(n)
                nil -> nil
              end

            php_target(String.downcase(s), maxmem)
        end
    end
  end

  defp php_target(spec, maxmem) do
    case spec do
      "memory" -> {:memory, maxmem}
      "temp" -> {:memory, maxmem}
      "stdin" -> {:std, :stdin}
      "stdout" -> {:std, :stdout}
      "stderr" -> {:std, :stderr}
      "output" -> {:output}
      "input" -> {:input}
      "filter" -> {:unsupported, "php"}
      _ -> {:unsupported, "php"}
    end
  end

  # php://filter/read=CHAIN/write=CHAIN/resource=URI — chains are
  # |-separated filter names, applied in order
  defp parse_filter(spec) do
    parts = String.split(spec, "/", parts: 2)

    case parts do
      [_prefix, args] ->
        {read_chain, write_chain, resource} = filter_args(args, [], [], nil)

        if resource == nil do
          {:unsupported, "php"}
        else
          # chains are built left-to-right already (php applies in order)
          {:filter, read_chain, write_chain, resource}
        end

      _ ->
        {:unsupported, "php"}
    end
  end

  defp filter_args("resource=" <> uri, r, w, _res), do: {r, w, uri}
  defp filter_args("read=" <> chain, r, w, res), do: filter_args_next(chain, r, w, res, :read)
  defp filter_args("write=" <> chain, r, w, res), do: filter_args_next(chain, r, w, res, :write)

  defp filter_args(_, r, w, res), do: {r, w, res}

  defp filter_args_next(chain, r, w, res, which) do
    # the chain ends at the next /resource= boundary
    case String.split(chain, "/resource=", parts: 2) do
      [filters, rest_uri] ->
        names = String.split(filters, "|", trim: true) |> Enum.reject(&(&1 == ""))
        {r2, w2} = if which == :read, do: {r ++ names, w}, else: {r, w ++ names}
        {r2, w2, rest_uri}

      _ ->
        names = String.split(chain, "|", trim: true) |> Enum.reject(&(&1 == ""))
        {r2, w2} = if which == :read, do: {r ++ names, w}, else: {r, w ++ names}
        {r2, w2, res}
    end
  end

  # data://[<mediatype>][;base64],<payload> — mediatype defaults to
  # text/plain;charset=US-ASCII; the payload may hold anything except we
  # take it verbatim to end of string (php does not URL-decode per docs,
  # though browsers do)
  defp parse_data(rest) do
    case String.split(rest, ",", parts: 2) do
      [header, payload] ->
        base64? = String.contains?(header, ";base64")

        data =
          if base64? do
            case Base.decode64(payload, ignore: :whitespace) do
              {:ok, d} -> d
              :error -> nil
            end
          else
            payload
          end

        case data do
          nil -> {:unsupported, "data"}
          d -> {:data, d}
        end

      _ ->
        {:unsupported, "data"}
    end
  end

  ## ─────────────────────── filter application ───────────────────────

  @doc "Apply a read/write filter chain to a binary (probed set)"
  def apply_chain(data, chain) do
    Enum.reduce(chain, data, fn f, acc ->
      case f do
        "string.toupper" -> String.upcase(acc)
        "string.tolower" -> String.downcase(acc)
        "string.rot13" -> rot13(acc)
        "convert.base64-encode" -> Base.encode64(acc)
        "convert.base64-decode" -> decode64(acc)
        _ -> acc
      end
    end)
  end

  defp decode64(s) do
    case Base.decode64(s, ignore: :whitespace) do
      {:ok, d} -> d
      :error -> s
    end
  end

  defp rot13(s) do
    s
    |> String.to_charlist()
    |> Enum.map(fn
      c when c in ?a..?z -> rem(c - ?a + 13, 26) + ?a
      c when c in ?A..?Z -> rem(c - ?A + 13, 26) + ?A
      c -> c
    end)
    |> List.to_string()
  end
end
