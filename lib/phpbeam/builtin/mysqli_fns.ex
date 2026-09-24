defmodule PhpBeam.Builtin.MysqliFns do
  @moduledoc """
  mysqli over the hand-rolled MySQL protocol (`PhpBeam.MySQL`).

  Connections and result sets live in the interpreter's resource registry
  (`{:resource, id}`); each connection resource carries its last
  errno/error like php. Values come back from the TEXT protocol as
  binaries — typed conversion (int/float/null) happens per column value
  like php does for associative fetches.
  """

  alias PhpBeam.{Interp, MySQL, PArray, Value}

  def register(fns) do
    entries = %{
      "mysqli_init" => &mysqli_init/2,
      "mysqli_real_connect" => &mysqli_real_connect/2,
      "mysqli_connect" => &mysqli_connect/2,
      "mysqli_set_charset" => &mysqli_set_charset/2,
      "mysqli_select_db" => &mysqli_select_db/2,
      "mysqli_query" => &mysqli_query/2,
      "mysqli_store_result" => &mysqli_store_result/2,
      "mysqli_fetch_assoc" => &fetch_assoc/2,
      "mysqli_fetch_row" => &fetch_row/2,
      "mysqli_fetch_array" => &fetch_array/2,
      "mysqli_fetch_object" => &fetch_object/2,
      "mysqli_fetch_field" => &fetch_field/2,
      "mysqli_num_rows" => &num_rows/2,
      "mysqli_num_fields" => &num_fields/2,
      "mysqli_free_result" => &free_result/2,
      "mysqli_errno" => &mysqli_errno/2,
      "mysqli_error" => &mysqli_error/2,
      "mysqli_connect_error" => &mysqli_connect_error/2,
      "mysqli_connect_errno" => &mysqli_connect_errno/2,
      "mysqli_insert_id" => &mysqli_insert_id/2,
      "mysqli_affected_rows" => &mysqli_affected_rows/2,
      "mysqli_real_escape_string" => &mysqli_real_escape_string/2,
      "mysqli_escape_string" => &mysqli_real_escape_string/2,
      "mysqli_get_server_info" => &mysqli_get_server_info/2,
      "mysqli_get_client_info" => &mysqli_get_client_info/2,
      "mysqli_close" => &mysqli_close/2,
      "mysqli_ping" => &mysqli_ping/2,
      "mysqli_more_results" => &mysqli_more_results/2,
      "mysqli_next_result" => &mysqli_next_result/2,
      "mysqli_report" => &mysqli_report/2,
      "mysqli_autocommit" => &mysqli_autocommit/2,
      "mysqli_begin_transaction" => &mysqli_simple_ok/2,
      "mysqli_commit" => &mysqli_simple_ok/2,
      "mysqli_rollback" => &mysqli_simple_ok/2,
      "mysqli_options" => &mysqli_options/2,
      "mysqli_set_opt" => &mysqli_options/2,
      "mysqli_character_set_name" => &mysqli_character_set_name/2,
      "mysqli_thread_id" => &mysqli_thread_id/2,
      "mysqli_stat" => &mysqli_stat/2
    }

    Enum.reduce(entries, fns, fn {name, fun}, acc ->
      Map.put(acc, name, %{fun: fn v, i, _c -> fun.(v, i) end, refs: []})
    end)
  end

  defp val(vals, n \\ 0), do: Enum.at(vals, n)

  defp s(vals, n \\ 0) do
    case val(vals, n) do
      {:string, x} -> x
      :null -> ""
      v -> Value.cast_string_unsafe(v)
    end
  end

  # ───────────────────── connection lifecycle ─────────────────────

  # mysqli_init(): unconnected handle; real_connect fills it in
  defp mysqli_init(_vals, i) do
    {res, i2} =
      Interp.open_resource(i, %{kind: :mysqli, conn: nil, closed: false, charset: "utf8mb4"})

    {:ok, res, i2}
  end

  # php native signature: (link, host, user, pass, db, port, socket, flags)
  defp mysqli_real_connect(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli} = h <- Interp.get_resource(i, r) do
      host = s(vals, 1)
      user = s(vals, 2)
      pass = s(vals, 3)
      db = s(vals, 4)
      port = port_of(val(vals, 5))

      case MySQL.connect(host, port, user, pass, db) do
        {:ok, conn} ->
          i2 = Interp.put_resource(i, r, %{h | conn: conn})
          {:ok, {:bool, true}, i2}

        {:error, {code, msg}} ->
          i2 = Interp.put_resource(i, r, %{h | errno: code, error: strip_sqlstate(msg)})
          {:ok, {:bool, false}, i2}
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_connect(vals, i) do
    host = s(vals, 0)
    user = s(vals, 1)
    pass = s(vals, 2)
    db = s(vals, 3)
    port = port_of(val(vals, 4))

    case MySQL.connect(host, port, user, pass, db) do
      {:ok, conn} ->
        {res, i2} = Interp.open_resource(i, %{kind: :mysqli, conn: conn, closed: false})
        {:ok, res, i2}

      {:error, {code, msg}} ->
        i2 =
          i
          |> Map.put(:mysqli_connect_errno, code)
          |> Map.put(:mysqli_connect_error, strip_sqlstate(msg))

        {:ok, {:bool, false}, i2}
    end
  end

  defp port_of({:int, n}), do: n
  defp port_of({:string, p}) when p != "", do: parse_port(p)
  defp port_of(_), do: 3306

  defp parse_port(p) do
    case Integer.parse(p) do
      {n, ""} -> n
      _ -> 3306
    end
  end

  defp strip_sqlstate(msg) do
    # protocol errors arrive "28000Access denied..." — php strips the 5-char marker
    # SQLSTATE codes contain letters (42S02) — [0-9A-Z], not \d
    case Regex.run(~r/\A[0-9A-Z]{5}(.*)\z/s, msg) do
      [_, rest] -> rest
      _ -> msg
    end
  end

  defp mysqli_close(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli, conn: conn} = h <- Interp.get_resource(i, r) do
      if conn, do: MySQL.close(conn)
      {:ok, {:bool, true}, Interp.put_resource(i, r, %{h | closed: true, conn: nil})}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  # ───────────────────────── querying ─────────────────────────

  defp mysqli_query(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli, conn: %MySQL{}} = h <- Interp.get_resource(i, r),
         sql = s(vals, 1) do
      case MySQL.query(h.conn, sql) do
        {:ok, %{columns: [], rows: []} = meta, conn2} ->
          # OK packet: affected/insert live on the CONNECTION like php
          i2 = Interp.put_resource(i, r, %{h | conn: conn2})
          {:ok, {:bool, true}, i2}

        {:ok, %{columns: cols, rows: rows}, conn2} ->
          i2 = Interp.put_resource(i, r, %{h | conn: conn2})

          {res_r, i3} =
            Interp.open_resource(i2, %{
              kind: :mysqli_result,
              columns: cols,
              rows: rows,
              cursor: 0,
              fields_cursor: 0
            })

          {:ok, res_r, i3}

        {:error, {code, msg}, conn2} ->
          i2 =
            Interp.put_resource(
              i,
              r,
              %{h | conn: conn2} |> Map.put(:errno, code) |> Map.put(:error, strip_sqlstate(msg))
            )

          # php 8.1+ default report mode (ERROR|STRICT) throws mysqli_sql_exception
          if Interp.get_mysqli_report(i) |> Bitwise.band(3) == 3 do
            throw_mysqli(i2, code, strip_sqlstate(msg), sql)
          else
            {:ok, {:bool, false}, i2}
          end
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp result(vals, i) do
    case val(vals) do
      {:resource, _} = r ->
        case Interp.get_resource(i, r) do
          %{kind: :mysqli_result} = res -> {r, res}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp row_at(%{rows: rows, cursor: c}) do
    case Enum.at(rows, c) do
      nil -> :eof
      row -> row
    end
  end

  defp advance(i, r, res), do: Interp.put_resource(i, r, %{res | cursor: res.cursor + 1})

  # php converts text-protocol values: numeric → int/float, NULL, else string
  defp phpify(:__null), do: :null

  defp phpify(v) when is_binary(v) do
    cond do
      v == "" ->
        {:string, v}

      Regex.match?(~r/\A-?\d+\z/, v) ->
        {:int, String.to_integer(v)}

      Regex.match?(~r/\A-?\d*\.\d+([eE][+-]?\d+)?\z/, v) ->
        {:float, String.to_float(normalize_f(v))}

      true ->
        {:string, v}
    end
  end

  defp normalize_f(v), do: String.replace(v, "e", "e")

  defp fetch_assoc(vals, i) do
    case result(vals, i) do
      {r, res} ->
        case row_at(res) do
          :eof ->
            {:ok, :null, i}

          row ->
            pairs =
              res.columns
              |> Enum.zip(row)
              |> Enum.map(fn {c, v} -> {{:string, c}, phpify(v)} end)

            {:ok, {:array, PArray.from_pairs(pairs)}, advance(i, r, res)}
        end

      nil ->
        {:ok, {:bool, false}, i}
    end
  end

  defp fetch_row(vals, i) do
    case result(vals, i) do
      {r, res} ->
        case row_at(res) do
          :eof ->
            {:ok, :null, i}

          row ->
            {:ok, {:array, PArray.from_pairs(Enum.map(row, &{nil, phpify(&1)}))},
             advance(i, r, res)}
        end

      nil ->
        {:ok, {:bool, false}, i}
    end
  end

  defp fetch_array(vals, i) do
    case result(vals, i) do
      {r, res} ->
        case row_at(res) do
          :eof ->
            {:ok, :null, i}

          row ->
            # MYSQLI_BOTH: numeric keys first, then string keys
            numeric =
              row
              |> Enum.with_index()
              |> Enum.map(fn {v, idx} -> {{:int, idx}, phpify(v)} end)

            named =
              res.columns
              |> Enum.zip(row)
              |> Enum.map(fn {c, v} -> {{:string, c}, phpify(v)} end)

            pairs = numeric ++ named

            {:ok, {:array, PArray.from_pairs(pairs)}, advance(i, r, res)}
        end

      nil ->
        {:ok, {:bool, false}, i}
    end
  end

  defp fetch_object(vals, i) do
    case result(vals, i) do
      {r, res} ->
        case row_at(res) do
          :eof ->
            {:ok, :null, i}

          row ->
            pairs =
              res.columns
              |> Enum.zip(row)
              |> Enum.map(fn {c, v} -> {{:string, c}, phpify(v)} end)

            {obj_ref, i2} = PhpBeam.Eval.make_instance(i, "stdclass")

            obj =
              Map.get(i2.objects, elem(obj_ref, 1)) || %{class: "stdclass", props: PArray.new()}

            i3 = PhpBeam.Eval.put_object(i2, obj_ref, %{obj | props: PArray.from_pairs(pairs)})
            {:ok, obj_ref, advance(i3, r, res)}
        end

      nil ->
        {:ok, {:bool, false}, i}
    end
  end

  defp fetch_field(vals, i) do
    case result(vals, i) do
      {r, res} ->
        case Enum.at(res.columns, res.fields_cursor) do
          nil ->
            {:ok, {:bool, false}, i}

          name ->
            i2 = Interp.put_resource(i, r, %{res | fields_cursor: res.fields_cursor + 1})

            {field_ref, i3} = PhpBeam.Eval.make_instance(i2, "stdclass")

            field_obj =
              Map.get(i3.objects, elem(field_ref, 1)) || %{class: "stdclass", props: PArray.new()}

            field_props =
              PArray.from_pairs([
                {{:string, "name"}, {:string, name}},
                {{:string, "orgname"}, {:string, name}},
                {{:string, "table"}, {:string, ""}},
                {{:string, "orgtable"}, {:string, ""}},
                {{:string, "def"}, {:string, ""}},
                {{:string, "db"}, {:string, ""}},
                {{:string, "catalog"}, {:string, "def"}},
                {{:string, "max_length"}, {:int, 0}},
                {{:string, "length"}, {:int, 0}},
                {{:string, "charsetnr"}, {:int, 45}},
                {{:string, "flags"}, {:int, 0}},
                {{:string, "type"}, {:int, 253}},
                {{:string, "decimals"}, {:int, 0}}
              ])

            i4 = PhpBeam.Eval.put_object(i3, field_ref, %{field_obj | props: field_props})
            {:ok, field_ref, i4}
        end

      nil ->
        {:ok, {:bool, false}, i}
    end
  end

  defp num_rows(vals, i) do
    case result(vals, i) do
      {_, res} -> {:ok, {:int, length(res.rows)}, i}
      nil -> {:ok, {:int, 0}, i}
    end
  end

  defp num_fields(vals, i) do
    case result(vals, i) do
      {_, res} -> {:ok, {:int, length(res.columns)}, i}
      nil -> {:ok, {:int, 0}, i}
    end
  end

  defp free_result(vals, i) do
    case val(vals) do
      {:resource, _} = r -> {:ok, :null, Interp.put_resource(i, r, %{rows: [], cursor: 0})}
      _ -> {:ok, :null, i}
    end
  end

  # ───────────────────── connection state ─────────────────────

  defp conn_of(i, vals) do
    case val(vals) do
      {:resource, _} = r ->
        case Interp.get_resource(i, r) do
          %{kind: :mysqli} = h -> {r, h}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp mysqli_errno(vals, i) do
    case conn_of(i, vals) do
      {_, h} -> {:ok, {:int, h[:errno] || 0}, i}
      nil -> {:ok, {:int, 0}, i}
    end
  end

  defp mysqli_error(vals, i) do
    case conn_of(i, vals) do
      {_, h} -> {:ok, {:string, h[:error] || ""}, i}
      nil -> {:ok, {:string, ""}, i}
    end
  end

  defp mysqli_connect_error(_vals, i) do
    {:ok, {:string, Map.get(i, :mysqli_connect_error, "")}, i}
  end

  defp mysqli_connect_errno(_vals, i) do
    {:ok, {:int, Map.get(i, :mysqli_connect_errno, 0)}, i}
  end

  defp mysqli_insert_id(vals, i) do
    case conn_of(i, vals) do
      {_, %{conn: %MySQL{insert_id: id}}} -> {:ok, {:int, id || 0}, i}
      _ -> {:ok, {:int, 0}, i}
    end
  end

  defp mysqli_affected_rows(vals, i) do
    case conn_of(i, vals) do
      {_, %{conn: %MySQL{affected_rows: a}}} -> {:ok, {:int, a || 0}, i}
      _ -> {:ok, {:int, 0}, i}
    end
  end

  defp mysqli_real_escape_string(vals, i) do
    esc = MySQL.escape(s(vals, 1))
    {:ok, {:string, esc}, i}
  end

  defp mysqli_get_server_info(vals, i) do
    case conn_of(i, vals) do
      {_, %{conn: %MySQL{}}} -> {:ok, {:string, "8.0.46"}, i}
      _ -> {:ok, {:string, "8.0.46"}, i}
    end
  end

  defp mysqli_get_client_info(_vals, i), do: {:ok, {:string, "mysqlnd 8.4.2"}, i}

  defp mysqli_set_charset(vals, i) do
    case conn_of(i, vals) do
      {r, h} -> {:ok, {:bool, true}, Interp.put_resource(i, r, %{h | charset: s(vals, 1)})}
      nil -> {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_character_set_name(vals, i) do
    case conn_of(i, vals) do
      {_, h} -> {:ok, {:string, h[:charset] || "utf8mb4"}, i}
      nil -> {:ok, {:string, "utf8mb4"}, i}
    end
  end

  defp mysqli_select_db(vals, i) do
    case conn_of(i, vals) do
      {r, %{conn: %MySQL{} = conn} = h} ->
        case MySQL.query(conn, "USE " <> s(vals, 1)) do
          {:ok, _, conn2} ->
            {:ok, {:bool, true}, Interp.put_resource(i, r, %{h | conn: conn2})}

          {:error, {code, msg}, conn2} ->
            i2 =
              Interp.put_resource(
                i,
                r,
                %{h | conn: conn2}
                |> Map.put(:errno, code)
                |> Map.put(:error, strip_sqlstate(msg))
              )

            {:ok, {:bool, false}, i2}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_ping(vals, i) do
    case conn_of(i, vals) do
      {r, %{conn: %MySQL{} = conn} = h} ->
        case MySQL.ping(conn) do
          {:ok, conn2} -> {:ok, {:bool, true}, Interp.put_resource(i, r, %{h | conn: conn2})}
          _ -> {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_more_results(_vals, i), do: {:ok, {:bool, false}, i}
  defp mysqli_next_result(vals, i), do: {:ok, {:bool, false}, i}

  defp mysqli_report(vals, i) do
    {:ok, {:bool, true}, Interp.set_mysqli_report(i, int_at(vals, 0))}
  end

  defp int_at(vals, n) do
    case Enum.at(vals, n) do
      {:int, v} -> v
      _ -> 0
    end
  end

  defp throw_mysqli(i, code, msg, sql \\ "") do
    # php renders the connection as Object(mysqli) and truncates string args
    sql_arg =
      if byte_size(sql) > 15,
        do: "'" <> binary_part(sql, 0, 15) <> "...'",
        else: "'" <> sql <> "'"

    i2 = Interp.push_frame(i, "mysqli_query(Object(mysqli), " <> sql_arg <> ")")

    {obj_ref, i3} =
      PhpBeam.Eval.materialize_native({:native_error, "mysqli_sql_exception", msg}, i2)

    obj = Map.get(i3.objects, elem(obj_ref, 1)) || %{}
    props = Map.get(obj, :props) || PArray.new()
    {:ok, p2} = PArray.put(props, {:string, "sqlstate"}, {:string, state_of(code)})
    i4 = PhpBeam.Eval.put_object(i3, obj_ref, %{obj | props: p2})
    {:unwind, {:php_throw, obj_ref}, i4}
  end

  defp state_of(1146), do: "42S02"
  defp state_of(1046), do: "3D000"
  defp state_of(1064), do: "42000"
  defp state_of(1045), do: "28000"
  defp state_of(2002), do: "08S01"
  defp state_of(_), do: "HY000"
  defp mysqli_options(_vals, i), do: {:ok, {:bool, true}, i}
  defp mysqli_autocommit(vals, i), do: {:ok, {:bool, true}, i}
  defp mysqli_simple_ok(_vals, i), do: {:ok, {:bool, true}, i}
  defp mysqli_thread_id(_vals, i), do: {:ok, {:int, 1}, i}
  defp mysqli_stat(vals, i), do: {:ok, {:string, "Uptime: 1  Threads: 1"}, i}
  defp mysqli_store_result(vals, i), do: {:ok, val(vals) || {:bool, false}, i}
end
