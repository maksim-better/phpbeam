<?php
class T { public int $x; }
$t = new T;
try { var_dump($t->x); } catch (Error $e) { echo "caught: ", $e->getMessage(), "\n"; }
var_dump(isset($t->x));
var_dump($t->x ?? 1);
class U { public ?int $n; public string $s = "hi"; }
$u = new U;
var_dump($u->s);
$u->n = null;
var_dump($u->n);
class V { public int $v; }
$v = new V;
try { var_dump($v->v); } catch (Error $e) { echo "V caught\n"; }
