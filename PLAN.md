# phpbeam — 待办计划（2026-09-25 目标切换：Laravel）

**北极星：浏览器访问 phpbeam 服务端口，完整运行一个 Laravel 编写的项目**——页面渲染、静态资源、表单提交（session/cookie）、数据库读写全部真实工作。

验收方式：同一 Laravel 项目分别在 `php -S` 与 phpbeam-Plug 下起服务，curl 对比响应（body 逐字节；Set-Cookie/header 顺序做规范化后比对）；最终以浏览器人工走通交互路径收口。

进度自评：语言核心已完成约 70%（类系统/生成器/autoload/命名空间作用域/异常/闭包绑定/引用语义等全部迁移复用）；实测缺口见下表。

## 已实测缺口（2026-09-25 探针，phpx 逐项验证）

语法（parser 级，1–2 会话冲刺）：
- [ ] 构造器属性提升 `__construct(private int $x = 1)` —— parse error
- [ ] 命名参数 `f(b: 3, a: 4)`（含 attribute 实参内）—— parse error
- [ ] heredoc/nowdoc —— parse error（config/视图遍地）
- [ ] 数组字面量展开 `[0, ...$a, 3]` —— parse error
- [ ] 枚举 enum/backed/cases —— 显式未实现
- [ ] readonly 类/属性；一等可调用 `strlen(...)`
- [ ] attributes 解析已过（`#[Attr(1)]` 可载入），带参形式依赖命名参数

运行时（大块）：
- [ ] **Reflection API**（Class/Method/Function/Parameter/Property/NamedType + getAttributes）——Laravel 容器/DI 的心脏，没有它容器不工作
- [ ] **Carbon 级 DateTime**：DateTimeImmutable/modify/diff/DateInterval/DatePeriod/时区换算（Carbon 是最重单依赖；现有原生 DateTime 仅 format('T','U','c') 最小集）
- [ ] **PDO**（Eloquent/DB 只走 PDO；叠在 MyXQL 上，1–2 会话）
- [ ] mbstring 深化（mb_convert_encoding/mb_str_split…）、iconv、ctype、tokenizer
- [ ] session/cookie 原语与 header 收集（SAPI 的一部分）

已迁移资产：M7–M24 全部语言核心与引擎修复；autoload 体系（fetch_class + spl 链 + 父类/接口/trait 链接期加载——Composer PSR-4 正好吃这套）；mysqli/MyXQL（PDO 底座）；ob_*/eval（Blade 需要）；文件流；Zend/phpt 护栏（285/697 + zend sample 12.6%）。

## L0：HTTP SAPI——Plug 每请求一 BEAM 进程（先做，2 会话）

- [ ] `phpbeam serve <docroot>`：Plug/Cowboy 起 HTTP 服务；每请求 spawn 一个 BEAM 进程跑 interp（天然并发 + 隔离）
- [ ] 请求种子：`$_SERVER`（REQUEST_METHOD/URI/HTTP_* 头/SCRIPT_NAME…）、`$_GET/$_POST/$_COOKIE/$_FILES` 按请求物化
- [ ] 响应收集：`header()/header_remove()/setcookie()` 进 interp 响应区；`exit/die` 映射为响应结束；状态码
- [ ] 静态文件直出（Plug.Static——css/js/图片不经过 PHP）
- [ ] 验收：现有差分用例在 HTTP 形态下同样 byte 级成立（对 `php -S`）；`phpx serve` 能出一个 phpinfo 风格自检页

## L1：语法冲刺（1–2 会话）

- [ ] 构造器属性提升（含默认值/可见性/readonly 修饰）
- [ ] 命名参数（调用点 + attribute 实参 + 跳参）
- [ ] heredoc/nowdoc（含缩进 heredoc、`{$expr}` 插值）
- [ ] 数组字面量展开（含字符串键规则）
- [ ] 枚举（case/backed/::cases()/match on enum/纯枚举 ===）
- [ ] readonly 属性与 readonly 类（写即 Error）
- [ ] 一等可调用 `f(...)`/`$obj->m(...)`
- [ ] nullsafe 边缘加固（链式、写路径、`?->` 后方法链）
- [ ] 差分用例 25_laravel_syntax.php 固化

## L2：Composer vendor 实战（1 会话）

- [ ] `composer create-project laravel/laravel` 真树可被我们的 autoload 加载（psr-4/classmap/files 三通道）
- [ ] `phpx artisan --version` 出版本号；差分对齐
- [ ] 暴露并修复 vendor 加载沿途的崩溃/缺口清单

## L3：Reflection API（2–3 会话，最大单项）

- [ ] ReflectionClass（newInstance/getMethod/getProperties/isInstantiable/getConstructor/getAttributes）
- [ ] ReflectionMethod/ReflectionFunction（invoke/invokeArgs/isPublic/getNumberOfParameters）
- [ ] ReflectionParameter（getType/getName/isOptional/isDefaultValueAvailable/getDefaultValue）
- [ ] ReflectionNamedType/UnionType（getName/allowsNull）
- [ ] ReflectionProperty（setValue/getValue/setAccessible）
- [ ] 验收：Laravel 容器能 `app(X::class)` 构造带依赖注入的类；`artisan list` 出命令清单

## L4：Carbon 级 DateTime（1–2 会话）

- [ ] DateTimeImmutable 全家（copy/modify/add/sub/diff/setTimezone/format 全说明符矩阵）
- [ ] DateInterval/DatePeriod 构造与遍历
- [ ] Carbon 兼容探针：vendor 下 Carbon 核心测试集抽样跑通
- [ ] 验收：Laravel 路由表构建通过（时间相关的 middleware/config 不再炸）

## L5：PDO on MyXQL（1–2 会话）

- [ ] PDO/PDOStatement 类（prepare/execute/fetch/fetchAll/bindValue/errorInfo/setAttribute）
- [ ] 预备语句语义（占位符→MyXQL 参数映射）
- [ ] 验收：Eloquent `User::count()/first()/create()` 对真 MySQL 正确

## L6：Laravel 在 HTTP 下 boot（1–2 会话）

- [ ] `public/index.php` 经 L0 SAPI 完整执行：kernel handle → 响应
- [ ] 简单路由（`Route::get('/', fn() => 'hello')`）200 出字符串
- [ ] 每-请求性能实测；若秒级，进程池预热/已 boot interp 复用（配置缓存路径）

## L7：完整浏览器体验（2 会话）

- [ ] Blade 视图渲染（编译→eval 链路）
- [ ] 静态资源（Vite 产物直出）+ CSS/JS 页面完整视觉
- [ ] session/cookie：登录表单 POST → 重定向 → 登录态保持
- [ ] DB 列表页（分页/查询）
- [ ] 浏览器人工验收 + 与 `php -S` 的 curl 差分矩阵

## L8：性能与架构（持续）

- [ ] 请求级 profile：Laravel boot 的热点函数榜
- [ ] interp 预热池；跨请求 static/类表复用的可行性论证
- [ ] 为编译后端铺路：L0 的 SAPI 边界（请求种子/响应收集）保持与求值器无耦合，编译后端可整体替换解释器内核

## 远期（架构级，README 路线图三步终点）

- [ ] **PHP → Elixir AST 编译后端**：树遍历慢 1~2 个数量级，Laravel 全量 boot 的根治方案；Laravel 的大型真实代码库是比 WP 更有价值的编译目标与正确性试金石（编译产物以现有差分/phpt/浏览器三层护栏回归）
- [ ] **Web 运行时深化**：在 L0 的 Plug 每请求一 BEAM 进程模型上进化——进程池/预热、热重载（文件 mtime 触发重新 boot）、与 Elixir 生态的部署形态（release 内嵌 PHP 项目）
- [ ] **Elixir 互操作层**：PHP 代码调用 Elixir 模块/函数（Enum/JSON/Ecto 等），双向边界（PHP 侧 `Elixir\Mod.fun()` 语法糖、Elixir 侧求值 PHP 片段），共享同一 interp/进程模型——phpbeam 的差异化终极形态：PHP 应用长在 BEAM 上

## WordPress 线处置

降级为**回归资产**，不再推进功能项：`wp-load` exit 0、install.php 完整渲染（`bd85da5`）作为既有能力保留；285/697 phpt + zend 抽样护栏继续作为每里程碑回归门禁。若后续需要 WP，从 install 向导建表处续。

## 低危队列（随手修）

- [ ] 函数/类顶层声明提升；动态属性 Deprecated（需 error_reporting 分级）
- [ ] `defined('Cls::CONST')`/class_exists 第二参触发 autoload
- [ ] `explode('')` ValueError；null 方法调用 Error 可 catch；get_parent_class 显示名
- [ ] 剩余 phpt 桶：`{:badkey, :statics}` 族、ob_start 重用 Fatal、func/005

## 风险登记

- **树遍历性能**：Laravel 全 boot 每 request 可能秒级——L6 起需池化/预热，根治靠编译后端（L8）
- **Reflection 深度**：容器用的细粒度 API（getType()->getName() 等）不能做半吊子
- **PHP 8.2+ 语义**：readonly 约束、枚举背衬、promotion 默认值需按 php 探针对齐
- **差分 oracle 变化**：HTTP 响应对比需规范化（Set-Cookie 顺序、Date 头剔除）

## 环境备忘

- MySQL 容器：`docker start phpbeam-mysql`（8.0，wp_test/wp/wppass，127.0.0.1:3306，native_password）——Laravel 项目另建库 `laravel_test`
- hex 仓库被网络 TLS 挡——依赖走 git（mix.exs 注释）；composer 走系统 php，不受影响
- 排障工具沉淀：BEAM 采样、exit 截断二分（截断语法 255≠挂起 142）、`fwrite(STDERR)` 即时插桩
- 验收纪律：语义疑问先查 php-src（/Users/guozhu/Downloads/php-8.4.24）或 `php -r` 探针，不空想（AGENTS.md 有正文）
