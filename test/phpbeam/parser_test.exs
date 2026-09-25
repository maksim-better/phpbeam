defmodule PhpBeam.ParserTest do
  use ExUnit.Case, async: true
  alias PhpBeam.{Lexer, Parser}

  defp parse(src) do
    with {:ok, toks} <- Lexer.tokenize(src),
         {:ok, ast} <- Parser.parse(toks) do
      Parser.strip_lines(ast)
    else
      {:error, m, l} -> flunk("parse error: #{m} line #{l}")
    end
  end

  defp expr(src) do
    {:ok, toks} = Lexer.tokenize("<?php " <> src)
    Parser.parse_expression(toks)
  end

  defp one_expr_stmt(src) do
    [stmt | _] = parse("<?php " <> src <> ";")
    stmt
  end

  test "literals and echo" do
    assert [{:echo, [{:int, 1}]}, {:block, []}, {:html, "x"}] = parse("<?php echo 1; ?>x")
  end

  test "binary operator precedence" do
    assert one_expr_stmt("1 + 2 * 3") ==
             {:expr_stmt, {:binop, :+, {:int, 1}, {:binop, :*, {:int, 2}, {:int, 3}}}}

    assert one_expr_stmt("(1 + 2) * 3") ==
             {:expr_stmt, {:binop, :*, {:binop, :+, {:int, 1}, {:int, 2}}, {:int, 3}}}
  end

  test "unary minus vs power" do
    assert expr("-2 ** 2") == {:unop, :-, {:binop, :**, {:int, 2}, {:int, 2}}}
    assert expr("2 ** -1") == {:binop, :**, {:int, 2}, {:unop, :-, {:int, 1}}}
  end

  test "concat binds like additive" do
    assert expr("1 . 2 + 3") == {:binop, :+, {:binop, :., {:int, 1}, {:int, 2}}, {:int, 3}}
  end

  test "keyword ops below assignment" do
    # $a = false or die() parses as ($a = false) or die()
    assert expr("$a = false or die()") ==
             {:binop, :or, {:assign, {:var, "a"}, {:bool, false}}, {:exit_expr, nil}}
  end

  test "ternary and coalesce" do
    assert expr("$a ? 1 : 2") == {:ternary, {:var, "a"}, {:int, 1}, {:int, 2}}
    assert expr("$a ?: 2") == {:short_ternary, {:var, "a"}, {:int, 2}}
    assert expr("$a ?? $b ?? 1") == {:coalesce, {:var, "a"}, {:coalesce, {:var, "b"}, {:int, 1}}}
  end

  test "assignment forms" do
    assert expr("$a = 1") == {:assign, {:var, "a"}, {:int, 1}}
    assert expr("$a .= 'x'") == {:assign_op, :., {:var, "a"}, {:string, "x"}}
    assert expr("$a ??= 1") == {:assign_op, :coalesce, {:var, "a"}, {:int, 1}}
    assert expr("$a = &$b") == {:assign_ref, {:var, "a"}, {:var, "b"}}
  end

  test "comparison ops" do
    assert expr("$a <=> $b") == {:binop, :"<=>", {:var, "a"}, {:var, "b"}}
    assert expr("$a === $b") == {:binop, :===, {:var, "a"}, {:var, "b"}}
    assert expr("1 << 2 >> 3") == {:binop, :shr, {:binop, :shl, {:int, 1}, {:int, 2}}, {:int, 3}}
  end

  test "casts" do
    assert expr("(int) $x") == {:cast, :int, {:var, "x"}}
    assert expr("(bool) $x") == {:cast, :bool, {:var, "x"}}
    assert expr("(string) 1.5") == {:cast, :string, {:float, 1.5}}
  end

  test "increments" do
    assert expr("++$a") == {:pre_inc, {:var, "a"}}
    assert expr("$a++") == {:post_inc, {:var, "a"}}
    assert expr("$a[--$i]") == {:index, {:var, "a"}, {:pre_dec, {:var, "i"}}}
  end

  test "variables: var_var, index chains" do
    assert expr("$$name") == {:var_var, {:var, "name"}}
    assert expr("$a[1][2]") == {:index, {:index, {:var, "a"}, {:int, 1}}, {:int, 2}}
    assert expr("$a[]") == {:index, {:var, "a"}, nil}
  end

  test "array literals and kv" do
    assert expr("[1, 2]") == {:array, [kv(nil, {:int, 1}), kv(nil, {:int, 2})]}
    assert expr("['a' => 1, 2]") == {:array, [kv({:string, "a"}, {:int, 1}), kv(nil, {:int, 2})]}

    assert expr("array(1, 'k' => 2)") ==
             {:array, [kv(nil, {:int, 1}), kv({:string, "k"}, {:int, 2})]}
  end

  test "string interpolation parts become AST" do
    assert {:interp,
            [
              {:text, "hi "},
              {:line_e, _, {:index, {:var, "a"}, {:int, 0}}},
              {:text, " "},
              {:line_e, _, {:prop, {:var, "b"}, {:lit_name, "c"}}},
              {:text, " end"}
            ]} = expr(~S|"hi $a[0] {$b->c} end"|)
  end

  test "calls: named, builtin, variable, static" do
    assert expr("foo(1, 'a')") ==
             {:call, {:const, ["foo"], false}, [arg({:int, 1}), arg({:string, "a"})]}

    assert expr("$f(1)") == {:call, {:var, "f"}, [arg({:int, 1})]}

    assert expr("A\\B::m(1)") ==
             {:static_call, {:cname, false, ["A", "B"]}, {:lit_name, "m"}, [arg({:int, 1})]}

    assert expr("strtoupper(x: 'a')") ==
             {:call, {:const, ["strtoupper"], false}, [{:arg, {:string, "a"}, false, "x"}]}
  end

  test "member access" do
    assert expr("$o->p") == {:prop, {:var, "o"}, {:lit_name, "p"}}

    assert expr("$o->m(1)") ==
             {:method_call, {:var, "o"}, {:lit_name, "m"}, [arg({:int, 1})], false}

    assert expr("$o?->p") == {:nullsafe_prop, {:var, "o"}, {:lit_name, "p"}}
    assert expr("A::$p") == {:static_prop, {:cname, false, ["A"]}, {:var, "p"}}
    assert expr("A::CONST") == {:class_const, {:cname, false, ["A"]}, "CONST"}
    assert expr("A::class") == {:class_const, {:cname, false, ["A"]}, "class"}
  end

  test "new" do
    assert expr("new Foo(1)") == {:new, {:cname, false, ["Foo"]}, [arg({:int, 1})]}
    assert expr("new \\Foo\\Bar") == {:new, {:cname, true, ["Foo", "Bar"]}, []}
    assert expr("new $cls") == {:new, {:var, "cls"}, []}
  end

  test "instanceof" do
    assert expr("$x instanceof Foo") ==
             {:binop, :instanceof, {:var, "x"}, {:const, ["Foo"], false}}
  end

  test "closures and arrow fn" do
    c = expr("function ($a) use ($b) { return $a; }")
    assert elem(c, 0) == :closure
    assert elem(c, 1) == [param("a")]
    assert elem(c, 2) == ["b"]

    f = expr("fn($x) => $x * 2")
    assert elem(f, 0) == :closure
    assert elem(f, 5) == true
  end

  test "function definition" do
    [{:func_def, name, params, body}] =
      parse("<?php function add($a, $b = 2, ...$rest) { return $a; }")

    assert name == "add"

    assert params == [
             {:param, "a", nil, nil, false, false},
             {:param, "b", nil, {:int, 2}, false, false},
             {:param, "rest", nil, nil, false, true}
           ]

    assert body == [{:return, {:var, "a"}}]
  end

  test "if / else / elseif nesting" do
    ast = parse("<?php if ($a) { echo 1; } elseif ($b) echo 2; else { echo 3; }")
    assert [{:if, {:var, "a"}, [{:echo, [{:int, 1}]}], else_part}] = ast
    assert [{:if, {:var, "b"}, [{:echo, [{:int, 2}]}], [{:echo, [{:int, 3}]}]}] = else_part
  end

  test "alternative syntax" do
    ast = parse("<?php if ($a): echo 1; echo 2; endif;")
    assert [{:if, {:var, "a"}, [{:echo, [{:int, 1}]}, {:echo, [{:int, 2}]}], nil}] = ast
  end

  test "while / do-while / for" do
    assert [{:while, {:var, "a"}, _}] = parse("<?php while ($a) echo 1;")

    assert [{:do_while, [{:echo, [{:int, 1}]}], {:var, "a"}}] =
             parse("<?php do { echo 1; } while ($a);")

    assert [{:for, init, cond, step, body}] = parse("<?php for ($i = 0; $i < 10; $i++) echo $i;")

    assert init == [{:assign, {:var, "i"}, {:int, 0}}]
    assert cond == {:binop, :<, {:var, "i"}, {:int, 10}}
    assert step == [{:post_inc, {:var, "i"}}]
  end

  test "foreach forms" do
    assert [{:foreach, {:var, "a"}, nil, {:var, "v"}, false, _}] =
             parse("<?php foreach ($a as $v) {}")

    assert [{:foreach, {:var, "a"}, {:var, "k"}, {:var, "v"}, false, _}] =
             parse("<?php foreach ($a as $k => $v) {}")

    assert [{:foreach, {:var, "a"}, nil, {:var, "v"}, true, _}] =
             parse("<?php foreach ($a as &$v) {}")

    assert [{:foreach, {:var, "a"}, nil, {:list_pat, [_, _]}, false, _}] =
             parse("<?php foreach ($a as [$x, $y]) {}")
  end

  test "switch with multiple case values" do
    ast = parse("<?php switch ($x) { case 1: case 2: echo 'a'; break; default: echo 'b'; }")

    assert [{:switch, {:var, "x"}, cases}] = ast
    # `case 1: case 2:` are two labels sharing one body (fall-through)
    assert [{[{:int, 1}], []}, {[{:int, 2}], _}] = Enum.take(cases, 2)
    assert {:default, _} = List.last(cases)
  end

  test "match" do
    m = expr("match($x) { 1, 2 => 'a', default => 'b' }")

    assert m ==
             {:match, {:var, "x"},
              [{[{:int, 1}, {:int, 2}], {:string, "a"}}, {:default, {:string, "b"}}]}
  end

  test "list destructuring" do
    assert expr("[$a, , $c] = $arr") ==
             {:assign, {:list_pat, [kv(nil, {:var, "a"}), nil, kv(nil, {:var, "c"})]},
              {:var, "arr"}}

    assert expr("list('x' => $a) = $arr") ==
             {:assign, {:list_pat, [kv({:string, "x"}, {:var, "a"})]}, {:var, "arr"}}
  end

  test "global and static vars" do
    assert [{:global, ["a", "b"]}] = parse("<?php global $a, $b;")
    assert [{:static_vars, [{"i", {:int, 0}}]}] = parse("<?php static $i = 0;")
    assert [{:static_vars, [{"x", nil}]}] = parse("<?php static $x;")
  end

  test "try/catch/finally" do
    ast = parse("<?php try { f(); } catch (A\\E | B $e) { } finally { g(); }")

    assert [{:try_stmt, _body, catches, finally}] = ast
    assert {types, "e", _} = hd(catches)
    assert types == [["A", "E"], ["B"]]
    assert finally == [{:expr_stmt, {:call, {:const, ["g"], false}, []}}]
  end

  test "isset / empty / unset" do
    assert expr("isset($a, $b[0])") == {:isset, [{:var, "a"}, {:index, {:var, "b"}, {:int, 0}}]}
    assert expr("empty($a)") == {:empty, {:var, "a"}}
    assert [{:unset, [{:var, "a"}]}] = parse("<?php unset($a);")
  end

  test "namespace and use" do
    assert [{:namespace, ["App"], nil}] = parse("<?php namespace App;")
    assert [{:use, :normal, [{["Foo", "Bar"], nil}], nil}] = parse("<?php use Foo\\Bar;")
    assert [{:use, :function, [{["f"], "g"}], nil}] = parse("<?php use function f as g;")

    assert [{:use, :normal, [{["Bar"], nil}, {["Baz"], "Z"}], ["Foo"]}] =
             parse("<?php use Foo\\{Bar, Baz as Z};")
  end

  test "exit constructs" do
    assert expr("exit(1)") == {:exit_expr, {:int, 1}}
    assert expr("die") == {:exit_expr, nil}
  end

  test "throw as statement" do
    assert [{:expr_stmt, {:throw, {:new, {:cname, false, ["Exception"]}, []}}}] =
             parse("<?php throw new Exception();")
  end

  test "error suppression" do
    assert expr("@$x['k']") == {:unop, :@, {:index, {:var, "x"}, {:string, "k"}}}
  end

  test "parse errors" do
    assert {:error, _, _} =
             Lexer.tokenize("<?php 1 + ;") |> then(fn {:ok, t} -> Parser.parse(t) end)

    assert {:error, _, _} =
             Lexer.tokenize("<?php if ($x { }") |> then(fn {:ok, t} -> Parser.parse(t) end)
  end

  defp kv(k, v), do: {:kv, k, v, false}
  defp arg(v), do: {:arg, v, false, nil}
  defp param(n), do: {:param, n, nil, nil, false, false}
end
