<?php
var_dump(posix_getuid(), posix_getgid(), posix_uname()["sysname"], posix_uname()["machine"] !== "");
var_dump(posix_getcwd() === getcwd());
var_dump(posix_strerror(2), posix_strerror(13), posix_strerror(22), posix_strerror(0));
$v = posix_getpwuid(posix_getuid());
var_dump($v["name"], $v["uid"] === posix_getuid(), isset($v["dir"]), isset($v["shell"]));
var_dump(posix_getpwnam($v["name"])["uid"] === posix_getuid());
var_dump(posix_getgrgid(posix_getgid())["name"], posix_getgrnam("staff")["gid"] === 20);
var_dump(posix_kill(posix_getpid(), 0), posix_access("/tmp", 1), posix_access("/nope", 0), posix_ctermid());
var_dump(posix_getlasterror(), is_int(posix_times()["ticks"]));
$g = posix_getgroups();
var_dump(in_array(20, $g), count($g) > 0);
var_dump(posix_getsid(posix_getpid()) > 0);
