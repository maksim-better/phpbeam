<?php
trait TA { public function f() { return "TA"; } public function g() { return "TA.g"; } }
trait TB { public function f() { return "TB"; } }
trait TMiddle {
  use TA, TB { TA::f insteadof TB; TB::f as fB; }
  public function mid() { return $this->f() . "/" . $this->fB() . "/" . $this->g(); }
}
trait TOuter {
  use TMiddle;
  public function out() { return "O:" . $this->mid(); }
}
class UseIt { use TOuter; }
echo (new UseIt())->out(), "\n";
