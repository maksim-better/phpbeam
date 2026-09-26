# phpbeam — 待办计划（2026-09-26 二次重排：完整 phpruntime on BEAM）

**验收定义（用户 2026-09-26 拍板，取代当日早间 3d7d1a8 的应用兼容路线）**：完整 phpruntime——
任意 PHP 8.4 程序在 BEAM 上语义等价运行。三条终态判据：

1. **语义完备**：php-src 官方 phpt 套件全套件 pass 或显式豁免（`docs/matrix/exempt.md` 逐条登记）——失败集不再「保留」，逐例消灭或登记；harness 从当前 6 目录 697 例分批扩到全套件（扩目录纪律见下）
2. **扩展完备**：本机 php 8.4 实测 67 扩展 = **51 个全量实现**（函数/类/常量注册面 + 差分探针）+ 3 个后置全量（intl/gd/sodium）+ 16 个豁免登记 + FFI 形态重映射（NIF 桥）。分层清单固化在 `docs/matrix/ext_inventory.txt`
3. **运行时完备**：CLI + HTTP SAPI + INI 解析层（「php.ini 改变行为」有效集，非 677 全量）+ 流子系统（13 包装器）+ 错误协议（error_reporting 分级/handler/@ 抑制/shutdown/assert）+ 进程执行（exec 族/proc_open）+ pcntl→BEAM 进程映射

## 与 3d7d1a8 的差异（显式修正）

| 项 | 3d7d1a8（应用兼容路线） | 本次（运行时路线） |
|---|---|---|
| 目标集 | Laravel+WP 加权 13 模块 | 67 扩展分层全量（ext_inventory.txt） |
| 北极星 | 浏览器完整运行 Laravel | 任意 PHP 程序语义等价运行 |
| phpt | 368 失败基线「保留」 | 全清或逐条豁免，分批扩全套件 |
| runtime 基础设施 | SAPI/INI「子项待补」顺延 | 独立 PHASE A 先行（错误协议/INI/流是差分正确性地基） |
| 编译后端 | 「远期」 | PHASE F 正式排期，S/E 冻结点后启动 |
| Laravel/WP/Composer | 北极星+排序权重 | 回归验证资产（每 PHASE 收尾冒烟，不再驱动排序） |

## 矩阵总账（全部 2026-09-26 本机实测）

- 函数面：67 扩展 ~2400+ 函数；已实现 ~450。分层：T1 纯逻辑 18 扩展 / T2 BEAM 原生等价 13 / T3 外部客户端 7 / T4 后置全量 3 / T5 豁免 16 / 特殊形态 2（FFI、OPcache）——明细 `docs/matrix/ext_inventory.txt`
- 13 流包装器：file（部分）php（部分）http/https/ftp/ftps/data/glob/compress.zlib/compress.bzip2(随 bz2 豁免)/phar/zip
- INI 677 项（`php -i` 实测）→ 有效集分层：core 行为项（error_reporting/include_path/auto_prepend_file/max_execution_time…）+ 随扩展项 + 只读桩
- phpt：当前 harness 6 目录 697 例，285 过 / 368 败（基线 `tmp/baseline_phpt_failures.txt`）

## 阶段计划（拒绝大爆炸：每模块单独 commit + 过 `scripts/gate.sh` 门禁）

### PHASE A：runtime 地基（先行——错误协议/INI/流影响后续一半差分的正确性）

- [x] **A1 错误协议子系统（2026-09-26 完成，`7eb92f4`+`9c83544`+`abbcf45`）**：E_ALL 修正 30719（8.4 移出 E_STRICT）+ 默认 error_reporting 30719；warn 管线分级过滤（记录 error_get_last/@ 下仍记录、显示按位掩码）；`@` 激活时 `error_reporting()` 读掩码 4437；`set_error_handler` 真派发（Eval.Error 层：errno/errstr/errfile/errline 四参、返 true 全吞含 error_get_last、恰 false 穿透显示、抛异常从出错表达式穿透——Laravel ErrorException 模式实测通；错误位置在派发前定格）、handler 栈+levels 第二参；`set_exception_handler`/`restore` 在 Finalize 边界派发（接住后 exit 0）；`register_shutdown_function` 真执行（FIFO/带参/shutdown 中注册也跑/输出追加在未捕获渲染后、退出码保持）；`trigger_error` ValueError 精确措辞+USER errno 传 handler；`assert()` 全语义（zend_ast_export 消息重建/字符串描述/Throwable 描述直抛/AssertionError 入原生类表/trace 帧参数）——27 个 warn 位点改装，顺手修两个既有引擎 bug（**箭头函数自动捕获**、**链式调用 `$f()()`**）；phpt 363→357，门禁全绿；顺延登记 docs/matrix/deferred.md
- [x] **A2 INI 解析层（2026-09-26 完成，`c232e59`）**：`PhpBeam.Ini` 全量 286 条注册表（模块/access 位/默认值，探针转储）+ php.ini 解析器（注释/节/引号）+ startup/perdir 两层应用；`ini_set` USER 位执法、`ini_get_all` 三键形状、`ini_parse_quantity` zend 全移植（乘数=整串末字符、C 饱和+64 位回绕、警告逐字）；CLI `-c`/`-n`/`-d`；HTTP `.user.ini` docroot→脚本目录链；**auto_prepend/auto_append 真执行**（prepend 先行/其 unwind 抢占主脚本/进 once 表修 bug #32924/append 仅正常终止）；disable_functions 整体摘除；phpt harness `--INI--`→`-d` 管道；PHP_INI_* 实测非用户态常量未加；差分 30 全同 + 7 单测；phpt 363→356
- [ ] A3 流包装器基础：`php://`（memory/temp/filter/stdout 家族）、`data://`、`glob://`；`stream_context_create` 及 context 选项传递；file_get_contents/file_put_contents/fopen 走统一包装器分派（现在直连文件系统）
- [ ] A4 L0 SAPI 欠账：`$_FILES` 物化（multipart 解析+上传临时文件）、chunked body、keep-alive、HTTP/1.0
- 验收：phpt basic/output 套件失败集收缩 ✓（363→357）；`php -c` 差分用例（INI 行为项）过门禁

### PHASE B：T1 纯逻辑扩展全量（快赢块，每模块：php-src 签名对照 → 实现 → 纳入 ext/*/tests → 门禁）

- [ ] B1 date 全量（48 函数 + 14 类：DateTimeImmutable/DateInterval/DatePeriod/时区）——**DateTime 构造 ISO 串静默错值是首修项**（1970-01-01 错值比 Fatal 危险）
- [ ] B2 mbstring 57 + ctype 11 + iconv 10（78 纯函数，Erlang unicode 底座）
- [ ] B3 standard 数组族 ~40（uintersect/udiff 族、array_multisort、shuffle、array_rand、array_find…）+ 杂项（ip2long/putenv/getopt/sleep 族/forward_static_call…）
- [ ] B4 Reflection 全量（类缺 18：Function/Parameter/Property/UnionType/Attribute/Extension…）——原 L3，Table meta API 地基已落
- [ ] B5 SPL 类族 16（ArrayObject/ArrayIterator/堆栈队列堆/FileInfo/ObjectStorage）——Laravel collections 底座
- [ ] B6 hash 15（:crypto 映射）+ random 9 + filter 7 + tokenizer 2（lexer token 映射）+ calendar 18
- [ ] B7 bcmath 14 + gmp 51（Elixir 任意精度整数）+ session 23（进程态）+ readline 12
- 验收：每模块 ext/*/tests 目录纳入 harness（基线 `--record` 重建后只许收缩）；`docs/matrix/matrix_gaps.txt` 对应段清零；Carbon 核心测试抽样（原 L4 验收并入）

### PHASE C：T2 BEAM 原生等价

- [ ] C1 zlib(:zlib) + zip(:zip) + Phar——composer phar 分发在此解锁；`compress.zlib://`/`zip://` 包装器
- [ ] C2 openssl 64（:crypto/:public_key：X509 解析/签名验签/加密族/pkey）+ `https://` 流包装器（OTP :ssl）
- [ ] C3 sockets 37（gen_tcp/gen_udp/socket 直映射）
- [ ] C4 curl 33（httpc 映射；CURLOPT 有效集分层）
- [ ] C5 ftp 36（OTP :ftp）+ `ftp://`/`ftps://` 包装器
- [ ] C6 xml 族：xml 22 + xmlwriter 42 + dom 类族 + SimpleXML + xmlreader（xmerl 树映射）
- [ ] C7 posix 40（:os/:file 可映射子集，其余显式返回 false 按扩展语义）
- 验收：`composer self-update`/`composer require` 在 phpbeam 下真实跑通（C1+C2+C4 的综合验收）

### PHASE D：T3 外部客户端

- [ ] D1 PDO 抽象层 + pdo_mysql（MyXQL）——原 L5；prepare/execute/fetch 族/bindValue/errorInfo/setAttribute
- [ ] D2 sqlite3 + pdo_sqlite（exqlite，git 依赖——hex 被 TLS 挡）
- [ ] D3 pgsql 122 + pdo_pgsql（epgsql，git 依赖）
- [ ] D4 mysqli 补全（106 中余 ~48）
- 验收：Laravel Eloquent `User::count()/first()/create()` 对真库正确（mysql+sqlite 双跑）；`artisan migrate` 真实执行

### PHASE E：T4 后置全量 + 差异化件

- [ ] E1 intl 子集起步（Carbon/Laravel 需要的 ICU 面：locale 泛型/NumberFormatter/IntlDateFormatter）→ 全量 183 排尾部
- [ ] E2 gd 105（git 依赖图像库评估：eimp/StbImage；getimagesize/imagesx 等无依赖件先行）
- [ ] E3 sodium 110（:crypto 映射，Laravel 加密可选路径）
- [ ] E4 FFI→BEAM NIF 桥：`FFI::cdef` 不做 C ABI，设计 PHP 侧调用 Elixir/NIF 的形态（差异化卖点，设计先行一节文档）
- [ ] E5 pcntl→BEAM 进程模型：fork 语义映射（spawn + interp 状态拷贝=COW 近似）、信号→消息——设计文档先行（并发原语路线已排序过：Web 运行时→代码级原语）

### PHASE F：编译后端（X 轴——冻结点判据：PHASE B+C+D 完成 且 phpt 全套件失败集只剩豁免类）

- [ ] PHP AST → Elixir AST 编译器（用户函数/方法体；builtin 层原样复用——两后端共享）
- [ ] 差分/phpt/浏览器三层护栏全量回归（编译产物以解释器输出为 oracle 逐字节对齐）
- [ ] SAPI 边界不动的承诺兑现（L0 已按此设计）：编译器整体替换解释器内核，Http/CLI 驱动零改动
- 验收：Laravel 全量 boot 从秒级到可测量加速；phpt 通过率不回退

## phpt 扩目录纪律（PHASE B 起）

1. harness `test/phpbeam/phpt_test.exs` 的目录分块列表随模块扩展纳入对应 `ext/<mod>/tests`
2. 新目录首次纳入：跑一遍全量分诊（class= 标签汇总）→ 失败集 `--record` 进基线 → 之后的提交只许收缩
3. 每例失败三选一：修复 / 豁免登记（exempt.md 用例级格式）/ 时间盒 2h 超时登记 `docs/matrix/deferred.md` 顺延（顺延≠豁免，会话末清理）
4. Zend/tests（语言语义主套件）在 PHASE B 中段整目录纳入——语言核心语义的最终考场

## 既有基座（已完成，验收记录见 git 历史；此处只留索引）

- **L0 HTTP SAPI**（`283950f`）：`phpx serve`、请求种子、SAPI 响应区、6 例 curl 差分全过；欠账（$_FILES/chunked/keep-alive）→ PHASE A4
- **L1/L1.5 语法冲刺**（`c602d64`/2026-09-25）：提升属性/枚举/readonly/数组展开/FCC/命名参数按名绑定（含 php 精确错误措辞）；语言核心自评 ~70%
- **H0 phpt 清障**：410→368，42 例清除（插值常量折叠/Iterator 协议/备用语法…）；顺延清单 → 引擎债
- **L2 Composer/artisan 战果**（2026-09-26 四轮）：composer autoload 全链、bootstrap/app.php 完整工作、DI 反射循环跑通、**Carbon 可注册**（trait 归属/联合类型/native 父类兼容等 8 项连锁修复）
- **架构重构 Phase 0-3**（2026-09-26）：四层模块图 + Table meta API + fork_request/warm 池化接缝（ARCHITECTURE_DESIGN.md）

## 引擎债（新主线外的待修清单，时间盒 2h 纪律）

- [ ] trait 嵌套展平在真实链路失效（artisan→Carbon week() 13GB 循环）；class_exists 触发 autoload 注册进被丢弃 interp——两处同根：trait 展平/interp 线程化残余路径（原 L2 前线，不再驱动主线，phpx artisan 冒烟时修）
- [ ] H0 顺延：short_tags（--INI-- 管道，A2 后可解）、unset_properties 重入死循环、property_override 跨类链、返回引用真语义（数组共享）、析构次序、serialize_001
- [ ] 低危队列：顶层声明提升；动态属性 Deprecated（A1 的 error_reporting 分级落地后自然解锁）；`defined('Cls::CONST')`；`explode('')` ValueError

## 回归验证资产（Laravel/WP/Composer——每 PHASE 收尾跑一轮，不再驱动排序）

- Laravel：`phpx artisan --version` → `artisan list` → 简单路由 HTTP 200（每 PHASE 收尾冒烟；浏览器完整体验的原 L6/L7 目标转为 PHASE D 后的自然产物）
- WordPress：wp-load exit 0、install.php 完整渲染（`bd85da5`）保留为 phpt 之外的活体回归
- Composer：PHASE C7 后 `composer require` 真实跑通进常规冒烟

## 执行纪律

- 语义疑问先 php 探针/php-src 源码，不空想（AGENTS.md 正文）
- 每模块单独 commit + `scripts/gate.sh`（build + 非 phpt 全绿 + phpt 失败集与基线比对，只许收缩）
- 引擎 bug 时间盒 2h，超时登记 deferred.md；豁免走 exempt.md 登记，不静默跳过
- 差分用例 `test/cases/NN_主题.php` 进库；phpt 新目录首次纳入才允许 `--record`
- 解释器状态新增字段 → Interp struct + repl_init/run 路径（AGENTS.md 既有纪律）

## 写明不做什么

- **不做解释器深性能优化**：编译后端（PHASE F）是根治方案；中间态只做池化/预热（fork_request/warm 已落）
- **不做 php-fpm 协议**：BEAM 每请求一进程即应用服务器，Plug/gen_tcp HTTP 已覆盖 web 形态；OPcache 同理架构不适用
- **不做多版本 PHP**：钉死 8.4 语义（金标准 /opt/homebrew/bin/php 8.4.2 + php-src 8.4.24）
- **不追 INI 677 只读项**：按「php.ini 改变行为」有效集实现
- **不碰豁免清单 16 扩展**（exempt.md，有信号随时解除）
- **不做 FFI 的 C ABI**：BEAM 形态是 NIF/Elixir 互操作桥

## 风险登记

- **xml/dom 类面**：DOMDocument API 树大，xmerl↔DOM 映射是 PHASE C6 最大单项
- **git 依赖**（exqlite/epgsql/图像库）：hex 被 TLS 挡，仓库可用性需开工时验证
- **intl/gd/sodium**（T4）：函数面 100+，子集边界要靠 Laravel/Carbon 实测圈定，防止滑向无限工程
- **phpt 全量纳入的性能**：数万用例并行跑耗时会显著拉长门禁——目录级并行已有，必要时按目录拆 gate
- **pcntl/FFI 形态设计**：是设计活不是抄写活，各需一节设计文档先行（PHASE E 内）

## 环境备忘

- MySQL 容器：`docker start phpbeam-mysql`（8.0，wp_test/wp/wppass，127.0.0.1:3306）；Laravel 用 `laravel_test` 库
- hex 被 TLS 挡——依赖走 git（mix.exs 注释）；composer 走系统 php
- php-src：/Users/guozhu/Downloads/php-8.4.24（PHP_SRC 可改指向）；本机 php 8.4.2
- 排障工具：BEAM 采样、exit 截断二分（截断语法 255≠挂起 142）、`fwrite(STDERR)` 即时插桩
