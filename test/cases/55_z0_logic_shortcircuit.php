<?php
$i = 0; $r = false && ($i = 99); var_dump($i, $r);
$j = 0; $s = true || ($j = 99); var_dump($j, $s);
class L { public function load() { $x = @require "/nonexistent-nope.php"; return $x; } }
var_dump((new L)->load() === false);
