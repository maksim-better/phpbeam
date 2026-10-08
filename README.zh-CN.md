# phpbeam — 跑在 BEAM 上的 PHP

[English](README.md) | **简体中文**

一个用 Elixir 编写、运行在 Erlang 虚拟机（BEAM）上的 **PHP 8.4** 树遍历解释器。验收标准是**与真实 PHP 语义等价**：每一项声明都以**对真实 PHP 8.4 逐字节测量**为准——先差分测试，再 php-src 官方测试套件（`.phpt`）。终态是 **BEAM 上的完整 PHP 运行时**——任意 PHP 8.4 程序以完全一致的可观测行为运行（验收定义与阶段计划见 PLAN.md）。

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

## 现状速览

| 指标 | 数值 |
| --- | --- |
| 已纳入的 php-src 官方用例（tests/{lang,strings,func,classes,basic,output,security,run-test} + Zend/tests/exit） | **348 / 760 通过**（按目录分片基线；失败三选一：修复/豁免/顺延——见 PLAN.md） |
| 全套件目标 | **20,766 例**（Zend/tests + 已实现扩展目录，分阶段纳入；`scripts/criterion.sh` 机械判定） |
| 已实现内建函数 | **约 1,040 个**，覆盖 std/date/mbstring/SPL/hash/xml/openssl/curl/sockets/数据库（PDO+mysqli+pgsql+sqlite3）/zlib/zip/phar/posix/进程执行 族 |
| 对本机 PHP 8.4 的差分用例（stdout+stderr 逐字节） | **54** 个（`test/cases/*.php`） |
| Laravel 冒烟 | `artisan` 贯穿 composer autoload、DI 容器、config 装载（Symfony Finder 链）、Carbon，进入 Kernel 命令分发 |
| 代码量 | 约 2.5 万行 Elixir；30+ 内建/类模块 |

## 快速开始

```console
$ mix deps.get && mix escript.build   # 构建 ./phpx（git 依赖走 SSH；网络受阻见 PLAN.md）
$ ./phpx script.php                   # 运行脚本（$argv/$argc 已播种；include/require 可用）
$ ./phpx -r 'echo "hi ", PHP_INT_MAX, "\n";'
$ ./phpx --repl                       # 持久 REPL
$ ./phpx serve <docroot> --port=8080  # HTTP SAPI（$_GET/$_POST/$_FILES/$_COOKIE、keep-alive）

$ scripts/gate.sh --lane fast         # 构建 + 非 phpt 套件全绿（日常门禁）
$ scripts/gate.sh --lane dirs -- lang # 只跑改动相关的 phpt 分片
$ scripts/gate.sh --lane full         # 全部已纳入分片 + 分片和自检
$ scripts/gate.sh --record            # 重录失败基线（仅绿套件后使用）

$ mix test                            # 单测 + 差分 + phpt 套件
$ mix test --exclude phpt             # 快速开发回路
```

`.phpt` 套件需要解包的 php-src 树（默认 `~/Downloads/php-8.4.25`，可用 `PHP_SRC` 覆盖），以及 oracle 二进制 `/opt/homebrew/bin/php`（开发机为 8.4.17）。失败基线在 `tmp/baseline/<dir>.txt`（gitignored），只允许收缩。

## 已验证的语义

正确性不是宣称出来的——是**测量**出来的，对 `/opt/homebrew/bin/php` 与 php-src 语料逐字节：

- **错误与诊断与 PHP 8.4 渲染一致**：stdout 显示副本 + stderr `log_errors` 副本、`PHP Deprecated:`/`PHP Fatal error:` 前缀、带真实调用栈的多行未捕获错误、保留字 `exit`/`die` 在声明位的解析错误措辞（源码写 `die` 也渲染规范名 `exit`）。
- **语言**：完整运算符优先级（含 `and`/`or` 短路）、`match`、一等可调用语法、闭包身份语义（拷贝后 `$f === $f`；生成器工厂）、trait（`insteadof`/`as`，`self`/`parent` 按声明处编译类绑定、owner 作用域可见性）、枚举、按声明序的只读/提升属性、命名空间、`@include` 抑制、`new static::$prop(...)`。
- **OOP**：单继承、接口（含原生 `Iterator`/`IteratorAggregate` → `Traversable` 链）、trait 抽象方法作为**用类**的要求、签名兼容的 `self`/`static` 展开、静态属性家族共享存储（每声明类一槽，php 语义）。
- **SPL 与迭代器**：ArrayObject/ArrayIterator、DLL/堆/优先队列族、SplFileInfo 族，以及迭代器家族——`IteratorIterator`、`FilterIterator`（accept 驱动、活对象 `$this->current()`）、`DirectoryIterator`/`FilesystemIterator`/`RecursiveDirectoryIterator`（裸 readdir 序、`getSubPath`/`getSubPathname`）、`GlobIterator`、`RecursiveIteratorIterator`（LEAVES_ONLY/SELF_FIRST/CHILD_FIRST）——足以让 Symfony Finder 启动。
- **运行时**：进程执行（`proc_open` 带描述符管道、`exec`/`system`/`passthru`/`shell_exec`）、流与过滤器链及 `php://` 族、真文件会话、INI 层（286 条注册表、`-c/-n/-d`、`.user.ini`）、CLI `$argv`/`argc` 与 `$_SERVER` 镜像。
- **客户端与存储**：PDO（mysql/sqlite）+ mysqli（prepared 协议）+ pgsql、zlib/zip/phar、openssl（AES/RSA/X509）、curl（file+http(s)）、gen_tcp 上的 sockets、`WeakMap`。

## 正确性如何被强制

三层：

1. **单元测试**：词法、语法、值模型、有序数组。
2. **差分测试**（`test/cases/*.php`）：每个用例在本机 PHP 与 phpx 上各跑一遍；**stdout 必须逐字节一致**（错误路径用例连 stderr 一起比）。
3. **php-src 官方验收 harness**（`test/phpbeam/phpt_test.exs`）：`.phpt` 用例按 `run-tests.php` 语义运行。纳入分阶段（先 Zend/tests，再扩展目录）；每批分诊为**修复 / 豁免（`docs/matrix/exempt.md`）/ 顺延（`docs/matrix/deferred.md`）**——没有静默跳过。`scripts/criterion.sh` 把冻结判据（失败集 ⊆ 豁免集）变成机械检查。

纪律：一模块一提交，过 `scripts/gate.sh` 门禁；失败基线只收缩；oracle 变更时的机器钉常量（php 版本、libcurl、sqlite）记入 `docs/matrix/drift.md`。实时计划见 **PLAN.md**，模块契约见 **ARCHITECTURE_DESIGN.md**。
