defmodule PhpBeam.LexerTest do
  use ExUnit.Case, async: true

  alias PhpBeam.Lexer

  defp toks(src) do
    {:ok, ts} = Lexer.tokenize(src)
    Enum.map(ts, fn {k, _l, v} -> {k, v} end)
  end

  defp values(src, kind) do
    toks(src) |> Enum.filter(&match?({^kind, _}, &1)) |> Enum.map(fn {_, v} -> v end)
  end

  defp only_interp(src) do
    {:ok, ts} = Lexer.tokenize(src)

    ts
    |> Enum.filter(&match?({:interp_string, _, _}, &1))
    |> Enum.map(fn {_, _, v} -> v end)
  end

  test "empty php file" do
    assert toks("<?php ") == [eof: :eof]
  end

  test "inline html before and after php" do
    src = "<h1>hi</h1><?php echo 1; ?>bye"
    ts = toks(src)
    assert {:inline_html, "<h1>hi</h1>"} = Enum.at(ts, 0)
    assert {:name, "echo"} = Enum.at(ts, 1)
    assert {:inline_html, "bye"} = Enum.at(ts, 5)
  end

  test "close tag implies semicolon and swallows one newline" do
    ts = toks("<?php echo 1 ?>\n<b>x</b>")
    assert {:op, ";"} in ts
    assert {:inline_html, "<b>x</b>"} in ts
  end

  test "short echo tag" do
    ts = toks("<?= 'hi' ?>")
    assert {:name, "echo"} = Enum.at(ts, 0)
    assert {:string, "hi"} = Enum.at(ts, 1)
  end

  test "integer literals: decimal, hex, octal, binary, underscores" do
    assert [123, 31, 15, 10, 1_000_000] == values("<?php 123 0x1F 0o17 0b1010 1_000_000", :int)
  end

  test "legacy octal 0123" do
    assert [83] == values("<?php 0123", :int)
  end

  test "invalid legacy octal errors" do
    assert {:error, _, _} = Lexer.tokenize("<?php 018;")
  end

  test "int overflow becomes float" do
    assert [9.223372036854776e18] == values("<?php 9223372036854775808", :float)
  end

  test "float literals" do
    assert [1.5, 0.5, 1.0, 1000.0, 0.0015, 2.0e8] ==
             values("<?php 1.5 .5 1. 1e3 1.5E-3 2e+8", :float)
  end

  test "number followed by identifier errors" do
    assert {:error, _, _} = Lexer.tokenize("<?php 123abc;")
  end

  test "single quoted strings keep escapes literal" do
    assert [~S(a\"b\n)] == values(~S(<?php 'a\"b\n'>), :string)
  end

  test "double quoted escapes" do
    parts = only_interp(~S(<?php "a\nb\tc\\d$e\"f">))
    assert [[{:text, "a\nb\tc\\d"}, {:simple, "e", [], _}, {:text, "\"f"}]] = parts
  end

  test "hex, octal and unicode escapes" do
    parts = only_interp(~S(<?php "\x41\101é">))
    assert [[{:text, "A" <> "A" <> "é"}]] = parts
  end

  test "simple interpolation: var, index, prop" do
    assert [[{:simple, "a", [], _}, {:text, " "}]] = only_interp(~S(<?php "$a ">))
    assert [[{:simple, "a", [{:index, {:str, "k"}}], _}]] = only_interp(~S(<?php "$a[k]">))
    assert [[{:simple, "a", [{:index, {:int, 0}}], _}]] = only_interp(~S(<?php "$a[0]">))
    assert [[{:simple, "a", [{:index, {:var, "i"}}], _}]] = only_interp(~S(<?php "$a[$i]">))
    assert [[{:simple, "a", [{:prop, "b"}], _}]] = only_interp(~S(<?php "$a->b">))
    # invalid index → the bracket stays literal text
    assert [[{:simple, "a", [], _}, {:text, "[x+y]"}]] = only_interp(~S(<?php "$a[x+y]">))
  end

  test "complex interpolation" do
    parts = only_interp(~S|<?php "{$a->m(1, 2)}"|)
    assert [[{:complex, toks2, _}]] = parts
    assert {:variable, _, "a"} = Enum.find(toks2, &match?({:variable, _, _}, &1))
  end

  test "comments" do
    assert [1] == values("<?php // line\n# hash\n/* block\nspan */ 1;", :int)
  end

  test "close tag inside line comment" do
    ts = toks("<?php // comment ?>HTML")
    assert {:inline_html, "HTML"} in ts
  end

  test "heredoc with interpolation and flexible indentation" do
    src = "<?php\n  <<<EOT\n    hello $name\n    EOT;\n"
    assert [[{:text, "hello "}, {:simple, "name", [], _}]] = only_interp(src)
  end

  test "nowdoc is raw" do
    src = "<?php\n<<<'EOT'\nraw $x \\n\nEOT;\n"
    assert ["raw $x \\n"] == values(src, :string)
  end

  test "heredoc closing marker followed by punctuation" do
    src = "<?php $a = <<<EOT\nx\nEOT . 'y';"
    assert [[{:text, "x"}]] = only_interp(src)
  end

  test "variables and variable-variable" do
    assert ["foo", "bar"] == values("<?php $foo $$bar;", :variable)
    assert {:op, "$"} in toks("<?php $foo $$bar;")
  end

  test "operators maximal munch" do
    ops = values("<?php $a<=> $b === $c !== $d **= 2 ?-> p ??= q ... \$r", :op)
    assert ["<=>", "===", "!==", "**=", "?->", "??=", "..."] -- ops == []
  end

  test "unterminated string errors" do
    assert {:error, _, _} = Lexer.tokenize(~S(<?php "abc))
    assert {:error, _, _} = Lexer.tokenize(~S(<?php 'abc))
  end

  test "unterminated heredoc errors" do
    assert {:error, _, _} = Lexer.tokenize("<?php $a = <<<EOT\nno end")
  end

  test "backtick shell string lexes" do
    {:ok, ts} = Lexer.tokenize("<?php `ls`")

    assert [{:shell_string, _, [{:text, "ls"}]}] =
             Enum.filter(ts, &match?({:shell_string, _, _}, &1))
  end

  test "line numbers tracked" do
    {:ok, ts} = Lexer.tokenize("<?php\n$a = 1;\n$b = 2;\n")

    lines =
      ts
      |> Enum.filter(&match?({:variable, _, _}, &1))
      |> Enum.map(fn {_, l, _} -> l end)

    assert lines == [2, 3]
  end
end
