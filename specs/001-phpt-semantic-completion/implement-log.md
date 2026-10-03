# implement-log — 001-phpt-semantic-completion

计划：`specs/001-phpt-semantic-completion/tasks.md`（本目录）。规格为约束权威。
台账纪律：每任务一行；偏差记 Ruling；每 Phase 末贴真实验证输出。

## Pre-flight（接口扫描）

- T007 产 dir_id 分片机制 ← T008/T009/T010/T012 消费：contracts/gate-cli.md + baseline-formats.md 已固化格式，一致。
- T011 产账本标记行 ← T010 criterion.sh 解析：格式同源 contracts/baseline-formats.md，一致。
- T003 PHP_SRC 重钉 ← 全部 phpt 任务消费：路径实测存在（20,766 例）。
- T005 exqlite 补丁 ← T028 sqlite 差分依赖：补丁重建后以差分 50/51 验证。
- Ruling: 台账按调用命令落本文件（非 sdd workspace）——sp-implement 命令规定优先。

## Phase 1

- [x] T001 建分支 001-phpt-semantic-completion（自 master c084e14）+ feature.json 核对 ✓ + 特性文档入库 | tests: N/A（纯分支/文档） | commit: 见本 commit
- Ruling: T002 的 tmp/{baseline,triage,env_blocked} 脚手架均在 /tmp/ gitignore 覆盖内，无入库物——完成即验证 gitignore，不产生 commit（避免空提交）。
- [x] T002 脚手架 mkdir tmp/baseline tmp/triage tmp/env_blocked + .gitignore 第 23 行 `/tmp/` 覆盖核对 ✓ | tests: N/A（gitignored 目录） | commit: 无（见 Ruling）

- [x] T003 R1 版本重钉：phpt_test.exs 默认 PHP_SRC→/Users/5i5j/Downloads/php-8.4.25 + 头注 oracle 8.4.17 重钉 + docs/matrix/drift.md 骨架（E7 格式） | tests: Code.string_to_quoted! syntax ok + tests/lang 解析 213 例 ✓（全量跑通顺延 T004 后——deps 未落无法编译） | commit: 本 commit
