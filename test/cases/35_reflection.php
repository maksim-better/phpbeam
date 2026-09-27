<?php
// PHASE B4: Reflection surface — functions, closures, properties, constants
$rf = new ReflectionFunction('strlen');
var_dump($rf->getName(), $rf->getNumberOfParameters());
$f = function (int $a, string $b = 'x') { return $a; };
$rf2 = new ReflectionFunction($f);
var_dump($rf2->getName(), $rf2->getNumberOfParameters());
foreach ($rf2->getParameters() as $p) {
  echo $p->getName(), " ";
  var_dump($p->isOptional(), $p->isDefaultValueAvailable());
  if ($p->isDefaultValueAvailable()) var_dump($p->getDefaultValue());
  $t = $p->getType();
  var_dump((string)$t, $t->allowsNull());
}
// properties + accessibility
class Demo {
  public int $px = 5;
  private string $py = "s";
  public const CC = 7;
  public function __construct(private int $z) {}
  public function m(int $q = 1): void {}
}
$rc = new ReflectionClass('Demo');
$prop = $rc->getProperty('px');
var_dump($prop->getName(), $prop->isPublic(), $prop->isPrivate(), $prop->isDefault(), $prop->isStatic());
$ppy = $rc->getProperty('py');
$o = new Demo(3);
var_dump($ppy->isPrivate());
$ppy->setAccessible(true);
var_dump($ppy->getValue($o));
$ppy->setValue($o, "new");
var_dump($ppy->getValue($o));
var_dump($ppy->getDeclaringClass()->getName());
// constants
$cst = $rc->getReflectionConstant('CC');
var_dump($cst->getName(), $cst->getValue(), $cst->isPublic(), $cst->getDeclaringClass()->getName());
var_dump($rc->getConstant('CC'), $rc->getConstants(), $rc->hasConstant('CC'), $rc->hasProperty('px'), $rc->hasProperty('nope'), $rc->getDefaultProperties());
// method surface
$m = $rc->getMethod('m');
var_dump($m->getDeclaringClass()->getName(), $m->getNumberOfParameters(), $m->getName());
var_dump($rc->getConstructor() !== null);
echo "done\n";
