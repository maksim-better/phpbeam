<?php
function divide($a, $b) {
    if ($b === 0) {
        throw new InvalidArgumentException("Division by zero");
    }
    return $a / $b;
}

try {
    echo divide(10, 2), "\n";
    echo divide(1, 0), "\n";
    echo "unreachable\n";
} catch (InvalidArgumentException $e) {
    echo "caught: ", $e->getMessage(), "\n";
} catch (Exception $e) {
    echo "caught generic\n";
} finally {
    echo "finally runs\n";
}

try {
    throw new RuntimeException("runtime issue", 42);
} catch (Exception $e) {
    echo get_class($e), ": ", $e->getMessage(), " code=", $e->getCode(), "\n";
}

try {
    echo 7 % 0;
} catch (DivisionByZeroError $e) {
    echo "DZ: ", $e->getMessage(), "\n";
}

try {
    throw new Exception("base");
} catch (LogicException $e) {
    echo "wrong branch\n";
} catch (Throwable $e) {
    echo "throwable: ", get_class($e), "\n";
}

class MyError extends Exception {
    public function __construct() {
        parent::__construct("my error", 7);
    }
    public function report() { return $this->getMessage() . "/" . $this->getCode(); }
}
try {
    throw new MyError();
} catch (Exception $e) {
    echo $e->report(), "\n";
    var_dump($e instanceof MyError, $e instanceof Exception, $e instanceof Throwable);
}

function thrower() { throw new TypeError("from function"); }
try { thrower(); } catch (TypeError $t) { echo "type: ", $t->getMessage(), "\n"; }

echo "end\n";
