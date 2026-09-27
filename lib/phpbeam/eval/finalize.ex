defmodule PhpBeam.Eval.Finalize do
  @moduledoc """
  Script termination: user exception-handler dispatch, shutdown functions,
  terminal rendering. Reached from `Interp.run/run_http` with the final
  `{result, env, interp}` of the statement list.

  php runs shutdown functions on every one of these terminal paths — normal
  end, exit(), uncaught exception (output appended AFTER the fatal render,
  exit code stays 255) and engine fatals (probed php 8.4). Parse errors
  never get here (the script never ran, nothing could register).
  """

  alias PhpBeam.{Eval, Interp}

  @doc "returns {output, exit_code, interp}"
  def finish(res, env, interp) do
    # php's session module writes $_SESSION at shutdown before user fns run
    interp0 = PhpBeam.Builtin.SessionFns.shutdown_write(interp)
    {out, code, interp2} = terminal(res, env, interp0)
    # terminal() already flattened prior output into `out`; shutdown writes
    # start from a clean buffer and are appended behind it
    {extra, override, interp3} = run_shutdown(env, %{interp2 | out: []})
    {out <> extra, override || code, interp3}
  end

  defp terminal(:ok, _env, interp), do: Interp.finish(interp, 0)
  defp terminal({:unwrap, _}, _env, interp), do: Interp.finish(interp, 0)
  defp terminal({:unwind, {:halt, code}}, _env, interp), do: Interp.finish(interp, code)

  defp terminal({:unwind, {:php_throw, val}}, env, interp) do
    case interp.exception_handlers do
      [cb | _] -> exception_handler_terminal(cb, val, env, interp)
      [] -> {Interp.render_uncaught(val, interp), 255, interp}
    end
  end

  defp terminal({:unwind, {:fatal, msg}}, _env, interp),
    do: {Interp.uncaught_out(interp, "Error", msg), 255, interp}

  defp terminal({:unwind, {:engine_fatal, msg}}, _env, interp),
    do: {Interp.engine_fatal_out(interp, msg), 255, interp}

  defp terminal({:unwind, {:parse_error, msg, file, line}}, _env, interp),
    do: {Interp.parse_error_out(interp, "syntax error, " <> msg, file, line), 255, interp}

  # set_exception_handler: the handler replaces the Uncaught render; the
  # script then terminates (probed php 8.4: exit code 0, no further output)
  defp exception_handler_terminal(cb, val, env, interp) do
    {obj, interp2} =
      case val do
        {:native_error, _, _} -> Eval.materialize_native(val, interp)
        ref -> {ref, interp}
      end

    case Eval.call_cb(cb, [obj], env, interp2) do
      {{:val, _}, _, interp3} -> Interp.finish(interp3, 0)
      {{:unwind, u}, _, interp3} -> {unwind_render(u, interp3), 255, interp3}
      {:unwind, u, _, interp3} -> {unwind_render(u, interp3), 255, interp3}
    end
  end

  defp unwind_render({:php_throw, v}, interp), do: Interp.render_uncaught(v, interp)
  defp unwind_render({:fatal, msg}, interp), do: Interp.uncaught_out(interp, "Error", msg)
  defp unwind_render({:engine_fatal, msg}, interp), do: Interp.engine_fatal_out(interp, msg)

  # FIFO; args captured at registration; functions registered DURING a
  # shutdown callback also run (the threaded interp carries them). An
  # uncaught throw inside one renders like a normal uncaught error and
  # stops the queue with exit 255.
  defp run_shutdown(_env, %{shutdown_fns: []} = interp),
    do: {IO.iodata_to_binary(Enum.reverse(interp.out)), nil, interp}

  defp run_shutdown(env, interp) do
    [{cb, args} | rest] = interp.shutdown_fns

    case Eval.call_cb(cb, args, env, %{interp | shutdown_fns: rest}) do
      {{:val, _}, _, interp2} -> run_shutdown(env, interp2)
      {{:unwind, u}, _, interp2} -> {unwind_render(u, interp2), 255, interp2}
      {:unwind, u, _, interp2} -> {unwind_render(u, interp2), 255, interp2}
    end
  end
end
