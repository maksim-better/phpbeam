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
