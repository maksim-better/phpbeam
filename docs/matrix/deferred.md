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
