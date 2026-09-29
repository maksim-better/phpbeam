<?php
// file:// transfer, error chain, escape/unescape, constants, version
$f = __DIR__ . "/43_fixture.txt";
file_put_contents($f, "curl file body");

$h = curl_init("file://" . $f);
curl_setopt($h, CURLOPT_RETURNTRANSFER, true);
var_dump(curl_exec($h), curl_errno($h), curl_error($h));
var_dump(curl_getinfo($h, CURLINFO_EFFECTIVE_URL));
curl_close($h);

$h2 = curl_init();
var_dump(curl_exec($h2), curl_errno($h2), curl_error($h2));
var_dump(curl_escape($h2, "a b/c?d=1"), curl_unescape($h2, "a%20b"));
curl_close($h2);

$h3 = curl_init("file:///definitely/not/here");
curl_setopt($h3, CURLOPT_RETURNTRANSFER, true);
var_dump(curl_exec($h3), curl_errno($h3), curl_error($h3));
curl_close($h3);

var_dump(curl_strerror(0), curl_strerror(6), curl_strerror(37));
var_dump(CURLOPT_RETURNTRANSFER, CURLOPT_URL, CURLOPT_POST, CURLOPT_HTTPHEADER,
         CURLOPT_TIMEOUT, CURLOPT_FOLLOWLOCATION, CURLOPT_SSL_VERIFYPEER,
         CURLINFO_HTTP_CODE, CURLINFO_EFFECTIVE_URL, CURLOPT_POSTFIELDS);
$v = curl_version();
var_dump($v["version"], $v["host"], $v["ssl_version_number"], $v["libssh_version"],
         in_array("https", $v["protocols"]), in_array("file", $v["protocols"]));
unlink($f);
