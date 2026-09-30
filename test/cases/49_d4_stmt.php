<?php
$m = mysqli_connect("127.0.0.1", "root", "root", "information_schema");
$st = mysqli_prepare($m, "SELECT ? AS a, ? AS b");
var_dump((bool)$st, mysqli_stmt_param_count($st));
$a = "x"; $b = "5";
mysqli_stmt_bind_param($st, "ss", $a, $b);
var_dump(mysqli_stmt_execute($st));
$r = mysqli_stmt_get_result($st);
var_dump(mysqli_fetch_assoc($r), mysqli_num_rows($r));
var_dump(mysqli_stmt_execute($st));
mysqli_stmt_close($st);

mysqli_select_db($m, "phpbeam_test");
$ins = mysqli_prepare($m, "INSERT INTO t3 (v) VALUES (?)");
$z = "zed";
mysqli_stmt_bind_param($ins, "s", $z);
var_dump(mysqli_stmt_execute($ins), mysqli_stmt_affected_rows($ins), mysqli_stmt_insert_id($ins) > 0);
mysqli_stmt_close($ins);

$sel = mysqli_prepare($m, "SELECT id, v FROM t3 WHERE id <= ?");
$lim = 2;
mysqli_stmt_bind_param($sel, "i", $lim);
mysqli_stmt_execute($sel);
$r2 = mysqli_stmt_get_result($sel);
$rows = mysqli_fetch_all($r2, MYSQLI_NUM);
var_dump(count($rows), $rows[0][1], $rows[1][1]);
var_dump(mysqli_stmt_field_count($sel));
mysqli_stmt_free_result($sel);
mysqli_close($m);
