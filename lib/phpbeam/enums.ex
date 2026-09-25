defmodule PhpBeam.Enums do
  @moduledoc """
  PHP 8.1 enums. An enum registers as a sealed class whose `case`s are
  materialized singleton objects at declaration time (`name`/`value` props).
  Static `cases()`/`from()`/`tryFrom()` close over the enum's key; user
  methods run like class methods against the singleton instances.
  """

  alias PhpBeam.{Classes, Eval, PArray}

  def register(decl, interp) do
    key = Classes.full_key_of(decl.name, interp)

    if Map.has_key?(interp.classes, key) do
      {:ok, PhpBeam.Interp.warn(interp, "Cannot declare enum #{decl.name} twice")}
    else
      class = build(decl, key, interp)
      interp2 = %{interp | classes: Map.put(interp.classes, key, class)}

      {pairs, interp3} =
        Enum.map_reduce(decl.cases, interp2, fn {cname, cval}, i ->
          {{:object, _} = ref, i2} = Eval.make_instance(i, key)
          obj = Eval.get_object(i2, ref)

          props =
            case PArray.put(obj.props, {:string, "name"}, {:string, cname}) do
              {:ok, p2} -> p2
              _ -> obj.props
            end

          props =
            case cval do
              nil ->
                props

              v ->
                vv = Eval.const_fold(v, i2) |> elem(1)

                case PArray.put(props, {:string, "value"}, vv) do
                  {:ok, p3} -> p3
                  _ -> props
                end
            end

          i3 = Eval.put_object(i2, ref, %{obj | props: props})
          {{cname, ref}, i3}
        end)

      classes3 =
        Map.update!(interp3.classes, key, fn c -> %{c | enum_cases: pairs} end)

      {:ok, %{interp3 | classes: classes3}}
    end
  end

  defp build(decl, key, interp) do
    methods =
      %{}
      |> Map.put("cases", static_native("cases", key, nil))
      |> Map.put("from", static_native("from", key, :throw))
      |> Map.put("tryfrom", static_native("tryFrom", key, :null))

    user_methods =
      Map.new(decl.methods, fn {vis, st?, ab?, fi?, _br?, mname, params, body, _line} ->
        {String.downcase(mname),
         %{
           name: mname,
           visibility: vis,
           static?: st?,
           abstract?: ab?,
           final?: fi?,
           params: params,
           body: body,
           class: key,
           line: nil,
           gen?: PhpBeam.Ast.has_yield?(body),
           native: nil
         }}
      end)

    consts =
      Map.new(decl.consts, fn {cname, cexpr} ->
        case Eval.const_fold(cexpr, interp, key) do
          {:ok, v} -> {cname, v}
          :defer -> {cname, {:const_ast, cexpr, key}}
        end
      end)

    struct!(Classes, %{
      name: decl.name,
      kind: :enum,
      consts: consts,
      methods: Map.merge(user_methods, methods),
      enum_cases: [],
      final?: true,
      backed?: decl.backing != nil,
      ns: interp.ns,
      uses: interp.uses,
      file: Enum.at(interp.file_stack, 0, "")
    })
  end

  # cases/from/tryFrom close over the enum key: no context threading needed
  defp static_native(name, key, on_miss) do
    run = fn vals, i ->
      case name do
        "cases" ->
          pairs = Map.get(i.classes, key) |> Kernel.||(%{}) |> Map.get(:enum_cases, [])
          arr = PArray.from_pairs(Enum.map(pairs, &{nil, elem(&1, 1)}))
          {:ok, {{:array, arr}, nil}, i}

        _lookup ->
          want = Enum.at(vals, 0)
          display = key |> String.split("\\") |> Enum.map(&String.capitalize/1) |> Enum.join("\\")

          hit =
            Map.get(i.classes, key)
            |> Kernel.||(%{})
            |> Map.get(:enum_cases, [])
            |> Enum.find(fn {_n, ref} ->
              obj = Eval.get_object(i, ref)

              case PArray.fetch(obj.props, {:string, "value"}) do
                {:ok, v} -> v == want
                :error -> false
              end
            end)

          case hit do
            {_, ref} ->
              {:ok, {ref, nil}, i}

            nil when on_miss == :null ->
              {:ok, {:null, nil}, i}

            nil ->
              {:ok,
               {:unwind,
                {:php_throw,
                 {:native_error, "ValueError",
                  "#{display}::from(): '" <>
                    PhpBeam.Value.render(want) <>
                    "' is not a valid backing value for enum \"#{display}\""}}}, i}
          end
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
      class: key,
      line: nil,
      gen?: false,
      native: {:native, fn _obj, vals, i -> run.(vals, i) end}
    }
  end
end
