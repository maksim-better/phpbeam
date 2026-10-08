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

- [x] T015-p4 Z0 本体连修（13GB→已灭）：①**owner 章**——trait 方法编译期并入用类：merge_trait_methods 终态给展平方法盖 `owner:`（用类 FQ），fenv.scope_class 改用 owner（php 语义：self::/parent:: 按声明处编译类链而非运行时 LSB——否则 Carbon\Carbon 的 parent:: 永指自身→环）；②私/保护可见性补 owner 关系（trait 私有=用类私有；`true→` 兜底臂的可见性列表加 owner——**同措辞双臂陷阱**：专臂修了兜底臂仍在报错）；③**WeakMap 原生类**（v1 强存 props "wk<objid>" 键；Throwable 方法注入器把它覆写→跳过名单；引擎 index-assign 的 k 折叠加 `{:object,_}` 直通；offsetExists 的 `PArray.get 缺键回 :null 非 nil` 谓词）；④`method_exists(str,str)` 补 autoload（php 语义）。**13GB 循环已灭**（cs 从 7.8M 降到正常；artisan 到 LogManager 层）| tests: pv/pt/pp/wm/me 探针全同；差分 56；fast lane PASS（docker 僵死致 DB 例假红，OrbStack 重启+容器复活后过） | commit: 本 commit

- [x] T016b trait 双语义修 + unwind 传播：①`use_trait_names` 丢 qualified_name 的 **fq 标志**（`\Nx\Helper` 被 ns 重叠成 `ny\nx\helper`——`use \Nx\Helper` in ns Ny 探针钉死）；②**trait 抽象方法被按类的完整性执法**（`ParsesLogConfiguration` 含 abstract → "must be declared abstract" fatal → 注册中止 → LogManager 消失——即 T016b「autoload 丢类」的因果链全通）——`check_abstract_methods` 对 kind==:trait 豁免；③assign_op RHS 与 index 容器/索引路径的 val 硬解改 unwind 传播；④index 容器**双包 unwind 防御性解包**（某产地把完整 unwind 再裹一层——未追到产地，防御层兜底，登记待查）。php 8.4 语义点：trait 抽象方法=用类要求 | tests: nt/nt2/dt 探针、LogManager class_exists bool(true)、artisan 进到 `BindingResolutionException: Target class [config] does not exist`（容器绑定层——`config` 别名绑定未注册，下一层）；fast lane PASS | commit: 1189ec7

- [x] T017-p4 反射双修：ReflectionFunction 构造器认 registry 的 `{:user,...}` 元组（此前只认 map→用户函数 "does not exist"）；`ReflectionParameter->name` 真实属性化（两处生成点写入实例动态属性表——php 把 name 作为属性暴露，Laravel 容器 `$dependency->name` 直读） | tests: rp/rc/bt/alias 探针全同；fast+lang+classes+zend-exit lane PASS | commit: f571f15

- [x] T017-p5 闭包身份修复：`$f=fn();$g=$f;$f===$g` 恒 false（php true）——runtime 元组第 2 位铸 unique_integer、strict_eq 加闭包子句、8 处宽度匹配 + call_value/closure_state 位置解构随迁（call_value 漏改首跑 function_clause 当场抓获） | tests: ci/stp/stp2 全同；fast PASS | commit: 58f768f

- [x] T017-p6 SPL 迭代器家族（八类）+ 五笔顺手修：IteratorIterator（快照驱动+IteratorAggregate unwrap）、FilterIterator（**接受期写回注册表**——$this->current() 读活对象而非 detached 副本；**valid 短路**防全-false 死循环；Map.new 后者覆盖——common 方法必须在前）、DirectoryIterator（current()===$this、裸 readdir 序——php 不排序）、FilesystemIterator（flags 位 4096/256/16/32 探针钉值）、RecursiveDirectoryIterator、GlobIterator（glob→regex）、RecursiveIteratorIterator（**走 inner iterator 的 getChildren**——current() 快照没有递归性，php RII 语义）、RecursiveIterator iface。顺手：**DateTime::ATOM 类 const 键形修复**（`{"X"}` 1-元组键 vs 查找用裸串——不可达 const）；$_ENV 空数组种子（oracle GPCS——count($_ENV) 可用无警告）；iterator_count 读 dt_state["pairs"]；SplFileInfo::getPathname；FS/RII 常量族 | tests: it1/it1b/g2/g4/g5/g6 六探针 byte-identical；fast PASS；基线重录 412@9 分片（稳定） | commit: b1743a6

- [x] T017-p7 提升属性参数序 + RII 校验 + ctor throw 形状：**promoted 参数按声明序**（table.ex desugar 曾 promoted 前置→`__construct($a, private int $mode)` 位置实参错位——php 探针钉死声明序；FileTypeFilterIterator 收 mode 当迭代器即此根）；RII 构造校验（非 RecursiveIterator inner → InvalidArgumentException 精确措辞，php 拒收 ex1 实证）；native ctor throw 改 `{{:unwind,payload},obj,interp}` 三元（旧语句三元撞 call_constructor case——括号手术三翻车后用临时变量定型）。未竟：uncaught 栈缺 ctor 帧（ex1 差分仅此）；Symfony RDI 子类链（ignoreFirstRewind/自定义 current）在 lc 深处仍现 {pathname,:null} 对——最小复现 ifr 却 IDENTICAL，需带全 Finder 上下文再猎 | tests: pp1/ifr/ex1(除栈帧)/六探针；fast PASS | commit: c7dc3cf

- [x] T017-p8 静态属性家族共享 + Finder 全链跑通：**static props 槽按声明类解析**（`static_declaring_key` 沿父链找声明者——php 家族单槽语义；此前 Application::setInstance 写 Application 槽、Container::getInstance 读自己的槽→null→`new static` 造出裸 Container→resourcePath 未定义——即 config 回退根之一）；RDI `getSubPath/getSubPathname`（sub_base 随 getChildren 传递——Symfony current() 依赖，sr1/sr2 IDENTICAL）；symlink 探测走 :file.read_link_info（Elixir 无 File.symlink?）；SORT_NATURAL/LOCALE_STRING/FLAG_CASE/ASC/DESC 常量。**lc 锚到达 helpers.php resourcePath**（Finder 全链+config 装载完成） | tests: sr1/sr2/ifr/stfam IDENTICAL；fast PASS | commit: 95240c4

- [x] T017-p9 语法/正则三修：①**`!` 操作数=完整表达式**（php yacc 语义 `!$x = f()` → `!($x=f())`——Container::rebound 的 `if (! $callbacks = …)` 与 HandleExceptions::handleShutdown 同模式；unary 里遗留的旧 `!` 子句抢先吞掉新臂（双子句陷阱第二次咬人）且 `@` 臂连带失踪——`@$x['k']` 解析回归被 parser_test 当场抓获）；②**switch case 标签=完整常量表达式**（`self::STATE`——Dotenv EntryParser 状态机死因；const_eval_quiet 只认字面量→所有类常量标签落 default）；③**括号定界符嵌套配对扫描+转义状态消费成对反斜杠**（Dotenv Lexer 的 `((..)|(..))A` 无定界符形态——php 以 `(` 为定界符；首版只数深度不看转义对，`\\)` 误判转义）；LOG_*/SORT_* 常量族 | tests: bang/rb/hs/sw1/dx 全 IDENTICAL；fast PASS | commit: 5c7d4ec

- [x] T017-p10 `$this` 未绑定读取 → Error：php 8 探针四上下文（普通函数/闭包/静态方法/顶层）全 Fatal `Using $this when not in object context`（isset($this)=false 走 isset 路径不受影响；`??` 也 Fatal）——eval({:var,"this"}) 守卫 `not match?({:object,_}, env.this)` 即 Fatal。容器 build(closure) 链上出现 fn=nil 的 env 读 $this（帧栈：resolve→isBuildable@Container:1117）——**isBuildable 以 function=nil 的 env 执行**（某条方法分派路径漏建 fenv.function 或 globalize 串入），已在台账固化待查 | tests: tb 探针语义对齐（仅差闭包帧进栈的已知债）；fast PASS | commit: a0127df

- [x] T017-p10 收尾：探针清除、fast PASS（27b6000）。**新确诊债（deferred 级）**：bc.php 链上出现 **env=nil 的 var 读取**——栈：exec_stmts(853)→stmt_line(885)→expr_stmt(928)→call_builtin(403)→arg eval→prop eval→var$this，env 贯穿为 nil ⇒ **某条语句把 nil env 当 :ok 线程化**（return-unwind 约定 env=nil 的残余泄漏——上层收到 {:unwind} 后某处又当值继续）。这不是 $this 守卫的错（守卫语义正确），是 nil-env 线程化泄漏的正主。修复方向：audit interp.ex 所有 return unwind 出口 + exec_stmts 的 goto-resume 路径，确保 :ok 分支永不携带 nil env。

- [x] T017-p11 **finally-env 根因修复**：try_stmt 的 unwind 臂把 `e2`（return-unwind 约定携带 nil）直接喂给 finally 语句——Container::build 的 `finally { array_pop($this->buildStack) }` 即在此炸穿（nil-env 读 $this 全链症状的正主）。修为 finally 体用 **try 语句自身的 env**（php 语义：finally 在 try 作用域执行、看得到函数变量），信号按原 env 槽传播。bc.php（bootstrap 四级 + build(closure) 全链）与 php **IDENTICAL**；artisan 穿过 config/LogManager/Carbon 到 **`Class "Request" not found`**（AliasLoader 的 class_alias 机制——下一层） | tests: bc IDENTICAL；fast PASS | commit: ab0674b

- [x] T017-p12 **PHP 8.4 属性钩子落地**：parser prop_member 识别 hook 块（get/set、参数表、`=>` 箭头 / `{...}` 块体 / `;` 简写）；decl 传 prop_hooks → register 注入 prop + merge_prop_hooks 挂 get_hook/set_hook；引擎读写路径分派（hook 体在类作用域、`$value` 绑定、**箭头 set 的返回值=存储值**——oracle 探针钉死；块形式体自写 backing）。hook_guard {obj,name} 防递归——**每出口必须移除**（首版泄漏：set 跑一次后 get 永久静默，当场抓获）。Symfony 8 http-foundation Request 依赖此特性（include 成功）。附带 trait_exists/enum_exists 补 autoload（php 语义同 class_exists）。环境插曲：OrbStack 整体僵死（docker exec 全挂）→ pkill 重启 + 容器 start 恢复，queue_timeout 假红消失 | tests: ph2/ph3/ph4/ph5 IDENTICAL（ph1 差异 = 引擎整体缺 typed-prop 未初始化读检查，登记非 hook 特有）；fast PASS | commit: fbdb814

- [x] T017-p13 收尾：探针清除、fast PASS（14285ae）。**Request trait 链确诊（X 相级单元）**：apply_traits_pair → fetch_class → composer loadClass(include 完成) → **classes 不增**（canbeprecognitive 141→141；对照：macroable 同路径 143 注册成功；spl_autoload_call 场景同一 trait 成功）——嫌疑 = **include 注册上下文线程化**（fetch_class 的 nil_env/global 剥离 interp 与返回 it2 的写回有一层丢失/被 TCO 吞）。此单元挂到 X 相 closure：预计要在 fetch_class/autoload 上下文做一次系统性审计（连同 T016b 的 125→124 倒退同根）。
**调试工艺最后一条**：`System.get_env("X") and str` 在 X="1" 时 badbool（get_env 返字符串）——探针一律 `!= nil`；本迭代 4 次被吞编译错误/陈旧二进制误导，均因 build 输出被重定向——已内化为强制检查。

- [x] T017-p14 **Z 相主体启动**：catch 原生错误物化（find_catch 绑定前 {:native_error,...} → materialize 成真对象——php catch 永远给对象；泛适修复，全引擎 Error 被 catch 场景）；四 Zend 子目录纳入（zend-throw 2/ast 2/typehints 4/gh15976 5 → 基线 425@13 分片）；分诊五缺口登记 deferred（算术措辞带操作数类型、assert AST 导出、`\int` unqualified fatal、enum/类名保留字检查、typed-prop 未初始化读） | tests: throw/001 体语义对齐（余算术措辞）；fast 前已验证；基线录制绿 | commit: 195699d

- [x] T017-p15 算术错误措辞带操作数：value.ex arith_operand 错误改 **tag**（:unsupported_operand——渲染需 op/两侧上下文故上移）；eval arith 层渲染 `Unsupported operand types: <左类名|gettype> <op符号> <右类型>`（oracle 探针钉死 `E + int`）；interp 线程化进 arith/4；ValueTest 期望随 tag 化 | tests: throw/001 语义对齐（leaks 余 `Caught` 流控小差异）；基线 424@13 收缩；fast PASS | commit: 593c0a0

- [x] T017-p16 保留字矩阵 + `_` 弃用 + log_errors stderr 三连：①类名保留字矩阵 oracle 钉死（bool/int/float/string/iterable/object/mixed/null/false/true → `Cannot use "X" as a <kind> name as it is reserved` 编译期 fatal（@fatal 通道）；array/callable/static 是词法 parse error）；②`_` 弃用（parser 收集 deprecated_name 成员 → class 走 Classes.register、**enum 走 Enums.register 独立路径**两处都发活警告——enum 曾静默因忘接）；③**log_errors stderr 副本通道全量补齐**（T006 债清偿——每条显示诊断一条 `PHP <前缀>:  msg in file on line N` stderr，log_errors 门控）；④匿名类 decl 补 prop_hooks/deprecated_names 字段（缺键 badmatch——21_m24 回归当场抓获，工程教训：**register 新增解构键必须同步 anon decl**） | tests: e1/cu/e2/case21 IDENTICAL；基线 424@13；fast PASS | commit: ee28f31

- [x] T017-p17 六目录纳入 + 箭头捕获误警修正：arrow/closures/list/anon/numeric_strings/multibyte 六分片入基线（62 例/44 败，总账 468@19）；箭头自动捕获**未定义变量发 Warning**（arrow-002 oracle 对齐）——首版两处误警被 05_funcs 差分当场抓获：①赋值目标是写不是读（`$a + $n = 5` 的 $n）→ arrow_vars 排除 target var（复合目标保留内部读）；②by-ref use 定义时未定义**合法**（自引用闭包 use (&$fact)）→ by-ref 臂静默 | tests: 05_funcs/arrow002 IDENTICAL；fast PASS | commits: 0dea9da + c555201

- [x] T017-p18 Closure::fromCallable 真实现：callable 归一化为引擎 FCC 形（[obj,"m"]→method_fcc / [Cls,"m"]与"Cls::m"→static_fcc / 裸名→string；旧恒等实现把数组原样返回→调用 function_clause）。basic 用例从 internal error 推进到正常输出流。**遗留**：`{:fcc, inner}` 包装语义（echo/插值路径 call_value:136 function_clause——inner 为 static_fcc 时某处再包一层）——下一迭代主攻 | tests: fast PASS（closures 分片基线未动） | commit: 2374678

- [x] T017-p19 探针收尾（fast PASS，无代码变更提交——clean tree）。**colon-scheme 线索精确化**：`Closure::fromCallable("Foo::publicStaticFunction")` → static_fcc("foo","publicstaticfunction") → 调用时报 `Call to undefined method Foo::publicfunction()`——**方法名在错误里呈全小写**=我们的 downcase 在 FCC 形里提前丢失原拼写？方法表键本就 downcase 应命中——疑 static_fcc 的 eval({:static_call,...}) 把 key 当**显示名**再 resolve 时二次处理。下一迭代从「phpx -r 'require inc; Closure::fromCallable("Foo::publicStaticFunction"); $f("x");'」单点追。

### 恢复点（下会话从这里继续）

**closures 10 例收尾路径**：colon-scheme 1 例（上述）→ basic 全通 → 其余 9 例（lsb/rebinding/non_static/reflection/error/instantiate/gc/gh19653×2）逐个 probe 对齐。
**沿用**：list-by-ref 11 例；vendor DBG 还原；基线 468@19。

**T017-p19 主攻**：`{:fcc, inner}` 双层包装——fromCallable 返回 {:static_fcc,...} 后，某处（echo/concat 的 call_value:136）收到 `{:fcc, {:static_fcc,...}}` 再包一层。下手点：grep `{:fcc,` 的**构造点**（parser value_fcc eval 路径），看 fromCallable 的返回值如何流经 eval（native 返回值应直通不包装）；修正后 closures 10 例 + basic 全语义对齐。
**沿用**：list-by-ref 族 11 例（引用大单元）；vendor DBG 残留还原；基线 468@19。

**下一批**：closures(10)/list(11，list-by-ref 族=引用大单元前哨)/anon(7) 的类级分诊；deferred 弹药（`\int` unqualified、assert AST 导出、typed-prop 未初始化、箭头警告位置/可变变量名）。
**基线**：468 @ 19 分片。

**下一批候选不变**：arrow_functions(8)/closures(11)/list(11)/anon(16)/numeric_strings(8)/multibyte(8) ~62 例。**deferred 余项**：`\int` unqualified（typehints 2）、assert AST 导出、typed-prop 未初始化读、leaks `Caught`。
**基线**：424 @ 13 分片。

**Z 相节奏（确立循环）**：每迭代 = 纳入 3-6 个小子目录 → 首录 → 分诊 → 修最大普适类 → 收缩提交。
**下一批候选**：arrow_functions(8)/closures(11)/list(11)/anon(16)/numeric_strings(8)/multibyte(8) ~62 例。
**deferred 弹药**（按普适序）：①`\int` unqualified fatal（parser 类型声明检查——typehints 2 例）；②enum/类名保留字检查（gh15976 5 例一族）；③assert AST 导出（ast 1 例+）；④typed-prop 未初始化读检查（ph1 揭示）；⑤leaks `Caught` 流控。
**基线**：424 @ 13 分片。

**Z 相节奏确立**：每迭代纳入 3-6 个小子目录 → 首录 → 分诊 → 修最大普适类 → 收缩提交。**下一批候选**（zend-*/ 子目录按大小序）：arrow_functions(8)/closures(11)/list(11)/anon(16)/numeric_strings(8)/multibyte(8) 一批 ~54 例。**deferred 五缺口**是这批分诊的直接弹药——优先修「算术措辞带操作数」（两例立收）。
**基线现况**：425 失败 @ 13 分片（401 + throw2/ast2/typehints4/gh15976 5 = 13 新例中 13 失败——exit 分片此前 12）。

**优先级建议**（下迭代抉择）：①继续 artisan 洋葱（Request trait 注册上下文审计——X 相级，2-3 迭代）；②转 Z 相主体（zend-<sub> 批次，量最大但机械）；③typed-prop 未初始化读检查（ph1 揭示的整体缺口）。建议 ②——Z 相是主线判据的正文，Laravel 侧线已到收益递减段，且 trait 注册上下文审计留到 X2 数据库目录（mysqli 也要）一并做。

**T017-p13 线索**：artisan 到 SetRequestForConsole 的 `Request::create()`——`use Illuminate\Http\Request` 别名 + 类加载链（composer loader 加载 Request.php 时其 trait `CanBePrecognitive` 的注册链）。快速回路：`phpx -r 'require "vendor/autoload.php"; require ".../Illuminate/Http/Request.php"; var_dump(class_exists("Illuminate\\Http\\Request", false));'`。
**收尾清单（沿用）**：vendor DBG 残留还原；DEBUG_BACKTRACE_IGNORE_ARGS 常量；closure 帧进 uncaught 栈；typed-prop 未初始化读检查（ph1 揭示，整体缺口）；Pdo.query_mysql 对 DBConnection.ConnectionError 无臂（case_clause 内错——环境恢复后不再触发但臂应补）。
**工具链**：OrbStack 僵死处置 = `pkill -9 -f OrbStack; open -a OrbStack; docker start phpbeam-mysql`（docker 命令挂 4 分钟即为此症）。

**T017-p12 线索**：`Class "Request" not found`（SetRequestForConsole）——php 的 AliasLoader 在 composer autoload 时把 `Request`/`Route` 等短名 class_alias 到 FQCN；我们 php 侧 `class_alias` 已有（B6 实现过）但 AliasLoader 的注册器链（spl_autoload_register 的 loader 检查 `$aliases` 映射）可能没触发。从 `phpx -r 'require autoload; var_dump(class_exists("Request"));'` 起查（php true）。
**收尾清单**：laravel-smoke vendor DBG 残留还原（Container/LoadConfiguration 有 .bak；Application.php 的 BOOT 两行、EntryParser.php 的 BAD-STATE 行需手撤）；DEBUG_BACKTRACE_IGNORE_ARGS 常量补；closure 帧进 uncaught 栈（ex1/tb 差分）。

**T017-p11**：①**nil-env 线程化泄漏**（上述，根因级）——修完 bc.php 应到 "done"，artisan 过 build('env')；②laravel-smoke vendor DBG 残留待还原（备份 /tmp/{Container,LoadConfiguration}.php.bak，Application.php/EntryParser.php 无备份需手撤 DBG 行）；③DEBUG_BACKTRACE_IGNORE_ARGS 常量缺失（php 调试块用）。
**工具链提示**：rebuild 后必须显式 grep error（编译错误会被重定向吞）；artisan 单跑 ~5 分钟（Carbon 重），用 `phpx /tmp/bc.php`（~3 秒）做快速回路。

**T017-p11 线索（isBuildable env 串扰）**：`$this` Fatal 的 env.function=nil + current_file=Container:1117（isBuildable 体）+ 帧栈=resolve→isBuildable。下手点：grep `lib/phpbeam/eval/call.ex` 与 interp.ex 里**所有构造 %Env{} 却漏 `function:` 字段**的路径（call_static_method 非 static 臂 / magic_static_call / resolve 的 FCC 调用 / Env.globalize 串入方法体）；再跑 bc.php 确认 isBuildable 拿到 function="isbuildable"。 artisan 链此时应能过 build('env') 到下一层。
**工具链提示**：laravel-smoke vendor DBG 残留仍在（备份 /tmp/{Container,LoadConfiguration}.php.bak）；`mix escript.build` 的编译错误会被 `>/dev/null 2>&1` 吞——**任何 rebuild 后必须显式 grep error**（本迭代两次被陈旧二进制误导）。

**artisan 当前层（T017-p10）**：`make('env')` → `build(Closure)`（Container:1143 `return $concrete($this, $this->getLastParameterOverride())`）执行 env 绑定闭包时冒出 **`Undefined variable $error`**（HandleExceptions:240 的 `$error['type']`——但该链所有闭包都不含 $error 变量 ⇒ 疑**FCC/闭包调用的作用域串扰**：闭包体在错误词法 env 下执行，读到别处 handleShutdown 的 $error）。复现已固化：`/tmp/bc.php`（LEV+LC+HandleExceptions 后 `$app->build(fn() => "x")`）——php 侧 "done"，phpx 侧炸同一链。下一步：最小化 bc.php（去掉 bootstrap 逐个减），或 engine 层 dump 闭包调用时的 env.vars 键集合。
**工具链**：laravel-smoke vendor 有 DBG 残留（Container.php 的 MAKE-CONFIG、LoadConfiguration 的 CONFIG-INSTANCED、Application 的 BOOT probe、EntryParser 的 BAD-STATE——备份在 /tmp/{Container,LoadConfiguration}.php.bak）；phpx 仍缺 `DEBUG_BACKTRACE_IGNORE_ARGS` 常量（deferred）。

**artisan vs lc 分叉（T017-p9）**：直跑 `phpx /tmp/lc.php`（require autoload → new Application → LoadConfiguration::bootstrap）已过 config 到 helpers；但 **`phpx artisan --version` 仍报 `Target class [config] does not exist`**——artisan 走 bootstrap/app.php → ApplicationBuilder::withProviders() 链，config instance 发生在 KERNEL handle 时的 bootstrappers——php 下 make('config') 前必有 instance——疑我们链上某处 instance 写入未达（或者 withProviders 先于 bootstrap 执行了 make）。下迭代：对 artisan 打 Container::build('config') 调用点的 php 帧（engine 层打 call_stack 文件行——参照 DBG ii-pos 手法），比对 php 的等价帧。
**遗下债**：ex1 uncaught 栈缺 ctor 帧；IteratorIterator 快照 vs 惰性（LazyIterator 时机）。

**lc 锚下一层（T017-p8 线索）**：Symfony `RecursiveDirectoryIterator`（finder 子类：`private bool $ignoreFirstRewind = true` + 自定义 rewind 首跳 + 自定义 current() new SplFileInfo）在 Finder 链里产出 `{pathname, :null}` 对（排除过滤器的 pair 值 null）。**ifr 最小复现 IDENTICAL**——说明孤立机制没问题，分歧在 Finder 全链（多实例/求值序/子路径状态）。下迭代直接在 finder 子类上带真实 config 目录复现（排除 Exclude 过滤器，仅 Symfony RDI + foreach），对拍 php 逐项。
**ecosystem note**：IteratorIterator 快照 vs php 惰性——Symfony LazyIterator 的 fn() => searchInDirectory 延迟执行依赖快照时机，若后续差分踩到再改真惰性驱动。

**lc 锚现状**：`/tmp/lc.php`（LoadConfiguration standalone）进到 Finder 构建链后在 **FileTypeFilterIterator 构造处**卡住——`parent::__construct($iterator)` 收到 **int 1**（=Finder 的 ONLY_FILES 常量，本该是第二参）。两种嫌疑：①提升属性（promoted `private int $mode`）的 ctor 参数绑定错位；②调用点 `$iterator` 变量求值先被污染（更早的迭代器链返回了 1）。下一迭代从「打印 Finder 该调用点的两实参求值」下手（FilesystemIterator/自建 FilterIterator 已就绪，工具链齐）。
**本单元新增债**（deferred 待录）：IteratorIterator rewind 快照（php 惰性）；FilterIterator 基类 accept 抽象未 fatal；DirectoryIterator seek/clone。

**artisan 洋葱当前层（已定位到根）**：`LoadConfiguration` bootstrap → Symfony Finder 扫 config 目录 → **SPL 迭代器家族缺失**——`FilterIterator`/`IteratorIterator`/`FilesystemIterator`/`RecursiveDirectoryIterator`/`GlobIterator` 全无（`class_exists` 全 false；含 FileTypeFilterIterator extends \FilterIterator 注册即 fatal "Class filteriterator not found"）。**下一单元＝SPL 迭代器家族模块**（B5 债，X1-ext-spl 也要）：以 IteratorIterator（包装 inner Traversable，转发 current/key/next/rewind/valid）、FilterIterator（子类 override accept()；引擎驱动循环调 accept）、FilesystemIterator/RecursiveDirectoryIterator（目录扫 + SplFileInfo 产出）、GlobIterator（glob 模式）为骨架；Finder 另需 SplFileInfo 的 isFile/isDir/getFilename/getPathname 真目录语义（B5 里 SplFileInfo 族已有底子）。差分锚：`/tmp/lc.php`（LoadConfiguration standalone，php 侧 bool(true) bool(true)）。
另记：容器 config 绑定问题为表象——真根即上（bootstrap 在 LoadConfiguration 炸，config 从未 instance）。

**artisan 当前层（T016b 本案）**：`Class "illuminate\log\logmanager" not found`（LogServiceProvider(49)→loadClass→includeFile 文件跑了但类没落账）。**最小复现已固化**：`phpx -r 'require "vendor/autoload.php"; var_dump(class_exists("Illuminate\\Log\\LogManager"));'` → phpx false / php true。**已探明的机制**：fetch_class 的 autoload reduce 里，composer 闭包返回 `{{:unwind,_},_,it2}` 且 **it2 的 classes 计数倒退**（125→124——unwind 携带陈旧 interp，把 include 期间注册的类回滚掉）＝ deferred「class_exists→autoload 注册进被丢弃 interp」的真身。下一步：沿 unwind 产地追（嫌疑：call_cb/call_function 的 return-unwind 或 fatal_violation catch 携带 call 前 interp 的路径；在 include 返回点打印 classes 计数二分定位）。
**环境注意**：OrbStack 会僵死（docker 命令也挂）→ osascript quit + open -a OrbStack + docker start phpbeam-mysql；机器高载时 fast lane 也会到 5 分钟。
**zend-exit 剩 11 分解**（同前）。附带债：native_error catch 未物化；require 实参优先级；TRACE 哨兵门控；WeakMap 弱语义/迭代键形、offsetGet 缺键应抛 Error（deferred 登记）。

