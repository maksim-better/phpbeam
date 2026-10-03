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

- [x] T003 R1 版本重钉：phpt_test.exs 默认 PHP_SRC→/Users/5i5j/Downloads/php-8.4.25 + 头注 oracle 8.4.17 重钉 + docs/matrix/drift.md 骨架（E7 格式） | tests: Code.string_to_quoted! syntax ok + tests/lang 解析 213 例 ✓（全量跑通顺延 T004 后——deps 未落无法编译） | commit: a98efc9

- Ruling (T004): 本机 github https 443 被墙（curl 16 + connect timeout 实测），SSH 22/443 通（身份 maksim-better，仓库 origin 本就是 SSH）——解法 = **仓库本地** `git config url."git@github.com:".insteadOf "https://github.com/"`，零文件改动零版本漂移；不动全局配置。fallback 已探明备而未用：hex 全部 8 依赖精确版本在架（本机 hex 可达，与旧机情形相反）、s3 rebar3 可达。若换机：unset 该 local config 即还原。代价若错：无（可逆、仓库内）。
- Ruling (T004): rebar3 已在 ~/.mix/elixir/1-19-otp-28/（本机 elixir 1.19.5/OTP 28 自缓存，兄弟项目 building-block-elixir 编过 telemetry 实证）——MIX_REBAR3 绕行在本机不需要。
- 附带（T006 提前件）: OrbStack 启动后发现 phpbeam-mysql 容器不存在（U8 运行时检查点应验）→ 重建 mysql:8.0（root/root，库 wp_test/laravel_test，用户 wp/wppass + wp_test/wppass，127.0.0.1:3306）。D 系差分 47–52 在套件中通过（正式验收仍归 T006）。
- [x] T004 R2a 依赖与构建：mix deps.get 全落（git deps 走 SSH 通道 + jason 走 hex）+ mix escript.build 成功 + 非 phpt 全绿 + 漂移吸收 5 处（ini.ex/interp.ex include_path、const_eval+runtime+mysqli_fns 的 8.4.17 版本族、curl_fns/curl_consts 的 libcurl 8.18.0、pdo.ex sqlite 3.51.3） | tests: `mix test --exclude phpt` → **127 tests, 0 failures, EXIT=0**（tmp/t004_nonphpt5.log） | commit: 本 commit

- [x] T005 R2b exqlite 补丁重建：scripts/patches/exqlite-load-nif.patch（56 行，含应用说明头）——比旧机版本更鲁棒：priv_dir 失败时**扫描 code path 真实 ebin 推导 ../priv**（归档伪路径被 is_dir 过滤）+ PHPBEAM_EXQLITE_NIF 逃生口。调试纪要：首版 which() 推导被归档遮蔽打脸；候选表 List.flatten 把 charlist 打成整数流（path 变成整数 47）——charlist 就是整数列表，flatten 会拆掉候选项本身，改用 ++ 拼接。 | tests: RED（:undef Sqlite3NIF.open 三轮复现）→ GREEN `./phpx -r 'new SQLite3(":memory:"); version()'` → 3.45.1 数组；case 50 直跑 **BYTE-IDENTICAL** 28 行；51 随套件绿 | commit: 本 commit

- [x] T006 R3 MySQL 差分恢复：OrbStack 启动 + phpbeam-mysql 容器重建（U8 检查点应验：容器不存在；mysql:8.0，root/root + wp_test/laravel_test + wp/wppass + wp_test/wppass）+ D 系验收 | tests: 47/48/49/50/51 直差分 BYTE-IDENTICAL（51/68/1/28/27 行）、52 套件绿；套件整体 127/0 | commit: 本 commit

- [x] T007 R4a harness 目录机制：phpt_test.exs groups 改显式 {dir_id, php-src 相对路径} 对 + 头注固化 U9 扁平命名约定（tests/* 本名 / zend-&lt;sub&gt; / zend-root / ext-&lt;mod&gt;；失败行 Module 名编码目录→gate 分片依据）；Phpt.run 的 :suite 原本就线程化（tmp/phpt/&lt;suite&gt;/ 命名空间），零改动兼容 | tests: `mix test --only phpt` → **697 tests, 348 failures**（与 PLAN 记录的 D 相收口数完全一致——换代零漂移实证；tmp/t007_phpt.log） | commit: 本 commit

### Phase 2 验证（D5）
- 命令：`./phpx -r 'echo 1+1;'` → `2`；`mix test --exclude phpt` 
- 输出摘要：`Finished in 16.8s … 127 tests, 0 failures (698 excluded)`，EXIT=0（698 excluded = phpt 全套件，PHP_SRC 已就位）
- 未验证项：phpt 套件本体（归 T012 重录基线时首跑）；http_test 孤儿清扫在多轮运行中两次观察到端口占用告警但套件仍绿——清扫效力正式复验归 T014

