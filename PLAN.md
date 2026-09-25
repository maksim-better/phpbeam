# phpbeam — 待办计划（2026-09-25 重整）

状态快照：phpt **280/697** · 差分 22/22（byte 级） · WP 内置频次覆盖 93% · wp-load 带真库 exit 0 · install.php 已穿过 Requests/PSR/ai-client/生成器现场。

进度自评：距"跑通 WordPress"约 70–75%；距"完整 PHP"为数十里程碑的长期线。北极星 = WordPress，完整 PHP = 长期回填。

## 已完成里程碑（压缩索引，细节见 git log）

- M7–M22：phpt harness、include/位置追踪、继承严格性、eval/func_get_args、serialize/游标、preg_*、resource 流、WP 引导实测、真 MySQL（MyXQL）、可见性执法两层。
- M23（830d15d）：`bind_params` 带标签返回终结 push_frame 崩溃族；ArgumentCountError php 精确；Zend 抽样护栏（199 例，阈值 0.12）。
- M24-p1（9557a5e）：引擎修复 15+ 处（MyXQL :text、__get/__set 守卫、$GLOBALS 写穿、嵌套属性写、str_replace 计数、可调用数组、匿名类、尾随逗号、STD* 流、display_errors/define 语义）。
- M24-p2（5c01ef1）：**生成器全量**（进程+interp 穿梭）；**autoload 体系**（spl 触发/ns 隔离/父类接口 trait 链接期/FQ 显示名）；**类编译期作用域**；类常量惰性折叠；__FUNCTION__ 族；stdClass；mb_*/strip_tags/addslashes。
- M24-p3（0af9883）：元素引用赋值；path_get/path_put 按段求值；`[&$x]` ref 线程化；按值参数 deref 数组 ref；realpath；method_call unwind 穿透。

## 阶段一：M24 收尾——install 页面出来（**p4 已达成主目标**，`bd85da5`）

- [x] **P0 异常**：`update_path_env` 自动装配臂返回 1 元组丢弃 interp（p3 两个哨兵都对——污染在 target 求值与 path_put 之间）。
- [x] **install.php 完整渲染 exit 0**（4983 字节完整 HTML，welcome/setup 表单页）。此轮根因链：fetch_class 返回 ns/uses 剥离后的 interp（调用方作用域现恢复）；普通函数携带定义文件 ns/uses（7 元组）并在体内切换；trait `m as x;` 裸形式解析 + 适配块后无分号 + **as 别名保留原方法**；链接期签名兼容按**解析后类型**比较；substr 越界；assign_op 宽容臂；`{:int, 非整数}` 泄漏加固。新内置：hash_*、addcslashes 族、strtok（游标）、array_values、debug_backtrace、JSON_* 常量族；原生 DateTime/DateTimeZone。
- [ ] install 页 byte 级对齐剩余三类差距：① CSS `<link>` 与部分 `<script src>` 未输出（wp_styles/wp_scripts do_items 的 src 型条目）② `wp_guess_url` 形态（php `http:///abs/path` vs 我们 `http:/relative`）③ 语言选择器需真实 translations API（网络数据，比对用 fixture/过滤）
- [ ] 向导 step 1/2 模拟（$_POST 注入）走 `wp_install()` 全链路：wpdb `query()/insert()` 建 12 张表——M24 的原始验收目标
- [ ] 安装完成后 `is_blog_installed()` → "Already Installed" 页差分
- [ ] 差分用例固化：23_install_page.php（对 step=1 包装基线，过滤 data-pw 随机密码）+ 24_install_wizard.php（建表后 SHOW TABLES 对比）
- phpt 280→**285/697**；单测+差分 784/0。

## 阶段二：M25——WP 安装后稳定性（预估 2–4 会话，深度未知）

- [ ] SPL 迭代器（WP 遍地用）：ArrayObject、ArrayIterator、IteratorIterator、RecursiveIteratorIterator（优先级按 WP 调用频次）
- [ ] session 族：session_start/$_SESSION/headers 已发判定
- [ ] wp-admin 首页/仪表盘渲染冒烟：options 页、plugins 页各跑一遍差分，缺口按频次补
- [ ] 前台（twentytwentyx 主题首页）渲染冒烟
- [ ] 长尾内置按 WP 调用频次补（当前 346+，目标随冒烟滚动扩充）
- [ ] HTTP 最小层：wp_remote_get/wp_remote_post 的 Headers/Response 对象（若走真实网络则需 fixture 策略）

## 阶段三：完整 PHP 长期线（按价值排序，数十里程碑）

语言核心：
- [ ] attributes 解析与 ReflectionAttribute（Zend 抽样 8 崩溃之一）
- [ ] 枚举（enum/backed enum/cases/match 配套）
- [ ] readonly 属性/类、first-class callable 语法 `strlen(...)`
- [ ] Fibers（协程语义，可能复用生成器进程模型）
- [ ] 函数/类顶层声明提升（php 编译期 hoist；WP 偶有依赖）
- [ ] parser 严格性：`f(...$arr, $x)` unpack 后位置参数应为编译错误

运行时与扩展：
- [ ] Reflection API（Class/Method/Property/Function——WP 调试路径）
- [ ] error_handler 真分派、ErrorException、set_exception_handler
- [ ] PDO（在 mysqli/MyXQL 之上）
- [ ] filter、mbstring 完善矩阵、date 完整格式化矩阵
- [ ] 剩余 phpt 桶：`{:badkey, :statics}` 崩溃族（4）、ob_start 缓冲重用 Fatal（3）、func/005 族
- [ ] Zend 抽样残留：nullsafe `new $x?->y` 解析、`__NAMESPACE__` 边角

低危队列（随手修）：
- [ ] 动态属性 Deprecated 警告（需 error_reporting 分级过滤配套，否则反而多话）
- [ ] `defined('Cls::CONST')`/class_exists 第二参（autoload 触发）
- [ ] `explode('')` ValueError
- [ ] null 方法调用 Error 应可 catch（现为引擎 fatal）
- [ ] get_parent_class 返回显示名（现为 key）

## 远期（架构级）

- [ ] PHP → Elixir AST 编译后端（树遍历慢 1~2 数量级；README 路线图原定终点）
- [ ] Plug 每请求一 BEAM 进程 Web 运行时（真 HTTP SAPI，替代 CLI 差分）
- [ ] Elixir 互操作层

## 环境备忘

- MySQL 容器：`docker start phpbeam-mysql`（8.0，wp_test/wp/wppass，127.0.0.1:3306，native_password）
- WP 树：/tmp/wp_extract/wordpress（7.1.2，wp-config 已配真库；改动后可 `unzip -p /tmp/wp.zip` 对应文件恢复）
- hex 仓库被网络 TLS 挡——依赖走 git（mix.exs 注释有说明）
- 排障工具沉淀：BEAM 采样（Process.info current_function/backtrace 写文件）、exit 截断二分（截断语法 255 ≠ 挂起 142）、`fwrite(STDERR)` 即时插桩、哨兵 raise 带栈
- 验收纪律：语义疑问先查 php-src（/Users/guozhu/Downloads/php-8.4.24）或 `php -r` 探针，不空想（AGENTS.md 有正文）
