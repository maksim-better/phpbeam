defmodule PhpBeam.Parser do
  @moduledoc """
  Recursive-descent parser: tokens → AST (node shapes in `PhpBeam.Ast`).

  Covers the PHP 8 functional subset: full operator precedence (including
  `or`/`and` below assignment, `**` above unary minus, right-assoc `??`),
  control flow with alternative syntax (`if: ... endif`), functions,
  closures / arrow functions, arrays, string interpolation, `match`,
  list destructuring, `try/catch/finally`, namespace/use declarations.
  Class declarations arrive in M5.
  """

  alias PhpBeam.Token

  defmodule ParseError do
    defexception [:message, :line]

    @impl true
    def message(%{message: m, line: l}), do: "#{m} on line #{l}"
  end

  @spec parse([Token.t()]) :: {:ok, [term()]} | {:error, binary(), pos_integer()}
  def parse(tokens) do
    {:ok, stmts, _rest} = program(tokens)
    {:ok, stmts}
  rescue
    # "@fatal ..." marks compile-time CHECK fatals (argument-order rules) —
    # php renders them without the "Parse error:" prefix
    e in ParseError ->
      if String.starts_with?(e.message, "@fatal ") do
        {:error, {:fatal_check, String.trim_leading(e.message, "@fatal ")}, e.line}
      else
        {:error, e.message, e.line}
      end
  end

  @doc "Parse a bare expression from a token list (interpolation bodies)."
  @spec parse_expression([Token.t()]) :: term()
  def parse_expression(tokens) do
    {ast, _rest} = expr(tokens)
    ast
  end

  @doc "Drops the `{:stmt_line, _, inner}` wrappers introduced by `statement/1`."
  def strip_lines(list) when is_list(list), do: Enum.map(list, &strip_lines/1)
  def strip_lines({:stmt_line, _, inner}), do: strip_lines(inner)

  def strip_lines(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&strip_lines/1) |> List.to_tuple()

  def strip_lines(other), do: other

  # ───────────────────────── token helpers ─────────────────────────

  defp peek([{k, l, v} | _]), do: {k, l, v}
  defp peek([]), do: {:eof, 0, :eof}

  defp peek_line([{_, l, _} | _]) when is_integer(l), do: l
  defp peek_line(_), do: 0

  defp at_op?([{k, _, v} | _], op), do: k == :op and v == op
  defp at_op?(_, _), do: false

  defp at_name?([{k, _, v} | _], name), do: k == :name and String.downcase(v) == name
  defp at_name?(_, _), do: false

  defp take_op([{k, _, v} | rest], op) when k == :op and v == op, do: {true, rest}
  defp take_op(ts, _op), do: {false, ts}

  defp take_name([{k, _, v} | rest], name) when k == :name do
    if String.downcase(v) == name, do: {true, rest}, else: {false, [{k, 0, v} | rest]}
  end

  defp take_name(ts, _name), do: {false, ts}

  defp take_ident([{k, _, v} | rest]) when k == :name, do: {v, rest}

  defp take_ident([{_, l, v} | _]),
    do: raise(ParseError, message: "expected identifier, got #{tok_desc(v)}", line: l)

  defp expect_op([{k, _, v} | rest], op) when k == :op and v == op, do: rest

  defp expect_op([{_, l, v} | _], op),
    do: raise(ParseError, message: "expected '#{op}', got #{tok_desc(v)}", line: l)

  defp expect_op([], op),
    do: raise(ParseError, message: "expected '#{op}' at end of file", line: 0)

  defp expect_semi([{k, _, v} | rest]) when k == :op and v == ";", do: rest

  defp expect_semi([{_, l, v} | _]),
    do: raise(ParseError, message: "expected ';', got #{tok_desc(v)}", line: l)

  defp tok_desc(v) when is_binary(v), do: "'#{v}'"
  defp tok_desc(_), do: "end of file"

  # ───────────────────────── program / statements ─────────────────────────

  defp program(ts, acc \\ []) do
    case peek(ts) do
      {:eof, _, _} ->
        {:ok, Enum.reverse(acc), ts}

      {_, _, _} ->
        {stmt, rest} = statement(ts)
        program(rest, [stmt | acc])
    end
  end

  # statement stream that stops at `}` (block end) or any of `stop_names`
  defp statements_until(ts, stop_names, acc \\ []) do
    cond do
      at_op?(ts, "}") ->
        {:stop, Enum.reverse(acc), ts}

      Enum.any?(stop_names, &at_name?(ts, &1)) ->
        {:stop, Enum.reverse(acc), ts}

      true ->
        case statement(ts) do
          {stmt, rest} -> statements_until(rest, stop_names, [stmt | acc])
        end
    end
  end

  defp block_body(ts) do
    {:stop, stmts, rest} = statements_until(ts, [])
    {stmts, expect_op(rest, "}")}
  end

  # `:` alternative-syntax body — stops at the given end keywords
  defp alt_body(ts, stop_names) do
    {:stop, stmts, rest} = statements_until(ts, stop_names, [])
    {stmts, rest}
  end

  # every statement carries its first token's line for warning/fatal rendering
  defp statement(ts) do
    {stmt, rest} = statement_raw(ts)

    line =
      case ts do
        [{_, l, _} | _] -> l
        _ -> 0
      end

    {{:stmt_line, line, stmt}, rest}
  end

  defp statement_raw([{_, _, _}, {:op, _, ":"} | _] = ts) do
    # `label:` statement (goto target)
    [{:name, _, label}, {:op, _, ":"} | rest] = ts
    {{:label, String.downcase(label)}, rest}
  end

  defp statement_raw(ts) do
    case peek(ts) do
      {:inline_html, _, text} ->
        {{:html, text}, tl(ts)}

      {:op, _, ";"} ->
        {{:block, []}, tl(ts)}

      {:op, _, "{"} ->
        {stmts, rest} = block_body(tl(ts))
        {{:block, stmts}, rest}

      {:name, _, n} ->
        keyword_statement(String.downcase(n), ts)

      _ ->
        expr_statement(ts)
    end
  end

  defp expr_statement(ts) do
    {e, rest} = expr(ts)
    {{:expr_stmt, e}, expect_semi(rest)}
  end

  defp keyword_statement(name, ts) do
    case name do
      "echo" ->
        echo_stmt(ts)

      "print" ->
        expr_statement(ts)

      "if" ->
        if_stmt(ts)

      "while" ->
        while_stmt(ts)

      "do" ->
        do_while_stmt(ts)

      "for" ->
        for_stmt(ts)

      "foreach" ->
        foreach_stmt(ts)

      "switch" ->
        switch_stmt(ts)

      "break" ->
        break_stmt(ts, :break)

      "continue" ->
        break_stmt(ts, :continue)

      "return" ->
        return_stmt(ts)

      "global" ->
        global_stmt(ts)

      "static" ->
        static_stmt(ts)

      "unset" ->
        unset_stmt(ts)

      "function" ->
        maybe_func_def(ts)

      "throw" ->
        throw_stmt(ts)

      "try" ->
        try_stmt(ts)

      "namespace" ->
        namespace_stmt(ts)

      "use" ->
        use_stmt(ts)

      "declare" ->
        declare_stmt(ts)

      "__halt_compiler" ->
        halt_stmt(ts)

      "const" ->
        const_stmt(ts)

      "class" ->
        class_stmt([], ts)

      "interface" ->
        class_stmt([], ts)

      "trait" ->
        class_stmt([], ts)

      "abstract" ->
        modifier_then_class(ts, "abstract")

      "final" ->
        modifier_then_class(ts, "final")

      "readonly" ->
        # `readonly class X` — consume readonly, pass empty mods through the
        # generic modifier walker so `final readonly class` also lands here
        case peek(tl(ts)) do
          {:name, _, "class"} -> class_stmt(["readonly"], [{:name, 0, "class"} | tl(tl(ts))])
          _ -> modifier_then_class(tl(ts), "readonly")
        end

      "enum" ->
        enum_stmt([], ts)

      # forward goto (labels resolved at execution time)
      "goto" ->
        {name, r1} = take_ident(tl(ts))
        {{:goto, String.downcase(name)}, expect_semi(r1)}

      _ ->
        expr_statement(ts)
    end
  end

  defp modifier_then_class(ts, mod) do
    rest0 = tl(ts)

    {mods, rest} =
      case peek(rest0) do
        {:name, _, "final"} when mod == "abstract" -> {[mod, "final"], tl(rest0)}
        {:name, _, "abstract"} when mod == "final" -> {[mod, "abstract"], tl(rest0)}
        {:name, _, "final"} when mod == "readonly" -> {[mod, "final"], tl(rest0)}
        {:name, _, "readonly"} when mod == "final" -> {[mod, "readonly"], tl(rest0)}
        _ -> {[mod], rest0}
      end

    case peek(rest) do
      {:name, _, "class"} ->
        class_stmt(mods, rest)

      {:name, _, "readonly"} ->
        class_stmt(mods ++ ["readonly"], tl(rest))

      {:name, _, "interface"} ->
        class_stmt(mods, rest)

      {:name, _, "trait"} ->
        class_stmt(mods, rest)

      {:name, _, "enum"} ->
        enum_stmt(mods, rest)

      _ ->
        raise(ParseError, message: "expected class after #{mod}", line: peek_line(rest))
    end
  end

  # ───────────────────────── classes ─────────────────────────

  defp class_stmt(mods, [{_, _, kind} | rest]) do
    {name, rest2} = take_ident(rest)
    {extends, rest3} = optional_extends(kind, rest2)
    {implements, rest4} = optional_implements(kind, rest3)

    rest5 = expect_op(rest4, "{")
    {members, rest6} = class_members(rest5, [], name)
    rest7 = expect_op(rest6, "}")

    decl = %{
      name: name,
      kind: String.to_atom(kind),
      modifiers: mods,
      extends: extends,
      implements: implements,
      # php attributes early-binding/inheritance fatals to the class' end
      end_line: peek_line(rest6),
      consts: List.flatten(Keyword.get_values(members, :consts)),
      props: List.flatten(Keyword.get_values(members, :props)),
      methods: List.flatten(Keyword.get_values(members, :methods)),
      uses: Keyword.get_values(members, :uses)
    }

    {{:class_def, decl}, rest7}
  end

  # `enum Name [: string] { use Trait; case A; case B = "b"; const/methods }`
  defp enum_stmt(mods, [{_, _, "enum"} | rest]) do
    {name, rest2} = take_ident(rest)

    {backing, rest3} =
      case take_op(rest2, ":") do
        {true, r} ->
          {t, r2} = param_type(r)
          {t, r2}

        {false, _} ->
          {nil, rest2}
      end

    {implements, rest4} = optional_implements("enum", rest3)
    rest5 = expect_op(rest4, "{")
    {members, rest6} = class_members(rest5, [], name)
    rest7 = expect_op(rest6, "}")

    decl = %{
      name: name,
      kind: :enum,
      modifiers: mods,
      backing: backing,
      extends: [],
      implements: implements,
      consts: List.flatten(Keyword.get_values(members, :consts)),
      props: [],
      methods: List.flatten(Keyword.get_values(members, :methods)),
      cases: List.flatten(Keyword.get_values(members, :cases)),
      uses: Keyword.get_values(members, :uses)
    }

    {{:enum_def, decl}, rest7}
  end

  # interfaces may extend several parents; classes/traits at most one
  defp optional_extends("interface", ts) do
    {yes, rest} = take_name(ts, "extends")

    if yes do
      {list, r} = interface_list(rest)
      {list, r}
    else
      {[], ts}
    end
  end

  defp optional_extends(_kind, ts) do
    {yes, rest} = take_name(ts, "extends")

    if yes do
      {parts, r, fq} = qualified_name(rest)
      {[{parts, fq}], r}
    else
      {[], ts}
    end
  end

  defp optional_implements("interface", ts), do: {[], ts}

  defp optional_implements(_kind, ts) do
    {yes, rest} = take_name(ts, "implements")

    if yes do
      {list, r} = interface_list(rest)
      {list, r}
    else
      {[], ts}
    end
  end

  defp interface_list(ts, acc \\ []) do
    {parts, rest, fq} = qualified_name(ts)
    {yes, rest2} = take_op(rest, ",")

    if yes do
      interface_list(rest2, [{parts, fq} | acc])
    else
      {Enum.reverse([{parts, fq} | acc]), rest}
    end
  end

  defp class_members(ts, acc, _cls) do
    cond do
      at_op?(ts, "}") ->
        {Enum.reverse(acc), ts}

      true ->
        {member, rest} = class_member(ts)
        class_members(rest, [member | acc], _cls)
    end
  end

  defp class_member(ts) do
    cond do
      at_name?(ts, "const") ->
        const_member(ts)

      at_name?(ts, "use") ->
        trait_use(ts)

      at_name?(ts, "case") ->
        case_member(ts)

      at_name?(ts, "public") or at_name?(ts, "protected") or at_name?(ts, "private") or
        at_name?(ts, "static") or at_name?(ts, "abstract") or at_name?(ts, "final") or
        at_name?(ts, "var") or at_name?(ts, "function") ->
        visibility_member(ts)

      true ->
        raise(ParseError, message: "unexpected token in class body", line: peek_line(ts))
    end
  end

  defp const_member([{_, _, "const"} | rest]) do
    {entries, rest2} = const_entries(rest, [])
    {{:consts, entries}, expect_semi(rest2)}
  end

  defp const_entries(ts, acc) do
    {name, rest} = take_ident(ts)

    {value, rest2} =
      case take_op(rest, "=") do
        {true, r} -> expr(r)
        {false, _} -> {:null, rest}
      end

    {yes, rest3} = take_op(rest2, ",")

    if yes do
      const_entries(rest3, [{name, value} | acc])
    else
      {Enum.reverse([{name, value} | acc]), rest2}
    end
  end

  defp case_member([{_, _, "case"} | rest]) do
    {cname, rest2} = take_ident(rest)

    {value, rest3} =
      case take_op(rest2, "=") do
        {true, r} ->
          {v, r2} = expr(r)
          {v, r2}

        {false, _} ->
          {nil, rest2}
      end

    {{:cases, [{cname, value}]}, expect_semi(rest3)}
  end

  defp trait_use([{_, _, "use"} | rest]) do
    {traits, rest2} = use_trait_names(rest, [])

    {adaptions, rest3} =
      if at_op?(rest2, "{") do
        {ad, r} = trait_adaptions(tl(rest2), [])
        r2 = expect_op(r, "}")
        {ad, r2}
      else
        {[], rest2}
      end

    # php: no semicolon after the adaptation block's closing brace
    if adaptions == [] do
      {{:uses, {traits, adaptions}}, expect_semi(rest3)}
    else
      {{:uses, {traits, adaptions}}, rest3}
    end
  end

  defp use_trait_names(ts, acc) do
    {parts, rest, _} = qualified_name(ts)
    {yes, rest2} = take_op(rest, ",")

    # stop if the next token opens a { block (adaptions)
    if yes and not at_op?(rest2, "{") do
      use_trait_names(rest2, [parts | acc])
    else
      if yes do
        {Enum.reverse([parts | acc]), rest2}
      else
        {Enum.reverse([parts | acc]), rest}
      end
    end
  end

  defp trait_adaptions(ts, acc) do
    if at_op?(ts, "}") do
      {Enum.reverse(acc), ts}
    else
      {ad, rest} = trait_adaption(ts)
      rest2 = expect_semi(rest)
      trait_adaptions(rest2, [ad | acc])
    end
  end

  # Insteadof: `B::m insteadof A;`  As: `B::m as x;` / `B::m as protected x;` /
  # `m as x;` (bare method, php allows omitting the trait qualifier)
  defp trait_adaption(ts) do
    {parts, rest, _} = qualified_name(ts)

    {trait_parts, method, rest3} =
      if at_op?(rest, "::") do
        {m, r2} = take_ident(tl(rest))
        {parts, m, r2}
      else
        # bare `m as x;` — no trait qualifier
        {nil, hd(parts), rest}
      end

    {yes2, rest4} = take_name(rest3, "insteadof")

    if yes2 do
      {excluded, rest5} = use_trait_names(rest4, [])
      {{:insteadof, trait_parts, method, excluded}, rest5}
    else
      {_, rest4b} = take_name(rest3, "as")

      {vis, alias, rest5} =
        case peek(rest4b) do
          {:name, _, n} when n in ~w(public protected private) ->
            {String.to_atom(n), nil, tl(rest4b)}

          _ ->
            {nil, nil, rest4b}
        end

      case peek(rest5) do
        {:name, _, alias_name} ->
          {{:as, trait_parts, method, alias_name, vis}, tl(rest5)}

        _ ->
          {{:as, trait_parts, method, method, vis}, rest5}
      end
    end
  end

  defp visibility_member(ts) do
    {mods, rest} = take_member_modifiers(ts, [])

    vis = Enum.find(mods, &(&1 in [:public, :protected, :private])) || :public
    static? = :static in mods
    abstract? = :abstract in mods
    final? = :final in mods

    cond do
      at_name?(rest, "function") ->
        method_member(rest, vis, static?, abstract?, final?)

      at_name?(rest, "const") ->
        const_member(rest)

      match?([{:variable, _, _} | _], rest) ->
        prop_member(rest, vis, static?, :readonly in mods)

      # typed property: `public int $x` / `public ?WP_Error $e` (param_type
      # consumes the hint, including nullable `?` and unions)
      match?([{:name, _, _} | _], rest) ->
        prop_member(rest, vis, static?, :readonly in mods)

      match?([{:op, _, "?"} | _], rest) ->
        prop_member(rest, vis, static?, :readonly in mods)

      match?([{:op, _, "\\"} | _], rest) ->
        prop_member(rest, vis, static?, :readonly in mods)

      true ->
        raise(ParseError,
          message: "expected property or method in class body",
          line: peek_line(rest)
        )
    end
  end

  defp take_member_modifiers(ts, acc) do
    case peek(ts) do
      {:name, _, n} when n in ~w(public protected private var static abstract final readonly) ->
        mod = if n == "var", do: :public, else: String.to_atom(n)
        take_member_modifiers(tl(ts), [mod | acc])

      _ ->
        {Enum.reverse(acc), ts}
    end
  end

  defp take_visibility(ts) do
    case peek(ts) do
      {:name, _, n} when n in ~w(public protected private var) ->
        {if(n == "var", do: :public, else: String.to_atom(n)), tl(ts)}

      _ ->
        {:public, ts}
    end
  end

  defp take_static(ts) do
    case peek(ts) do
      {:name, _, "static"} -> {true, tl(ts)}
      _ -> {false, ts}
    end
  end

  defp take_abstract(ts) do
    case peek(ts) do
      {:name, _, "abstract"} -> {true, tl(ts)}
      _ -> {false, ts}
    end
  end

  defp prop_member(ts, vis, static?, readonly?) do
    {props, rest} = prop_entries(ts, vis, static?, readonly?, [])
    {{:props, props}, expect_semi(rest)}
  end

  defp prop_entries(ts, vis, static?, readonly?, acc) do
    {_t, rest0} = param_type(ts)

    case rest0 do
      [{:variable, _, name} | rest2] ->
        {default, rest3} =
          case take_op(rest2, "=") do
            {true, r} -> expr(r)
            {false, _} -> {nil, rest2}
          end

        {yes, rest4} = take_op(rest3, ",")

        if yes do
          prop_entries(rest4, vis, static?, readonly?, [
            {vis, static?, readonly?, name, default} | acc
          ])
        else
          {Enum.reverse([{vis, static?, readonly?, name, default} | acc]), rest3}
        end

      _ ->
        raise(ParseError, message: "expected property declaration", line: peek_line(rest0))
    end
  end

  # fl = the `function` keyword's line: php attributes ArgumentCountError to
  # the method declaration site
  defp method_member([{_, fl, "function"} | rest], vis, static?, abstract?, final?) do
    {by_ref?, rest1} =
      case take_op(rest, "&") do
        {true, r} -> {true, r}
        {false, _} -> {false, rest}
      end

    {name, rest2} = take_ident(rest1)
    rest3 = expect_op(rest2, "(")
    {params, rest4} = param_list(rest3)
    rest5 = return_hint(rest4)

    {body, rest6} =
      cond do
        # abstract methods and interface declarations end with `;`
        abstract? or at_op?(rest5, ";") ->
          {[], expect_semi(rest5)}

        true ->
          rest5b = expect_op(rest5, "{")
          {stmts, r} = block_body(rest5b)
          {stmts, r}
      end

    {{:methods, [{vis, static?, abstract?, final?, by_ref?, name, params, body, fl}]}, rest6}
  end

  # statement-level `const A = 1, B = 2;`
  defp const_stmt([{_, _, "const"} | rest]) do
    {entries, rest2} = const_entries(rest, [])
    {{:const_decl, entries}, expect_semi(rest2)}
  end

  defp echo_stmt([{_, _, "echo"} | rest]) do
    {args, rest2} = comma_exprs(rest)
    {{:echo, args}, expect_semi(rest2)}
  end

  # parse `(cond)` then `{...}`, a single statement, or `:...end` alt syntax
  defp cond_then(ts) do
    rest = expect_op(ts, "(")
    {cond, rest2} = expr(rest)
    rest3 = expect_op(rest2, ")")

    cond do
      at_op?(rest3, "{") ->
        {stmts, r} = block_body(tl(rest3))
        {cond, {:block, stmts}, r}

      at_op?(rest3, ":") ->
        {stmts, r} = alt_body(tl(rest3), ["endif", "else", "elseif"])
        {cond, {:alt, stmts}, r}

      true ->
        {stmt, r} = statement(rest3)
        {cond, {:one, [stmt]}, r}
    end
  end

  defp if_stmt([{_, _, "if"} | rest]) do
    {cond, then, else_part, rest2} = if_chain(rest)
    {{:if, cond, then, else_part}, rest2}
  end

  # tokens after `if` / `elseif` / `else if`
  defp if_chain(ts) do
    {cond, {_tag, then}, rest2} = cond_then(ts)

    {else_part, rest3} =
      cond do
        at_name?(rest2, "elseif") ->
          {c2, t2, e2, r} = if_chain(tl(rest2))
          {[{:if, c2, t2, e2}], r}

        at_name?(rest2, "else") ->
          {_, r} = take_name(rest2, "else")

          if at_name?(r, "if") do
            {c2, t2, e2, r2} = if_chain(tl(r))
            {[{:if, c2, t2, e2}], r2}
          else
            else_body(r)
          end

        true ->
          {nil, rest2}
      end

    {yes_end, rest4} = take_name(rest3, "endif")
    rest5 = if yes_end, do: expect_semi(rest4), else: rest3
    {cond, then, else_part, rest5}
  end

  defp else_body(ts) do
    cond do
      at_op?(ts, "{") ->
        block_body(tl(ts))

      at_op?(ts, ":") ->
        alt_body(tl(ts), ["endif"])

      true ->
        {stmt, r} = statement(ts)
        {[stmt], r}
    end
  end

  defp while_stmt([{_, _, "while"} | rest]) do
    {cond, {_tag, then}, rest2} = cond_then(rest)
    {yes_end, rest3} = take_name(rest2, "endwhile")
    rest4 = if yes_end, do: expect_semi(rest3), else: rest2
    {{:while, cond, then}, rest4}
  end

  defp do_while_stmt([{_, _, "do"} | rest]) do
    {stmts, rest2} =
      if at_op?(rest, "{") do
        block_body(tl(rest))
      else
        {:stop, s, r} = statements_until(rest, ["while"])
        {s, r}
      end

    {_, rest3} = take_name(rest2, "while")
    {cond, rest4} = paren_expr(rest3)
    {{:do_while, stmts, cond}, expect_semi(rest4)}
  end

  defp for_stmt([{_, _, "for"} | rest]) do
    rest1 = expect_op(rest, "(")

    {init, rest2} =
      if at_op?(rest1, ";") do
        {[], tl(rest1)}
      else
        {es, r} = comma_exprs(rest1)
        {es, expect_semi(r)}
      end

    {cond, rest3} =
      if at_op?(rest2, ";") do
        {nil, tl(rest2)}
      else
        {e, r} = expr(rest2)
        {e, expect_semi(r)}
      end

    {step, rest4} =
      if at_op?(rest3, ")") do
        {[], rest3}
      else
        comma_exprs(rest3)
      end

    rest5 = expect_op(rest4, ")")
    {body, rest6} = loop_body(rest5, "endfor")
    {{:for, init, cond, step, body}, rest6}
  end

  defp comma_exprs(ts) do
    {e, rest} = expr(ts)
    comma_exprs(rest, [e])
  end

  defp comma_exprs(ts, acc) do
    {yes, rest} = take_op(ts, ",")

    if yes do
      {e, rest2} = expr(rest)
      comma_exprs(rest2, [e | acc])
    else
      {Enum.reverse(acc), ts}
    end
  end

  defp loop_body(ts, end_kw) do
    cond do
      at_op?(ts, "{") ->
        block_body(tl(ts))

      at_op?(ts, ":") ->
        alt_body(tl(ts), [end_kw]) |> drop_end(end_kw)

      true ->
        {stmt, r} = statement(ts)
        {[stmt], r}
    end
  end

  defp drop_end({stmts, rest}, end_kw) do
    {yes, rest2} = take_name(rest, end_kw)
    if yes, do: {stmts, expect_semi(rest2)}, else: {stmts, rest}
  end

  defp foreach_stmt([{_, _, "foreach"} | rest]) do
    rest1 = expect_op(rest, "(")
    {subj, rest2} = expr(rest1)
    {_, rest3} = take_name(rest2, "as")
    {key_t, val_t, by_ref?, rest4} = foreach_targets(rest3)
    rest5 = expect_op(rest4, ")")
    {body, rest6} = loop_body(rest5, "endforeach")
    {{:foreach, subj, key_t, val_t, by_ref?, body}, rest6}
  end

  # `foreach ($e as $k => $v)` / `as $v` / `as &$v` / `as [$a, $b]`
  defp foreach_targets(ts) do
    {t1, rest} = foreach_target(ts)
    {yes, rest2} = take_op(rest, "=>")

    if yes do
      {t2, rest3} = foreach_target(rest2)
      {strip_ref(t1), strip_ref(t2), ref?(t2), rest3}
    else
      {nil, strip_ref(t1), ref?(t1), rest2}
    end
  end

  defp strip_ref({:by_ref, t}), do: t
  defp strip_ref(t), do: t

  defp ref?({:by_ref, _}), do: true
  defp ref?(_), do: false

  defp foreach_target(ts) do
    {yes, rest} = take_op(ts, "&")

    {t, rest2} =
      cond do
        at_op?(rest, "[") -> list_pattern(rest)
        at_name?(rest, "list") -> list_pattern(rest)
        true -> expr(rest)
      end

    if yes, do: {{:by_ref, t}, rest2}, else: {t, rest2}
  end

  defp list_pattern([{k, _, "["} | rest]) when k == :op do
    {items, rest2} = list_items(rest, "]")
    {{:list_pat, items}, rest2}
  end

  defp list_pattern([{k, _, "list"} | rest]) when k == :name do
    rest1 = expect_op(rest, "(")
    {items, rest2} = list_items(rest1, ")")
    {{:list_pat, items}, rest2}
  end

  defp list_pattern(ts),
    do: raise(ParseError, message: "expected list pattern", line: peek_line(ts))

  # entries for both array literals and list() patterns: `nil`, `value`,
  # or `key => value` (by-ref `&$v` accepted on values)
  defp list_items(ts, closer, acc \\ []) do
    cond do
      at_op?(ts, closer) ->
        {Enum.reverse(acc), tl(ts)}

      at_op?(ts, ",") ->
        list_items(tl(ts), closer, [nil | acc])

      true ->
        {entry, rest} = array_entry(ts)
        {yes, rest2} = take_op(rest, ",")

        if yes,
          do: list_items(rest2, closer, [entry | acc]),
          else: {Enum.reverse([entry | acc]), expect_op(rest, closer)}
    end
  end

  defp array_entry(ts) do
    # `...$arr` spread: php re-keys ints sequentially, keeps string keys
    case take_op(ts, "...") do
      {true, r1} ->
        {e, rest} = expr(r1)
        {{:kv, nil, {:spread_elem, e}, false}, rest}

      {false, _} ->
        array_entry_plain(ts)
    end
  end

  defp array_entry_plain(ts) do
    {by_ref?, ts1} =
      case take_op(ts, "&") do
        {true, r} -> {true, r}
        {false, _} -> {false, ts}
      end

    {e, rest} = array_entry_value(ts1)

    case take_op(rest, "=>") do
      {true, rest2} ->
        {v_ref?, v, rest3} = array_rhs(rest2)
        {{:kv, e, v, v_ref?}, rest3}

      {false, _} ->
        {{:kv, nil, e, by_ref?}, rest}
    end
  end

  # in `key =>` position the key cannot itself be a by-ref; rewind
  defp array_entry_value(ts) do
    case peek(ts) do
      {:variable, _, _} -> expr(ts)
      _ -> expr(ts)
    end
  end

  defp array_rhs(ts) do
    {ref?, rest} =
      case take_op(ts, "&") do
        {true, r} -> {true, r}
        {false, _} -> {false, ts}
      end

    {e, rest2} = expr(rest)
    {ref?, e, rest2}
  end

  defp switch_stmt([{_, _, "switch"} | rest]) do
    {subj, rest2} = paren_expr(rest)

    if at_op?(rest2, ":") do
      # alternative syntax: switch (...): ... endswitch;
      {cases, rest3} = switch_cases(tl(rest2), [], true)
      {_, rest4} = take_name(rest3, "endswitch")
      {{:switch, subj, cases}, expect_semi(rest4)}
    else
      rest3 = expect_op(rest2, "{")
      {cases, rest4} = switch_cases(rest3, [])
      rest5 = expect_op(rest4, "}")
      {{:switch, subj, cases}, rest5}
    end
  end

  # alt_syntax? tracks switch (...): form — the last case's statements must
  # stop at endswitch (statement parser would otherwise eat it as a name)
  defp switch_cases(ts, acc, alt? \\ false)

  defp switch_cases(ts, acc, alt?) do
    cond do
      at_op?(ts, "}") ->
        {Enum.reverse(acc), ts}

      at_name?(ts, "case") ->
        {_, rest} = take_name(ts, "case")
        {vals, rest2} = case_values(rest, [])
        rest3 = colon_or_semi(rest2)
        stops = if alt?, do: ["case", "default", "endswitch"], else: ["case", "default"]
        {:stop, stmts, rest4} = statements_until(rest3, stops, [])
        switch_cases(rest4, [{vals, stmts} | acc], alt?)

      at_name?(ts, "default") ->
        {_, rest} = take_name(ts, "default")
        rest2 = colon_or_semi(rest)
        stops = if alt?, do: ["case", "default", "endswitch"], else: ["case", "default"]
        {:stop, stmts, rest3} = statements_until(rest2, stops, [])
        switch_cases(rest3, [{:default, stmts} | acc], alt?)

      true ->
        raise(ParseError, message: "unexpected token in switch body", line: peek_line(ts))
    end
  end

  defp colon_or_semi(ts) do
    {c, rest} = take_op(ts, ":")
    if c, do: rest, else: expect_semi(ts)
  end

  defp case_values(ts, acc) do
    {e, rest} = expr(ts)
    {yes, rest2} = take_op(rest, ",")

    if yes do
      case_values(rest2, [e | acc])
    else
      {Enum.reverse([e | acc]), rest}
    end
  end

  defp break_stmt([{_, _, kw} | rest], kind) do
    {n, rest2} =
      if at_op?(rest, ";") do
        {nil, rest}
      else
        expr(rest)
      end

    {{kind, n}, expect_semi(rest2)}
  end

  defp return_stmt([{_, _, "return"} | rest]) do
    {e, rest2} =
      if at_op?(rest, ";") do
        {nil, rest}
      else
        expr(rest)
      end

    {{:return, e}, expect_semi(rest2)}
  end

  defp global_stmt([{_, _, "global"} | rest]) do
    {names, rest2} = var_name_list(rest)
    {{:global, names}, expect_semi(rest2)}
  end

  defp var_name_list([{k, l, v} | rest]) do
    if k != :variable,
      do: raise(ParseError, message: "expected variable, got #{tok_desc(v)}", line: l)

    {yes, rest2} = take_op(rest, ",")

    if yes do
      {more, r} = var_name_list(rest2)
      {[v | more], r}
    else
      {[v], rest}
    end
  end

  defp static_stmt([{_, _, "static"} | rest] = ts) do
    case rest do
      [{:variable, _, _} | _] ->
        {vars, rest2} = static_vars(rest, [])
        {{:static_vars, vars}, expect_semi(rest2)}

      _ ->
        expr_statement(ts)
    end
  end

  defp static_vars([{k, l, v} | rest], acc) do
    if k != :variable,
      do:
        raise(ParseError,
          message: "expected variable in static declaration, got #{tok_desc(v)}",
          line: l
        )

    {init, rest2} =
      case take_op(rest, "=") do
        {true, r} -> expr(r)
        {false, _} -> {nil, rest}
      end

    {yes, rest3} = take_op(rest2, ",")

    if yes do
      static_vars(rest3, [{v, init} | acc])
    else
      {Enum.reverse([{v, init} | acc]), rest2}
    end
  end

  defp unset_stmt([{_, _, "unset"} | rest]) do
    rest1 = expect_op(rest, "(")
    {targets, rest2} = comma_targets(rest1, [])
    {{:unset, targets}, expect_semi(expect_op(rest2, ")"))}
  end

  defp comma_targets(ts, acc) do
    {e, rest} = expr(ts)
    {yes, rest2} = take_op(rest, ",")

    if yes do
      comma_targets(rest2, [e | acc])
    else
      {Enum.reverse([e | acc]), rest}
    end
  end

  defp throw_stmt([{_, _, "throw"} | rest]) do
    {e, rest2} = expr(rest)
    {{:expr_stmt, {:throw, e}}, expect_semi(rest2)}
  end

  defp try_stmt([{_, _, "try"} | rest]) do
    {body, rest2} = block_body(expect_op(rest, "{"))
    {catches, rest3} = catch_clauses(rest2, [])
    {finally, rest4} = finally_clause(rest3)
    {{:try_stmt, body, catches, finally}, rest4}
  end

  defp catch_clauses(ts, acc) do
    {yes, rest} = take_name(ts, "catch")

    if yes do
      rest1 = expect_op(rest, "(")
      {types, rest2} = catch_types(rest1, [])
      {var, rest3} = var_or_nil(rest2)
      rest4 = expect_op(rest3, ")")
      {body, rest5} = block_body(expect_op(rest4, "{"))
      catch_clauses(rest5, [{types, var, body} | acc])
    else
      {Enum.reverse(acc), ts}
    end
  end

  defp var_or_nil([{:variable, _, v} | rest]), do: {v, rest}
  defp var_or_nil(ts), do: {nil, ts}

  defp catch_types(ts, acc) do
    {parts, rest, _fq} = qualified_name(ts)
    {yes, rest2} = take_op(rest, "|")

    if yes do
      catch_types(rest2, [parts | acc])
    else
      {Enum.reverse([parts | acc]), rest}
    end
  end

  defp finally_clause(ts) do
    {yes, rest} = take_name(ts, "finally")

    if yes do
      {body, rest2} = block_body(expect_op(rest, "{"))
      {body, rest2}
    else
      {nil, ts}
    end
  end

  defp namespace_stmt([{_, _, "namespace"} | rest]) do
    cond do
      at_op?(rest, "{") ->
        {stmts, rest2} = block_body(tl(rest))
        {{:namespace, nil, stmts}, rest2}

      true ->
        {name, rest2, _} = qualified_name(rest)

        if at_op?(rest2, "{") do
          {stmts, rest3} = block_body(tl(rest2))
          {{:namespace, name, stmts}, rest3}
        else
          {{:namespace, name, nil}, expect_semi(rest2)}
        end
    end
  end

  defp use_stmt([{_, _, "use"} | rest]) do
    {kind, rest1} =
      cond do
        at_name?(rest, "function") -> {:function, tl(rest)}
        at_name?(rest, "const") -> {:const, tl(rest)}
        true -> {:normal, rest}
      end

    {first, rest2, _} = qualified_name(rest1)
    {yes_bs, rest3} = take_op(rest2, "\\")

    if yes_bs do
      rest4 = expect_op(rest3, "{")
      {items, rest5} = use_items(rest4, [])
      rest6 = expect_op(rest5, "}")
      {{:use, kind, items, first}, expect_semi(rest6)}
    else
      {as, rest4} = use_alias(rest2)
      {items, rest5} = more_use_items(rest4, [{first, as}])
      {{:use, kind, items, nil}, expect_semi(rest5)}
    end
  end

  defp more_use_items(ts, acc) do
    {yes, rest} = take_op(ts, ",")

    if yes do
      {parts, rest2, _} = qualified_name(rest)
      {as, rest3} = use_alias(rest2)
      more_use_items(rest3, [{parts, as} | acc])
    else
      {Enum.reverse(acc), ts}
    end
  end

  defp use_items(ts, acc) do
    {parts, rest, _} = qualified_name(ts)
    {as, rest2} = use_alias(rest)
    {yes, rest3} = take_op(rest2, ",")

    if yes do
      use_items(rest3, [{parts, as} | acc])
    else
      {Enum.reverse([{parts, as} | acc]), rest2}
    end
  end

  defp use_alias(ts) do
    {yes, rest} = take_name(ts, "as")

    if yes do
      {a, rest2} = take_ident(rest)
      {a, rest2}
    else
      {nil, ts}
    end
  end

  defp declare_stmt([{_, _, "declare"} | rest]) do
    {_, rest2} = paren_expr(rest)

    if at_op?(rest2, "{") do
      {stmts, rest3} = block_body(tl(rest2))
      {{:block, stmts}, rest3}
    else
      {{:block, []}, expect_semi(rest2)}
    end
  end

  defp halt_stmt([{_, _, "__halt_compiler"} | rest]) do
    {{:halt}, expect_semi(rest)}
  end

  defp paren_expr(ts) do
    rest = expect_op(ts, "(")
    {e, rest2} = expr(rest)
    {e, expect_op(rest2, ")")}
  end

  # ───────────────────────── functions ─────────────────────────

  # `function` at statement level: definition when a name follows, closure otherwise
  defp maybe_func_def([{_, _, "function"} | _] = ts) do
    case tl(ts) do
      # `function &name()` — return-by-ref declaration (approximated as
      # by-value until ref-returns land)
      [{:op, _, "&"}, {:name, _, _} | _] -> func_def(tl(tl(ts)))
      [{:name, _, _} | _] -> func_def(tl(ts))
      _ -> expr_statement(ts)
    end
  end

  defp func_def([{name, _, fname} | rest]) when name == :name do
    rest1 = expect_op(rest, "(")
    {params, rest2} = param_list(rest1)
    rest3 = expect_op(return_hint(rest2), "{")
    {body, rest4} = block_body(rest3)
    {{:func_def, String.downcase(fname), params, body}, rest4}
  end

  defp param_list(ts, acc \\ []) do
    cond do
      at_op?(ts, ")") ->
        {Enum.reverse(acc), tl(ts)}

      true ->
        {param, rest} = one_param(ts)
        {yes, rest2} = take_op(rest, ",")

        if yes do
          param_list(rest2, [param | acc])
        else
          {Enum.reverse([param | acc]), expect_op(rest, ")")}
        end
    end
  end

  defp one_param(ts) do
    {vis, ro?, rest0} = take_promoted_vis(ts)
    {_t, rest} = param_type(rest0)

    {by_ref?, rest2} =
      case take_op(rest, "&") do
        {true, r} -> {true, r}
        {false, _} -> {false, rest}
      end

    {variadic?, rest3} =
      case take_op(rest2, "...") do
        {true, r} -> {true, r}
        {false, _} -> {false, rest2}
      end

    case rest3 do
      [{:variable, _, v} | rest4] ->
        {default, rest5} =
          case take_op(rest4, "=") do
            {true, r} -> expr(r)
            {false, _} -> {nil, rest4}
          end

        param =
          if vis,
            do: {:param_promoted, vis, ro?, v, _t, default, by_ref?, variadic?},
            else: {:param, v, _t, default, by_ref?, variadic?}

        {param, rest5}

      [{_, l, v} | _] ->
        raise(ParseError, message: "expected parameter variable, got #{tok_desc(v)}", line: l)
    end
  end

  # constructor promotion: `public|protected|private [readonly] int $x = 1` —
  # returns {visibility, readonly?, rest}
  defp take_promoted_vis(ts) do
    case peek(ts) do
      {:name, _, n} when n in ~w(public protected private) ->
        rest = tl(ts)

        {ro?, rest} =
          case peek(rest) do
            {:name, _, "readonly"} -> {true, tl(rest)}
            _ -> {false, rest}
          end

        {String.to_atom(n), ro?, rest}

      {:name, _, "readonly"} ->
        # php 8.1: bare `readonly` promotion is invalid but laravel never
        # writes it; treat as public to keep parsing
        {nil, true, ts}

      _ ->
        {nil, false, ts}
    end
  end

  # type consumption that KEEPS the source spelling: `?A|B`, `int`,
  # `\Foo\Bar`, `self` … — inheritance signature checks need it
  defp param_type(ts) do
    cond do
      at_op?(ts, "(") or at_op?(ts, ")") or at_op?(ts, "&") or at_op?(ts, "...") ->
        {nil, ts}

      at_op?(ts, "?") ->
        {t, r} = param_type_atom(tl(ts))
        type_union_tail(r, "?" <> t)

      true ->
        case ts do
          [{:name, _, _} | _] ->
            {t, r} = param_type_atom(ts)
            type_union_tail(r, t)

          [{:op, _, "\\"} | _] ->
            {t, r} = param_type_atom(ts)
            type_union_tail(r, t)

          _ ->
            {nil, ts}
        end
    end
  end

  defp param_type_atom(ts) do
    {parts, rest, _fq} = qualified_name(ts)
    {Enum.join(parts, "\\"), rest}
  end

  defp type_union_tail(ts, acc) do
    cond do
      at_op?(ts, "|") ->
        {t, r} = param_type_atom(tl(ts))
        type_union_tail(r, acc <> "|" <> t)

      # `&` before a variable or `...` is the by-ref marker (incl. by-ref
      # variadics `mixed &...$vars`), not a type intersection
      at_op?(ts, "&") and not match?([{:variable, _, _} | _], tl(ts)) and
          not match?([{:op, _, "..."} | _], tl(ts)) ->
        {t, r} = param_type_atom(tl(ts))
        type_union_tail(r, acc <> "&" <> t)

      true ->
        {acc, ts}
    end
  end

  defp return_hint(ts) do
    {yes, rest} = take_op(ts, ":")

    if yes do
      {_t, r} = param_type(rest)
      r
    else
      ts
    end
  end

  # ───────────────────────── expressions ─────────────────────────

  defp expr(ts), do: kw_or(ts)

  # or < xor < and < assignment < ternary … (keyword ops bind lowest)
  defp kw_or(ts) do
    {l, rest} = kw_xor(ts)
    kw_tail(rest, l, "or", &kw_xor/1, :or)
  end

  defp kw_xor(ts) do
    {l, rest} = kw_and(ts)
    kw_tail(rest, l, "xor", &kw_and/1, :xor)
  end

  defp kw_and(ts) do
    {l, rest} = assign(ts)
    kw_tail(rest, l, "and", &assign/1, :and)
  end

  defp binop_tail(ts, l, op_str, next, op) do
    case take_op(ts, op_str) do
      {true, rest} ->
        {r, rest2} = next.(rest)
        binop_tail(rest2, {:binop, op, l, r}, op_str, next, op)

      {false, _} ->
        {l, ts}
    end
  end

  defp kw_tail(ts, l, kw, next, op) do
    case take_name(ts, kw) do
      {true, rest} ->
        {r, rest2} = next.(rest)
        kw_tail(rest2, {:binop, op, l, r}, kw, next, op)

      {false, _} ->
        {l, ts}
    end
  end

  @bin_assign_ops %{
    "+=" => :+,
    "-=" => :-,
    "*=" => :*,
    "/=" => :/,
    ".=" => :.,
    "%=" => :%,
    "**=" => :**,
    "&=" => :&,
    "|=" => :|,
    "^=" => :^,
    "<<=" => :shl,
    ">>=" => :shr
  }

  defp assign(ts) do
    {l, rest} = ternary(ts)

    # php grammar: assignment may appear as the RIGHT operand of a tighter
    # operator — `false !== $p = f()` parses as `false !== ($p = f())`.
    # Our chain parsed it as `(false !== $p) = f()`; rebalance when the
    # binop's right side is itself an lvalue.
    case {l, peek(rest)} do
      {{:binop, op, a, lv}, {:op, _, "="}} ->
        if lvalue_shape?(lv) do
          {r, rest2} = assign(tl(rest))
          {{:binop, op, a, {:assign, lv, r}}, rest2}
        else
          assign_plain(l, rest)
        end

      _ ->
        assign_plain(l, rest)
    end
  end

  defp assign_plain(l, rest) do
    case peek(rest) do
      {:op, _, "="} ->
        case tl(rest) do
          [{:op, _, "&"} | r2] ->
            {r, rest3} = assign(r2)
            {{:assign_ref, to_list_pat(l), r}, rest3}

          _ ->
            {r, rest2} = assign(tl(rest))
            {{:assign, to_list_pat(l), r}, rest2}
        end

      {:op, _, op} when is_map_key(@bin_assign_ops, op) ->
        {r, rest2} = assign(tl(rest))
        {{:assign_op, Map.fetch!(@bin_assign_ops, op), l, r}, rest2}

      {:op, _, "??="} ->
        {r, rest2} = assign(tl(rest))
        {{:assign_op, :coalesce, l, r}, rest2}

      _ ->
        {l, rest}
    end
  end

  @include_kws ~w(include include_once require require_once)

  # shapes that can receive an assignment inside an expression
  defp lvalue_shape?({:var, _}), do: true
  defp lvalue_shape?({:var_var, _}), do: true
  defp lvalue_shape?({:index, _, _}), do: true
  defp lvalue_shape?({:prop, _, _}), do: true
  defp lvalue_shape?({:static_prop, _, _}), do: true
  defp lvalue_shape?({:list_pat, _}), do: true
  defp lvalue_shape?(_), do: false

  # `include`/`require` sit below assignment (`$v = include ...` parses) and
  # consume a full ternary-level expression — the WordPress idiom
  # `require_once ABSPATH . 'wp-settings.php'` concatenates before including
  defp ternary([{:name, _, kw} | rest]) when kw in @include_kws do
    {e, r} = ternary(rest)
    {{:include, String.to_atom(kw), e}, r}
  end

  defp ternary(ts) do
    {c, rest} = coalesce(ts)

    case take_op(rest, "?") do
      {true, rest2} ->
        if at_op?(rest2, ":") do
          {f, rest3} = assign(tl(rest2))
          {{:short_ternary, c, f}, rest3}
        else
          {t, rest3} = assign(rest2)
          rest4 = expect_op(rest3, ":")
          {f, rest5} = assign(rest4)
          {{:ternary, c, t, f}, rest5}
        end

      {false, _} ->
        {c, rest}
    end
  end

  defp coalesce(ts) do
    {l, rest} = bool_or(ts)

    case take_op(rest, "??") do
      {true, rest2} ->
        {r, rest3} = coalesce(rest2)
        {{:coalesce, l, r}, rest3}

      {false, _} ->
        {l, rest}
    end
  end

  defp bool_or(ts) do
    {l, rest} = bool_and(ts)
    binop_tail(rest, l, "||", &bool_and/1, :||)
  end

  defp bool_and(ts) do
    {l, rest} = bit_or(ts)
    binop_tail(rest, l, "&&", &bit_or/1, :&&)
  end

  defp bit_or(ts) do
    {l, rest} = bit_xor(ts)
    binop_tail(rest, l, "|", &bit_xor/1, :|)
  end

  defp bit_xor(ts) do
    {l, rest} = bit_and(ts)
    binop_tail(rest, l, "^", &bit_and/1, :^)
  end

  defp bit_and(ts) do
    {l, rest} = equality(ts)
    binop_tail(rest, l, "&", &equality/1, :&)
  end

  @eq_ops %{"==" => :==, "!=" => :!=, "<>" => :!=, "===" => :===, "!==" => :!==, "<=>" => :"<=>"}

  defp equality(ts) do
    {l, rest} = relational(ts)

    case peek(rest) do
      {:op, _, op} when is_map_key(@eq_ops, op) ->
        {r, rest2} = relational(tl(rest))
        {{:binop, Map.fetch!(@eq_ops, op), l, r}, rest2}

      _ ->
        {l, rest}
    end
  end

  @rel_ops %{"<" => :<, "<=" => :<=, ">" => :>, ">=" => :>=}

  defp relational(ts) do
    {l, rest} = shift(ts)
    rel_tail(rest, l)
  end

  defp rel_tail(ts, l) do
    case peek(ts) do
      {:op, _, op} when is_map_key(@rel_ops, op) ->
        {r, rest} = shift(tl(ts))
        rel_tail(rest, {:binop, Map.fetch!(@rel_ops, op), l, r})

      _ ->
        {l, ts}
    end
  end

  @shift_ops %{"<<" => :shl, ">>" => :shr}

  defp shift(ts) do
    {l, rest} = additive(ts)
    shift_tail(rest, l)
  end

  defp shift_tail(ts, l) do
    case peek(ts) do
      {:op, _, op} when is_map_key(@shift_ops, op) ->
        {r, rest} = additive(tl(ts))
        shift_tail(rest, {:binop, Map.fetch!(@shift_ops, op), l, r})

      _ ->
        {l, ts}
    end
  end

  @add_ops %{"+" => :+, "-" => :-, "." => :.}

  defp additive(ts) do
    {l, rest} = multiplicative(ts)
    add_tail(rest, l)
  end

  defp add_tail(ts, l) do
    case peek(ts) do
      {:op, _, op} when is_map_key(@add_ops, op) ->
        {r, rest} = multiplicative(tl(ts))
        add_tail(rest, {:binop, Map.fetch!(@add_ops, op), l, r})

      _ ->
        {l, ts}
    end
  end

  @mul_ops %{"*" => :*, "/" => :/, "%" => :%}

  defp multiplicative(ts) do
    {l, rest} = instanceof_expr(ts)
    mul_tail(rest, l)
  end

  defp mul_tail(ts, l) do
    case peek(ts) do
      {:op, _, op} when is_map_key(@mul_ops, op) ->
        {r, rest} = instanceof_expr(tl(ts))
        mul_tail(rest, {:binop, Map.fetch!(@mul_ops, op), l, r})

      _ ->
        {l, ts}
    end
  end

  defp instanceof_expr(ts) do
    {l, rest} = unary(ts)

    case take_name(rest, "instanceof") do
      {true, rest2} ->
        {r, rest3} = instanceof_rhs(rest2)
        {{:binop, :instanceof, l, r}, rest3}

      {false, _} ->
        {l, rest}
    end
  end

  defp instanceof_rhs(ts) do
    case peek(ts) do
      {:name, _, _} -> qualified_name_expr(ts)
      {:variable, _, _} -> var_or_expr(ts)
      _ -> unary(ts)
    end
  end

  # `**` binds tighter than unary minus: -2**2 == -(2**2), and is right-assoc
  defp pow(ts) do
    {l, rest} = postfix(ts)

    case take_op(rest, "**") do
      {true, rest2} ->
        {r, rest3} = unary(rest2)
        {{:binop, :**, l, r}, rest3}

      {false, _} ->
        {l, rest}
    end
  end

  defp unary(ts) do
    case peek(ts) do
      {:op, _, "!"} ->
        wrap_unop(tl(ts), :!)

      {:op, _, "~"} ->
        wrap_unop(tl(ts), :bnot)

      {:op, _, "-"} ->
        wrap_unop(tl(ts), :-)

      {:op, _, "+"} ->
        wrap_unop(tl(ts), :+)

      {:op, _, "@"} ->
        wrap_unop(tl(ts), :@)

      {:op, _, "++"} ->
        {e, r} = unary(tl(ts))
        {{:pre_inc, e}, r}

      {:op, _, "--"} ->
        {e, r} = unary(tl(ts))
        {{:pre_dec, e}, r}

      {:op, _, "("} ->
        maybe_cast(ts)

      {:name, _, "print"} ->
        {e, r} = unary(tl(ts))
        {{:print, e}, r}

      {:name, _, "throw"} ->
        {e, r} = unary(tl(ts))
        {{:throw, e}, r}

      {:name, _, "clone"} ->
        {e, r} = unary(tl(ts))
        {{:clone, e}, r}

      {:name, _, "yield"} ->
        yield_expr(tl(ts))

      _ ->
        pow(ts)
    end
  end

  # yield [from] expr [=> expr] — bare when directly followed by a terminator.
  # The value expression parses at full expression level (assignment binds
  # tighter is a php subtlety we don't need for statement-position yields).
  defp yield_expr([{_, _, "from"} | rest]) do
    {e, r} = expr(rest)
    {{:yield_from, e}, r}
  end

  defp yield_expr(ts) do
    if yield_bare?(ts) do
      {{:yield_bare}, ts}
    else
      {e, r} = expr(ts)

      case peek(r) do
        {:op, _, "=>"} ->
          {v, r2} = expr(tl(r))
          {{:yield_kv, e, v}, r2}

        _ ->
          {{:yield, e}, r}
      end
    end
  end

  defp yield_bare?([]), do: true

  defp yield_bare?([{kind, _, txt} | _]) do
    case kind do
      :op -> txt in [";", ")", ",", "]", "}", ">", "?", ":", "&&", "||", "??"]
      :eof -> true
      _ -> false
    end
  end

  defp wrap_unop(ts, op) do
    {e, r} = unary(ts)
    {{:unop, op, e}, r}
  end

  # `(` cast-type `)` unary  |  `(` expr `)`
  defp maybe_cast([{:op, _, "("}, {:name, _, nv}, {:op, _, ")"} | rest] = ts) do
    if Token.cast_type?(String.downcase(nv)) do
      # the operand may be an include/require (also ternary-bound like
      # include itself): `(array) include $file` appears in WP's l10n
      {e, r} = cast_operand(rest)
      {{:cast, Token.cast_kind(String.downcase(nv)), e}, r}
    else
      group_expr(ts)
    end
  end

  defp maybe_cast([{:op, _, "("} | _] = ts), do: group_expr(ts)

  # casts bind tighter than include in the grammar, but `(array) include $f`
  # needs the ternary-level operand (include is parsed there)
  defp cast_operand([{:name, _, kw} | _] = ts) when kw in @include_kws,
    do: ternary(ts)

  defp cast_operand(ts), do: unary(ts)

  defp group_expr([{_, _, "("} | rest]) do
    {e, r} = expr(rest)
    postfix_loop(e, expect_op(r, ")"))
  end

  # ───────────────────────── postfix ─────────────────────────

  defp postfix(ts) do
    {e, rest} = primary(ts)
    postfix_loop(e, rest)
  end

  defp postfix_loop(e, ts) do
    case peek(ts) do
      {:op, _, "["} ->
        {idx, rest} = index_body(tl(ts))
        postfix_loop({:index, e, idx}, rest)

      {:op, _, "->"} ->
        {name, rest} = prop_name(tl(ts))

        if at_op?(rest, "(") do
          case call_args(tl(rest)) do
            {:fcc, rest2} -> postfix_loop({:method_fcc, e, name}, rest2)
            {args, rest2} -> postfix_loop({:method_call, e, name, args, false}, rest2)
          end
        else
          postfix_loop({:prop, e, name}, rest)
        end

      {:op, _, "?->"} ->
        {name, rest} = prop_name(tl(ts))

        if at_op?(rest, "(") do
          {args, rest2} = call_args(tl(rest))
          postfix_loop({:method_call, e, name, args, true}, rest2)
        else
          postfix_loop({:nullsafe_prop, e, name}, rest)
        end

      {:op, _, "::"} ->
        static_tail(to_cname(e), tl(ts))

      {:op, _, "("} ->
        case call_args(tl(ts)) do
          {:fcc, rest} -> postfix_loop({:value_fcc, e}, rest)
          {args, rest} -> postfix_loop({:call, e, args}, rest)
        end

      {:op, _, "++"} ->
        {{:post_inc, e}, tl(ts)}

      {:op, _, "--"} ->
        {{:post_dec, e}, tl(ts)}

      _ ->
        {e, ts}
    end
  end

  defp index_body(ts) do
    if at_op?(ts, "]") do
      {nil, tl(ts)}
    else
      {e, rest} = expr(ts)
      {e, expect_op(rest, "]")}
    end
  end

  defp prop_name(ts) do
    case ts do
      [{:name, _, n} | rest] ->
        {{:lit_name, n}, rest}

      [{:variable, _, v} | rest] ->
        {{:var, v}, rest}

      [{:op, _, "{"} | rest] ->
        {e, r} = expr(rest)
        {e, expect_op(r, "}")}

      [{_, l, v} | _] ->
        raise(ParseError, message: "expected property name, got #{tok_desc(v)}", line: l)
    end
  end

  defp static_tail(class_ref, ts) do
    case ts do
      [{:name, _, _} | _] = ts ->
        if at_name?(ts, "class") do
          {{:class_const, class_ref, "class"}, tl(ts)}
        else
          static_tail_name(class_ref, ts)
        end

      [{:variable, _, _} | _] ->
        {v, rest} = var_or_expr(ts)
        static_prop_or_call(class_ref, v, rest)

      [{:op, _, "$"} | _] ->
        {e, rest} = var_or_expr(tl(ts))
        static_prop_or_call(class_ref, e, rest)

      [{:op, _, "{"} | _] ->
        {e, rest} = expr(tl(ts))
        static_prop_or_call(class_ref, e, expect_op(rest, "}"))

      _ ->
        raise(ParseError, message: "expected member after '::'", line: peek_line(ts))
    end
  end

  defp static_tail_name(class_ref, [{:name, _, n} | rest]) do
    if at_op?(rest, "(") do
      case call_args(tl(rest)) do
        {:fcc, rest2} -> postfix_loop({:static_fcc, class_ref, {:lit_name, n}}, rest2)
        {args, rest2} -> postfix_loop({:static_call, class_ref, {:lit_name, n}, args}, rest2)
      end
    else
      postfix_loop({:class_const, class_ref, n}, rest)
    end
  end

  defp static_prop_or_call(class_ref, name_e, ts) do
    if at_op?(ts, "(") do
      case call_args(tl(ts)) do
        {:fcc, rest} -> postfix_loop({:static_fcc, class_ref, name_e}, rest)
        {args, rest} -> postfix_loop({:static_call, class_ref, name_e, args}, rest)
      end
    else
      postfix_loop({:static_prop, class_ref, name_e}, ts)
    end
  end

  defp to_list_pat({:array, items}), do: {:list_pat, items}
  defp to_list_pat(t), do: t

  defp to_cname({:const, parts, fq}), do: {:cname, fq, parts}
  defp to_cname({:cname, _, _} = c), do: c
  defp to_cname(e), do: e

  defp call_args(ts) do
    cond do
      at_op?(ts, ")") ->
        {[], tl(ts)}

      # first-class callable: `strlen(...)` — the argument list is exactly `...`
      match?([{:op, _, "..."}, {:op, _, ")"} | _], ts) ->
        {:fcc, tl(tl(ts))}

      true ->
        {args, rest} = call_args_list(ts, [])
        {args, expect_op(rest, ")")}
    end
  end

  defp call_args_list(ts, acc) do
    {arg, rest} = one_arg(ts)
    {yes, rest2} = take_op(rest, ",")

    # php compile-time checks: a LITERAL positional argument may not follow
    # an unpack or a named argument (spreads/named after those are fine);
    # rendered as bare "Fatal error:" not "Parse error:"
    seen_spread = Enum.any?(acc, &match?({:arg_spread, _, _}, &1))
    seen_named = Enum.any?(acc, fn a -> elem(a, 0) == :arg and elem(a, 3) != nil end)

    case arg do
      {:arg, _, _, nil} ->
        cond do
          seen_spread ->
            raise(ParseError,
              message: "@fatal Cannot use positional argument after argument unpacking",
              line: arg_line(ts)
            )

          seen_named ->
            raise(ParseError,
              message: "@fatal Cannot use positional argument after named argument",
              line: arg_line(ts)
            )

          true ->
            :ok
        end

      _ ->
        :ok
    end

    if yes do
      # php 7.3+: trailing comma in function calls
      if at_op?(rest2, ")") do
        {Enum.reverse([arg | acc]), rest2}
      else
        call_args_list(rest2, [arg | acc])
      end
    else
      {Enum.reverse([arg | acc]), rest}
    end
  end

  defp arg_line([{_, l, _} | _]), do: l
  defp arg_line(_), do: 0

  defp one_arg(ts) do
    {name, rest} = named_arg_name(ts)

    {by_ref?, rest2} =
      case take_op(rest, "&") do
        {true, r} -> {true, r}
        {false, _} -> {false, rest}
      end

    case take_op(rest2, "...") do
      {true, rest3} ->
        {e, rest4} = expr(rest3)
        {{:arg_spread, e, name}, rest4}

      {false, _} ->
        {e, rest3} = expr(rest2)
        {{:arg, e, by_ref?, name}, rest3}
    end
  end

  # `name:` marks a named argument unless followed by `=` (`?:` short ternary)
  defp named_arg_name([{k, _, n}, {:op, _, ":"} | rest]) when k == :name do
    case rest do
      [{:op, _, "="} | _] -> {nil, [{k, 0, n} | [{:op, 0, ":"} | rest]]}
      _ -> {n, rest}
    end
  end

  defp named_arg_name(ts), do: {nil, ts}

  # ───────────────────────── primary ─────────────────────────

  defp primary(ts) do
    case peek(ts) do
      {:int, _, v} ->
        {{:int, v}, tl(ts)}

      {:float, _, v} ->
        {{:float, v}, tl(ts)}

      {:string, _, v} ->
        {{:string, v}, tl(ts)}

      {:interp_string, _, parts} ->
        interp_parts(parts, ts)

      {:shell_string, l, _} ->
        raise(ParseError, message: "shell execution is not supported", line: l)

      {:variable, _, v} ->
        {{:var, v}, tl(ts)}

      {:op, _, "$"} ->
        {e, rest} = var_or_expr(tl(ts))
        {{:var_var, e}, rest}

      # fully-qualified name in expression position: \App\Models\User
      {:op, _, "\\"} ->
        qualified_name_expr(ts)

      {:op, _, "["} ->
        {items, rest} = list_items(tl(ts), "]")
        {{:array, items}, rest}

      {:op, _, "("} ->
        {e, rest} = expr(tl(ts))
        {e, expect_op(rest, ")")}

      {:name, _, n} ->
        name_primary(String.downcase(n), ts)

      _ ->
        raise(ParseError, message: "unexpected token in expression", line: peek_line(ts))
    end
  end

  defp var_or_expr(ts) do
    case peek(ts) do
      {:variable, _, v} ->
        {{:var, v}, tl(ts)}

      {:op, _, "$"} ->
        {e, r} = var_or_expr(tl(ts))
        {{:var_var, e}, r}

      {:op, _, "{"} ->
        {e, r} = expr(tl(ts))
        {e, expect_op(r, "}")}

      _ ->
        raise(ParseError, message: "expected variable", line: peek_line(ts))
    end
  end

  defp name_primary(n, ts) do
    case n do
      "true" ->
        {{:bool, true}, tl(ts)}

      "false" ->
        {{:bool, false}, tl(ts)}

      "null" ->
        {:null, tl(ts)}

      "array" ->
        array_paren(ts)

      "list" ->
        list_pattern(ts)

      "isset" ->
        isset_expr(ts)

      "empty" ->
        empty_expr(ts)

      "function" ->
        closure(ts)

      "fn" ->
        arrow_fn(ts)

      # `static function () : T {}` / `static fn() =>` — closures never bind
      # $this in this interpreter, so the static marker is consumed and dropped
      "static" ->
        case tl(ts) do
          [{:name, _, "function"} | r] -> closure([{:name, 0, "function"} | r])
          [{:name, _, "fn"} | r] -> arrow_fn([{:name, 0, "fn"} | r])
          _ -> {{:cname, false, ["static"]}, tl(ts)}
        end

      "match" ->
        match_expr(ts)

      "new" ->
        new_expr(ts)

      "exit" ->
        exit_expr(ts)

      "die" ->
        exit_expr(ts)

      "static" ->
        {{:cname, false, ["static"]}, tl(ts)}

      _ ->
        qualified_name_expr(ts)
    end
  end

  defp array_paren([{_, _, "array"} | rest]) do
    rest1 = expect_op(rest, "(")
    {items, rest2} = list_items(rest1, ")")
    {{:array, items}, rest2}
  end

  defp isset_expr([{_, _, "isset"} | rest]) do
    rest1 = expect_op(rest, "(")
    {targets, rest2} = comma_targets(rest1, [])
    {{:isset, targets}, expect_op(rest2, ")")}
  end

  defp empty_expr([{_, _, "empty"} | rest]) do
    {e, rest2} = paren_expr(rest)
    {{:empty, e}, rest2}
  end

  defp closure([{_, _, "function"} | rest]) do
    {by_ref?, rest1} =
      case take_op(rest, "&") do
        {true, r} -> {true, r}
        {false, _} -> {false, rest}
      end

    rest2 = expect_op(rest1, "(")
    {params, rest3} = param_list(rest2)
    {uses, rest4} = closure_uses(rest3)
    rest5 = expect_op(return_hint(rest4), "{")
    {body, rest6} = block_body(rest5)
    {{:closure, params, uses, by_ref?, body, false}, rest6}
  end

  defp closure_uses(ts) do
    {yes, rest} = take_name(ts, "use")

    if yes do
      rest1 = expect_op(rest, "(")
      {uses, rest2} = use_vars(rest1, [])
      {uses, expect_op(rest2, ")")}
    else
      {[], ts}
    end
  end

  defp use_vars(ts, acc) do
    {ref?, rest} =
      case take_op(ts, "&") do
        {true, r} -> {true, r}
        {false, _} -> {false, ts}
      end

    case rest do
      [{:variable, _, v} | rest2] ->
        entry = if ref?, do: {:ref, v}, else: v
        {yes, rest3} = take_op(rest2, ",")

        if yes do
          use_vars(rest3, [entry | acc])
        else
          {Enum.reverse([entry | acc]), rest2}
        end

      [{_, l, v} | _] ->
        raise(ParseError, message: "expected closure use variable, got #{tok_desc(v)}", line: l)
    end
  end

  defp arrow_fn([{_, _, "fn"} | rest]) do
    {by_ref?, rest1} =
      case take_op(rest, "&") do
        {true, r} -> {true, r}
        {false, _} -> {false, rest}
      end

    rest2 = expect_op(rest1, "(")
    {params, rest3} = param_list(rest2)
    rest4 = return_hint(rest3)
    rest5 = expect_op(rest4, "=>")
    {body, rest6} = expr(rest5)
    {{:closure, params, [], by_ref?, [{:return, body}], true}, rest6}
  end

  defp match_expr([{_, _, "match"} | rest]) do
    {subj, rest2} = paren_expr(rest)
    rest3 = expect_op(rest2, "{")
    {arms, rest4} = match_arms(rest3, [])
    {{:match, subj, arms}, expect_op(rest4, "}")}
  end

  defp match_arms(ts, acc) do
    cond do
      at_op?(ts, "}") ->
        {Enum.reverse(acc), ts}

      true ->
        {arm, rest} = match_arm(ts)
        {_yes, rest2} = take_op(rest, ",")
        match_arms(rest2, [arm | acc])
    end
  end

  defp match_arm(ts) do
    {conds, rest} =
      if at_name?(ts, "default") do
        {:default, tl(ts)}
      else
        match_conditions(ts, [])
      end

    rest2 = expect_op(rest, "=>")
    {body, rest3} = expr(rest2)
    {{conds, body}, rest3}
  end

  defp match_conditions(ts, acc) do
    {e, rest} = expr(ts)
    {yes, rest2} = take_op(rest, ",")

    if yes do
      match_conditions(rest2, [e | acc])
    else
      {Enum.reverse([e | acc]), rest}
    end
  end

  defp new_expr([{_, _, "new"} | rest]) do
    case peek(rest) do
      {:name, _, "class"} ->
        anon_class_expr(rest)

      _ ->
        {cls, rest2} =
          case peek(rest) do
            {:name, _, _} ->
              {parts, r, fq} = qualified_name(rest)
              {{:cname, fq, parts}, r}

            {:op, _, "\\"} ->
              {parts, r, fq} = qualified_name(rest)
              {{:cname, fq, parts}, r}

            {:variable, _, _} ->
              var_or_expr(rest)

            {:op, _, "("} ->
              {e, r} = expr(rest)
              {e, expect_op(r, ")")}

            _ ->
              raise(ParseError, message: "expected class name after 'new'", line: peek_line(rest))
          end

        {args, rest3} = ctor_args(rest2)
        {{:new, cls, args}, rest3}
    end
  end

  # `new class(args) extends P implements A, B { members }` — the construction
  # args attach to the ctor call; the class body is declared inline
  defp anon_class_expr([{_, _, "class"} | rest]) do
    {args, rest2} = ctor_args(rest)
    {extends, rest3} = optional_extends("class", rest2)
    {implements, rest4} = optional_implements("class", rest3)

    rest5 = expect_op(rest4, "{")
    {members, rest6} = class_members(rest5, [], "class@anonymous")
    rest7 = expect_op(rest6, "}")

    decl = %{
      name: "class@anonymous",
      kind: :class,
      modifiers: [],
      extends: extends,
      implements: implements,
      consts: List.flatten(Keyword.get_values(members, :consts)),
      props: List.flatten(Keyword.get_values(members, :props)),
      methods: List.flatten(Keyword.get_values(members, :methods)),
      uses: Keyword.get_values(members, :uses)
    }

    {{:anon_class, decl, args}, rest7}
  end

  defp ctor_args(ts) do
    if at_op?(ts, "(") do
      call_args(tl(ts))
    else
      {[], ts}
    end
  end

  defp exit_expr([{_, _, _} | rest]) do
    {e, rest2} =
      cond do
        at_op?(rest, "(") ->
          if at_op?(tl(rest), ")") do
            {nil, tl(tl(rest))}
          else
            {ev, r} = expr(tl(rest))
            {ev, expect_op(r, ")")}
          end

        at_op?(rest, ";") ->
          {nil, rest}

        true ->
          {nil, rest}
      end

    {{:exit_expr, e}, rest2}
  end

  # qualified name in expression position (constants, class names)
  defp qualified_name_expr(ts) do
    {parts, rest, fq} = qualified_name(ts)
    {{:const, parts, fq}, rest}
  end

  defp qualified_name([{k, _, v} | rest]) when k == :name do
    case rest do
      [{:op, _, "\\"}, {:name, _, _} | _] -> name_chain(tl(rest), [v], false)
      _ -> {[v], rest, false}
    end
  end

  defp qualified_name([{k, _, "\\"} | rest]) when k == :op do
    name_chain(rest, [], true)
  end

  defp qualified_name([{_, l, v} | _]),
    do: raise(ParseError, message: "expected name, got #{tok_desc(v)}", line: l)

  defp name_chain([{k, _, v} | rest], acc, fq) when k == :name do
    case rest do
      [{:op, _, "\\"}, {:name, _, _} | _] -> name_chain(tl(rest), [v | acc], fq)
      _ -> {Enum.reverse([v | acc]), rest, fq}
    end
  end

  defp name_chain([{_, l, v} | _], _acc, _fq),
    do: raise(ParseError, message: "expected name after '\\', got #{tok_desc(v)}", line: l)

  # ───────────────────────── interpolation ─────────────────────────

  defp interp_parts(parts, ts) do
    {{:interp, Enum.map(parts, &interp_part_ast/1)}, tl(ts)}
  end

  defp interp_part_ast({:text, s}), do: {:text, s}

  # expression parts carry their source line: php attributes interpolation
  # warnings to the line the variable sits on, not the heredoc/quote end
  defp interp_part_ast({:simple, name, accessors, line}) do
    {:line_e, line, interp_accessors(accessors, {:var, name})}
  end

  defp interp_part_ast({:complex, tokens, line}) do
    {:line_e, line, parse_expression(tokens)}
  end

  defp interp_part_ast({:simple, name, accessors}) do
    interp_accessors(accessors, {:var, name})
  end

  defp interp_part_ast({:complex, tokens}) do
    {:complex, parse_expression(tokens)}
  end

  defp interp_accessors(accessors, base) do
    Enum.reduce(accessors, base, fn
      {:index, idx}, acc ->
        idx_ast =
          case idx do
            {:str, s} -> {:string, s}
            {:int, i} -> {:int, i}
            {:var, v} -> {:var, v}
          end

        {:index, acc, idx_ast}

      {:prop, p}, acc ->
        {:prop, acc, {:lit_name, p}}
    end)
  end
end
