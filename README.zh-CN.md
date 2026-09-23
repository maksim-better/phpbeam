# phpbeam — PHP on the BEAM

[English](README.md) | **简体中文**

用 Elixir 实现的 **PHP 8.4 子集树遍历解释器**，运行在 Erlang 虚拟机（BEAM）上。这是"在 BEAM 上实现 PHP"的第一阶段：词法 → 语法 → 求值四层完整落地，语义以本机 PHP 8.4 为金标准做**逐字节差分测试**。

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

## 快速开始

```console
$ mix deps.get && mix escript.build   # 生成 ./phpx
$ ./phpx script.php                   # 运行脚本
$ ./phpx -r 'echo "hi ", PHP_INT_MAX, "\n";'
$ ./phpx --repl                       # 状态持久化 REPL（变量/函数/类跨行保留）
$ mix test                            # 单测 + 差分测试（需本机 php 8.4 于 /opt/homebrew/bin/php）
```

## 支持范围

| 层 | 能力 |
| --- | --- |
| 词法 | `<?php`/`<?=`/inline HTML、行/块注释（含 `?>`-in-comment 规则）、全部数值字面量（hex/oct/bin/下划线/64 位溢出转 float）、单双引号、heredoc/nowdoc（7.3+ 弹性缩进）、转义序列、简单与 `{$...}` 插值 |
| 语法 | 完整运算符优先级（`or`/`and` 低于赋值、`**` 高于一元负号、`??` 右结合）、替代语法（`if: endif`）、`match`、`list()` 解构、闭包/箭头函数/IIFE、trait（`insteadof`/`as`）、类/接口/抽象/final、静态成员、命名空间与 `use` |
| 求值 | PHP 8 类型杂耍（松散相等矩阵、数字字符串、算术 coercion、`"az"++`）、有序哈希数组（slot 方案保插入序，键规范化含 int64 边界）、`max(整型键)+1` 自动索引、var_dump/print_r/var_export/json 逐字节一致的格式化 |
| 类 | 单继承、接口、trait 扁平化、`self`/`static`/`parent`（后期静态绑定）、`::class`、`instanceof`、静态属性、可见性、`__construct`/`__get`/`__set`/`__isset`/`__call`/`__callStatic`/`__toString`、对象句柄语义（写穿透） |
| 异常 | 原生 `Throwable` 层次（Exception/Error 及常用子类）、`throw`/`try`/`catch`（按继承链匹配）/`finally`、算术错误物化为异常对象 |
| 引用 | `$a = &$b` 共享单元、`foreach as &$v` 写回、`&` 参数写回、`usort` 族引用排序 |
| 函数 | 约 90 个内置函数 + `call_user_func(_array)`/`array_map`/`array_filter`/`array_reduce`/`usort`/`uasort`/`uksort` 高阶函数、static 变量、递归、可变参数、命名参数 |

## 架构

```
lib/phpbeam/
├── lexer.ex        # 词法：HTML/PHP 模式切换、heredoc、插值扫描
├── parser.ex       # 递归下降语法：token → AST（节点形状见 ast.ex）
├── interp.ex       # 语句执行、控制流信号（return/break/continue/throw 以值穿透，状态不丢）
├── eval.ex         # 表达式求值、左值路径写、函数/方法分派、高阶内置
├── classes.ex      # 类模型：注册（trait 扁平化）、继承链查找、原生 Throwable
├── value.ex        # zval 等价物 + 全部类型杂耍规则（gcvt 14 位浮点格式化、短表示）
├── parray.ex       # 有序哈希数组（slot 单调递增保序）
├── render.ex       # var_dump/print_r/var_export（与 PHP 逐字节一致）
├── builtin/        # string/math/array/var + 求值器侧高阶函数
└── cli.ex          # phpx CLI + 持久化 REPL
```

**关键设计**：

- **控制流即值**：`return`/`break`/`throw` 都是 `{:unwind, signal}` 元组穿透求值器并携带最新解释器状态——static 变量、对象注册表、输出缓冲在异常路径上不丢失（Elixir 异常会丢弃累积状态，故不用）。
- **对象注册表**：`{:object, id}` 句柄指向 `interp.objects`，属性写穿透所有持有者，与 PHP 的 zval 引用语义一致。
- **数组 slot 方案**：单调递增 slot 保留插入序，删除留洞，替换保持原位；`max(历史整型键)+1` 自动索引（含负键、unset 后高水位保持）。
- **差分测试**：`test/cases/*.php` 在本机 PHP 8.4 与 phpx 上运行并逐字节比对 stdout——13 组用例覆盖从算术边角（`018` 非法八进制、`"1abc"+1` 警告后取 1）到 OOP/异常/引用的完整语义。

## 已知偏差

- `__destruct` 不保证时序（BEAM GC 语义），脚本结束时统一执行
- 不支持 resource 类型与文件 I/O、`eval()`、匿名类、goto、枚举
- 树遍历解释器比 php-src 慢 1~2 个数量级（预期内，性能优化属于后续编译后端里程碑）
- 可见性检查宽松（private/protected 读取放行，写入按声明）

## 后续路线

- PHP → Elixir AST 编译后端（原生 BEAM 性能 + 热加载，词法/语法/值模型全部复用）
- Plug 每请求一 BEAM 进程的 Web 运行时（PHP share-nothing 与 BEAM 进程模型天然对齐）
- Elixir 互操作（PHP 调 Elixir 函数）、`eval`/文件 I/O

## 许可证

[MIT](LICENSE)
