<?php
class S { public static int $s; public static ?int $n; public static $u; public static int $d = 7; }
try { var_dump(S::$s); } catch (Error $e) { echo "caught: ", $e->getMessage(), "\n"; }
try { var_dump(S::$n); } catch (Error $e) { echo "caught: ", $e->getMessage(), "\n"; }
var_dump(S::$u, S::$d);
var_dump(isset(S::$s), S::$s ?? 5);
class C extends S {}
try { var_dump(C::$s); } catch (Error $e) { echo "C caught: ", $e->getMessage(), "\n"; }
try { unset(S::$s); echo "unset ok\n"; } catch (Error $e) { echo "unset caught: ", $e->getMessage(), "\n"; }
var_dump(S::$s);
