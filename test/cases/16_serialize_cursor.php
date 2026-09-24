<?php
// serialize/unserialize wire format + array cursor family
echo serialize(5), " ", serialize(1.5), " ", serialize(true), " ", serialize(null), "\n";
echo serialize("he\tillo"), " ", serialize(0.1), " ", serialize(1 / 3), "\n";

$mixed = [10, "b" => 20, 30.5, "k" => [1, 2]];
echo serialize($mixed), "\n";

$round = unserialize(serialize($mixed));
echo count($round), " ", $round[1], " ", $round["b"], "\n";

class Point {
    public $x = 1;
    private $hidden = 2;
    protected $guarded = 3;
    public $name = "p";
}
$ser = serialize(new Point());
echo strlen($ser), " ", substr_count($ser, "Point"), "\n";
$back = unserialize($ser);
echo get_class($back), " ", $back->x, " ", $back->name, "\n";

var_dump(unserialize("not-serialized"));

$a = ["x" => 1, "y" => 2, 5 => "v"];
echo current($a), " ", key($a), "\n";
echo next($a), " ", key($a), "\n";
echo next($a), " ", key($a), "\n";
var_dump(next($a), current($a), key($a));
echo end($a), " ", key($a), "\n";
echo reset($a), " ", key($a), "\n";

$empty = [];
var_dump(current($empty), key($empty), end($empty));

$copy = ["m" => 1, "n" => 2];
next($copy);
$b = $copy;
var_dump(current($b), current($copy));
echo "__done__\n";
