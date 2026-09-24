defmodule PhpBeam.Env do
  @moduledoc """
  Evaluation scope. Function bodies get a fresh scope; `global $x` binds a
  local name to the interpreter's global table; `static` variables persist in
  the interpreter keyed by `statics_key`.
  """

  defstruct vars: %{},
            globalized: MapSet.new(),
            statics_key: nil,
            statics: %{},
            this: nil,
            function: nil,
            called_class: nil,
            scope_class: nil,
            closure_captures: %{},
            args: []

  @type t :: %__MODULE__{}

  def global_scope(_argv) do
    %__MODULE__{function: nil}
  end

  def function_scope(name, statics_key) do
    %__MODULE__{function: name, statics_key: statics_key}
  end

  # ───────────────────────── variable access ─────────────────────────

  @superglobals ~w(GLOBALS _SERVER _GET _POST _COOKIE _FILES _REQUEST _ENV _SESSION argv argc)

  def superglobal?(name), do: name in @superglobals

  # defensive: nil/foreign env (unwind convention leaks) behaves as undefined
  def lookup(env, _interp, _name) when not is_map(env), do: :undefined

  def lookup(%__MODULE__{} = env, interp, name) do
    cond do
      name == "this" ->
        case env.this do
          nil -> :undefined
          obj -> {:ok, obj}
        end

      true ->
        lookup_scope(env, interp, name)
    end
  end

  defp lookup_scope(env, interp, name) do
    cond do
      env.function == nil or superglobal?(name) ->
        global_fetch(interp, name)

      MapSet.member?(env.globalized, name) ->
        global_fetch(interp, name)

      Map.has_key?(env.statics, name) ->
        {:static, env.statics_key, name}

      true ->
        case Map.fetch(env.vars, name) do
          {:ok, v} ->
            {:ok, v}

          :error ->
            case Map.fetch(env.closure_captures, name) do
              {:ok, v} -> {:ok, v}
              :error -> :undefined
            end
        end
    end
  end

  defp global_fetch(interp, name) do
    case Map.fetch(interp.globals, name) do
      {:ok, v} -> {:ok, v}
      :error -> :undefined
    end
  end

  def bind_var(%__MODULE__{} = env, interp, name, value) do
    cond do
      env.function == nil or superglobal?(name) ->
        {:ok, env, %{interp | globals: Map.put(interp.globals, name, value)}}

      MapSet.member?(env.globalized, name) ->
        {:ok, env, %{interp | globals: Map.put(interp.globals, name, value)}}

      true ->
        {:ok, %{env | vars: Map.put(env.vars, name, value)}, interp}
    end
  end

  def bind_static(%__MODULE__{} = env, name, statics_key) do
    %{env | statics: Map.put(env.statics, name, statics_key)}
  end

  def globalize(%__MODULE__{} = env, name) do
    %{env | globalized: MapSet.put(env.globalized, name)}
  end

  def unset_var(%__MODULE__{} = env, interp, name) do
    cond do
      env.function == nil or superglobal?(name) ->
        {:ok, env, %{interp | globals: Map.delete(interp.globals, name)}}

      MapSet.member?(env.globalized, name) ->
        {:ok, env, %{interp | globals: Map.delete(interp.globals, name)}}

      true ->
        {:ok, %{env | vars: Map.delete(env.vars, name)}, interp}
    end
  end
end
