defmodule PhpBeam.Builtin do
  @moduledoc """
  Builtin function registry. Each builtin is `%{fun: fun(vals, interp, ctx), refs: []}`
  where `fun` returns `{:ok, v, interp}` (or `{:ref_call, v, vals', interp}` for
  functions that mutate by-reference arguments).
  """

  alias PhpBeam.Builtin.{
    ArrayFns,
    CursorFns,
    FileFns,
    MathFns,
    MiscFns,
    MysqliFns,
    ObFns,
    OutputFns,
    PatternFns,
    RuntimeFns,
    SerializeFns,
    StreamFns,
    StringFns,
    VarFns
  }

  alias PhpBeam.{PArray, Render, Value}

  def registry do
    %{}
    |> StringFns.register()
    |> MathFns.register()
    |> ArrayFns.register()
    |> VarFns.register()
    |> RuntimeFns.register()
    |> FileFns.register()
    |> MiscFns.register()
    |> MysqliFns.register()
    |> StreamFns.register()
    |> PatternFns.register()
    |> SerializeFns.register()
    |> CursorFns.register()
    |> ObFns.register()
    |> OutputFns.register()
    |> put_param_names()
  end

  # php arginfo parameter names (php 8.4, ReflectionFunction-verified) for
  # builtins that real code calls with named arguments; entries without
  # metadata fall back to positional binding when names appear
  @param_names %{
    "str_replace" => ["search", "replace", "subject", "count"],
    "str_ireplace" => ["search", "replace", "subject", "count"],
    "implode" => ["separator", "array"],
    "explode" => ["separator", "string", "limit"],
    "substr" => ["string", "offset", "length"],
    "str_pad" => ["string", "length", "pad_string", "pad_type"],
    "str_repeat" => ["string", "times"],
    "trim" => ["string", "characters"],
    "ltrim" => ["string", "characters"],
    "rtrim" => ["string", "characters"],
    "strtolower" => ["string"],
    "strtoupper" => ["string"],
    "ucfirst" => ["string"],
    "lcfirst" => ["string"],
    "htmlspecialchars" => ["string", "flags", "encoding", "double_encode"],
    "number_format" => ["num", "decimals", "decimal_separator", "thousands_separator"],
    "in_array" => ["needle", "haystack", "strict"],
    "array_slice" => ["array", "offset", "length", "preserve_keys"],
    "array_merge" => ["arrays"],
    "array_key_exists" => ["key", "array"],
    "array_keys" => ["array", "filter_value", "strict"],
    "array_values" => ["array"],
    "count" => ["value", "mode"],
    "http_build_query" => ["data", "numeric_prefix", "arg_separator", "encoding_type"],
    "setcookie" => ["name", "value", "expires_or_options", "path", "domain", "secure", "httponly"],
    "sprintf" => ["format", "values"],
    "printf" => ["format", "values"]
  }

  defp put_param_names(fns) do
    Map.new(fns, fn {k, v} ->
      case Map.get(@param_names, k) do
        nil -> {k, v}
        names -> {k, Map.put(v, :params, names)}
      end
    end)
  end
end
