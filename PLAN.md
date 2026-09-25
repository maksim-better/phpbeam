# phpbeam — 待办计划（2026-09 落盘）

状态快照：phpt 273/697 · 差分 20/20 · WP 内置频次覆盖 93% · wp-load 带真库 exit 0（`704a7d5`）。

## M23（已完成，`2026-09-25`）

- [x] **Zend 回归根因修复**：`do_bind_params` 错误路径把 `{{:unwind,...}, interp}` 塞进 `{binds, interp}` 第二位，`call_function`→`push_frame` 必崩。`bind_params` 改带标签返回（`{:ok, binds, vals, interp} | {{:unwind,u}, env, interp}`），四个调用点传播。
- [x] 附带修复（同族）：实参表达式抛出穿透（`spread_args` 停止折叠曾混入 unwind 元素）、数组字面量元素抛出穿透（`array_pairs`）、`call_constructor` 丢 env/interp 的裸 2 元组、`is_callable($closure)` 因元数漂移恒 false。
- [x] **ArgumentCountError 全面对齐 php 8.4**：精确消息（`Too few arguments to function C::m(), 0 passed in file on line N and exactly|at least k expected`，闭包名 `{closure:file:line}`，定义类命名）、异常 file/line 指声明处（函数/方法/闭包/类声明文件已入库）、未捕获 trace 逐字节一致。新增差分 `test/cases/20_arg_count.php`。
- [x] Zend 抽样护栏：`test/phpbeam/zend_sample_test.exs`（确定性 199 例抽样，`--only zend`，阈值 0.12）；实测 12.6%（修前基线 ~11%）。
- 已知残留（非本族）：抽样中 8 例引擎崩溃在 yield 生成器（gh18581 等）、`__NAMESPACE__`、nullsafe `new $x?->y`、attributes 家族。

## M24：WordPress install 实测（进行中，`2026-09-25`）

- [x] **引擎修复大丰收（15+ 处，全部 php 探针/源码实证）**：MyXQL 默认 prepare 协议拒 `USE`（改 `query_type: :text` 走 COM_QUERY，M20 遗留）；`__get`/`__set` 重入守卫（同对象同属性不二入，php 语义——WP wpdb 全靠它）；`$GLOBALS['k']=v` 写穿到真实全局槽（wp_cache_init 靠它）；嵌套属性写 `$obj->p[$i][$j]=v` 走递归 read-modify-write（曾把整个 env 搞丢）；写上下文静默自动装配（quiet_read）；`str_replace` 空搜索串原样返回 + `&$count` 计数写回（_deep_replace 曾死循环）+ refs 写回线程化 env（函数作用域曾丢）；可调用数组 `[obj,'m']`（M5 占位终结）；匿名类（`父类@anonymous\0文件:行$序号` 命名精确）；调用尾随逗号（php 7.3+）；STDIN/STDOUT/STDERR 可写流（STDOUT→输出缓冲、STDERR→真实 stderr 即时可见）；display_errors ini 生效；define() 重定义警告+保留原值+返回 false；wp_timezone 内置摘除（WP 自定义被劫持）；命名空间函数定义注册 `ns\name`；array_fill_keys；PHP_SAPI 族常量。
- [x] **wp-load 带真库完整 exit 0**（1.4s，php 0.2s）；install.php 差分推进到 wp-settings:273。
- [ ] **硬墙：生成器（yield）**——WP html-api 遍地用（class-wp-html-tag-processor.php:1246 等），不实现则 install 页出不来。即 M25 的核心工程（新执行模型构件）。
- [ ] 待收尾：install.php 差分对齐（含 translations API 网络数据——考虑离线固定 fixture 或过滤）、向导 step 模拟建表。
- [ ] 顺带发现的缺口（低危，排队列）：函数/类顶层声明提升（php 编译期 hoist）；动态属性 Deprecated 警告（需 error_reporting 分级过滤配套，否则反而多话）；`explode('')` 应 ValueError；null 方法调用 Error 应可 catch（现为引擎 fatal）。
- 差分：21_m24_engine.php（byte 级一致）；phpt 273→274/697。

## M25+：按价值排序的队列

- [ ] Zend 抽样残留崩溃族：yield 生成器（M25+ 大块）、`__NAMESPACE__` 常量、nullsafe `new` 解析、attributes
- [ ] 剩余 phpt 桶：`{:badkey, :statics}` 崩溃族（4 用例）、ob_start 缓冲重用 Fatal（3）、func/005 族
- [ ] SPL 迭代器（ArrayObject/Iterator——WP 遍处用）、session、date 完整格式化矩阵
- [ ] **生成器（yield）**——需要新的执行模型构件，语言核心最后的大块
- [ ] Reflection API（WP 调试路径）
- [ ] error_handler 真分派、ErrorException、set_exception_handler
- [ ] PDO（在 mysqli/MyXQL 之上）、filter、mbstring 完善
- [ ] parser 严格性：`f(...$arr, $x)`（unpack 后位置参数）php 是编译错误，我们放行

## 远期（架构级）

- [ ] PHP → Elixir AST 编译后端（README 路线图原定终点；树遍历慢 1~2 数量级）
- [ ] Plug 每请求一 BEAM 进程 Web 运行时

## 环境备忘

- MySQL 容器：`docker start phpbeam-mysql`（8.0，wp_test/wp/wppass，127.0.0.1:3306，native_password）
- hex 仓库被网络 TLS 挡——依赖走 git（mix.exs 注释有说明）
- 复现/追踪脚本：`/tmp/z1.php`（Zend func_num_args 用例）、`/tmp/dz.exs`
