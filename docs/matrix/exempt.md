# 扩展/用例豁免登记（exempt.md）

用户 2026-09-26 拍板：完整 phpruntime 路线下，67 扩展中 16 个低频/无 BEAM 落点件豁免。
每条必须写明理由与解除条件——豁免不是删除，是有需求信号即复工的待命清单。

| 扩展 | 函数面 | 豁免理由 | BEAM 替代建议 | 解除条件 |
|---|---|---|---|---|
| snmp | 24 | 网络设备监控协议，Web 应用零需求 | — | 出现真实运行目标 |
| ldap | 56 | 目录服务客户端，场景窄 | — | 出现真实运行目标 |
| odbc / pdo_dblib / PDO_ODBC | 48 | 通用 DB 桥，BEAM 上无对应驱动；Laravel 主用 mysql/pgsql/sqlite | pdo_mysql/pdo_sqlite/pgsql 已覆盖主流 | 需求信号 |
| dba | 15 | dbm 抽象层，古董存储 | ETS | 需求信号 |
| tidy | 24 | HTML 清理/修复，DOM 扩展可覆盖大部分 | dom（T2） | 需求信号 |
| xsl | XSLTProcessor 类 | XSLT 转换，现代 PHP 应用罕见 | xmerl + 手写转换 | 需求信号 |
| exif | 4 | 图片元数据读取 | gd/getimagesize 子集先行 | gd 落地后随需 |
| fileinfo | 6 | mime 探测需 libmagic 数据库 | 先做扩展名+魔数子集；Laravel 上传验证踩到时升级 | Laravel 上传链路实测 |
| gettext | 10 | C libintl 绑定；Laravel 翻译自带系统不走 gettext | Laravel translation 组件 | 需求信号 |
| soap | 2+WSDL 类族 | WSDL 栈重（解析/代理生成），BEAM 上更自然的是 HTTP API 直连 | curl+SimpleXML 组合手写客户端 | 出现真实运行目标 |
| bz2 | 10 | BEAM 无自带 bzip2（hex 被挡，git 依赖评估中）；compress.bzip2 随之豁免 | zlib 已覆盖主流压缩分发 | composer 分发踩到 bz2 phar 时 |
| shmop | 6 | SysV 共享内存，BEAM 上语义错位 | ETS | 需求信号 |
| sysvmsg / sysvsem / sysvshm | 7/4/7 | 同上（SysV IPC 三兄弟） | ETS / BEAM 消息传递 | 需求信号 |
| Zend OPcache | — | **架构不适用**：BEAM 常驻进程即缓存，无「每次请求重新编译」问题 | Interp.warm/fork_request 池化 | 永久（形态不同） |

## phpt 用例级豁免（随套件扩目录时逐条登记）

登记格式：`用例路径 | 豁免理由`。预期豁免类别：
- 内存限制类（memory_limit/OOM 注入）——BEAM 内存模型不同
- OPcache 专属用例（ext/opcache/tests）
- FFI 的 C 编译类用例（ext/ffi/tests 需要编译 .so——FFI 在 BEAM 上走 NIF 桥，形态不同）
- 依赖豁免扩展的用例（ext/{snmp,ldap,…}/tests）

_本节在 PHASE B 起随目录纳入逐条补登。_

## 机器可读标记行（T011，2026-10-03——目录级豁免入库）

spec 001 判据一口径：豁免扩展目录按 dir-id 登记，criterion.sh 消费。
散文表（上节）仍为理由权威；标记行是其机器形态，解除条件同名。

EXEMPT-DIR ext-snmp | 网络设备监控协议，Web 应用零需求 | 解除: 出现真实运行目标
EXEMPT-DIR ext-ldap | 目录服务客户端，场景窄 | 解除: 出现真实运行目标
EXEMPT-DIR ext-odbc | 通用 DB 桥，BEAM 无对应驱动 | 解除: 需求信号
EXEMPT-DIR ext-pdo_dblib | 同 odbc | 解除: 需求信号
EXEMPT-DIR ext-dba | dbm 抽象层，古董存储（ETS 替代） | 解除: 需求信号
EXEMPT-DIR ext-tidy | HTML 清理，dom 可覆盖大部分 | 解除: 需求信号
EXEMPT-DIR ext-xsl | XSLT 现代应用罕见 | 解除: 需求信号
EXEMPT-DIR ext-exif | 图片元数据，gd 落地后随需 | 解除: gd 子集落地后
EXEMPT-DIR ext-fileinfo | mime 探测需 libmagic；先做扩展名+魔数子集 | 解除: Laravel 上传链路实测
EXEMPT-DIR ext-gettext | Laravel 翻译自带系统不走 gettext | 解除: 需求信号
EXEMPT-DIR ext-soap | WSDL 栈重；BEAM 上更自然是 HTTP 直连 | 解除: 出现真实运行目标
EXEMPT-DIR ext-bz2 | 本 OTP 无 bzip2；zlib 已覆盖主流 | 解除: composer 分发踩到 bz2 phar
EXEMPT-DIR ext-shmop | SysV 共享内存语义错位（ETS 替代） | 解除: 需求信号
EXEMPT-DIR ext-sysvmsg | SysV IPC 三兄弟（BEAM 消息传递替代） | 解除: 需求信号
EXEMPT-DIR ext-sysvsem | 同上 | 解除: 需求信号
EXEMPT-DIR ext-sysvshm | 同上 | 解除: 需求信号
EXEMPT-DIR ext-opcache | 架构不适用：BEAM 常驻进程即缓存（Interp.warm/fork_request 池化） | 解除: 永久（形态不同）
EXEMPT-DIR ext-ffi | FFI 的 C 编译类用例（BEAM 走 NIF/Elixir 互操作桥，spec 001 E′ 设计文档） | 解除: FFI 桥设计落地后重划用例级

intl 子集外与 gd 图像生成类的用例级豁免在 E′ 相（spec 001）随分诊逐条登记，此处不预登。
