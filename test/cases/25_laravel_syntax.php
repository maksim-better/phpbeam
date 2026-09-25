<?php
// L1 syntax sprint solidification + named-args/enum/readonly completion:
// every construct Laravel/Composer vendor trees lean on.

// ── named arguments ──────────────────────────────────────────────
function f($a, $b, $c = 3) { return "$a-$b-$c"; }
echo f(b: 3, a: 4), " ";
echo f(1, c: 9, b: 2), " ";
echo f(...["a" => 10], c: 30, b: 20), "\n";

function v($a, ...$rest) { var_export($rest); echo "|", count(func_get_args()), "\n"; }
v(1, 2, x: 9, y: 8);
v(a: 1, b: 2);

class W { public function __construct(public int $i, public string $t = "d") {} }
$w = new W(t: "z", i: 8);
echo $w->i, $w->t, " ", (new W(1))->t, "\n";

echo str_replace(search: "a", subject: "banana", replace: "o"), " ";
echo substr(string: "hello", offset: 1, length: 3), " ";
echo explode(string: "a b", separator: " ")[1], "\n";

try { f(1, c: 9); } catch (ArgumentCountError $e) { echo "A:", $e->getMessage(), "\n"; }
try { f(c: 9); } catch (ArgumentCountError $e) { echo "B:", $e->getMessage(), "\n"; }
try { f(1); } catch (ArgumentCountError $e) { echo "C:", $e->getMessage(), "\n"; }
try { f(z: 1); } catch (Error $e) { echo "D:", $e->getMessage(), "\n"; }
try { f(1, a: 5); } catch (Error $e) { echo "E:", $e->getMessage(), "\n"; }

// ── enums ────────────────────────────────────────────────────────
enum Suit: string { case Hearts = "h"; case Spades = "s"; }
enum IntE: int { case One = 1; }

echo Suit::Hearts->name, "=", Suit::Hearts->value, " ";
echo IntE::from("1")->value, " ";
var_dump(Suit::tryFrom("zz"));
foreach (Suit::cases() as $c) echo $c->name, ":", $c->value, ";";
echo " ", Suit::Hearts === Suit::cases()[0] ? "single" : "multi", "\n";
try { Suit::from("zz"); } catch (ValueError $e) { echo "F:", $e->getMessage(), "\n"; }
try { IntE::from(99); } catch (ValueError $e) { echo "G:", $e->getMessage(), "\n"; }

// ── readonly ─────────────────────────────────────────────────────
class Rw {
    public readonly int $y;
    public function __construct() { $this->y = 9; }
    public function re() { $this->y = 2; }
}
$r = new Rw();
echo $r->y, "\n";
try { $r->re(); } catch (Error $e) { echo "H:", $e->getMessage(), "\n"; }
try { $r->y = 1; } catch (Error $e) { echo "I:", $e->getMessage(), "\n"; }

class Rw2 { public readonly int $z; }
$r2 = new Rw2();
try { $r2->z = 1; } catch (Error $e) { echo "J:", $e->getMessage(), "\n"; }

class Sub extends Rw2 { function init() { $this->z = 5; } }
$s = new Sub(); $s->init(); echo $s->z, "\n";
try { unset($s->z); } catch (Error $e) { echo "K:", $e->getMessage(), "\n"; }

$ro = new class(1) { public function __construct(public readonly int $x) {} };
try { $ro->x = 2; } catch (Error $e) { echo "L:", $e->getMessage(), "\n"; }

// ── promotion + spread + FCC + heredoc (L1) ─────────────────────
$nums = [2, 3];
print_r([1, ...$nums, 4]);
$len = strlen(...);
echo $len("héllo"), " ";
echo call_user_func(fn($q) => $q + 1, 41), "\n";

$name = "w";
$hered = <<<EOT
Hello $name
EOT . "!";
echo $hered, "\n";

class CC { function m($x) { return "m$x"; } static function s($x) { return "s$x"; } }
$cc = new CC();
echo $cc->m(...)(7), " ", CC::s(...)(8), " ";
$us = [[3, 1], [2, 4]];
usort($us, fn($p, $q) => $p[0] <=> $q[0]);
echo $us[0][0], $us[1][0], "\n";

$o1 = new stdClass();
$o2 = $o1;
var_dump($o1 === $o2, $o1 === new stdClass());

echo "__main_done__\n";
