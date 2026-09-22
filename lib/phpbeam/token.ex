defmodule PhpBeam.Token do
  @moduledoc """
  PHP 8 token definitions shared by the lexer and parser.

  A token is a 3-tuple `{kind, line, value}`:

    * `:inline_html`   — raw text outside `<?php ... ?>`
    * `:variable`      — `$foo`; value is the variable name without `$`
    * `:int`           — integer literal (already wrapped to float on 64-bit overflow)
    * `:float`         — float literal
    * `:string`        — single-quoted string; value is the unescaped bytes
    * `:interp_string` — double-quoted / heredoc; value is a parts list:
      `{:text, binary}` | `{:simple, name, accessors}` | `{:complex, tokens}`
      where accessors is a list of `{:index, idx}` (`idx` is `{:str, s}` |
      `{:int, i}` | `{:var, name}`) or `{:prop, name}`.
    * `:name`          — identifier or keyword; value kept as written
    * `:op`            — operator or punctuator; value is the operator text
    * `:eof`
  """

  @type interp_part ::
          {:text, binary}
          | {:simple, binary, list({:index, idx} | {:prop, binary})}
          | {:complex, [t()]}
  @type idx :: {:str, binary} | {:int, integer} | {:var, binary}

  @type t :: {kind(), line :: pos_integer(), value :: term()}
  @type kind ::
          :inline_html
          | :variable
          | :int
          | :float
          | :string
          | :interp_string
          | :shell_string
          | :name
          | :op
          | :eof

  @doc """
  Operators and punctuators, longest first, for maximal-munch lexing.
  """
  @spec operators() :: [binary]
  def operators do
    [
      "<=>",
      "===",
      "!==",
      "**=",
      "<<=",
      ">>=",
      "??=",
      "?->",
      "...",
      "**",
      "++",
      "--",
      "->",
      "=>",
      "<=",
      ">=",
      "&&",
      "||",
      "??",
      "<<",
      ">>",
      "+=",
      "-=",
      "*=",
      "/=",
      ".=",
      "%=",
      "&=",
      "|=",
      "^=",
      "==",
      "!=",
      "<>",
      "::",
      "+",
      "-",
      "*",
      "/",
      "%",
      ".",
      "=",
      "<",
      ">",
      "!",
      "?",
      ":",
      ";",
      ",",
      "(",
      ")",
      "[",
      "]",
      "{",
      "}",
      "&",
      "|",
      "^",
      "@",
      "\\",
      "~",
      "$"
    ]
  end

  @cast_types ~w(int integer bool boolean float double real string binary array object)

  @doc "Whether `name` (already downcased) names a cast type like `(int)`."
  def cast_type?(name), do: name in @cast_types

  @doc "Normalize a cast type alias to its canonical type atom."
  def cast_kind(name) do
    case name do
      n when n in ~w(int integer) -> :int
      n when n in ~w(bool boolean) -> :bool
      n when n in ~w(float double real) -> :float
      "string" -> :string
      "array" -> :array
      "object" -> :object
    end
  end
end
