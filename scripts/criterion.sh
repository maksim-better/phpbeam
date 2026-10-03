#!/bin/zsh
# 判据机械判定（契约：specs/001-phpt-semantic-completion/contracts/gate-cli.md）
#   scripts/criterion.sh --mode freeze        # 冻结判据：未「豁免」失败项数（0 = PHASE F 可启动）
#   scripts/criterion.sh --mode phase -- Z    # 相出口：未「登记」失败项数（豁免∪顺延；0 = 相达标）
#
# 输入：tmp/failures_now/*.txt（最近一次 gate 全量/目录 lane 的失败分片；行格式
#   `test <dir-id>/<file>.phpt (Module.GN)`）。无分片 → 提示先跑 full lane（exit 2）。
# 账本（docs/matrix/，机器可读标记行，格式见 contracts/baseline-formats.md）：
#   EXEMPT-CASE <用例标识或 php-src 相对路径> | 理由 | 解除: 条件   —— 终态豁免（两种模式都计入）
#   EXEMPT-DIR  <dir-id>                      | 理由 | 解除: 条件   —— 目录级豁免
#   DEFER      <简述> | <dir-id[,…] 或 ALL>   | 根因… | 再入… | 登记…  —— 顺延（仅 phase 模式容忍）
# 顺延不计入 freeze 达标（规格 SC-006：豁免集才算数）。
# 退出码：0=达标 1=未达标（列未登记项）2=输入缺失。
set -u
cd "$(dirname "$0")/.."

mode="" ; phase=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 ;;
    --) shift; phase="${1:-}"; shift ;;
    *) echo "criterion: unknown arg '$1'"; exit 2 ;;
  esac
done
case "$mode" in
  freeze) [ -n "$phase" ] && { echo "criterion: freeze 模式不接相名"; exit 2; } ;;
  phase)  [ -n "$phase" ] || { echo "criterion: phase 模式需要 -- <相名>"; exit 2; } ;;
  *) echo "usage: scripts/criterion.sh --mode freeze | --mode phase -- <相名>"; exit 2 ;;
esac

failures=$(cat tmp/failures_now/*.txt(N) 2>/dev/null)
if [ -z "$failures" ]; then
  echo "criterion: 无失败分片（tmp/failures_now/ 空）——先跑 scripts/gate.sh --lane full"
  exit 2
fi

# ---- 账本读取 ---------------------------------------------------------------
exempt_cases=(${(f)"$(grep -h '^EXEMPT-CASE' docs/matrix/exempt.md 2>/dev/null | awk '{print $2}')"})
exempt_dirs=(${(f)"$(grep -h '^EXEMPT-DIR' docs/matrix/exempt.md 2>/dev/null | awk '{print $2}')"})
defer_dirs=()
if [ "$mode" = phase ]; then
  for f in ${(f)"$(grep -h '^DEFER' docs/matrix/deferred.md 2>/dev/null | awk -F'|' '{print $2}')"}; do
    f="${f// /}"
    [ -n "$f" ] && defer_dirs+=(${(s:,:)f})
  done
fi

# ---- 作差 -------------------------------------------------------------------
total=0 exempted=0 tolerated=0
unregistered=()
for line in ${(f)failures}; do
  total=$((total+1))
  id="${line#test }"; id="${id%% *}"         # 截到首个空格 → dir/file.phpt
  dir="${id%%/*}"
  hit=0
  for ec in "${exempt_cases[@]}"; do
    if [ "$ec" = "$id" ] || [ "$ec" = "*/$id" ]; then hit=1; break; fi
  done
  if [ $hit -eq 0 ]; then
    for ed in "${exempt_dirs[@]:-}"; do [ "$ed" = "$dir" ] && { hit=1; break; } ; done
  fi
  if [ $hit -eq 1 ]; then exempted=$((exempted+1)); continue; fi
  if [ "$mode" = phase ]; then
    for dd in "${defer_dirs[@]:-}"; do
      [ "$dd" = "$dir" ] || [ "$dd" = ALL ] && { hit=2; break; }
    done
    if [ $hit -eq 2 ]; then tolerated=$((tolerated+1)); continue; fi
  fi
  unregistered+=("$id")
done

echo "criterion[$mode${phase:+/$phase}]: 失败 $total = 豁免 $exempted + 顺延容忍 $tolerated + 未登记 ${#unregistered[@]}"
if [ ${#unregistered[@]} -gt 0 ]; then
  echo "未登记项（前 20）："
  printf '  %s\n' "${unregistered[@]:0:20}"
  [ ${#unregistered[@]} -gt 20 ] && echo "  …共 ${#unregistered[@]} 项"
  exit 1
fi
echo "达标（mode=$mode${phase:+ 相=$phase}${phase:+：顺延项须在 F 冻结前清偿或转豁免}）"
exit 0
