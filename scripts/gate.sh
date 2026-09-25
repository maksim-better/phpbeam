#!/bin/zsh
# 一次性执行门禁（ARCHITECTURE_DESIGN.md §4）
#   1) mix escript.build
#   2) 非 phpt 套件全绿（exit 0 且 0 failures）
#   3) phpt 失败集不超出基线（基线失败清单 tmp/baseline_phpt_failures.txt；
#      基线 2026-09-26 = 410 失败 / 288 过）
# 用法：scripts/gate.sh          正常门禁
#       scripts/gate.sh --record 重建基线失败清单（仅在确认绿后手动使用）
set -u
cd "$(dirname "$0")/.."
mkdir -p tmp

mix escript.build >/dev/null 2>&1 || { echo "GATE: escript.build FAIL"; exit 1; }

mix test --exclude phpt >tmp/gate_nonphpt.log 2>&1
rc=$?
pkill -f 'phpx serve /tmp/phpbeam_http' 2>/dev/null
pkill -f 'php -S 127.0.0.1:18898' 2>/dev/null
line=$(grep -Eo '[0-9]+ tests?, [0-9]+ failures?(, [0-9]+ excluded)?' tmp/gate_nonphpt.log | tail -1)
echo "non-phpt: ${line:-NO SUMMARY} (exit=$rc)"

mix test --only phpt >tmp/gate_phpt.log 2>&1
pkill -f 'phpx serve /tmp/phpbeam_http' 2>/dev/null
pkill -f 'php -S 127.0.0.1:18898' 2>/dev/null
line=$(grep -Eo '[0-9]+ tests?, [0-9]+ failures?(, [0-9]+ excluded)?' tmp/gate_phpt.log | tail -1)
echo "phpt:     ${line:-NO SUMMARY}"

# ExUnit 失败块 "N) test xxx.phpt (Module)"——异步输出会把行首粘住，不能锚定 ^
grep -oE '[0-9]+\) test [a-zA-Z0-9./_-]+\.phpt \(PhpBeam\.Phpt\.[A-Za-z]+\.G[0-9]+\)' tmp/gate_phpt.log | sed -E 's/^[0-9]+\) //' | sort >tmp/phpt_failures_now.txt

if [ "${1:-}" = "--record" ]; then
  cp tmp/phpt_failures_now.txt tmp/baseline_phpt_failures.txt
  echo "baseline recorded: $(wc -l < tmp/baseline_phpt_failures.txt | tr -d ' ') failures"
  exit 0
fi

if [ ! -f tmp/baseline_phpt_failures.txt ]; then
  echo "GATE: WARN no baseline file (run scripts/gate.sh --record first)"
  exit 2
fi

comm -13 tmp/baseline_phpt_failures.txt tmp/phpt_failures_now.txt >tmp/phpt_new_failures.txt
new=$(wc -l < tmp/phpt_new_failures.txt | tr -d ' ')
if [ "$rc" -ne 0 ]; then
  echo "GATE: FAIL (non-phpt red)"
  tail -30 tmp/gate_nonphpt.log
  exit 1
fi
if [ "$new" -gt 0 ]; then
  echo "GATE: FAIL ($new NEW phpt failures):"
  head -10 tmp/phpt_new_failures.txt
  exit 1
fi
echo "GATE: PASS (phpt failures: $(wc -l < tmp/phpt_failures_now.txt | tr -d ' '), baseline $(wc -l < tmp/baseline_phpt_failures.txt | tr -d ' '))"
