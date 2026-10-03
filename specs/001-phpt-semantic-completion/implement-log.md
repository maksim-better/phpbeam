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

## Phase 2（Foundational：R1/R2）

- [x] T003 R1 版本重钉：phpt_test.exs 默认 PHP_SRC→/Users/5i5j/Downloads/php-8.4.25 + 头注 oracle 8.4.17 重钉 + docs/matrix/drift.md 骨架（E7 格式） | tests: Code.string_to_quoted! syntax ok + tests/lang 解析 213 例 ✓（全量跑通顺延 T004 后——deps 未落无法编译） | commit: a98efc9

- Ruling (T004): 本机 github https 443 被墙（curl 16 + connect timeout 实测），SSH 22/443 通（身份 maksim-better，仓库 origin 本就是 SSH）——解法 = **仓库本地** `git config url."git@github.com:".insteadOf "https://github.com/"`，零文件改动零版本漂移；不动全局配置。fallback 已探明备而未用：hex 全部 8 依赖精确版本在架（本机 hex 可达，与旧机情形相反）、s3 rebar3 可达。若换机：unset 该 local config 即还原。代价若错：无（可逆、仓库内）。
- Ruling (T004): rebar3 已在 ~/.mix/elixir/1-19-otp-28/（本机 elixir 1.19.5/OTP 28 自缓存，兄弟项目 building-block-elixir 编过 telemetry 实证）——MIX_REBAR3 绕行在本机不需要。
- 附带（T006 提前件）: OrbStack 启动后发现 phpbeam-mysql 容器不存在（U8 运行时检查点应验）→ 重建 mysql:8.0（root/root，库 wp_test/laravel_test，用户 wp/wppass + wp_test/wppass，127.0.0.1:3306）。D 系差分 47–52 在套件中通过（正式验收仍归 T006）。
- [x] T004 R2a 依赖与构建：mix deps.get 全落（git deps 走 SSH 通道 + jason 走 hex）+ mix escript.build 成功 + 非 phpt 全绿 + 漂移吸收 5 处（ini.ex/interp.ex include_path、const_eval+runtime+mysqli_fns 的 8.4.17 版本族、curl_fns/curl_consts 的 libcurl 8.18.0、pdo.ex sqlite 3.51.3） | tests: `mix test --exclude phpt` → **127 tests, 0 failures, EXIT=0**（tmp/t004_nonphpt5.log） | commit: 本 commit

- [x] T005 R2b exqlite 补丁重建：scripts/patches/exqlite-load-nif.patch（56 行，含应用说明头）——比旧机版本更鲁棒：priv_dir 失败时**扫描 code path 真实 ebin 推导 ../priv**（归档伪路径被 is_dir 过滤）+ PHPBEAM_EXQLITE_NIF 逃生口。调试纪要：首版 which() 推导被归档遮蔽打脸；候选表 List.flatten 把 charlist 打成整数流（path 变成整数 47）——charlist 就是整数列表，flatten 会拆掉候选项本身，改用 ++ 拼接。 | tests: RED（:undef Sqlite3NIF.open 三轮复现）→ GREEN `./phpx -r 'new SQLite3(":memory:"); version()'` → 3.45.1 数组；case 50 直跑 **BYTE-IDENTICAL** 28 行；51 随套件绿 | commit: 本 commit

### Phase 2 验证（D5）
- 命令：`./phpx -r 'echo 1+1;'` → `2`；`mix test --exclude phpt`
- 输出摘要：`127 tests, 0 failures (698 excluded)`，EXIT=0（tmp/t004_nonphpt5.log）
- 未验证项：phpt 套件本体（后在 T007/T012 补验）；http_test 孤儿清扫多轮观察到端口告警但套件绿——清扫效力随 full lane 持续运行观察

## Phase 3（US1：设施恢复 MVP）

- [x] T006 R3 MySQL 差分恢复：OrbStack 启动 + phpbeam-mysql 容器重建（U8 检查点应验：容器不存在；mysql:8.0，root/root + wp_test/laravel_test + wp/wppass + wp_test/wppass）+ D 系验收 | tests: 47/48/49/50/51 直差分 BYTE-IDENTICAL（51/68/1/28/27 行）、52 套件绿；套件整体 127/0 | commit: 本 commit

- [x] T007 R4a harness 目录机制：phpt_test.exs groups 改显式 {dir_id, php-src 相对路径} 对 + 头注固化 U9 扁平命名约定（tests/* 本名 / zend-&lt;sub&gt; / zend-root / ext-&lt;mod&gt;；失败行 Module 名编码目录→gate 分片依据）；Phpt.run 的 :suite 原本就线程化（tmp/phpt/&lt;suite&gt;/ 命名空间），零改动兼容 | tests: `mix test --only phpt` → **697 tests, 348 failures**（与 PLAN 记录的 D 相收口数完全一致——换代零漂移实证；tmp/t007_phpt.log） | commit: 本 commit

- [x] T008 R4b 门禁三 lane：scripts/gate.sh 全量重写——fast/dirs/full + --record [-- <dir>]、分片只收缩比对（comm -13）、full 分片和自检、映射默认 lane（无 gate_map.conf 时 fail-safe 走 full，T009 接表）；harness 侧 PHPT_DIRS 编译期过滤（未知 dir_id 即 raise 防手滑）。调试纪要：①失败行 awk 分片首版没剥 "test " 前缀（分片名带空格）；②gate_phpt.log 被 dirs lane 复用覆盖，重录必须走 record 全量而非手工重切 | tests: 三态验证——record 全量（348/6 分片，和自检 348=348）、dirs lang PASS（112/112 shrink-ok）、**篡改证伪 RED**（删基线末行→GATE: FAIL 精确报出该例）、恢复后 full PASS、fast PASS | commit: 本 commit

- [x] T009 R4c 映射表：scripts/gate_map.conf V1（lib/ 引擎核心→ALL；test/scripts/docs/specs/md→空=快通道；未命中→ALL fail-safe 由 gate.sh 执行）+ phpbeam_map_dirs 三处真 bug 修复（zsh 单字符修剪陷阱→emulate -L+extendedglob 纯参数展开；`X/**/Y` 在 [[ == ]] 下零目录不命中→双行模式；stdin 传参弄反→printf 管道） | tests: 提取函数单测 10/10（lib 两级→ALL、test/docs/scripts/specs→EMPTY、未命中→ALL）；端到端默认 lane：分支 diff 含 lib → 映射 ALL → full PASS（348/348 只收缩+自检） | commit: 本 commit

- [x] T010 R4d 判定命令：scripts/criterion.sh——freeze（只认豁免集）/phase <相>（豁免∪顺延）双模式、EXEMPT-CASE（标识或 */后缀双形态匹配）/EXEMPT-DIR/DEFER 三类标记行解析、无分片 exit 2 提示先跑 full。zsh 两陷阱：`%% (*` 的括号是模式分组符→改截首空格；`*/"$id"` 未全引用被当文件名展开→全引号 | tests: 四态矩阵——freeze 基线 348=0+0+348(exit1)；+1 CASE→豁免1/未登记347；+DIR lang→豁免112；+DEFER strings(phase Z)→容忍7/未登记229——计数逐一精确，账本合成后还原 | commit: 本 commit

- [x] T011 账本标记行：exempt.md +18 行 EXEMPT-DIR（16 扩展+OPcache+FFI 编译类）；deferred.md 存量 24 节转写 DEFER 作用域行（转写不改语义，散文节保持权威）。**Ruling（判定语义收紧）**：节级 DEFER 作用域仅元数据不产生容忍——容忍只认分诊时逐例 `case:<id>` 标记（否则 15 条引擎根因可放行全部 348，phase 判据失真）；criterion.sh 同步收紧并回归 | tests: 转写后 freeze/phase 均 348=0+0+348（目录级行指未纳入目录、节级零容忍——设计行为实证）；case: 逐例容忍此前已验证 1=1 | commit: 本 commit

- [x] T012 R5a 基线重录：security+run-test 纳入 suites 首录；**Ruling（模块原子净化）**：Macro.camelize 不吃连字符（run-test→Run-test 原子带杠，gate 模块正则漏 6 条失败）→ 模块名 `-`→`_` 后 camelize（RunTest/ZendTypeDeclarations），gate 正则同步放宽 `[A-Za-z0-9-]`；drift.md 补 R5 收口结论（漂移面=5 常量已吸收，phpt 失败集零漂移实证） | tests: 重录 **401 failures/8 分片**，分片和=摘要=401（348 旧+47 security+6 run-test） | commit: 本 commit

- [x] T013 PLAN.md 三次重排：spec 001 结构权威落位（判据一口径/总账本机重记 401@8 分片/五决策溯源/R 相收口 Z 待启/纪律机械化/风险与环境备忘全面换本机事实）——单独 commit（49f47df） | tests: N/A（文档；数字全部来自本会话实测） | commit: 49f47df
- [x] T014 MVP 验收：quickstart 场景 1 全链路 | tests: 见下 D5 块 | commit: 本 commit

### Phase 3（US1 MVP）验证（D5）
- 命令：`mix escript.build`；`scripts/gate.sh --lane fast`；`mix test test/phpbeam/diff_test.exs`；`scripts/gate.sh --lane full`；`ls tmp/baseline/ | wc -l`
- 输出摘要（真实输出，2026-10-03）：
  - `Generated escript phpx with MIX_ENV=dev`
  - `GATE: PASS (fast lane)`
  - `1 test, 0 failures`（差分套件含 D 系 47–52）
  - `self-check: shards 401 lines, baseline sum 401` + `GATE: PASS (full lane)`
  - `8`（分片数）
- 未验证项：phpt 8 目录以外的全部 Zend/ext 目录（属 Z/X 相）；Laravel/WP/Composer 冒烟资产本机不存在（旧机未随迁）——T015 首步须先重建 Laravel fixture（composer create-project，网络待验证），已记入恢复点

## Phase 4（US2：Z 相——进行中）

- [x] T015-p1 trait 别名旁路修复（Z0a 第一刀，13GB 循环本体仍在追）：合成探针 t2（嵌套 trait + insteadof + as）暴露真 bug——`TB::f as fB` 的源方法被 insteadof 排除后**别名一起消失**（php 语义：排除只让出原名槽，别名仍挂）；修 table.ex merge_trait_methods：kept 只按 insteadof_excluded? 收（顺带清一段恒 false 死代码）+ 新增 excluded_aliases 通道对全候选集解析、仅入别名槽（键 downcase 对齐 219/431 行既有规范化——首版原始键被大小写咬了一口）；get_class_methods 是登记在案的 stub（旁路发现，Z 相反射目录债） | tests: RED（undefined method fB，watchdog 护栏）→ GREEN `O:TA/TB/TA.g` 与 php 逐字节一致；差分 53_z0_trait_alias.php BYTE-IDENTICAL；非 phpt 127/0 | commit: 本 commit

- [x] T018 argv 播种：CLI 附参 → $argv/$argc（-r → "Standard input code"、脚本→原样拼写、-- 剥离、无参恒有 [argv0]）+ $_SERVER 的 argv/argc 镜像 + SCRIPT_NAME/PHP_SELF/SCRIPT_FILENAME 保 as-typed（display 路径线程化，__FILE__ 仍 canonical）。探针三形状全 byte-match 8.4.17；调试纪要：①变量住 interp.globals 非 env（argv_info 桩是天生忽略参数的空壳）；②键名无下划线（$argv 非 $_argv）；③PArray.put 返 {:ok,arr} 元组不能管道直连 | tests: srvargv/srvkeys/-r 三探针 + 差分 54_z0_argv.php IDENTICAL + 门禁全量 PASS（401/401 只收缩+自检） | commit: 本 commit

- [x] T015-p2 + T017-p1（Z 相首批大扫除，一waves 一 commit——分解见下）：
  - **Laravel 冒烟资产重建**（T015 前置）：composer prefer-source 双通道下载（首任务被 600s 腰斩后续装），vendor 就位
  - **artisan boot 打穿三层**：FILTER/INPUT 常量补集（39 个，探针转储拼接；INPUT_SERVER=4→5 修正 + INPUT_ENV 补）→ badmatch 吞 fatal 的 **unwind 传播清扫**（eval.ex 8 位 + interp.ex 语句 9 位：if/while/do_while×2/for/switch/foreach 主+ref×2 + @ 抑制器 + cast 续体抽取 + 逻辑 and/or/**短路**修复（原实现两边都求值！）+ foreach_dispatch 续体法）→ artisan 现到 PHP 层正规错误（sebastian/version 的 @proc_open）
  - **exit/die 保留字执法**（T017 主刀）：类族名/顶层 const/goto 位 `expecting identifier`、函数名 `expecting "("`、标签位 `unexpected token ":"`（exit 当表达式撞冒号）、**die 一律渲染 "exit"**（T_EXIT 规范名）；类成员位放行（正向例保持绿）
  - **错误双通道**：解析错误 + 运行期 uncaught 的 log_errors stderr 副本（探针钉形：前缀 PHP+双空格、uncaught 带全栈、无前导空行）；harness 改 run-tests 语义（只比 stdout，2>/dev/null——此前 stderr 合并无害因 phpx 从不发 stderr）
  - **@include/@require 解析**：unary 层接 ternary 级 include（parse_include 抽取）；PHPX_TRACE_DEPTH 行号栈
  - zend-exit 分片 **24→12**；差分 55（短路+@include+fatal 传播）stdout/stderr 双通道 IDENTICAL
  - 调试纪要：for 门控 case-case 需括号；foreach_ref 替换残留孤儿调用；@suppress 计数器须在 unwind 出口回退 | tests: 门禁全量 PASS（9 分片只收缩、自检 413=基线收敛、zend-exit 12）；差分 53/54/55 三新增全同 | commit: 本 commit

- [x] T017-p2 进程执行族落地 + 三连修：`Builtin.ProcFns`（proc_open/close/terminate/get_status + exec/system/passthru/shell_exec + escapeshellarg/cmd；fd0/1 走 Port stdio、fd2 临时文件、数组形经 /usr/bin/env、字符串形 sh -c 带 $0="sh" argv0 修正；同步族 run_sync 收集到 exit_status）——**纯箭头必须裹 %{fun:, refs:[]}**（registry v2 约定，裸箭头在 call_named case_clause 崩）；`iterator_to_array(Generator)` 补驱动分支（gen_resume 复用；false 模式全重编、true 模式保键）；**生成器键计数器修**（显式 string 键不推计数器、无键才 use-and-bump、int 显键设 n+1——探针 g1/g2 全同）；`ReflectionClass::implementsInterface`（is_a? 传递闭包 + 接口不存在 ReflectionException）；harness 注入 TEST_PHP_EXECUTABLE(_ESCAPED) + cli 认 `--no-php-ini` | tests: po/sync-family 探针 BYTE-IDENTICAL；g1/g2/ii IDENTICAL；门禁全量 PASS（412 收敛）；zend-exit 12→11（exit_statements 清，env 注入生效） | commit: 本 commit

- [x] T015-p3 + T017-p3 artisan 六连修（一波一 commit）：①isset? 全调用点（6 处）unwind 传播（coalesce/nullsafe/isset/empty/index；empty 的 else 重排 + index 的 if 壳重建两度失手）；②`new static::$prop(...)` 解析（表达式类源——`::`+var 手构 static_prop，rest 须吃 `::` 与 var 两 token；此前的 `Some not found` 是 coalesce 断路的级联假象）；③**签名兼容 self 展开**（php: 父签名 self=声明类，子类宽型兼容——展开为前导 `\` 绝对形走 types_equiv 解析；name 已含全名防双前缀、`=~` 不能进 guard 两坑）；④iterator_to_array 非 traversable 对象 TypeError（措辞 `Traversable|array`）+ dt_state 点访问 Map.get 化；⑤**原生接口 parent 链**（Iterator/IteratorAggregate extends Traversable——is_a? 走通，Some 属 Traversable）；⑥**trait 作用域可见性**（trait 方法编译期并入用类——trait scope 见用类 protected；trait_used_by? 深链含祖先 traits）。附带发现：native_error 在 catch 语境未物化成异常对象（$e 绑到消息串，ita 探针对着，登记待查） | tests: 差分 56（self 兼容）IDENTICAL、nx/ita/some-ok 探针过；门禁全量 PASS（412） | commit: 本 commit

### 恢复点（下会话从这里继续）

**artisan 链当前层**：`Class "Some" not found`（= PhpOption\Some，包在 vendor/phpoption）——**use 导入解析在特定上下文失效**（错误报短名，疑 static-call/isset? 路径没过 interp.uses.normal）。同场需修 `Assign.isset?:684` 的 val 硬解（fatal 穿 `??` 变 badmatch——清扫族漏网位）。

**zend-exit 剩 11**：exit_values/exit_named_arg/exit_string_with_buffer（exit 参数弃用警告：`Passing null to parameter #1 ($status)…deprecations` + float 15.5 隐转警告 + named arg `status:`）、ast_print ×4（assert 消息的 zend_ast dump 含 exit）、disabling ×2（disable_functions 摸 exit/die 的 startup 警告 `Cannot disable function exit() in Unknown on line 0`）、die_string_cast（`exit(): Argument #1 ($status) must be of type string|int, stdClass given`）、exit_as_function（exit/die 的 FCC `exit(...)`）。

** artisan 每修一层剥一洋葱**：FILTER→badmatch 清扫→proc_open→生成器键→implementsInterface→现在 PhpOption 导入层。

