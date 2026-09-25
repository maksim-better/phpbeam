defmodule PhpBeam.Repl do
  @moduledoc """
  Persistent-state read-eval-print loop: variables, functions and classes
  survive across inputs.
  """

  def start do
    IO.puts("phpx repl — PHP on BEAM (type a statement, :q to quit)")
    state = PhpBeam.Interp.repl_init()
    loop("", state)
  end

  defp loop(buffer, state) do
    prompt = if buffer == "", do: "phpx> ", else: "...   > "

    case IO.gets(prompt) do
      :eof ->
        :ok

      :error ->
        :ok

      line when line in [":q\n", ":q\r\n", ":q\r"] ->
        :ok

      "" ->
        loop(buffer, state)

      line ->
        buffer2 = buffer <> line

        if complete?(buffer2) do
          {out, state2} = PhpBeam.Interp.repl_eval(state, buffer2)
          IO.write(out)
          loop("", state2)
        else
          loop(buffer2, state)
        end
    end
  end

  defp complete?(buf) do
    src = "<?php " <> buf

    case PhpBeam.Lexer.tokenize(src) do
      {:ok, toks} ->
        case PhpBeam.Parser.parse(toks) do
          {:ok, _} -> true
          {:error, _msg, _line} -> false
        end

      {:error, _, _} ->
        false
    end
  end
end
