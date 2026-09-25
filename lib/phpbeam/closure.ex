defmodule PhpBeam.Closure do
  @moduledoc """
  The two closure shapes' single authority.

  - AST (parser output, 6 elems): `{:closure, params, uses, by_ref?, body, arrow?}`
  - Runtime value (8 elems): `{:closure, params, body, captures, arrow?,
    def_file, def_line, gen?}`

  The shared `:closure` tag with different arities is a known trap
  (AGENTS.md); new code must construct via `runtime/7` and discriminate via
  `ast?/runtime?`. Bare arity matches remain only in the documented
  consumers: Eval call machinery, MiscFns callable?/callable_name.
  """

  # def_file/def_line feed php's `{closure:file:line}` naming; gen? marks a
  # generator-factory body (contains yield)
  def runtime(params, body, captures, arrow?, def_file, def_line, gen?) do
    {:closure, params, body, captures, arrow?, def_file, def_line, gen?}
  end

  def ast?({:closure, _, _, _, _, _}), do: true
  def ast?(_), do: false

  def runtime?({:closure, _, _, _, _, _, _, _}), do: true
  def runtime?(_), do: false
end
