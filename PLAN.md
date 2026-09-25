# phpbeam — 待办计划（2026-09 落盘）

状态快照：phpt 273/697 · 差分 20/20 · WP 内置频次覆盖 93% · wp-load 带真库 exit 0（`704a7d5`）。

## M23（已完成，`2026-09-25`）

- [x] **Zend 回归根因修复**：`do_bind_params` 错误路径把 `{{:unwind,...}, interp}` 塞进 `{binds, interp}` 第二位，`call_function`→`push_frame` 必崩。`bind_params` 改带标签返回（`{:ok, binds, vals, interp} | {{:unwind,u}, env, interp}`），四个调用点传播。
- [x] 附带修复（同族）：实参表达式抛出穿透（`spread_args` 停止折叠曾混入 unwind 元素）、数组字面量元素抛出穿透（`array_pairs`）、`call_constructor` 丢 env/interp 的裸 2 元组、`is_callable($closure)` 因元数漂移恒 false。
- [x] **ArgumentCountError 全面对齐 php 8.4**：精确消息（`Too few arguments to function C::m(), 0 passed in file on line N and exactly|at least k expected`，闭包名 `{closure:file:line}`，定义类命名）、异常 file/line 指声明处（函数/方法/闭包/类声明文件已入库）、未捕获 trace 逐字节一致。新增差分 `test/cases/20_arg_count.php`。
- [x] Zend 抽样护栏：`test/phpbeam/zend_sample_test.exs`（确定性 199 例抽样，`--only zend`，阈值 0.12）；实测 12.6%（修前基线 ~11%）。
- 已知残留（非本族）：抽样中 8 例引擎崩溃在 yield 生成器（gh18581 等）、`__NAMESPACE__`、nullsafe `new $x?->y`、attributes 家族。

## M24：WordPress install 实测

- [ ] Docker MySQL（容器 `phpbeam-mysql`，库 wp_test）建 WP 表，跑 `wp-admin/install.php`
- [ ] 安装向导第一步走 wpdb `query()/insert()` 全链路，检验 MyXQL 路径的真实负载
- [ ] 差分对比安装页输出

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
