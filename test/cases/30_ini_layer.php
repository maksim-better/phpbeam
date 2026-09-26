<?php
// PHASE A2: INI layer — registered-table semantics, access checks,
// ini_get_all details shape, ini_parse_quantity (zend port)
var_dump(ini_get("error_reporting"));
var_dump(ini_get("totally_unknown_ini_xyz"));

// runtime set: USER-bit entries settable, SYSTEM-only refuse
var_dump(ini_set("memory_limit", "256M"));
var_dump(ini_get("memory_limit"));
var_dump(ini_set("extension_dir", "/nope"));
var_dump(ini_set("also_unknown", "1"));

// ini_get_all: details shape for a known entry
$all = ini_get_all(null, true);
var_dump($all["error_reporting"]["access"], $all["error_reporting"]["local_value"]);
$sess = ini_get_all("session", true);
var_dump($sess["session.name"]["access"]);
$flat = ini_get_all("date", false);
var_dump($flat["date.timezone"]);

// ini_restore: back to the startup value
ini_set("memory_limit", "999M");
ini_restore("memory_limit");
var_dump(ini_get("memory_limit"));
ini_restore("no_such_key");

// ini_parse_quantity — the zend_atol family (warnings route through the
// A1 error pipeline with exact php wording)
var_dump(ini_parse_quantity("1k"), ini_parse_quantity("2M"), ini_parse_quantity("1G"));
var_dump(ini_parse_quantity("0x1F"), ini_parse_quantity("+3K"), ini_parse_quantity(" 128M "));
var_dump(ini_parse_quantity("-2M"), ini_parse_quantity(""), ini_parse_quantity("0"));
var_dump(ini_parse_quantity("1z"));
var_dump(ini_parse_quantity("1_000"));
var_dump(ini_parse_quantity("1k5"));
var_dump(ini_parse_quantity("99999999999999999999"));
var_dump(ini_parse_quantity("abc"));
echo "done\n";
