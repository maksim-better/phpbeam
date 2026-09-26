<?php
// PHASE A3: stream wrappers — php://memory family, data://, php://filter,
// php://output vs stdout vs ob, stream contexts
$m = fopen("php://memory", "r+");
var_dump(fwrite($m, "hello world"), ftell($m));
rewind($m);
var_dump(fread($m, 5), fread($m, 100), feof($m), ftell($m));
fseek($m, 4);
var_dump(fread($m, 2));
fseek($m, -3, SEEK_END);
var_dump(fread($m, 10));
var_dump(fstat($m)["size"], fstat($m)["mode"]);
var_dump(file_get_contents("php://memory"));

$t = fopen("php://temp", "w+");
fwrite($t, "tempdata");
rewind($t);
var_dump(stream_get_contents($t));

// data:// forms
var_dump(file_get_contents("data://text/plain,hello there"));
var_dump(file_get_contents("data://text/plain;base64,SGVsbG8gV29ybGQ="));
var_dump(file_get_contents("data:,raw-default-mime"));
$fh = fopen("data://text/plain,streamform", "r");
var_dump(fread($fh, 100), feof($fh));

// filter chains (read and write)
var_dump(file_get_contents("php://filter/read=string.toupper/resource=data://text/plain,abc"));
var_dump(file_get_contents("php://filter/read=string.rot13/resource=data://text/plain,abc"));
var_dump(file_get_contents("php://filter/read=convert.base64-encode/resource=data://text/plain,abc"));
var_dump(file_get_contents("php://filter/read=string.tolower|convert.base64-encode/resource=data://text/plain,ABC"));
$f2 = fopen("php://filter/write=string.toupper/resource=php://memory", "w+");
fwrite($f2, "xyz");
rewind($f2);
var_dump(stream_get_contents($f2));

// output vs stdout vs output-buffering (probed ordering)
echo "A";
ob_start();
echo "b1";
file_put_contents("php://output", "-O");
file_put_contents("php://stdout", "-S");
echo "b2";
ob_end_flush();
echo "B\n";
var_dump(file_get_contents("php://input"));

// stream contexts
$ctx = stream_context_create(["http" => ["method" => "POST", "header" => "X: 1"]]);
var_dump(gettype($ctx), stream_context_get_options($ctx)["http"]["method"]);
stream_context_set_option($ctx, "http", "timeout", 3.0);
var_dump(stream_context_get_options($ctx)["http"]["timeout"]);
$d = stream_context_set_default(["file" => ["x" => 1]]);
var_dump(gettype($d), stream_context_get_options($d)["file"]["x"]);

// unsupported wrapper renders php's warning
var_dump(@file_get_contents("http://example.invalid/"));
echo "done\n";
