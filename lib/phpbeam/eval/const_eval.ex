defmodule PhpBeam.Eval.ConstEval do
  @moduledoc """
  Compile-time constant evaluation: const_fold (static-expression folding),
  const_eval (class const entries), eval_const_expr, magic/builtin consts.
  Moved verbatim from Eval (P2c).
  """

  alias PhpBeam.Eval
  @int_min -9_223_372_036_854_775_808
  @int_max 9_223_372_036_854_775_807
  alias PhpBeam.{Env, Error, Interp, PArray, Pattern, Value}

  def const_eval_quiet(v, _env, _interp), do: eval_const_expr(v)

  def eval_const_expr({:int, n}), do: {:int, n}

  def eval_const_expr({:string, s}), do: {:string, s}

  # pure-text interpolated literal (the parser's normal string shape)
  def eval_const_expr({:interp, [text: s]}), do: {:string, s}
  def eval_const_expr({:interp, _}), do: :null

  def eval_const_expr({:bool, b}), do: {:bool, b}

  def eval_const_expr(:null), do: :null

  def eval_const_expr(_), do: :null

  # resolve a class-name AST to a storage key (downcased, no leading backslash)
  # class lookup with the registered spl autoloaders run on miss (php
  # triggers them for new/static calls/class_exists-with-autoload). Returns
  # {class_or_nil, interp} — the autoloaders' side effects (require files
  # registering classes) thread back.

  def const_fold(ast, interp), do: const_fold(ast, interp, nil)

  # folds in the declaring class's scope so self::CONST resolves; anything
  # that can't fold eagerly (forward refs, function calls) defers to the AST

  def const_fold(ast, interp, scope) do
    env = if scope, do: %Env{scope_class: scope, called_class: scope}, else: nil

    case Eval.eval(ast, env, interp) do
      {{:val, :null}, _, _} ->
        case ast do
          :null -> {:ok, :null}
          _ -> :defer
        end

      {{:val, v}, _, _} ->
        {:ok, v}

      _ ->
        :defer
    end
  rescue
    _ -> :defer
  end

  # lazy const-expr evaluation (deferred {:const_ast, ...} markers)

  def const_eval(ast, interp, decl_key) do
    env = %Env{scope_class: decl_key, called_class: decl_key}
    {ns0, uses0, i0} = push_class_scope(interp, decl_key)

    case Eval.eval(ast, env, i0) do
      {{:val, v}, _, i2} -> {v, pop_class_scope(i2, ns0, uses0)}
      {{:unwind, _}, _, i2} -> {:null, pop_class_scope(i2, ns0, uses0)}
    end
  end

  # php compiles each class with its declaring file's namespace + use
  # aliases; method/const evaluation runs under that scope

  def resolve_const(name, _fq, env, interp) do
    case magic_const(name, env, interp) do
      {:ok, _} = ok -> ok
      :error -> resolve_plain_const(name, interp)
    end
  end

  def resolve_plain_const(name, interp) do
    case Map.fetch(interp.consts, name) do
      {:ok, v} -> {:ok, v}
      :error -> builtin_const(name)
    end
  end

  # magic constants are case-insensitive and resolve per file (include)

  def magic_const(name, env, interp) do
    current =
      case interp.file_stack do
        [cur | _] -> cur
        [] -> "Command line code"
      end

    case String.upcase(name) do
      "__FILE__" -> {:ok, {:string, current}}
      "__DIR__" -> {:ok, {:string, Path.dirname(current)}}
      "__FUNCTION__" -> {:ok, {:string, env.function || ""}}
      "__LINE__" -> {:ok, {:int, interp.cur_line}}
      "__METHOD__" -> {:ok, {:string, method_name(env, interp)}}
      "__CLASS__" -> {:ok, {:string, class_name_of(env, interp)}}
      "__NAMESPACE__" -> {:ok, {:string, Enum.join(interp.ns, "\\")}}
      _ -> :error
    end
  end

  def builtin_const(name) do
    case name do
      "PHP_EOL" ->
        {:ok, {:string, "\n"}}

      "PHP_INT_MAX" ->
        {:ok, {:int, @int_max}}

      "PHP_INT_MIN" ->
        {:ok, {:int, @int_min}}

      "PHP_INT_SIZE" ->
        {:ok, {:int, 8}}

      "PHP_FLOAT_EPSILON" ->
        {:ok, {:float, :math.pow(2, -52)}}

      "PHP_FLOAT_MAX" ->
        {:ok, {:float, 1.7976931348623157e308}}

      "PHP_FLOAT_MIN" ->
        {:ok, {:float, 2.2250738585072014e-308}}

      "PHP_VERSION" ->
        {:ok, {:string, "8.4.2"}}

      "PHP_VERSION_ID" ->
        {:ok, {:int, 80_402}}

      "PHP_MAJOR_VERSION" ->
        {:ok, {:int, 8}}

      "PHP_MINOR_VERSION" ->
        {:ok, {:int, 4}}

      "PHP_RELEASE_VERSION" ->
        {:ok, {:int, 2}}

      "PHP_EXTRA_VERSION" ->
        {:ok, {:string, ""}}

      "PHP_ZTS" ->
        {:ok, {:bool, false}}

      "PHP_OS" ->
        {:ok, {:string, "Darwin"}}

      "PHP_FLOAT_DIG" ->
        {:ok, {:int, 15}}

      "PHP_MAXPATHLEN" ->
        {:ok, {:int, 1024}}

      "PHP_BINARY" ->
        {:ok, {:string, "/opt/homebrew/bin/php"}}

      "PHP_OS" ->
        {:ok, {:string, "Darwin"}}

      "PHP_OS_FAMILY" ->
        {:ok, {:string, "Darwin"}}

      "PHP_SAPI" ->
        {:ok, {:string, "cli"}}

      "PHP_DEBUG" ->
        {:ok, {:bool, false}}

      "PHP_WINDOWS_VERSION_MAJOR" ->
        {:ok, {:bool, false}}

      "M_PI" ->
        {:ok, {:float, :math.pi()}}

      "M_E" ->
        {:ok, {:float, :math.exp(1)}}

      "M_SQRT2" ->
        {:ok, {:float, :math.sqrt(2)}}

      "NAN" ->
        {:ok, {:float, :erlang.nan()}}

      "INF" ->
        {:ok,
         {:float, :erlang.float_to_binary(:erlang.list_to_float('1.0e308')) |> String.to_float()}}

      "E_ALL" ->
        {:ok, {:int, 32767}}

      "E_WARNING" ->
        {:ok, {:int, 2}}

      "E_NOTICE" ->
        {:ok, {:int, 8}}

      "PHP_ZTS" ->
        {:ok, {:bool, false}}
        SHOULD_NOT_EXIST

      "STR_PAD_LEFT" ->
        {:ok, {:int, 0}}

      "STR_PAD_RIGHT" ->
        {:ok, {:int, 1}}

      "STR_PAD_BOTH" ->
        {:ok, {:int, 2}}

      "SORT_REGULAR" ->
        {:ok, {:int, 0}}

      "SORT_NUMERIC" ->
        {:ok, {:int, 1}}

      "SORT_STRING" ->
        {:ok, {:int, 2}}

      "COUNT_RECURSIVE" ->
        {:ok, {:int, 1}}

      "JSON_HEX_TAG" ->
        {:ok, {:int, 1}}

      "JSON_HEX_AMP" ->
        {:ok, {:int, 2}}

      "JSON_HEX_APOS" ->
        {:ok, {:int, 4}}

      "JSON_HEX_QUOT" ->
        {:ok, {:int, 8}}

      "JSON_FORCE_OBJECT" ->
        {:ok, {:int, 16}}

      "JSON_UNESCAPED_SLASHES" ->
        {:ok, {:int, 64}}

      "JSON_PRETTY_PRINT" ->
        {:ok, {:int, 128}}

      "JSON_UNESCAPED_UNICODE" ->
        {:ok, {:int, 256}}

      "JSON_PARTIAL_OUTPUT_ON_ERROR" ->
        {:ok, {:int, 512}}

      "JSON_INVALID_UTF8_SUBSTITUTE" ->
        {:ok, {:int, 2_097_152}}

      "JSON_THROW_ON_ERROR" ->
        {:ok, {:int, 4_194_304}}

      "EXTR_OVERWRITE" ->
        {:ok, {:int, 0}}

      "PHP_DEBUG" ->
        {:ok, {:bool, false}}

      "TRUE" ->
        {:ok, {:bool, true}}

      "FALSE" ->
        {:ok, {:bool, false}}

      "NULL" ->
        {:ok, :null}

      # error-reporting bit mask (PHP 8 values)
      "E_ERROR" ->
        {:ok, {:int, 1}}

      "E_RECOVERABLE_ERROR" ->
        {:ok, {:int, 4096}}

      "E_PARSE" ->
        {:ok, {:int, 4}}

      "E_CORE_ERROR" ->
        {:ok, {:int, 16}}

      "E_CORE_WARNING" ->
        {:ok, {:int, 32}}

      "E_COMPILE_ERROR" ->
        {:ok, {:int, 64}}

      "E_COMPILE_WARNING" ->
        {:ok, {:int, 128}}

      "E_USER_ERROR" ->
        {:ok, {:int, 256}}

      "E_USER_WARNING" ->
        {:ok, {:int, 512}}

      "E_USER_NOTICE" ->
        {:ok, {:int, 1024}}

      "E_USER_DEPRECATED" ->
        {:ok, {:int, 16_384}}

      "E_DEPRECATED" ->
        {:ok, {:int, 8192}}

      "E_STRICT" ->
        {:ok, {:int, 2048}}

      # setlocale categories (darwin C library values)
      "LC_CTYPE" ->
        {:ok, {:int, 0}}

      "LC_NUMERIC" ->
        {:ok, {:int, 1}}

      "LC_TIME" ->
        {:ok, {:int, 2}}

      "LC_COLLATE" ->
        {:ok, {:int, 3}}

      "LC_MONETARY" ->
        {:ok, {:int, 4}}

      "LC_MESSAGES" ->
        {:ok, {:int, 5}}

      "LC_ALL" ->
        {:ok, {:int, 6}}

      "DIRECTORY_SEPARATOR" ->
        {:ok, {:string, "/"}}

      "PATH_SEPARATOR" ->
        {:ok, {:string, ":"}}

      "FILE_APPEND" ->
        {:ok, {:int, 8}}

      "FILE_USE_INCLUDE_PATH" ->
        {:ok, {:int, 1}}

      "LOCK_EX" ->
        {:ok, {:int, 2}}

      "PREG_PATTERN_ORDER" ->
        {:ok, {:int, 1}}

      "PREG_SET_ORDER" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_NO_EMPTY" ->
        {:ok, {:int, 1}}

      "PREG_SPLIT_DELIM_CAPTURE" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_OFFSET_CAPTURE" ->
        {:ok, {:int, 4}}

      "PREG_OFFSET_CAPTURE" ->
        {:ok, {:int, 256}}

      "PREG_UNMATCHED_AS_NULL" ->
        {:ok, {:int, 512}}

      "PREG_GREP_INVERT" ->
        {:ok, {:int, 1}}

      "PREG_NO_ERROR" ->
        {:ok, {:int, 0}}

      "PHP_URL_SCHEME" ->
        {:ok, {:int, 0}}

      "PHP_URL_HOST" ->
        {:ok, {:int, 1}}

      "PHP_URL_PORT" ->
        {:ok, {:int, 2}}

      "PHP_URL_USER" ->
        {:ok, {:int, 3}}

      "PHP_URL_PASS" ->
        {:ok, {:int, 4}}

      "PHP_URL_PATH" ->
        {:ok, {:int, 5}}

      "PHP_URL_QUERY" ->
        {:ok, {:int, 6}}

      "PHP_URL_FRAGMENT" ->
        {:ok, {:int, 7}}

      "PATHINFO_DIRNAME" ->
        {:ok, {:int, 1}}

      "PATHINFO_BASENAME" ->
        {:ok, {:int, 2}}

      "PATHINFO_EXTENSION" ->
        {:ok, {:int, 4}}

      "PATHINFO_FILENAME" ->
        {:ok, {:int, 3}}

      "FILE_IGNORE_NEW_LINES" ->
        {:ok, {:int, 2}}

      "FILE_SKIP_EMPTY_LINES" ->
        {:ok, {:int, 4}}

      "EXTR_OVERWRITE" ->
        {:ok, {:int, 0}}

      "EXTR_SKIP" ->
        {:ok, {:int, 1}}

      "EXTR_PREFIX_SAME" ->
        {:ok, {:int, 2}}

      "EXTR_IF_EXISTS" ->
        {:ok, {:int, 6}}

      "PHP_QUERY_RFC1738" ->
        {:ok, {:int, 1738}}

      "PHP_QUERY_RFC3986" ->
        {:ok, {:int, 3986}}

      "JSON_ERROR_NONE" ->
        {:ok, {:int, 0}}

      "STDIN" ->
        {:ok, {:resource, 0}}

      "STDOUT" ->
        {:ok, {:resource, 1}}

      "STDERR" ->
        {:ok, {:resource, 2}}

      "SEEK_SET" ->
        {:ok, {:int, 0}}

      "SEEK_CUR" ->
        {:ok, {:int, 1}}

      "SEEK_END" ->
        {:ok, {:int, 2}}

      "LOCK_SH" ->
        {:ok, {:int, 1}}

      "LOCK_UN" ->
        {:ok, {:int, 3}}

      "MYSQLI_REPORT_OFF" ->
        {:ok, {:int, 0}}

      "ENT_COMPAT" ->
        {:ok, {:int, 2}}

      "ENT_QUOTES" ->
        {:ok, {:int, 3}}

      "ENT_NOQUOTES" ->
        {:ok, {:int, 0}}

      "ENT_IGNORE" ->
        {:ok, {:int, 4}}

      "ENT_SUBSTITUTE" ->
        {:ok, {:int, 8}}

      "ENT_HTML401" ->
        {:ok, {:int, 0}}

      "ENT_HTML5" ->
        {:ok, {:int, 48}}

      "CASE_UPPER" ->
        {:ok, {:int, 1}}

      "CASE_LOWER" ->
        {:ok, {:int, 0}}

      "MYSQLI_CLIENT_SSL" ->
        {:ok, {:int, 2048}}

      "MYSQLI_CLIENT_COMPRESS" ->
        {:ok, {:int, 32}}

      "MYSQLI_OPT_SSL_VERIFY_SERVER_CERT" ->
        {:ok, {:int, 2048}}

      "MYSQLI_REPORT_ERROR" ->
        {:ok, {:int, 1}}

      "MYSQLI_REPORT_STRICT" ->
        {:ok, {:int, 2}}

      "MYSQLI_REPORT_INDEX" ->
        {:ok, {:int, 4}}

      "MYSQLI_REPORT_ALL" ->
        {:ok, {:int, 255}}

      "MYSQLI_ASSOC" ->
        {:ok, {:int, 1}}

      "MYSQLI_NUM" ->
        {:ok, {:int, 2}}

      "MYSQLI_BOTH" ->
        {:ok, {:int, 3}}

      "MYSQLI_CLIENT_COMPRESS" ->
        {:ok, {:int, 32}}

      "MYSQLI_OPT_INT_AND_FLOAT_NATIVE" ->
        {:ok, {:int, 205}}

      "DATE_W3C" ->
        {:ok, {:string, "Y-m-d\\TH:i:sP"}}

      "DATE_ATOM" ->
        {:ok, {:string, "Y-m-d\\TH:i:sP"}}

      "DATE_ISO8601" ->
        {:ok, {:string, "Y-m-d\\TH:i:sO"}}

      "DATE_RFC2822" ->
        {:ok, {:string, "D, d M Y H:i:s O"}}

      "PREG_PATTERN_ORDER" ->
        {:ok, {:int, 1}}

      "PREG_SET_ORDER" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_NO_EMPTY" ->
        {:ok, {:int, 1}}

      "PREG_SPLIT_DELIM_CAPTURE" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_OFFSET_CAPTURE" ->
        {:ok, {:int, 4}}

      "PREG_OFFSET_CAPTURE" ->
        {:ok, {:int, 256}}

      "PREG_UNMATCHED_AS_NULL" ->
        {:ok, {:int, 512}}

      "PREG_GREP_INVERT" ->
        {:ok, {:int, 1}}

      "PREG_NO_ERROR" ->
        {:ok, {:int, 0}}

      _ ->
        :error
    end
  end

  defp class_key_of(a, b, c), do: Eval.class_key_of(a, b, c)
  defp static_prop_name(a, b, c), do: Eval.static_prop_name(a, b, c)
  defp static_props_key(a), do: Eval.static_props_key(a)
  defp make_instance(a, b), do: Eval.make_instance(a, b)
  defp call_php_method(a, b, c, d, e), do: Eval.call_php_method(a, b, c, d, e)
  defp materialize_native(a, b), do: Eval.materialize_native(a, b)
  defp class_name_of(a, b), do: Eval.class_name_of(a, b)
  defp pop_class_scope(a, b, c), do: Eval.pop_class_scope(a, b, c)

  defp push_class_scope(a, b), do: Eval.push_class_scope(a, b)
  defp method_name(a, b), do: Eval.method_name(a, b)
end
