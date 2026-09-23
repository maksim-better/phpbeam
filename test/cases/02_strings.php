<?php
$s = "Hello World";
echo strtoupper($s), "|", strtolower($s), "|", ucfirst("abc"), "|", ucwords("a b c"), "\n";
echo strlen($s), "|", substr($s, 6), "|", substr($s, -5), "|", substr($s, 0, 5), "\n";
echo strpos($s, "World"), "|", strpos($s, "x") === false ? "f" : "t", "\n";
echo str_replace("World", "BEAM", $s), "|", strrev("abc"), "\n";
echo str_pad("5", 3, "0", STR_PAD_LEFT), "\n";
echo trim("  x  "), "|", ltrim("--x--", "-"), "|", rtrim("x\n\n", "\n"), "\n";
echo implode("-", [1, 2, 3]), "|";
print_r(explode(",", "a,b,c"));
echo substr_count("aXbXc", "X"), "|", str_contains("abc", "b") ? "y" : "n", "|", str_starts_with("abc", "ab") ? "y" : "n", "\n";
echo sprintf("%05.2f|%d|%s|%+d", 3.14159, 42, "s", 7), "\n";
echo "abc" . 1 . 2.5 . true . false . null, "\n";
printf("[%s]\n", "x");
echo number_format(1234567.891, 2, ",", "."), "\n";
