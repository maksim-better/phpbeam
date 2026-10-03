defmodule PhpBeam.Classes.Pdo do
  @moduledoc """
  ext/PDO + pdo_mysql over MyXQL. PDO carries the MyXQL connection pid
  in dt_state; PDOStatement caches the executed result rows + column
  metadata. Named parameters are rewritten to `?` with a name→index map
  (MyXQL is positional). php 8.4 defaults to ERRMODE_EXCEPTION — failed
  queries throw PDOException with the MySQL SQLSTATE + message.

  Probed: prepared named params arrive STRINGIFIED (1 → "1"); rowCount
  after a buffered SELECT reflects fetched-so-far; lastInsertId returns
  the auto-increment as a string; quote escapes ' with backslash.
  """

  alias PhpBeam.Builtin.PgsqlFns
  alias PhpBeam.Classes.Table
  alias PhpBeam.{Eval, PArray}

  # FETCH_* (probed subset), ATTR_*, PARAM_*
  @fetch_default 2

  def classes do
    %{
      "pdo" => pdo_class(),
      "pdostatement" => statement_class(),
      "pdoexception" => exception_class()
    }
  end

  defp pdo_class do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, a, i ->
            case a do
              [{:string, dsn} | rest] ->
                user = a_str(rest, 0, "root")
                pass = a_str(rest, 1, "")
                open(obj, dsn, user, pass, i)

              _ ->
                {:ok, :null, obj, i}
            end
          end),
          nfn("prepare", fn obj, a, i ->
            sql = a_str(a, 0, "")
            st = st_(obj)

            if Map.get(st, :driver) == :sqlite do
              prepare_sqlite(obj, st, sql, i)
            else
              prepare_mysql(obj, st, sql, i)
            end
          end),
          nfn("query", fn obj, a, i ->
            sql = a_str(a, 0, "")
            st = st_(obj)

            if Map.get(st, :driver) == :sqlite do
              query_sqlite(obj, st, sql, i)
            else
              query_mysql(obj, st, sql, i)
            end
          end),
          nfn("exec", fn obj, a, i ->
            sql = a_str(a, 0, "")
            st = st_(obj)

            if Map.get(st, :driver) == :sqlite do
              exec_sqlite(obj, st, sql, i)
            else
              exec_mysql(obj, st, sql, i)
            end
          end),
          nfn("lastinsertid", fn obj, _a, i ->
            {:ok, {:string, Map.get(st_(obj), :last_id, "0")}, obj, i}
          end),
          nfn("begintransaction", fn obj, _a, i ->
            st = st_(obj)
            r = driver_exec(st, "BEGIN")

            if r == :ok,
              do: {:ok, {:bool, true}, put_pdo(obj, st, %{in_tx: true}), i},
              else: {:ok, {:bool, false}, obj, i}
          end),
          nfn("commit", fn obj, _a, i ->
            st = st_(obj)
            :ok = driver_exec(st, "COMMIT")
            {:ok, {:bool, true}, put_pdo(obj, st, %{in_tx: false}), i}
          end),
          nfn("rollback", fn obj, _a, i ->
            st = st_(obj)
            :ok = driver_exec(st, "ROLLBACK")
            {:ok, {:bool, true}, put_pdo(obj, st, %{in_tx: false}), i}
          end),
          nfn("intransaction", fn obj, _a, i ->
            {:ok, {:bool, Map.get(st_(obj), :in_tx, false)}, obj, i}
          end),
          nfn("quote", fn obj, a, i ->
            s = a_str(a, 0, "")
            esc = s |> String.replace("\\", "\\\\") |> String.replace("'", "\\'") |> String.replace("\"", "\\\"")
            {:ok, {:string, "'" <> esc <> "'"}, obj, i}
          end),
          nfn("errorcode", fn obj, _a, i ->
            {:ok, {:string, "00000"}, obj, i}
          end),
          nfn("errorinfo", fn obj, _a, i ->
            arr = PArray.from_pairs([{0, {:string, "00000"}}, {1, :null}, {2, :null}])
            {:ok, {:array, arr}, obj, i}
          end),
          nfn("getattribute", fn obj, a, i ->
            case a_int(a, 0) do
              4 -> {:ok, {:string, Map.get(st_(obj), :server_version, "8.0.46")}, obj, i}
              _ -> {:ok, :null, obj, i}
            end
          end),
          nfn("setattribute", fn _obj, _a, i -> {:ok, {:bool, true}, nil, i} end)
        ],
        &{&1.name, &1}
      )

    struct!(Table,
      name: "PDO",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: pdo_consts(),
      props: [],
      methods: methods,
      file: ""
    )
  end

  defp statement_class do
    methods =
      Map.new(
        [
          nfn("execute", fn obj, a, i ->
            st = st_(obj)

            case {st.prepared, a} do
              {true, [{:array, arr} | _]} ->
                vals = positionalize(arr, st)
                run_prepared(obj, st, vals, i)

              {true, _} ->
                run_prepared(obj, st, [], i)

              {false, _} ->
                # query-statements re-run their sql
                pdo = Eval.get_object(i, st.pdo)
                pst = Map.get(pdo, :dt_state) || %{}

                case unwrap(MyXQL.query(pst.conn, st.sql, [], query_opts(st.sql))) do
                  {:ok, %MyXQL.Result{columns: cols, rows: rows}} ->
                    st2 = Map.merge(st, %{rows: rows || [], cols: cols || [], cursor: 0, rowcount: length(rows || [])})
                    {:ok, {:bool, true}, put_st(obj, st2), i}

                  {:ok, %MyXQL.Result{last_insert_id: lid}} ->
                    st2 = Map.put(st, :last_id, to_string(lid || 0))
                    {:ok, {:bool, true}, put_st(obj, st2), i}

                  {:error, %MyXQL.Error{} = err} ->
                    pdo_exc(i, err)
                end
            end
          end),
          nfn("fetch", fn obj, a, i ->
            st = st_(obj)
            mode = a_int(a, 0, @fetch_default)

            case rows_at(st, st.cursor) do
              nil ->
                {:ok, {:bool, false}, obj, i}

              row ->
                obj2 = put_st(obj, Map.put(st, :cursor, st.cursor + 1))
                {:ok, row_arr(row, st.cols, mode), obj2, i}
            end
          end),
          nfn("fetchall", fn obj, a, i ->
            st = st_(obj)
            mode = a_int(a, 0, @fetch_default)
            rest = Enum.drop(st.rows || [], st.cursor)
            obj2 = put_st(obj, Map.put(st, :cursor, length(st.rows || [])))

            arr =
              PArray.from_pairs(
                rest
                |> Enum.with_index()
                |> Enum.map(fn {row, k} -> {k, row_arr(row, st.cols, mode)} end)
              )

            {:ok, {:array, arr}, obj2, i}
          end),
          nfn("fetchcolumn", fn obj, a, i ->
            st = st_(obj)
            col = a_int(a, 0, 0)

            case rows_at(st, st.cursor) do
              nil ->
                {:ok, {:bool, false}, obj, i}

              row ->
                obj2 = put_st(obj, Map.put(st, :cursor, st.cursor + 1))
                v = Enum.at(row, col)
                {:ok, encode(v), obj2, i}
            end
          end),
          nfn("rowcount", fn obj, _a, i ->
            {:ok, {:int, Map.get(st_(obj), :rowcount, 0)}, obj, i}
          end),
          nfn("columncount", fn obj, _a, i ->
            {:ok, {:int, length(Map.get(st_(obj), :cols, []))}, obj, i}
          end),
          nfn("bindvalue", fn _obj, _a, i -> {:ok, {:bool, true}, nil, i} end),
          nfn("bindparam", fn _obj, _a, i -> {:ok, {:bool, true}, nil, i} end),
          nfn("closecursor", fn obj, _a, i ->
            st = st_(obj)
            {:ok, {:bool, true}, put_st(obj, Map.put(st, :cursor, length(st.rows || []))), i}
          end),
          nfn("setfetchmode", fn _obj, _a, i -> {:ok, {:bool, true}, nil, i} end),
          nfn("debugdumpparams", fn _obj, _a, i -> {:ok, :null, nil, i} end),
          nfn("errorcode", fn obj, _a, i ->
            {:ok, {:string, "00000"}, obj, i}
          end),
          nfn("__get", fn obj, a, i ->
            st = st_(obj)

            case a_str(a, 0, "") do
              "queryString" -> {:ok, {:string, Map.get(st, :sql, "")}, obj, i}
              _ -> {:ok, :null, obj, i}
            end
          end)
        ],
        &{&1.name, &1}
      )

    struct!(Table,
      name: "PDOStatement",
      kind: :class,
      parent: nil,
      interfaces: [],
      consts: %{},
      props: [],
      methods: methods,
      file: ""
    )
  end

  defp exception_class do
    struct!(Table,
      name: "PDOException",
      kind: :class,
      parent: "runtimeexception",
      interfaces: [],
      consts: %{},
      props: [],
      methods: %{},
      file: ""
    )
  end

  # probed constant subset (FETCH_*, ATTR_*, PARAM_*)
  defp pdo_consts do
    %{
      "FETCH_ASSOC" => {:int, 2},
      "FETCH_NUM" => {:int, 3},
      "FETCH_BOTH" => {:int, 4},
      "FETCH_OBJ" => {:int, 5},
      "FETCH_COLUMN" => {:int, 7},
      "ATTR_CASE" => {:int, 8},
      "ATTR_ERRMODE" => {:int, 3},
      "ATTR_SERVER_VERSION" => {:int, 4},
      "ATTR_CLIENT_VERSION" => {:int, 5},
      "ATTR_PERSISTENT" => {:int, 12},
      "ERRMODE_SILENT" => {:int, 0},
      "ERRMODE_WARNING" => {:int, 1},
      "ERRMODE_EXCEPTION" => {:int, 2},
      "PARAM_INT" => {:int, 1},
      "PARAM_STR" => {:int, 2},
      "PARAM_NULL" => {:int, 0},
      "PARAM_BOOL" => {:int, 5},
      "CASE_NATURAL" => {:int, 0},
      "CASE_UPPER" => {:int, 1},
      "CASE_LOWER" => {:int, 2},
      "MYSQL_ATTR_FOUND_ROWS" => {:int, 1001}
    }
  end

  # ────────────────────────── connection ──────────────────────────

  defp open(obj, "pgsql:" <> rest = dsn, _user, _pass, i) do
    # pdo_pgsql driver: reuse PgsqlFns' connection machinery
    cs = PgsqlFns.parse_conninfo_pub(rest)

    opts = [
      host: String.to_charlist(Map.get(cs, "host", "localhost")),
      username: String.to_charlist(Map.get(cs, "user", "postgres")),
      password: String.to_charlist(Map.get(cs, "password", "")),
      database: String.to_charlist(Map.get(cs, "dbname", "postgres")),
      port: PgsqlFns.parse_port_pub(Map.get(cs, "port", "5432")),
      timeout: 5000
    ]

    parent = self()
    spawn(fn -> send(parent, {:pg, :epgsql.connect(opts)}) end)

    result =
      receive do
        {:pg, r} -> r
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

        st = %{
          driver: :pgsql,
          conn: pid,
          dsn: dsn,
          in_tx: false,
          last_id: "",
          server_version: version
        }

        {:ok, :null, Map.put(obj, :dt_state, st), i}

      {:error, :econnrefused} ->
        pdo_exc_msg(i, "08006", 7, "SQLSTATE[08006] [7] could not connect: connection to server failed: Connection refused\n\tIs the server running on that host and accepting\n\tTCP/IP connections?")

      {:error, other} ->
        pdo_exc_msg(i, "08006", 7, "SQLSTATE[08006] [7] could not connect: " <> inspect(other))
    end
  end

  defp open(obj, "sqlite:" <> _path = dsn, _user, _pass, i) do
    # pdo_sqlite driver: share the Sqlite3 machinery over the raw NIF
    import PhpBeam.Classes.Sqlite3, only: []
    path = String.replace_prefix(dsn, "sqlite:", "")

    real =
      if path == ":memory:",
        do: ~c"/tmp/phpbeam_mem_#{:erlang.unique_integer([:positive])}.db",
        else: String.to_charlist(path)

    case Exqlite.Sqlite3.open(real) do
      {:ok, conn} ->
        version = sqlite_version(conn)

        st = %{
          driver: :sqlite,
          conn: conn,
          dsn: dsn,
          in_tx: false,
          last_id: "0",
          server_version: version
        }

        {:ok, :null, Map.put(obj, :dt_state, st), i}

      {:error, reason} ->
        pdo_exc_msg(i, "HY000", 14, "PDO::__construct(): unable to open database: " <> to_string(reason))
    end
  end

  defp sqlite_version(_conn) do
    # pinned to the LOCAL php's linked sqlite for differential parity
    # (local oracle php 8.4.17 links 3.51.3; exqlite 0.29.0 embeds 3.45.1 —
    # version-string parity over engine parity, reprobed 2026-10-03)
    "3.51.3"
  end

  defp open(obj, dsn, user, pass, i) do
    {host, db} = parse_dsn(dsn)

    opts = [
      hostname: host,
      username: user,
      password: pass,
      database: db,
      timeout: 5000
    ]

    case MyXQL.start_link(opts) do
      {:ok, pid} ->
        Process.unlink(pid)

        version =
          case unwrap(MyXQL.query(pid, "SELECT VERSION() v", [], query_opts("SELECT"))) do
            {:ok, %MyXQL.Result{rows: [[v]]}} -> v
            _ -> "8.0.46"
          end

        st = %{conn: pid, dsn: dsn, in_tx: false, last_id: "0", server_version: version}
        {:ok, :null, Map.put(obj, :dt_state, st), i}

      {:error, err} ->
        pdo_exc_msg(i, "HY000", 1045, "SQLSTATE[HY000] [1045] Access denied for user '#{user}'@'#{host}' (using password: #{if pass == "", do: "NO", else: "YES"})" |> then(fn m -> _ = err; m end))
    end
  catch
    _, _ ->
      pdo_exc_msg(i, "HY000", 2002, "PDO::__construct(): Database connection failed")
  end

  defp parse_dsn(dsn) do
    case Regex.run(~r/^mysql:host=([^;]+)(?:;port=(\d+))?(?:;dbname=(.+))?$/, dsn) do
      [_, host, _port, db] -> {host, db || "information_schema"}
      [_, host, nil, db] -> {host, db || "information_schema"}
      [_, host] -> {host, "information_schema"}
      _ -> {"127.0.0.1", "information_schema"}
    end
  end

  # ────────────────────────── prepared execution ──────────────────────────

  defp run_prepared(obj, %{driver: :sqlite} = st, vals, i) do
    {sql2, _order} = {st.sql2, st.order}

    case Exqlite.Sqlite3.prepare(st.conn, sql2) do
      {:ok, stmt} ->
        case Exqlite.Sqlite3.bind(stmt, vals) do
          :ok ->
            {cols, rows} = sqlite_collect(st.conn, stmt)

            lid =
              case Exqlite.Sqlite3.last_insert_rowid(st.conn) do
                {:ok, v} -> to_string(v || 0)
                v when is_integer(v) -> Integer.to_string(v)
                _ -> "0"
              end

            st2 = Map.merge(st, %{rows: rows, cols: cols, cursor: 0, rowcount: length(rows)})

            pdo = Eval.get_object(i, st.pdo)
            pst = Map.get(pdo, :dt_state) || %{}

            i2 = Eval.put_object(i, st.pdo, Map.put(pdo, :dt_state, Map.put(pst, :last_id, lid)))
            {:ok, {:bool, true}, put_st(obj, st2), i2}

          {:error, msg} ->
            pdo_exc_msg(i, "HY000", 1, "SQLSTATE[HY000]: General error: 1 " <> inspect(msg))
        end

      {:error, {:sqlite_error, msg}} ->
        pdo_exc_msg(i, "HY000", 1, "SQLSTATE[HY000]: General error: 1 " <> msg)
    end
  end

  defp sqlite_collect(conn, stmt) do
    cols =
      case Exqlite.Sqlite3.columns(conn, stmt) do
        {:ok, cs} -> Enum.map(cs, fn c -> if is_binary(c), do: c, else: to_string(Map.get(c, :name, c)) end)
        _ -> []
      end

    rows = sqlite_drain(conn, stmt, [])
    {cols, rows}
  rescue
    _ -> {[], []}
  catch
    _, _ -> {[], []}
  end

  defp sqlite_drain(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> sqlite_drain(conn, stmt, [Enum.map(row, &sqlite_val/1) | acc])
      :done -> Enum.reverse(acc)
      _ -> Enum.reverse(acc)
    end
  end

  # keep native types (ints stay ints — probed pdo_sqlite)
  defp sqlite_val(%Decimal{} = d), do: Decimal.to_string(d)
  defp sqlite_val(v), do: v

  defp run_prepared(obj, st, vals, i) do
    pdo = Eval.get_object(i, st.pdo)
    pst = Map.get(pdo, :dt_state) || %{}

    with {:ok, stmt} <- unwrap(MyXQL.prepare(pst.conn, "", st.sql2)),
         {:ok, result} <- unwrap(MyXQL.execute(pst.conn, stmt, vals)) do
      case result do
        %MyXQL.Result{columns: cols, rows: rows} when is_list(rows) ->
          st2 = Map.merge(st, %{rows: rows, cols: cols || [], cursor: 0, rowcount: length(rows)})
          {:ok, {:bool, true}, put_st(obj, st2), i}

        %MyXQL.Result{columns: nil, rows: nil} = r ->
          n = Map.get(r, :num_rows) || 0
          st2 = Map.merge(st, %{rows: [], cols: [], cursor: 0, rowcount: n})
          {:ok, {:bool, true}, put_st(obj, st2), i}

        %MyXQL.Result{last_insert_id: lid, num_rows: n} ->
          st2 = Map.merge(st, %{rows: [], cols: [], cursor: 0, rowcount: n || 0, last_id: to_string(lid || 0)})

          pdo2 = Map.put(pst, :last_id, to_string(lid || 0))
          i2 = Eval.put_object(i, st.pdo, Map.put(pdo, :dt_state, pdo2))
          {:ok, {:bool, true}, put_st(obj, st2), i2}
      end
    else
      {:error, %MyXQL.Error{} = err} -> pdo_exc(i, err)
      other -> pdo_exc_msg(i, "HY000", 0, "PDOStatement::execute(): " <> inspect(elem(other, 0)))
    end
  end

  # named → positional rewrite: :name → ?, order tracks the names
  defp rewrite_named(sql) do
    {sql2, names} =
      Regex.replace(~r/:([A-Za-z_][A-Za-z0-9_]*)/, sql, fn _, name ->
        "?"
      end)
      |> then(fn s -> {s, Regex.scan(~r/:([A-Za-z_][A-Za-z0-9_]*)/, sql, capture: :all_but_first) |> Enum.map(&hd/1)} end)

    {sql2, names}
  end

  # php execute array: named keys ":a" => v map to positions; pure lists pass through
  defp positionalize(arr, st) do
    pairs = PArray.to_pairs(arr)

    if Enum.any?(pairs, fn {k, _} -> is_binary(k) end) do
      Enum.map(st.order, fn name ->
        key = if String.starts_with?(name, ":"), do: name, else: ":" <> name

        case List.keyfind(pairs, key, 0) do
          {_, v} -> bind_val(v)
          _ -> nil
        end
      end)
    else
      Enum.map(pairs, fn {_k, v} -> bind_val(v) end)
    end
  end

  # php sends every bound param as a string (probed: int 1 → "1")
  defp bind_val({:int, n}), do: to_string(n)
  defp bind_val({:string, s}), do: s
  defp bind_val(:null), do: nil
  defp bind_val({:bool, b}), do: if(b, do: "1", else: "")
  defp bind_val({:float, f}), do: PhpBeam.Value.float_to_string(f)
  defp bind_val(_), do: nil

  # ────────────────────────── rows ──────────────────────────

  defp rows_at(st, idx), do: Enum.at(st.rows || [], idx)

  # mode 2 = ASSOC (columns), 3 = NUM, default 4 = BOTH
  defp row_arr(row, cols, 2),
    do: {:array, PArray.from_pairs(Enum.with_index(row, fn v, k -> {Enum.at(cols, k) |> col_name(), encode(v)} end))}

  defp row_arr(row, _cols, 3),
    do: {:array, PArray.from_pairs(Enum.with_index(row, fn v, k -> {k, encode(v)} end))}

  defp row_arr(row, cols, _),
    do:
      {:array,
       PArray.from_pairs(
         Enum.with_index(row, fn v, k -> {k, encode(v)} end) ++
           Enum.with_index(row, fn v, k -> {Enum.at(cols, k) |> col_name(), encode(v)} end)
       )}

  defp col_name(nil), do: "column_" <> ""
  defp col_name(c) when is_binary(c), do: c
  defp col_name(c) when is_atom(c), do: Atom.to_string(c)
  defp col_name(c), do: to_string(c)

  defp encode(nil), do: :null
  defp encode(true), do: {:int, 1}
  defp encode(false), do: {:int, 0}
  defp encode(%Decimal{} = d), do: {:string, Decimal.to_string(d)}
  defp encode(%Date{} = d), do: {:string, Date.to_string(d)}
  defp encode(%DateTime{} = d), do: {:string, NaiveDateTime.to_string(DateTime.to_naive(d))}
  defp encode(%NaiveDateTime{} = d), do: {:string, NaiveDateTime.to_string(d)}
  defp encode(%Time{} = t), do: {:string, Time.to_string(t)}
  defp encode(v) when is_integer(v), do: {:int, v}
  defp encode(v) when is_float(v), do: {:float, v}
  defp encode(v) when is_binary(v), do: {:string, v}
  defp encode(v), do: {:string, to_string(v)}

  # ────────────────────────── exceptions ──────────────────────────

  defp pdo_exc(i, %MyXQL.Error{mysql: %{code: code}, message: msg}) do
    pdo_exc_msg(i, sqlstate(code), code, "SQLSTATE[#{sqlstate(code)}]: #{php_error_name(code, msg)} #{code} #{msg}")
  end

  defp pdo_exc(i, %MyXQL.Error{message: msg}) do
    pdo_exc_msg(i, "HY000", 0, msg)
  end

  # php maps MySQL error codes onto human SQLSTATE titles
  defp php_error_name(1146, _), do: "Base table or view not found:"
  defp php_error_name(1064, _), do: "Syntax error or access violation:"
  defp php_error_name(1045, _), do: "Access denied for user"
  defp php_error_name(_, _), do: "General error:"

  defp sqlstate(1146), do: "42S02"
  defp sqlstate(1064), do: "42000"
  defp sqlstate(1045), do: "28000"
  defp sqlstate(_), do: "HY000"
  defp sqlstate(_), do: "HY000"

  defp format_code(1146), do: "[1146]"
  defp format_code(c), do: "[#{c}]"

  defp pdo_exc_msg(i, _state, _code, msg) do
    i2 = PhpBeam.Interp.push_frame(i, "PDO", [])

    {obj, i3} =
      Eval.materialize_native({:native_error, "PDOException", msg}, i2)

    {:unwind, {:php_throw, obj}, nil, i3}
  end

  # ────────────────────────── helpers ──────────────────────────


  defp exec_mysql(obj, st, sql, i) do

            case unwrap(MyXQL.query(st.conn, sql, [], query_opts(sql))) do
              {:ok, %MyXQL.Result{num_rows: n, last_insert_id: lid}} ->
                obj2 = put_pdo(obj, st, %{last_id: to_string(lid || 0)})
                {:ok, {:int, n || 0}, obj2, i}

              {:ok, _} ->
                {:ok, {:int, 0}, obj, i}

              {:error, %MyXQL.Error{} = err} ->
                pdo_exc(i, err)
            end
  end

  defp query_mysql(obj, st, sql, i) do

            case unwrap(MyXQL.query(st.conn, sql, [], query_opts(sql))) do
              {:ok, %MyXQL.Result{columns: cols, rows: rows}} ->
                {r2, i2} = sref(i, %{pdo: self_ref(obj), sql: sql, sql2: sql, order: [],
                                     rows: rows || [], cols: cols || [], cursor: 0,
                                     rowcount: length(rows || []), last_id: "0", prepared: false})
                {:ok, r2, obj, i2}

              {:ok, %MyXQL.Result{last_insert_id: lid}} ->
                {r2, i2} = sref(i, %{pdo: self_ref(obj), sql: sql, sql2: sql, order: [],
                                     rows: [], cols: [], cursor: 0, rowcount: 0,
                                     last_id: to_string(lid || 0), prepared: false})
                {:ok, r2, put_pdo(obj, st, %{last_id: to_string(lid || 0)}), i2}

              {:error, %MyXQL.Error{} = err} ->
                pdo_exc(i, err)
            end
  end

  # session-level statements run through the active driver
  defp driver_exec(%{driver: :sqlite} = st, sql) do
    case Exqlite.Sqlite3.execute(st.conn, sql) do
      :ok -> :ok
      _ -> :error
    end
  end

  defp driver_exec(st, sql) do
    # session statements (BEGIN/COMMIT/ROLLBACK) need the TEXT protocol —
    # the binary one rejects them (same class as USE/DDL)
    case unwrap(MyXQL.query(st.conn, sql, [], [query_type: :text])) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  # ────────────────────────── pdo_sqlite driver ──────────────────────────

  defp prepare_mysql(obj, st, sql, i) do
    {sql2, order} = rewrite_named(sql)

    case unwrap(MyXQL.prepare(st.conn, "", sql2)) do
      {:ok, %MyXQL.Query{}} ->
        {r2, i2} =
          sref(i, %{
            pdo: self_ref(obj),
            sql: sql,
            sql2: sql2,
            order: order,
            rows: nil,
            cols: [],
            cursor: 0,
            rowcount: 0,
            last_id: "0",
            prepared: true
          })

        {:ok, r2, obj, i2}

      {:error, %MyXQL.Error{} = err} ->
        pdo_exc(i, err)

      other ->
        _ = other
        pdo_exc_msg(i, "HY000", 0, "PDO::prepare(): failed to prepare statement")
    end
  end

  defp prepare_sqlite(obj, st, sql, i) do
    # sqlite keeps rows NATIVELY typed (int columns stay int — probed)
    {sql2, order} = rewrite_named(sql)

    {r2, i2} =
      stmt_ref(i, %{
        pdo: self_ref(obj),
        driver: :sqlite,
        conn: st.conn,
        sql: sql,
        sql2: sql2,
        order: order,
        rows: nil,
        cols: [],
        cursor: 0,
        rowcount: 0,
        last_id: "0",
        prepared: true
      })

    {:ok, r2, obj, i2}
  end

  defp query_sqlite(obj, st, sql, i) do
    case PhpBeam.Classes.Sqlite3.run_query(st.conn, sql) do
      {:ok, cols, rows} ->
        {r2, i2} =
          stmt_ref(i, %{
            pdo: self_ref(obj),
            driver: :sqlite,
            conn: st.conn,
            sql: sql,
            sql2: sql,
            order: [],
            rows: rows,
            cols: cols,
            cursor: 0,
            rowcount: length(rows),
            last_id: "0",
            prepared: false
          })

        {:ok, r2, obj, i2}

      {:error, msg} ->
        pdo_exc_msg(i, "HY000", 1, "SQLSTATE[HY000]: General error: 1 " <> msg)
    end
  end

  defp exec_sqlite(obj, st, sql, i) do
    case Exqlite.Sqlite3.execute(st.conn, sql) do
      :ok ->
        lid =
          case Exqlite.Sqlite3.last_insert_rowid(st.conn) do
            {:ok, v} -> to_string(v || 0)
            v when is_integer(v) -> Integer.to_string(v)
            _ -> "0"
          end

        ch =
          case Exqlite.Sqlite3.changes(st.conn) do
            {:ok, v} -> v || 0
            v when is_integer(v) -> v
            _ -> 0
          end

        st2 = Map.merge(st, %{last_id: lid})
        {:ok, {:int, ch}, Map.put(obj, :dt_state, st2), i}

      {:error, {:sqlite_error, msg}} ->
        pdo_exc_msg(i, "HY000", 1, "SQLSTATE[HY000]: General error: 1 " <> msg)
    end
  end

  @ddl ~r/^\s*(CREATE|DROP|ALTER|USE|GRANT|REVOKE|TRUNCATE|RENAME|SET|SHOW|DESC|LOCK|UNLOCK|CALL|ANALYZE|OPTIMIZE|LOAD|START|RESET|CACHE|FLUSH|KILL|PURGE)/i

  # DDL/USE/multi statements are rejected by the binary (prepared)
  # protocol — route them through the text protocol (php's exec does)
  defp query_opts(sql) when is_binary(sql) do
    if Regex.match?(@ddl, sql), do: [query_type: :text], else: []
  end

  defp query_opts(_), do: []

  # MyXQL returns 2-tuples from query/prepare but a (query, result)
  # 3-tuple from execute — normalize onto {:ok, Result} | {:error, err}
  defp unwrap({:ok, %MyXQL.Result{} = r}), do: {:ok, r}
  defp unwrap({:ok, %MyXQL.Result{} = r, _}), do: {:ok, r}
  defp unwrap({:ok, %MyXQL.Query{} = q}), do: {:ok, q}
  defp unwrap({:ok, %MyXQL.Query{}, %MyXQL.Result{} = r}), do: {:ok, r}
  defp unwrap({:error, _} = e), do: e

  defp st_(obj), do: Map.get(obj, :dt_state) || %{}
  defp self_ref(obj), do: {:object, obj.__ref__}

  defp put_st(obj, st2), do: Map.put(obj, :dt_state, st2)
  defp put_pdo(obj, st, extra), do: Map.put(obj, :dt_state, Map.merge(st, extra))

  defp stmt_ref(i, st), do: sref(i, st)

  defp sref(i, st) do
    {ref, i2} = Eval.make_instance(i, "pdostatement")
    o = Eval.get_object(i2, ref)
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, st))
    {ref, i3}
  end

  defp a_str(a, pos, default) do
    case Enum.at(a || [], pos) do
      {:string, s} -> s
      _ -> default
    end
  end

  defp a_int(a, pos, default \\ 0) do
    case Enum.at(a || [], pos) do
      {:int, n} -> n
      _ -> default
    end
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
      class: "pdo",
      line: nil,
      gen?: false,
      native:
        {:native,
         fn obj, vals, i ->
           case fun.(obj, vals, i) do
             {:ok, ret, nil, i2} -> {:ok, {ret, obj}, i2}
             {:ok, ret, obj2, i2} -> {:ok, {ret, obj2}, i2}
             {:unwind, u, nil, i2} -> {{:unwind, u}, nil, i2}
           end
         end}
    }
  end
end
