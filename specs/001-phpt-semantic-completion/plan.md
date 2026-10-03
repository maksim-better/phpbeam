# Implementation Plan: phpt 语义完备主线（全套件清偿）

**Branch**: `001-phpt-semantic-completion` | **Date**: 2026-10-03 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/001-phpt-semantic-completion/spec.md`

## Summary

把 phpbeam 的验收主线从「6 目录 780 例 + 348 失败」推进到「语言核心 + 已实现扩展目录全量、失败集只剩登记项」：先在本机重建验证设施（R），再修两枚阻断 bug 后按子目录清偿 Zend/tests 与 `tests/` 顶层（Z），随后逐目录收割 T1/T2/T3 已实现扩展（X1/X2），E 组扩展以子集口径落地（E′），Z 相完成后插编译后端尖曝（F0），全程由「三 lane 门禁 + 目录分片基线 + 机械判定命令」承载。技术路线的五项方向性决策见 spec 的 Clarifications 与上游 brief。

## Technical Context

**Language/Version**: Elixir ~1.18 / BEAM（宿主）；金标准 PHP 8.4.17（`/opt/homebrew/bin/php`）；验收源 php-src 8.4.25（`/Users/5i5j/Downloads/php-8.4.25`）

**Primary Dependencies**: OTP 内置（:zlib/:crypto/:ssl/:ftp/:zip/xmerl/:httpc/:re）；git 依赖（hex 被 TLS 挡）：exqlite v0.29.0（+本地 load_nif 补丁，需重建入库）、myxql v0.7.1、epgsql 4.8.0、db_connection/decimal/telemetry/elixir_make/cc_precompiler；构建绕行 `MIX_REBAR3=~/.mix/rebar3`

**Storage**: 文件系统——`tmp/baseline/<dir>.txt` 失败基线分片（gitignored）；`docs/matrix/{exempt,deferred}.md` 登记账本（入库）；`tmp/triage/<dir>.md` 分诊报表；MySQL 容器（OrbStack `phpbeam-mysql`，库 wp_test/laravel_test）

**Testing**: `mix test` 三 lane（`scripts/gate.sh [lane]`）；差分 `test/cases/NN_*.php`（双引擎字节比对）；phpt harness `test/phpbeam/phpt_test.exs` + `test/support/phpt.ex`（run-tests.php 语义）

**Target Platform**: macOS（darwin 24.6.0）本机；BEAM 常驻

**Project Type**: 解释器验收基础设施改造 + 语义清偿工程（非新子系统）

**Performance Goals**: 快通道 ≤10 分钟；目录通道分钟级（单目录）；全量通道目标 ≤30 分钟（超限按目录组拆 lane）；phpt 单例 ~0.2s、40 例/模块异步并行

**Constraints**: hex/部分外网被 TLS 挡；PHP_SRC 钉本机 8.4.25 树；oracle 钉 8.4.17；`mix escript.build` 先于 `mix test`（phpx 依赖）；每模块单独 commit 过门禁

**Scale/Scope**: 全套件 20,766 例；Z 相 = Zend/tests 4,969（根级 2,520 + 59 子目录 2,449）+ `tests/` 顶层新增 run-test 13 / security 50 + 存量 348；X1 ≈ 11.5k（18 目录）；X2 ≈ 3.5k（16 目录）；E′ = intl 553 / gd 315 / pcntl 58；deferred ≈ 170 条

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` 为未填充模板——无成文 gate 可执行。以仓库既有工程纪律（CLAUDE.md / PLAN.md 执行纪律节）为事实 gate：

| 事实 Gate | 评估 |
|---|---|
| 每模块单独 commit，过 `scripts/gate.sh` | 计划完全沿用（批次=commit 单位）✓ |
| phpt 失败基线只许收缩 | 强化为目录分片基线 + 判定命令机械校验 ✓ |
| 失败三选一（修复/豁免登记/2h 时间盒顺延） | FR-007 全文重申，相出口盘点 ✓ |
| 语义疑问先探针不空想 | 批次纪律第一步即全量分诊 ✓ |
| 解释器状态新增字段走 Interp + repl_init/run | 清偿批次的实现约束不变 ✓ |

**结论：无违规，Phase 0 放行。**

## Project Structure

### Documentation (this feature)

```text
specs/001-phpt-semantic-completion/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output（gate CLI / 基线与登记格式 / 判定命令）
└── tasks.md             # Phase 2 output (/speckit-tasks)
```

### Source Code (repository root)

本 feature 不新建源码树——改造既有验收基础设施并在清偿批次中触碰解释器：

```text
scripts/
├── gate.sh                    # lane 化改造：--lane fast|dirs <d,...>|full；--record [dirs]
├── criterion.sh               # 新增：冻结判据/相出口 机械判定（作差命令）
└── patches/
    └── exqlite-load-nif.patch # 新增：补丁重建入库（deps 刷新后可重放）

test/
├── phpbeam/phpt_test.exs      # 目录列表扩展 + 多级目录的模块扁平命名
├── support/phpt.ex            # run() 透传目录标识（失败清单可分片）
└── cases/NN_*.php             # 差分用例随批次追加

tmp/                           # gitignored
├── baseline/<dir>.txt         # 失败基线分片（dir = 验收目录标识）
└── triage/<dir>.md            # 分诊报表（class= 聚类，三选一计数）

docs/matrix/
├── exempt.md                  # 用例级 + 新增目录级豁免登记
└── deferred.md                # 顺延登记（含根因与再入条件）

lib/phpbeam/**                 # 按清偿批次触碰（Z 相：Eval/Interp/Parser/Classes；X 相：Builtin.*/Classes.*）

PLAN.md                        # 里程碑移动单独 commit
```

**Structure Decision**: 沿用单项目布局（lib/ + test/ + scripts/ + docs/），新增物全部是验证设施文件（gate/criterion/patches/baseline 分片），不引入新架构层——与「门禁是本 feature 的产品」定位一致。

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

无违规——不适用。
