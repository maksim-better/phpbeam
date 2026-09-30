<?php
// failure path: no postgres on this host (docker pull blocked by network)
$c = @pg_connect("host=127.0.0.1 port=5432 dbname=test user=root");
var_dump($c === false);
$c2 = @pg_connect("host=nope.invalid user=x");
var_dump($c2 === false);
$c3 = @pg_connect("host=127.0.0.1 port=15432 dbname=d user=u");
var_dump($c3 === false);
var_dump(pg_last_error() === "");
