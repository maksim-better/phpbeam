# 顺延登记（deferred.md）— 时间盒超时/超出当前里程碑的项

规则：引擎 bug 时间盒 2h 超时登记于此；顺延 ≠ 豁免（豁免走 exempt.md），会话末清理。

## A1 错误协议（2026-09-26 PHASE A1 收尾登记）

- [ ] **E_STRICT 常量访问弃用警告**：php 8.4 `var_dump(E_STRICT)` 先打 `Deprecated: Constant E_STRICT is deprecated in file on line N` 再出 int(2048)；const_eval 常量子句无 interp 线程化，需在常量求值调用点对 "E_STRICT" 特判补一条 warn_level（探针已钉：/tmp 探针与 probe_a1_1 diff）
- [ ] **闭包 var_dump 全量渲染**：php 输出 `object(Closure)#N (4) { ["name"]=> "{closure:file:line}" ... ["parameter"]=> array }`（无参闭包 3 属性）；需要闭包进对象注册表拿稳定 #N 编号（与 new Foo 的编号共用序列），是架构决策——render.ex:80 兜底 "object" 挡着
- [ ] **assign 写路径 warn 位点的 handler 派发**（assign.ex ~103/123 的 `{env, interp}` 契约、~805/817 字符串写助手纯函数返回字符串）：函数签名表达不了 unwind；handler 在属性赋值/字符串偏移写警告时抛异常将不传播（仅显示路径不受影响）
- [ ] **read_target 的 handler 派发**（assign.ex:140 `&$x`/复合赋值 `$a += ...` 的未定义变量警告）：6 个复合赋值调用方需一起改返回形状
- [ ] **链接期警告的 handler 派发**（enums.ex:17、classes/table.ex:598/607 类注册期警告）：php 语义上该走 handler，当前仅输出

## A1 顺延已修（登记后当场解决，留档）

- [x] **箭头函数自动捕获**（fn() => $x 引用外层变量返回 NULL——既有 bug，A1c 修：eval.ex 闭包创建时自由变量按值捕获，list/tuple 递归遍历）
- [x] **链式调用 $f()()**（普通/箭头闭包皆 `unsupported call target` Fatal——既有 bug，A1c 修：do_call 通用臂「任意表达式求值后作调用目标」）

## H0 顺延（2026-09-26 迁入）

- [ ] short_tags×4（--INI-- 管道，A2 INI 层落地后可解）
- [ ] unset_properties（__get/__set 重入死循环）
- [ ] property_override 系（protected 属性跨类访问链）
- [ ] lang/028（析构次序）、bug21600（引用赋值 Notice）、serialize_001、autoload_012/021
- [ ] 返回引用真语义（数组共享）、default+endswitch 残角、invalid_octal/71897 措辞

## B4 顺延（2026-09-26）

- [ ] **方法/函数返回类型的反射**（ReflectionMethod::getReturnType 有值）：parser 的 `return_hint/1` 目前丢弃返回类型（只返回剩余 token）——需给方法/函数元组加 ret 字段（parser 3 处调用点 + Table methods_map + eval 调用执法可选强化），影响面大单独做
- [ ] ReflectionFunction 的 invoke（闭包/具名真调用）、getClosure、getFileName/getStartLine/getEndLine（需 def_site 线程化）
- [ ] ReflectionGenerator/Fiber/Reference/Extension/ZendExtension 为空壳类（php 有方法但 Laravel 不用）
- [ ] ReflectionEnum 的 getCases/backed case getValue 需 enum 常量物化通道

## B3 顺延（2026-09-26）

- [ ] **array_uintersect_assoc 键-值联合匹配的 php 精确语义**：php 对 [0=>1,1=>2]∩[9,2] 保留 1=>2（键等值 + 回调值匹配的组合判定里有 slot 语义）；我们简单实现返回空——回调在同一 interp 快照下重评测（inline 箭头函数）路径疑有 stale-env，需查 call_cb_raw 的 AST 闭包重评测
- [ ] array_multisort 完整语法（多列联动排序 + SORT_ASC/DESC/SORT_NUMERIC/STRING 标志位 + 多数组引用写回）；V1 只排序首数组并重编号

## B2 顺延（2026-09-26）

- [ ] **mb_ereg\* 全家族 11 函数**（mb_ereg/eregi/ereg_replace/eregi_replace/ereg_replace_callback/split/match/search\* 7 个/regex_encoding/regex_set_options）——多字节正则引擎（Oniguruma 语义），可先桥 :re + /u 的 UTF-8 模式（PCRE UTF 模式与 Oniguruma 边缘语义差异需差分护住）
- [ ] mb_convert_kana（假名互转表）、mb_send_mail（mail 通道）、mb_convert_variables（多变体 ho 引用写回）
- [ ] **iconv //TRANSLIT 精确表**：libiconv 的 latin1→ASCII 表把 é 转成 'e（撇号+e），我们的 NFD 剥离给 e；差分用例已绕开 //TRANSLIT 断言
- [ ] mb_parse_str 当前恒 false（需要 ho raw-args + 引用写回，A3 的 context 通道可复用）

## B1 收尾顺延（2026-09-26）

- [ ] **DatePeriod foreach 迭代**：展开日期为整数键属性后，find_prop（table.ex）对整数键抛 case_clause（属性机器假设字符串键）；需在 B5 Iterator 协议时统一（构造/存储已工作）
- [ ] createFromFormat 全说明符（现支持 Y y m d H i s + 字面量；缺 a A g G n j u v U D l N w S F M e O P T + ! | # 语义）
- [ ] DateTime::getLastErrors 明细数组（warning_count/warnings/errors）
- [ ] timezone_abbreviations_list、date_sun_info、date_isodate_set、date_parse

## B5 顺延（2026-09-26）

- [ ] SplStack/SplQueue foreach 第二轮迭代中断（第一轮正确；疑 next() 写回后 iter_call 取到陈旧 obj）
- [ ] SplFixedArray 经引擎 `$fa[0]='x'` 写丢失（直接 `->offsetSet(0,'x')` 工作正常——engine generic_index_assign 的 ArrayAccess 写路径对 native 方法结果丢弃待查）；`$fa[0]` 直读同源问题
- [ ] SplHeap 用户 compare() 排序方向、SplPriorityQueue 全差分、SplFileInfo 相对路径/splFileObject 行读取族、SplObjectStorage serialize/var_export、ArrayObject flags(STD_PROP_LIST/ARRAY_AS_PROPS 影响)

## B6 顺延（2026-09-26）

- [ ] func_get_args 变参元素顺序：`function t($a, ...$r) { t(1,2,3) }` 我们返回 [1,3,2]，php [1,2,3]——call.ex 的变参展开序（engine_ho 域）
- [ ] class_alias 后同表达式内 get_declared_interfaces() !== [] 返回 false（单独语句正常——同类逗号求值交互，疑 interp 线程化的残余；登记待查）
- [ ] token_get_all 的 T_INLINE_HTML/T_CLOSE_TAG/T_NUM_STRING 等非关键字 token 类别按需扩；FILTER_SANITIZE_STRING 等废弃过滤器未做
- [ ] preg_replace_callback_array 未实现（桩返回 false）
## B7 顺延（2026-09-27）

- [ ] **GMP 对象 id 回收**：php 的 zend 对象 freelist 会复用已销毁对象的 #N 编号（两次 catch 释放后 gmp_init 复回 #1 实测）；我们 next_obj 单调递增——仅影响 var_dump/debug_zval 里的 id 可见输出，B7 差分用例已用无 id 探针绕开
- [ ] gmp_random_bits/range/seed 用 :rand 源（GMP 的 Mersenne randstate 流未复刻）——随机值与 php 不同，仅格式/边界可差分
- [ ] gmp_strval/gmp_add 等内部参数收 null 时的 `Deprecated: Passing null` 警告未发（php 8.4 弃用语义）；gmp_scan 越过幅值位的返回值为 idx 而非 GMP 的 ULONG_MAX 语义
- [ ] readline_list_history **故意不注册**（本地 php 为 libedit 构建无此函数，function_exists 差分一致优先；GNU readline 构建有）——真实 GNU 构建兼容时再补
- [ ] readline 交互式行读取（TTY 回显/补全回调触发/completion callback 实际调用）未做——非交互 EOF 语义已差分；readline_completion_function 的回调校验消息为 libedit 特有文案
- [ ] session 自定义 save handler（对象/闭包形）接受但不分派，恒走 files 后端；session.gc_probability 自动 GC 未建模（手动 session_gc 按 mtime 扫描工作）；session_start 的 options 数组仅实现 read_and_close
- [ ] bcpowmod 模 0/bcsqrt 负数等 ValueError 文案按文档推断未逐一探针；bcround 的 RoundingMode 参数传入非枚举对象时的 TypeError 文案为近似
- [ ] 未定义数组键警告的键渲染：整数键我们渲染 `"0"`（带引号），php 渲染 `0`——gmp_gcdext 探针暴露，属引擎既有键渲染差异
## C1 顺延（2026-09-29 zlib+zip 首批）

- [ ] gz 文件族的 gzpassthru 写模式下行为（读模式差分已对齐；php 写模式下 passthru 未探针）
- [ ] deflate_add 在 finished 上下文上再调用（php 警告文案已按探针对齐，但同上下文重复 add 的警告序未差分）
- [ ] gzopen 模式串的 h（hex）/f（filter）修饰与 use_include_path 第三参
- [ ] ZipArchive 条目压缩方法恒 stored（:zip 不写 deflate 成员；statIndex 的 comp_method/comp_size 近似）；增量 addGlob/addPattern/replaceFile、加密（setEncryptionName）、进度回调（registerProgressCallback）、外部属性族未做
- [ ] ZipArchive 修改现有档的 append 语义（open(现有) + addFromString 时旧条目保留已对，但 renameName 的 statIndex 细节未全探针）
- [ ] legacy zip_entry_read 的 length 参数边界（默认全读已对齐；部分读未探针）
## C1c Phar 顺延（2026-09-29）

- [ ] Phar 写路径（offsetSet/addFromString 后的落盘物化）受 phar.readonly 门但未接 Finalize——差分侧 php 默认 readonly=1 无法对拍，composer 实测时补
- [ ] PharData 的 tar/zip **写**路径（读路径 :erl_tar/:zip 全通）；convertToExecutable/convertToData、压缩（compressFiles GZ）桩
- [ ] mapPhar/loadPhar 的全局 alias 注册表（跨对象 phar://alias 解析）、webPhar/mungServer/mount（SAPI 相）、buildFromDirectory/buildFromIterator
- [ ] phar:// 的 fopen 流式（当前 file_get_contents/md5_file/filesize/file_put_contents 无读、readfile 全读已接；fopen+fread 细粒度未接）
- [ ] Phar::running() 对 CLI 入口 phar 的真值（恒返回 phar://main——未按 .phar 后缀分支，差分未覆盖）
- [ ] bz2 条目（PHAR_ENT_COMPRESSED_BZ2）：本 OTP 无 :bzip2
- [ ] harness：SKIP_SLOW_TESTS=1 对齐 run-tests.php 的 -m 慢测开关（func/010 的 16K 参绑定单跑 4.1s/门禁并行贴线——不是回归，官方 skip 探针本就为此设计）
## C2 顺延（2026-09-29/30 openssl + https）

- [ ] openssl_seal/open 的 &$sealdata/&$envkeys/&$decryptedkeys 数组 by-ref 输出（ho 通道待接）；当前 seal 返回密文不写回
- [ ] CSR 族（openssl_csr_new/sign/export）与 PKCS7/CMS/PKCS12/SPOP（SPKI）桩；openssl_dh_compute_key/pkey_derive 未做
- [ ] X509：purposes 数组为恒真近似（php 随证书/CA 状态变）；signatureTypeNID 恒 65；serialNumber 大数 hex 形态；x509_checkpurpose 桩
- [ ] openssl_pkey_new 密钥参数（bits/type/config 数组）与 export 的 passphrase 加密（:public_key 无 PKCS 加密 PEM——需 :crypto 手写）；pkey_get_details 的 dmp1/dmq1（OTP record 有 dp/dq ✓ 但 qinv=coefficient 映射未差分）
- [ ] https:// 包装器：verify_none（php 默认 verify peer——CA bundle 校验待 C 相接 public_key:cacerts_load）；仅 file_get_contents 全读（fopen 流式/headers/POST 未接，归 C4 curl 时统一）
- [ ] openssl_get_cipher_methods 名单为子集（php 200+；核心 aes 家族齐）；md_methods 别名表子集
- [ ] openssl_error_string 恒 false（无错误队列模型）；openssl_random_pseudo_bytes 的 &$strong_result 未写回
## C3 顺延（2026-09-30 sockets）

- [ ] socket_select 三数组 by-ref（tv_sec/tv_usec 微秒语义）；recvfrom 的 &$name/&$port 精确写回（当前部分写回）；recv 的 flags（MSG_PEEK/WAITALL 位）
- [ ] socket_create 的第 3 参 protocol 校验与 AF_INET6（:inet6 未接）；SOCK_RAW/RDM/SEQPACKET（gen_tcp 仅 stream）
- [ ] socket_import/export_stream（与 php:// 流互转）；addrinfo_* 族（:inet.getaddrinfo 映射）；cmsg/sendmsg/recvmsg（控制消息）；atmark
- [ ] set_block/nonblock 桩恒 true（gen_tcp 无 per-call 非阻塞；select 模型需 active once）
- [ ] socket_write 的 MSG_OOB/DONTROUTE flags 第二参；SO_LINGER setopt（gen_tcp 关闭语义近似）
- [ ] socket_last_error 恒 0（无 per-socket errno 追踪——errno 在各失败分支吞掉未记录）
## C4 顺延（2026-09-30 curl）

- [ ] http(s) 请求面：FOLLOWLOCATION/重定向链、PUT/DELETE（CURLOPT_CUSTOMREQUEST）、HTTPHEADER 精确大小写回传、CURLOPT_USERPWD/BASIC 认证、CURLOPT_WRITEHEADER/HEADER 回调、COOKIEJAR（composer 需要——C 相后续）
- [ ] curl_getinfo 的 30+ 信息键（现 URL/HTTP_CODE/EFFECTIVE_URL）；CURLINFO_* 数组形态（无参 getinfo 返回全表）
- [ ] multi 族的真并发（现为顺序执行——独立请求输出等价；共享句柄状态/PIPELINING 无）、multi_select 的 select 语义、multi_info_read 队列
- [ ] CURLOPT_FILE/INFILE（流写读）、CURLOPT_RETURNTRANSFER=false 的直写已做但 file:// + http 混合边界未差分；curl_share 的真共享（cookie/dns）
- [ ] CURLOPT_SSL_VERIFYPEER=true 的 CA bundle（:public_key.cacerts_load 接入——与 https:// 包装器同一债）
- [ ] curl_version 的 features 位与 ares 版本等跟随本机 libcurl 硬编码（跨机器差分需再探针）
## C5 顺延（2026-09-30 ftp）

- [ ] ftp:// 与 ftps:// 流包装器（read_wrapper_uri 接 :ftp 会话生命周期——与 phar:// 同形扩展）
- [ ] ftp_size/mdtm（:ftp 无 stat 协议命令映射——现恒 -1）；ftp_mlsd 的 MLST facts 全集（type/size/modify/perm/unique/unix.*）；rawlist 的 LIST 格式差异
- [ ] ftp_nb_* 的真异步（现同步执行返 FINISHED=1）；ftp_exec/site/chmod 的 SITE 命令（:ftp.send_cmd 透传待真服务器验证）；ssl_connect 的 TLS（:ftp ssl 选项）
- [ ] 真实 FTP 服务器差分（本机无 server——proftpd/vsftpd 起桩后补 get/put/rawlist 往返用例）
## C7 顺延（2026-09-30 posix）

- [ ] posix_setuid/setgid/setsid/setpgid/initgroups 桩（BEAM 无进程身份切换——web 运行时相接 worker 权限时设计）
- [ ] posix_times 的 utime/stime（:erlang.statistics 的 job statistics 映射粗糙）；getrlimit 全键（硬编码 macOS 默认）；sysconf/pathconf/fpathconf/mknod 近似值
- [ ] pwuid 的 gecos 字段（dscl RealName）；getgrgid 的 members 列表（dscl GroupMembership）；ttyname/isatty 的真 TTY 检测（CLI 恒 false——管道下 php 同 false）
## C6 顺延（2026-09-30 xml 族）

- [ ] XMLWriter 42（memory 流式写——xmerl 导出侧）与 XMLReader（流式读）未实现（本轮交付 xml_parse/SimpleXML/DOM 核心；writer/reader 依需追加）
- [ ] DOM 变异穿透仅 appendChild→document（removeChild/replaceChild/insertBefore/setAttribute 的 doc 回写同模式待补）；parentNode/nextSibling 恒 null；getElementById/DOMSchema
- [ ] xpath 子集（//tag、/root/tag、[@attr]）——谓词全集（[@attr='v']、轴、text()、count）与 SimpleXML xpath 结果类型差异；DOMXPath::evaluate
- [ ] CDATA/注释/命名空间/PI 节点（strip_ws 只留 xmlElement/xmlText）；DOMText/DOMComment 拆分；实体引用解码（&amp; 等 xmerl 默认解）
- [ ] xml_parse 的分块回调（handler 族 noop）；XMLParser 的编码选项；xml_error_string 全表
- [ ] simplexml 的 addChild/addAttribute 的 asXML 回写（写 wrapper 未透 root——与 DOM append 同型）
- [ ] DOMDocument::save 的 HTML 序列化形态；formatOutput/pretty print
## D1 顺延（2026-09-30 PDO+pdo_mysql）

- [ ] FETCH_OBJ/FETCH_CLASS/FETCH_LAZY/FETCH_KEY_PAIR/FETCH_UNIQUE/FETCH_GROUP/FETCH_FUNC；setFetchMode 与类的 o construct 回调；fetchObject
- [ ] PDO::ATTR_ERRMODE 切换（默认异常模式已对齐；SILENT/WARNING 分支待需）；getAttribute 其余键（CLIENT_VERSION/SERVER_INFO/DRIVER_NAME）
- [ ] bindParam 的 by-ref 执行期绑定（bindValue 桩恒 true）；debugDumpParams 输出；columnCount 的 SHOW 形态
- [ ] DSN 形态（unix socket/charset/ssl）；持久连接（ATTR_PERSISTENT）；连接错误码细描（1045 之外的 2002/2054 等）
- [ ] PDOStatement::nextRowset/getColumnMeta/errorInfo；事务嵌套与 SAVEPOINT；MySQL 8 的 cursor 常量族
- [ ] 差分用例对 DB 的破坏性：phpbeam_test 库重建（两侧同跑安全——差分 harness 里 php 先跑 php 侧重建 ✓ 保留）
## D4 批1 顺延（2026-09-30 mysqli 40→69，批2 后 94/106）

- [ ] **bind_param 的 by-ref 语义**（批2 现按绑定时刻值快照——php 在 execute 时重读变量；需 out-vars 式执行期回读）；bind_result+stmt_fetch 组合（out_vars 已存、fetch 写回未接）
- [ ] **affected_rows/insert_id 长事务链上下文非确定性**（登记待查）：单函数多次验证正确（INSERT 后 2/1），但在 autocommit→begin→rollback→DDL 链后偶发 0/0——疑 DBConnection 池 checkout 时 text 协议 Result 形态漂移（{:ok,R} vs {:ok,R,_}）进入错误分支；差分用例已改用行数断言绕开
- [ ] fetch_object/fetch_lengths 边界；multi_query/poll/reap 异步族；warning 对象族（get_warnings/stmt_get_warnings）
- [ ] field 元数据精确化（type/flags/max_length 按协议列定义——现按首行值猜测）；error_list 的 sqlstate 全表；change_user/kill/refresh 真语义
- [ ] mysqli_result 的 Traversable（foreach 直接迭代——引擎需 resource 迭代协议）
- [ ] 常量面：MYSQLI_READ_CONSTANT/CLIENT_* 剩余；CURSOR_TYPE_*；stmt attr 常量

## D4 批2 顺延（2026-09-30 mysqli_stmt 族，94/106）

- [ ] stmt_fetch 的 by-ref 行写回（out_vars 已记录 var AST——需引擎 vars 写回通道）；execute_query（参数化单步）
- [ ] prepared 参数原生类型往返（php "si" 的 i 出 int(5)——MyXQL 字面参数列型返回串；需 server-side 类型提示或结果后cast）；result_metadata 返回元数据结果集；attr_get 常量族
- [ ] stmt 更多结果集（next_result）；store/use_result 语义差（mysqlnd 无缓冲）；send_long_data 分块
## D2 顺延（2026-09-30 sqlite3+pdo_sqlite）

- [ ] 构建链：exqlite/elixir_make/cc_precompiler 为 git 依赖（hex TLS 被网络挡）；**deps/exqlite 打了 load_nif fallback 补丁**（escript 内 priv_dir 失效时落 _build 路径——mix deps.update 会覆盖，需登记）；escript emu_args -pa 全部 _build/dev ebin（escript 不能嵌 .so）
- [ ] exqlite NIF 无 bind_parameter_name——参数名从 SQL 文本扫描（:name/顺序 ?）；:memory: 映射到 /tmp 唯一文件（NIF 每连接一文件）；BLOB/openBlob；loadExtension
- [ ] pdo_sqlite 版本钉死 3.53.4（本机 php 链的 sqlite；exqlite 内嵌 3.48）；getAttribute 其余键；sqlite 的 lastInsertId 非字符串形态（php pdo_sqlite 恒 string）
- [ ] 事务（BEGIN 文本协议）与 SAVEPOINT；FETCH_OBJ 族与 pdo_pgsql 同批
## D3 顺延（2026-09-30 pgsql+pdo_pgsql）

- [ ] **活库差分**：docker 拉 postgres 镜像被网络挡（hex TLS 同源）——失败路径已差分（连接拒绝/DNS 失败/pg_last_error 无连接 fatal）；服务器可得后补往返用例
- [ ] pg_query_params 的 equery 通道写完未活测；大对象族（pg_lo_*）桩；异步族（send_query/get_result 单值 stash 非队列）；pg_copy_from/put_line 真拷贝协议
- [ ] pg_fetch_result 的行/列参数形态；pg_convert/insert/update/delete/select（php 便捷层）；pg_meta_data 的 information_schema 查询
- [ ] PDO pgsql 驱动：连接建立（活服务器验证）+ prepare/equery 参数绑定 + pgsql 特有 ATTR（ATTR_SERVER_VERSION 等）；SQLSTATE 08006 文案按文档近似（活库后对齐）
- [ ] epgsql connect 键是 host（不是 hostname）——API 文档陷阱已注释
## 工具链（2026-09-30）
- [ ] mix local.rebar 与 hex 元数据均被 TLS 挡——MIX_REBAR3=~/.mix/rebar3 指向 brew rebar3 可绕过（已 cp 到 ~/.mix/rebar3）；gate.sh 需 export MIX_REBAR3 才能全新环境跑 deps.get
- [ ] http_test 偶发遗留孤儿 `phpx serve` 进程（占 18898/18899 端口，后续 run 全体报 Address already in use 且 mix test 挂起等端口）——测试收尾 kill 不彻底，gate.sh 非 phpt 段后已有 18899 全清扫（pkill -9 -f "phpx serve"）
## T006（2026-10-03，spec 001）

- [ ] **log_errors 的 stderr 副本通道**：log_errors=1 且 error_log 空时，php 对每条错误/弃用在显示副本之外再写一行 `PHP Xxx: message in file on line N` 到 stderr（差分 harness 只比 stdout 故 47–52 不可见；手工 2>&1 比对暴露——52_d3_pgsql）。错误协议域，Z 相 Zend 错误类用例预计踩到时一并接上（A1 的 warn 管线补 log 通道）

## 机器可读标记行（T011，2026-10-03——存量节转写，语义不变）

节级 DEFER 行：作用域=dir-id（**仅供检索的元数据，不产生 phase 容忍**——容忍只认
`case:<id>` 逐例登记，criterion.sh 执行；防少数根因放行整目录）。逐例 case: 标记
在 Z/X 分诊时随批补写；原散文节保持权威。
引擎域 = tests/{lang,strings,func,classes,basic,output} 六目录。

DEFER A1 错误协议（E_STRICT 常量/闭包 var_dump/assign 派发） | lang,strings,func,classes,basic,output | 根因: 见 A1 节 | 再入: Z 相错误协议类分诊 | 登记: 2026-09-26
DEFER H0 顺延（short_tags/unset_properties/析构次序…） | lang,strings,func,classes,basic,output | 根因: 见 H0 节 | 再入: Z 相 | 登记: 2026-09-26
DEFER B1 date（DatePeriod foreach/createFromFormat 全说明符…） | ext-date | 根因: 见 B1 节 | 再入: X1-ext-date | 登记: 2026-09-26
DEFER B2 mbstring（mb_ereg 族 11/kana/send_mail…） | ext-mbstring,ext-ctype,ext-iconv | 根因: 见 B2 节 | 再入: X1 对应目录 | 登记: 2026-09-26
DEFER B3 数组族（uintersect_assoc slot 语义/multisort 全语法） | func,basic,ext-standard | 根因: 见 B3 节 | 再入: X1 | 登记: 2026-09-26
DEFER B4 Reflection（返回类型反射/invoke/文件行号族） | ext-reflection | 根因: 见 B4 节（返回类型=深度工程，Z 相超盒拆里程碑） | 再入: X1-ext-reflection | 登记: 2026-09-26
DEFER B5 SPL（stack/queue foreach 第二轮/FixedArray 引擎写路径…） | ext-spl | 根因: 见 B5 节 | 再入: X1-ext-spl | 登记: 2026-09-26
DEFER B6 hash/tokenizer/filter（token 非键类别/废弃过滤器…） | ext-hash,ext-tokenizer,ext-filter,ext-json,func | 根因: 见 B6 节 | 再入: X1 对应目录 | 登记: 2026-09-26
DEFER B7 bcmath/gmp/session/readline（GMP id 回收/随机流/自定义 handler…） | ext-bcmath,ext-gmp,ext-session,ext-readline | 根因: 见 B7 节 | 再入: X1 对应目录 | 登记: 2026-09-27
DEFER C1 zlib+zip（gzpassthru 写模式/条目压缩方法…） | ext-zlib,ext-zip | 根因: 见 C1 节 | 再入: X2 对应目录 | 登记: 2026-09-29
DEFER C1c Phar（写路径物化/PharData 写/alias 注册表…） | ext-phar | 根因: 见 C1c 节 | 再入: X2-ext-phar | 登记: 2026-09-29
DEFER C2 openssl（seal/open by-ref/CSR 族/cipher 名单…） | ext-openssl | 根因: 见 C2 节 | 再入: X2-ext-openssl | 登记: 2026-09-29
DEFER C3 sockets（select/addrinfo/cmsg/INET6…） | ext-sockets | 根因: 见 C3 节 | 再入: X2-ext-sockets | 登记: 2026-09-30
DEFER C4 curl（重定向链/认证/multi 真并发/CA bundle…） | ext-curl | 根因: 见 C4 节 | 再入: X2-ext-curl | 登记: 2026-09-30
DEFER C5 ftp（ftp:// 包装器/size/mdtm/nb_*…） | ext-ftp | 根因: 见 C5 节 | 再入: X2-ext-ftp | 登记: 2026-09-30
DEFER C6 xml 族（XMLWriter/Reader/DOM 变异穿透全集…） | ext-xml,ext-dom,ext-simplexml | 根因: 见 C6 节 | 再入: X2 对应目录 | 登记: 2026-09-30
DEFER C7 posix（身份切换桩/TTY 探测…） | ext-posix | 根因: 见 C7 节 | 再入: X2-ext-posix | 登记: 2026-09-30
DEFER D1 PDO（FETCH_OBJ 族/ERRMODE/持久连接…） | ext-pdo,ext-pdo_mysql,ext-mysqli | 根因: 见 D1 节 | 再入: X2 对应目录 | 登记: 2026-09-30
DEFER D2 sqlite3（:memory: 映射/BLOB/构建链登记…） | ext-sqlite3,ext-pdo_sqlite | 根因: 见 D2 节 | 再入: X2 对应目录 | 登记: 2026-09-30
DEFER D3 pgsql（活库差分/equery 活测/大对象…） | ext-pgsql,ext-pdo | 根因: 见 D3 节 | 再入: X2-ext-pgsql（服务器可得时） | 登记: 2026-09-30
DEFER D4 mysqli（by-ref 执行期重读/stmt_fetch 写回/multi-async 12…） | ext-mysqli | 根因: 见 D4 批1/批2 节 | 再入: X2-ext-mysqli | 登记: 2026-09-30
DEFER 工具链（MIX_REBAR3 流程/http_test 孤儿进程…） | （构建域，无目录关联） | 根因: 见工具链节 | 再入: 持续 | 登记: 2026-09-30
DEFER T006 log_errors stderr 副本通道 | lang,strings,func,classes,basic,output | 根因: A1 warn 管线缺 log 通道 | 再入: Z 相错误协议类分诊 | 登记: 2026-10-03
