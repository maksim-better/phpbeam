defmodule PhpBeam.Classes.Sqlite3 do
  @moduledoc """
  ext/sqlite3 over Exqlite.Sqlite3 (the raw NIF: open/exec/prepare/bind/
  step/columns). SQLite3 carries the conn reference; SQLite3Result and
  SQLite3Stmt carry the statement handle + cached rows.

  Probed: prepared :name binds with SQLITE3_* type hints keep native types;
  lastInsertRowID/changes report ints; lastErrorCode 0 with "not an error";
  escapeString leaves double quotes alone.
  """

  alias PhpBeam.Classes.Table
  alias PhpBeam.{Eval, PArray}

  def classes do
    %{
      "sqlite3" => db_class(),
      "sqlite3result" => result_class(),
      "sqlite3stmt" => stmt_class()
    }
  end

  # ────────────────────────── SQLite3 ──────────────────────────

  defp db_class do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, a, i ->
            path =
              case a do
                [{:string, p} | _] -> p
                _ -> ":memory:"
              end

            real =
              if path == ":memory:", do: ~c"/tmp/phpbeam_mem_#{:erlang.unique_integer([:positive])}.db", else: String.to_charlist(path)

            case Exqlite.Sqlite3.open(real) do
              {:ok, conn} ->
                st = %{conn: conn, path: path, real: real, closed: false, changes: 0, last_rowid: 0, last_err: "not an error", last_code: 0}
                {:ok, :null, Map.put(obj, :dt_state, st), i}

              {:error, reason} ->
                st = %{conn: nil, path: path, real: real, closed: true, changes: 0, last_rowid: 0,
                       last_err: to_string(reason), last_code: 1}
                {:ok, :null, Map.put(obj, :dt_state, st), i}
            end
          end),
          nfn("exec", fn obj, a, i ->
            st = mst(obj)
            sql = a_s(a, 0)

            case Exqlite.Sqlite3.execute(st.conn, sql) do
              :ok ->
                info =
                  case Exqlite.Sqlite3.last_insert_rowid(st.conn) do
                    {:ok, v} -> v || 0
                    v when is_integer(v) -> v
                    _ -> 0
                  end

                ch =
                  case Exqlite.Sqlite3.changes(st.conn) do
                    {:ok, v} -> v || 0
                    v when is_integer(v) -> v
                    _ -> 0
                  end

                st2 = Map.merge(st, %{last_rowid: info, changes: ch, last_err: "not an error", last_code: 0})
                {:ok, {:bool, true}, Map.put(obj, :dt_state, st2), i}

              {:error, {:sqlite_error, msg}} ->
                st2 = Map.merge(st, %{last_err: msg, last_code: 1})
                {:ok, {:bool, false}, Map.put(obj, :dt_state, st2), i}

              {:error, reason} ->
                msg = inspect(reason)
                {:ok, {:bool, false}, Map.put(obj, :dt_state, Map.merge(st, %{last_err: msg, last_code: 1})), i}
            end
          end),
          nfn("query", fn obj, a, i ->
            st = mst(obj)
            sql = a_s(a, 0)

            case run_query(st.conn, sql) do
              {:ok, cols, rows} ->
                {ref, i2} = result_obj(i, cols, rows)
                {:ok, ref, obj, i2}

              {:error, msg} ->
                {:ok, {:bool, false}, Map.put(obj, :dt_state, Map.merge(st, %{last_err: msg, last_code: 1})), i}
            end
          end),
          nfn("prepare", fn obj, a, i ->
            st = mst(obj)
            sql = a_s(a, 0)

            case Exqlite.Sqlite3.prepare(st.conn, sql) do
              {:ok, stmt} ->
                {ref, i2} = stmt_obj(i, st.conn, stmt, sql)
                {:ok, ref, obj, i2}

              {:error, {:sqlite_error, msg}} ->
                {:ok, {:bool, false}, Map.put(obj, :dt_state, Map.merge(st, %{last_err: msg, last_code: 1})), i}
            end
          end),
          nfn("lastinsertrowid", fn obj, _a, i ->
            st = mst(obj)
            n =
              case Exqlite.Sqlite3.last_insert_rowid(st.conn) do
                {:ok, v} -> v || 0
                v when is_integer(v) -> v
                _ -> st.last_rowid || 0
              end

            {:ok, {:int, n}, obj, i}
          end),
          nfn("changes", fn obj, _a, i ->
            st = mst(obj)

            n =
              case Exqlite.Sqlite3.changes(st.conn) do
                {:ok, v} -> v || 0
                v when is_integer(v) -> v
                _ -> st.changes || 0
              end

            {:ok, {:int, n}, obj, i}
          end),
          nfn("lasterrorcode", fn obj, _a, i ->
            {:ok, {:int, mst(obj).last_code || 0}, obj, i}
          end),
          nfn("lasterrormsg", fn obj, _a, i ->
            {:ok, {:string, mst(obj).last_err || "not an error"}, obj, i}
          end),
          nfn("escapestring", fn obj, a, i ->
            s = a_s(a, 0)
            esc = s |> String.replace("'", "''")
            {:ok, {:string, esc}, obj, i}
          end),
          nfn("close", fn obj, _a, i ->
            st = mst(obj)
            if st.conn && !st.closed, do: Exqlite.Sqlite3.close(st.conn)
            {:ok, :null, Map.put(obj, :dt_state, Map.put(st, :closed, true)), i}
          end),
          nfn("busytimeout", fn _obj, _a, i -> {:ok, {:bool, true}, nil, i} end),
          nfn("version", fn _obj, _a, i ->
            arr = PArray.from_pairs([{"versionString", {:string, "3.45.1"}}, {"versionNumber", {:int, 3_045_001}}])
            {:ok, {:array, arr}, nil, i}
          end),
          nfn("openblob", fn _obj, _a, i -> {:ok, {:bool, false}, nil, i} end)
        ],
        &{&1.name, &1}
      )

    struct!(Table, name: "SQLite3", kind: :class, parent: nil, interfaces: [],
              consts: sqlite3_consts(), props: [], methods: methods, file: "")
  end

  # php exposes these BOTH as class consts and bare globals — the keys
  # carry the full constant name (SQLITE3_TEXT, probed)
  defp sqlite3_consts do
    %{
      "SQLITE3_OK" => {:int, 0},
      "SQLITE3_BOTH" => {:int, 4},
      "SQLITE3_NUM" => {:int, 2},
      "SQLITE3_ASSOC" => {:int, 1},
      "SQLITE3_INTEGER" => {:int, 1},
      "SQLITE3_FLOAT" => {:int, 2},
      "SQLITE3_TEXT" => {:int, 3},
      "SQLITE3_BLOB" => {:int, 4},
      "SQLITE3_NULL" => {:int, 5},
      "SQLITE3_OPEN_READONLY" => {:int, 1},
      "SQLITE3_OPEN_READWRITE" => {:int, 2},
      "SQLITE3_OPEN_CREATE" => {:int, 4}
    }
  end

  # ────────────────────────── SQLite3Result ──────────────────────────

  defp result_class do
    methods =
      Map.new(
        [
          nfn("fetcharray", fn obj, a, i ->
            st = mst(obj)
            mode = a_i(a, 0, 4)

            case Enum.at(st.rows, st.cursor) do
              nil ->
                {:ok, {:bool, false}, obj, i}

              row ->
                obj2 = Map.put(obj, :dt_state, Map.put(st, :cursor, st.cursor + 1))
                {:ok, row_arr(row, st.cols, mode), obj2, i}
            end
          end),
          nfn("numcolumns", fn obj, _a, i ->
            {:ok, {:int, length(mst(obj).cols)}, obj, i}
          end),
          nfn("columnname", fn obj, a, i ->
            {:ok, {:string, Enum.at(mst(obj).cols, a_i(a, 0)) || ""}, obj, i}
          end),
          nfn("columntype", fn obj, a, i ->
            idx = a_i(a, 0)
            v = Enum.at(mst(obj).rows, 0) |> then(&Enum.at(&1 || [], idx))
            {:ok, {:int, col_type(v)}, obj, i}
          end),
          nfn("finalize", fn obj, _a, i -> {:ok, {:bool, true}, obj, i} end),
          nfn("reset", fn obj, _a, i ->
            st = mst(obj)
            {:ok, {:bool, true}, Map.put(obj, :dt_state, Map.put(st, :cursor, 0)), i}
          end)
        ],
        &{&1.name, &1}
      )

    struct!(Table, name: "SQLite3Result", kind: :class, parent: nil, interfaces: [],
              consts: %{}, props: [], methods: methods, file: "")
  end

  # ────────────────────────── SQLite3Stmt ──────────────────────────

  defp stmt_class do
    methods =
      Map.new(
        [
          nfn("bindvalue", fn obj, a, i ->
            st = mst(obj)
            key = a_s(a, 0)
            val = Enum.at(a, 1, :null)
            binds = Map.put(st.binds, key, val)
            {:ok, {:bool, true}, Map.put(obj, :dt_state, Map.put(st, :binds, binds)), i}
          end),
          nfn("bindparam", fn obj, a, i ->
            # by-ref params: capture the current value (deviation registered)
            st = mst(obj)
            key = a_s(a, 0)
            val = Enum.at(a, 1, :null)
            binds = Map.put(st.binds, key, val)
            {:ok, {:bool, true}, Map.put(obj, :dt_state, Map.put(st, :binds, binds)), i}
          end),
          nfn("execute", fn obj, _a, i ->
            st = mst(obj)

            vals =
              st.order
              |> Enum.map(fn k -> Map.get(st.binds, k, Map.get(st.binds, ":" <> k, :null)) end)
              |> Enum.map(&sql_val/1)

            # statements are ONE-SHOT through the raw NIF — re-prepare the
            # SQL each execute (bind map already carries the bound values)
            case Exqlite.Sqlite3.prepare(st.conn, st.sql) do
              {:ok, stmt2} ->
                case Exqlite.Sqlite3.bind(stmt2, vals) do
                  :ok ->
                    case collect_rows(st.conn, stmt2) do
                      {:ok, cols, rows} ->
                        {ref, i2} = result_obj(i, cols, rows)
                        st2 = Map.merge(st, %{cols: cols, rows: rows})
                        {ref2, i3} = Eval.make_instance(i2, "sqlite3result")
                        o = Eval.get_object(i3, ref2)
                        i4 = Eval.put_object(i3, ref2, Map.put(o, :dt_state, %{cols: cols, rows: rows, cursor: 0}))
                        _ = ref
                        {:ok, ref2, Map.put(obj, :dt_state, st2), i4}

                      {:error, msg} ->
                        exc(i, msg)
                    end

                  {:error, msg} ->
                    exc(i, inspect(msg))
                end

              {:error, {:sqlite_error, msg}} ->
                exc(i, msg)
            end
          end),
          nfn("reset", fn obj, _a, i -> {:ok, {:bool, true}, obj, i} end),
          nfn("clear", fn obj, _a, i -> {:ok, {:bool, true}, obj, i} end),
          nfn("close", fn obj, _a, i -> {:ok, {:bool, true}, obj, i} end),
          nfn("paramcount", fn obj, _a, i ->
            {:ok, {:int, length(mst(obj).order)}, obj, i}
          end),
          nfn("getsql", fn obj, _a, i ->
            {:ok, {:string, mst(obj).sql}, obj, i}
          end)
        ],
        &{&1.name, &1}
      )

    struct!(Table, name: "SQLite3Stmt", kind: :class, parent: nil, interfaces: [],
              consts: %{}, props: [], methods: methods, file: "")
  end

  # ────────────────────────── shared query machinery ──────────────────────────

  def run_query(conn, sql) do
    case Exqlite.Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        case Exqlite.Sqlite3.bind(stmt, []) do
          :ok -> collect_rows(conn, stmt)
          {:error, _} -> {:error, "bind failed"}
        end

      {:error, {:sqlite_error, msg}} ->
        {:error, msg}

      {:error, {:missuse, _}} ->
        {:error, "missuse"}
    end
  end

  defp collect_rows(conn, stmt) do
    cols =
      case Exqlite.Sqlite3.columns(conn, stmt) do
        {:ok, cs} -> Enum.map(cs, fn c -> if is_binary(c), do: c, else: to_string(Map.get(c, :name, c)) end)
        {:error, _} -> []
      end

    rows = drain(conn, stmt, [])
    {:ok, cols, rows}
  rescue
    _ -> {:error, "step failed"}
  catch
    _, _ -> {:error, "step failed"}
  end

  defp drain(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> drain(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
      _ -> Enum.reverse(acc)
    end
  end

  defp sql_val({:int, n}), do: n
  defp sql_val({:float, f}), do: f
  defp sql_val({:string, s}), do: s
  defp sql_val(:null), do: nil
  defp sql_val(v), do: to_string(v)

  defp row_arr(row, cols, 1),
    do: {:array, PArray.from_pairs(Enum.with_index(row, fn v, k -> {Enum.at(cols, k), phpv(v)} end))}

  defp row_arr(row, _cols, 2),
    do: {:array, PArray.from_pairs(Enum.with_index(row, fn v, k -> {k, phpv(v)} end))}

  defp row_arr(row, cols, _),
    do:
      {:array,
       PArray.from_pairs(
         Enum.with_index(row, fn v, k -> {k, phpv(v)} end) ++
           Enum.with_index(row, fn v, k -> {Enum.at(cols, k), phpv(v)} end)
       )}

  defp phpv(nil), do: :null
  defp phpv(v) when is_integer(v), do: {:int, v}
  defp phpv(v) when is_float(v), do: {:float, v}
  defp phpv(v) when is_binary(v), do: {:string, v}

  defp col_type(nil), do: 5
  defp col_type(v) when is_integer(v), do: 1
  defp col_type(v) when is_float(v), do: 2
  defp col_type(v) when is_binary(v), do: 3

  defp result_obj(i, cols, rows) do
    {ref, i2} = Eval.make_instance(i, "sqlite3result")
    o = Eval.get_object(i2, ref)
    st = %{cols: cols, rows: rows, cursor: 0}
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, st))
    {ref, i3}
  end

  defp stmt_obj(i, conn, stmt, sql) do
    param_count = Exqlite.Sqlite3.bind_parameter_count(stmt) || 0

    # this NIF build exposes no bind_parameter_name — derive from the SQL
    # text: each ? in order, plus :name tokens when present
    named = Regex.scan(~r/:([A-Za-z_][A-Za-z0-9_]*)/, sql, capture: :all_but_first)

    order =
      case named do
        [] -> Enum.map(1..param_count, &Integer.to_string/1)
        names -> Enum.map(names, &"#{hd(&1)}")
      end

    {ref, i2} = Eval.make_instance(i, "sqlite3stmt")
    o = Eval.get_object(i2, ref)
    st = %{conn: conn, stmt: stmt, sql: sql, binds: %{}, order: order}
    i3 = Eval.put_object(i2, ref, Map.put(o, :dt_state, st))
    {ref, i3}
  end

  defp mst(obj), do: Map.get(obj, :dt_state) || %{}

  defp exc(i, msg) do
    i2 = PhpBeam.Interp.push_frame(i, "SQLite3", [])

    {obj, i3} =
      Eval.materialize_native({:native_error, "RuntimeException", msg}, i2)

    {:unwind, {:php_throw, obj}, nil, i3}
  end

  defp a_s(a, pos), do: (v = Enum.at(a || [], pos)) && php_to_s(v)

  defp php_to_s({:string, s}), do: s
  defp php_to_s(_), do: ""

  defp a_i(a, pos, default \\ 0) do
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
      class: "sqlite3",
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
