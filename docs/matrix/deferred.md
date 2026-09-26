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
