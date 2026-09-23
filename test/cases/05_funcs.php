<?php
function add($a, $b) { return $a + $b; }
function greet($name = "World") { return "Hello, $name!"; }
function variadic($first, ...$rest) { return $first . ":" . implode("|", $rest); }
function fib($n) { return $n < 2 ? $n : fib($n - 1) + fib($n - 2); }
function counter() { static $c = 0; return ++$c; }

echo add(2, 3), "\n";
echo greet(), "|", greet("BEAM"), "\n";
echo variadic("a", "b", "c"), "\n";
echo fib(15), "\n";
echo counter(), counter(), counter(), "\n";

$double = function ($x) { return $x * 2; };
echo $double(21), "\n";
$add_n = fn($a) => $a + $n = 5;
echo (fn($x) => $x ** 2)(9), "\n";
$byref = 10;
function inc(&$x) { $x++; }
inc($byref);
echo $byref, "\n";
$names = ["alice", "bob"];
$upper = array_map(fn($s) => strtoupper($s), $names);
echo implode(",", $upper), "\n";
function outer() {
    $v = "captured";
    $f = function () use ($v) { return $v; };
    return $f();
}
echo outer(), "\n";
$fact = function ($n) use (&$fact) { return $n <= 1 ? 1 : $n * $fact($n - 1); };
echo $fact(6), "\n";
