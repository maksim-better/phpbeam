defmodule PhpBeam.Classes do
  @moduledoc """
  Compatibility facade: the class table lives in `PhpBeam.Classes.Table`
  (ARCHITECTURE_DESIGN §2). In-repo callers keep using PhpBeam.Classes.*;
  new code may call Table directly. exception_info lives in PhpBeam.Objects.
  """

  defdelegate register(_a, _b), to: PhpBeam.Classes.Table
  defdelegate full_key_of(_a, _b), to: PhpBeam.Classes.Table
  defdelegate get_class(_a, _b), to: PhpBeam.Classes.Table
  defdelegate prop_declarer(_a, _b, _c), to: PhpBeam.Classes.Table
  defdelegate self_and_ancestors(_a, _b), to: PhpBeam.Classes.Table
  defdelegate find_method(_a, _b, _c), to: PhpBeam.Classes.Table
  defdelegate find_prop(_a, _b, _c), to: PhpBeam.Classes.Table
  defdelegate find_const(_a, _b, _c), to: PhpBeam.Classes.Table
  defdelegate find_const_lazy(_a, _b, _c), to: PhpBeam.Classes.Table
  defdelegate is_a?(_a, _b, _c), to: PhpBeam.Classes.Table
  defdelegate native_classes, to: PhpBeam.Classes.Table
  defdelegate exception_info(_a, _b), to: PhpBeam.Classes.Table
end
