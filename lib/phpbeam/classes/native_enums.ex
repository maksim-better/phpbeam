defmodule PhpBeam.Classes.NativeEnums do
  @moduledoc """
  Native (engine-provided) enums. Currently RoundingMode (php 8.4, consumed
  by bcround/round): a PURE enum — 8 cases, no backing values. Case
  singletons are materialized into the objects registry at interpreter boot
  (declaration-ordered, matching `EnumX::cases()`).
  """

  alias PhpBeam.Eval
  alias PhpBeam.PArray
  alias PhpBeam.Classes.Table

  # declaration order = cases() order (php reflection-verified)
  @rounding_modes ~w(HalfAwayFromZero HalfTowardsZero HalfEven HalfOdd TowardsZero AwayFromZero NegativeInfinity PositiveInfinity)

  def rounding_mode_cases, do: @rounding_modes

  def classes do
    %{
      "roundingmode" =>
        struct!(Table,
          name: "RoundingMode",
          kind: :enum,
          parent: nil,
          interfaces: [],
          consts: %{},
          props: [],
          # pure enums expose only cases() — from()/tryFrom() belong to
          # backed enums (php: undefined method on RoundingMode)
          methods: %{
            "cases" => static_native("cases")
          },
          enum_cases: [],
          final?: true,
          backed?: false,
          file: ""
        )
    }
  end

  @doc """
  Materialize case singletons LAZILY on first enum access (php does the
  same — an untouched enum consumes no object ids, so var_dump #N counters
  stay differential-identical). Idempotent; per-request (fork-safe).
  """
  def materialize_lazy(interp, key) do
    case Map.get(interp.classes, key) do
      %Table{kind: :enum, enum_cases: []} -> materialize(interp, key)
      _ -> interp
    end
  end

  def materialize(interp, key \\ "roundingmode") do
    {pairs, interp2} =
      Enum.map_reduce(@rounding_modes, interp, fn name, acc ->
        {ref, a} = Eval.make_instance(acc, key)
        obj = Eval.get_object(a, ref)

        props =
          case PArray.put(obj.props, {:string, "name"}, {:string, name}) do
            {:ok, p} -> p
            _ -> obj.props
          end

        a2 = Eval.put_object(a, ref, %{obj | props: props})
        {{name, ref}, a2}
      end)

    case Map.get(interp2.classes, key) do
      %Table{} = c ->
        %{interp2 | classes: Map.put(interp2.classes, key, %{c | enum_cases: pairs})}

      _ ->
        interp2
    end
  end

  defp static_native(name) do
    run = fn vals, i ->
      class = Map.get(i.classes, "roundingmode") || %{}
      cases = Map.get(class, :enum_cases, [])

      case name do
        "cases" ->
          cases =
            if cases == [] do
              i2 = materialize(i, "roundingmode")
              Map.get(i2.classes, "roundingmode") |> Kernel.||(%{}) |> Map.get(:enum_cases, [])
            else
              cases
            end

          arr = PArray.from_pairs(Enum.map(cases, &{nil, elem(&1, 1)}))
          {:ok, {{:array, arr}, nil}, i}

      end
    end

    %{
      name: name,
      visibility: :public,
      static?: true,
      abstract?: false,
      final?: true,
      params: [],
      body: [],
      class: "roundingmode",
      line: nil,
      gen?: false,
      native: {:native, fn _obj, vals, i -> run.(vals, i) end}
    }
  end
end
