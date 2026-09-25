defmodule PhpBeam.Classes do
  @moduledoc """
  Compatibility facade: the class table lives in `PhpBeam.Classes.Table`
  (ARCHITECTURE_DESIGN §2). In-repo callers keep using PhpBeam.Classes.*;
  new code may call Table directly. exception_info lives in PhpBeam.Objects.
  """

  defdelegate register(a, b), to: PhpBeam.Classes.Table
  defdelegate full_key_of(a, b), to: PhpBeam.Classes.Table
  defdelegate get_class(a, b), to: PhpBeam.Classes.Table
  defdelegate prop_declarer(a, b, c), to: PhpBeam.Classes.Table
  defdelegate self_and_ancestors(a, b), to: PhpBeam.Classes.Table
  defdelegate find_method(a, b, c), to: PhpBeam.Classes.Table
  defdelegate find_prop(a, b, c), to: PhpBeam.Classes.Table
  defdelegate find_const(a, b, c), to: PhpBeam.Classes.Table
  defdelegate find_const_lazy(a, b, c), to: PhpBeam.Classes.Table
  defdelegate is_a?(a, b, c), to: PhpBeam.Classes.Table
  defdelegate native_classes, to: PhpBeam.Classes.Table
  defdelegate exception_info(a, b), to: PhpBeam.Classes.Table
end
