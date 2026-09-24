<?php
// eval + func_get_args family: scope sharing, return values, pseudo-file
// warnings, argument snapshots, error frames
$x = 10;

function probe($a, $b = 2, ...$rest) {
    echo "num=", func_num_args(), " arg1=", var_export(func_get_arg(1), true), "\n";
    $snap = func_get_args();
    echo "first=", $snap[0], " count=", count($snap), "\n";
    return $a + $b;
}

echo "probe=", probe(7, 9, 11, 13), "\n";

$v = eval('return $x * 2;');
echo "eval-ret=", var_export($v, true), "\n";

$noReturn = eval('$y = 5;');
echo "eval-null=", var_export($noReturn, true), " y=", $y, "\n";

eval('function from_eval() { return "def"; }');
echo "eval-def=", from_eval(), "\n";

class Holder { public $p = 3;
    function m() { return eval('return $this->p + 1;'); }
}
echo "eval-this=", (new Holder())->m(), "\n";

function evaled_warn() { eval('echo $undef_in_eval;'); }
evaled_warn();

function caught() {
    try { func_get_arg(-1); } catch (ValueError $e) {
        echo "caught=", get_class($e), ": ", substr($e->getMessage(), 0, 30), "...\n";
    }
}
caught();

echo "__main_done__\n";
