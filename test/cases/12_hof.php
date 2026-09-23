<?php
$nums = [5, 3, 8, 1, 9, 2];

usort($nums, fn($a, $b) => $a <=> $b);
echo implode(",", $nums), "\n";
usort($nums, fn($a, $b) => $b <=> $a);
echo implode(",", $nums), "\n";

$names = ["charlie", "alpha", "bravo"];
usort($names, "strcmp");
echo implode(",", $names), "\n";

$products = [
    ["name" => "A", "price" => 30],
    ["name" => "B", "price" => 10],
    ["name" => "C", "price" => 20],
];
usort($products, fn($x, $y) => $x["price"] <=> $y["price"]);
echo implode(",", array_column($products, "name")), "\n";

$bykey = ["z" => 1, "y" => 2, "x" => 3];
uasort($bykey, fn($a, $b) => $b <=> $a);
echo implode(",", $bykey), "\n";
uksort($bykey, fn($a, $b) => $a <=> $b);
echo implode("|", array_keys($bykey)), "\n";

echo call_user_func("strtoupper", "mixed"), "\n";
echo call_user_func_array("implode", ["-", [1, 2, 3]]), "\n";
echo array_reduce([1, 2, 3, 4], fn($c, $i) => $c + $i), "\n";
echo implode(",", array_filter([1, 2, 3, 4, 5], fn($n) => $n % 2 == 0)), "\n";
echo implode(",", array_map(fn($n) => $n * $n, [1, 2, 3])), "\n";
echo implode(",", array_map(fn($a, $b) => $a . $b, [1, 2], ["x", "y"])), "\n";

$comparator = function ($a, $b) { return $a <=> $b; };
$more = [4, 2];
usort($more, $comparator);
echo implode(",", $more), "\n";
