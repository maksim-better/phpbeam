# phpbeam 架构评审与分层改造方案

**后续文档**：`ARCHITECTURE_DESIGN.md`（落地版设计——模块清单/签名/迁移力学/commit 级步骤；其中 §1.1 修正了本评审的三处事实偏差，以设计为准）。
**评审时点**：2026-09-25（M24p4 后、L1 语法冲刺完成，目标已切 Laravel）
**评审方法**：全量依赖图扫描（grep 交叉引用）、LOC/函数计数、封装泄漏计数（struct 字段越层直摸）、git 演化分析（48 commits / 4 天）、对照 PLAN.md 三大远期目标（编译后端 / Web 运行时 / Elixir 互操作）逐项评估架构承压能力。
**代码规模**：lib 共 ~19,720 行 / 31 个模块；测试护栏 = 22 个 byte-diff 用例 + 697 phpt（285 过）+ zend 抽样 + 6 HTTP 差分。

---

## 0. 结论摘要

**现状不是"没有分层"，而是"前半身分层良好、语义核心塌缩成巨石"。** 前端（Lexer→Parser→Ast）和 stdlib（builtin/ 按扩展域拆分 + 注册表）已经分层且运转良好；SAPI 边界（L0）也是有意设计出来的干净接缝。真正的债高度集中在三处：

1. **`Eval` 巨石**（4,942 行 = 全库 25%，359 个函数，≥9 类职责）；
2. **`Interp` 上帝状态**（30+ 字段，被所有层直摸字段）；
3. **对象模型双表示**（`{:object, id}` 句柄 vs `{:object, %{...}}` 全 map 并存）——这已经产出一个存续了 24 个里程碑的真 bug（`===` 对对象恒 false，L1 才修）。

对用户"分层会好一些"的判断：**方向对，但要分层的地方是语义核心，且必须分阶段、绑定里程碑做，不能大爆炸重写。** Laravel 路线（L3 Reflection / L5 PDO / L6 池化）和编译后端恰好都需要同一组接缝——改造方案按"Laravel 里程碑前置抽取"编排，让每次重构都直接服务下一个功能里程碑，而不是为分层而分层。

---

## 1. 现状依赖图（实测）

```
                         ┌─ CLI ─┐
        驱动层            │ Repl(藏在cli.ex) │   Http(自足，仅碰 Interp.run/run_http/real_path)
                         └───────┘
                            │
   前端（干净，无回头依赖）    ▼        语义核心（债在这里）
   Lexer → Token            Interp ◄──────► Eval        Classes(1452行)
   Parser ─→ Ast            (上帝状态)     (4942行巨石)    Enums / Render(反向依赖Classes)
                                     ▲          │
                                     │          ▼
   值模型                          builtin/ 13个域模块 ──(回摸)──► Eval.call / Interp.warn ...
   Value / PArray / Env / Error / Pattern / MySQL(叶)
```

关键实测数字：

| 指标 | 数值 | 含义 |
|---|---|---|
| `eval.ex` | 4,942 行，135 def + 224 defp | 单模块占全库 25%，git 4 天内被 27 个 commit 触碰 |
| Top5 模块（eval/parser/classes/misc/interp） | 11,395 行 | 58% 代码在 5 个文件里 |
| `Interp` struct 字段 | 30+ | 输出缓冲/函数表/类表/常量/refs/statics/objects/资源/SAPI/调用栈/生成器上下文…全部平铺 |
| struct 字段越层直摸 | eval.ex 27 处、classes.ex 20 处、builtin 系 4 处 | 封装形同虚设 |
| `dispatch_ho`（eval.ex 内） | ~40 个 stdlib 函数 | eval/func_get_args/array_map/preg_match/usort…寄生在求值器里 |
| `builtin/misc.ex` | 1,304 行 | 名字即信号：无内聚原则的杂物间 |
| 全 map 形态对象泄漏 | builtin.ex:390、serialize.ex:101 | 绕过 objects 注册表直接匹配 `%{props:...}` |

---

## 2. 做对了什么（改造中必须保留的资产）

1. **前端分层已经成立**：Parser 只依赖 Token/Ast，零回头引用；heredoc/enum/promotion 每次语法冲刺都是纯增量落点。**不动。**
2. **builtin/ 的域拆分 + 注册表模式是对的**：13 个域模块按 PHP 扩展边界切（string/math/array/var/file/mysqli/stream/pattern/serialize/cursor/ob/runtime），`%{fun:, refs:}` 协议简单可扩展。Laravel 路线要新增的 mbstring/iconv/ctype/tokenizer/session/PDO 天然应该落这里。**保留，深化。**
3. **SAPI 接缝是有意设计的**：Http 只碰 `Interp.run_http` + 请求种子 + `sapi` 响应区，PLAN L8 明确"编译后端可整体替换解释器内核"——这个边界已经兑现了设计意图。**保留。**
4. **`{result, env, interp}` 线程化纪律是本项目的架构脊柱**：unwind 携带状态穿透、警告写 interp 必须返回——AGENTS.md 里每条"踩过"的坑都是这个纪律被违反的代价。分层**不得**改变这个模型（它等价于显式 state monad，是编译后端语义复用的前提）。
5. **byte 级差分护栏使重构可行**：eval.ex 的 359 个函数没有单测，但 22 个差分用例 + 697 phpt + zend 抽样是逐字节回归网。这是敢动巨石模块的唯一理由，也是下面每个阶段验收门禁的基础。
6. **moduledoc 记录不变量**的习惯（interp.ex 开头那段是全库最好的文档）。

---

## 3. 不足清单（按严重度）

### N1 `Eval` 巨石：9 类职责共生 ⚠️ 最重

一个模块里同时住着：表达式分派（`eval/3`）、**赋值/lvalue 机器**（`assign/4`/`lvalue_path`/`path_write`/`unset_target`/`destructure`，~600 行）、**调用协议**（`do_call`/`call_function`/`call_cb`/`call_php_method`/`bind_params`，~1,000+ 行）、**生成器协程**（`start_generator`/`gen_resume`，~300 行）、**对象注册表操作**（`get_object`/`put_object`/`make_instance`/`new_stdclass`）、**autoload**（`fetch_class`）、**常量折叠**（`const_fold`/`const_eval`）、**字符串转换语义**（`php_to_string`）、**原生错误物化**（`materialize_native`）。

影响：(a) 每个里程碑都往同一文件堆——Reflection（L3）要的是类元数据读取，却不得不改 eval.ex；(b) 编译后端需要"PHP 表达式语义"与"树遍历实现"分离，现在二者是同一坨；(c) 4,942 行单文件已经影响编辑/评审效率（27/48 个 commit 触碰它）。

### N2 `Interp` 上帝状态 ⚠️ 与 N1 并列

30+ 字段把"进程生命周期的所有状态"平铺：不可变的引导态（类表、函数表、常量表——**跨请求可复用、池化的对象**）和每请求态（out/ob、refs、objects、resources、sapi、call_stack——**必须每请求重建**）没有区分。L8 列的"跨请求 static/类表复用的可行性论证"在这个 struct 形状下无法做——要么全量复制，要么全量重建。且所有层直摸字段（eval 27 处、classes 20 处），没有访问器边界。

### N3 对象双表示 ⚠️ 已产出真 bug

`{:object, id}`（句柄，数据在 `interp.objects`）与 `{:object, %{props:...}}`（全 map 内联）两种形态并存，靠模式匹配的地方各自选择认哪种。后果实录：`strict_eq` 的 object_identity 只认全 map 形态 → **`===` 对真实对象自 M1 起恒 false**，24 个里程碑无人发现，L1 才顺手修掉。当前仍有两处绕过注册表直接匹配全 map（builtin.ex:390 json_encode、serialize.ex:101）。同理还有 `{:closure,...}` 6 元（AST）/7 元（运行时）**同 tag 双 arity**——AGENTS.md 自己标注"靠元数区分，踩过坑"。

### N4 `dispatch_ho` 落位错误

~40 个 stdlib 函数因"需要回调/env"而寄生在 eval.ex。切分标准（纯函数→builtin/，需回调→eval）是**实现便利驱动**而非领域驱动：usort 和 array_map 在 PHP 语义上和 sort() 是同一个 stdlib 家族，只因需要回调求值就住进了求值器。正确边界是给 builtin 层一个**显式回调协议**，而不是搬家。

### N5 对象/类运行时横跨三模块

类表与链接检查在 `Classes`，对象注册表操作在 `Eval`（get/put_object/make_instance），实例状态本体在 `Interp.objects`，枚举注册又单列 `Enums`。L3 Reflection（PLAN 里"最大单项"）需要的是对这套东西的**只读元数据 API**，现在它不存在——Reflection 届时要么自己重新拼装 9 元组，要么直接深摸。

### N6 元数据是裸位置元组

方法 9 元组 `{vis, static?, abstract?, final?, by_ref?, name, params, body, line}`、param 6 元组、类 decl map。位置访问无命名——每次加一个修饰符都是全库手术（AGENTS.md 已有实录）。Reflection/编译后端都要消费这些形状，是 N5 的放大器。

### N7 杂项卫生

- `lib/phpbeam/interpreter/` **空目录**（9/22 遗留）——某次未完成的重构意图；
- `Repl` 定义在 cli.ex 第 124 行（同文件两个 defmodule）；
- `builtin.ex` 自身挂实现（php_sprintf/json_encode/php_date，~200 行）而非纯注册表；
- ~56 个编译警告积压（AGENTS.md 明示不能当门禁）——死代码/未用变量在累积，大重构前不清会成为噪音。

### N8 单测结构（半项不足）

lexer/parser/value/parray 有单测；eval/interp/classes 只有集成级（CLI 差分）护栏。对差分纪律来说这**够用**，但意味着重构 eval.ex 时回归信号只有"整程序输出对不对"，没有"assign 语义这条函数级契约"。不要求补全单测（差分哲学不变），但 Phase 1/2 抽取的**新模块接缝处**应各带一小撮函数级测试。

---

## 4. 目标分层架构

依赖规则：**只许向下依赖；同层互不依赖；值模型层不知道语义层存在。**

```
L5  驱动/SAPI     CLI / Repl / Http            ← 现状已达标，不动
L4  stdlib       builtin/*.{string,math,array,var,file,preg,serialize,
                 stream,mysqli,session,PDO,mbstring,reflection...}
                 经「回调协议」下调语义核心      ← dispatch_ho 迁入；Laravel 新扩展全落此层
L3  语义核心     Eval.Expr     表达式分派（瘦壳）
                 Eval.Assign   lvalue/赋值机器
                 Eval.Call     调用协议（bind_params/call_function/call_cb）→ 唯一回调入关口
                 Eval.Generator 生成器协程
                 Classes.Table 类表/链接检查/元数据只读API（Reflection 消费者）
                 Objects       对象注册表 + 实例化（唯一认得对象形状的模块）
L2  运行时状态    Interp.State  →  Boot(不可变: classes/functions/consts/autoload链)
                                →  Request(out/ob/refs/objects/resources/sapi/call_stack)
                    池化/预热/编译后端共享的接缝
L1  值模型       Value / PArray / Object(形状唯一权威) / Env / Error / Pattern
L0  前端         Lexer / Token / Parser / Ast                    ← 现状已达标，不动
```

两条不变量贯穿全层：`{result, env, interp}` 线程化纪律不变；`unwind` 携带状态穿透不变。**分层是模块级的，不引入 process/GenServer/behaviour 边界**——每请求一 BEAM 进程已经由 L5 驱动层提供，语义核心保持纯函数。

---

## 5. 改造方案：四阶段，绑定里程碑，拒绝大爆炸

原则：每阶段结束时差分/phpt 全绿 + `./phpx test/cases/*.php` byte 级一致；一次只动一个接缝；**重构夹在里程碑之间做，从不在功能冲刺中途做**。4 天 24 个里程碑的速度是最大的资产，任何让差分护栏失效超过半天的方案都不采纳。

### Phase 0 — 卫生清扫（0.5 会话，随时可做）

- 删空的 `lib/phpbeam/interpreter/` 目录；`Repl` 拆到 `lib/phpbeam/repl.ex`。
- `builtin.ex` 里的实现函数（php_sprintf/json_encode/php_date）迁到 `builtin/output.ex`（新建），builtin.ex 只剩注册表。
- 清 56 个警告至 0，`mix compile --warnings-as-errors` 升格为门禁。
- `misc.ex` 按域粗分（info/options/error/网络…）——不求完美，只消灭"杂物间"心智模型。
- **验收**：全测试绿；diff 无回归；warnings=0。

### Phase 1 — Reflection 前置抽取（1 会话，紧贴 L3 之前，ROI 最高）

L3 是 PLAN 里"最大单项"，它需要的接缝恰是 N5/N6 的解药——**把重构做成 Reflection 的第一步**：

1. 抽 `Classes.Table`：类表数据结构 + `link_checks` + **元数据只读 API**（`method_meta/3` 返回 `%{vis:, static?:, params: [%{name:, type:, default:, by_ref:, variadic:}]...}`）。裸 9 元组对外不可见。
2. 抽 `Objects`：`get/put/make_instance/new_stdclass/instantiate` 从 eval.ex/classes.ex 集中；**消灭全 map 形态**（N3）：json_encode/serialize 改走注册表取数据，`{:closure}` 加显式 tag 区分 AST/运行时。
3. Reflection 类实现放 L4（`builtin/reflection.ex`），只消费 `Classes.Table` API——它成为该 API 的第一个验收者（`app(X::class)` 构造注入 = L3 验收标准本身）。
- **验收**：L3 全部验收项 + 既有差分全绿。

### Phase 2 — eval.ex 瘦身（1–2 会话，L3 与 L4（Carbon）之间）

1. 抽**回调协议**：`Eval.Call` 暴露 `call_cb/4` + `assign/4`（lvalue 写回）为 builtin 层唯一关口；然后把 `dispatch_ho` 的 ~40 个函数**迁回 builtin/**（usort/preg_*/array_map 到各自域模块；eval/func_get_args 这类真引擎函数留在 `Eval.Call`）。从此"纯/不纯"不再是摆放依据，领域才是。
2. 抽 `Eval.Assign`（assign/lvalue_path/path_write/unset/destructure）与 `Eval.Generator`（start_generator/gen_resume/yield）。
3. eval.ex 剩表达式分派 + 运算，目标 <1,500 行。
- **验收**：22 差分 + 697 phpt 回到基线通过数以上；新模块各带函数级单测（接缝契约）。

### Phase 3 — Interp 状态分层（0.5–1 会话，绑定 L6 池化实测时做）

`Interp.State` 拆 `Boot`（类表/函数表/常量/autoload 链/ini）与 `Request`（out/ob/refs/objects/resources/sapi/call_stack/statics）。驱动层拿 `Boot` 预热复用 + 每请求 fork `Request`。
- 这是 L8"跨请求 static/类表复用论证"的使能器，也是编译后端共享运行时的接缝——**只在 L6 实测证明需要池化时才做**（若 Laravel boot 性能够则降级为文档化方向）。
- **验收**：L6 的 per-request 性能对比（池化前后）+ 全回归。

### 不做清单（反模式防御）

- ❌ 不引入 behaviour/protocol/GenServer 重划边界——纯函数 + 状态线程化已验证 24 个里程碑；
- ❌ 不动前端与 builtin 域拆分（它们就是目标分层的样子）；
- ❌ 不为"每个 PHP 概念一个模块"做颗粒度均匀化——按接缝切，不按教科书切；
- ❌ 不在 Laravel 冲刺（L4/L5/L6）中途插队重构——Phase 2 排在 L3 后正是为此。

---

## 6. 风险登记

| 风险 | 缓解 |
|---|---|
| 重构破坏 byte 级语义（警告顺序/ob 状态线程化） | 每次移动后立刻跑全量差分；AGENTS.md 的"踩坑"条目即回归清单 |
| Phase 1/2 抽取时 interp 线程化被静默破坏（返回值丢 interp） | 警告 = interp 状态的既有纪律；接缝函数加单测固化 `{_, env, interp}` 三元组形状 |
| 改造与 Laravel 冲刺抢带宽 | 方案已按里程碑编排；Phase 0 可随手；每个 Phase ≤2 会话，可独立止损 |
| 全 map 对象消灭后 serialize/json 行为漂移 | 用 php 探针逐字节对照（既有纪律），两处泄漏点各加差分用例 |

## 7. 一句话收束

**这个代码库的问题不是缺分层，而是分层在语义核心处塌缩。** 修复它的正确方式不是重写，而是让接下来的三个里程碑（Reflection、dispatch_ho 归位、池化）各自携带一块接缝落地——功能与架构同一次支付。
