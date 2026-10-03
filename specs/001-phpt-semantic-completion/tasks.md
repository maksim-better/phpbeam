# Tasks: phpt 语义完备主线（全套件清偿）

**Input**: Design documents from `/specs/001-phpt-semantic-completion/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/gate-cli.md, contracts/baseline-formats.md, quickstart.md

**Tests**: 本 feature 的验收即门禁/判定命令本身（见 quickstart.md 三场景）——不单列测试任务，每个 Checkpoint 即验收点。

**Organization**: 按 spec.md 六个用户故事（P1→P6）分相，对应上游决策 R→Z→X→E′→F0→判定。

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可并行（不同文件、无未完成依赖）
- **[Story]**: US1…US6（映射 spec 用户故事）
- 路径为仓库相对路径

## Path Conventions

单项目既有仓库布局（plan.md Project Structure 节）：`scripts/`、`test/`、`lib/phpbeam/`、`docs/matrix/`、`tmp/`（gitignored）。

---

## Phase 1: Setup (Shared Infrastructure)

- [ ] T001 确认/创建工作分支 `001-phpt-semantic-completion`（自 master，若无），核对 `.specify/feature.json` 指向 `specs/001-phpt-semantic-completion`
- [ ] T002 [P] 建立账本脚手架：`tmp/baseline/`、`tmp/triage/`、`tmp/env_blocked/` 目录与 `.gitignore` 覆盖核对（tmp/ 整体已忽略）

---

## Phase 2: Foundational (Blocking Prerequisites)

**⚠️ 阻塞全部故事**：源树/依赖/构建在本机复活，否则任何 phpt 相关工作都无法进行。

- [ ] T003 [P] R1 版本重钉：`test/phpbeam/phpt_test.exs` 默认 `PHP_SRC` 改 `/Users/5i5j/Downloads/php-8.4.25`；文件头注释重记 oracle=8.4.17；建 `docs/matrix/drift.md` 骨架（E7 漂移登记项格式：用例/差异类型/处置）
- [ ] T004 R2a 依赖与构建：`MIX_REBAR3=~/.mix/rebar3 mix deps.get` + `mix escript.build` 全流程跑通；http_test 孤儿 `phpx serve` 清扫效力复验（`scripts/gate.sh` 既有 pkill 段）
- [ ] T005 R2b exqlite 补丁重建：fetch 后依 deferred.md 工具链条目描述重写 load_nif fallback 补丁，落 `scripts/patches/exqlite-load-nif.patch`（含应用说明头注释），`git apply` 重放并跑 sqlite3/pdo_sqlite 差分（test/cases/50_*.php、51_*.php）验证

**Checkpoint**: `mix escript.build` 成功、sqlite 差分绿——环境可开工。

---

## Phase 3: User Story 1 - 在本机恢复完整验证设施 (Priority: P1) 🎯 MVP

**Goal**: 三 lane 门禁 + 分片基线 + 判定命令 + 账本标记行 + 本机基线重录 + PLAN 重写（FR-001…FR-006 除 Z0 外、FR-014 基础部分、FR-015）。

**Independent Test**: quickstart.md 场景 1 三命令全过（fast/full lane PASS + 基线分片就位 + MySQL 差分绿）。

- [ ] T006 [US1] R3 MySQL 差分恢复：启动 OrbStack → 验证/重建 `phpbeam-mysql`（wp_test/wp/wppass）→ `mix test test/phpbeam/diff_test.exs` D 系 47–52 全绿
- [ ] T007 [US1] R4a harness 目录机制：`test/phpbeam/phpt_test.exs` groups 改显式 `{dir_id, path}` 对（U9 扁平命名 `zend-<sub>`/`ext-<name>`），`test/support/phpt.ex` 透传 dir_id 使失败清单可按目录分片
- [ ] T008 [US1] R4b 门禁三 lane：改造 `scripts/gate.sh` 为 `--lane fast|dirs -- <dir-id>…|full` + `--record [-- <dir-id>…]`（契约见 contracts/gate-cli.md：只收缩比对、分片和自检、退出码 0/1/2）
- [ ] T009 [P] [US1] R4c 映射表：建 `scripts/gate_map.conf`（fnmatch；引擎核心 `lib/phpbeam/{eval,interp,lexer,parser,classes,value,parray,objects}*.ex` → ALL；域模块→对应目录；`test/**`,`scripts/**` → 空；未命中→ALL）
- [ ] T010 [P] [US1] R4d 判定命令：实现 `scripts/criterion.sh --mode freeze|phase -- <相>`（freeze=豁免集作差；phase=豁免∪顺延；契约见 contracts/gate-cli.md）
- [ ] T011 [P] [US1] 账本标记行：`docs/matrix/exempt.md` 补 EXEMPT-DIR 目录级条目（16 扩展+OPcache+FFI C 编译类）；`docs/matrix/deferred.md` 存量条目转 DEFER 标记行（转写不改语义；格式见 contracts/baseline-formats.md）
- [ ] T012 [US1] R5a 基线重录：绿非 phpt 后 `--record` 分片重录既有 6 目录 + run-test/security 首录（13+50 例）+ 全量分片和自检 + 漂移量化（与旧 348 对照的差异逐条进 `docs/matrix/drift.md`）
- [ ] T013 [US1] R5b/FR-015 PLAN 重写：`PLAN.md` 按新结构重写（判据一口径含 tests/ 顶层 8 目录、矩阵总账本机重记、各相出口判据、五决策引用 `.specify/sp-brainstorm/phpt-semantic-completion/brief.md`）——单独 commit
- [ ] T014 [US1] MVP 验收：quickstart.md 场景 1 全过并记录输出

**Checkpoint**: 验证设施完全恢复，`scripts/criterion.sh` 可运行——US2…US6 可开工。

---

## Phase 4: User Story 2 - 语言核心考场全量开门（Z 相） (Priority: P2)

**Goal**: Z0 两枚阻断 bug 修复 + Zend/tests 4,969（根级 2,520 + 59 子目录 2,449）+ `tests/` 顶层 8 目录（含存量 348）清偿至只剩登记项。

**Independent Test**: `scripts/criterion.sh --mode phase -- Z` exit 0 + 冒烟三件套（artisan --version / WP install 渲染 / composer）全过。

- [ ] T015 [US2] Z0a trait 死循环修复：先复现探针（artisan→Carbon week() 13GB 路径）钉死症状，再修 `lib/phpbeam/classes/` trait 展平/interp 线程化同根因；探针差分用例入 `test/cases/`
- [ ] T016 [P] [US2] Z0b autoload 状态丢失修复：`class_exists` 触发 autoload 注册进被丢弃 interp 的路径（与 T015 同根：`lib/phpbeam/` interp 线程化残余）；修后 artisan 冒烟可跑
- [ ] T017 [US2] 演练批：`Zend/tests/exit`（25 例）全流程——harness 纳入（zend-exit）→ `--record` 首录 → 分诊 `tmp/triage/zend-exit.md`（class= 聚类+计数守恒）→ 清偿 → 分片收缩验证；quickstart.md 场景 2 即此批复盘
- [ ] T018 [US2] argv 播种：CLI extra args → `$argv`（`lib/phpbeam/` CLI 驱动路径；CLAUDE.md 已知欠账），以 Zend `--CLI--` 形态用例验收
- [ ] T019 [P] [US2] A1 顺延项：assign/read_target 警告位点的 error-handler 派发改造（`lib/phpbeam/eval/assign.ex` 六个复合赋值调用点返回形状，deferred.md A1 节）
- [ ] T020 [US2] B4 深度项：parser `return_hint` 保留返回类型字段 + Table 方法元组扩展 + Reflection getReturnType（`lib/phpbeam/parser*.ex`、`lib/phpbeam/classes/table.ex`）；超 2h 盒→拆独立里程碑登记 DEFER（Q5 规则）
- [ ] T021 [US2] 根级批次：Zend/tests 根级 2,520 例按 40/chunk 分批（~63 批）纳入清偿，批批三选一、分片只收缩
- [ ] T022 [US2] 子目录批次：59 子目录按规模序纳入清偿（type_declarations 460 → lazy_objects 225 → property_hooks 198 → traits 165 → generators 159 → enum 139 → …；>200 例目录再拆 chunk）
- [ ] T023 [US2] 顶层批次：`tests/` 既有 6 目录存量 348 失败清偿 + run-test/security 分片清偿（Q1 口径）
- [ ] T024 [US2] 相出口：`criterion.sh --mode phase -- Z` exit 0 + 冒烟三件套全过 + deferred.md Z 相盘点 commit（无第三态）

**Checkpoint**: 语言核心失败集只剩登记项；F0（US5）自此可插队执行。

---

## Phase 5: User Story 3 - 已实现扩展目录收割（X1+X2） (Priority: P3)

**Goal**: 18 个 T1 目录（~11.5k）+ 16 个 T2/T3 目录（~3.5k）逐目录清偿至只剩登记项；环境性失败与语义失败分列。

**Independent Test**: `scripts/criterion.sh --mode phase -- X` exit 0 + composer require 冒烟。

- [ ] T025 [US3] X1 大目录批：standard(3766)/spl(775)/date(690)/reflection(517)/mbstring(420)/session(256) 逐目录纳入清偿（deferred.md 对应扩展项随批消化；B2/B1/B5 各节）
- [ ] T026 [US3] X1 余量批：pcre/bcmath/filter/hash/gmp/random/iconv/ctype/json/tokenizer/calendar/readline 12 目录纳入清偿
- [ ] T027 [US3] X2 环境机制：`tmp/env_blocked/<dir-id>.txt` 清单落地（复跑义务机械执行：全量通道中清单内用例重现即转待复跑——Q3 决议）；OrbStack 常备
- [ ] T028 [P] [US3] X2 DB 目录批：mysqli(447)/pdo_mysql(168)/pdo(93)/pdo_sqlite(76)/sqlite3(94)/pgsql(99) 纳入清偿（D 系 deferred 项随批消化；环境性失败单列）
- [ ] T029 [P] [US3] X2 余量批：dom(855)/phar(568)/openssl(221)/curl(160)/zlib(157)/simplexml(157)/zip(108)/sockets(105)/xml(66)/posix(62)/ftp(64) 纳入清偿（C 系 deferred 项随批消化）
- [ ] T030 [US3] 相出口：`criterion.sh --mode phase -- X` exit 0 + composer require 冒烟 + env_blocked 复跑义务执行一轮（mysql 类全部复跑）

**Checkpoint**: 已实现面全部目录失败集只剩登记项。

---

## Phase 6: User Story 4 - E 组扩展子集落地（E′） (Priority: P4)

**Goal**: intl 场景锚子集 / gd 无依赖件 / sodium 映射 + FFI、pcntl 两节设计文档。

**Independent Test**: intl 场景锚差分逐字节一致（SC-004）+ sodium 用例三选一清偿 + 两节设计文档独立可评审。

- [ ] T031 [P] [US4] intl 子集：命名 Carbon/Laravel 本地化场景差分用例入 `test/cases/`（场景锚，Q4 决议）→ locale 泛型/NumberFormatter/IntlDateFormatter 实现（`lib/phpbeam/builtin/`）→ 子集外 553 例批量 EXEMPT-CASE 登记（理由：子集边界）
- [ ] T032 [P] [US4] gd 子集：无依赖件（getimagesize/imagesx/imagesy 等）实现 + git 图像库可得性评估（eimp/StbImage；hex 被挡走 git）→ 图像生成类用例 EXEMPT-CASE/EXEMPT-DIR 架构性豁免登记（评估失败则整扩展降级登记）
- [ ] T033 [P] [US4] sodium：:crypto 原语映射实现 110 面子集（`lib/phpbeam/builtin/`）+ 官方用例纳入三选一清偿
- [ ] T034 [P] [US4] FFI 设计文档：`docs/design/ffi-bridge.md`（PHP 侧调 Elixir/NIF 的形态设计，不做 C ABI——一节文档先行）
- [ ] T035 [P] [US4] pcntl 设计文档：`docs/design/pcntl-beam.md`（fork=spawn+状态分叉近似、信号→消息映射）+ 设计定稿后可落地用例（58 例中可执行子集）纳入

**Checkpoint**: E′ 相验收过 SC-004。

---

## Phase 7: User Story 5 - 编译后端去风险尖曝（F0） (Priority: P5)

**Goal**: 单用户函数 PHP AST→宿主 AST 端到端，解释器输出为 oracle 逐字节比对，可行性结论+接缝清单。

**Independent Test**: quickstart.md 各阶段锚点表 F0 行：两路输出逐字节一致或明确不可行判定。

**时点**: 依赖 T024（Z 相完成）之后任意时点，可与 Phase 5/6 并行。

- [ ] T036 [US5] F0 尖曝：选 1 个含类型/常量/调用的用户函数实现端到端编译验证（代码标注 throwaway，不入 lib/）；结论文档落 `specs/001-phpt-semantic-completion/f0-spike.md`（可行/不可行/条件可行 + 接缝清单全带处置建议）

---

## Phase 8: User Story 6 - 终态判据可机械判定 (Priority: P6)

**Goal**: 判定命令可复现性验证 + 判据口径文档化收尾（命令本身已在 T010 交付）。

**Independent Test**: quickstart.md 场景 3——同点双跑输出一致。

- [ ] T037 [US6] 判定演练：同提交点 `criterion.sh --mode freeze` 双跑一致性验证 + exempt/deferred 标记行与命令联动的边界用例（空登记、未知 dir-id）校验
- [ ] T038 [US6] 判据口径收尾：`PLAN.md` 终态节固化「全套件口径 = Zend 全量 + tests/ 顶层 8 目录 + 已实现目录 + EXEMPT-DIR 登记目录」与冻结判据机械判定说明——单独 commit

---

## Phase 9: Polish & Cross-Cutting Concerns

- [ ] T039 全量 lane 时长实测：超 30 分钟则按目录组拆 lane（`scripts/gate.sh`，语义不变）；快 lane 复测 ≤10 分钟
- [ ] T040 [P] quickstart.md 三场景全量复验 + `docs/matrix/{exempt,deferred,drift}.md` 账本终检（计数守恒抽查）
- [ ] T041 会话末清理：deferred.md 再入条件盘点、孤儿进程清扫复验、`tmp/` 产物归档说明

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: 无依赖，立即可始
- **Foundational (Phase 2)**: 依赖 Phase 1——**阻塞全部故事**
- **US1 (Phase 3)**: 依赖 Phase 2（T005 供 sqlite 差分、T003 供 harness）
- **US2 (Phase 4)**: 依赖 T014（US1 MVP）——三 lane 与分片基线是批次纪律的载体
- **US3 (Phase 5)**: 依赖 T024（Z 相出口——Zend 先行决策，避免引擎根因在 ext 目录重复修 N 遍）
- **US4 (Phase 6)**: 依赖 T030（X 相出口）；相内 5 任务全并行
- **US5 (Phase 7)**: 依赖 T024 之后任意时点，**可与 Phase 5/6 并行**
- **US6 (Phase 8)**: T037 依赖 T010 即可早跑演练；T038 收尾于全部相之后
- **Polish (Phase 9)**: 最后

### User Story Dependencies

```text
Phase2 → US1(MVP) → US2 → US3 → US4
                    └────→ US5（任意时点插队）
US1 ──────────────────────→ US6（命令早可用，终态读数靠全部）
```

### Parallel Opportunities

- Phase 2: T003 ∥ T004（不同文件）
- US1: T009/T010/T011 三任务并行（不同文件）
- US2: T016 ∥ T015；T019 ∥ 批次任务（不同文件）
- US3: T028 ∥ T029（DB 批与余量批不同目录集）
- US4: T031–T035 全并行
- 批次任务内部（T021/T022/T025/T026/T029）：目录间天然独立，可按目录并行分诊

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Phase 1 + Phase 2 + US1（T001–T014）→ **STOP and VALIDATE**: quickstart 场景 1
2. MVP 交付物 = 可复现验证设施 + 判定命令——此后每个相的「进度」都变成可读数字

### Incremental Delivery

1. US1 → 设施恢复（MVP）
2. US2 → 语言核心钉死 + `criterion --mode phase -- Z` = 0
3. US3 → 已实现面收割 + phase X = 0
4. US4 → E′ 子集 + 设计文档
5. US5 随时插队（Z 后）→ F 可行性答案
6. US6 → 判据终态可判定；`criterion --mode freeze` = 0 即 F 启动条件达成

### 单人节奏（本仓库实况）

批次任务（T021/T022/T025/T026/T028/T029）是**循环性工作**：每批=独立 commit 过 gate（仓库纪律），跨会话推进；任务勾选在对应目录集合全部收缩后打勾。

---

## Notes

- [P] = 不同文件且无未完成依赖
- 每批 commit 纪律沿用 CLAUDE.md：单独 commit、gate 只收缩、三选一、2h 时间盒、PLAN 里程碑单独 commit
- 语义疑问先探针（/opt/homebrew/bin/php 或 php-src 源码），不空想
- 解释器状态新增字段 → Interp struct + repl_init/run 双路径（仓库既有纪律）
- Z0（T015/T016）是引擎债里唯二「先行修复」项，其余 ~168 条随批次消化（Q3 决议并入主线）
