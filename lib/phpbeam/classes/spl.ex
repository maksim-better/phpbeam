defmodule PhpBeam.Classes.Spl do
  @moduledoc """
  PHASE B5: the SPL class family. ArrayObject/ArrayIterator (the Laravel
  collections substrate), the SplDoublyLinkedList base with Stack/Queue,
  Heap family (compare via user-land override), SplFixedArray,
  SplObjectStorage, SplFileInfo family, Observer/Subject interfaces.

  Storage rides `dt_state["arr"]` (PArray) + per-object cursor for the
  Iterator protocol; foreach drives native rewind/valid/current/key/next
  through the H0 protocol machinery (classes declare the Iterator/
  IteratorAggregate/ArrayAccess/Countable interfaces so is_a? grants
  protocol dispatch).
  """

  alias PhpBeam.{Eval, Objects, PArray, Value}
  alias PhpBeam.Classes.Table

  def classes do
    %{
      "arrayobject" => array_object_class(),
      "arrayiterator" => array_iterator_class(),
      "spldoublylinkedlist" => dll_class("SplDoublyLinkedList", :none),
      "splstack" => dll_class("SplStack", :lifo),
      "splqueue" => dll_class("SplQueue", :fifo),
      "splheap" => heap_class("SplHeap", :minmax_user),
      "splminheap" => heap_class("SplMinHeap", :min),
      "splmaxheap" => heap_class("SplMaxHeap", :max),
      "splpriorityqueue" => pq_class(),
      "splfixedarray" => fixed_array_class(),
      "splobjectstorage" => object_storage_class(),
      "splfileinfo" => file_info_class("SplFileInfo"),
      "splfileobject" => file_info_class("SplFileObject"),
      "spltempfileobject" => file_info_class("SplTempFileObject"),
      "splobserver" => iface("SplObserver", ["update"]),
      "splsubject" => iface("SplSubject", ["attach", "detach", "notify"])
    }
  end

  ## ───────────────── helpers ─────────────────

  def st(obj), do: Map.get(obj, :dt_state) || %{}
  defp st_put(obj, k, v), do: Map.put(obj, :dt_state, Map.put(st(obj), k, v))

  defp nfn(name, fun) do
    %{
      name: name,
      visibility: :public,
      static?: false,
      abstract?: false,
      final?: false,
      params: [],
      body: [],
      class: nil,
      native: {:native, fun}
    }
  end

  defp shell(name, kind, methods, ifaces) do
    struct(Table,
      name: name,
      kind: kind,
      parent: nil,
      interfaces: ifaces,
      consts: %{},
      props: [],
      methods: methods,
      file: ""
    )
  end

  defp iface(name, method_names) do
    methods =
      Map.new(method_names, fn mn ->
        {String.downcase(mn),
         %{
           name: mn,
           visibility: :public,
           static?: false,
           abstract?: true,
           final?: false,
           params: [],
           body: [],
           class: nil,
           line: 1,
           gen?: false,
           native: nil
         }}
      end)

    shell(name, :interface, methods, [])
  end

  defp dt_s({:string, s}), do: s
  defp dt_s(v), do: Eval.php_to_string(v)

  defp get_arr(obj), do: Map.get(st(obj), "arr") || PArray.new()

  defp get_arr_of({:array, a}), do: a
  defp get_arr_of(%PhpBeam.PArray{} = a), do: a
  defp get_arr_of(_), do: PhpBeam.PArray.new()

  defp arr_pairs({:array, a}, _i), do: PArray.to_pairs(a)

  defp wrap_arr(a), do: {:array, a}

  defp put_obj(i, oref, obj2), do: Objects.put_object(i, oref, obj2)

  ## ───────────────── ArrayObject ─────────────────

  defp array_object_class do
    methods =
      Map.new(
        array_common_methods("arr") ++
          [
            nfn("getiterator", fn obj, _a, i ->
              {iref, i2} = Eval.make_instance(i, "arrayiterator")
              io = Eval.get_object(i2, iref)
              io2 = st_put(io, "arr", get_arr(obj))
              i3 = put_obj(i2, iref, io2)
              {:ok, {iref, obj}, i3}
            end),
            nfn("exchangearray", fn obj, a, i ->
              case a do
                [{:array, _} = arr_v | _] ->
                  obj2 = st_put(obj, "arr", get_arr_of(arr_v))
                  {:ok, {{:array, get_arr(obj)}, obj2}, i}

                _ ->
                  {:ok, {:null, obj}, i}
              end
            end),
            nfn("setiteratorclass", fn obj, _a, i -> {:ok, {:null, obj}, i} end),
            nfn("getiteratorclass", fn obj, _a, i ->
              {:ok, {{:string, "ArrayIterator"}, obj}, i}
            end),
            nfn("asort", fn obj, _a, i -> sort_st(obj, i, :asc, true) end),
            nfn("ksort", fn obj, _a, i -> sort_keys(obj, i, :asc) end),
            nfn("uasort", fn obj, _a, i -> sort_st(obj, i, :asc, true) end),
            nfn("uksort", fn obj, _a, i -> sort_keys(obj, i, :asc) end),
            nfn("natsort", fn obj, _a, i -> {:ok, {{:bool, true}, obj}, i} end),
            nfn("serialize", fn obj, _a, i -> {:ok, {{:string, ""}, obj}, i} end)
          ],
        fn m -> {String.downcase(m.name), m} end
      )

    shell("ArrayObject", :class, methods, [
      "iteratoraggregate",
      "traversable",
      "arrayaccess",
      "serializable",
      "countable"
    ])
  end

  # shared offsetX/count/iterator methods for ArrayObject & ArrayIterator
  defp array_common_methods(_state_key) do
    [
      nfn("__construct", fn obj, args, i ->
        arr =
          case args do
            [{:array, a} | _] -> get_arr_of(a)
            _ -> PArray.new()
          end

        {:ok, {:null, st_put(obj, "arr", arr) |> st_put("cur", 0)}, i}
      end),
      nfn("offsetget", fn obj, a, i ->
        case a do
          [k | _] ->
            case PArray.fetch(get_arr(obj), k) do
              {:ok, v} -> {:ok, {v, obj}, i}
              _ -> {:ok, {:null, obj}, i}
            end

          _ ->
            {:ok, {:null, obj}, i}
        end
      end),
      nfn("offsetset", fn obj, a, i -> offset_set(obj, a, i) end),
      nfn("offsetexists", fn obj, a, i ->
        case a do
          [k | _] ->
            found = PArray.fetch(get_arr(obj), k) != :error
            {:ok, {{:bool, found}, obj}, i}

          _ ->
            {:ok, {{:bool, false}, obj}, i}
        end
      end),
      nfn("offsetunset", fn obj, a, i ->
        case a do
          [k | _] ->
            case PArray.delete(get_arr(obj), k) do
              {:ok, arr2} -> {:ok, {:null, st_put(obj, "arr", arr2)}, i}
              _ -> {:ok, {:null, obj}, i}
            end

          _ ->
            {:ok, {:null, obj}, i}
        end
      end),
      nfn("count", fn obj, _a, i ->
        {:ok, {{:int, PArray.size(get_arr(obj))}, obj}, i}
      end),
      nfn("getarraycopy", fn obj, _a, i ->
        {:ok, {{:array, get_arr(obj)}, obj}, i}
      end),
      nfn("append", fn obj, a, i ->
        case a do
          [v | _] ->
            arr2 = PArray.push(get_arr(obj), v)
            {:ok, {:null, st_put(obj, "arr", arr2)}, i}

          _ ->
            {:ok, {:null, obj}, i}
        end
      end),
      nfn("rewind", fn obj, _a, i ->
        {:ok, {:null, st_put(obj, "cur", 0)}, i}
      end),
      nfn("valid", fn obj, _a, i ->
        pairs = PArray.to_pairs(get_arr(obj))
        cur = Map.get(st(obj), "cur", 0)
        {:ok, {{:bool, cur < length(pairs)}, obj}, i}
      end),
      nfn("current", fn obj, _a, i ->
        pairs = PArray.to_pairs(get_arr(obj))
        cur = Map.get(st(obj), "cur", 0)
        v = if cur < length(pairs), do: pairs |> Enum.at(cur) |> elem(1), else: :null
        {:ok, {v, obj}, i}
      end),
      nfn("key", fn obj, _a, i ->
        pairs = PArray.to_pairs(get_arr(obj))
        cur = Map.get(st(obj), "cur", 0)
        v = if cur < length(pairs), do: key_val(pairs |> Enum.at(cur) |> elem(0)), else: :null
        {:ok, {v, obj}, i}
      end),
      nfn("next", fn obj, _a, i ->
        {:ok, {:null, st_put(obj, "cur", Map.get(st(obj), "cur", 0) + 1)}, i}
      end),
      nfn("seek", fn obj, a, i ->
        case a do
          [{:int, p} | _] -> {:ok, {:null, st_put(obj, "cur", max(p, 0))}, i}
          _ -> {:ok, {:null, obj}, i}
        end
      end)
    ]
  end

  defp norm_key({:int, n}), do: n
  defp norm_key({:string, s}), do: s
  defp norm_key(v), do: v

  defp key_val(k) when is_integer(k), do: {:int, k}
  defp key_val(k) when is_binary(k), do: {:string, k}

  defp offset_get(obj, a, i) do
    case a do
      [k | _] ->
        case PArray.fetch(get_arr(obj), k) do
          {:ok, v} -> {:ok, {v, obj}, i}
          _ -> {:ok, {:null, obj}, i}
        end

      _ ->
        {:ok, {:null, obj}, i}
    end
  end

  defp offset_set(obj, a, i) do
    case a do
      [k, v | _] ->
        case PArray.put(get_arr(obj), k, v) do
          {:ok, arr2} -> {:ok, {:null, st_put(obj, "arr", arr2)}, i}
          _ -> {:ok, {:null, obj}, i}
        end

      [v | _] ->
        arr2 = PArray.push(get_arr(obj), v)
        {:ok, {:null, st_put(obj, "arr", arr2)}, i}

      _ ->
        {:ok, {:null, obj}, i}
    end
  end

  defp sort_st(obj, i, _dir, _keep) do
    pairs = PArray.to_pairs(get_arr(obj))

    sorted =
      Enum.sort_by(pairs, fn {_k, v} -> v end, fn x, y -> Value.compare(x, y) < 0 end)

    arr2 = PArray.from_pairs(sorted)
    {:ok, {{:bool, true}, st_put(obj, "arr", arr2)}, i}
  end

  defp sort_keys(obj, i, _dir) do
    pairs = PArray.to_pairs(get_arr(obj))

    sorted = Enum.sort_by(pairs, &elem(&1, 0))
    arr2 = PArray.from_pairs(sorted)
    {:ok, {{:bool, true}, st_put(obj, "arr", arr2)}, i}
  end

  ## ───────────────── ArrayIterator ─────────────────

  defp array_iterator_class do
    methods =
      Map.new(array_common_methods("arr") -- [], fn m ->
        {String.downcase(m.name), m}
      end)

    shell("ArrayIterator", :class, methods, [
      "iterator",
      "traversable",
      "arrayaccess",
      "serializable",
      "countable"
    ])
  end

  ## ───────────────── DLL / Stack / Queue ─────────────────

  # storage: list of values in PUSH order; stack pops the LAST (lifo),
  # queue dequeues the FIRST (fifo); plain DLL defaults to lifo
  defp dll_class(name, mode) do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, _a, i ->
            {:ok, {:null, st_put(obj, "arr", PArray.new()) |> st_put("cur", 0)}, i}
          end),
          nfn("push", fn obj, a, i -> dll_push(obj, a, i) end),
          nfn("unshift", fn obj, a, i ->
            case a do
              [v | _] ->
                # unshift prepends (stack top at the head after iteration mode)
                arr = get_arr(obj)
                pairs = [{nil, v} | PArray.to_pairs(arr)]
                {:ok, {:null, st_put(obj, "arr", PArray.from_pairs(pairs))}, i}

              _ ->
                {:ok, {:null, obj}, i}
            end
          end),
          nfn("pop", fn obj, _a, i -> dll_pop(obj, i, mode) end),
          nfn("shift", fn obj, _a, i -> dll_shift(obj, i) end),
          nfn("top", fn obj, _a, i -> dll_top(obj, i, mode) end),
          nfn("bottom", fn obj, _a, i -> dll_bottom(obj, i, mode) end),
          nfn("enqueue", fn obj, a, i -> dll_enqueue(obj, a, i, mode) end),
          nfn("dequeue", fn obj, _a, i -> dll_dequeue(obj, i, mode) end),
          nfn("count", fn obj, _a, i ->
            {:ok, {{:int, PArray.size(get_arr(obj))}, obj}, i}
          end),
          nfn("isempty", fn obj, _a, i ->
            {:ok, {{:bool, PArray.size(get_arr(obj)) == 0}, obj}, i}
          end),
          # Iterator protocol: php iterates stacks top→bottom, queues head→tail
          nfn("rewind", fn obj, _a, i ->
            {:ok, {:null, st_put(obj, "cur", 0)}, i}
          end),
          nfn("valid", fn obj, _a, i ->
            {:ok, {{:bool, Map.get(st(obj), "cur", 0) < PArray.size(get_arr(obj))}, obj}, i}
          end),
          nfn("current", fn obj, _a, i -> dll_at(obj, i, mode) end),
          nfn("key", fn obj, _a, i ->
            {:ok, {{:int, Map.get(st(obj), "cur", 0)}, obj}, i}
          end),
          nfn("next", fn obj, _a, i ->
            {:ok, {:null, st_put(obj, "cur", Map.get(st(obj), "cur", 0) + 1)}, i}
          end),
          nfn("offsetexists", fn obj, a, i ->
            case a do
              [{:int, idx} | _] ->
                {:ok, {{:bool, idx >= 0 and idx < PArray.size(get_arr(obj))}, obj}, i}

              _ ->
                {:ok, {{:bool, false}, obj}, i}
            end
          end),
          nfn("offsetset", fn obj, a, i -> dll_push(obj, a, i) end),
          nfn("offsetget", fn obj, a, i ->
            case a do
              [{:int, idx} | _] when idx >= 0 ->
                vals = dll_values(obj)
                v = if idx < length(vals), do: Enum.at(vals, idx), else: :null
                {:ok, {v, obj}, i}

              _ ->
                {:ok, {:null, obj}, i}
            end
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )

    shell(name, :class, methods, ["iterator", "arrayaccess", "countable"])
  end

  defp dll_push(obj, a, i) do
    case a do
      [v | _] ->
        arr2 = PArray.push(get_arr(obj), v)
        {:ok, {:null, st_put(obj, "arr", arr2)}, i}

      _ ->
        {:ok, {:null, obj}, i}
    end
  end

  defp dll_values(obj) do
    get_arr(obj) |> PArray.values()
  end

  defp dll_pop(obj, i, _mode) do
    case PArray.pop(get_arr(obj)) do
      {:ok, {_k, v}, arr2} ->
        {:ok, {v, st_put(obj, "arr", arr2)}, i}

      :error ->
        {r, i2} =
          Eval.materialize_native(
            {:native_error, "RuntimeException", "Can't pop from an empty datastructure"},
            i
          )

        {{:unwind, {:php_throw, r}}, nil, i2}
    end
  end

  defp dll_shift(obj, i) do
    case PArray.shift(get_arr(obj)) do
      {:ok, {_k, v}, arr2} ->
        {:ok, {v, st_put(obj, "arr", arr2)}, i}

      :error ->
        {r, i2} =
          Eval.materialize_native(
            {:native_error, "RuntimeException", "Can't shift from an empty datastructure"},
            i
          )

        {{:unwind, {:php_throw, r}}, nil, i2}
    end
  end

  defp dll_top(obj, i, _mode) do
    vals = dll_values(obj)

    case List.last(vals) do
      nil -> {:ok, {:null, obj}, i}
      v -> {:ok, {v, obj}, i}
    end
  end

  defp dll_bottom(obj, i, _mode) do
    case dll_values(obj) do
      [v | _] -> {:ok, {v, obj}, i}
      [] -> {:ok, {:null, obj}, i}
    end
  end

  # queue: enqueue = push (tail), dequeue = shift (head)
  defp dll_enqueue(obj, a, i, _mode), do: dll_push(obj, a, i)

  defp dll_dequeue(obj, i, :fifo), do: dll_shift(obj, i)
  defp dll_dequeue(obj, i, _), do: dll_shift(obj, i)

  defp dll_at(obj, i, mode) do
    vals = dll_values(obj)
    cur = Map.get(st(obj), "cur", 0)

    vals =
      case mode do
        :lifo -> Enum.reverse(vals)
        _ -> vals
      end

    v = if cur < length(vals), do: Enum.at(vals, cur), else: :null
    {:ok, {v, obj}, i}
  end

  ## ───────────────── Heap family ─────────────────

  defp heap_class(name, order) do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, _a, i ->
            {:ok, {:null, st_put(obj, "arr", PArray.new())}, i}
          end),
          nfn("insert", fn obj, a, i ->
            case a do
              [v | _] ->
                arr = get_arr(obj)
                arr2 = PArray.push(arr, v)
                {:ok, {{:bool, true}, st_put(obj, "arr", arr2)}, i}

              _ ->
                {:ok, {{:bool, false}, obj}, i}
            end
          end),
          nfn("extract", fn obj, _a, i ->
            vals = dll_values(obj)

            case heap_pick(vals, order, obj, i) do
              {v, rest} ->
                arr2 = PArray.from_pairs(Enum.map(rest, &{nil, &1}))
                {:ok, {v, st_put(obj, "arr", arr2)}, i}

              nil ->
                {r, i2} =
                  Eval.materialize_native(
                    {:native_error, "RuntimeException", "Can't extract from empty heap"},
                    i
                  )

                {{:unwind, {:php_throw, r}}, nil, i2}
            end
          end),
          nfn("top", fn obj, _a, i ->
            vals = dll_values(obj)

            case heap_pick(vals, order, obj, i) do
              {v, _} -> {:ok, {v, obj}, i}
              nil -> {:ok, {:null, obj}, i}
            end
          end),
          nfn("count", fn obj, _a, i ->
            {:ok, {{:int, PArray.size(get_arr(obj))}, obj}, i}
          end),
          nfn("isempty", fn obj, _a, i ->
            {:ok, {{:bool, PArray.size(get_arr(obj)) == 0}, obj}, i}
          end),
          nfn("rewind", fn obj, _a, i -> {:ok, {:null, obj}, i} end),
          nfn("valid", fn obj, _a, i ->
            {:ok, {{:bool, PArray.size(get_arr(obj)) > 0}, obj}, i}
          end),
          nfn("current", fn obj, _a, i ->
            vals = dll_values(obj)

            case heap_pick(vals, order, obj, i) do
              {v, _} -> {:ok, {v, obj}, i}
              nil -> {:ok, {:null, obj}, i}
            end
          end),
          nfn("key", fn obj, _a, i -> {:ok, {{:int, 0}, obj}, i} end),
          nfn("next", fn obj, _a, i ->
            # heap foreach consumes
            vals = dll_values(obj)

            case heap_pick(vals, order, obj, i) do
              {_, rest} ->
                arr2 = PArray.from_pairs(Enum.map(rest, &{nil, &1}))
                {:ok, {:null, st_put(obj, "arr", arr2)}, i}

              nil ->
                {:ok, {:null, obj}, i}
            end
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )

    shell(name, :class, methods, ["iterator", "countable"])
  end

  # order: :min (MinHeap), :max (MaxHeap), :minmax_user (base — delegate to
  # the user compare(); default min when unimplemented)
  defp heap_pick([], _order, _obj, _i), do: nil

  defp heap_pick(vals, order, obj, i) do
    case order do
      :min ->
        sorted = Enum.sort(vals, fn a, b -> Value.compare(a, b) < 0 end)
        {hd(sorted), tl(sorted)}

      :max ->
        sorted = Enum.sort(vals, fn a, b -> Value.compare(a, b) > 0 end)
        {hd(sorted), tl(sorted)}

      :minmax_user ->
        # user heap: call compare($a,$b) — must return >0 when $a < $b for
        # min-heaps; fall back to min semantics when not implemented
        case Table.find_method(i, obj.class, "compare") do
          nil ->
            heap_pick(vals, :min, obj, i)

          m ->
            sorted =
              Enum.sort(vals, fn a, b ->
                # compare(a,b) > 0 → a should come first (min-heap)
                case Eval.call_php_method({:object, obj.__ref__}, m, [a, b], nil, i) do
                  {{:val, v}, _, _} -> Value.compare(v, {:int, 0}) > 0
                  _ -> Value.compare(a, b) < 0
                end
              end)

            {hd(sorted), tl(sorted)}
        end
    end
  end

  ## ───────────────── SplPriorityQueue ─────────────────

  defp pq_class do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, _a, i ->
            {:ok, {:null, st_put(obj, "arr", PArray.new())}, i}
          end),
          nfn("insert", fn obj, a, i ->
            case a do
              [v, p | _] ->
                arr = get_arr(obj)
                arr2 = PArray.push(arr, {:array, PArray.from_pairs([{0, v}, {1, p}])})
                {:ok, {{:bool, true}, st_put(obj, "arr", arr2)}, i}

              _ ->
                {:ok, {{:bool, false}, obj}, i}
            end
          end),
          nfn("extract", fn obj, _a, i ->
            vals = dll_values(obj)

            best =
              Enum.max_by(vals, fn {:array, pair} ->
                case PArray.fetch(pair, {:int, 1}) do
                  {:ok, p} -> p
                  _ -> {:int, 0}
                end
              end)

            rest = List.delete(vals, best)

            arr2 = PArray.from_pairs(Enum.map(rest, &{nil, &1}))

            v =
              case best do
                {:array, pair} ->
                  case PArray.fetch(pair, {:int, 0}) do
                    {:ok, v} -> v
                    _ -> :null
                  end

                _ ->
                  :null
              end

            {:ok, {v, st_put(obj, "arr", arr2)}, i}
          end),
          nfn("count", fn obj, _a, i ->
            {:ok, {{:int, PArray.size(get_arr(obj))}, obj}, i}
          end),
          nfn("isempty", fn obj, _a, i ->
            {:ok, {{:bool, PArray.size(get_arr(obj)) == 0}, obj}, i}
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )

    shell("SplPriorityQueue", :class, methods, ["countable"])
  end

  ## ───────────────── SplFixedArray ─────────────────

  defp fixed_array_class do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, a, i ->
            n =
              case a do
                [{:int, n} | _] -> max(n, 0)
                _ -> 0
              end

            arr = PArray.from_pairs(Enum.map(0..(n - 1), fn idx -> {idx, :null} end))
            {:ok, {:null, st_put(obj, "arr", arr)}, i}
          end),
          nfn("getsize", fn obj, _a, i ->
            {:ok, {{:int, PArray.size(get_arr(obj))}, obj}, i}
          end),
          nfn("count", fn obj, _a, i ->
            {:ok, {{:int, PArray.size(get_arr(obj))}, obj}, i}
          end),
          nfn("setsize", fn obj, a, i ->
            case a do
              [{:int, n} | _] ->
                cur = PArray.size(get_arr(obj))

                pairs =
                  if n > cur do
                    PArray.to_pairs(get_arr(obj)) ++
                      Enum.map(cur..(n - 1), fn idx -> {idx, :null} end)
                  else
                    PArray.to_pairs(get_arr(obj)) |> Enum.take(max(n, 0))
                  end

                arr2 = PArray.from_pairs(pairs)
                {:ok, {:null, st_put(obj, "arr", arr2)}, i}

              _ ->
                {:ok, {:null, obj}, i}
            end
          end),
          nfn("offsetget", fn obj, a, i ->
            case a do
              [{:int, _} = k | _] ->
                case PArray.fetch(get_arr(obj), k) do
                  {:ok, v} -> {:ok, {v, obj}, i}
                  _ -> {:ok, {:null, obj}, i}
                end

              _ ->
                {:ok, {:null, obj}, i}
            end
          end),
          nfn("offsetset", fn obj, a, i ->
            case a do
              [{:int, idx}, v | _] when idx >= 0 ->
                if idx < PArray.size(get_arr(obj)) do
                  case PArray.put(get_arr(obj), {:int, idx}, v) do
                    {:ok, arr2} -> {:ok, {:null, st_put(obj, "arr", arr2)}, i}
                    _ -> {:ok, {:null, obj}, i}
                  end
                else
                  {r, i2} =
                    Eval.materialize_native(
                      {:native_error, "RuntimeException", "Index invalid or out of range"},
                      i
                    )

                  {{:unwind, {:php_throw, r}}, nil, i2}
                end

              _ ->
                {r, i2} =
                  Eval.materialize_native(
                    {:native_error, "RuntimeException", "Index invalid or out of range"},
                    i
                  )

                {{:unwind, {:php_throw, r}}, nil, i2}
            end
          end),
          nfn("offsetexists", fn obj, a, i ->
            case a do
              [{:int, idx} | _] ->
                {:ok, {{:bool, idx >= 0 and idx < PArray.size(get_arr(obj))}, obj}, i}

              _ ->
                {:ok, {{:bool, false}, obj}, i}
            end
          end),
          nfn("offsetset", fn obj, a, i -> dll_push(obj, a, i) end),
          nfn("offsetget", fn obj, a, i ->
            case a do
              [{:int, idx} | _] when idx >= 0 ->
                vals = dll_values(obj)
                v = if idx < length(vals), do: Enum.at(vals, idx), else: :null
                {:ok, {v, obj}, i}

              _ ->
                {:ok, {:null, obj}, i}
            end
          end),
          nfn("toarray", fn obj, _a, i ->
            {:ok, {wrap_arr(get_arr(obj)), obj}, i}
          end),
          nfn("rewind", fn obj, _a, i -> {:ok, {:null, st_put(obj, "cur", 0)}, i} end),
          nfn("valid", fn obj, _a, i ->
            {:ok, {{:bool, Map.get(st(obj), "cur", 0) < PArray.size(get_arr(obj))}, obj}, i}
          end),
          nfn("current", fn obj, _a, i ->
            cur = Map.get(st(obj), "cur", 0)

            v =
              case PArray.fetch(get_arr(obj), cur) do
                {:ok, v} -> v
                _ -> :null
              end

            {:ok, {v, obj}, i}
          end),
          nfn("key", fn obj, _a, i ->
            {:ok, {{:int, Map.get(st(obj), "cur", 0)}, obj}, i}
          end),
          nfn("next", fn obj, _a, i ->
            {:ok, {:null, st_put(obj, "cur", Map.get(st(obj), "cur", 0) + 1)}, i}
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )

    shell("SplFixedArray", :class, methods, ["iterator", "arrayaccess", "countable"])
  end

  ## ───────────────── SplObjectStorage ─────────────────

  defp object_storage_class do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, _a, i ->
            {:ok, {:null, st_put(obj, "arr", PArray.new())}, i}
          end),
          nfn("attach", fn obj, a, i ->
            case a do
              [{:object, _} = oref, d | _] ->
                if contains_obj?(obj, oref) do
                  {:ok, {:null, obj}, i}
                else
                  arr2 =
                    PArray.push(get_arr(obj), {:array, PArray.from_pairs([{0, oref}, {1, d}])})

                  {:ok, {:null, st_put(obj, "arr", arr2)}, i}
                end

              [{:object, _} = oref | _] ->
                if contains_obj?(obj, oref) do
                  {:ok, {:null, obj}, i}
                else
                  arr2 =
                    PArray.push(
                      get_arr(obj),
                      {:array, PArray.from_pairs([{0, oref}, {1, :null}])}
                    )

                  {:ok, {:null, st_put(obj, "arr", arr2)}, i}
                end

              _ ->
                {:ok, {:null, obj}, i}
            end
          end),
          nfn("detach", fn obj, a, i ->
            case a do
              [{:object, _} = oref | _] ->
                keep =
                  Enum.reject(dll_values(obj), fn {:array, pair} ->
                    case PArray.fetch(pair, {:int, 0}) do
                      {:ok, ^oref} -> true
                      _ -> false
                    end
                  end)

                arr2 =
                  PArray.from_pairs(Enum.map(keep, fn {:array, pair} = v -> {nil, v} end))

                {:ok, {:null, st_put(obj, "arr", arr2)}, i}

              _ ->
                {:ok, {:null, obj}, i}
            end
          end),
          nfn("contains", fn obj, a, i ->
            case a do
              [{:object, _} = oref | _] ->
                {:ok, {{:bool, contains_obj?(obj, oref)}, obj}, i}

              _ ->
                {:ok, {{:bool, false}, obj}, i}
            end
          end),
          nfn("offsetget", fn obj, a, i ->
            case a do
              [{:object, _} = oref | _] ->
                found =
                  Enum.find_value(dll_values(obj), fn {:array, pair} ->
                    case PArray.fetch(pair, {:int, 0}) do
                      {:ok, ^oref} -> PArray.fetch(pair, {:int, 1}) |> elem(1)
                      _ -> nil
                    end
                  end)

                v = found || :null
                {:ok, {v, obj}, i}

              _ ->
                {:ok, {:null, obj}, i}
            end
          end),
          nfn("count", fn obj, _a, i ->
            {:ok, {{:int, PArray.size(get_arr(obj))}, obj}, i}
          end),
          nfn("setdata", fn obj, a, i ->
            case a do
              [{:object, _} = oref, d | _] ->
                pairs =
                  Enum.map(dll_values(obj), fn {:array, pair} ->
                    case PArray.fetch(pair, {:int, 0}) do
                      {:ok, ^oref} -> {nil, {:array, PArray.from_pairs([{0, oref}, {1, d}])}}
                      _ -> {nil, {:array, pair}}
                    end
                  end)

                {:ok, {:null, st_put(obj, "arr", PArray.from_pairs(pairs))}, i}

              _ ->
                {:ok, {:null, obj}, i}
            end
          end),
          nfn("getarraycopy", fn obj, _a, i ->
            arr =
              PArray.from_pairs(
                Enum.with_index(dll_values(obj), fn {:array, pair}, idx ->
                  {idx, pair}
                end)
              )

            {:ok, {{:array, arr}, obj}, i}
          end),
          nfn("rewind", fn obj, _a, i -> {:ok, {:null, st_put(obj, "cur", 0)}, i} end),
          nfn("valid", fn obj, _a, i ->
            {:ok, {{:bool, Map.get(st(obj), "cur", 0) < PArray.size(get_arr(obj))}, obj}, i}
          end),
          nfn("current", fn obj, _a, i ->
            cur = Map.get(st(obj), "cur", 0)
            vals = dll_values(obj)
            v = if cur < length(vals), do: elem(Enum.at(vals, cur), 1), else: :null

            # current() yields the stored OBJECT; the data via getInfo()
            v =
              case v do
                {:array, pair} ->
                  case PArray.fetch(pair, {:int, 0}) do
                    {:ok, oref} -> oref
                    _ -> :null
                  end

                _ ->
                  :null
              end

            {:ok, {v, obj}, i}
          end),
          nfn("key", fn obj, _a, i ->
            cur = Map.get(st(obj), "cur", 0)
            {:ok, {{:int, cur}, obj}, i}
          end),
          nfn("getinfo", fn obj, _a, i ->
            cur = Map.get(st(obj), "cur", 0)
            vals = dll_values(obj)

            v =
              if cur < length(vals) do
                case elem(Enum.at(vals, cur), 1) do
                  {:array, pair} ->
                    case PArray.fetch(pair, {:int, 1}) do
                      {:ok, d} -> d
                      _ -> :null
                    end

                  _ ->
                    :null
                end
              else
                :null
              end

            {:ok, {v, obj}, i}
          end),
          nfn("next", fn obj, _a, i ->
            {:ok, {:null, st_put(obj, "cur", Map.get(st(obj), "cur", 0) + 1)}, i}
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )

    shell("SplObjectStorage", :class, methods, ["iterator", "countable", "arrayaccess"])
  end

  defp contains_obj?(obj, oref) do
    Enum.any?(dll_values(obj), fn {:array, pair} ->
      PArray.fetch(pair, {:int, 0}) == {:ok, oref}
    end)
  end

  ## ───────────────── SplFileInfo family ─────────────────

  defp file_info_class(name) do
    methods =
      Map.new(
        [
          nfn("__construct", fn obj, a, i ->
            path = a |> Enum.at(0, {:string, ""}) |> dt_s()
            {:ok, {:null, st_put(obj, "path", path)}, i}
          end),
          nfn("getpath", fn obj, _a, i ->
            {:ok, {{:string, Path.dirname(st(obj)["path"] || "")}, obj}, i}
          end),
          nfn("getfilename", fn obj, _a, i ->
            {:ok, {{:string, Path.basename(st(obj)["path"] || "")}, obj}, i}
          end),
          nfn("getbasename", fn obj, a, i ->
            p = st(obj)["path"] || ""
            base = Path.basename(p)

            out =
              case a do
                [{:string, suffix} | _] ->
                  String.replace_suffix(base, suffix, "")

                _ ->
                  base
              end

            {:ok, {{:string, out}, obj}, i}
          end),
          nfn("getextension", fn obj, _a, i ->
            {:ok, {{:string, String.trim_leading(Path.extname(st(obj)["path"] || ""), ".")}, obj},
             i}
          end),
          nfn("getrealpath", fn obj, _a, i ->
            p = st(obj)["path"] || ""

            out =
              if File.exists?(p) do
                PhpBeam.Interp.real_path(p)
              else
                ""
              end

            {:ok, {{:string, out}, obj}, i}
          end),
          nfn("isfile", fn obj, _a, i ->
            {:ok, {{:bool, File.regular?(st(obj)["path"] || "")}, obj}, i}
          end),
          nfn("isdir", fn obj, _a, i ->
            {:ok, {{:bool, File.dir?(st(obj)["path"] || "")}, obj}, i}
          end),
          nfn("islink", fn obj, _a, i ->
            {:ok, {{:bool, File.symlink?(st(obj)["path"] || "")}, obj}, i}
          end),
          nfn("exists", fn obj, _a, i ->
            {:ok, {{:bool, File.exists?(st(obj)["path"] || "")}, obj}, i}
          end),
          nfn("getsize", fn obj, _a, i ->
            case File.stat(st(obj)["path"] || "") do
              {:ok, %{size: s}} -> {:ok, {{:int, s}, obj}, i}
              _ -> {:ok, {{:bool, false}, obj}, i}
            end
          end),
          nfn("getperms", fn obj, _a, i ->
            case File.stat(st(obj)["path"] || "") do
              {:ok, %{mode: m}} -> {:ok, {{:int, m}, obj}, i}
              _ -> {:ok, {{:bool, false}, obj}, i}
            end
          end),
          nfn("getmtime", fn obj, _a, i ->
            case File.stat(st(obj)["path"] || "") do
              {:ok, %{mtime: {{_, _, _}, _} = dt}} ->
                secs = :calendar.datetime_to_gregorian_seconds(dt) - 62_167_219_200
                {:ok, {{:int, secs}, obj}, i}

              {:ok, _} ->
                {:ok, {{:bool, false}, obj}, i}

              _ ->
                {:ok, {{:bool, false}, obj}, i}
            end
          end)
        ],
        fn m -> {String.downcase(m.name), m} end
      )

    shell(name, :class, methods, [])
  end
end
