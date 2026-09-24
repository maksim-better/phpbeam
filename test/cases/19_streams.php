<?php
// resource streams: fopen modes, fread/fwrite/fseek/ftell/feof/fgets/fgetc,
// closed-resource TypeErrors with trace frames
$path = sys_get_temp_dir() . "/phpbeam_streams_" . getmypid() . ".txt";

$f = fopen($path, "w");
var_dump(is_resource($f));
fwrite($f, "alpha\nbeta\ngamma");
var_dump(fclose($f));

$r = fopen($path, "r");
echo fread($r, 5), "|";
var_dump(feof($r));
fseek($r, -4, SEEK_END);
echo fread($r, 100), "|", ftell($r), "\n";
rewind($r);
echo fgets($r), "|", fgetc($r), "|", fgets($r), "\n";
fseek($r, 1, SEEK_CUR);
echo ftell($r), " ", fread($r, 2), "\n";
fclose($r);

$w = fopen($path, "a");
fwrite($w, "!");
fclose($w);
echo filesize($path), " ", file_get_contents($path), "\n";

$neg = fopen("/tmp/__no_dir_phpbeam__/x.txt", "r");
var_dump($neg);

$t = tmpfile();
fwrite($t, "temp-content");
rewind($t);
echo stream_get_contents($t), " ";
var_dump(ftruncate($t, 4));
fclose($t);

$flock = fopen($path, "r");
var_dump(flock($flock, LOCK_EX));
$closed = fopen($path, "r");
fclose($closed);
try {
    fread($closed, 5);
} catch (TypeError $e) {
    echo "caught: ", substr($e->getMessage(), 0, 40), "...\n";
}

unlink($path);
echo "__done__\n";
