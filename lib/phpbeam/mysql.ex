defmodule PhpBeam.MySQL do
  @moduledoc """
  MySQL access for the mysqli builtins, backed by **MyXQL** (the Ecto
  MySQL driver) instead of a hand-rolled protocol client.

  The public surface is deliberately narrow — `connect/5`, `query/2`,
  `ping/1`, `close/1`, `escape/1` — and row values are converted back to
  their TEXT-protocol representation (binaries, or `:__null`) so the
  mysqli layer's php-style typing (`phpify`) is unchanged from the
  protocol-client era.

  Errors carry php-style `{code, message}` tuples; sqlstate prefixes are
  stripped by the caller (MysqliFns).
  """

  defstruct [:conn, :host, :user, :db, insert_id: 0, affected_rows: 0]

  @type t :: %__MODULE__{}

  # ───────────────────────── connect ─────────────────────────

  @doc """
  Connect via MyXQL (a DBConnection pool). Applications are ensured
  started so this also works inside the escript. Returns `{:ok, state}`
  or `{:error, {errno, message}}`.
  """
  def connect(host, port, user, password, db) do
    host_s = to_string(host)

    {host_arg, port_arg} = normalize_endpoint(host_s, port)
    user_s = to_string(user || "")
    pass_s = to_string(password || "")
    db_s = if is_nil(db) or db == "", do: nil, else: to_string(db)

    case Application.ensure_all_started(:myxql) do
      {:ok, _} ->
        opts = [
          hostname: host_arg,
          port: port_arg,
          username: user_s,
          password: pass_s,
          pool_size: 1,
          backoff_type: :stop,
          queue_target: 5_000,
          queue_interval: 10_000
        ]

        opts = if db_s, do: Keyword.put(opts, :database, db_s), else: opts

        case MyXQL.start_link(opts) do
          {:ok, conn} ->
            {:ok, %__MODULE__{conn: conn, host: host_s, user: user_s, db: db_s}}

          {:error, %MyXQL.Error{mysql: %{code: code, message: msg}}} ->
            {:error, {code, strip_state(msg)}}

          {:error, err} ->
            {:error, connection_error(host_s, err)}
        end

      {:error, _} ->
        {:error, {2002, "MyXQL applications failed to start"}}
    end
  end

  # MyXQL takes hostname as a binary (it runs String.to_charlist itself)
  defp normalize_endpoint(host, port), do: {host, port || 3306}

  defp connection_error(_host, %DBConnection.ConnectionError{}), do: {2002, "Connection refused"}

  defp connection_error(_host, err) when is_exception(err),
    do: {2003, Exception.message(err) |> String.slice(0, 120)}

  defp connection_error(_host, _), do: {2003, "Can't connect to MySQL server"}

  defp strip_state(msg) do
    case Regex.run(~r/\A[0-9A-Z]{5}(.*)\z/s, msg) do
      [_, rest] -> rest
      _ -> msg
    end
  end

  # ───────────────────────── query ─────────────────────────

  @doc """
  COM_QUERY via MyXQL. Result rows come back DECODED (ints, Decimals,
  dates) — re-rendered to text form so the mysqli layer keeps applying
  php's conversion rules to strings, exactly like the protocol client did.
  """
  def query(%__MODULE__{conn: conn} = st, sql) do
    case MyXQL.query(conn, to_string(sql)) do
      {:ok, %MyXQL.Result{} = r} ->
        meta = %{
          columns: r.columns || [],
          rows: Enum.map(r.rows || [], &render_row/1),
          num_rows: r.num_rows || 0,
          affected_rows: r.num_rows || 0,
          insert_id: r.last_insert_id || 0
        }

        st2 = %{st | insert_id: r.last_insert_id || 0, affected_rows: r.num_rows || 0}
        {:ok, meta, st2}

      {:ok, _other} ->
        {:ok, %{columns: [], rows: [], num_rows: 0, affected_rows: 0, insert_id: 0}, st}

      {:error, %MyXQL.Error{mysql: %{code: code, message: msg}}} ->
        {:error, {code, msg}, st}

      {:error, %MyXQL.Error{message: msg}} ->
        {:error, {1064, msg}, st}

      {:error, err} ->
        {:error,
         {2013, "Lost connection to MySQL server (#{inspect(err) |> String.slice(0, 60)})"}, st}
    end
  rescue
    e in MyXQL.Error ->
      {code, msg} =
        case e do
          %{mysql: %{code: c, message: m}} -> {c, m}
          _ -> {1064, e.message || "query error"}
        end

      {:error, {code, msg}, st}

    e in DBConnection.ConnectionError ->
      _ = e
      {:error, {2013, "Lost connection to MySQL server"}, st}

    _ ->
      {:error, {2013, "Lost connection to MySQL server during query"}, st}
  end

  # text-protocol re-rendering: php's mysqli hands php strings, and our
  # phpify() layer types them; mirror that by stringifying decoded values
  defp render_row(row), do: Enum.map(row, &render_value/1)

  defp render_value(nil), do: :__null
  defp render_value(v) when is_binary(v), do: v
  defp render_value(v) when is_integer(v), do: Integer.to_string(v)
  defp render_value(v) when is_float(v), do: Float.to_string(v)

  defp render_value(%Decimal{} = v), do: Decimal.to_string(v)

  defp render_value(%Date{} = v), do: Date.to_string(v)
  defp render_value(%Time{} = v), do: Time.to_string(v)
  defp render_value(%NaiveDateTime{} = v), do: NaiveDateTime.to_string(v)
  defp render_value(%DateTime{} = v), do: NaiveDateTime.to_string(DateTime.to_naive(v))

  defp render_value(v) when is_atom(v), do: Atom.to_string(v)
  defp render_value(v), do: inspect(v)

  # ───────────────────────── misc ─────────────────────────

  def ping(%__MODULE__{conn: conn} = st) do
    case MyXQL.ping(conn) do
      :ok -> {:ok, st}
      {:error, _} -> {:error, :closed}
    end
  rescue
    _ -> {:error, :closed}
  end

  def close(%__MODULE__{conn: conn}) do
    if is_pid(conn) and Process.alive?(conn) do
      GenServer.stop(conn, :normal, 1_000)
    end

    :ok
  catch
    _, _ -> :ok
  end

  @doc "php mysqli_real_escape_string semantics (client-side escaping)"
  def escape(s) do
    for <<c <- s>>, into: "" do
      case c do
        ?n -> "\\n"
        ?r -> "\\r"
        ?0 -> "\\0"
        ?\\ -> "\\\\"
        ?' -> "\\'"
        ?" -> "\\\""
        0x1A -> "\\Z"
        _ -> <<c>>
      end
    end
  end
end
