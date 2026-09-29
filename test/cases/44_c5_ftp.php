<?php
var_dump(ftp_connect("127.0.0.1", 2121, 2) === false);
var_dump(ftp_connect("no.such.host.invalid", 21, 1) === false);
try { ftp_login(false, "u", "p"); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { ftp_pwd(null); } catch (Throwable $e) { echo get_class($e), "\n"; }
try { ftp_close(1); } catch (Throwable $e) { echo get_class($e), "\n"; }
