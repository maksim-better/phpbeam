defmodule PhpBeam.Objects do
  @moduledoc """
  Object registry authority. Handles are `{:object, id}`; the object maps
  (`%{__ref__, class, props, ...}`) live in `interp.objects`. Every
  construction/read/write of registry objects goes through here so that
  write-through (PHP reference semantics) has exactly one implementation.

  Dependency whitelist: Classes (table reads), PArray. One pre-existing
  upward edge: Eval.php_to_string in exception_info/2 (string conversion
  semantics live in Eval; Objects stays its consumer, not its owner).
  """

  alias PhpBeam.{Classes, PArray}

  # ───────────────────────── registry ops (from Eval) ─────────────────────────

  def make_instance(interp, key) do
    id = interp.next_obj
    obj = instantiate(interp, key, id)
    interp2 = %{interp | objects: Map.put(interp.objects, id, obj), next_obj: id + 1}
    {{:object, id}, interp2}
  end

  def get_object(interp, {:object, id}),
    do: Map.get(interp.objects, id, %{__ref__: id, class: "stdclass", props: PArray.new()})

  def get_object(_interp, other), do: other

  def put_object(interp, {:object, id}, obj_map) do
    %{interp | objects: Map.put(interp.objects, id, obj_map)}
  end

  def new_stdclass(interp, props) do
    id = interp.next_obj
    obj = %{__ref__: id, class: "stdclass", props: props, stdclass?: true}
    {{:object, id}, %{interp | objects: Map.put(interp.objects, id, obj), next_obj: id + 1}}
  end

  # ───────────────────────── instantiation (from Classes) ─────────────────────────

  # returns the object MAP (the {:object, id} handle wraps it in the registry)
  def instantiate(interp, key, obj_id) do
    defaults = instance_defaults(interp, key)
    %{__ref__: obj_id, class: key, props: PArray.from_pairs(defaults)}
  end

  defp instance_defaults(interp, key) do
    case Map.get(interp.classes, key) do
      nil ->
        []

      class ->
        ro_class? = "readonly" in (Map.get(class, :modifiers) || [])

        own =
          class.props
          # readonly props start UNINITIALIZED (defaults only reach them via
          # promoted ctor params) so presence in obj.props genuinely means
          # "initialized" — a readonly class makes every own prop readonly
          |> Enum.reject(fn p ->
            p.static? or match?(%{readonly?: true}, p) or ro_class?
          end)
          |> Enum.map(&{{:string, &1.display}, &1.default})

        own ++ instance_defaults(interp, class.parent)
    end
  end

  # ───────────────────────── exceptions (from Classes) ─────────────────────────

  def exception_info(interp, {:object, id}) do
    case Map.get(interp.objects, id) do
      nil ->
        {"Exception", ""}

      %{class: cls} = obj ->
        name =
          case Classes.get_class(interp, cls) do
            %{name: n} -> n
            _ -> cls
          end

        {name, PhpBeam.Eval.php_to_string(native_get(obj, "message"))}
    end
  end

  defp native_get(obj, name), do: PArray.get(obj.props, {:string, name}, :null)

  # ───────────────────────── type checks (from Classes) ─────────────────────────

  def instance_of?(interp, {:object, %{class: key}}, target_key),
    do: Classes.is_a?(interp, key, target_key)

  def instance_of?(_interp, _, _target_key), do: false
end
