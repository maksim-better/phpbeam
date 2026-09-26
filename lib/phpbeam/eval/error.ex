defmodule PhpBeam.Eval.Error do
  @moduledoc """
  User error-handler dispatch — zend_error_impl's handler stage. Lives at
  the Eval layer because the handler call re-enters PHP; everything else
  (recording, error_reporting filtering, display) falls through to the
  Interp output pipeline.

  Handler contract (probed php 8.4): called with (errno, errstr, errfile,
  errline) whenever the top of the handler stack registered for the level —
  @ does NOT stop the dispatch (only the later display). Returning exactly
  `false` falls through to normal display+recording; anything else swallows
  the error completely (not even error_get_last records it). An exception
  thrown inside the handler propagates out of the erroring expression.
  """

  alias PhpBeam.{Env, Eval, Interp}

  import Bitwise

  # builtin-land warn sites have no caller env; handler closures build
  # their own env from captures and the four handler args are by-value, so
  # a bare env is sufficient for the dispatch
  def stub_env, do: %Env{}

  def warn(env, interp, msg), do: emit(env, interp, 2, "Warning", msg)

  def warn_level(env, interp, prefix, msg),
    do: emit(env, interp, error_code(prefix), prefix, msg)

  # trigger_error family: the errno is the USER level (E_USER_*), not the
  # display-prefix-derived engine code — handlers must see 512/1024/16384
  def user_warn(env, interp, errno, prefix, msg), do: emit(env, interp, errno, prefix, msg)

  defp error_code("Notice"), do: 8
  defp error_code("Deprecated"), do: 8192
  defp error_code(_), do: 2

  defp emit(env, interp, type, prefix, msg) do
    # pin the position before the handler runs: its own statements update
    # cur_line, and php keeps the original error location for both the
    # handler args and any false-passthrough display
    {file, line} = pos = {Interp.current_file(interp), interp.cur_line}

    case interp.error_handlers do
      [{cb, levels} | _] when not is_nil(cb) and (levels &&& type) != 0 ->
        args = [{:int, type}, {:string, msg}, {:string, file}, {:int, line}]

        case Eval.call_cb(cb, args, env, interp) do
          {{:val, {:bool, false}}, _, i2} ->
            {:cont, env, plain_emit(i2, type, prefix, msg, pos)}

          {{:val, _}, _, i2} ->
            {:cont, env, i2}

          {{:unwind, u}, _, i2} ->
            {:unwind, u, env, i2}

          {:unwind, u, _, i2} ->
            {:unwind, u, env, i2}
        end

      _ ->
        {:cont, env, plain_emit(interp, type, prefix, msg, pos)}
    end
  end

  defp plain_emit(interp, _type, "Warning", msg, {file, line}),
    do: Interp.warn_at(interp, msg, file, line)

  defp plain_emit(interp, _type, prefix, msg, {file, line}),
    do: Interp.warn_level_at(interp, prefix, msg, file, line)
end
