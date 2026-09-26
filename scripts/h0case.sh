#!/bin/zsh
# H0 迭代助手：scripts/h0case.sh classes/abstract_redeclare
# 从 phpt 抽 --FILE-- 生成 <base>.phpbeam.php（同目录，同 cwd 语义），双侧跑 diff
set -u
rel="${1%.phpt}"
src="/Users/guozhu/Downloads/php-8.4.24/tests/${rel}.phpt"
copy="${src%.phpt}.phpbeam.php"
[ -f "$copy" ] || awk '/^--FILE--$/{f=1;next} /^--[A-Z_]+--$/{f=0} f' "$src" > "$copy"
cd "${copy:h}"
echo "═══ php ═══"; perl -e 'alarm 10; exec @ARGV' /opt/homebrew/bin/php "${copy:t}" 2>&1
echo "═══ phpx ═══"; perl -e 'alarm 10; exec @ARGV' "/Users/guozhu/WorkSpace/ai/php/phpbeam/phpx" "${copy:t}" 2>&1
