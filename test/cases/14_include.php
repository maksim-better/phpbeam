<?php
// include/require semantics: scope sharing, return values, _once idempotence,
// full-expression operands (the WordPress `CONST . 'file.php'` idiom)
$dir = sys_get_temp_dir() . '/phpbeam_incl_fixed';
if (is_dir($dir)) { array_map('unlink', glob("$dir/*")); rmdir($dir); }
mkdir($dir, 0777, true);

file_put_contents("$dir/a.php", '<?php $shared = 42; return "from-a";');
file_put_contents("$dir/b.php", '<?php global $counter; $counter++;');

$v = include "$dir/a.php";
echo "v=$v shared=$shared\n";

include_once "$dir/b.php";
include_once "$dir/b.php";
$r2 = require_once "$dir/b.php";
echo "counter=$counter once-ret=";
var_dump($r2);

$prefix = "$dir/";
$w = include $prefix . "a.php";
echo "w=$w\n";

$x = include "$dir/missing.php";
echo "missing-ret=";
var_dump($x);

echo "file_exists=", var_export(file_exists("$dir/a.php"), true), "\n";
echo "file_size_gt0=", var_export(filesize("$dir/a.php") > 0, true), "\n";

unlink("$dir/a.php");
unlink("$dir/b.php");
rmdir($dir);
echo "cleaned=", var_export(is_dir($dir), true), "\n";

function scoped() {
    $local = "L";
    include_pass($local);
}
function include_pass($v) { echo "fn-scope=$v\n"; }
scoped();
echo "__main_done__\n";
