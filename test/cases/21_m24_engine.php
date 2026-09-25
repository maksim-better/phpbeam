<?php
// M24 engine fixes harvest: GLOBALS write-through, __get/__set recursion
// guards, nested property writes, str_replace &$count, std streams,
// anonymous classes, trailing commas, define() semantics, display_errors
define('A1', 1);
$r = define('A1', 2);
var_dump($r, A1);

function set_g() { $GLOBALS['gx'] = 42; }
function read_g() { global $gx; return $gx; }
set_g();
var_dump(read_g());

class Nested {
    public $cb = [];
    public function m($p, $i) {
        $ex = isset($this->cb[$p]);
        $this->cb[$p][$i] = array('f' => 1);
        $this->cb[$p][$i]['g'] = 2;
        return array($ex, count($this->cb[$p]), $this->cb[$p][$i]['g']);
    }
}
var_dump((new Nested())->m(10, 'k1'));

$c = 5;
var_dump(str_replace("a", "b", "aabaa", $c), $c);
$c = 0;
var_dump(str_replace(["a","b"], "", "aabb", $c), $c);
$c = 9;
var_dump(str_replace("zz", "b", "abc", $c), $c);
var_dump(str_replace("", "x", "abc"));

function deep( $search, $subject ) {
    $count = 1;
    $n = 0;
    while ( $count ) {
        $subject = str_replace( $search, '', $subject, $count );
        $n++;
        if ($n > 5) return "LOOP";
    }
    return $subject;
}
var_dump(deep(['%0d', '%0a', '%0D', '%0A'], 'http://x/%0Dpath?q=1'));

$n = fwrite(STDOUT, "hi\n");
var_dump($n);

class AnonBase { public $v; public function __construct($v) { $this->v = $v; } protected function base() { return "base"; } }
$o = new class(42) extends AnonBase {
    public function get() { return $this->v; }
    public function callBase() { return $this->base(); }
};
var_dump($o->get(), $o->callBase(), $o instanceof AnonBase);
var_dump(is_callable('str_replace'));

function trailing($a, $b) { return $a + $b; }
var_dump(trailing(
    1,
    2,
));
echo "end\n";
