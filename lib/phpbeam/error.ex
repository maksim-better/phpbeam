defmodule PhpBeam.Error do
  @moduledoc """
  PHP-level errors and (later) thrown values.

  `kind` mirrors the PHP error/exception taxonomy:
  `:warning` `:notice` `:deprecation` `:fatal` for engine errors, and
  `:type_error` `:division_by_zero_error` `:arithmetic_error` `:value_error`
  `:argument_count_error` `:error` for `Throwable`s the interpreter raises.
  """

  defstruct [:kind, :message, :file, :line]

  @type t :: %__MODULE__{}

  def warning(msg), do: %__MODULE__{kind: :warning, message: msg}
  def notice(msg), do: %__MODULE__{kind: :notice, message: msg}
  def fatal(msg), do: %__MODULE__{kind: :fatal, message: msg}

  def type_error(msg), do: %__MODULE__{kind: :type_error, message: msg}

  def division_by_zero(msg \\ "Division by zero"),
    do: %__MODULE__{kind: :division_by_zero_error, message: msg}

  def arithmetic_error(msg), do: %__MODULE__{kind: :arithmetic_error, message: msg}
  def value_error(msg), do: %__MODULE__{kind: :value_error, message: msg}

  def php_class(%__MODULE__{kind: kind}) do
    case kind do
      :type_error -> "TypeError"
      :division_by_zero_error -> "DivisionByZeroError"
      :arithmetic_error -> "ArithmeticError"
      :value_error -> "ValueError"
      :argument_count_error -> "ArgumentCountError"
      _ -> "Error"
    end
  end
end
