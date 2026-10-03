#!/bin/zsh
# 门禁（契约：specs/001-phpt-semantic-completion/contracts/gate-cli.md）
#   scripts/gate.sh                          # 目录 lane：git 改动 ×映射表推导目录集；无映射表=全量（fail-safe）
#   scripts/gate.sh --lane fast              # 快 lane：escript.build + 非 phpt 全绿
#   scripts/gate.sh --lane dirs -- <dir-id>… # 目录 lane 显式目录集：非 phpt + 指定分片只收缩比对
#   scripts/gate.sh --lane full              # 全量 lane：非 phpt + 全部已纳入目录 + 分片和自检
#   scripts/gate.sh --record                 # 全量重录基线（仅绿后手动）
#   scripts/gate.sh --record -- <dir-id>…    # 只重录指定分片（新目录首录用）
#
# 基线：tmp/baseline/<dir-id>.txt，行格式 `test <file>.phpt (Module.GN)`，
# 只允许收缩（comm -13 语义）；全量失败清单 = 全部分片按字典序 concat（full 自检）。
# 退出码：0=PASS 1=FAIL 2=基线缺失。
set -u
cd "$(dirname "$0")/.."
mkdir -p tmp tmp/baseline tmp/failures_now

die() { echo "GATE: FAIL ($1)"; exit 1; }
usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -12; exit 2; }

lane="" record=0 dirs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --lane)  lane="${2:-}"; shift 2 ;;
    --record) record=1; shift ;;
    --)      shift; while [ $# -gt 0 ]; do dirs+=("$1"); shift; done ;;
    -h|--help) usage ;;
    *)       echo "GATE: unknown arg '$1'"; usage ;;
  esac
done
[ -n "$lane" ] && [ "$lane" != fast ] && [ "$lane" != dirs ] && [ "$lane" != full ] && usage
[ "$lane" = dirs ] && [ ${#dirs[@]} -eq 0 ] && { echo "GATE: dirs lane needs -- <dir-id>..."; usage; }

mix escript.build >/dev/null 2>&1 || die "escript.build"

sweep() {
  pkill -f 'phpx serve /tmp/phpbeam_http' 2>/dev/null
  pkill -f 'php -S 127.0.0.1:18898' 2>/dev/null
  # orphans also bind 18899 and linger with ppid=1 — sweep by the serve keyword
  pkill -9 -f 'phpx serve' 2>/dev/null || true
}

run_nonphpt() {
  mix test --exclude phpt >tmp/gate_nonphpt.log 2>&1
  local rc=$?; sweep
  local line
  line=$(grep -Eo '[0-9]+ tests?, [0-9]+ failures?(, [0-9]+ excluded)?' tmp/gate_nonphpt.log | tail -1)
  echo "non-phpt: ${line:-NO SUMMARY} (exit=$rc)"
  [ "$rc" -ne 0 ] && { tail -30 tmp/gate_nonphpt.log; die "non-phpt red"; }
  return 0
}

# run phpt for the dir set (empty = all), then split failures into tmp/failures_now/<dir>.txt
run_phpt() {
  rm -f tmp/failures_now/*.txt(N)
  if [ ${#dirs[@]} -gt 0 ]; then
    PHPT_DIRS="${(j:,:)dirs}" mix test test/phpbeam/phpt_test.exs --only phpt >tmp/gate_phpt.log 2>&1
  else
    mix test test/phpbeam/phpt_test.exs --only phpt >tmp/gate_phpt.log 2>&1
  fi
  sweep
  local line
  line=$(grep -Eo '[0-9]+ tests?, [0-9]+ failures?(, [0-9]+ excluded)?' tmp/gate_phpt.log | tail -1)
  echo "phpt:     ${line:-NO SUMMARY} ${dirs:+(dirs: ${(j:,:)dirs})}"
  # ExUnit failure block "N) test <dir>/<file>.phpt (Module)" — async output glues lines, never anchor ^
  grep -oE '[0-9]+\) test [a-zA-Z0-9./_-]+\.phpt \(PhpBeam\.Phpt\.[A-Za-z]+\.G[0-9]+\)' tmp/gate_phpt.log \
    | sed -E 's/^[0-9]+\) //' | sort | awk '{split($2, a, "/"); print > ("tmp/failures_now/" a[1] ".txt")}'
  return 0
}

# compare the given shards (or every shard in tmp/failures_now) against baseline
compare_shards() {
  local targets=() new_total=0
  if [ ${#dirs[@]} -gt 0 ]; then targets=("${dirs[@]}"); else targets=(tmp/failures_now/*.txt(N)); targets=(${${targets##*/}%.txt}); fi
  local d
  for d in "${targets[@]}"; do
    local base="tmp/baseline/$d.txt"
    if [ ! -f "$base" ]; then echo "GATE: WARN no baseline shard for '$d' (run: scripts/gate.sh --record -- $d)"; exit 2; fi
    local now="tmp/failures_now/$d.txt"; [ -f "$now" ] || : >"$now"
    local new
    new=$(comm -13 "$base" "$now" | wc -l | tr -d ' ')
    if [ "$new" -gt 0 ]; then
      echo "GATE: FAIL ($new NEW phpt failures in $d):"
      comm -13 "$base" "$now" | head -10
      exit 1
    fi
    echo "shard $d: $(wc -l < "$base" | tr -d ' ') baseline / $(wc -l < "$now" | tr -d ' ') now (only-shrink ok)"
    new_total=$((new_total + $(wc -l < "$now" | tr -d ' ')))
  done
}

shard_sum_selfcheck() {
  local total now_sum
  total=$(cat tmp/failures_now/*.txt(N) 2>/dev/null | wc -l | tr -d ' ')
  now_sum=$(cat tmp/failures_now/*.txt(N) 2>/dev/null | sort | wc -l | tr -d ' ')
  [ "$total" -ne "$now_sum" ] && die "shard sum self-check (duplicate failure lines across shards?)"
  local base_sum
  base_sum=$(cat tmp/baseline/*.txt(N) 2>/dev/null | wc -l | tr -d ' ')
  echo "self-check: shards $total lines, baseline sum $base_sum"
}

# changed files (stdin) → dir set. gate_map.conf rule: `glob -> ALL | dir,dir` (# comments; empty dst = fast lane)
# first matching rule wins; no rule matching the file = ALL (fail-safe); no conf at all = ALL.
phpbeam_map_dirs() {
  local conf=scripts/gate_map.conf
  local -a out
  local path line pat dst
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    local matched=0
    while IFS= read -r line; do
      case "$line" in '#'*|'') continue ;; esac
      pat="${line%%->*}"; dst="${line##*->}"
      pat="${${pat%%[[:space:]]}##[[:space:]]}"
      dst="${${dst%%[[:space:]]}##[[:space:]]}"
      if [[ "$path" == ${~pat} ]]; then
        matched=1
        case "$dst" in
          ALL) echo ALL; return ;;
          "")  : ;;
          *)   out+=("${(s:,:)dst}") ;;
        esac
        break
      fi
    done < "$conf"
    [ "$matched" -eq 0 ] && { echo ALL; return; }   # fail-safe: unmapped change
  done
  printf '%s\n' ${(u)out}
}

# ---- lanes -----------------------------------------------------------------
if [ "$record" -eq 1 ]; then
  run_nonphpt
  run_phpt
  if [ ${#dirs[@]} -eq 0 ]; then
    for f in tmp/failures_now/*.txt(N); do cp "$f" "tmp/baseline/${f:t}"; done
  else
    for d in "${dirs[@]}"; do cp "tmp/failures_now/$d.txt" "tmp/baseline/$d.txt"; done
  fi
  local n_shards=$(ls tmp/baseline | wc -l | tr -d ' ')
  echo "baseline recorded: $(cat tmp/baseline/*.txt(N) 2>/dev/null | wc -l | tr -d ' ') failures across $n_shards shards"
  exit 0
fi

case "${lane:-}" in
  fast)
    run_nonphpt
    echo "GATE: PASS (fast lane)"
    ;;
  dirs)
    run_nonphpt
    run_phpt
    compare_shards
    echo "GATE: PASS (dirs lane: ${(j:,:)dirs})"
    ;;
  full)
    run_nonphpt
    run_phpt
    compare_shards
    shard_sum_selfcheck
    echo "GATE: PASS (full lane)"
    ;;
  "")
    # directory lane: git changed files × gate_map.conf derive the directory set; fail-safe when no mapping = full
    mapfile=scripts/gate_map.conf
    if [ ! -f "$mapfile" ]; then
      echo "no gate_map.conf — fail-safe to full lane"
      run_nonphpt; run_phpt; compare_shards; shard_sum_selfcheck
      echo "GATE: PASS (full lane via fail-safe)"
    else
      changed=$( { git status --porcelain 2>/dev/null | awk '{print $NF}'; git diff --name-only "$(git merge-base master HEAD)" 2>/dev/null; } | sort -u)
      dirs=($(phpbeam_map_dirs "$changed"))
      if [ ${#dirs[@]} -eq 0 ]; then
        run_nonphpt
        echo "GATE: PASS (fast lane — mapping of changes is empty)"
      elif [ ${#dirs[@]} -eq 1 ] && [ "${dirs[1]}" = ALL ]; then
        run_nonphpt; run_phpt; compare_shards; shard_sum_selfcheck
        echo "GATE: PASS (full lane — mapping hit ALL)"
      else
        run_nonphpt; run_phpt; compare_shards
        echo "GATE: PASS (dirs lane: ${(j:,:)dirs})"
      fi
    fi
    ;;
  *) usage ;;
esac
