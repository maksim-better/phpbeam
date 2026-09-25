defmodule PhpBeam.Eval.Generator do
  @moduledoc """
  Generator coroutines: start_generator spawns the body process, gen_resume
  drives it, gen_yield is the yield-side handshake. Moved verbatim (P2c);
  Eval keeps the yield eval clauses delegating here.
  """

  alias PhpBeam.Eval
  alias PhpBeam.{Env, Error, Interp, PArray, Pattern, Value}

  def start_generator(fenv, body, env, interp) do
    me = self()

    pid =
      spawn(fn ->
        receive do
          {:gen_start, driver, ii} ->
            ctx = %{
              driver: driver,
              key: 0,
              file: top_file(ii),
              ns: ii.ns,
              uses: ii.uses
            }

            i0 = %{ii | gen_ctx: ctx}

            case Interp.exec_stmts(body, fenv, i0) do
              {:ok, _, i2} ->
                send(
                  i2.gen_ctx.driver,
                  {:gen_done, :null, strip_gen(strip_def_file(i2, i2.gen_ctx.file))}
                )

              {{:unwind, {:return, v}}, _, i2} ->
                send(
                  i2.gen_ctx.driver,
                  {:gen_done, v, strip_gen(strip_def_file(i2, i2.gen_ctx.file))}
                )

              {{:unwind, u}, _, i2} ->
                send(
                  i2.gen_ctx.driver,
                  {:gen_throw, u, strip_gen(strip_def_file(i2, i2.gen_ctx.file))}
                )
            end
        end
      end)

    {obj_ref, interp2} = make_instance(interp, "generator")
    obj = Eval.get_object(interp2, obj_ref)

    st = %{pid: pid, started: false, done: false, k: :null, v: :null, ret: :null}

    props =
      case PArray.put(obj.props, {:string, "gen_state"}, {:gen_state, st}) do
        {:ok, p2} -> p2
        _ -> obj.props
      end

    {{:val, obj_ref}, env, Eval.put_object(interp2, obj_ref, %{obj | props: props})}
  end

  @doc """
  Resumes a Generator object. `:start` boots a fresh generator to its first
  yield; `:null` is next(); any other value is send(). Returns
  `{:yielded, k, v, interp}` | `{:done, ret, interp}` | `{:thrown, u, interp}`
  with the latest interpreter state.
  """

  def gen_resume({:object, _} = obj_ref, send_v, interp) do
    obj = Eval.get_object(interp, obj_ref)

    case PArray.get(obj.props, {:string, "gen_state"}) do
      {:gen_state, st} ->
        cond do
          st.done ->
            {:done, st.ret, interp}

          st.pid == nil ->
            {:done, :null, interp}

          true ->
            my_ctx = interp.gen_ctx
            my_ns = interp.ns
            my_uses = interp.uses
            # file_stack is per-context like ns/uses: the generator's copy
            # carries its (def-file-stripped) view — keep the driver's own,
            # or every warning/throw after a generator use loses its file
            my_files = interp.file_stack
            ref = :erlang.monitor(:process, st.pid)

            msg =
              case {st.started, send_v} do
                {false, :start} ->
                  {:gen_start, self(), strip_gen(interp)}

                {false, v} ->
                  [
                    {:gen_start, self(), strip_gen(interp)},
                    {:gen_resume, self(), v, strip_gen(interp)}
                  ]

                {true, :start} ->
                  {:gen_resume, self(), :null, strip_gen(interp)}

                {true, v} ->
                  {:gen_resume, self(), v, strip_gen(interp)}
              end

            send_each(st.pid, msg)

            receive do
              {:gen_yield, k, v, i2} ->
                :erlang.demonitor(ref, [:flush])
                i3 = put_gen_state(i2, obj_ref, %{st | started: true, done: false, k: k, v: v})

                {:yielded, k, v,
                 %{i3 | gen_ctx: my_ctx, ns: my_ns, uses: my_uses, file_stack: my_files}}

              {:gen_done, ret, i2} ->
                :erlang.demonitor(ref, [:flush])
                i3 = put_gen_state(i2, obj_ref, %{st | started: true, done: true, ret: ret})

                {:done, ret,
                 %{i3 | gen_ctx: my_ctx, ns: my_ns, uses: my_uses, file_stack: my_files}}

              {:gen_throw, u, i2} ->
                :erlang.demonitor(ref, [:flush])
                i3 = put_gen_state(i2, obj_ref, %{st | started: true, done: true})

                {:thrown, u,
                 %{i3 | gen_ctx: my_ctx, ns: my_ns, uses: my_uses, file_stack: my_files}}

              {:DOWN, _, :process, _, reason} ->
                {:thrown, {:fatal, "generator process died: #{inspect(reason)}"}, interp}
            end
        end
    end
  end

  def gen_resume(_, _, interp), do: {:done, :null, interp}

  def send_each(pid, msgs) when is_list(msgs), do: Enum.each(msgs, &send(pid, &1))

  def send_each(pid, msg), do: send(pid, msg)

  def top_file(%{file_stack: [f | _]}) when is_binary(f), do: f

  def top_file(_), do: nil

  def strip_gen(%{gen_ctx: _} = i), do: %{i | gen_ctx: nil}

  def gen_yield(env, interp, k, v, ctx2) do
    ctx = interp.gen_ctx

    case ctx do
      nil ->
        {{:unwind, {:fatal, "Cannot use \"yield\" outside of a generator"}}, env, interp}

      _ ->
        def_file = Map.get(ctx, :file)
        stripped = strip_def_file(interp, def_file)

        send(ctx.driver, {:gen_yield, k, v, %{stripped | gen_ctx: ctx2}})

        receive do
          {:gen_resume, driver2, send_v, i3} ->
            restored =
              case {def_file, i3.file_stack} do
                {f, stack} when is_binary(f) -> %{i3 | file_stack: [f | stack]}
                _ -> i3
              end

            body_scope = %{restored | ns: ctx2.ns, uses: ctx2.uses}
            {{:val, send_v}, env, %{body_scope | gen_ctx: %{ctx2 | driver: driver2}}}
        end
    end
  end

  defp put_gen_state(a, b, c), do: Eval.put_gen_state(a, b, c)
  defp strip_def_file(a, b), do: Eval.strip_def_file(a, b)
  defp make_instance(a, b), do: Eval.make_instance(a, b)

  defp method_name(a, b), do: Eval.method_name(a, b)

  defp pop_class_scope(a, b, c), do: Eval.pop_class_scope(a, b, c)

  defp push_class_scope(a, b), do: Eval.push_class_scope(a, b)
end
