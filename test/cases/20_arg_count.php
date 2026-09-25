<?php
// ArgumentCountError family: php-exact messages, catchability, throw-in-arg
function exact2($a, $b) {}
function atleast2($a, $b, $c = 1) {}
function variadic1($a, ...$rest) {}

try { exact2(1); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
try { exact2(); } catch (ArgumentCountError $e) { echo $e->getMessage(), "\n"; }
try { atleast2(1); } catch (Throwable $e) { echo $e->getMessage(), "\n"; }
try { atleast2(); } catch (Throwable $e) { echo $e->getMessage(), "\n"; }
try { variadic1(); } catch (Throwable $e) { echo $e->getMessage(), "\n"; }

// extra args are never an error
exact2(1, 2, 3, 4);
echo "extra ok\n";

// methods use the DEFINING class, :: even for instance calls
class Base { public function m($x) {} static function s($y) {} }
class Child extends Base {}

try { (new Child)->m(); } catch (Throwable $e) { echo $e->getMessage(), "\n"; }
try { Child::s(); } catch (Throwable $e) { echo $e->getMessage(), "\n"; }

// constructors
class P { public function __construct($q) {} }
try { new P(); } catch (Throwable $e) { echo $e->getMessage(), "\n"; }

// closures are named by definition site
$f = function($a, $b) {};
$g = fn($x) => $x;
try { $f(3); } catch (Throwable $e) { echo $e->getMessage(), "\n"; }
try { $g(); } catch (Throwable $e) { echo $e->getMessage(), "\n"; }
try { call_user_func($f); } catch (Throwable $e) { echo $e->getMessage(), "\n"; }

// a throw inside an argument expression propagates (no engine crash)
function boom() { throw new Exception("boom"); }
function one($a) { echo "one ran\n"; }
try { one(boom()); } catch (Exception $e) { echo "caught: ", $e->getMessage(), "\n"; }
try { one(...[boom()]); } catch (Exception $e) { echo "caught-spread: ", $e->getMessage(), "\n"; }

// is_callable on closures
var_dump(is_callable($f), is_callable($g), is_callable("strlen"));
echo "end\n";
