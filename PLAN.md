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
- [x] **A3 流包装器基础（2026-09-26 完成，`3e03511`）**：`PhpBeam.StreamWrapper` 解析层（file/php/data + `php://filter` 链 read=A|B/resource= 左到右 + `data:,` 短式）；fopen/fread/fwrite/fseek/ftell/feof/fstat/fgets/fgetc/rewind/stream_get_contents 统一资源操作层（memory/data/input 的 mem 资源 + filter 叠层递归 + close 递归内层）；**php://output 走 ob、php://stdout 绕过 ob**（write_direct，探针钉序）；fgc/fpc 同解析分派（丢弃写仍报字节数；文件系统回退）；stream_context 五函数（默认 context 惰性占注册表槽 3）；get/put_resource 裸 id 接缝；差分 31 全同 + w1-w3 探针全同；glob://（opendir-only）顺延至 B5 SPL；phpt 356，门禁 PASS
- [x] **A4 L0 SAPI 欠账（2026-09-26 完成，`ab80bf7`，PHASE A 收口）**：multipart 解析→`$_FILES` 全结构（php 8.1 full_path；同名 up[] 扇出平行数组）+ php 形状临时文件物化/响应后清理 + is_uploaded_file/move_uploaded_file（NUL 前缀内部注册表）；请求变量嵌套按**有序 assoc list** 重建（a[b]/a[] 自增/c[d][]/点空格→下划线）；chunked 解码（RFC 尺寸行/trailer/终止块）；keep-alive（1.1 持久默认、1.0 显式、proto 镜像、管道化余量、**完整 body 循环读**——修既有长 POST 截断）；var_export 嵌套数组换行缩进；array_walk_recursive（返回值语义，by-ref 契约顺延 B3）；http_test 六新差分用例 12/12；825 测试 0 败；phpt 356 无新增
- 验收：phpt basic/output 套件失败集收缩 ✓（363→357）；`php -c` 差分用例（INI 行为项）过门禁

### PHASE B：T1 纯逻辑扩展全量（快赢块，每模块：php-src 签名对照 → 实现 → 纳入 ext/*/tests → 门禁）

- [x] **B1 date 全量（2026-09-26 完成，`7bf75e8`+`6f19f0a`）**：`DtZone` TZif v2 真 DST 转换表 + `Dt` 引擎（解析语法含溢出滚动/@epoch 偏移区/月名形态；33 说明符 format 矩阵 20 输入逐字节；相对语法 21/21；add_months/diff/createFromFormat）；DateTime/Immutable/Zone/Interval/Period 五类重建（ISO 串静默错值根除；Immutable 新注册实例；diff 属性播种+%R%a；T 位定 M 义）；date()/gmdate()/strtotime()/mktime 族（溢出滚动）/checkdate/date_create 族/timezone_open 真例/date() 去遮蔽；差分 32 + d1-d4 探针全同；顺延 deferred.md：DatePeriod foreach（find_prop 整数键）/createFromFormat 全说明符/getLastErrors 明细；phpt 356 无回归
- [x] **B2 mbstring+ctype+iconv（2026-09-26 完成，`ed36fe8`）**：新域模块 `MbFns` 注册 59 函数——ctype 11/11（ASCII 类 + 整型码点语义 + Deprecated 精确措辞）；iconv 10/10（UTF-8/latin1/cp1252/ASCII 转换、//IGNORE、//TRANSLIT=NFD 剥离、MIME B64+Q 编解码 76 列折叠、set_encoding=php8.4 静默 false）；mbstring 38/57（码点族、strcut 边界向下取整、宽度族东亚宽表、convert_case 真常量 UPPER=0、str_pad 右侧新鲜填充循环、list_encodings 真实序、output_handler 带 headers-sent 警告、http_input=false 全探针对齐）；差分 33 全同；825 测试 0 败；phpt 356 无回归；**顺延**：mb_ereg\* 11（Oniguruma）、convert_kana/send_mail/convert_variables、TRANSLIT 精确表、mb_parse_str ho 通道
- [x] **B3 standard-数组族（2026-09-26 完成，`6f5d0b0`）**：新域模块 `ArrayStdFns` 26 函数——u\* 交集/差集矩阵 10 变体（ho raw-args + 回调末位约定，首数组键保留探针钉死；diff_uassoc 键对**全部**对方键过回调）+ assoc/key 纯变体 4；natsort/natcasesort 数字串自然序（键保留）；array_replace/\_recursive（修 Enum.reduce 捕获倒置）；count_values 首现插入序 + "1"/1 键合并；array_find/find_key（8.4 ho raw）；shuffle/multisort/natsort 走 {:ref_call} 写回（该重编号处重编号）；array_rand 双形态；str_shuffle；ip2long/long2ip（溢出负数/非法 false）；差分 34 全同；825 测试 0 败；phpt 356 无回归；**顺延**：uintersect_assoc 精确 slot 语义（AST 闭包重评测 stale-env 疑点）、multisort 多列+标志位全语法；杂项（putenv/getopt/sleep 族/forward_static_call）归 B7
- [x] **B4 Reflection 全量（2026-09-26 完成，`1b79d30`）**：新模块 `Classes.Reflection2`——ReflectionFunction(+Abstract)（builtin 注册表 + 闭包值双源，{closure:file:line} 命名，内置 arginfo 表补无参注条目）、ReflectionObject/Property（setAccessible/getValue/setValue 真对象变异 + 链式可见性）、ClassConstant、Union/IntersectionType、Enum(+cases)、Generator/Fiber/Reference/Extension 壳——18 缺口类 14 个真接线；ReflectionClass 补 getProperty/Properties/Constant(s)/hasConstant/getReflectionConstant/getDefaultProperties（链遍历 + 提升属性 nil 默认排除）；ReflectionMethod 补 getName/getNumberOfParameters(+Required)/getReturnType/getDeclaringClass-返回对象；**引擎修复两枚**：(string) 强转对象现在查 __toString()（cast_to_string，NamedType 渲染通道）、NamedType::allowsNull 畸形四元组（既有）；param 对象构造 interp 线程化（stale-id bug）；差分 35 全同；825 测试 0 败；phpt 356 无回归；**顺延**（deferred.md）：返回类型反射（parser return_hint 丢弃类型，需方法元组加字段）、invoke/getClosure/文件行号族、enum case 物化
- [x] **B5 SPL 类族 16（2026-09-26 完成，`adafd47`）**：新模块 `Classes.Spl` 全 16 类——ArrayObject/ArrayIterator（共用方法表：offsetX 四件套/count/getArrayCopy/append/完整 Iterator 协议被 H0 foreach 机器驱动；exchangeArray/排序族）；DLL 底座 + SplStack(lifo)/SplQueue(fifo enqueue/dequeue)；SplHeap 族 min/max（排序余集抽取 + 用户 compare 分支）+ SplPriorityQueue；SplFixedArray(getSize/setSize)；SplObjectStorage（attach/detach/contains 对象键 + getInfo 迭代）；SplFileInfo 族；SplObserver/SplSubject 接口；**ArrayAccess 升格引擎协议**：$ao[$k] 读→offsetGet / 写→offsetSet（容器单次求值分派；raw 路径保原 interp——双求值回归被 22_generators 门禁当场抓获）/ isset→offsetExists / unset→offsetUnset；heap 比较方向修正；tagged-key 纪律（裸 int 在 PArray.normalize 全灭——数个静默丢弃 bug）；差分 36 全同；825 测试 0 败；phpt 354<基线363 门禁 PASS；**顺延**：stack/queue foreach 第二轮、FixedArray 引擎写路径（直接 offsetSet 正常）、heap 用户 compare 方向、ArrayObject flags
- [x] **B6 hash/tokenizer/filter+Core 杂项（2026-09-26 完成，`12e5546`）**：新域模块 `Builtin.B6` ~90 条——hash 增量族（hash_init/update/final/copy/update_stream/update_file/hash_file/hash_hmac_file，上下文住 `interp.resources` `%{hash_algo:, hash_buf:}`+closed 标志；hash_pbkdf2 走 pbkdf2_hmac/5 带长度——本 OTP 无 /4；hash_hkdf 手写 RFC 5869 extract+expand——本 OTP 无 :crypto.hkdf）；json_validate（null 命中 php8.4 弃用警告）；tokenizer（token_get_all/token_name，@token_ids 是 php -r 探针转储的 100 个真实 T_* id——T_ECHO=291 等，单行 "<?php " 开标签前置、T_VARIABLE 补 $ 前缀；FILTER_*/INPUT_*/PHP_SESSION_*/T_* 常量入 ConstEval）；filter（VALIDATE 核+SANITIZE 核，min_range/max_range/default 选项）；Core 杂项（strncasecmp/class_alias 结构拷贝/get_class_vars/trait_exists/enum_exists/get_declared_*/get_defined_vars/gc_*/get_included_files/user_error）；spl 信息件（spl_classes/class_parents/class_implements 传递闭包/iterator_to_array/count 走 dt_state arr）；session 面桩（session_start→true+空 $_SESSION，session_status=1）；classes/spl.ex 给 ArrayObject/ArrayIterator 补 traversable+serializable 接口（class_implements 闭包对齐 php 5 接口集）+ Table 注册 Serializable 原生接口；差分 37 全同；825 测试 0 败；phpt 353<基线363 门禁 PASS；**顺延**（deferred.md B6）：func_get_args 变参顺序（[1,3,2] vs php [1,2,3]，call.ex 变参扁平化）、class_alias→declared_interfaces interp 线程化交互（登记待查）、token_get_all 非 key 类别（T_INLINE_HTML/T_CLOSE_TAG/T_NUM_STRING）、SANITIZE 弃用过滤器、session 真存储（C 相 ETS/Redis）、preg_replace_callback_array
- [x] **B7 bcmath+gmp+session+readline（2026-09-27 完成，`8f52136`）——PHASE B 收官**：新模块 `BcmathFns` 14（缩放整数引擎；scale 向零截断不四舍五入、bcmod 截整、bcpow 全量缩放幂、bcscale 返回旧值走 ini、bcround 接 RoundingMode 8 模式逐字节验证）；新模块 `Classes.NativeEnums`——RoundingMode 纯枚举 8 case，**惰性物化**（首触 ::case/cases() 才分配单例，php 同语义，07_dump 的 #N 计数差分当场抓获开机物化回归；per-request 物化天然 fork 安全）；新模块 `Classes.Gmp`+`GmpFns` 51（Elixir 整数作 GMP 基底；GMP 对象=句柄+num 属性串；运算符重载挂 apply_binop 且**只在真对象参与时启用**（首版劫持 int+int 全炸、assign_op 缺 {:ok,v,interp} 分支裸元组漏进属性——两枚回归均被门禁当场抓获）；setbit/clrbit 穿透共享句柄；探针钉死 div_q 截断/% 随除号/无穷二补数位运算/popcount(-n)=-1/gmp_intval=sign×(|n| mod 2^62)/export 字内小端/gcdext 字符串键 g,s/t）；新模块 `SessionFns` 23 取代 B6 桩——**真文件会话**（sess_<id> 文件+key|serialize 线格式，往返与跨进程持久化字节级一致）；$_SESSION 启动前未定义（修正桩的预播种）；启动前有输出即 headers-sent 拒绝；重复 start=Notice+true 带首启位置；encode 在 started-closed 后静默 false（从未启动才警告）；Finalize 在用户 shutdown 前写盘；`ReadlineFns` 11（readline_list_history 故意不注册——本地 libedit 构建无此函数，function_exists 差分优先）；差分 38 全同；825 测试 0 败；phpt 353<基线363 门禁 PASS；**顺延**（deferred.md B7）：php 对象 id freelist 回收、GMP 随机流、null 弃用警告、自定义 session handler 分派、交互式 readline
- 验收：每模块 ext/*/tests 目录纳入 harness（基线 `--record` 重建后只许收缩）；`docs/matrix/matrix_gaps.txt` 对应段清零；Carbon 核心测试抽样（原 L4 验收并入）

### PHASE C：T2 BEAM 原生等价

- [x] **C1 zlib+zip+Phar（2026-09-29 完成，`2649564`+`497faf8`）**：`ZlibFns` 30——encoding 参数=zlib windowBits 直通（-15/15/31），一次性编解码与 php **字节级一致**（hex 差分钉死）；增量上下文（deflate_init/add、inflate_init/add）持真 :zlib 端口，safeInflate 的 complete=php Z_STREAM_END；gz 文件族全内存游标；**写路径真增量流**——gzwrite NO_FLUSH 累积、gzclose SYNC+FINISH（php 的 00 00 FF FF+final 块尾迹 cmp 一致）；`ZipArchive`（open 错误码 ER_NOENT=9/CREATE/EXCL、tombstone delete——numFiles 不变槽访问 false、close 压实（探针钉死）、props 经 {:string,小写} 槽形同步）+ 旧 zip_* 10（全函数 Deprecated 警告精确文案）+ libzip 1.11.2 常量表；`PharFormat`——按 php-src phar.c 逐字段解析（manifest/entry/SHA-256 GBMB 签名校验/gz 条目）+ `PharArchive` 四类读路径 + **phar:// compress.zlib:// zip:// 三包装器**（file_get_contents/filesize/md5_file/sha1_file 新增并接包装器）；:zip 互操作 charlist + :zip_file 元数无关匹配；差分 39/40 全同；825 测试 0 败；phpt 348<基线363（harness 接 SKIP_SLOW_TESTS=1 对齐 run-tests.php -m，func/010 慢测按其自带 SKIPIF 显式跳过）；**顺延**（deferred.md C1/C1c）：Phar 写路径物化、PharData tar/zip 写、alias 全局注册表、fopen 流式 phar://、bz2 条目
- [x] **C2 openssl 核心+X509+http(s)://（2026-09-30 完成，`55bc435`）**：新模块 `OpensslFns`——对称密码族（aes cbc/ctr/gcm/ofb/cfb 全家，**字节级对齐**（crypto_one_time 要按 key 长度选 cipher atom 的坑探针钉死，PKCS7 手写））；RSA 族以 DER record 为规范键形（PKCS#8 PrivateKeyInfo 解包=OTP der_decode 直给 key record、sign/verify 参数序 (Msg, DigestType, Key) 均探针发现）；**openssl_sign 签名与 php 生成的 512 位 fixture 逐字节相等**、verify 1/0 对齐；加密对（public/private × encrypt/decrypt）round-trip；by-ref 输出参数走引擎 refs+[1]+skip_eval_refs 通道（不触发 php 不发的未定义变量警告，write_back 按位取值）；X509 read/parse/export/fingerprint/verify/check_private_key（:otp 模式 record 是元组非 map、RDN 双值形、utcTime 裸 charlist、Map.get 默认值总求值的 Enum.join 崩点全探针钉死）；pkey 族（get_private/get_public/export/get_details——n 与 php 逐字节一致）；常量全探针（OPENSSL_ALGO_SHA256=7 非猜测）；`http(s)://` 流包装器（:httpc/:ssl 全读，真网双引擎实测一致；verify_none 差异登记）；差分 41 全同（php 自生成的固定密钥对+签名+自签证书 fixture 内嵌）；825 测试 0 败；phpt 348<基线363 门禁 PASS；**顺延**（deferred.md C2）：seal/open by-ref 数组、CSR/PKCS7/CMS/PKCS12、purposes 表、export 口令加密、https 对端校验+流式、cipher 名单全集
- [x] **C3 sockets 37（2026-09-30 完成，`1b3202c`）**：新模块 `SocketsFns`——首版 :socket NIF **死锁整个 VM**（accept/recv 阻塞调度器；spawn 包装又遇 socket 属主被收割），改 **:gen_tcp/gen_udp**（receive 语义天然异步）后全通；create 惰性（bind/connect 时物化句柄——php 裸 fd 无对应物）；create_listen(0) 惰性端口；同进程 connect/accept/write/read 回环**字节级对齐**（binary read 到 len、NORMAL_READ 遇 \n/\r 停并修剪、EOF 返 ""）；socketpair 走 unix 域临时路径；by-ref 输出（getsockname/getpeername/recv/recvfrom/create_pair）走 refs+skip_eval_refs 通道；:inet.sockname 返回 {{a,b,c,d},port} 元组（map 访问崩点）；strerror 内嵌探针 macOS errno 表（11=Resource deadlock avoided）；154 常量 php 转储生成；socket_create(9999) 抛 php 精确 ValueError；差分 42 全同；825 测试 0 败；phpt 348<基线363 门禁 PASS；**顺延**（deferred.md C3）：select、recvfrom 精确写回、addrinfo/cmsg 族、INET6/raw、per-socket errno
- [x] **C4 curl 33（2026-09-30 完成，`c40b0e9`）**：新模块 `CurlConsts`（**679 常量 php 转储生成**——module attribute 先定义后使用的 nil 陷阱钉死）+ `CurlFns` 与 CurlHandle/Multi/Share/CURLFile 类——exec 双路径（file:// 原生读/ENOENT→errno 37 带路径的实例消息 vs strerror 表文案两套探针文案、http(s):// 走 :httpc GET/POST/headers/timeout/SSL 映射）；RETURNTRANSFER 与直写双形态；errno/error/getinfo 核心键/reset/copy/escape(RFC3986)/version（钉死本机 libcurl 8.11.1 字段）；multi 顺序执行（独立请求输出等价）+ share 桩；差分 43 全同；825 测试 0 败；phpt 348<基线363 门禁 PASS；**顺延**（deferred.md C4）：重定向链、认证、写回调、getinfo 全表、真并发 multi、CA bundle
- [x] **C5 ftp 36（2026-09-30 完成，`d47755e`）**：新模块 `FtpFns`——:ftp 二进制模式全命令面（pwd/chdir/mkdir/put/get/fput/fget/nlist/rawlist/mlsd/pasv/raw…）；**:ftp.open 链接 gen_server 会拖死解释器**（不可达主机 internal exit）——spawn 隔离+超时等待；探针对齐失败语义（IP 字面量拒连**静默**、DNS 失败发 php getaddrinfo 文案）；FTP\Connection TypeError 面；差分 44 全同；**顺延**（deferred.md C5）：ftp:// 包装器、size/mdtm、真异步 nb_*、TLS、真服务器往返
- [x] **C6 xml 族核心（2026-09-30 完成，`711933e`）**：`XmlTree` 共享内核（xmerl 13 元元组按位解构、**畸形输入以 EXIT 信号抛出**——spawn 隔离扫描、php 形渲染含 asXML 尾换行、expat 行 walker 单次反转为文档序、xpath 子集）；`XmlFns` expat 层——xml_parse_into_struct **字节级一致**（大写 tag、attributes 先于 value 键序、索引 map；**输出在 refs[2,3]**——错位时把垃圾喂进 xmerl 杀了 VM）；SimpleXML（__get 子元素访问/重名 sibling 集 count+索引+foreach 走 Iterator 协议/ArrayAccess 属性读/asXML/三连坏解析警告链）；DOM 九类（loadXML/saveXML/createElement/getElementsByTagName/属性 shim 走 __get/**appendChild 带 doc 回写**——wrapper 持 doc_ref+replace_deep）；**引擎修复**：cast eval 传陈旧 interp（__get 建的对象在新注册表——(string)$d->child 崩）；mix.exs 补 xmerl/inets/ssl/ftp 依赖（escript 此前没带 xmerl）；差分 46 全同；825 测试 0 败；phpt 348<基线363 门禁 PASS；**顺延**（deferred.md C6）：XMLWriter/XMLReader、变异回写全集、xpath 谓词、CDATA/NS
- [x] **C7 posix 40（2026-09-30 完成，`2b7655a`）**：新模块 `PosixFns`——进程身份（getpid/ppid——:os.getpid/1 跨 OTP 整数/字符串双形；uid/gid 缓存 shellout）、uname/getcwd/getlogin、macOS errno 表（strerror(0)="Undefined error: 0"）、kill(sig0=ps 存在性探测)、会话查询、pwuid/pwnam 走 dscl（**grnam 数组键序 members 在 gid 前**——探针钉死）、getgroups、access（**目录 R_OK 读作存在性**——File.read 目录是 eisdir）、mkfifo、times/rlimit/sysconf 近似；差分 45 全同；**顺延**（deferred.md C7）：身份切换桩、真 TTY 探测、rlimit/sysconf 全表
- 验收：`composer self-update`/`composer require` 在 phpbeam 下真实跑通（C1+C2+C4 的综合验收）

### PHASE D：T3 外部客户端

- [x] **D1 PDO+pdo_mysql（2026-09-30 完成，`82791e1`）**：新模块 `Classes.Pdo`（PDO/PDOStatement/PDOException）——MyXQL 连接（unlink 存活）；prepare/query/exec、命名参数→`?` 改写+顺序表（**php 全部绑定值字符串化**——int 1 传 "1"）；fetch 族（ASSOC/NUM/BOTH 交错序）、rowCount（SELECT=缓冲行数、UPDATE 走 nil-columns Result 的 num_rows 臂）、lastInsertId 字符串、事务、quote 反斜杠转义；**MyXQL 协议坑一次排清**（query/prepare 2 元组 vs execute {:ok,Query,Result}——Result 感知 unwrap；DDL/USE 被二进制协议拒→query_opts 走 text 协议且 options 在**第 4 参**）；PDOException 带 php SQLSTATE 标题（1146→Base table or view not found:）；差分 47 对 **docker 真 MySQL 8.0.46 字节级一致**（版本/双参型 prepare/DML+lastInsertId/事务可见性/UPDATE rowCount/quote/缺表异常文案）；825 测试 0 败；phpt 348<基线363 门禁 PASS；**顺延**（deferred.md D1）：FETCH_OBJ 族、ERRMODE 切换、by-ref bindParam、DSN 变体、持久连接
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
