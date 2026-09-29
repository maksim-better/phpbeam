<?php
// loopback TCP round-trip, strerror table, socketpair, ValueError
$server = socket_create_listen(0);
socket_getsockname($server, $addr, $port);
var_dump($port > 0, $addr);
$c = socket_create(AF_INET, SOCK_STREAM, SOL_TCP);
var_dump(socket_connect($c, "127.0.0.1", $port));
$s = socket_accept($server);
var_dump(socket_write($c, "ping") === 4, socket_read($s, 4));
var_dump(socket_write($s, "pong") === 4, socket_read($c, 4, PHP_NORMAL_READ));
var_dump(socket_last_error($c));
socket_shutdown($s, 2);
socket_close($c); socket_close($s); socket_close($server);
var_dump(socket_strerror(11), socket_strerror(0), socket_strerror(61), socket_strerror(999999));
$pair = [];
var_dump(socket_create_pair(AF_UNIX, SOCK_STREAM, 0, $pair));
socket_write($pair[0], "x");
var_dump(socket_read($pair[1], 1));
socket_close($pair[0]); socket_close($pair[1]);
try { socket_create(9999, SOCK_STREAM, SOL_TCP); } catch (Throwable $e) { echo get_class($e), "\n"; }
try { socket_create(AF_INET, 777, SOL_TCP); } catch (Throwable $e) { echo get_class($e), "\n"; }
var_dump(AF_INET, SOCK_STREAM, SOL_SOCKET, MSG_WAITALL, SO_REUSEADDR);
