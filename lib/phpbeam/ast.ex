defmodule PhpBeam.Ast do
  @moduledoc """
  AST node shapes produced by `PhpBeam.Parser`.

  ## Expressions

    * `{:int, n}` `{:float, f}` `{:string, s}` `{:bool, b}` `:null`
    * `{:interp, [part]}` — part: `{:text, s}` | `{:simple, name, accessors}`
      (pre-translated to AST by the parser) | `{:complex, ast}`
    * `{:var, name}` `{:var_var, expr}`
    * `{:const, parts :: [binary]}` — constant / bare name
    * `{:cname, fq? :: boolean, parts :: [binary]}` — class references
    * `{:array, [{key | nil, value, by_ref?}]}`
    * `{:list_pat, [target | nil]}`
    * `{:index, arr, idx | nil}` `{:prop, obj, name}` `{:nullsafe_prop, obj, name}`
    * `{:static_prop, cname, name}` `{:class_const, cname, name}`
    * `{:call, callee, [arg]}` — arg: `{:arg, value, by_ref?, name | nil}`
    * `{:method_call, obj, name_ast, [arg], nullsafe?}`
    * `{:static_call, cname, name_ast, [arg]}`
    * `{:new, cls, [arg]}` `{:clone, e}`
    * `{:binop, op, l, r}` — `:+ :- :* :/ :% :** :. :== :!= :=== :!== :< :<= :> :>=
      :<=> :&& :|| :and :or :xor :& :| :^ :shl :shr :instanceof`
    * `{:unop, op, e}` — `:! :- :+ :~ :@`
    * `{:pre_inc, t}` `{:pre_dec, t}` `{:post_inc, t}` `{:post_dec, t}`
    * `{:cast, :int|:float|:string|:bool|:array|:object, e}`
    * `{:assign, target, e}` `{:assign_op, binop, target, e}` `{:assign_ref, target, e}`
    * `{:ternary, c, t, f}` `{:short_ternary, c, f}` `{:coalesce, l, r}`
    * `{:closure, [param], [use], by_ref?, body, arrow?}`
      — param: `{:param, name, [type], default | nil, by_ref?, variadic?}`
    * `{:match, subject, [{guard | :default, expr}]}`
    * `{:isset, [target]}` `{:empty, e}` `{:print, e}`
    * `{:throw, e}` `{:exit_expr, e | nil}`

  ## Statements

    * `{:html, text}` — inline HTML (echo)
    * `{:echo, [expr]}` `{:expr_stmt, e}` `{:block, [stmt]}`
    * `{:if, cond, then :: [stmt], else :: [stmt] | nil}`
    * `{:while, cond, body}` `{:do_while, body, cond}` `{:until...}` (n/a)
    * `{:for, [init], cond | nil, [step], body}`
    * `{:foreach, subject, key_target | nil, val_target, by_ref?, body}`
    * `{:switch, subject, [{[val] | :default, [stmt]}]}`
    * `{:break, n | nil}` `{:continue, n | nil}` `{:return, e | nil}`
    * `{:global, [name]}` `{:static_vars, [{name, init | nil}]}`
    * `{:func_def, name, [param], by_ref?, body}`
    * `{:unset, [target]}` `{:try_stmt, body, [{[cname], var | nil, body}], finally | nil}`
    * `{:namespace, name | nil, [stmt], braced?}`
    * `{:use, kind :: :normal | :function | :const, [{parts, as | nil}], group_prefix | nil}`
    * `{:class_def, ...}` etc. — M5
  """

  @type t :: term()
end
