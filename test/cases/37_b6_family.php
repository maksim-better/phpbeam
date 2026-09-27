<?php
// hash incremental
$h = hash_init('sha256');
hash_update($h, "abc");
hash_update($h, "def");
var_dump(hash_final($h));
$h2 = hash_init('md5');
hash_update($h2, "x");
$h3 = hash_copy($h2);
var_dump(hash_final($h2), hash_final($h3));
var_dump(hash('sha256', "abcdef") === hash_final(hash_init('sha256')));
// pbkdf2 + hkdf
var_dump(strlen(hash_pbkdf2("sha256", "pw", "salt", 1000, 32)) > 0, substr(hash_pbkdf2("sha256", "pw", "salt", 1, 8), 0, 4) === substr(hash_pbkdf2("sha256", "pw", "salt", 1, 8), 0, 4));
var_dump(strlen(hash_hkdf("sha256", "secret", 32)) === 32);
// filter
var_dump(filter_var("john@example.com", FILTER_VALIDATE_EMAIL) , filter_var("not-an-email", FILTER_VALIDATE_EMAIL));
var_dump(filter_var("http://example.com", FILTER_VALIDATE_URL), filter_var("127.0.0.1", FILTER_VALIDATE_IP));
var_dump("  hi  ");
var_dump(filter_var("123abc", FILTER_SANITIZE_NUMBER_INT), filter_var("  42 ", FILTER_VALIDATE_INT), filter_var("abc", FILTER_VALIDATE_INT, ["options" => ["default" => "dflt"]]));
var_dump(filter_has_var(INPUT_GET, "nope"), filter_list()[0], filter_id("int"));
// tokenizer
$toks = token_get_all("<?php echo 1;");
var_dump(count($toks) > 2, $toks[1][0] === T_ECHO ? "echo-id" : $toks[1]);
var_dump(token_name(T_ECHO), token_name(T_STRING));
var_dump(token_get_all("<?php \$x;")[1]);
// json_validate
var_dump(json_validate("{}"), json_validate("{"), json_validate("[]"), json_validate(null));
// Core
var_dump(get_defined_vars() !== []);
function targs($a, $b, $c) { var_dump(func_num_args(), func_get_args()[2] ?? "n/a"); }
targs(1, 2, 3);
var_dump(strncasecmp("Hello", "HELLO world", 5), strncasecmp("abcX", "abcY", 3));
var_dump(trait_exists('Nonexistent'));
var_dump(gc_enabled(), gc_status() !== []);
var_dump(spl_classes()["ArrayObject"] ?? "no", class_parents('ArrayIterator'), class_implements('ArrayObject'));
var_dump(iterator_to_array(new ArrayIterator(['a'=>1,'b'=>2])), iterator_count(new ArrayIterator([1,2])));
var_dump(class_alias('ArrayObject', 'ArrObj'), class_exists('ArrObj'));
var_dump(preg_last_error_msg(), 1);
echo "done\n";
