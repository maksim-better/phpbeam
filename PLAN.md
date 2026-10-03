# phpbeam — 待办计划（2026-10-03 三次重排：语义完备主线，spec 001）

**验收定义（2026-09-26 拍板，2026-10-03 spec 001 重申并明确口径）**：完整 phpruntime——
任意 PHP 8.4 程序在 BEAM 上语义等价运行。三条终态判据：

1. **语义完备**：php-src 官方 phpt 套件 **全套件 pass 或显式豁免**。全套件口径（2026-10-03 明确）：
   **Zend/tests 全量（4,969）+ php-src `tests/` 顶层全部 8 目录（lang/strings/func/classes/basic/output/security/run-test，760 例）+ 已实现扩展目录全量 + 豁免扩展目录级登记**（exempt.md EXEMPT-DIR：16 扩展+OPcache+FFI 编译类，共 18 行）。
   失败三选一：修复 / EXEMPT-CASE 登记 / 2h 时间盒 DEFER 顺延。**F 冻结判据机械判定：`scripts/criterion.sh --mode freeze` 未豁免失败项 = 0（顺延不计入达标）**。
2. **扩展完备**：67 扩展 = 51 全量 + 3 后置全量（intl/gd/sodium，**子集口径**：intl 场景锚=Carbon/Laravel 命名场景差分一致、gd 无依赖件+图像生成架构性豁免）+ 16 豁免 + FFI 形态重映射（NIF 桥，设计先行）。
3. **运行时完备**：CLI + HTTP SAPI + INI 有效集 + 流子系统 + 错误协议 + 进程执行 + pcntl→BEAM 映射。

**主线五决策**（2026-10-03 头脑风暴，brief 归档 `.specify/sp-brainstorm/phpt-semantic-completion/`，gitignored；全文已并入 `specs/001-phpt-semantic-completion/spec.md`）：
语义完备优先 / 本机为准 / deferred 并入主线（先修阻断两枚）/ F 冻结+F0 尖曝 / Zend 先行。

## 矩阵总账（2026-10-03 本机重记，R5 事实源）

- **本机金标准**：oracle `/opt/homebrew/bin/php` **8.4.17**（PATH 裸 `php` 是 7.1 keg，勿用）；源树 `/Users/5i5j/Downloads/php-8.4.25`（**20,766 例**实测）
- **phpt 基线**：`tmp/baseline/*.txt` **8 分片 401 行**（lang 112/classes 149/basic 19/output 58/strings 7/func 3/security 47/run-test 6）；既有 6 目录 348 失败与旧机 D 相收口数**逐例一致**（换代零漂移实证，drift.md R5 结论）
- **漂移账**：换代实际漂移面 = 5 处机器钉常量（include_path keg、PHP_VERSION 族 8.4.17、mysqlnd 串、libcurl 8.18.0、pdo_sqlite 3.51.3）——已全部 probe 重钉；登记 `docs/matrix/drift.md`
- 函数面：~2400+ 已实现大半（A–D 相战果见 git 历史）；deferred.md 存量 24 节已转 DEFER 作用域行
- 待收割目录规模：Zend 4,969 + tests/ 顶层 760（401 已在账）+ T1 已实现 18 目录 ~11.5k + T2/T3 已实现 16 目录 ~3.5k + E′（intl 553/gd 315/sodium/pcntl 58）

## 阶段计划（spec 001 = 本计划的结构权威；每模块单独 commit 过 gate）

### R 环境与基线重置 ✅（2026-10-03 完成，spec 001 T001–T012）

- 依赖通道：github https 被墙 → **仓库本地 `url.git@github.com:.insteadOf`**（可逆）+ jason 走 hex；rebar3 用 ~/.mix/elixir/1-19-otp-28 自缓存（MIX_REBAR3 不再需要）
- exqlite load_nif 补丁重建入库 `scripts/patches/exqlite-load-nif.patch`（候选链：priv_dir→code path 扫描→PHPBEAM_EXQLITE_NIF 逃生口；deps.update 后 git apply 重放）
- phpbeam-mysql 容器本机重建（mysql:8.0 最新，root/root + wp_test/laravel_test + wp/wppass + wp_test/wppass）
- **门禁三 lane**（`scripts/gate.sh [--lane fast|dirs -- <dir-id>…|full]` + `--record [-- <dir-id>…]`）：分片基线只收缩比对、全量分片和自检、映射表 `scripts/gate_map.conf`（未命中 fail-safe=ALL）
- **判定命令** `scripts/criterion.sh --mode freeze|phase -- <相>`：EXEMPT-CASE/EXEMPT-DIR/DEFER(case: 逐例) 标记行解析；篡改证伪三态验证过
- harness：`{dir_id, path}` 显式对 + PHPT_DIRS 编译期过滤 + 模块原子净化（`-`→`_` camelize）
- 非 phpt 127/0 绿；D 系差分 47–52 全同

### Z 阻断 bug + 语言核心全量（进行中——下一步）

- [ ] **Z0**：trait 嵌套展平 13GB 死循环 + `class_exists`→autoload 进被丢弃 interp（同根：interp 线程化残余；artisan→Carbon week() 复现探针先行）
- [ ] **Z 相批次**（Zend/tests 59 子目录 + 根级 2,520 分 chunk + tests/ 顶层 348 存量清偿）：纳入→分诊（class= 聚类，`tmp/triage/<dir>.md` 守恒校验）→三选一→分片只收缩。已知会踩：`--CLI--`/argv 播种（$argv 现仅 HTTP SAPI）、A1 顺延的 assign/read_target handler 派发、B4 返回类型反射（深度工程超盒拆里程碑）、T006 登记的 log_errors stderr 副本通道
- [ ] 出口：`criterion.sh --mode phase -- Z` exit 0 + artisan/WP/composer 冒烟 + deferred Z 盘点
- 规模预期：初始失败 ~2,500 量级，数周至数月，跨会话推进

### X1 T1 已实现目录收割（~11.5k 例）

- [ ] standard(3766)→spl(775)→date(690)→reflection(517)→mbstring(420)→session(256)→pcre(166)→bcmath(167)→filter(115)→gmp(95)→random(71)→iconv(76)→json(89)→ctype(49)→tokenizer(51)→calendar(54)→hash(80)→readline(28)
- deferred 对应节随批消化（B1–B7）；出口：phase X1 = 0

### X2 T2/T3 已实现目录收割（~3.5k 例）

- [ ] dom(855)→phar(568)→mysqli(447)→openssl(221)→curl(160)→zlib(157)→simplexml(157)→zip(108)→sockets(105)→pdo(93)+pdo_mysql(168)+pdo_sqlite(76)→sqlite3(94)→pgsql(99)→xml(66)→posix(62)→ftp(64)
- 环境不可得单列（env_blocked 机制：全量通道复跑义务）；出口：phase X2 = 0 + composer require 冒烟

### E′ 后置扩展子集 + 设计文档

- [ ] intl：场景锚（Carbon/Laravel 本地化命名场景差分逐字节一致）；子集外用例 EXEMPT-CASE 逐条登记；不追 ICU 全量
- [ ] gd：无依赖件先行；图像生成类按架构性差异豁免（不追 libgd 字节对齐）；git 图像库评估（不可得则降级登记）
- [ ] sodium：:crypto 映射 + 用例三选一
- [ ] FFI→NIF 桥 `docs/design/ffi-bridge.md`；pcntl→BEAM `docs/design/pcntl-beam.md` + 可落地用例纳入（58 例子集）

### F0 尖曝（Z 相完成后任意时点，时间盒）

- [ ] 单用户函数 PHP AST→宿主 AST 端到端，解释器输出为 oracle 逐字节比对；结论+接缝清单落 `specs/001-phpt-semantic-completion/f0-spike.md`；代码 throwaway

### F 编译后端（冻结判据：`criterion.sh --mode freeze` = 0）

- [ ] PHP AST→Elixir AST 编译器（builtin 层两后端共享）；SAPI 边界不动；差分/phpt/浏览器三层护栏（编译产物以解释器输出为 oracle）
- 验收：Laravel 全量 boot 可测量加速；phpt 通过率不回退

## 既有基座（A–D 相战果索引；验收记录见 git 历史 7eb92f4..c084e14）

- **A runtime 地基**：错误协议（handler/_shutdown/assert）+ INI 286 条注册表 + 流包装器基础 + SAPI 欠账（$_FILES/chunked/keep-alive）
- **B T1 全量**：date/Dt 引擎、mbstring+ctype+iconv、数组族、Reflection、SPL 16 类、hash/tokenizer/filter/Core 杂项、bcmath/gmp/session/readline
- **C T2**：zlib/zip/Phar+三包装器、openssl+X509+http(s)、sockets、curl、ftp、xml 族、posix
- **D T3**：PDO+pdo_mysql（MyXQL）、sqlite3+pdo_sqlite（exqlite）、pgsql+pdo_pgsql（epgsql）、mysqli 94/106
- L0/L1/L1.5/L2/H0/架构重构 Phase 0-3 见 2026-09-26 版 PLAN（git 历史 c084e14）

## 引擎债（并入主线后仅剩阻断两枚先行，其余随批次消化）

- [ ] **Z0 两枚**：trait 嵌套展平死循环、class_exists interp 线程化（Z 相第一步）
- [ ] H0 顺延/A1 派发缺口/B4 返回类型等：Z 相分诊自然拉出
- [ ] log_errors stderr 副本通道（T006 登记）：Z 相错误协议类用例一并接上

## 回归验证资产（每相收尾一轮）

- Laravel：`phpx artisan --version` → list → 简单路由 HTTP 200
- WordPress：wp-load exit 0、install.php 完整渲染
- Composer：`composer require` 真实跑通
- D 系 DB 差分 47–52（容器在位）

## 执行纪律（gate/criterion 已机械化，2026-10-03 起）

- 语义疑问先 probe（/opt/homebrew/bin/php 或 php-src 源码），不空想
- 每模块单独 commit 过 `scripts/gate.sh`；快通道 ≤10 分钟；全量收尾跑
- 失败三选一：修复 / exempt.md EXEMPT-CASE（带理由与解除条件）/ deferred.md DEFER（case: 逐例，2h 时间盒）
- 基线只收缩（分片和自检）；豁免/顺延不静默
- 相出口 `criterion.sh --mode phase -- <相>` = 0；里程碑移动 PLAN.md 单独 commit
- 解释器状态新增字段 → Interp struct + repl_init/run 双路径

## 写明不做什么

- 不做解释器深性能优化（F 是根治；中间态只池化）
- 不做 php-fpm / OPcache 协议 / 多版本 PHP（钉 8.4 语义，金标准=本机 8.4.17+8.4.25）
- 不追 INI 677 只读项；不碰豁免 16 扩展（exempt.md 待命）
- 不做 FFI 的 C ABI；不做 intl 全量 ICU 移植与 gd 字节对齐（子集口径+架构性豁免）

## 风险登记

- Z 相规模：初始失败 ~2,500 估算，批次=子目录跨会话；深度工程（parser 元组改形）拆里程碑不卡批次
- 全量 lane 时长：现 ~103s/760 例——扩到 20k 例预计 ~30 分钟级，超限按目录组拆 lane（T039）
- exqlite 补丁：mix deps.update 会覆盖，重放 `git apply scripts/patches/exqlite-load-nif.patch`
- OrbStack/外网（curl/openssl/ftp 用例）可得性：env_blocked 单列
- 本机机器钉常量（include_path/版本族）：换 oracle 版本须随迁（drift.md 在案）

## 环境备忘（本机 /Users/5i5j，2026-10-03）

- php-src：`/Users/5i5j/Downloads/php-8.4.25`（PHP_SRC 可覆盖）；oracle：`/opt/homebrew/bin/php` 8.4.17
- 网络：github https 被墙走 SSH（仓库本地 insteadOf 已设）；hex 可达；Docker Hub 经 OrbStack 可达
- MySQL：OrbStack 容器 `phpbeam-mysql`（mysql:8.0，root/root；库 wp_test/laravel_test；用户 wp/wppass、wp_test/wppass）
- 排障：`fwrite(STDERR)` 即时插桩；工具 shell 的 grep 是快照函数，复杂管道用 `/usr/bin/grep`
