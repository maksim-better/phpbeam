<?php
for ($i = 0; $i < 5; $i++) {
    if ($i == 2) continue;
    if ($i == 4) break;
    echo $i;
}
echo "\n";
$n = 0;
while (true) {
    $n++;
    if ($n >= 3) break;
}
echo $n, "\n";
do { echo "once "; } while (false);
echo "\n";
$x = 2;
switch ($x) {
    case 1: echo "one"; break;
    case 2: echo "two";
    case 3: echo "three"; break;
    default: echo "other";
}
echo "\n";
switch ("abc") { case 0: echo "loose"; break; default: echo "strict8"; }
echo "\n";
echo match(3) { 1 => "a", 2, 3 => "bc", default => "d" }, "\n";
$r = match(true) { 5 > 10 => "no", 5 > 3 => "yes" };
echo $r, "\n";
for ($i = 0; $i < 3; $i++) {
    for ($j = 0; $j < 3; $j++) {
        if ($j == 2) continue 2;
        echo "i$i-j$j ";
    }
}
echo "\n";
echo (3 > 2) ? "t" : "f", "|", 0 ?: "def", "|", null ?? "n", "\n";
