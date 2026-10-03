# Quickstart: 验证 phpt 语义完备主线

端到端证明本 feature 成立的三个 runnable 场景：R 相设施恢复验收、Z 相单批次工作流验收、判据机械判定验收。命令均为仓库根执行。

## 前置条件

- `/Users/5i5j/Downloads/php-8.4.25` 存在（php-src 源树）
- `/opt/homebrew/bin/php`（8.4.17）可用
- `MIX_REBAR3=~/.mix/rebar3`（hex 被挡的绕行，brew rebar3 已拷贝）
- X2 相关验证另需 OrbStack + `phpbeam-mysql` 容器

## 场景 1：R 相完成——设施恢复验收

```console
# 1. 依赖重落 + 补丁重放 + 构建
mix deps.get && git apply scripts/patches/exqlite-load-nif.patch
mix escript.build

# 2. 三 lane 全通
scripts/gate.sh --lane fast          # 期望: GATE: PASS（非 phpt 全绿, ≤10 分钟）
scripts/gate.sh --lane full          # 期望: GATE: PASS + 分片和自检行
ls tmp/baseline/ | head              # 期望: 每个已纳入目录一个分片文件

# 3. MySQL 差分恢复（先启动 OrbStack）
docker start phpbeam-mysql
mix test test/phpbeam/diff_test.exs  # 期望: D 系 47–52 全绿
```

**通过判据**：三条命令全过、基线分片数 = 已纳入目录数、PLAN 矩阵总账已按本机重记（含 run-test/security 63 例与漂移登记）。

## 场景 2：Z 相单批次——纳入→分诊→清偿→收缩

以 `Zend/tests/exit`（25 例，小目录适合首批演练）为例：

```console
# 1. harness 纳入（phpt_test.exs 的目录列表加 zend-exit → zend/tests/exit 映射）
# 2. 首录该分片基线（绿非 phpt 前提）
scripts/gate.sh --lane fast && scripts/gate.sh --record -- zend-exit

# 3. 全量分诊（失败按 class= 聚类），产出 tmp/triage/zend-exit.md
#    计数守恒: 修复 X + 豁免 Y + 顺延 Z = 初始失败 K
# 4. 清偿后该分片只剩登记项，且不引入新失败
scripts/gate.sh --lane dirs -- zend-exit    # 期望: GATE: PASS
scripts/criterion.sh --mode phase -- Z      # Z 相全部批次完成后: 期望 exit 0
```

**通过判据**：分诊报表守恒校验 ✓、分片单调收缩、冒烟三件套（`phpx artisan --version` / WP install 渲染 / composer）全过。

## 场景 3：判据机械判定——任意提交点可复现

```console
scripts/gate.sh --lane full
scripts/criterion.sh --mode freeze   # 未豁免失败项 N
scripts/criterion.sh --mode freeze   # 同点重跑, 期望 N 完全一致
```

**通过判据**：同一提交点两次运行输出一致；随 Z→X→E′ 推进 N 单调下降；N=0 即 F 冻结判据达成。

## 各阶段验收锚点速查

| 阶段 | 命令 | 期望 |
|---|---|---|
| R | 场景 1 全部 | 三 lane PASS + 差分绿 |
| Z | `criterion.sh --mode phase -- Z` | exit 0 |
| X1/X2 | `criterion.sh --mode phase -- X1` 等 | exit 0 |
| E′ | intl 场景锚差分 + sodium 用例 + 两节设计文档 | 见 spec SC-004 |
| F0 | 尖曝结论文档 | 两路输出逐字节一致或明确不可行 |
| 终态 | `criterion.sh --mode freeze` | exit 0 |
