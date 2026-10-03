# Contract: 账本与基线文件格式（机器可读约定）

`criterion.sh` 与 `gate.sh` 依赖以下稳定格式。原则：文本、grep 可解析、人不看工具也能读。

## 失败基线分片 `tmp/baseline/<dir-id>.txt`

- 每行一条，沿用现行格式：`test <file>.phpt (PhpBeam.Phpt.<FlatName>.G<N>)`
- `<dir-id>` 扁平标识约定：`tests/` 顶层目录 → 原名（`lang`/`security`/…）；`Zend/tests` 根级散文件 → `zend-root`；`Zend/tests/<sub>` → `zend-<sub>`；`ext/<name>/tests` → `ext-<name>`
- 全量失败清单 = 全部分片按字典序 concat（gate 全量 lane 自检此不变量）

## 豁免登记 `docs/matrix/exempt.md` — 机器可读行

用例级与目录级各一种稳定行格式（其余散文保持现状，解析器只认标记行）：

```text
EXEMPT-CASE <用例路径相对 php-src> | <理由> | 解除: <条件>
EXEMPT-DIR  <dir-id 或目录路径>       | <理由> | 解除: <条件>
```

既有散文表不迁移——新登记一律用标记行；目录级 16 扩展 + OPcache + FFI C 编译类在 R 相一次性补 `EXEMPT-DIR` 行。

## 顺延登记 `docs/matrix/deferred.md` — 机器可读行

```text
DEFER <简述> | <dir-id 或引擎域> | 根因: <一句> | 再入: <条件> | 登记: <日期>
```

既有条目在相出口盘点时顺带转成标记行（转写不改语义）。

## 分诊报表 `tmp/triage/<dir-id>.md`

```markdown
# Triage: <dir-id> 批次 <N>
初始失败: <K>
| class | 数量 | 处置 | 去向 |
|---|---|---|---|
| <class=标签> | n | 修复 x / 豁免 y / 顺延 z | <commit 或登记引用> |
守恒校验: 修复 X + 豁免 Y + 顺延 Z = K ✓
```

## 目录映射表 `scripts/gate_map.conf`

```text
# glob（相对仓库根,fnmatch 语义） -> ALL | dir-id 逗号列表   # 理由注释
lib/phpbeam/eval*.ex            -> ALL                      # 引擎核心
lib/phpbeam/builtin/date_fns.ex -> ext-date,zend-root       # 域模块
test/**                         ->                          # 空=快通道即可
```

解析规则：首条命中生效；未命中 → `ALL`。

## 环境不可得清单 `tmp/env_blocked/<dir-id>.txt`

每行 `用例路径 | 缺失环境标签（mysql|ftp|network）`；全量通道运行时凡清单内用例重新出现即视为待复跑（Q3 复跑义务的机械执行）。
