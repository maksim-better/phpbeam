# phpbeam 架构设计 v1（落地版）

**上游文档**：`ARCHITECTURE_REVIEW.md`（2026-09-25 评审）。本文件把评审结论细化为可直接开工的设计：模块清单、函数签名、数据形状、迁移力学、commit 级步骤与验收门禁。
**设计过程对 review 的三处修正**见 §1.1——精读代码后事实有更新，以本文件为准。

---

## 1. 硬约束（所有设计决策的边界）

1. **`{result, env, interp}` 三元组线程化**不变。表达式 `{{:val, v}, env, interp}`；语句 `:ok | {:unwind, signal} | {{:unwind, signal}, env, interp}`。
2. **unwind 携带最新 interp**穿透（statics/objects/ob 不得在异常路径丢失）。四元组 `{:unwind, u, env, interp}` 通道保留。
3. **分层只在模块级**：不引入 behaviour / Protocol / GenServer / 进程边界。语义核心保持纯函数。
4. **每个迁移 commit 独立可停**：差分 22 用例 byte 级一致 + phpt ≥ 基线（285/697）+ `mix test` 全绿；否则 revert 该 commit。
5. **纯移动优先**：抽模块的 commit 不改逻辑；逻辑变更（如 class_ref 替换）单独成 commit。
6. **热路径不加间接层**：类/方法查找、赋值路径的存储形状（map、9 元组）不动——分层加在"读视图"和"构造/判型"上，不动运行时表示。

## 1.1 对 review 的事实修正

| review 的说法 | 精读后的事实 | 设计影响 |
|---|---|---|
| 对象双表示 = 句柄 vs 全 map `%{props:...}` | `{:object, %{props:...}}` 全库**零构造点**（builtin.ex:390 是死代码，删即可）。真实的第二形态是 `{:object, %{class: key}}`——PHP 8.4 `Foo::class` 的 ClassName 占位符（3 处消费：eval.ex:3691、classes.ex:831、builtin/var.ex:231） | N3 缩小为：一个死分支 + 一个未命名占位符形状。修法见 §3.4 |
| 回调协议需要"新建" env 通道 | 注册表调用点 `fun.(vals, interp, %{env: env})` **已传 env**（eval.ex `call_resolved_builtin`）；builtin 也已直接调用 `Eval.call_cb/put_object/get_object/make_ref` 等公开函数 | 协议不是新建，是**把既成事实正式化**：两个关口函数 + 注册表 `ho:` 能力位（§3.1） |
| `dispatch_ho` 约 40 个函数 | 实际 **23 个**（usort/uasort/uksort/preg_match/preg_match_all/preg_replace_callback/array_any/array_all/parse_str 为 raw-AST 档；call_user_func(_array)/array_map/array_filter/array_reduce/array_walk/eval/func_get_args/func_get_arg/func_num_args/compact/extract/exit/die 为已求值档），由 `higher_order/4` 的**硬编码名单**前置分派 | 迁移规模更小；两档模式直接成为 `ho:` 的 `args:` 取值（§3.1） |
| Phase 3 物理拆分 `Interp.State` 为 Boot/Request 两个子 struct | 物理拆分要改全部 `interp.classes` 等直摸点（50+ 处），功能零收益 | 改为**逻辑归属表 + `fork_request/1`**（§3.5），物理拆分留待编译后端真需要时再议 |

---

## 2. 目标模块总表

命名遵循现有惯例：语义核心用嵌套命名空间（`lib/phpbeam/classes/table.ex` → `PhpBeam.Classes.Table`），stdlib 保持 `Builtin.XxxFns` 平铺。**"允许依赖"= 该模块 import/全名引用的白名单，写入各模块 moduledoc，越层即 bug。**

| 模块 | 文件 | 行数预算（现值） | 职责 | 允许依赖 |
|---|---|---|---|---|
| `Lexer` / `Token` / `Parser` / `Ast` | 现状 | 不限（2421） | 前端。**不动** | 同现状 |
| `Value` | 现状 | 973 | 标量语义/juggling/比较 | PArray, Error |
| `PArray` | 现状 | 344 | 有序数组 + 游标 | Value |
| `Env` | 现状 | 116 | 作用域/变量表/args 快照 | Value |
| `Error` | 现状 | 37 | PHP 错误值 | — |
| `Pattern` | 现状 | 281 | PCRE 封装 | PArray |
| **`Objects`** ★新 | `lib/phpbeam/objects.ex` | ~250（从 eval/classes 抽） | 对象注册表唯一权威：get/put/make/new_stdclass/instantiate/instance_of?/exception_info；`class_ref` 占位符构造与判型 | Classes.Table, Interp(只读形状), PArray |
| **`Closure`** ★新 | `lib/phpbeam/closure.ex` | ~80 | 闭包双形状唯一权威：`runtime/7`、`ast?/1`、`runtime?/1`、取 params/captures | — |
| `Classes.Table` ★拆 | `lib/phpbeam/classes/table.ex` | ~1000（classes.ex 1452 减 instantiate/exception_info） | 类表 + 链接检查 + 名字解析（resolve_class_*）+ **元数据只读 API** | Value, PArray, Interp |
| `Enums` | 现状 | 162 | 枚举注册（消费 Table.register） | Classes.Table, Interp |
| `Interp` | 现状 | ~1300 | 语句执行 exec_stmt/stmts + 驱动（run/run_http/repl）+ 状态访问器（warn/write/push_frame/sapi_*）+ **fork_request** | Eval, Classes.Table, Objects, Builtin, Render |
| **`Eval`** 瘦身 | `lib/phpbeam/eval.ex` | ≤2000（4942） | 表达式分派 eval/3、运算、字符串转换（php_to_string 族）、include、fetch_class（autoload 触发）；对 Assign/Call/Generator 做 façade defdelegate | 全语义层 + Interp |
| **`Eval.Assign`** ★新 | `lib/phpbeam/eval/assign.ex` | ~700 | lvalue 机器：assign/4 全型、lvalue_path、path_write、unset_target、read_target、isset?、destructure | Eval(读值), Interp, Objects, PArray |
| **`Eval.Call`** ★新 | `lib/phpbeam/eval/call.ex` | ~1200 | 调用协议：do_call、call_named、call_value、call_function、call_builtin、call_cb、call_php_method、call_count_method、bind_params、resolve_args、eval_args、resolve_function、materialize_native；**两个关口函数的家** | Eval, Interp, Objects, Classes.Table, Builtin |
| **`Eval.Generator`** ★新 | `lib/phpbeam/eval/generator.ex` | ~400 | 生成器协程：start_generator、gen_resume、yield 分派、gen_ctx | Eval, Interp, Env |
| **`Eval.ConstEval`** ★新 | `lib/phpbeam/eval/const_eval.ex` | ~600 | 编译期常量：const_fold、const_eval、eval_const_expr | Eval, Classes.Table, Value |
| `Render` | 现状 | 217 | var_dump/print_r/var_export/栈迹渲染 | Value, PArray, Classes.Table(只读), Objects |
| `Builtin`（注册表） | 现状 | ~180（517 减实现） | **纯注册表**：registry/0 + ho 解析辅助；实现全部下沉域模块 | 全部 XxxFns, Value |
| `Builtin.*Fns` 13 个 | 现状 | misc 1304→拆 | stdlib 域模块 + **新增 reflection.ex / datetime.ex / pdo.ex / session.ex**（Laravel 路线） | Eval.Call(仅两个关口), Interp(仅访问器), Objects, Classes.Table, Value, PArray |
| `MySQL` / `Http` / `CLI` / `Repl` ★拆出 | cli.ex 拆 repl.ex | — | 驱动/SAPI，**不动结构** | Interp |

**两个关口函数**（builtin → 语义核心的唯一入口，家在 `Eval.Call`，`Eval` 上保留 defdelegate）：

```elixir
# 回调：把 PHP 可调用值当函数调（usort 比较器、array_map 映射器、ReflectionMethod::invoke…）
Eval.Call.call_cb(cb_value, args :: [php_value], env, interp) ::
  {{:val, v}, env, interp} | {{:unwind, u}, env, interp}

# lvalue 写回（preg $matches、usort 数组本身、parse_str 第二参…）
Eval.Call.assign(ast_target, v, env, interp) :: {env, interp} | {{:unwind, u}, env, interp}
```

现状 builtin 已在用 `Eval.call_cb` / `Eval.assign`（pattern_fns、array_fns）——关口是**把事实收敛为唯一约定**：此后 builtin 域模块允许调的语义核心函数**只有这两个** + Interp 访问器 + Objects/Closure/Table 的读 API。新增 builtin 评审时按白名单卡。

---

## 3. 接缝详细设计

### 3.1 注册表 v2 与高阶能力位

现状条目：`%{fun: fun(vals, interp, ctx), refs: []}`，返回 `{:ok, v, interp} | {:ref_call, v, vals', interp} | {:ok, {:unwind, {:php_throw, {:native_error,_,_}}}, interp}`（原生错误通道）。**v2 完全后向兼容，只加一个可选键**：

```elixir
%{
  fun: ..., refs: [...],            # 不变
  skip_eval_refs: [...],            # 不变
  ho: %{                            # 可选：声明即加入高阶分派，取代 higher_order 硬编码名单
    args: :raw | :eval,
    #   :raw  = 收实参 AST（lvalue 写回型：usort/preg_match/parse_str…）
    #   :eval = 收已求值值（回调型：array_map/call_user_func/compact…）
    fun: fn(args_or_vals, env, interp) ->
      {{:val, v}, env, interp} | {{:unwind, u}, env, interp}
    end
  }
}
```

`do_call` 新流程（`Eval.Call` 内）：

```
callee 分派（var/closure IIFE/Closure::bind 特例）→ call_named
call_named:
  resolve_function →
    {:user,...}       → call_function          （不变）
    {:user_gen,...}   → call_generator_fn      （不变）
    %{ho: ho} = entry → ho 分派：
        :raw  → dispatch_ho 现逻辑（unwrap AST）→ ho.fun.(asts, env, interp)
        :eval → resolve_args(eval_args(...))   → ho.fun.(vals, env, interp)
    %{fun: _} = entry → call_builtin            （不变）
    :error            → undefined function
```

迁移策略：23 个函数按域成批注册 `ho:`（每批一个 commit），批内删 `dispatch_ho` 对应子句与 `higher_order` 名单项；全部迁完后删 `higher_order/4` 与 `dispatch_ho/2` 整体。**过渡期两套并存，任何时刻差分全绿。**

落位表（dispatch_ho 23 函数 → 目标模块）：

| 函数 | 目标 | args 档 |
|---|---|---|
| usort / uasort / uksort | `Builtin.ArrayFns` | raw |
| array_map / array_filter / array_reduce / array_walk / array_any / array_all | `Builtin.ArrayFns` | eval（any/all 现 raw，随迁移统一为 eval——其 cb 收值即可，需差分验证） |
| preg_match / preg_match_all / preg_replace_callback | `Builtin.PatternFns` | raw（$matches 写回） |
| parse_str | `Builtin.StringFns` | raw |
| compact / extract | `Builtin.ArrayFns`（extract 是数组域） | eval / raw |
| call_user_func / call_user_func_array | `Builtin.RuntimeFns` | eval |
| func_get_args / func_get_arg / func_num_args | **留 `Eval.Call`**（真引擎函数：读调用帧） | eval |
| eval | **留 `Eval.Call`**（真引擎函数：词法→执行） | eval |
| exit / die | `Builtin.RuntimeFns` | eval |

### 3.2 Eval 拆分与 façade

迁移原则：**`Eval` 保持全部现有公开函数名**（defdelegate 到子模块），builtin/Interp/测试零改动；子模块内部函数互相直调，不绕 façade。后续（可选、低优先）再逐步收紧调用方。

函数归属全清单（按 eval.ex 现有 def 划分）：

- **留 `Eval`**：所有 `eval/3` 子句（除 yield 四条 → Generator）、`apply_binop`、`php_to_string`、`concat_to_string`、`warn_to_string`、`warn/3`、`fetch_class`、`include` 相关、`static_props_key`、`prop_name_string`、`static_prop_name`。
- **→ `Eval.Call`**：`call_cb/4`（全型）、`call_count_method`、`call_php_method`、`call_function`、`materialize_native`、`resolve_args`、`eval_args`（含 func_get_args 族与 eval 两个 ho 实现迁入）。
- **→ `Eval.Assign`**：`assign/4`（全型）、`lvalue_path`、`path_write`、`read_target`、`isset?`、`unset_target`、`destructure`。
- **→ `Eval.Generator`**：`start_generator`、`gen_resume`、yield 四条 `eval/3` 子句（Generator 内部 `def eval_yield/2`，Eval 的 `eval({:yield,...})` 子句 defdelegate）。
- **→ `Eval.ConstEval`**：`const_fold/2,3`、`const_eval/3`、`const_eval_quiet`、`eval_const_expr`（defp）。
- **→ `Objects`**：`get_object`、`put_object`、`make_instance`、`new_stdclass`；**→ `Closure`**：`eval({:closure,...})` 里的运行时值构造。
- **→ `Classes.Table`**：`resolve_class_display`、`resolve_class_key`、`resolve_class_string`（读类表+uses，属地原则）。
- **→ `Refs` 不单设**：`deref/new_ref/make_ref_cell` 三函数小且热，留 `Eval`（ façade 已有，builtin 在用）。

### 3.3 Classes.Table 元数据只读 API（Reflection 的地基）

**存储不动**（方法 9 元组、param 6 元组、class decl map 保持——热路径零成本），API 按需渲染命名视图：

```elixir
def class_meta(interp, key) :: %{
      name: binary,                    # 显示名（含命名空间）
      kind: :class | :interface | :trait | :enum,
      parent: key | nil, interfaces: [key], traits: [key],
      final?: boolean, abstract?: boolean, readonly?: boolean,
      file: binary, line: non_neg_integer,
      methods: %{downcase_name => method_meta},   # 含继承链上全部（declaring_class 标注）
      props: %{downcase_name => prop_meta},
      consts: %{upcase_name => {:const_meta, value_ast}}
    } | nil

def method_meta(interp, key, name) :: %{        # find_method 的命名视图
      name: binary, declaring_class: key,
      vis: :public | :protected | :private,
      static?: boolean, abstract?: boolean, final?: boolean, by_ref?: boolean,
      params: [param_meta], line: non_neg_integer
    } | nil

def param_meta({:param, name, type, default, by_ref?, variadic?}) :: %{
      name: binary, type: binary | nil,          # 源码拼写串（签名消息用）
      default: ast | :required,
      by_ref?: boolean, variadic?: boolean,
      default_value: term | :not_evaluated       # 懒求值：ReflectionParameter 用
    }

def prop_meta / const_meta / interface_meta ...  # 同型，按 Reflection 需要补
```

实现纪律：`*_meta` 函数只做**元组→map 的纯渲染**（沿 `parent_chain` 合并继承成员），不做语义判断；`link_checks`、`find_*`、`is_a?`、`register`、`full_key_of`、`native_classes`、`parent_chain` 原样留在 Table。`instantiate`、`exception_info` → `Objects`。

**验收者即消费者**：L3 的 `Builtin.ReflectionFns`（ReflectionClass/Method/Function/Parameter/Property/NamedType 家族，以 native_classes 形式注册，方法体调 Table API + `Eval.Call.call_cb`）——API 够不够用由 Laravel 容器实测裁决，不够只扩视图不破形状。

### 3.4 Objects / Closure：值形状唯一权威

- **`class_ref` 替换**：`{:object, %{class: key}}` → `{:class_ref, key}`。全库消费点 3 处（eval.ex:3691 构造、classes.ex:831、builtin/var.ex:231）+ 可能的渲染/比较分支；一个 commit 完成，差分用例覆盖 `Foo::class` 的 var_dump/get_class/instanceof。同时删 builtin.ex:390 死子句。`Objects.class_ref(key)` / `class_ref?(v)` 收口构造与判型。
- **对象句柄**：`{:object, id}` 不变；注册表操作全部经 `Objects.get/put`（现 `Eval.get_object/put_object` 平移，Eval 留 delegate）。serialize.ex:101 直接匹配对象 map 的 `%{props:...}` 改为从 Objects 取数据后匹配（行为不变，去掉形状知识泄漏）。
- **闭包显式化**：`Closure.runtime(params, body, captures, arrow?, def_file, def_line)` 构造 7 元运行时值（tag 后 7 元 = 含 tag 8 元，现状不变形状）；`Closure.ast?/1`（6 元）`Closure.runtime?/1`（8 元）谓词。第一步只加模块并让 eval.ex 构造点走它；各处 `{:closure, _, ...}` 按 arity 的裸匹配**不强制**立刻改（风险/收益不成比例），新代码禁止裸匹配——写进 AGENTS.md。

### 3.5 Interp 状态归属与 fork_request（修订 Phase 3）

不物理拆 struct。在 `Interp` 内声明归属并实现池化原语：

```elixir
@boot_fields [:classes, :functions, :consts, :ini, :autoload_fns]
# 其余全部 @request_fields（out/globals/refs/next_ref/statics/objects/next_obj/
#   ns/uses/halted/suppress/warnings/error_handler/shutdown_fns/ob_stack/
#   file_stack/included/cur_line/call_stack/resources/next_res/output_origin/
#   throw_pos/get_guards/set_guards/sapi/anon_sites/gen_ctx/mysqli_report）

def fork_request(%__MODULE__{} = boot) :: %__MODULE__{}
# = boot 上把所有 @request_fields 重置为 new() 的初值（resources 重建 std 0/1/2）
```

驱动层（Http/L6）预热拓扑：`boot = Interp.warm(vendor_files)`（跑 autoload 树，丢弃输出）→ 每连接 `fork_request(boot)` + 注入请求 globals/sapi → `run_http` 的执行体。
**语义偏差登记**（L6 决策，不在本设计裁决）：池化下 `included`（require_once）与 statics 跨请求残留——预热载入过的文件请求内不再执行、`static` 属性不重置。PHP 真语义是每请求全新；Laravel 依赖此假设的程度需实测（config 缓存路径恰好缓解）。fork 时**全量重置 statics/included**是保命默认，池化收益只吃类表/函数表/常量表（这才是大头）。

---

## 4. 落地计划（commit 级）

每步门禁统一：`mix test` 全绿 + 差分 byte 一致 + phpt ≥ 285 + （Phase 1 起）`--warnings-as-errors` 干净。逻辑变更类 commit 必须先加差分用例。

### Phase 0 — 卫生（0.5 会话，独立价值）
1. 删 `lib/phpbeam/interpreter/` 空目录；`Repl` 拆 `lib/phpbeam/repl.ex`（纯移动）。
2. builtin.ex 的 php_sprintf/json_*/php_date 实现 → 新 `builtin/output.ex`（`OutputFns`），builtin.ex 只剩 registry（纯移动）。
3. 清 56 警告至 0；`mix compile --warnings-as-errors` 进门禁。
4. misc.ex 域内粗分（info/options/error 等 defp 分组即可，不拆文件——省 churn）。

### Phase 1 — Reflection 前置（1 会话，L3 开工前）
1. commit：建 `Objects`（平移 4 函数 + exception_info/instantiate/instance_of?，Eval 留 delegate）＋ 单测（句柄 get/put、new_stdclass 形状）。
2. commit：**class_ref 替换**（逻辑变更，先加差分用例：`Foo::class` 的 dump/比较/instanceof）＋ 删 json_encode 死子句。
3. commit：建 `Closure`（构造 + 谓词，改 eval.ex 构造点）。
4. commit：`Classes.Table` 从 classes.ex 拆名（classes.ex 变为 `defmodule PhpBeam.Classes` defdelegate 兼容层，防外部引用断裂——本仓内 30+ 调用点随后逐步改直引，不阻塞）。
5. commit：Table 的 `class_meta/method_meta/param_meta/prop_meta` 实现 + 单测（**用 php 探针生成期望**：`php -r 'var_dump((new ReflectionMethod(...))->...)';` 逐字段对照——探针先行纪律的天然用武处）。
6. L3 本体（`builtin/reflection.ex`）在干净地基上开工；其 API 缺口回灌 Table 视图。

### Phase 2 — 调用协议与 Eval 瘦身（1–2 会话，L3 与 L4 之间）
1. commit：`Eval.Call` 抽出（纯移动 + façade），eval.ex 内 do_call 私有函数随迁。
2. commit 批×4：注册表 `ho:` 落地——array 批 / pattern 批 / runtime 批 / string 批；每批删对应 dispatch_ho 子句与 higher_order 名单段。
3. commit：留引擎的 func_get_args 族 + eval 迁入 `Eval.Call`，删 higher_order/dispatch_ho 整体。
4. commit：`Eval.Assign` 抽出；commit：`Eval.Generator` 抽出；commit：`Eval.ConstEval` 抽出。
5. commit：misc.ex 若 Phase 0 后仍 >800 行，按域拆文件。
6. 收尾：eval.ex ≤2000 行核对；AGENTS.md 更新架构段（关口函数、白名单、禁裸匹配闭包）。

### Phase 3 — fork_request（0.5 会话，绑定 L6 实测）
1. commit：`@boot_fields/@request_fields` + `fork_request/1` + `warm/1` + 单测（cold vs fork 跑同一脚本输出一致；statics/included 重置不泄漏）。
2. L6 实测：预热收益数据（boot 时间×请求数）；若池化必要，Http 加 `--preload=files` 选项；语义偏差按 §3.5 登记。
3. （条件触发）编译后端立项时，再评估 Boot 物理拆分/ETS 共享——此时有真实消费者，不为想象设计。

---

## 5. 测试策略

- **接缝单测**（新增，仅新模块）：Objects/Closure 形状操作、Table meta 渲染（探针对照）、fork_request 重置语义、registry `ho:` 两档分派。每个 ≤30 用例，函数级。
- **既有护栏不动**：22 差分 + 697 phpt + 6 HTTP 差分 = 全部迁移 commit 的验收门禁；逻辑变更 commit 先补差分用例（用例文件按 `NN_主题.php` 惯例：`23_class_ref.php`、`24_ho_builtin.php`…）。
- **回归红线**：任何 commit 使 phpt 通过数 < 285 即 revert，不修复迁移（修复成本 > 重做该批）。

## 6. 风险与未决

| # | 风险/未决 | 处置 |
|---|---|---|
| R1 | ho 迁移中 array_any/all 从 raw 改 eval 引起实参求值时序差（警告顺序 byte 变化） | 迁移该批前 `php -r` 探针实证时序；若有差，保持 raw 档不统一 |
| R2 | Classes 兼容层（defdelegate）造成"两个名字"并存期心智负担 | Phase 1 内完成本仓直引改造，兼容层只防外部（对外仓 better-maksim/phpbeam 的兼容承诺） |
| R3 | Table meta 渲染在巨型类表（vendor 全载）下的性能 | meta 仅 Reflection 请求时渲染，不进 boot/执行热路径；实测在 L3 验收内 |
| R4 | 池化 statics/included 语义偏差误伤 Laravel | fork 默认全量重置 request 态；只吃类/函数/常量表复用 |
| D1 | **未决**：`Builtin.ReflectionFns` 以 native_classes 注册还是伪 PHP 类？ | 建议 native_classes（现役机制，mysqli/DateTime 同型），L3 开工首日定 |
| D2 | **未决**：对 better-maksim/phpbeam 外部使用者，Classes/Eval 公开面是否承诺兼容 | 建议不承诺（README 已声明实验项目）；façade 只是迁移力学，不是公共 API 承诺 |

## 7. 与 PLAN.md 的挂接

Phase 0 随手下个会话带走；Phase 1 排在 L3 之前（同一会话内先地基后本体）；Phase 2 塞在 L3→L4 间隙；Phase 3 由 L6 实测触发。本文件落地后，在 PLAN.md 各 L 条目下加一行"前置：见 ARCHITECTURE_DESIGN.md Phase N"即可。
