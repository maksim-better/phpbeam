<?php
// PHASE A1b: user error handler dispatch semantics
// handler receives (errno, errstr, errfile, errline); true swallows,
// exactly-false falls through to normal display; throw propagates
set_error_handler(function ($no, $str, $file, $line) {
    echo "H[$no][$str][$line]\n";
    return true;
});
echo $undef;
$a = [1];
echo $a["k"];
trigger_error("uw", E_USER_WARNING);

// @ still dispatches to the handler; error_reporting() inside reads the mask
$x = @file_get_contents("/nonexistent-probe-xyz");
var_dump($x);

restore_error_handler();

// returning exactly false: handler runs AND the warning displays
set_error_handler(function () { echo "PASSTHRU\n"; return false; });
echo $u2;
restore_error_handler();

// handler throw propagates out of the erroring expression (the Laravel
// ErrorException pattern)
set_error_handler(function ($no, $str) { throw new RuntimeException("boom:$str"); });
try {
    $y = $missing;
} catch (RuntimeException $e) {
    echo "caught: ", $e->getMessage(), "\n";
}
restore_error_handler();

// levels arg: an E_USER_WARNING-only handler skips engine notices
set_error_handler(function () { echo "USER-ONLY\n"; return true; }, E_USER_WARNING);
echo $u3;
trigger_error("t", E_USER_WARNING);
restore_error_handler();

// handler-true suppresses error_get_last recording too
set_error_handler(function () { return true; });
$z = @file_get_contents("/nonexistent-probe-xyz");
$w = $nope;
var_dump(error_get_last() === null);
restore_error_handler();
echo "done\n";
