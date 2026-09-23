<?php
interface Shape {
    public function area(): float;
    const DIMENSIONS = 2;
}
abstract class Base implements Shape {
    public string $name;
    protected static int $count = 0;

    public function __construct(string $name) {
        $this->name = $name;
        self::$count++;
    }
    public static function count(): int { return self::$count; }
    abstract protected function scale($f);
    public function describe(): string {
        return $this->name . " area=" . $this->area();
    }
}
class Square extends Base {
    private float $side;
    public function __construct($side) {
        parent::__construct("square");
        $this->side = $side;
    }
    public function area(): float { return $this->side ** 2; }
    protected function scale($f) { $this->side *= $f; }
    public function grow($f) { $this->scale($f); return $this; }
}
$circ = 0;
class Circle extends Base {
    public function __construct($r) {
        parent::__construct("circle");
        global $circ;
        $circ = $r;
    }
    public function area(): float { return 3.14159 * $circ ** 2; }
    protected function scale($f) { }
}

$s = new Square(3);
echo $s->describe(), "\n";
$s->grow(2);
echo $s->describe(), "\n";
echo Circle::class, " ", Shape::DIMENSIONS, "\n";
$c = new Circle(2);
echo $c->describe(), "\n";
echo Base::count(), "\n";
var_dump($s instanceof Square, $s instanceof Base, $s instanceof Shape, $s instanceof Circle);
echo get_class($s), "|", get_parent_class($s), "\n";

trait Logger {
    public function log($m) { return "[log] " . $m; }
    protected function secret() { return "hidden"; }
}
class Service {
    use Logger;
    public function run() { return $this->log("ran") . " / " . $this->secret(); }
}
echo (new Service())->run(), "\n";

class Magic {
    private $data = [];
    public function __get($k) { return $this->data[$k] ?? "default:$k"; }
    public function __set($k, $v) { $this->data[$k] = strtoupper($v); }
    public function __isset($k) { return isset($this->data[$k]); }
    public function __call($name, $args) { return "call:$name(" . implode(",", $args) . ")"; }
    public static function __callStatic($name, $args) { return "static:$name"; }
    public function __toString() { return "Magic!"; }
}
$m = new Magic();
$m->foo = "bar";
echo $m->foo, "|", $m->baz, "|", $m->anything(1, "x"), "|", Magic::go(), "|", $m, "\n";
var_dump(isset($m->foo), isset($m->nope));

class Counter2 {
    public static $n = 0;
    public function __construct() { self::$n++; }
}
new Counter2(); new Counter2(); new Counter2();
echo Counter2::$n, "\n";
