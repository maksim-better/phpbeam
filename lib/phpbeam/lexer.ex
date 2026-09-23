defmodule PhpBeam.Lexer do
  @moduledoc """
  PHP 8 lexer: source bytes → token list.

  Handles inline-HTML / PHP mode switching (`<?php`, `<?=`, `?>`), comments
  (including the `?>`-inside-line-comment rule), all numeric literal forms
  (hex/octal/binary/underscores/float exponents, 64-bit overflow to float),
  single/double-quoted strings, heredoc/nowdoc with PHP 7.3+ flexible
  indentation, escape sequences, and simple + complex (`{$...}`) string
  interpolation scanning.
  """

  alias PhpBeam.Token

  @type error :: {:error, binary(), pos_integer()}

  @int_max 9_223_372_036_854_775_807

  defguardp name_start?(c) when c in ?a..?z or c in ?A..?Z or c == ?_ or c >= 0x80

  defguardp name_char?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c >= 0x80

  @spec tokenize(binary()) :: {:ok, [Token.t()]} | error()
  def tokenize(src) do
    case html_mode(src, 1, []) do
      {:ok, acc, _rest, line} -> {:ok, Enum.reverse(acc) ++ [{:eof, line, :eof}]}
      {:error, _, _} = e -> e
    end
  end

  @doc """
  Lex a PHP code fragment (the body of a `{$...}` interpolation).
  Requires balanced braces; returns the unconsumed tail.
  """
  @spec tokenize_fragment(binary(), pos_integer()) :: {:ok, [Token.t()], binary()} | error()
  def tokenize_fragment(src, line) do
    case php_mode(src, line, [], {:frag, 0}) do
      {:ok, toks, rest, _l} -> {:ok, Enum.reverse(toks), rest}
      {:error, _, _} = e -> e
    end
  end

  # ─────────────────────────── HTML mode ───────────────────────────

  defp html_mode(src, line, acc)

  defp html_mode("", line, acc), do: {:ok, acc, "", line}

  # <?= expr ?> behaves like echo expr;
  defp html_mode("<?=" <> rest, line, acc),
    do: php_mode(rest, line, [{:name, line, "echo"} | acc], nil)

  defp html_mode("<?php" <> rest, line, acc) do
    if rest == "" or whitespace?(first_byte(rest)) do
      php_mode(rest, line, acc, nil)
    else
      # not a real open tag (e.g. `<?phpx`): stays literal text
      html_mode(rest, line, [{:inline_html, line, "<?php"} | acc])
    end
  end

  defp html_mode(src, line, acc) do
    case :binary.match(src, "<?") do
      :nomatch ->
        {:ok, [{:inline_html, line, src} | acc], "", line + count_nl(src)}

      {pos, 2} ->
        prefix = binary_part(src, 0, pos)
        rest = binary_part(src, pos, byte_size(src) - pos)
        html_mode(rest, line + count_nl(prefix), [{:inline_html, line, prefix} | acc])
    end
  end

  # ─────────────────────────── PHP mode ───────────────────────────
  # ctx: nil (top level) or {:frag, depth} while lexing an interpolation body.

  defp php_mode(src, line, acc, ctx)

  defp php_mode("", line, acc, nil), do: {:ok, acc, "", line}
  defp php_mode("", line, _acc, {:frag, _}), do: {:error, "unterminated interpolation", line}

  defp php_mode(<<c, rest::binary>>, line, acc, ctx) when c == ?\s or c == ?\t or c == ?\r,
    do: php_mode(rest, line, acc, ctx)

  defp php_mode("\n" <> rest, line, acc, ctx), do: php_mode(rest, line + 1, acc, ctx)

  # close tag: implies a statement terminator, back to HTML, swallows one newline
  defp php_mode("?>" <> rest, line, acc, nil),
    do: html_mode(strip_one_newline(rest), line, [{:op, line, ";"} | acc])

  defp php_mode("?>" <> _, line, _acc, {:frag, _}),
    do: {:error, "unexpected \"?>\" inside interpolation", line}

  # comments
  defp php_mode("//" <> rest, line, acc, ctx), do: line_comment(rest, line, acc, ctx)
  defp php_mode("#" <> rest, line, acc, ctx), do: line_comment(rest, line, acc, ctx)
  defp php_mode("/*" <> rest, line, acc, ctx), do: block_comment(rest, line, acc, ctx)

  # $name — a `$` not followed by a name char is an operator (for $$name)
  defp php_mode(<<?$, c, rest::binary>>, line, acc, ctx) when name_start?(c) do
    {name, rest2} = take_name(c, rest)
    php_mode(rest2, line, [{:variable, line, name} | acc], ctx)
  end

  # numbers
  defp php_mode(<<c, rest::binary>>, line, acc, ctx) when c >= ?0 and c <= ?9,
    do: number(c, rest, line, acc, ctx)

  defp php_mode(<<?., c, rest::binary>>, line, acc, ctx) when c >= ?0 and c <= ?9 do
    {more, rest2} = take_while(rest, fn c -> (c >= ?0 and c <= ?9) or c == ?_ end)
    build_float("", <<c>> <> more, rest2, line, acc, ctx)
  end

  # names
  defp php_mode(<<c, rest::binary>>, line, acc, ctx) when name_start?(c) do
    {name, rest2} = take_name(c, rest)
    php_mode(rest2, line, [{:name, line, name} | acc], ctx)
  end

  # strings
  defp php_mode("'" <> rest, line, acc, ctx), do: sq_string(rest, line, [], acc, ctx)

  defp php_mode(<<?", rest::binary>>, line, acc, ctx),
    do: dq_string(rest, line, [], [], acc, ctx, :dq)

  defp php_mode("`" <> rest, line, acc, ctx), do: dq_string(rest, line, [], [], acc, ctx, :shell)

  # heredoc / nowdoc
  defp php_mode("<<<" <> rest, line, acc, ctx), do: heredoc(rest, line, acc, ctx)

  # brace tracking inside interpolation fragments
  defp php_mode("{" <> rest, line, acc, {:frag, d}),
    do: php_mode(rest, line, [{:op, line, "{"} | acc], {:frag, d + 1})

  defp php_mode("}" <> rest, line, acc, {:frag, 0}), do: {:ok, acc, "}" <> rest, line}

  # operators: clauses are ordered longest-first so matching is maximal-munch
  defp php_mode("<=>" <> rest, line, acc, ctx), do: emit("<=>", rest, line, acc, ctx)
  defp php_mode("===" <> rest, line, acc, ctx), do: emit("===", rest, line, acc, ctx)
  defp php_mode("!==" <> rest, line, acc, ctx), do: emit("!==", rest, line, acc, ctx)
  defp php_mode("**=" <> rest, line, acc, ctx), do: emit("**=", rest, line, acc, ctx)
  defp php_mode("<<=" <> rest, line, acc, ctx), do: emit("<<=", rest, line, acc, ctx)
  defp php_mode(">>=" <> rest, line, acc, ctx), do: emit(">>=", rest, line, acc, ctx)
  defp php_mode("??=" <> rest, line, acc, ctx), do: emit("??=", rest, line, acc, ctx)
  defp php_mode("?->" <> rest, line, acc, ctx), do: emit("?->", rest, line, acc, ctx)
  defp php_mode("..." <> rest, line, acc, ctx), do: emit("...", rest, line, acc, ctx)
  defp php_mode("**" <> rest, line, acc, ctx), do: emit("**", rest, line, acc, ctx)
  defp php_mode("++" <> rest, line, acc, ctx), do: emit("++", rest, line, acc, ctx)
  defp php_mode("--" <> rest, line, acc, ctx), do: emit("--", rest, line, acc, ctx)
  defp php_mode("->" <> rest, line, acc, ctx), do: emit("->", rest, line, acc, ctx)
  defp php_mode("=>" <> rest, line, acc, ctx), do: emit("=>", rest, line, acc, ctx)
  defp php_mode("<=" <> rest, line, acc, ctx), do: emit("<=", rest, line, acc, ctx)
  defp php_mode(">=" <> rest, line, acc, ctx), do: emit(">=", rest, line, acc, ctx)
  defp php_mode("&&" <> rest, line, acc, ctx), do: emit("&&", rest, line, acc, ctx)
  defp php_mode("||" <> rest, line, acc, ctx), do: emit("||", rest, line, acc, ctx)
  defp php_mode("??" <> rest, line, acc, ctx), do: emit("??", rest, line, acc, ctx)
  defp php_mode("<<" <> rest, line, acc, ctx), do: emit("<<", rest, line, acc, ctx)
  defp php_mode(">>" <> rest, line, acc, ctx), do: emit(">>", rest, line, acc, ctx)
  defp php_mode("+=" <> rest, line, acc, ctx), do: emit("+=", rest, line, acc, ctx)
  defp php_mode("-=" <> rest, line, acc, ctx), do: emit("-=", rest, line, acc, ctx)
  defp php_mode("*=" <> rest, line, acc, ctx), do: emit("*=", rest, line, acc, ctx)
  defp php_mode("/=" <> rest, line, acc, ctx), do: emit("/=", rest, line, acc, ctx)
  defp php_mode(".=" <> rest, line, acc, ctx), do: emit(".=", rest, line, acc, ctx)
  defp php_mode("%=" <> rest, line, acc, ctx), do: emit("%=", rest, line, acc, ctx)
  defp php_mode("&=" <> rest, line, acc, ctx), do: emit("&=", rest, line, acc, ctx)
  defp php_mode("|=" <> rest, line, acc, ctx), do: emit("|=", rest, line, acc, ctx)
  defp php_mode("^=" <> rest, line, acc, ctx), do: emit("^=", rest, line, acc, ctx)
  defp php_mode("==" <> rest, line, acc, ctx), do: emit("==", rest, line, acc, ctx)
  defp php_mode("!=" <> rest, line, acc, ctx), do: emit("!=", rest, line, acc, ctx)
  defp php_mode("<>" <> rest, line, acc, ctx), do: emit("<>", rest, line, acc, ctx)
  defp php_mode("::" <> rest, line, acc, ctx), do: emit("::", rest, line, acc, ctx)

  defp php_mode(<<c, rest::binary>>, line, acc, ctx) when c in ~c"+-*/%.=<>!?:;,()[]{}&|^@\\~$",
    do: emit(<<c>>, rest, line, acc, ctx)

  defp php_mode(<<c, _rest::binary>>, line, _acc, _ctx),
    do: {:error, "unexpected character #{inspect(<<c>>, binaries: :as_strings)}", line}

  defp emit(op, rest, line, acc, ctx), do: php_mode(rest, line, [{:op, line, op} | acc], ctx)

  # ─────────────────────────── comments ───────────────────────────

  defp line_comment(rest, line, acc, ctx) do
    nl = :binary.match(rest, "\n")
    close = :binary.match(rest, "?>")

    close_first? =
      case {nl, close} do
        {:nomatch, :nomatch} -> false
        {:nomatch, {_, _}} -> true
        {{_, _}, :nomatch} -> false
        {{pn, _}, {pc, _}} -> pc < pn
      end

    cond do
      close_first? ->
        {pc, 2} = close
        tail = binary_part(rest, pc + 2, byte_size(rest) - pc - 2)
        html_mode(strip_one_newline(tail), line, [{:op, line, ";"} | acc])

      nl == :nomatch ->
        php_mode("", line, acc, ctx)

      true ->
        {pn, _} = nl
        php_mode(binary_part(rest, pn, byte_size(rest) - pn), line, acc, ctx)
    end
  end

  defp block_comment(rest, line, acc, ctx) do
    case :binary.match(rest, "*/") do
      :nomatch ->
        {:error, "unterminated comment", line}

      {pos, 2} ->
        chunk = binary_part(rest, 0, pos)

        php_mode(
          binary_part(rest, pos + 2, byte_size(rest) - pos - 2),
          line + count_nl(chunk),
          acc,
          ctx
        )
    end
  end

  # ─────────────────────────── names ───────────────────────────

  defp take_name(c, rest), do: do_take_name(rest, <<c>>)

  defp do_take_name(<<c, rest::binary>>, acc) when name_char?(c),
    do: do_take_name(rest, <<acc::binary, c>>)

  defp do_take_name(rest, acc), do: {acc, rest}

  defp whitespace?(c), do: c == ?\s or c == ?\t or c == ?\r or c == ?\n

  defp first_byte(<<c, _::binary>>), do: c

  # ─────────────────────────── numbers ───────────────────────────

  defp number(?0, rest, line, acc, ctx) do
    case rest do
      <<x, _::binary>> when x in ~c"xX" -> radix_number(rest, 16, line, acc, ctx)
      <<x, _::binary>> when x in ~c"oO" -> radix_number(rest, 8, line, acc, ctx)
      <<x, _::binary>> when x in ~c"bB" -> radix_number(rest, 2, line, acc, ctx)
      _ -> decimal_number("0", rest, line, acc, ctx)
    end
  end

  defp number(c, rest, line, acc, ctx), do: decimal_number(<<c>>, rest, line, acc, ctx)

  defp radix_number(<<_pfx, rest::binary>>, base, line, acc, ctx) do
    {digits, rest2} = take_while(rest, &(&1 in radix_chars(base)))

    cond do
      digits == "" ->
        {:error, "invalid numeric literal", line}

      underscore_misplaced?(digits) ->
        {:error, "invalid underscore placement in numeric literal", line}

      true ->
        int_token(String.to_integer(String.replace(digits, "_", ""), base), rest2, line, acc, ctx)
    end
  end

  defp radix_chars(16), do: ~c"0123456789abcdefABCDEF_"
  defp radix_chars(8), do: ~c"01234567_"
  defp radix_chars(2), do: ~c"01_"

  defp decimal_number(int_digits, rest, line, acc, ctx) do
    {more, rest2} = take_while(rest, fn c -> (c >= ?0 and c <= ?9) or c == ?_ end)
    digits = int_digits <> more

    case rest2 do
      <<?., r::binary>> ->
        {frac, rest3} = take_while(r, fn c -> (c >= ?0 and c <= ?9) or c == ?_ end)
        build_float(digits, frac, rest3, line, acc, ctx)

      <<e, _::binary>> when e in ~c"eE" ->
        build_float(digits, "", rest2, line, acc, ctx)

      _ ->
        decimal_int(digits, rest2, line, acc, ctx)
    end
  end

  # plain decimal integer or legacy octal (0123)
  defp decimal_int(digits, rest, line, acc, ctx) do
    cond do
      underscore_misplaced?(digits) ->
        {:error, "invalid underscore placement in numeric literal", line}

      true ->
        digits = String.replace(digits, "_", "")

        value =
          if byte_size(digits) > 1 and :binary.first(digits) == ?0 do
            # legacy octal
            if Regex.match?(~r/^[0-7]*$/, digits) do
              String.to_integer(digits, 8)
            else
              :invalid_octal
            end
          else
            String.to_integer(digits)
          end

        case value do
          :invalid_octal ->
            {:error, "invalid octal literal #{digits}", line}

          v ->
            case rest do
              <<x, _::binary>> when name_char?(x) or x == ?. ->
                {:error, "syntax error: malformed number", line}

              _ ->
                int_token(v, rest, line, acc, ctx)
            end
        end
    end
  end

  defp int_token(val, rest, line, acc, ctx) do
    if val > @int_max do
      php_mode(rest, line, [{:float, line, val * 1.0} | acc], ctx)
    else
      php_mode(rest, line, [{:int, line, val} | acc], ctx)
    end
  end

  # Build a float from integer digits, fraction digits (possibly empty) and
  # the remaining source (which may start with an exponent).
  defp build_float(int, frac, rest, line, acc, ctx) do
    int_s = String.replace(int, "_", "")
    frac_s = String.replace(frac, "_", "")

    {exp_s, rest2} =
      case rest do
        <<e, r::binary>> when e in ~c"eE" ->
          {sign, r2} =
            case r do
              <<s, rr::binary>> when s in ~c"+-" -> {<<s>>, rr}
              _ -> {"", r}
            end

          {d, r3} = take_while(r2, fn c -> (c >= ?0 and c <= ?9) or c == ?_ end)

          if d == "" do
            {"", rest}
          else
            {"e" <> sign <> String.replace(d, "_", ""), r3}
          end

        _ ->
          {"", rest}
      end

    num =
      if(int_s == "", do: "0", else: int_s) <>
        "." <> if(frac_s == "", do: "0", else: frac_s) <> exp_s

    case Float.parse(num) do
      {f, ""} ->
        case rest2 do
          <<x, _::binary>> when name_char?(x) -> {:error, "syntax error: malformed number", line}
          _ -> php_mode(rest2, line, [{:float, line, f} | acc], ctx)
        end

      _ ->
        {:error, "invalid float literal", line}
    end
  end

  defp underscore_misplaced?(digits) do
    :binary.first(digits) == ?_ or :binary.last(digits) == ?_ or String.contains?(digits, "__")
  end

  # ─────────────────────────── strings ───────────────────────────

  defp sq_string(rest, line, out, acc, ctx) do
    case rest do
      "'" <> rest2 ->
        php_mode(
          rest2,
          line,
          [{:string, line, IO.iodata_to_binary(Enum.reverse(out))} | acc],
          ctx
        )

      "\\\\" <> rest2 ->
        sq_string(rest2, line, ["\\" | out], acc, ctx)

      "\\'" <> rest2 ->
        sq_string(rest2, line, ["'" | out], acc, ctx)

      "\n" <> rest2 ->
        sq_string(rest2, line + 1, ["\n" | out], acc, ctx)

      <<c, rest2::binary>> ->
        sq_string(rest2, line, [<<c>> | out], acc, ctx)

      "" ->
        {:error, "unterminated string", line}
    end
  end

  # Double-quoted (and backtick) scanning with interpolation.
  defp dq_string(rest, line, text, parts, acc, ctx, style) do
    case rest do
      <<c, rest2::binary>> when c == ?" and style == :dq ->
        parts = flush_text(text, parts)
        php_mode(rest2, line, [{:interp_string, line, Enum.reverse(parts)} | acc], ctx)

      <<c, rest2::binary>> when c == ?` and style == :shell ->
        parts = flush_text(text, parts)
        php_mode(rest2, line, [{:shell_string, line, Enum.reverse(parts)} | acc], ctx)

      "\n" <> rest2 ->
        dq_string(rest2, line + 1, ["\n" | text], parts, acc, ctx, style)

      "\\" <> rest2 ->
        case escape(rest2, line, style) do
          {:ok, chunk, rest3, line2} ->
            dq_string(rest3, line2, [chunk | text], parts, acc, ctx, style)

          {:error, _, _} = e ->
            e
        end

      <<?$, c, rest2::binary>> when name_start?(c) ->
        {name, rest3} = take_name(c, rest2)
        {accessors, rest4} = simple_accessor(rest3, line)
        parts = flush_text(text, parts)
        dq_string(rest4, line, [], [{:simple, name, accessors} | parts], acc, ctx, style)

      "{$" <> rest2 ->
        case tokenize_fragment("$" <> rest2, line) do
          {:ok, toks, "}" <> rest3} ->
            parts = flush_text(text, parts)
            dq_string(rest3, line, [], [{:complex, toks} | parts], acc, ctx, style)

          {:ok, _, _} ->
            {:error, "unterminated interpolation", line}

          {:error, _, _} = e ->
            e
        end

      <<c, rest2::binary>> ->
        dq_string(rest2, line, [<<c>> | text], parts, acc, ctx, style)

      "" ->
        {:error, "unterminated string", line}
    end
  end

  defp flush_text([], parts), do: parts
  defp flush_text(text, parts), do: [{:text, IO.iodata_to_binary(Enum.reverse(text))} | parts]

  # ─────────────────── interpolation accessors ───────────────────
  # Simple syntax allows at most one accessor: `$a[i]` or `$a->p`.

  defp simple_accessor("[" <> rest, _line) do
    {inner, rest2} = take_while(rest, fn c -> c != ?] and c != ?\n end)

    case rest2 do
      "]" <> rest3 ->
        case simple_index(inner) do
          nil -> {[], "[" <> rest}
          idx -> {[{:index, idx}], rest3}
        end

      _ ->
        {[], "[" <> rest}
    end
  end

  defp simple_accessor("->" <> rest, _line) do
    case rest do
      <<c, r::binary>> when name_start?(c) ->
        {name, rest2} = take_name(c, r)
        {[{:prop, name}], rest2}

      _ ->
        {[], "->" <> rest}
    end
  end

  defp simple_accessor(rest, _line), do: {[], rest}

  defp simple_index(inner) do
    cond do
      inner == "" ->
        nil

      Regex.match?(~r/^[0-9]+$/, inner) ->
        {:int, String.to_integer(inner)}

      Regex.match?(~r/^[a-zA-Z_\x80-\xff][a-zA-Z0-9_\x80-\xff]*$/, inner) ->
        {:str, inner}

      Regex.match?(~r/^\$[a-zA-Z_\x80-\xff][a-zA-Z0-9_\x80-\xff]*$/, inner) ->
        {:var, binary_part(inner, 1, byte_size(inner) - 1)}

      true ->
        nil
    end
  end

  # ─────────────────────────── escapes ───────────────────────────

  defp escape(<<c, rest::binary>>, line, style) do
    case c do
      ?n ->
        {:ok, "\n", rest, line}

      ?r ->
        {:ok, "\r", rest, line}

      ?t ->
        {:ok, "\t", rest, line}

      ?v ->
        {:ok, "\v", rest, line}

      ?f ->
        {:ok, "\f", rest, line}

      ?e ->
        {:ok, "\e", rest, line}

      ?\\ ->
        {:ok, "\\", rest, line}

      ?$ ->
        {:ok, "$", rest, line}

      ?" when style != :heredoc ->
        {:ok, "\"", rest, line}

      ?` when style == :shell ->
        {:ok, "`", rest, line}

      ?x ->
        {hex, _rest2} = take_while(rest, fn c -> c in ~c"0123456789abcdefABCDEF" end)

        if hex == "" do
          {:ok, "\\x", rest, line}
        else
          n = min(byte_size(hex), 2)
          h = binary_part(hex, 0, n)
          rest3 = binary_part(rest, n, byte_size(rest) - n)
          {:ok, <<String.to_integer(h, 16)::8>>, rest3, line}
        end

      ?u ->
        case rest do
          "{" <> r ->
            {hex, r2} = take_while(r, fn c -> c in ~c"0123456789abcdefABCDEF" end)

            case r2 do
              "}" <> r3 when hex != "" ->
                cp = String.to_integer(hex, 16)

                if cp > 0x10FFFF do
                  {:error, "invalid UTF-8 codepoint escape", line}
                else
                  {:ok, <<cp::utf8>>, r3, line}
                end

              _ ->
                {:error, "malformed \\u{...} escape", line}
            end

          _ ->
            {:ok, "\\u", rest, line}
        end

      c when c >= ?0 and c <= ?7 ->
        {oct, _rest2} = take_while(rest, fn c -> c >= ?0 and c <= ?7 end)
        digits = <<c>> <> binary_part(oct, 0, min(2, byte_size(oct)))
        used = byte_size(digits)
        rest3 = binary_part(rest, used - 1, byte_size(rest) - used + 1)
        val = Bitwise.band(String.to_integer(digits, 8), 0xFF)
        {:ok, <<val::8>>, rest3, line}

      _ ->
        {:ok, <<?\\, c>>, rest, line}
    end
  end

  defp escape("", line, _style), do: {:error, "unterminated string", line}

  # ─────────────────────────── heredoc ───────────────────────────

  defp heredoc(rest, line, acc, ctx) do
    {_ws, rest1} = take_while(rest, fn c -> c == ?\s or c == ?\t end)

    case read_marker(rest1) do
      {:ok, marker, interp?, rest2} ->
        {trailing, rest3} = take_while(rest2, fn c -> c == ?\s or c == ?\t end)

        case rest3 do
          "\r\n" <> rest4 ->
            heredoc_body(rest4, line + 1, marker, interp?, [], acc, ctx)

          "\n" <> rest4 ->
            heredoc_body(rest4, line + 1, marker, interp?, [], acc, ctx)

          _ when trailing != "" ->
            {:error, "invalid characters after heredoc identifier", line}

          _ ->
            {:error, "expected newline after heredoc opener", line}
        end

      {:error, msg} ->
        {:error, msg, line}
    end
  end

  defp read_marker("'" <> rest) do
    {m, r} = take_label(rest)

    if m != "" and r != "" and first_byte(r) == ?' do
      {:ok, m, false, tl_bytes(r)}
    else
      {:error, "invalid nowdoc identifier"}
    end
  end

  defp read_marker(<<?", rest::binary>>) do
    {m, r} = take_label(rest)

    if m != "" and r != "" and first_byte(r) == ?" do
      {:ok, m, true, tl_bytes(r)}
    else
      {:error, "invalid heredoc identifier"}
    end
  end

  defp read_marker(<<c, rest::binary>>) when name_start?(c) do
    {m, r} = take_name(c, rest)
    {:ok, m, true, r}
  end

  defp read_marker(_), do: {:error, "invalid heredoc opener"}

  defp tl_bytes(<<_c, rest::binary>>), do: rest

  defp take_label(<<c, rest::binary>>) when name_start?(c), do: take_name(c, rest)
  defp take_label(_), do: {"", ""}

  # Collect body lines until the closing marker line.
  defp heredoc_body(src, line, marker, interp?, lines, acc, ctx) do
    if src == "" do
      {:error, "unterminated heredoc", line}
    else
      {line_bytes, rest, had_nl?} = split_line(src)

      case heredoc_close_remainder(line_bytes, marker) do
        {:ok, after_marker} ->
          body = finalize_heredoc_body(Enum.reverse(lines), closing_indent(line_bytes))

          case heredoc_token(body, interp?, line) do
            {:ok, tok} ->
              rest_code = after_marker <> if(had_nl?, do: "\n" <> rest, else: rest)
              php_mode(rest_code, line + if(had_nl?, do: 1, else: 0), [tok | acc], ctx)

            {:error, m, l} ->
              {:error, m, l}
          end

        :error ->
          if rest == "" and not had_nl? do
            {:error, "unterminated heredoc", line}
          else
            heredoc_body(rest, line + 1, marker, interp?, [line_bytes | lines], acc, ctx)
          end
      end
    end
  end

  defp heredoc_token(body, interp?, line) do
    if interp? do
      case scan_interp_parts(body, line, [], []) do
        {:ok, parts, _} -> {:ok, {:interp_string, line, Enum.reverse(parts)}}
        {:error, _, _} = e -> e
      end
    else
      {:ok, {:string, line, body}}
    end
  end

  # split one line; returns content without newline, rest, whether a newline was consumed
  defp split_line(src) do
    case :binary.match(src, "\n") do
      :nomatch ->
        {strip_cr(src), "", false}

      {pos, _} ->
        line = binary_part(src, 0, pos)
        rest = binary_part(src, pos + 1, byte_size(src) - pos - 1)
        {strip_cr(line), rest, true}
    end
  end

  defp strip_cr(line) do
    if byte_size(line) > 0 and :binary.last(line) == ?\r,
      do: binary_part(line, 0, byte_size(line) - 1),
      else: line
  end

  # the closing marker line: leading indent + marker must be followed by a
  # non-name char; whatever follows the marker is ordinary PHP code
  defp heredoc_close_remainder(line, marker) do
    {_indent, content} = take_while(line, fn c -> c == ?\s or c == ?\t end)

    if String.starts_with?(content, marker) do
      rest = binary_part(content, byte_size(marker), byte_size(content) - byte_size(marker))

      if rest == "" or not name_char?(first_byte(rest)) do
        {:ok, rest}
      else
        :error
      end
    else
      :error
    end
  end

  defp closing_indent(line) do
    {indent, _} = take_while(line, fn c -> c == ?\s or c == ?\t end)
    indent
  end

  defp finalize_heredoc_body(lines, indent) do
    lines
    |> Enum.map(fn
      "" -> ""
      line -> if(indent == "", do: line, else: String.trim_leading(line, indent))
    end)
    |> Enum.join("\n")
  end

  # scan interpolation over a heredoc body (no terminating quote char)
  defp scan_interp_parts(<<>>, line, text, parts), do: {:ok, flush_text(text, parts), line}

  defp scan_interp_parts("\n" <> rest, line, text, parts),
    do: scan_interp_parts(rest, line + 1, ["\n" | text], parts)

  defp scan_interp_parts("\\" <> rest, line, text, parts) do
    case escape(rest, line, :heredoc) do
      {:ok, chunk, rest2, line2} -> scan_interp_parts(rest2, line2, [chunk | text], parts)
      e -> e
    end
  end

  defp scan_interp_parts(<<?$, c, rest::binary>>, line, text, parts) when name_start?(c) do
    {name, rest2} = take_name(c, rest)
    {accessors, rest3} = simple_accessor(rest2, line)
    scan_interp_parts(rest3, line, [], [{:simple, name, accessors} | flush_text(text, parts)])
  end

  defp scan_interp_parts("{$" <> rest, line, text, parts) do
    case tokenize_fragment("$" <> rest, line) do
      {:ok, toks, "}" <> rest2} ->
        scan_interp_parts(rest2, line, [], [{:complex, toks} | flush_text(text, parts)])

      {:ok, _, _} ->
        {:error, "unterminated interpolation", line}

      e ->
        e
    end
  end

  defp scan_interp_parts(<<c, rest::binary>>, line, text, parts),
    do: scan_interp_parts(rest, line, [<<c>> | text], parts)

  # ─────────────────────────── misc ───────────────────────────

  defp take_while(bin, pred) do
    split_at(bin, count_while(bin, pred))
  end

  defp count_while(<<c, rest::binary>>, pred) do
    if pred.(c), do: 1 + count_while(rest, pred), else: 0
  end

  defp count_while(<<>>, _pred), do: 0

  defp split_at(bin, n), do: {binary_part(bin, 0, n), binary_part(bin, n, byte_size(bin) - n)}

  defp count_nl(bin), do: length(:binary.matches(bin, "\n"))

  defp strip_one_newline("\r\n" <> rest), do: rest
  defp strip_one_newline("\n" <> rest), do: rest
  defp strip_one_newline(rest), do: rest
end
