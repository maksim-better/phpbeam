defmodule PhpBeam.Builtin.ProcFns do
  @moduledoc """
  Process execution family: proc_open/proc_close/proc_terminate/proc_get_status
  plus the synchronous exec/system/passthru/shell_exec and the escapers.

  Mechanics: one Port per child. fd0/fd1 ride the port's stdio — the interp
  process owns the port's mailbox, so reads drain it non-blockingly and wait
  only when the pipe has no data yet. An fd2 PIPE is served through a temp
  file the child's stderr is redirected to (plain ports cannot separate
  stderr). String commands run via `/bin/sh -c` (probed: `echo shell-$0`
  prints "shell-sh"); array commands via `/usr/bin/env` for PATH lookup
  (probed: ['git','--version'] works, no shell).

  v1 bounds (registered in docs/matrix/deferred.md): no stdin EOF (fclose on
  the fd0 pipe is a no-op mark), descriptor 'file'/'redirect' forms ignored,
  proc_terminate is Port.close, get_status approximations.
  """

  alias PhpBeam.PArray
  alias PhpBeam.Value

  @read_wait_cap_ms 10_000

  def register(fns) do
    plain =
      Map.new(
        %{
          "proc_close" => &proc_close/2,
          "proc_terminate" => &proc_terminate/2,
          "proc_get_status" => &proc_get_status/2,
          "system" => &system_fn/2,
          "passthru" => &passthru_fn/2,
          "shell_exec" => &shell_exec_fn/2,
          "escapeshellarg" => &escapeshellarg/2,
          "escapeshellcmd" => &escapeshellcmd/2
        },
        fn {n, f} -> {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}} end
      )

    fns
    |> Map.merge(plain)
    |> Map.merge(%{
      "proc_open" => %{fun: fn v, i, _c -> proc_open(v, i) end, refs: [2], skip_eval_refs: [2]},
      "exec" => %{fun: fn v, i, _c -> exec_fn(v, i) end, refs: [1, 2], skip_eval_refs: [1, 2]}
    })
  end

  ## ───────────────────────── proc_open ─────────────────────────

  # vals: [cmd, spec, &pipes-AST] (slot 2 raw via skip_eval_refs)
  defp proc_open(vals, i) do
    cmd = List.first(vals)
    {:array, spec} = Enum.at(vals, 1) || {:array, PArray.new()}

    with {:ok, exe, args, tmp2} <- spawn_plan(cmd, pipe_fd?(spec, 2)),
         {:ok, port} <- spawn_port(exe, args) do
      {proc_r, i2} =
        PhpBeam.Interp.open_resource(i, %{
          proc: %{port: port, tmp2: tmp2, out: <<>>, eof: false, exit: nil},
          closed: false
        })

      {pairs, i3} = pipe_resources(spec, proc_r, i2)
      {:ref_call, proc_r, [cmd, {:array, spec}, {:array, PArray.from_pairs(pairs)}], i3}
    else
      {:error, _} ->
        {:ref_call, {:bool, false}, [cmd, {:array, spec}, {:array, PArray.new()}], i}
    end
  end

  defp pipe_fd?(spec, fd) do
    case PArray.get(spec, {:int, fd}) do
      {:array, inner} ->
        PArray.get(inner, {:int, 0}) == {:string, "pipe"}

      _ ->
        false
    end
  end

  defp spawn_plan({:string, s}, true) when is_binary(s) do
    tmp = tmp2_name()
    {:ok, ~c"/bin/sh", ["-c", "( #{s} ) 2>#{tmp}", "sh"], tmp}
  end

  defp spawn_plan({:string, s}, false) when is_binary(s) do
    # trailing "sh" sets $0 like php's execvp("sh", ["sh","-c",cmd]) —
    # probed: `echo shell-$0` prints "shell-sh"
    {:ok, ~c"/bin/sh", ["-c", s, "sh"], nil}
  end

  defp spawn_plan({:array, arr}, fd2_pipe?) do
    argv = for {_, v} <- PArray.to_pairs(arr), v != nil, do: Value.cast_string_unsafe(v)

    case argv do
      [] ->
        {:error, :empty_argv}

      _ ->
        if fd2_pipe? do
          tmp = tmp2_name()
          {:ok, ~c"/bin/sh", ["-c", "exec \"$@\" 2>#{tmp}", "sh" | argv], tmp}
        else
          {:ok, ~c"/usr/bin/env", argv, nil}
        end
    end
  end

  defp spawn_plan(_, _), do: {:error, :bad_cmd}

  defp tmp2_name do
    "/tmp/phpbeam_p2_" <> Integer.to_string(:erlang.unique_integer([:positive]))
  end

  defp spawn_port(exe, args) do
    try do
      {:ok, Port.open({:spawn_executable, exe}, [:binary, :exit_status, {:args, args}])}
    rescue
      _ -> {:error, :spawn}
    end
  end

  defp pipe_resources(spec, proc_r, i) do
    {pairs, i2} =
      spec
      |> PArray.to_pairs()
      |> Enum.filter(fn {k, v} -> is_integer(k) and pipe_fd?(spec, k) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({[], i}, fn {fd, _}, {acc, ia} ->
        {pipe_r, ia2} =
          PhpBeam.Interp.open_resource(ia, %{
            proc_pipe: %{proc_id: elem(proc_r, 1), fd: fd},
            out: <<>>,
            sent: 0,
            eof: false,
            closed: false
          })

        {acc ++ [{fd, pipe_r}], ia2}
      end)

    {pairs, i2}
  end

  ## ───────────────────────── pipe IO (called from StreamFns) ─────────────────────────

  # fread on an fd1 pipe: drain the port mailbox, serve from the proc buffer.
  # Waits (bounded) when empty but the child has not exited yet.
  def pipe_read(i, r, %{proc_pipe: %{proc_id: pid, fd: 1}} = res, len) do
    case PhpBeam.Interp.get_resource(i, pid) do
      %{proc: proc, closed: false} = cell ->
        proc2 = wait_for_data(drain(proc), len, @read_wait_cap_ms)
        data = binary_part(proc2.out, 0, min(len, byte_size(proc2.out)))
        rest = binary_part(proc2.out, byte_size(data), byte_size(proc2.out) - byte_size(data))
        i2 = PhpBeam.Interp.put_resource(i, pid, %{cell | proc: %{proc2 | out: rest}})
        eof? = rest == <<>> and (proc2.eof or proc2.exit != nil)
        {data, if(eof?, do: PhpBeam.Interp.put_resource(i2, r, Map.put(res, :eof, true)), else: i2)}

      _ ->
        {"", i}
    end
  end

  # fd2 rides a temp file: offset-tracked reads, re-check while running
  def pipe_read(i, r, %{proc_pipe: %{proc_id: pid, fd: 2}} = res, len) do
    case PhpBeam.Interp.get_resource(i, pid) do
      %{proc: %{tmp2: tmp2} = proc, closed: false} when is_binary(tmp2) ->
        proc2 = drain(proc)
        cell = PhpBeam.Interp.get_resource(i, pid)
        i2 = PhpBeam.Interp.put_resource(i, pid, %{cell | proc: proc2})
        read_tmp(i2, r, res, pid, tmp2, len, 3)

      _ ->
        {"", i}
    end
  end

  def pipe_read(i, _r, _res, _len), do: {"", i}

  defp read_tmp(i, r, res, pid, tmp2, len, tries) do
    case File.read(tmp2) do
      {:ok, bin} ->
        sent = Map.get(res, :sent, 0)

        cond do
          byte_size(bin) > sent ->
            take = min(len, byte_size(bin) - sent)
            data = binary_part(bin, sent, take)
            {data, PhpBeam.Interp.put_resource(i, r, Map.put(res, :sent, sent + take))}

          tries > 0 and running?(i, pid) ->
            :timer.sleep(100)
            read_tmp(i, r, PhpBeam.Interp.get_resource(i, r), pid, tmp2, len, tries - 1)

          true ->
            {"", i}
        end

      _ ->
        {"", i}
    end
  end

  defp running?(i, pid) do
    case PhpBeam.Interp.get_resource(i, pid) do
      %{proc: %{exit: nil}} -> true
      _ -> false
    end
  end

  # fwrite to the fd0 pipe pushes into the port
  def pipe_write(i, %{proc_pipe: %{proc_id: pid, fd: 0}}, data) do
    case PhpBeam.Interp.get_resource(i, pid) do
      %{proc: %{port: port}} ->
        Port.command(port, data)
        {:ok, byte_size(data), i}

      _ ->
        {:ok, 0, i}
    end
  end

  def pipe_write(i, _res, _data), do: {:ok, 0, i}

  ## port mailbox drain (non-blocking) and bounded wait
  defp drain(%{port: port} = proc) do
    receive do
      {^port, {:data, d}} -> drain(%{proc | out: proc.out <> d})
      {^port, :eof} -> drain(%{proc | eof: true})
      {^port, {:exit_status, n}} -> drain(%{proc | exit: n})
    after
      0 -> proc
    end
  end

  defp wait_for_data(%{out: out} = proc, len, left)
       when byte_size(out) >= len or proc.eof or proc.exit != nil,
       do: proc

  defp wait_for_data(proc, _len, left) when left <= 0, do: drain(proc)

  defp wait_for_data(%{port: port} = proc, len, left) do
    receive do
      {^port, {:data, d}} ->
        wait_for_data(%{proc | out: proc.out <> d}, len, left)

      {^port, :eof} ->
        %{proc | eof: true}

      {^port, {:exit_status, n}} ->
        %{proc | exit: n}
    after
      200 -> wait_for_data(drain(proc), len, left - 200)
    end
  end

  ## ───────────────────────── close / status ─────────────────────────

  defp proc_close(vals, i) do
    case List.first(vals) do
      {:resource, _} = r ->
        case PhpBeam.Interp.get_resource(i, r) do
          %{proc: proc} = cell ->
            proc2 = wait_exit(drain(proc), 10_000)
            if proc2.tmp2, do: File.rm(proc2.tmp2)
            i2 = PhpBeam.Interp.put_resource(i, r, %{cell | proc: proc2, closed: true})
            {:ok, {:int, norm_exit(proc2.exit)}, i2}

          _ ->
            {:ok, {:int, -1}, i}
        end

      _ ->
        {:ok, {:int, -1}, i}
    end
  end

  defp wait_exit(%{exit: nil, port: port} = proc, left) when left > 0 do
    receive do
      {^port, {:data, _}} -> wait_exit(proc, left)
      {^port, :eof} -> wait_exit(%{proc | eof: true}, left)
      {^port, {:exit_status, n}} -> %{proc | exit: n}
    after
      100 -> wait_exit(proc, left - 100)
    end
  end

  defp wait_exit(proc, _), do: proc

  defp norm_exit(nil), do: -1
  defp norm_exit(n), do: n

  defp proc_terminate(vals, i) do
    case List.first(vals) do
      {:resource, _} = r ->
        case PhpBeam.Interp.get_resource(i, r) do
          %{proc: %{port: port}} = cell ->
            Port.close(port)
            {:ok, {:bool, true}, PhpBeam.Interp.put_resource(i, r, put_in(cell.proc.closed, true))}

          _ ->
            {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp proc_get_status(vals, i) do
    case List.first(vals) do
      {:resource, _} = r ->
        case PhpBeam.Interp.get_resource(i, r) do
          %{proc: proc} ->
            proc2 = drain(proc)

            running = proc2.exit == nil
            os_pid = port_os_pid(proc2.port)

            arr =
              PArray.from_pairs([
                {"command", {:string, ""}},
                {"pid", {:int, os_pid || 0}},
                {"running", {:bool, running}},
                {"signaled", {:bool, false}},
                {"stopped", {:bool, false}},
                {"exitcode", {:int, proc2.exit || -1}},
                {"termsig", {:int, 0}},
                {"stopsig", {:int, 0}}
              ])

            {:ok, {:array, arr}, i}

          _ ->
            {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp port_os_pid(port) do
    case Port.info(port) do
      info when is_list(info) ->
        case :proplists.get_value(:os_pid, info) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      _ ->
        nil
    end
  end

  ## ───────────────────────── synchronous family ─────────────────────────

  defp exec_fn(vals, i) do
    cmd = Value.cast_string_unsafe(List.first(vals))

    with {:ok, out, code} <- run_sync(cmd) do
      lines = String.split(out, "\n", trim: true)
      arr = PArray.from_pairs(Enum.with_index(lines, fn l, n -> {n, {:string, l}} end))
      last = if lines == [], do: {:string, ""}, else: {:string, List.last(lines)}
      new_vals = vals |> List.replace_at(1, {:array, arr}) |> List.replace_at(2, {:int, code}) |> Enum.take(3)
      {:ref_call, last, new_vals, i}
    else
      _ -> {:ref_call, {:string, ""}, [List.first(vals), {:array, PArray.new()}, {:int, 127}], i}
    end
  end

  defp system_fn(vals, i) do
    cmd = Value.cast_string_unsafe(List.first(vals))

    with {:ok, out, _code} <- run_sync(cmd) do
      i2 = PhpBeam.Interp.write(i, out)
      lines = String.split(out, "\n", trim: true)
      last = if lines == [], do: {:bool, false}, else: {:string, List.last(lines)}
      {:ok, last, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp passthru_fn(vals, i) do
    cmd = Value.cast_string_unsafe(List.first(vals))

    with {:ok, out, _code} <- run_sync(cmd) do
      {:ok, {:bool, true}, PhpBeam.Interp.write(i, out)}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp shell_exec_fn(vals, i) do
    cmd = Value.cast_string_unsafe(List.first(vals))

    with {:ok, out, 0} <- run_sync(cmd) do
      {:ok, {:string, out}, i}
    else
      {:ok, out, _} -> {:ok, {:string, out}, i}
      _ -> {:ok, :null, i}
    end
  end

  # run to completion: collect stdout to eof + exit_status (bounded)
  defp run_sync(cmd) do
    case spawn_port(~c"/bin/sh", ["-c", "( #{cmd} ) 2>/dev/null"]) do
      {:ok, port} ->
        {out, code} = collect(port, <<>>, nil, 10_000)
        {:ok, out, code || 0}

      _ ->
        {:error, :spawn}
    end
  end

  defp collect(port, acc, exit, left) when is_integer(exit) or left <= 0,
    do: {acc, exit}

  defp collect(port, acc, exit, left) do
    receive do
      {^port, {:data, d}} -> collect(port, acc <> d, exit, left)
      {^port, :eof} -> collect(port, acc, exit, left)
      {^port, {:exit_status, n}} -> {acc, n}
    after
      100 -> collect(port, acc, exit, left - 100)
    end
  end

  ## ───────────────────────── escapers ─────────────────────────

  defp escapeshellarg(vals, i) do
    s = Value.cast_string_unsafe(List.first(vals))
    {:ok, {:string, "'" <> String.replace(s, "'", "'\\''") <> "'"}, i}
  end

  # php's metachar set: &#;`|*?~<>^()[]{}$\, " and unpaired '
  @esc_chars ~c"&#;`|*?~<>^()[]{}$\\,\x00"

  defp escapeshellcmd(vals, i) do
    s = Value.cast_string_unsafe(List.first(vals))
    {:ok, {:string, escape_cmd(s, false)}, i}
  end

  defp escape_cmd(<<c, rest::binary>>, _in_dq) when c in @esc_chars,
    do: <<?\\, c>> <> escape_cmd(rest, false)

  defp escape_cmd(<<?", rest::binary>>, in_dq),
    do: <<?\\, ?">> <> escape_cmd(rest, not in_dq)

  defp escape_cmd(<<?', rest::binary>>, true),
    do: escape_cmd(rest, true)

  defp escape_cmd(<<c, rest::binary>>, in_dq),
    do: <<c>> <> escape_cmd(rest, in_dq)

  defp escape_cmd(<<>>, _), do: ""
end
