<?php
// preg_* family: match/match_all (named groups, offset capture, set order),
// replace (backrefs, arrays, count), split, grep, quote
$n = preg_match("/(\d+)-(\w+)/", "id 42-ab", $m);
echo "n=$n m0={$m[0]} m1={$m[1]} m2={$m[2]}\n";

preg_match("/(?<year>\d{4})-(?<mo>\d{2})/", "date 2024-03", $d);
echo "y={$d['year']} mo={$d['mo']} k1={$d[1]}\n";

preg_match("/(\w)(\d)?/", "c", $t);
echo "trimmed=", count($t), "\n";

preg_match("/(\w+)/", "ab cd", $om, PREG_OFFSET_CAPTURE);
echo "off0={$om[0][1]} str={$om[0][0]}\n";

$cnt = preg_match_all("/(\w)(\d)?/", "a1 b2 c", $all, PREG_SET_ORDER);
echo "cnt=$cnt rows=", count($all), " r0={$all[0][0]} r2n=", count($all[2]), "\n";

$cnt2 = preg_match_all("/(\d)/", "1a2b", $po);
echo "f0={$po[0][0]}{$po[0][1]} g1={$po[1][0]}{$po[1][1]} cnt2=$cnt2\n";

echo preg_replace("/(\w+)@(\w+)/", "$2:$1", "user@host"), "\n";
echo preg_replace("/x/i", "0", ["k" => "xX", "j" => "y"])["k"], "\n";
$c = 0;
echo preg_replace(["/a/", "/b/"], ["X", "Y"], "abc", 1, $c), " c=$c\n";

echo preg_replace_callback("/(\d+)/", fn($mm) => "[" . $mm[1] . "]", "a1 b22"), "\n";

$parts = preg_split("/[\s,]+/", " a, b ,,c", -1, PREG_SPLIT_NO_EMPTY);
echo count($parts), " $parts[0]$parts[1]$parts[2]\n";

var_dump(preg_grep("/^\d+$/", ["12", "ab", "34", "x1"]));

echo preg_quote("a.b/c", "/"), " ", preg_quote("x*y"), "\n";

var_dump(preg_match("/[bad", "x"));
echo preg_replace("/(\d+)/", "\\1x", "a5b6"), "\n";
echo "__done__\n";
