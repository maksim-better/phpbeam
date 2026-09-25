# phpbeam — 待办计划（2026-09 落盘）

状态快照：phpt 273/697 · 差分 19/19 · WP 内置频次覆盖 93% · wp-load 带真库 exit 0（`704a7d5`）。

## M23（进行中，最高优先）

- [ ] **修复 Zend 回归根因**：`push_frame` 收到 `{{:php_throw, _}, %Interp{}}`——某个调用点把 eval 的 unwind 结果元组当 interp 下传。高度指向 `dispatch_ho` 的 `func_get_arg`/`func_num_args` 分支（`fn_context → native_throw` 链，eval.ex:1487 一带）。一条 grep + 十行阅读可终结。
- [ ] 修复后 Zend 抽样复测（基线 11%），把 Zend 抽样加进回归护栏（每里程碑跑一次）
- 附带已修：`spread_args` 的 nil env/interp 泄漏（`704a7d5`）

## M24：WordPress install 实测

- [ ] Docker MySQL（容器 `phpbeam-mysql`，库 wp_test）建 WP 表，跑 `wp-admin/install.php`
- [ ] 安装向导第一步走 wpdb `query()/insert()` 全链路，检验 MyXQL 路径的真实负载
- [ ] 差分对比安装页输出

## M25+：按价值排序的队列

- [ ] 剩余 phpt 桶：`{:badkey, :statics}` 崩溃族（4 用例）、ob_start 缓冲重用 Fatal（3）、func/005 族
- [ ] SPL 迭代器（ArrayObject/Iterator——WP 遍处用）、session、date 完整格式化矩阵
- [ ] **生成器（yield）**——需要新的执行模型构件，语言核心最后的大块
- [ ] Reflection API（WP 调试路径）
- [ ] error_handler 真分派、ErrorException、set_exception_handler
- [ ] PDO（在 mysqli/MyXQL 之上）、filter、mbstring 完善

## 远期（架构级）

- [ ] PHP → Elixir AST 编译后端（README 路线图原定终点；树遍历慢 1~2 数量级）
- [ ] Plug 每请求一 BEAM 进程 Web 运行时

## 环境备忘

- MySQL 容器：`docker start phpbeam-mysql`（8.0，wp_test/wp/wppass，127.0.0.1:3306，native_password）
- hex 仓库被网络 TLS 挡——依赖走 git（mix.exs 注释有说明）
- 复现/追踪脚本：`/tmp/z1.php`（Zend func_num_args 用例）、`/tmp/dz.exs`
