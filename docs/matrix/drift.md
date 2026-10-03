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

_（本节在 R5（T012）重录时填充；此处为骨架——T003 交付物。）_
