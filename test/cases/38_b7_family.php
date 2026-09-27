<?php
// session starts FIRST (no output may precede it)
var_dump(session_start());
var_dump(session_status(), session_id() !== "", strlen(session_id()));

// bcmath
var_dump(bcadd("1.2", "1.5"), bcadd("1.25", "1.55", 3), bcsub("0", "0.4", 0));
var_dump(bcmul("1.5", "2.25"), bcmul("1.5", "2.25", 2), bcdiv("1", "3", 5));
var_dump(bcmod("10.5", "3"), bcmod("-10.5", "3"));
var_dump(bcpow("2.5", "2", 3), bcpow("2", "-1"), bcsqrt("2", 6));
var_dump(bccomp("1.00001", "1", 4), bccomp("1.00001", "1", 5));
var_dump(bcfloor("-3.2"), bcceil("3.2"));
var_dump(bcround("2.675", 2), bcround("-3.5"));
var_dump(bcround("2.5", 0, RoundingMode::HalfEven), bcround("2.5", 0, RoundingMode::AwayFromZero), bcround("2.5", 0, RoundingMode::NegativeInfinity));
var_dump(bcdivmod("-10", "3"));
var_dump(bcscale(4), bcadd("1.2", "1.5"), bcscale());
try { bcdiv("1", "0"); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { bcadd("abc", "1"); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }

// roundingmode — probed FIRST so the enum case singletons consume the
// same object-registry ids on both engines (php materializes lazily on
// first use, ours at boot)
var_dump(count(RoundingMode::cases()), RoundingMode::cases()[2]->name, RoundingMode::cases()[7]->name);

// gmp
$a = gmp_init(5);
var_dump(get_class($a), gmp_strval($a));
var_dump(gmp_strval(gmp_add($a, 3)), gmp_strval($a * $a), gmp_strval($a / 2), gmp_strval($a % 3));
$b = $a;
gmp_setbit($b, 1);
var_dump(gmp_strval($a), gmp_strval($b), gmp_strval(clone $a));
$c = gmp_init(-5);
var_dump(gmp_strval($c % 3), gmp_strval($c / 2), gmp_popcount($c), gmp_strval(~$c));
var_dump(gmp_strval(gmp_fact(10)), gmp_strval(gmp_powm("7", "100", "13")), gmp_strval(gmp_gcdext("12", "18")["g"]), gmp_strval(gmp_sqrtrem("17")[1]));
var_dump(gmp_invert("2", "4"), gmp_prob_prime("9"), gmp_prob_prime("1000003"), gmp_strval(gmp_nextprime("1000000")));
var_dump(bin2hex(gmp_export(gmp_init(0x11223344))), bin2hex(gmp_export(gmp_init(0x010203), 2)), gmp_strval(gmp_import(hex2bin("11223344"))));
var_dump(gmp_strval(gmp_init(255), 62), gmp_strval(gmp_init(-255), 62), gmp_strval(gmp_init("0x10")));
var_dump(gmp_intval(gmp_init("12345678901234567890")));
var_dump(gmp_jacobi("2", "15"), gmp_legendre("3", "7"), gmp_kronecker("-1", "7"), gmp_scan0(gmp_init(6), 1), gmp_scan1(gmp_init(-1), 2));
var_dump(gmp_and(-1, 5) == 5, gmp_or(-2, 3) == -1);
var_dump(serialize(gmp_init(7)));
$g7 = unserialize(serialize(gmp_init(7)));
var_dump(gmp_strval($g7), bin2hex(json_encode(gmp_init(7)) === false ? "" : ""));
try { gmp_fact(-1); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { gmp_add([], 1); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { gmp_pow("2", "-1"); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }
try { gmp_strval(gmp_init(255), 1); } catch (Throwable $e) { echo get_class($e), ": ", $e->getMessage(), "\n"; }

// session state machine (session is already active from the top)
$_SESSION["n"] = 42;
var_dump(session_encode());
var_dump(session_decode("k|i:5;s|s:3:\"abc\";"), $_SESSION);
var_dump(session_unset(), $_SESSION);
var_dump(session_reset(), $_SESSION);
var_dump(session_write_close(), session_status());
var_dump(session_id("changeit"));
var_dump(strlen(session_create_id()), (bool)preg_match('/^[A-Za-z0-9,\-]{32}$/', session_create_id()));
var_dump(session_destroy());
var_dump(session_encode());
var_dump(session_unset(), session_status());
var_dump(session_get_cookie_params());
var_dump(session_set_cookie_params(["lifetime" => 3600]));
var_dump(session_get_cookie_params()["lifetime"]);
var_dump(session_register_shutdown(), session_module_name(), session_cache_limiter(), session_cache_expire(60));

// readline
var_dump(readline());
var_dump(readline_add_history("h1"), readline_add_history("h2"));
var_dump(readline_info("line_buffer"), readline_info("point"), readline_info("end"));
var_dump(readline_read_history("/nonexistent/path"), readline_clear_history());
var_dump(readline_completion_function("strlen"));
var_dump(readline_redisplay(), readline_on_new_line());
var_dump(readline_callback_handler_remove());
var_dump(readline_callback_handler_install("p", function ($l) {}));
