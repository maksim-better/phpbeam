<?php
// lossy float / float-string implicit conversions in bitwise ops
$var = 1.5 | 3;  var_dump($var);
$var = 1.5 & 3;  var_dump($var);
$var = 1.5 ^ 3;  var_dump($var);
$var = 1.5 << 3; var_dump($var);
$var = 3 << 1.5; var_dump($var);
$var = 3 >> 1.5; var_dump($var);
$var = ~1.5;     var_dump($var);
$var = "1.5" | 3;  var_dump($var);
$var = "1.5" << 3; var_dump($var);
$var = ~"1.5";   var_dump($var);
$var = "6.5" % 2; var_dump($var);
$x = 1; $x &= 1.5; var_dump($x);
$y = 2; $y <<= "1.5"; var_dump($y);
// lossless floats: no warnings
$var = 1.0 | 3; var_dump($var);
$var = ~2.0; var_dump($var);
// string bitwise (both operands strings)
var_dump("a" | "b");
var_dump(~"abc");
// error wordings
try { var_dump(~[]); } catch (TypeError $e) { echo "TE1: ", $e->getMessage(), "\n"; }
try { var_dump(~true); } catch (TypeError $e) { echo "TE2: ", $e->getMessage(), "\n"; }
try { var_dump(~(new stdClass)); } catch (TypeError $e) { echo "TE3: ", $e->getMessage(), "\n"; }
