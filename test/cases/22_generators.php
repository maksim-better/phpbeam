<?php
// M24 part 2: generators, autoload machinery, class scope, lazy consts,
// magic constants, stdClass, mb_/string builtins
function g1() { echo "started\n"; yield "a"; yield 10 => "b"; yield "c"; }
$g = g1();
echo "created\n";
foreach ($g as $k => $v) { echo "k=" . var_export($k, true) . " v=" . var_export($v, true) . "\n"; }
var_dump($g->valid());

function g2() { $x = yield; yield $x + 1; return "R"; }
$h = g2();
$h->send(5);
var_dump($h->current());
$h->next();
var_dump($h->valid(), $h->getReturn());

function g6() { yield from [1, 2, 3]; yield from g1(); }
foreach (g6() as $k => $v) { echo "$k:$v "; }
echo "\n";

class GenCls {
    private $n;
    public function __construct($n) { $this->n = $n; }
    public function upto() { for ($i = 0; $i < $this->n; $i++) { yield $i * $i; } }
}
foreach ((new GenCls(4))->upto() as $sq) { echo $sq, " "; }
echo "\n";

$mk = function($a) { foreach ($a as $x) { yield $x * 2; } };
foreach ($mk([1,2,3]) as $d) { echo $d, " "; }
echo "\n";

function g7() { yield 1; throw new Exception("boom"); }
try { foreach (g7() as $v) { echo "v=$v "; } } catch (Exception $e) { echo "caught: ", $e->getMessage(), "\n"; }

// spl_autoload + namespaced class + alias resolution + self:: consts
class AutoT {
    public static function load($c) {
        if ($c === 'Tn\\Lib') { eval('namespace Tn; class Lib { const V = "3.3"; public static function hi() { return "hi-" . self::V; } }'); return true; }
        return false;
    }
}
spl_autoload_register(['AutoT', 'load']);
var_dump(Tn\Lib::hi());

// magic constants
function mc() { return __FUNCTION__ . "/" . __CLASS__ . "/" . __NAMESPACE__; }
var_dump(mc());

$o = new stdClass();
$o->dyn = 42;
var_dump($o->dyn, get_class($o));

var_dump(strip_tags("<p>Hi <b>there</b>!</p>", "<b>"));
var_dump(mb_strlen("héllo"), mb_substr("héllo", 1, 2), mb_strtolower("HÉ"));
var_dump(addslashes("a'b"), stripslashes("a\\'b"));
echo "end\n";

// ref-assign onto elements (M24 part 3)
class RA { public static $c = ["a" => ["n" => 1]]; public $p = ["x" => 2]; }
$ra = &RA::$c["a"];
$ra["n"] = 42;
var_dump(RA::$c["a"]["n"]);
$ro = new RA;
$rw = &$ro->p["x"];
$rw = 9;
var_dump($ro->p["x"]);
$rarr = ["k" => "orig"];
$rz = &$rarr["k"];
$rz = "changed";
var_dump($rarr["k"]);
$rd = ["deep" => ["n" => 1]];
$rd["deep"]["n"] = 99;
$rk = "key";
$rd[$rk]["x"] = 5;
var_dump($rd["deep"]["n"], $rd["key"]["x"]);
echo "refend\n";
