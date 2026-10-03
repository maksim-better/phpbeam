# 版本漂移登记（drift.md）— R5 基线重录时量化

重钉事实（2026-10-03，R1/T003）：

| 项 | 旧（原开发机） | 新（本机） |
|---|---|---|
| oracle php | /opt/homebrew/bin/php 8.4.2 | /opt/homebrew/bin/php 8.4.17 |
| php-src 源树 | php-8.4.24（/Users/guozhu/…，已失效） | php-8.4.25（/Users/5i5j/Downloads/php-8.4.25，20,766 例实测） |
| 失败基线 | tmp/baseline_phpt_failures.txt（348 败，文件已随旧机丢失） | 待 R5 分片重录（tmp/baseline/<dir-id>.txt） |

## 漂移条目（E7 格式）

规则：基线重录时，凡「旧机器已知通过/失败状态」与「本机重录结果」不一致且无法归因于
代码改动的用例，逐条登记——不静默改判。差异类型分两类：

- **expect 文本**：8.4.24→8.4.25 之间 .phpt 期望文件本身的变更（php-src bug 修复带动）。
- **SKIPIF 行为**：8.4.2→8.4.17 探针判定变化（扩展加载/环境检查结果不同导致 skip 集漂移）。

登记格式：`用例路径 | 差异类型(expect|skipif) | 处置(重录吸收/个案分析/登记待查)`

- test/cases/14_include.php | expect（php 侧警告内嵌 oracle 安装路径：旧机 `Cellar/php/8.4.2` → 本机 `Cellar/php@8.4/8.4.17`） | 处置：ini.ex:97 include_path 默认值重钉本机 keg 路径（该默认值始终为机器钉死值，换机须随迁；T004 修复，2026-10-03）
- deps/exqlite 实测内嵌 SQLite 3.45.1 | 版本事实 | deferred.md D2 节记录的「exqlite 内嵌 3.48」与实际不符——以本机实测为准，D 系 sqlite 差分如断言版本串以此为准核对（T005 发现）
- test/cases/43_c4_curl.php | expect（本机 libcurl 8.11.1→8.18.0：errno 37 文案 "Couldn't"→"Could not open file"、curl_version 版本串/host 三元组） | 处置：curl_fns.ex 版本块+错误文案重钉本机（deferred C4「跨机器差分需再探针」预登记项兑现；T004 修复，2026-10-03）
- test/cases/47..52（D 系 DB 差分） | ~~环境不可得~~ 已恢复 | 处置：容器本机重建（mysql:8.0 最新 8.0.x，root/root + wp_test/laravel_test + wp/wppass + wp_test/wppass，127.0.0.1:3306；旧机为 8.0.46）后 T006 验收：47/48/49/50/51 直差分 BYTE-IDENTICAL、52 套件绿（stdout 通道；旧机为 8.0.46，版本串如有断言以本机为准）
- test/cases/52_d3_pgsql.php（手工 2>&1 发现，非套件差异） | 语义缺口登记 | php 的 log_errors=1 + error_log 空时每错写 stderr 一份 `PHP Deprecated:`/`PHP Fatal error:` 副本，phpx 仅走显示通道——差分 harness 只比 stdout 故不可见；Z 相 Zend 错误协议类用例可能踩到，登记 deferred.md（T006 发现）
- test/cases/51_d2_pdo_sqlite.php | expect（本机 php 8.4.17 链 SQLite 3.51.3；phpx 钉的 3.53.4 是旧机值） | 处置：pdo.ex sqlite_version 重钉 3.51.3（T004 修复，2026-10-03；换 oracle 版本须随迁）

_（其余条目在 R5（T012）重录时填充。）_
