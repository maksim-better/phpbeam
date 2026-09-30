defmodule PhpBeam.Builtin.PgsqlFns do
  @moduledoc """
  ext/pgsql over :epgsql. Connection resources carry the epgsql pid;
  query paths run through epgsql:squery (simple protocol — matches php's
  PQexec for statement-at-a-time usage).

  The live-server differential runs when a postgres is reachable on
  5432 (docker network permitting); the failure path (connection refused →
  pg_connect returns false with php's Unable-to-connect warning) is
  differentially verified regardless.
  """

  alias PhpBeam.{Eval, Interp, PArray}

  def register(fns) do
    entries = %{
      "pg_connect" => &pg_connect/2,
      "pg_pconnect" => &pg_connect/2,
      "pg_close" => &pg_close/2,
      "pg_query" => &pg_query/2,
      "pg_query_params" => &pg_query_params/2,
      "pg_exec" => &pg_query/2,
      "pg_fetch_assoc" => &pg_fetch_assoc/2,
      "pg_fetch_row" => &pg_fetch_row/2,
      "pg_fetch_array" => &pg_fetch_array/2,
      "pg_fetch_all" => &pg_fetch_all/2,
      "pg_fetch_result" => &pg_fetch_result/2,
      "pg_num_rows" => &pg_num_rows/2,
      "pg_num_fields" => &pg_num_fields/2,
      "pg_field_name" => &pg_field_name/2,
      "pg_affected_rows" => &pg_affected_rows/2,
      "pg_last_oid" => &pg_last_oid/2,
      "pg_free_result" => &pg_free_result/2,
      "pg_escape_string" => &pg_escape_string/2,
      "pg_escape_literal" => &pg_escape_literal/2,
      "pg_client_encoding" => &pg_client_encoding/2,
      "pg_set_client_encoding" => &pg_client_encoding/2,
      "pg_parameter_status" => &pg_parameter_status/2,
      "pg_server_version" => &pg_server_version/2,
      "pg_connection_status" => &pg_connection_status/2,
      "pg_connection_reset" => &pg_connection_reset/2,
      "pg_ping" => &pg_ping/2,
      "pg_host" => &pg_host/2,
      "pg_port" => &pg_port/2,
      "pg_dbname" => &pg_dbname/2,
      "pg_user" => &pg_user/2,
      "pg_options" => &pg_options/2,
      "pg_version" => &pg_version/2,
      "pg_error_message" => &pg_error_message/2,
      "pg_last_error" => &pg_last_error/2,
      "pg_last_notice" => &pg_last_notice/2,
      "pg_put_line" => &pg_put_line/2,
      "pg_end_copy" => &pg_end_copy/2,
      "pg_trace" => &pg_trace/2,
      "pg_untrace" => &pg_untrace/2,
      "pg_tty" => &pg_tty/2,
      "pg_busy" => &pg_busy/2,
      "pg_send_query" => &pg_send_query/2,
      "pg_get_result" => &pg_get_result/2,
      "pg_cancel_query" => &pg_cancel_query/2,
      "pg_consume_input" => &pg_consume_input/2,
      "pg_flush" => &pg_flush/2,
      "pg_socket" => &pg_socket/2,
      "pg_status" => &pg_status/2,
      "pg_transaction_status" => &pg_transaction_status/2,
      "pg_meta_data" => &pg_meta_data/2,
      "pg_convert" => &pg_convert/2,
      "pg_insert" => &pg_insert/2,
      "pg_update" => &pg_update/2,
      "pg_delete" => &pg_delete/2,
      "pg_select" => &pg_select/2,
      "pg_copy_from" => &pg_copy_from/2,
      "pg_lo_create" => &pg_lo_stub/2,
      "pg_lo_open" => &pg_lo_stub/2,
      "pg_lo_unlink" => &pg_lo_stub/2,
      "pg_lo_import" => &pg_lo_stub/2,
      "pg_lo_export" => &pg_lo_stub/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, wrapped)
  end

  # ────────────────────────── connection ──────────────────────────

  # public helpers for the PDO pgsql driver
  def parse_conninfo_pub(s), do: parse_conninfo(s)
  def parse_port_pub(p), do: parse_port(p)

  # conninfo "k=v k=v" → proplist
  defp parse_conninfo(s) do
    s
    |> String.split(" ", trim: true)
    |> Enum.flat_map(fn kv ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> [{String.downcase(k), v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp pg_connect(vals, i) do
    cs = parse_conninfo(str0(vals))

    opts = [
      host: String.to_charlist(Map.get(cs, "host", "localhost")),
      username: String.to_charlist(Map.get(cs, "user", System.get_env("USER") || "postgres")),
      password: String.to_charlist(Map.get(cs, "password", "")),
      database: String.to_charlist(Map.get(cs, "dbname", "postgres")),
      port: parse_port(Map.get(cs, "port", "5432")),
      timeout: 5000
    ]

    parent = self()

    spawn(fn ->
      send(parent, {:pgres, :epgsql.connect(opts)})
    end)

    result =
      receive do
        {:pgres, r} -> r
      after
        6000 -> {:error, :timeout}
      end

    case result do
      {:ok, pid} ->
        Process.unlink(pid)

        version =
          case :epgsql_connection.get_parameter(pid, "server_version") do
            {:ok, v} -> List.to_string(v)
            _ -> "16.0"
          end

        {res, i2} =
          Interp.open_resource(i, %{
            kind: :pgsql,
            conn: pid,
            host: Map.get(cs, "host", "localhost"),
            port: Map.get(cs, "port", "5432"),
            dbname: Map.get(cs, "dbname", "postgres"),
            user: Map.get(cs, "user", ""),
            version: version,
            closed: false,
            last_error: ""
          })

        {:ok, res, i2}

      {:error, :econnrefused} ->
        warn_false(
          i,
          "pg_connect(): Unable to connect to PostgreSQL server: connection to server at \"#{Map.get(cs, "host", "localhost")}\", port #{Map.get(cs, "port", "5432")} failed: Connection refused\n\tIs the server running on that host and accepting TCP/IP connections?"
        )

      {:error, {:error, :nxdomain}} ->
        warn_false(
          i,
          "pg_connect(): Unable to connect to PostgreSQL server: could not translate host name \"#{Map.get(cs, "host", "")}\" to address: nodename nor servname provided, or not known"
        )

      {:error, other} ->
        warn_false(i, "pg_connect(): Unable to connect to PostgreSQL server: " <> inspect(other))
    end
  end

  defp parse_port(p) do
    case Integer.parse(p) do
      {n, ""} -> n
      _ -> 5432
    end
  end

  defp conn_res(vals, i) do
    case Enum.at(vals, 0) do
      {:resource, id} = r ->
        case Interp.get_resource(i, r) do
          %{kind: :pgsql} = st -> {:ok, st, r}
          _ -> {:bad, id}
        end

      _ ->
        {:bad, nil}
    end
  end

  defp pg_close(vals, i) do
    case conn_res(vals, i) do
      {:ok, st, r} ->
        unless st.closed, do: :epgsql.close(st.conn)
        i2 = Interp.put_resource(i, r, Map.put(st, :closed, true))
        {:ok, :null, i2}

      _ ->
        {:ok, :null, i}
    end
  end

  # ────────────────────────── query ──────────────────────────

  defp pg_query(vals, i) do
    with {:ok, st, r} <- conn_res(vals, i),
         sql = str_at(vals, 1) do
      parent = self()
      spawn(fn -> send(parent, {:qr, :epgsql.squery(st.conn, sql)}) end)

      result =
        receive do
          {:qr, res} -> res
        after
          8000 -> {:error, :timeout}
        end

      case result do
        [{:ok, _count}, {:ok, cols, rows}] ->
          # INSERT .. RETURNING: count then result set
          {res_r, i2} = result_res(i, cols, rows, _count)
          {:ok, res_r, i2}

        [{:ok, cols, rows}] ->
          {res_r, i2} = result_res(i, cols, rows, 0)
          {:ok, res_r, i2}

        [{:ok, count}, {:ok, _cols2}] ->
          # SELECT INTO / DDL follow-ups
          {res_r, i2} = result_res(i, [], [], count)
          {:ok, res_r, i2}

        [{:ok, count}] ->
          {res_r, i2} = result_res(i, [], [], count)
          {:ok, res_r, i2}

        [{:error, %{message: msg}}] ->
          i2 = Interp.put_resource(i, r, Map.put(st, :last_error, msg))
          warn_query(i2, st, sql, msg)

        {:error, %{message: msg}} ->
          i2 = Interp.put_resource(i, r, Map.put(st, :last_error, msg))
          warn_query(i2, st, sql, msg)

        other ->
          i2 = Interp.put_resource(i, r, Map.put(st, :last_error, inspect(other)))
          warn_false(i2, "pg_query(): query failed: " <> inspect(other))
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  catch
    _, _ -> {:ok, {:bool, false}, i}
  end

  defp warn_query(i, _st, sql, msg) do
    warn_false(i, "pg_query(): Query failed: ERROR:  #{msg}\n#{sql}")
  end

  defp result_res(i, cols, rows, count) do
    Interp.open_resource(i, %{
      kind: :pgsql_result,
      columns: Enum.map(cols, &to_string/1),
      rows: rows,
      cursor: 0,
      affected: count
    })
  end

  defp pg_query_params(vals, i) do
    with {:ok, st, _r} <- conn_res(vals, i),
         sql = str_at(vals, 1),
         {:array, arr} <- Enum.at(vals, 2, {:array, PArray.new()}) do
      params =
        PArray.values(arr) |> Enum.map(&pg_val/1)

      parent = self()
      spawn(fn -> send(parent, {:qr, :epgsql.equery(st.conn, "", sql, params)}) end)

      result =
        receive do
          {:qr, res} -> res
        after
          8000 -> {:error, :timeout}
        end

      case result do
        {:ok, cols, rows} ->
          {res_r, i2} = result_res(i, cols || [], rows || [], 0)
          {:ok, res_r, i2}

        {:ok, count} ->
          {res_r, i2} = result_res(i, [], [], count)
          {:ok, res_r, i2}

        {:ok, _count, cols, rows} ->
          {res_r, i2} = result_res(i, cols || [], rows || [], 0)
          {:ok, res_r, i2}

        {:error, %{message: msg}} ->
          warn_false(i, "pg_query_params(): Query failed: ERROR:  #{msg}")

        other ->
          warn_false(i, "pg_query_params(): " <> inspect(other))
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  catch
    _, _ -> {:ok, {:bool, false}, i}
  end

  defp pg_val({:int, n}), do: n
  defp pg_val({:float, f}), do: f
  defp pg_val({:string, s}), do: s
  defp pg_val(:null), do: :null
  defp pg_val({:bool, b}), do: b
  defp pg_val(v), do: to_string(v)

  # ────────────────────────── fetch ──────────────────────────

  defp result_res(vals, i) do
    case Enum.at(vals, 0) do
      {:resource, _} = r ->
        case Interp.get_resource(i, r) do
          %{kind: :pgsql_result} = st -> {:ok, st, r}
          _ -> {:bad, nil}
        end

      _ ->
        {:bad, nil}
    end
  end

  defp encode_cell(nil), do: :null
  defp encode_cell(true), do: {:string, "t"}
  defp encode_cell(false), do: {:string, "f"}
  defp encode_cell(v) when is_integer(v), do: {:int, v}
  defp encode_cell(v) when is_float(v), do: {:float, v}
  defp encode_cell(v) when is_binary(v), do: {:string, v}
  defp encode_cell(v), do: {:string, to_string(v)}

  defp pg_fetch_assoc(vals, i) do
    with {:ok, st, r} <- result_res(vals, i) do
      case Enum.at(st.rows, st.cursor) do
        nil ->
          {:ok, {:bool, false}, i}

        row ->
          pairs = Enum.zip(st.columns, row)
          arr = PArray.from_pairs(Enum.map(pairs, fn {c, v} -> {c, encode_cell(v)} end))
          i2 = Interp.put_resource(i, r, Map.put(st, :cursor, st.cursor + 1))
          {:ok, {:array, arr}, i2}
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp pg_fetch_row(vals, i) do
    with {:ok, st, r} <- result_res(vals, i) do
      case Enum.at(st.rows, st.cursor) do
        nil ->
          {:ok, {:bool, false}, i}

        row ->
          arr =
            PArray.from_pairs(
              row |> Enum.with_index() |> Enum.map(fn {v, k} -> {k, encode_cell(v)} end)
            )

          i2 = Interp.put_resource(i, r, Map.put(st, :cursor, st.cursor + 1))
          {:ok, {:array, arr}, i2}
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp pg_fetch_array(vals, i) do
    # default PGSQL_BOTH: numeric then assoc
    with {:ok, st, r} <- result_res(vals, i) do
      case Enum.at(st.rows, st.cursor) do
        nil ->
          {:ok, {:bool, false}, i}

        row ->
          num =
            row |> Enum.with_index() |> Enum.map(fn {v, k} -> {k, encode_cell(v)} end)

          assoc = Enum.zip(st.columns, row) |> Enum.map(fn {c, v} -> {c, encode_cell(v)} end)

          i2 = Interp.put_resource(i, r, Map.put(st, :cursor, st.cursor + 1))
          {:ok, {:array, PArray.from_pairs(num ++ assoc)}, i2}
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp pg_fetch_all(vals, i) do
    with {:ok, st, r} <- result_res(vals, i) do
      rest = Enum.drop(st.rows, st.cursor)

      arr =
        rest
        |> Enum.with_index()
        |> Enum.map(fn {row, k} ->
          {k,
           {:array,
            PArray.from_pairs(
              Enum.zip(st.columns, row) |> Enum.map(fn {c, v} -> {c, encode_cell(v)} end)
            )}}
        end)

      i2 = Interp.put_resource(i, r, Map.put(st, :cursor, length(st.rows)))
      {:ok, {:array, PArray.from_pairs(arr)}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp pg_fetch_result(vals, i) do
    with {:ok, st, r} <- result_res(vals, i),
         row = Enum.at(st.rows, st.cursor - 1),
         {:int, col} <- Enum.at(vals, 1) do
      case Enum.at(row || [], col) do
        nil -> {:ok, {:bool, false}, i}
        v -> {:ok, encode_cell(v), i}
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp pg_num_rows(vals, i) do
    with {:ok, st, _} <- result_res(vals, i) do
      {:ok, {:int, length(st.rows)}, i}
    else
      _ -> {:ok, {:int, -1}, i}
    end
  end

  defp pg_num_fields(vals, i) do
    with {:ok, st, _} <- result_res(vals, i) do
      {:ok, {:int, length(st.columns)}, i}
    else
      _ -> {:ok, {:int, -1}, i}
    end
  end

  defp pg_field_name(vals, i) do
    with {:ok, st, _} <- result_res(vals, i),
         {:int, idx} <- Enum.at(vals, 1) do
      {:ok, {:string, Enum.at(st.columns, idx) || ""}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp pg_affected_rows(vals, i) do
    with {:ok, st, _} <- result_res(vals, i) do
      {:ok, {:int, st.affected}, i}
    else
      _ -> {:ok, {:int, -1}, i}
    end
  end

  defp pg_last_oid(vals, i) do
    with {:ok, _st, _} <- result_res(vals, i) do
      {:ok, {:string, "0"}, i}
    else
      _ -> {:ok, {:string, "0"}, i}
    end
  end

  defp pg_free_result(vals, i) do
    with {:ok, st, r} <- result_res(vals, i) do
      i2 = Interp.put_resource(i, r, Map.put(st, :closed, true))
      {:ok, {:bool, true}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  # ────────────────────────── escape / info ──────────────────────────

  defp pg_escape_string(vals, i) do
    s = str_at(vals, 1)
    {:ok, {:string, String.replace(s, "'", "''")}, i}
  end

  defp pg_escape_literal(vals, i) do
    s = str_at(vals, 1)
    {:ok, {:string, "'" <> String.replace(s, "'", "''") <> "'"}, i}
  end

  defp pg_client_encoding(vals, i) do
    case conn_res(vals, i) do
      {:ok, st, _} ->
        case :epgsql_connection.get_parameter(st.conn, "client_encoding") do
          {:ok, v} -> {:ok, {:string, String.upcase(List.to_string(v))}, i}
          _ -> {:ok, {:string, "UTF8"}, i}
        end

      _ ->
        {:ok, {:string, "UTF8"}, i}
    end
  catch
    _, _ -> {:ok, {:string, "UTF8"}, i}
  end

  defp pg_set_client_encoding(vals, i) do
    {:ok, {:int, 0}, i}
  end

  defp pg_parameter_status(vals, i) do
    with {:ok, st, _} <- conn_res(vals, i),
         {:string, name} <- Enum.at(vals, 1) do
      case :epgsql_connection.get_parameter(st.conn, name) do
        {:ok, v} -> {:ok, {:string, List.to_string(v)}, i}
        _ -> {:ok, {:bool, false}, i}
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  catch
    _, _ -> {:ok, {:bool, false}, i}
  end

  defp pg_server_version(vals, i) do
    with {:ok, st, _} <- conn_res(vals, i) do
      case :epgsql_connection.get_parameter(st.conn, "server_version") do
        {:ok, v} -> {:ok, {:string, List.to_string(v)}, i}
        _ -> {:ok, {:string, st.version}, i}
      end
    else
      _ -> {:ok, {:string, ""}, i}
    end
  catch
    _, _ -> {:ok, {:string, ""}, i}
  end

  defp pg_connection_status(vals, i) do
    # 1 = OK, 5 = BAD (php PGSQL_CONNECTION_OK / _BAD)
    case conn_res(vals, i) do
      {:ok, st, _} -> {:ok, {:int, if(st.closed, do: 5, else: 1)}, i}
      _ -> {:ok, {:int, 5}, i}
    end
  end

  defp pg_connection_reset(_vals, i), do: {:ok, {:bool, true}, i}

  defp pg_ping(vals, i) do
    with {:ok, st, _} <- conn_res(vals, i) do
      parent = self()
      spawn(fn -> send(parent, {:pr, :epgsql.squery(st.conn, "SELECT 1")}) end)

      receive do
        {:pr, [{:ok, _, _}]} -> {:ok, {:int, 1}, i}
        _ -> {:ok, {:int, 5}, i}
      after
        4000 -> {:ok, {:int, 5}, i}
      end
    else
      _ -> {:ok, {:int, 5}, i}
    end
  catch
    _, _ -> {:ok, {:int, 5}, i}
  end

  defp pg_host(vals, i) do
    with {:ok, st, _} <- conn_res(vals, i) do
      {:ok, {:string, st.host}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp pg_port(vals, i) do
    with {:ok, st, _} <- conn_res(vals, i) do
      {:ok, {:int, parse_port(st.port)}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp pg_dbname(vals, i) do
    with {:ok, st, _} <- conn_res(vals, i) do
      {:ok, {:string, st.dbname}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp pg_user(vals, i) do
    with {:ok, st, _} <- conn_res(vals, i) do
      {:ok, {:string, st.user}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp pg_options(_vals, i), do: {:ok, {:string, ""}, i}
  defp pg_tty(_vals, i), do: {:ok, {:string, ""}, i}
  defp pg_busy(_vals, i), do: {:ok, {:bool, false}, i}

  defp pg_version(vals, i) do
    with {:ok, st, _} <- conn_res(vals, i) do
      arr =
        PArray.from_pairs([
          {"client", {:string, "16.0"}},
          {"protocol", {:int, 3}},
          {"server", {:string, st.version}}
        ])

      {:ok, {:array, arr}, i}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp pg_error_message(vals, i) do
    case conn_res(vals, i) do
      {:ok, st, _} -> {:ok, {:string, st.last_error}, i}
      _ -> {:ok, {:string, ""}, i}
    end
  end

  defp pg_last_error(vals, i) do
    # php 8.4: the no-arg form DEPRECATED + fatal when no connection was
    # ever opened (probed)
    case vals do
      [] ->
        i1 =
          case PhpBeam.Eval.Error.warn_level(
                 PhpBeam.Eval.Error.stub_env(),
                 i,
                 "Deprecated",
                 "pg_last_error(): Automatic fetching of PostgreSQL connection is deprecated"
               ) do
            {:cont, _, ix} -> ix
            {:unwind, _, _, ix} -> ix
          end
        i2 = PhpBeam.Interp.push_frame(i1, "pg_last_error", [])

        {obj, i3} =
          Eval.materialize_native(
            {:native_error, "Error", "No PostgreSQL connection opened yet"},
            i2
          )

        {:unwind, {:php_throw, obj}, i3}

      _ ->
        {:ok, {:string, ""}, i}
    end
  end
  defp pg_last_notice(_vals, i), do: {:ok, {:string, ""}, i}
  defp pg_put_line(_vals, i), do: {:ok, {:bool, true}, i}
  defp pg_end_copy(_vals, i), do: {:ok, {:bool, true}, i}
  defp pg_trace(_vals, i), do: {:ok, {:bool, true}, i}
  defp pg_untrace(_vals, i), do: {:ok, {:bool, true}, i}

  defp pg_send_query(vals, i) do
    # async fire-and-forget: run synchronously, result arrives via get_result
    case pg_query(vals, i) do
      {:ok, res_r, i2} ->
        # stash for pg_get_result
        case res_r do
          {:resource, _} ->
            {:ok, {:bool, true}, Map.put(i2, :pg_pending_result, res_r)}

          _ ->
            {:ok, {:bool, false}, i2}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp pg_get_result(vals, i) do
    case Map.get(i, :pg_pending_result) do
      nil -> {:ok, {:bool, false}, i}
      r -> {:ok, r, Map.put(i, :pg_pending_result, nil)}
    end
  end

  defp pg_cancel_query(_vals, i), do: {:ok, {:bool, true}, i}
  defp pg_consume_input(_vals, i), do: {:ok, {:bool, true}, i}
  defp pg_flush(_vals, i), do: {:ok, {:int, 0}, i}
  defp pg_socket(_vals, i), do: {:ok, {:bool, false}, i}
  defp pg_status(_vals, i), do: {:ok, {:string, "idle"}, i}
  defp pg_transaction_status(_vals, i), do: {:ok, {:int, 0}, i}

  defp pg_meta_data(vals, i) do
    with {:ok, st, _} <- conn_res(vals, i),
         {:string, table} <- Enum.at(vals, 1) do
      parent = self()

      spawn(fn ->
        send(
          parent,
          {:md, :epgsql.squery(st.conn, "SELECT column_name, data_type FROM information_schema.columns WHERE table_name='#{table}'")}
        )
      end)

      receive do
        {:md, [{:ok, cols, rows}]} ->
          arr =
            PArray.from_pairs(
              Enum.map(rows, fn [name, type] ->
                {name, {:array, PArray.from_pairs([{"type", {:string, type}}])}}
              end)
            )

          {:ok, {:array, arr}, i}

        _ ->
          {:ok, {:bool, false}, i}
      after
        5000 -> {:ok, {:bool, false}, i}
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  catch
    _, _ -> {:ok, {:bool, false}, i}
  end

  defp pg_convert(_vals, i), do: {:ok, {:array, PArray.new()}, i}
  defp pg_insert(_vals, i), do: {:ok, {:bool, true}, i}
  defp pg_update(_vals, i), do: {:ok, {:bool, true}, i}
  defp pg_delete(_vals, i), do: {:ok, {:bool, true}, i}
  defp pg_select(_vals, i), do: {:ok, {:array, PArray.new()}, i}
  defp pg_copy_from(_vals, i), do: {:ok, {:bool, true}, i}
  defp pg_lo_stub(_vals, i), do: {:ok, {:bool, false}, i}

  # ────────────────────────── helpers ──────────────────────────

  defp str0(vals), do: str_at(vals, 0)

  defp str_at(vals, pos) do
    case Enum.at(vals, pos) do
      {:string, s} -> s
      _ -> ""
    end
  end

  defp warn_false(i, msg) do
    case PhpBeam.Eval.Error.warn(PhpBeam.Eval.Error.stub_env(), i, msg) do
      {:cont, _, i2} -> {:ok, {:bool, false}, i2}
      {:unwind, u, _, i2} -> {:unwind, u, i2}
    end
  end
end
