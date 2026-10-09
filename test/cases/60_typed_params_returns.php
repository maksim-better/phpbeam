<?php
function sum(int $a) { return $a; }
function fs(string $s) { return $s; }
function fb(bool $b) { return $b; }
function ff(float $f) { return $f; }
function fno(?int $n) { return $n; }
function fu(int|string $u) { return $u; }
class C { public function m(int $a) { return $a; } }
var_dump(sum("7"), sum(1.0), sum(true), fs(5), fs(1.5), fs(true), fb(1.5), ff(1), fno("8"), fu(1.5));
var_dump(fno(null));
try { sum([]); } catch (TypeError $e) { echo "T2: ", $e->getMessage(), "\n"; }
try { sum(null); } catch (TypeError $e) { echo "T3: ", $e->getMessage(), "\n"; }
try { fno([]); } catch (TypeError $e) { echo "T5: ", $e->getMessage(), "\n"; }
try { fu([]); } catch (TypeError $e) { echo "T7: ", $e->getMessage(), "\n"; }
try { (new C)->m([]); } catch (TypeError $e) { echo "T8: ", $e->getMessage(), "\n"; }
function fb2(bool $b) { return $b; }
function fi2(int|float $x) { return $x; }
function rf(): int { return []; }
function rstr(): string { return null; }
try { fb2(null); } catch (TypeError $e) { echo "B1: ", $e->getMessage(), "\n"; }
try { fi2([]); } catch (TypeError $e) { echo "B2: ", $e->getMessage(), "\n"; }
try { rf(); } catch (TypeError $e) { echo "B3: ", $e->getMessage(), "\n"; }
try { rstr(); } catch (TypeError $e) { echo "B4: ", $e->getMessage(), "\n"; }
function rn(): ?int { return null; }
var_dump(rn());
function rv(): void { return; }
rv(); echo "void ok\n";
function rimp(): int {}
try { rimp(); } catch (TypeError $e) { echo "RI: ", $e->getMessage(), "\n"; }
