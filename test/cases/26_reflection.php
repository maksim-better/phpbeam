<?php
abstract class Abst { public function m($a, $b = 2) {} protected static function sm() {} }
interface Ifc {}
enum En: string { case A = 'a'; }

$r = new ReflectionClass('Abst');
echo $r->getName(), "|", $r->isAbstract()?1:0, $r->isFinal()?1:0, $r->isInterface()?1:0, $r->isEnum()?1:0, "\n";
echo $r->hasMethod("M")?1:0, $r->hasMethod("nope")?1:0, "\n";
$m = $r->getMethod("m");
echo $m->getName(), "|", $m->getNumberOfParameters(), "|", $m->isPublic()?1:0, $m->isStatic()?1:0, "\n";
$sm = $r->getMethod("sm");
echo $sm->isStatic()?1:0, "\n";

$r2 = new ReflectionClass('Ifc');
echo $r2->getName(), "|", $r2->isInterface()?1:0, "\n";
$r3 = new ReflectionClass('En');
echo $r3->isEnum()?1:0, "\n";
$c = new ReflectionClass('Abst');
$r4 = new ReflectionClass($c);
echo $r4->getName(), "\n";
try { new ReflectionClass('NoSuch'); } catch (ReflectionException $e) { echo "E:", $e->getMessage(), "\n"; }
try { (new ReflectionClass('Abst'))->getMethod('zz'); } catch (ReflectionException $e) { echo "F:", $e->getMessage(), "\n"; }
