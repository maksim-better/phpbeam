<?php
// CLI $argv/$argc: this case runs without extra args from the differential
// harness, so it pins the no-arg shapes; the with-args shapes are probed in
// specs/001 implement-log (T018) against /opt/homebrew/bin/php directly.
var_dump($argc >= 1, is_array($argv), $argv[0] === basename($argv[0]) || is_string($argv[0]));
echo $_SERVER["argc"] === $argc ? "mirror-ok\n" : "mirror-bad\n";
