# Contract: 门禁与判定命令 CLI（scripts/gate.sh, scripts/criterion.sh）

本 feature 对外暴露的接口是两个 shell 命令。调用方：开发者日常提交、批次收尾、CI 式复现。

## `scripts/gate.sh` — 三 lane 门禁

```console
scripts/gate.sh                          # 目录 lane：按映射表推导改动 → 目录集；无改动信息时等价 full
scripts/gate.sh --lane fast              # 快 lane：escript.build + 非 phpt 全绿（≤10 分钟）
scripts/gate.sh --lane dirs -- <dir-id>… # 显式目录集：非 phpt + 指定分片的只收缩比对
scripts/gate.sh --lane full              # 全量 lane：非 phpt + 全部已纳入目录 + 分片和自检
scripts/gate.sh --record                 # 全量重录基线（仅绿非 phpt 后手动使用；重写 tmp/baseline/*.txt）
scripts/gate.sh --record -- <dir-id>…    # 只重录指定分片（新目录纳入用）
```

**行为约定**：

- 三 lane 均先 `mix escript.build`，失败即 FAIL exit 1。
- 非 phpt 段任何失败 → FAIL（与现状一致）。
- 目录 lane 的目录集 = `git diff --name-only <base>..HEAD` 经映射表（E4）推导；**映射未命中 → 全部已纳入目录**（fail-safe）；引擎核心路径 → 全部。
- 比对语义：`comm -13 baseline/<dir>.txt failures_now/<dir>.txt` 非空 = 新失败 = FAIL（只收缩）。
- 全量 lane 额外自检：各分片行数和 == 本轮全量失败清单行数（防分片腐化）。
- 每次 lane 结束清扫孤儿 `phpx serve`（沿用现行 pkill 逻辑）。
- 退出码：0=PASS；1=FAIL（构建/非 phpt/新失败）；2=基线缺失（提示 --record）。

## `scripts/criterion.sh` — 判据机械判定

```console
scripts/criterion.sh --mode freeze       # 冻结判据：未豁免失败项数（0 = F 可启动）
scripts/criterion.sh --mode phase -- Z   # 相出口：未登记失败项数（豁免∪顺延；0 = 相达标）
```

**行为约定**：

- 输入：最新全量失败清单（无则提示先跑 `--lane full`）+ 登记账本（E2/E3）。
- 输出：达标与否 + 未登记项列表（前 20 条 + 总数）；同一提交点重复运行输出必须一致。
- 退出码：0=达标；1=未达标（列出未登记项）；2=输入缺失。
- 免责口径：`freeze` 只认豁免集；`phase` 认豁免∪顺延——两模式差异是规格 SC-002/SC-006 的直接实现。
