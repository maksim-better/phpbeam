<?php
namespace PhpOpt {
  abstract class Base { public function take(self $x): self { return $this; } }
  final class Derived extends Base { public function take(Base $x): Base { return $x; } }
}
namespace {
  var_dump((new PhpOpt\Derived)->take(new PhpOpt\Derived) instanceof PhpOpt\Base);
}
