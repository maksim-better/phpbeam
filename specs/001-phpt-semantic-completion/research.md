# Research: phpt 语义完备主线（Phase 0）

日期：2026-10-03。所有结论来自本机实测探测（非记忆），探测命令与原始输出见会话记录。

## U1 金标准版本漂移（8.4.24→8.4.25 / 8.4.2→8.4.17）

- **Decision**: 接受本机版本对——oracle=`/opt/homebrew/bin/php`（8.4.17）、源树=`/Users/5i5j/Downloads/php-8.4.25`（20,766 例实测）。R5 重录基线时把「旧基线用例在新版下的结果变化」单列为漂移分诊项登记。
- **Rationale**: 8.4.x 为补丁线，语义面冻结；expect 文本差异属可吸收噪声，且旧机器基线文件已丢失、无法作对照——重录是唯一事实源。
- **Alternatives**: 下载 8.4.24 源树对齐原 PLAN（拒绝：两树并存制造双事实源；漂移以重录量化即可）。

## U2 `tests/` 顶层目录清点（Q1 口径）

- **Decision**: 顶层共 **8 目录**——已纳入 6（lang/strings/func/classes/basic/output）+ 未纳入 **run-test(13 例)** 与 **security(50 例)**，共 63 新例随 R5 纳入。
- **Rationale**: 实测 `ls php-8.4.25/tests/`；两目录均为语言核心性质（run-tests 自举 + 安全语义），属判据一「语言核心」口径。
- **Alternatives**: 视作豁免（拒绝：security 50 例是 CLI/语言语义，无豁免理由）。

## U3 Zend/tests 批次切分

- **Decision**: 4,969 例 = **根级散文件 2,520 + 59 个子目录 2,449**。批次=子目录（59 批）+ 根级按现有 40 例/模块 chunk 约定分组（~63 批）。子目录规模头部：type_declarations 460 / lazy_objects 225 / property_hooks 198 / traits 165 / generators 159 / enum 139——单目录超 200 例的再按 chunk 拆模块。
- **Rationale**: 与 harness 现有 `Enum.chunk_every(files, 40)` 异步模块化天然对齐；子目录语义聚簇，失败分诊效率高。
- **Alternatives**: 按字母序全局 chunk（拒绝：丢失语义聚簇，分诊无法按根因聚类）。

## U4 exqlite load_nif 补丁状态

- **Decision**: 本机 `deps/` 未 fetch，原「escript 内 priv_dir 失效落 _build 路径」的本地补丁**已随旧机器丢失**。R2 重建为入库补丁文件 `scripts/patches/exqlite-load-nif.patch`（+落地步骤写进 quickstart），deps.fetch 后 `git apply` 重放，消除「deps.update 即丢」的隐性债。
- **Rationale**: deferred.md 工具链条目明示该补丁是 gitignored 目录里的本地改动；重建为仓库资产是唯一可持久化路径。
- **Alternatives**: 每次 deps.update 后手工重打（拒绝：正是要消灭的隐性债）；fork exqlite 到自管 git tag（过重，YAGNI）。

## U5 基线分片格式

- **Decision**: `tmp/baseline/<dir-id>.txt`，行格式沿用现行 `test <file>.phpt (Module.GN)` 不变；`<dir-id>` = 验收目录的扁平标识（如 `zend-type_declarations`、`std`、`ext-dom`）；全量基线 = 全部分片按字典序 concat（`cat tmp/baseline/*.txt | sort`），gate 校验分片和=全量。
- **Rationale**: `comm -13` 只收缩比对逻辑零改动；分片即「目录通道」的比对单位；格式不变让历史失败清单可迁移。
- **Alternatives**: 结构化格式（JSON/CSV，拒绝：现格式已含全部所需信息，引入解析层无增益）；单一文件+目录列（拒绝：目录通道需常量级切片，单文件做不到）。

## U6 改动文件 → 验收目录映射表（Q2 fail-safe）

- **Decision**: 映射表入库（`tmp/baseline/` 同级的 `docs/matrix/gate_map.md` 起，`scripts/gate.sh` 读 `scripts/gate_map.conf`）：引擎核心路径（`lib/phpbeam/{eval,interp,lexer,parser,classes,value,parray,objects}*.ex` 全族）→ `ALL`；`builtin/<域>` 与 `classes/<域>` → 对应 ext 目录列表；`test/**`、`scripts/**`、文档 → 空（快通道即可）；**未命中 → `ALL`**。
- **Rationale**: Q2 决议 fail-safe；核心文件本来就污染全部目录，映射为 ALL 与语义一致；表显式维护、注释写理由，映射演化随批次 commit。
- **Alternatives**: 按函数名/模块属性自动推导（拒绝：推导器自身成为新的错误源；显式表可 review）。

## U7 冻结判据/相出口判定命令

- **Decision**: 新增 `scripts/criterion.sh [--mode freeze|phase <相>]`：读当前全量失败清单 + `docs/matrix/exempt.md`（+相出口模式并入 `deferred.md`），作差输出未登记失败项；exit 0=达标。豁免/顺延条目格式见 contracts。
- **Rationale**: SC-006 要求「任何提交点可运行、结果可复现」；作差必须机器可读，登记文件加稳定行格式（见 contracts/baseline-formats.md）。
- **Alternatives**: 手工核对（拒绝：判据从仪表盘退回愿望）。

## U8 OrbStack / MySQL 可得性

- **Decision**: R3 步骤为「启动 OrbStack → 确认 `phpbeam-mysql` 容器存在（不存在则按 PLAN 环境备忘以 wp_test/wp/wppass 重建）→ 跑 D 系差分 47–52」。容器镜像在 OrbStack 卷里是否幸存只能启动后验证——列为 R3 的运行时检查点而非计划假设。
- **Rationale**: 探测时 daemon 未运行，`docker ps -a` 不可达；不臆断存在与否。
- **Alternatives**: 假设容器在（拒绝：违反「语义疑问先探针」纪律）。

## U9 harness 目录扩展的模块命名

- **Decision**: 多级目录（`Zend/tests/type_declarations`、`ext/dom/tests`）以扁平 `<前缀>-<名>` 进 Module 名：`PhpBeam.Phpt.ZendTypeDeclarations.G0`、`PhpBeam.Phpt.ExtDom.G0`——`Macro.camelize` 不接受 `/` 与 `.`，groups 元组改为显式传入 `{dir_id, dir_path}` 对列表。
- **Rationale**: 现有代码 `~w(lang strings ...)` 假设单级目录；ExUnit 模块名必须唯一且合法原子。
- **Alternatives**: 目录树镜像 Module 嵌套（拒绝：defmodule 嵌套生成复杂化，扁平前缀已唯一）。

## 结论

Technical Context 无遗留 NEEDS CLARIFICATION。全部 9 项研究点已决，进入 Phase 1 设计。
