# phpbeam — PHP on the BEAM

[English](README.md) | **简体中文**

用 Elixir 实现、运行在 Erlang 虚拟机（BEAM）上的 **PHP 8.4 子集树遍历解释器**。它是"**在 BEAM 上跑 WordPress**"计划的第一阶段：语言管线（词法 → 语法 → 求值）已完整落地，所有语义决定都以**真实 PHP 8.4 逐字节对拍**来锚定——先是差分测试，再是 PHP 官方测试套件（`.phpt`）。

```
$ ./phpx test/cases/13_showcase.php
phpbeam cart: 3 items, €26.74
in USD: 24.60
elixir > beam > php
cart had 3 items
caught: Division by zero
1+4+9+16+25 = 55
interpolation: 3 items for ~€26.74
```

## 现状一览

| 指标 | 数值 |
| --- | --- |
| php-src 官方测试（tests/{lang,strings,func,classes,basic,output}） | **273 / 697 通过**（可见性执法已落地；Zend 套件回归修复中，见 PLAN.md） |
| WordPress 内置函数需求覆盖（按调用频次） | **93%**（346 个内置；真 MySQL 走 MyXQL） |
| 对本机 PHP 8.4 的差分用例（stdout 逐字节） | 19/19 |
| wp-load.php | 无配置：错误页**逐字节一致**；带 wp-config + 真 MySQL：完整跑通 exit 0 |
| 代码量 | 约 1.6 万行 Elixir，13 个内置模块 |

## 快速开始

```console
$ mix deps.get && mix escript.build   # 生成 ./phpx
$ ./phpx script.php                   # 运行脚本（include/require 可用）
$ ./phpx -r 'echo "hi ", PHP_INT_MAX, "\n";'
$ ./phpx --repl                       # 状态持久化 REPL
$ mix test                            # 单测 + 差分 + .phpt 三层
$ mix test --exclude phpt             # 快速开发循环
```

`.phpt` 套件需要一份解压的 php-src 源码树（默认 `~/Downloads/php-8.4.24`，用 `PHP_SRC` 环境变量改指向）。

## 已验证的语义

正确性不是宣称的，是**测出来的**——对 `/opt/homebrew/bin/php`（8.4.2）和 php-src 8.4.24 官方语料逐字节比对：

- **警告与错误渲染和 PHP 8.4 完全一致**：`\nWarning: Undefined variable $x in /real/path.php on line 3`、带真实调用栈（含实参列表）的多行未捕获错误 `#0 /app/wp-load.php(5): require()`、链接期引擎 fatal（无 Uncaught 包装）——全部经探针与差分用例验证。
- **语言**：完整 PHP 8 运算符优先级、`match`、`list()` 解构、闭包/箭头函数、trait（`insteadof`/`as`）、命名空间、`include`/`require`(_once)（吃完整表达式操作数，`require_once ABSPATH . 'wp-settings.php'`）、调用方作用域的 `eval()`、逐文件栈的 `__FILE__`/`__DIR__`。
- **类型与值**：PHP 8 类型杂耍（松散相等矩阵、数字字符串、`"az"++`）、slot 保序的有序哈希数组、int64 键规范化与自动索引、逐字节一致的 `var_dump`/`print_r`/`var_export`/JSON。
- **面向对象**：单继承、接口、trait、后期静态绑定、魔术方法、写穿透的对象句柄——以及**链接期严格性**：abstract 强制、可见性收窄、static 冲突、`final` 重写、签名兼容性检查（`Declaration of D::f(array $a) must be compatible with A::f($a)`）。
- **Throwable**：原生 Exception/Error 层次、`DivisionByZeroError`、内置抛出的 `ValueError`、带真实栈帧的 `Uncaught Error:` 格式。
- **函数**：约 220 个内置（字符串/数学/数组/文件/输出缓冲/序列化/正则）；高阶分派（`array_map`、`usort` 族引用写回、`preg_replace_callback`）、`func_get_args()` 族、引用语义（`$a = &$b`、`foreach as &$v`、`&` 参数）。
- **PCRE**：完整 `preg_*` 族直跑原生 PCRE——命名组（`$m['year']`）、`PREG_OFFSET_CAPTURE`、`PATTERN_ORDER`/`SET_ORDER`、`$N`/`${N}`/`$name` 替换反引用、`preg_split` 标志。
- **I/O 与状态**：include_path 解析的 include/require、字符串类文件函数（`file_get_contents`、`file_put_contents`、`scandir` 等）、输出缓冲（`ob_*` 族连警告一起捕获）、带可见性修饰属性名和最短往返浮点的 `serialize`/`unserialize`、数组游标（`current`/`next`/`key`/…）。

## 正确性如何保证

三层，全部由 `mix test` 驱动：

1. **单元测试**：词法、语法、值模型、有序数组。
2. **差分测试**（`test/cases/*.php`）：每个用例在本机 PHP 和 phpx 上各跑一遍，**stdout 必须逐字节一致**——警告、错误文本、行号，全部。
3. **php-src 官方验收 harness**（`test/phpbeam/phpt_test.exs`）：php-8.4.24 发行版约 700 个 `.phpt` 用例，按 `run-tests.php` 语义执行（PHP 式 trim、逐条照抄的 `expectf_to_regex` 代码表）。失败带分诊标签（`undef_fn`、`parse_error`、`mismatch`……），每个里程碑攻最大的一桶。

## 架构

```
lib/phpbeam/
├── lexer.ex        # PHP 8 词法：HTML/PHP 模式、heredoc、插值扫描
├── parser.ex       # 递归下降 → AST；每条语句携带行号
├── interp.ex       # 语句执行；警告/fatal、文件栈、调用栈
├── eval.ex         # 表达式、左值、调用分派（含高阶 preg/排序）
├── classes.ex      # 类模型、链接期继承检查、原生 Throwable
├── value.ex        # zval 等价物：全部类型杂耍规则、浮点格式化
├── parray.ex       # 有序哈希数组（slot 单调递增）+ 内部游标
├── pattern.ex      # preg_* 引擎（原生 :re），命名组编号扫描器
├── render.ex       # var_dump / print_r / var_export（与 PHP 逐字节一致）
├── env.ex          # 作用域：局部/static/捕获 + 每帧实参快照
├── builtin/        # 11 个注册表模块：string、math、array、var、file、
│                   # ob、runtime/ini、serialize、cursor、preg
└── cli.ex          # phpx CLI + 持久化 REPL
```

**关键设计**：

- **控制流即值**：`return`/`break`/`throw` 以 `{:unwind, signal}` 元组穿透并始终携带最新解释器状态——static 变量、对象注册表、输出缓存在异常路径上不丢（用 Elixir 异常会丢弃累积状态）。
- **解释器状态线程化，绝不共享**：`{result, env, interp}` 贯穿一切；副作用（警告、ob 写入、实参求值）必须返回新状态，否则静默丢失——本项目用血泪修掉的一整族 bug。
- **对象是句柄**：`{:object, id}` 指向 `interp.objects`；属性写穿透注册表，所有持有者立即可见——免费获得 PHP 引用语义。
- **错误带位置**：语句包行号，`Interp.cur_line` + 文件栈喂给每条警告/fatal；函数调用压帧（含渲染后的实参），支撑 PHP 8.4 风格的未捕获栈。
- **PCRE 就是 PCRE**：Erlang 的 `:re` 底层就是 PCRE，模式体只做定界符/修饰符翻译即直通。

## 通往 WordPress 的路线

对着 WordPress 真实源码（它调用的每一个函数）量出来的：

1. ✅ 语言核心、include 链、preg_*、serialize、输出缓冲——**WP 内置需求已覆盖 80%**
2. ▶ 字符串/杂项内置扫尾（`is_callable`、`parse_url`、`md5`、`ord`/`chr`、`compact` 等）→ 约 85%
3. ◻ resource 流（`fopen`/`fread`/`fseek`……需要 resource 值类型）、`trigger_error`、date/time 族
4. ◻ SPL（`ArrayObject`、迭代器）、session、`filter_var`
5. ◻ 基于Elixir 数据库驱动的 `mysqli`/PDO——真实站点的门槛
6. ◻ 性能：PHP→Elixir AST 编译后端（词法/语法/值模型全复用）——树遍历比 php-src 慢 1~2 个数量级

## 许可证

[MIT](LICENSE)
