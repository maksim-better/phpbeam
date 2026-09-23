<?php
var_dump(42, 3.14, "str", true, false, null);
var_dump([1, "two", 3.5, [4, 5]]);
print_r(["a" => 1, "b" => ["c" => 2]]);
print_r(true);
print_r("x", true);
var_dump([]);
echo var_export([1, "a" => 'b', 2.5], true), "\n";
echo json_encode(["list" => [1, 2], "assoc" => ["x" => 1], "mix" => [0 => "a", "k" => "b"]]), "\n";
$j = json_decode('{"a": [1, 2], "b": {"c": true}}');
var_dump($j);
var_dump(json_decode('[1, 2, "x"]'));
