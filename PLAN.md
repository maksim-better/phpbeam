# phpbeam — 待办计划（2026-09-25 目标切换：Laravel）

**北极星：浏览器访问 phpbeam 服务端口，完整运行一个 Laravel 编写的项目**——页面渲染、静态资源、表单提交（session/cookie）、数据库读写全部真实工作。

验收方式：同一 Laravel 项目分别在 `php -S` 与 phpbeam-Plug 下起服务，curl 对比响应（body 逐字节；Set-Cookie/header 顺序做规范化后比对）；最终以浏览器人工走通交互路径收口。

进度自评：语言核心已完成约 70%（类系统/生成器/autoload/命名空间作用域/异常/闭包绑定/引用语义等全部迁移复用）；实测缺口见下表。

## 已实测缺口（**2026-09-26 复测**，重构+L1.5 后逐项探针；2026-09-25 首测见 git 历史）

语法项 L1/L1.5 已全部关闭。运行时复测结论（phpx 实测）：

| 域 | 状态 | 实测细节 |
|---|---|---|
| **autoload 链路** | ✅ **实测可用** | spl_autoload_register + 回调内 eval 建类 + 常量解析全通——L2 的引擎依赖已就位 |
| Reflection | 🟡 仅薄切片 | ReflectionClass：getName/isAbstract/isInterface/isEnum/hasMethod/getMethod ✓；getMethods/getConstructor/newInstance ✗；ReflectionFunction/Parameter/NamedType 类不存在；attributes 语法解析 ✓ 但 getAttributes ✗（L3 主体工作，地基 Table meta API 已落） |
| DateTime/Carbon | 🔴 **缺口比记载严重** | `new DateTime("2026-01-02 03:04:05")->format(...)` 返回 **1970-01-01 00:33:46——静默错值**（ISO 串解析缺失，比 Fatal 危险：Laravel 会算出错误时间不报错）；modify/diff/DateTimeImmutable/DatePeriod/strtotime 全缺（strtotime 是 bool(false) 缺失） |
| PDO | 🔴 全缺（预期 L5） | class_exists("PDO")=false |
| mbstring/ctype/iconv/tokenizer | 🟡 部分 | mb_strlen ✓；mb_convert_encoding/mb_str_split/ctype_digit/iconv/token_get_all ✗——真实需求面待 L2 vendor 加载沿途暴露 |
| session | 🔴 缺（预期） | session_start 不存在；headers_sent/headers_list ✓（L0 已做） |

**执行就绪度结论（2026-09-26）**：可以执行。L2（Composer vendor）引擎依赖实测就绪、随时可开工；L3 前置已落；L4 需把「DateTime 构造 ISO 串静默错值」升为该里程碑首修项（错值比缺功能危险）。

## L0：HTTP SAPI（**已完成**，`283950f`）

- [x] `phpx serve <docroot> --port=N`：gen_tcp 零依赖 HTTP 服务（hex 被 TLS 挡，Plug 顺延——解释器只见请求种子+SAPI 响应区，后续可整体换 Plug 不动引擎）；每连接一 BEAM 进程跑 interp。
- [x] 请求种子：`$_SERVER`（REQUEST_METHOD/URI/QUERY_STRING/HTTP_*/SCRIPT_NAME/DOCUMENT_ROOT…）、`$_GET/$_POST`（urlencoded）/`$_COOKIE/$_REQUEST`；目录→index.php；静态文件带 mime 直出；**未匹配路径回退 docroot 前端控制器**（php -S 实测行为，Laravel public/index.php 路由依赖）。
- [x] Interp sapi 响应区：`header()/setcookie()/http_response_code()/header_remove()/headers_list()` HTTP 下真实现（CLI 保留旧警告语义）；HTTP 模式 body 全缓冲（= php -S output_buffering，echo 后仍可 setcookie）；响应形态对齐（脚本头在前、默认 Content-type 小写 t 追加、Set-Cookie 无默认 path）。
- [x] 验收：`test/phpbeam/http_test.exs` 双服务器（phpx serve + php -S）6 例 curl 差分（根 GET 带参/POST 表单/静态/目录索引/重定向/前端控制器回退）全部一致（归一化 Host/Date/Connection/CL/X-Powered-By）。
- 后续待补（低优先）：`$_FILES` 物化、chunked body、keep-alive、HTTP/1.0

## L1：语法冲刺（**已完成**，`c602d64`）

- [x] 构造器属性提升（可见性+readonly 前缀解析；类构建时糖解构为声明属性 + 前置 `$this->x = $x;` 赋值；byte-diff 一致）
- [x] **枚举**（php 8.1）：case/backed `enum S: string { case A = "a"; }`；case 单例在声明时物化（name/value 属性）；`Suit::Hearts` 经类常量通道解析；`::cases()/from()/tryFrom()` 闭包携带枚举 key；var_dump 渲染 `enum(Cls::Case)`
- [x] readonly：`readonly class`/`final readonly class` 解析；写已初始化 readonly 属性抛可捕获 Error（物化 + php 措辞）
- [x] 数组字面量展开 `[...$a, 'k' => v]`（字符串键保留、int 键顺序重编）；`PArray.from_pairs` 接受裸键
- [x] 一等可调用 `strlen(...)`/`$obj->m(...)`/`Cls::m(...)`（裸名 FCC 产字符串可调用不做常量求值；`usort($a, strcmp(...))` 可用）
- [x] **重大修复**：`strict_eq` 对对象句柄（整数 id）——**自 M1 起 `===` 对对象恒 false**（object_identity 只匹配全 map 形态）
- [x] 差分 25_laravel_syntax.php 固化

## L1.5：语法缺口收口（**已完成**，2026-09-25 校验后冲刺）

L1 声称"命名参数已可用"经差分证伪（实为按位置绑定）；随 enum from()/readonly 一起收口：

- [x] **命名参数按名绑定**（用户函数/方法/构造器/闭包/静态）：`f(b: 3, a: 4)` 交换序、`str_replace(search:…, subject:…)` 内置重排（builtin.ex 挂 ReflectionFunction 核实的 arginfo 参数名表）、解包字符串键 `f(...["a"=>1])` 产命名实参；错误族 php 精确措辞（Unknown named parameter $z / Named parameter $a overwrites previous argument / `f(): Argument #2 ($b) not passed` 变体 + 帧渲染 `f(1, NULL, 9)`）；`func_get_args` 快照语义（位置+声明形参，变参收集的命名实参不计入）；编译期检查 `Cannot use positional argument after [argument unpacking|named argument]`（fatal 通道）
- [x] **enum from() 非法值**：物化 ValueError + `S::from('zz')` 帧 + 背衬类型弱强制（`from("1")` 命中 int case）；消息 `"zz" is not a valid backing value for enum S`
- [x] **readonly 属性（非 readonly class）写保护**：初始化一次（声明类或子类作用域内）；外部初始化 `Cannot modify protected(set) readonly property Q::$y from [global scope|scope W]`（php 8.4 措辞）；二次写 `Cannot modify readonly property`；unset 拒绝；读未初始化 `Typed property Q::$y must not be accessed before initialization`；链接期检查（readonly 带默认值/static readonly，提升 readonly 带默认值合法）
- [x] **提升属性真声明修复**：原实现的属性收集在糖解构之后运行（死代码）——提升属性从未真正声明，全靠动态属性；readonly/默认值/instance_defaults 语义随之修正
- [x] 顺手修复：三元/短三元条件 unwind 穿透（原裸 `=` 匹配崩）；FCC 链式调用 `strlen(...)("x")`/`$o->m(...)(7)`；非静态方法 FCC 创建即抛；var_export 尾换行；heredoc 插值警告行号（part 级行标记 + 关闭行后 lexer 行号 +1 漂移）；生成器 yield 后主进程 file_stack 丢失（用生成器后所有警告/异常文件名退化为 Command line code）；原生方法抛错通道 env=nil 崩 catch 机器（generator rewind/getReturn 物化 + 帧）
- phpt 净变化：+3 过（func/008、func/009、classes/property_override…），无回归

## H0：phpt 清障——四个可治桶清零（1–2 会话，2026-09-26 插入，先于 L2）

2026-09-26 失败分诊（410 败 = 274 mismatch + 50 fatal + 16 undef_symbol + 9 parse_error + 10 timeout，另有 ~51 在基线内抖动边界）：mismatch 实测 **195 个独立家族**（最大家族仅 6 例）——长尾真实，"全部通过"按当前证据需 20–40 会话纯边缘语义苦工且大半与 Laravel 无关，**不设全通过目标**；四个可治桶（~85 例）全部高价值，先清：

- [ ] **fatal(50)**：类声明严格性错误路径（abstract_redeclare/interface_method_final/visibility_00x/static_mix——Classes.Table.link_checks 的措辞与触发面扩展）、__call 家族、constants_basic
- [ ] **undef_symbol(16)**：SPL 迭代器家族（iterators_00x → ArrayIterator/IteratorIterator 等 native 类）、autoload_0xx 边角、serialize_001、func/041/043/044 缺函数
- [ ] **parse_error(9)**：语法错误消息措辞对齐 + invalid_octal/bug24396 等真实语法缺口
- [ ] **timeout(10)**：挂起即 bug——short_tags 家族（短标签词法）、unset_properties、bug29944、timeout_variation 族
- [ ] 门禁：`scripts/gate.sh --record` 收缩基线（预期 410→~320），顺延清单同步

## H1：phpt 高价值 mismatch 子集——只做 classes/ 套件的 Laravel 相关族（2–4 会话，H0 后择机）

- [ ] 按主题族推进（不按用例数）：可见性/继承错误路径、autoload、array_access（Laravel collections 底座）、destructor 次序、常量可见性
- [ ] 长尾（~150–200 例）**保留失败**：由基线失败集护栏看管回归，不为凑数实现 bug26869 类边缘语义；个别架构不适用例（OOM/内存限制类）登记豁免理由

## L2：Composer vendor 实战（1 会话）

- [ ] `composer create-project laravel/laravel` 真树可被我们的 autoload 加载（psr-4/classmap/files 三通道）
- [ ] `phpx artisan --version` 出版本号；差分对齐
- [ ] 暴露并修复 vendor 加载沿途的崩溃/缺口清单

## L3：Reflection API（2–3 会话，最大单项）

- [x] 前置已落（2026-09-26 重构 Phase 1，见 ARCHITECTURE_DESIGN.md）：Classes.Table meta 只读 API + ReflectionClass/ReflectionMethod 薄切片（26_reflection.php 差分逐字节过）；L3 本体直接在 `builtin/reflection.ex` 扩

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
- [x] 池化接缝已落（2026-09-26）：`Interp.fork_request/1` + `warm/1`（fork 单测：boot 表共享、statics 重置）；预热池本体待 L6 实测收益后接 Http
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
