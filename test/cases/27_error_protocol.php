<?php
// PHASE A1 error protocol: error_reporting filtering, E_* constants,
// trigger_error levels, error_get_last, @ suppression
var_dump(E_ALL, E_DEPRECATED, E_USER_DEPRECATED);

// default reporting level (php 8.4 cli)
var_dump(error_reporting());

// filtering: E_ALL & ~E_WARNING hides undefined-variable warnings
error_reporting(E_ALL & ~E_WARNING);
echo $u;
error_reporting(E_ALL);
echo $u;

// trigger_error levels
trigger_error("custom notice");
trigger_error("custom warn", E_USER_WARNING);
trigger_error("custom dep", E_USER_DEPRECATED);

// invalid level -> ValueError (php 8.4 message)
try {
    trigger_error("x", E_ERROR);
} catch (ValueError $e) {
    echo "VE: ", $e->getMessage(), "\n";
}

// error_get_last survives @; clear_last resets
@file_get_contents("/nonexistent-probe-xyz");
var_dump(error_get_last()["type"]);
error_clear_last();
var_dump(error_get_last());

// @ suppresses the diagnostic entirely
$x = @file_get_contents("/nonexistent-probe-xyz");
var_dump($x);

// display_errors=0 hides warnings but error_get_last still records
ini_set("display_errors", "0");
echo $v;
ini_set("display_errors", "1");
var_dump(error_get_last()["message"]);

// E_USER_ERROR: 8.4 deprecation then fatal (last statement — script ends)
trigger_error("fatal-ish", E_USER_ERROR);
echo "not reached\n";
