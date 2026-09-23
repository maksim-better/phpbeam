<?php
namespace App\Models;

use App\Util\Str;
use App\Util\Math as M;

const VERSION = "1.0";

class User {
    public $name;
    public function __construct($n) { $this->name = $n; }
    public function greet() { return "hello " . $this->name; }
}
class Admin extends User {
    public function greet() { return strtoupper(parent::greet()); }
}

function helper() { return "helper@" . VERSION; }

echo (new User("bob"))->greet(), "\n";
echo (new Admin("amy"))->greet(), "\n";
echo helper(), "\n";
echo User::class, "|", Admin::class, "\n";
echo \App\Models\User::class === User::class ? "fq ok" : "fq bad", "\n";

namespace App\Util;

class Str {
    public static function up($s) { return strtoupper($s); }
}
class Math {
    public static function twice($n) { return $n * 2; }
}

namespace App\Models;

use App\Util\Str;
use App\Util\Math as M;

echo Str::up("mixed"), " ", M::twice(21), "\n";
echo strlen("ns works"), "\n";
