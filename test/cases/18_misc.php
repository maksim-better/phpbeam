<?php
// M14 misc sweep: strings, paths, digests, codecs, url, class checks
echo ord("A"), " ", chr(66), " ", strstr("hello@world", "@"), "\n";
echo strnatcasecmp("img10", "img2"), " ", strspn("42abc", "0123456789"), " ", strcspn("abc42", "0123456789"), "\n";
echo strtr("abc", "ab", "XY"), " ", strtr("abc", ["a" => "A", "bc" => "X"]), "\n";
echo substr_replace("hello", "...", -3), " ", substr_replace(["a", "b"], "X", 0, 1)[1], "\n";
echo substr_compare("abcde", "BC", 1, 2, true), " ", substr_compare("abcde", "bd", 1, 2), "\n";
echo version_compare("7.4", "8.0"), " ", version_compare("8.0-beta", "8.0"), " ", version_compare("8.0", "8.0.0"), "\n";
var_dump(version_compare("8.0", "8.0", ">="), version_compare("7.4", "8.0", "<"));
echo md5("abc"), " ", sha1("abc"), " ", crc32("abc"), "\n";
var_dump(md5("abc", true) === hex2bin(md5("abc")));
echo base64_encode("hello"), " ", bin2hex("\x01\x02"), " ", urlencode("a b&c"), " ", rawurlencode("a b"), "\n";
echo html_entity_decode("&lt;a&gt;&nbsp;&amp;&quot;b&quot;"), "\n";
echo dirname("/a/b/c/d", 2), " ", basename("/x/y/file.php.txt", ".txt"), "\n";
print_r(pathinfo("/a/b/c.txt"));
var_dump(parse_url("https://u:p@host:8080/pa?x=1#f")["host"], parse_url("//h/p", PHP_URL_HOST));
function myfn() {}
var_dump(is_callable("myfn"), is_callable("nope"), is_callable("strlen"));
class Base {} class Kid extends Base {}
var_dump(is_a(new Kid(), "Base"), is_subclass_of("Kid", "Base"), is_resource("x"));
var_dump(extension_loaded("pcre"), extension_loaded("definitely_not"), is_a("Kid", "Base", false));
trigger_error("user-warn", E_USER_WARNING);
trigger_error("user-dep", E_USER_DEPRECATED);
$a = "v1"; $b = ["v2"];
print_r(compact("a", "b"));
parse_str("x=1&arr%5B0%5D=n&arr%5Bq%5D=z", $out);
echo $out["x"], $out["arr"]["0"], $out["arr"]["q"], "\n";
$cnt = extract(["ex1" => 9]);
echo "cnt=$cnt ex1=$ex1\n";
echo http_build_query(["a" => 1, "b" => ["c" => "x y"]]), "\n";
var_dump(array_is_list([]), array_is_list(["a" => 1]), array_intersect_key(["a" => 1, "b" => 2], ["a" => 0]));
echo escapeshellarg("it's"), "\n";
echo getenv("__PHPBEAM_NOPE__") === false ? "env-false" : "env-??", "\n";
echo "__done__\n";
