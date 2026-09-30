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
      "mysqli_fetch_all" => &mysqli_fetch_all/2,
      "mysqli_fetch_column" => &mysqli_fetch_column/2,
      "mysqli_fetch_fields" => &mysqli_fetch_fields/2,
      "mysqli_fetch_field_direct" => &mysqli_fetch_field_direct/2,
      "mysqli_fetch_lengths" => &mysqli_fetch_lengths/2,
      "mysqli_field_count" => &mysqli_field_count/2,
      "mysqli_field_seek" => &mysqli_field_seek/2,
      "mysqli_field_tell" => &mysqli_field_tell/2,
      "mysqli_data_seek" => &mysqli_data_seek/2,
      "mysqli_begin_transaction" => &mysqli_begin_transaction/2,
      "mysqli_savepoint" => &mysqli_savepoint/2,
      "mysqli_release_savepoint" => &mysqli_release_savepoint/2,
      "mysqli_sqlstate" => &mysqli_sqlstate/2,
      "mysqli_warning_count" => &mysqli_warning_count/2,
      "mysqli_error_list" => &mysqli_error_list/2,
      "mysqli_errno" => &mysqli_errno/2,
      "mysqli_get_proto_info" => &mysqli_get_proto_info/2,
      "mysqli_get_server_version" => &mysqli_get_server_version/2,
      "mysqli_get_host_info" => &mysqli_get_host_info/2,
      "mysqli_get_client_version" => &mysqli_get_client_version/2,
      "mysqli_get_charset" => &mysqli_get_charset/2,
      "mysqli_thread_safe" => &mysqli_thread_safe/2,
      "mysqli_autocommit" => &mysqli_autocommit/2,
      "mysqli_kill" => &mysqli_kill/2,
      "mysqli_refresh" => &mysqli_refresh/2,
      "mysqli_debug" => &mysqli_debug/2,
      "mysqli_dump_debug_info" => &mysqli_debug/2,
      "mysqli_change_user" => &mysqli_change_user/2,
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
        {res, i2} =
          Interp.open_resource(i, %{kind: :mysqli, conn: conn, closed: false, host: host})
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
          i2 =
            Interp.put_resource(
              i,
              r,
              %{h | conn: conn2} |> Map.put(:last_field_count, length(cols))
            )

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
  defp phpify(v) when is_binary(v), do: {:string, v}
  defp phpify(v) when is_integer(v), do: {:string, Integer.to_string(v)}
  defp phpify(v) when is_float(v), do: {:string, PhpBeam.Value.float_to_string(v)}
  defp phpify(v), do: {:string, to_string(v)}

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
      {_, %{conn: %MySQL{affected_rows: a}}} ->
        File.write!("/tmp/mdb.txt", "affected=#{inspect(a)}", [:append])
        {:ok, {:int, a || 0}, i}

      _ ->
        File.write!("/tmp/mdb.txt", "nofall", [:append])
        {:ok, {:int, 0}, i}
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


  ## ───────────────── D4 batch: result cursors / fields / transactions ─────────────────

  defp mysqli_fetch_all(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli_result, rows: rows, columns: cols, cursor: c} <- Interp.get_resource(i, r) do
      # MYSQLI_ASSOC=1 NUM=2 BOTH=3 (NOTE: different values from PDO!)
      mode =
        case val(vals, 1) do
          {:int, 1} -> :assoc
          {:int, 2} -> :num
          _ -> :both
        end

      arr =
        rows
        |> Enum.drop(c)
        |> Enum.with_index()
        |> Enum.map(fn {row, k} -> {k, result_row(row, cols, mode)} end)

      i2 = Interp.put_resource(i, r, %{Interp.get_resource(i, r) | cursor: length(rows)})
      {:ok, {:array, PArray.from_pairs(arr)}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp result_row(row, _cols, :num),
    do: {:array, PArray.from_pairs(Enum.with_index(row, fn v, k -> {k, mval(v)} end))}

  defp result_row(row, cols, :assoc),
    do: {:array, PArray.from_pairs(Enum.with_index(row, fn v, k -> {Enum.at(cols, k), mval(v)} end))}

  defp result_row(row, cols, :both),
    do:
      {:array,
       PArray.from_pairs(
         Enum.with_index(row, fn v, k -> {k, mval(v)} end) ++
           Enum.with_index(row, fn v, k -> {Enum.at(cols, k), mval(v)} end)
       )}

  defp mval(nil), do: :null
  defp mval(v) when is_binary(v), do: {:string, v}
  defp mval(v) when is_integer(v), do: {:string, Integer.to_string(v)}
  defp mval(v) when is_float(v), do: {:string, PhpBeam.Value.float_to_string(v)}
  defp mval(v), do: {:string, to_string(v)}

  defp mysqli_fetch_column(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli_result, rows: rows, cursor: c} = res <- Interp.get_resource(i, r) do
      col = (match?({:int, _}, val(vals, 1)) && elem(val(vals, 1), 1)) || 0

      case Enum.at(rows, c) do
        nil ->
          {:ok, :null, i}

        row ->
          i2 = Interp.put_resource(i, r, %{res | cursor: c + 1})
          {:ok, mval(Enum.at(row, col)), i2}
      end
    else
      _ -> {:ok, :null, i}
    end
  end

  # field metadata objects (stdClass-shaped with php's field property names)
  defp field_obj(i, name, table, type_code, flags, length) do
    props =
      PArray.from_pairs([
        {"name", {:string, name}},
        {"orgname", {:string, name}},
        {"table", {:string, table}},
        {"orgtable", {:string, table}},
        {"def", {:string, ""}},
        {"db", {:string, ""}},
        {"catalog", {:string, "def"}},
        {"max_length", {:int, 0}},
        {"length", {:int, length}},
        {"charsetnr", {:int, 63}},
        {"flags", {:int, flags}},
        {"type", {:int, type_code}},
        {"decimals", {:int, 0}}
      ])

    PhpBeam.Objects.new_stdclass(i, props)
  end

  defp guess_type(v) do
    cond do
      is_integer(v) -> 3
      is_float(v) -> 5
      is_nil(v) -> 6
      true -> 253
    end
  end

  defp field_list(i, r) do
    %{kind: :mysqli_result, rows: rows, columns: cols} = Interp.get_resource(i, r)
    first = List.first(rows) || []

    cols
    |> Enum.with_index()
    |> Enum.map_reduce(i, fn {c, k}, acc ->
      v = Enum.at(first, k)
      field_obj(acc, to_string(c), "", guess_type(v), 0, len_of(v))
    end)
  end

  defp len_of(nil), do: 0
  defp len_of(v) when is_integer(v), do: String.length(Integer.to_string(v))
  defp len_of(v) when is_binary(v), do: String.length(v)
  defp len_of(v), do: String.length(to_string(v))

  defp mysqli_fetch_fields(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli_result} <- Interp.get_resource(i, r) do
      {refs, i2} = field_list(i, r)
      arr = PArray.from_pairs(Enum.with_index(refs, fn x, k -> {k, x} end))
      {:ok, {:array, arr}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_fetch_field_direct(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli_result} <- Interp.get_resource(i, r),
         {:int, idx} <- val(vals, 1) do
      {refs, i2} = field_list(i, r)

      case Enum.at(refs, idx) do
        nil -> {:ok, {:bool, false}, i2}
        ref -> {:ok, ref, i2}
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_fetch_lengths(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli_result, rows: rows, cursor: c} <- Interp.get_resource(i, r) do
      case Enum.at(rows, c - 1) do
        nil ->
          {:ok, {:bool, false}, i}

        row ->
          arr = PArray.from_pairs(Enum.with_index(row, fn v, k -> {k, {:int, len_of(v)}} end))
          {:ok, {:array, arr}, i}
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_field_count(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli, last_field_count: fc} <- Interp.get_resource(i, r) do
      {:ok, {:int, fc || 0}, i}
    else
      _ -> {:ok, {:int, 0}, i}
    end
  end

  defp mysqli_field_seek(vals, i) do
    with {:resource, _} = r <- val(vals),
         res = %{kind: :mysqli_result} <- Interp.get_resource(i, r),
         {:int, idx} <- val(vals, 1) do
      i2 = Interp.put_resource(i, r, Map.put(res, :fields_cursor, idx))
      {:ok, {:bool, true}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_field_tell(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli_result, fields_cursor: fc} <- Interp.get_resource(i, r) do
      {:ok, {:int, fc}, i}
    else
      _ -> {:ok, {:int, 0}, i}
    end
  end

  defp mysqli_data_seek(vals, i) do
    with {:resource, _} = r <- val(vals),
         res = %{kind: :mysqli_result} <- Interp.get_resource(i, r),
         {:int, idx} <- val(vals, 1) do
      i2 = Interp.put_resource(i, r, Map.put(res, :cursor, max(idx, 0)))
      {:ok, {:bool, true}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  # ── transaction / session (SQL-level, same handle) ──

  defp mysqli_begin_transaction(vals, i) do
    with {:resource, _} = r <- val(vals),
         h = %{kind: :mysqli, conn: conn} <- Interp.get_resource(i, r) do
      {:ok, _, conn2} = MySQL.query(conn, "START TRANSACTION")
      i2 = Interp.put_resource(i, r, %{h | conn: conn2})
      {:ok, {:bool, true}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_savepoint(vals, i) do
    with {:resource, _} = r <- val(vals),
         h = %{kind: :mysqli, conn: conn} <- Interp.get_resource(i, r) do
      name = s(vals, 1)
      {:ok, _, conn2} = MySQL.query(conn, "SAVEPOINT " <> name)
      i2 = Interp.put_resource(i, r, %{h | conn: conn2})
      {:ok, {:bool, true}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_release_savepoint(vals, i) do
    with {:resource, _} = r <- val(vals),
         h = %{kind: :mysqli, conn: conn} <- Interp.get_resource(i, r) do
      name = s(vals, 1)
      {:ok, _, conn2} = MySQL.query(conn, "RELEASE SAVEPOINT " <> name)
      i2 = Interp.put_resource(i, r, %{h | conn: conn2})
      {:ok, {:bool, true}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_autocommit(vals, i) do
    with {:resource, _} = r <- val(vals),
         h = %{kind: :mysqli, conn: conn} <- Interp.get_resource(i, r) do
      on = val(vals, 1) |> PhpBeam.Value.truthy?()
      {:ok, _, conn2} = MySQL.query(conn, "SET autocommit = " <> if(on, do: "1", else: "0"))
      i2 = Interp.put_resource(i, r, %{h | conn: conn2})
      {:ok, {:bool, true}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  # ── info / state ──

  defp mysqli_sqlstate(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli} <- Interp.get_resource(i, r) do
      {:ok, {:string, "00000"}, i}
    else
      _ -> {:ok, {:string, "00000"}, i}
    end
  end

  defp mysqli_warning_count(_vals, i), do: {:ok, {:int, 0}, i}

  defp mysqli_error_list(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli, errno: errno, error: err} <- Interp.get_resource(i, r) do
      arr =
        if errno do
          PArray.from_pairs([
            {0,
             {:array,
              PArray.from_pairs([
                {"errno", {:int, errno}},
                {"sqlstate", {:string, sqlstate_of(errno)}},
                {"error", {:string, err}}
              ])}}
          ])
        else
          PArray.new()
        end

      {:ok, {:array, arr}, i}
    else
      _ -> {:ok, {:array, PArray.new()}, i}
    end
  end

  defp sqlstate_of(1146), do: "42S02"
  defp sqlstate_of(1064), do: "42000"
  defp sqlstate_of(_), do: "HY000"

  defp mysqli_errno(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli, errno: errno} <- Interp.get_resource(i, r) do
      {:ok, {:int, errno || 0}, i}
    else
      _ -> {:ok, {:int, 0}, i}
    end
  end

  defp mysqli_get_proto_info(_vals, i), do: {:ok, {:int, 10}, i}
  defp mysqli_get_server_version(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli, conn: conn} <- Interp.get_resource(i, r) do
      case MySQL.query(conn, "SELECT VERSION() v") do
        {:ok, %{rows: [[v]]}, _} ->
          # 8.0.46 → 80046 (numeric fold)
          {:ok, {:int, numeric_version(v)}, i}

        _ ->
          {:ok, {:int, 80_046}, i}
      end
    else
      _ -> {:ok, {:int, 0}, i}
    end
  end

  defp numeric_version(v) do
    [maj, min | patch] = String.split(v, ".")
    p = List.first(patch) || "0"

    p =
      p
      |> String.replace(~r/[^0-9].*$/, "")
      |> case do
        "" -> "0"
        x -> x
      end

    String.to_integer(maj) * 10_000 + String.to_integer(min) * 100 + String.to_integer(p)
  end

  defp mysqli_get_host_info(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli, host: host} <- Interp.get_resource(i, r) do
      {:ok, {:string, host <> " via TCP/IP"}, i}
    else
      _ -> {:ok, {:string, "localhost via TCP/IP"}, i}
    end
  end

  defp mysqli_get_client_version(_vals, i), do: {:ok, {:int, 80_402}, i}

  defp mysqli_get_charset(vals, i) do
    with {:resource, _} = r <- val(vals),
         %{kind: :mysqli} <- Interp.get_resource(i, r) do
      props =
        PArray.from_pairs([
          {"charset", {:string, "utf8mb4"}},
          {"collation", {:string, "utf8mb4_general_ci"}},
          {"dir", {:string, ""}},
          {"min_length", {:int, 1}},
          {"max_length", {:int, 4}},
          {"number", {:int, 255}},
          {"state", {:int, 801}}
        ])

      {ref, i2} = PhpBeam.Objects.new_stdclass(i, props)
      {:ok, ref, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mysqli_thread_safe(_vals, i), do: {:ok, {:bool, true}, i}
  defp mysqli_kill(_vals, i), do: {:ok, {:bool, true}, i}
  defp mysqli_refresh(_vals, i), do: {:ok, {:bool, true}, i}
  defp mysqli_debug(_vals, i), do: {:ok, {:bool, true}, i}
  defp mysqli_change_user(_vals, i), do: {:ok, {:bool, true}, i}
end
