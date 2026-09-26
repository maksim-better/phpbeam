<?php
// PHASE A1c: assert() semantics — zend_ast_export message, descriptions,
// Throwable descriptions; plus the arrow-fn auto-capture it exercises
$x = 5;
try { assert($x === 1); } catch (AssertionError $e) { echo "M: ", $e->getMessage(), "\n"; }
try { assert(strlen("abc") > 10); } catch (AssertionError $e) { echo "M: ", $e->getMessage(), "\n"; }
try { assert($x > 1 && $x < 2); } catch (AssertionError $e) { echo "M: ", $e->getMessage(), "\n"; }
try { assert(!$x); } catch (AssertionError $e) { echo "M: ", $e->getMessage(), "\n"; }
try { assert(0 == "a"); } catch (AssertionError $e) { echo "M: ", $e->getMessage(), "\n"; }
try { assert(null); } catch (AssertionError $e) { echo "M: ", $e->getMessage(), "\n"; }
try { assert(false, "custom desc"); } catch (AssertionError $e) { echo "M: ", $e->getMessage(), "\n"; }
try { assert(false, new RuntimeException("thrown-desc")); } catch (RuntimeException $e) { echo "O: ", get_class($e), " ", $e->getMessage(), "\n"; }
var_dump(assert(true), assert($x === 5));

// arrow functions auto-capture outer vars by value (engine fix A1c)
$double = fn($v) => $v * $x;
var_dump($double(4));
$make = fn() => fn() => $x + 1;
var_dump($make()());
$captured = 10;
$fn = function () use ($captured) { return $captured + $x; };
var_dump($fn());
echo "done\n";
