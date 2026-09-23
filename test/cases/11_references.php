<?php
// 引用赋值
$a = 1;
$b = &$a;
$b = 5;
echo $a, "\n";
$c = &$a;
$c += 10;
echo $a, "|", $b, "|", $c, "\n";
unset($b);
$a = 100;
echo $c, "\n";

// 数组引用元素
$arr = [1, 2, 3];
foreach ($arr as &$v) {
    $v *= 10;
}
echo implode(",", $arr), "\n";

// foreach by-ref 写回
$data = ["x" => 1, "y" => 2, "z" => 3];
foreach ($data as $k => &$item) {
    $item = $item + 100;
}
echo implode(",", $data), "\n";

// 函数引用参数累积
function push_val(&$sink, $val) { $sink[] = $val; }
$sink = [];
push_val($sink, "a");
push_val($sink, "b");
echo implode("", $sink), "\n";

// 引用返回值跳过（少见）；可变引用 swap
$x = 1; $y = 2;
function swap(&$p, &$q) { $t = $p; $p = $q; $q = $t; }
swap($x, $y);
echo $x, "|", $y, "\n";

// sort 引用传参
$unsorted = [3, 1, 2];
sort($unsorted);
echo implode(",", $unsorted), "\n";
$assoc = ["b" => 3, "a" => 1];
asort($assoc);
echo implode(",", array_keys($assoc)), "|", implode(",", $assoc), "\n";
