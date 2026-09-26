<?php
// PHASE B2: mbstring + ctype + iconv — pure-function family
// ctype
echo ctype_alnum("ab12"), ctype_alnum("a b") ? "T" : "", ctype_alnum("123"), ctype_alnum(""), ctype_alnum("é") ? "T" : "", "\n";
echo ctype_digit("123"), ctype_digit("12.3") ? "T" : "", ctype_alpha("AbC"), ctype_alpha("Ab2") ? "T" : "", "\n";
echo ctype_upper("AB"), ctype_upper("Ab") ? "T" : "", ctype_lower("ab"), ctype_space(" \t\n"), ctype_punct("!?"), ctype_print("a !"), ctype_graph("a!") ? "" : "F", ctype_cntrl("\x01") ? "" : "F", ctype_xdigit("1aF"), "\n";
// iconv
var_dump(iconv("UTF-8", "UTF-8", "héllo"), iconv_strlen("héllo"), iconv_substr("héllo", 1, 2));
var_dump(iconv_strpos("héllo", "l"), iconv_strrpos("héllo", "l"));
var_dump(iconv("UTF-8", "ISO-8859-1", "héllo") === "h\xE9llo", iconv_strlen(iconv("UTF-8", "ISO-8859-1", "héllo")));
var_dump(iconv_mime_encode("Subject", "plain", ["input-charset" => "UTF-8"]));
var_dump(iconv_mime_decode("Subject: =?UTF-8?B?aMOpbGxv?="));
var_dump(iconv_mime_decode_headers("Subject: =?UTF-8?B?aMOpbGxv?=\r\nX-Type: plain"));
var_dump(iconv_set_encoding("input", "UTF-8"), iconv_get_encoding("input"));
// mb core
var_dump(mb_strlen("héllo"), mb_substr("héllo", 1, 2), mb_strpos("héllo", "l"), mb_strrpos("aXbX", "X"));
var_dump(mb_stripos("Héllo", "L"), mb_strripos("abcXaX", "A"));
var_dump(mb_strtolower("HÉLLO"), mb_strtoupper("héllo"));
var_dump(mb_strwidth("héllo 世界"), mb_strwidth("ﾃｽﾄ"), mb_strwidth("abc"));
var_dump(mb_str_split("héllo", 2), mb_substr_count("aXbXc", "X"));
var_dump(mb_strstr("abc@def", "@"), mb_stristr("Héllo wórld", "LLO"), mb_strrchr("abcXdefX", "X"), mb_strrichr("aXbXc", "x", true));
var_dump(mb_strcut("héllo wórld", 2, 4), mb_strimwidth("héllo wórld", 0, 8, "..."));
var_dump(mb_convert_case("héllo wÓrld", 0), mb_convert_case("héllo wÓrld", 1), mb_convert_case("héllo wÓrld", 2));
var_dump(mb_ucfirst("héllo"), mb_lcfirst("HÉLLO"), mb_trim("  héllo  "), mb_ltrim("xxhéllo", "x"), mb_rtrim("hélloxx", "x"));
var_dump(mb_str_pad("ab", 5), mb_str_pad("ab", 5, "-=", 2), mb_str_pad("ab", 5, "-=", 1));
var_dump(mb_convert_encoding("héllo", "UTF-8", "ISO-8859-1") === "héllo");
var_dump(mb_encode_mimeheader("héllo"), mb_decode_mimeheader("=?UTF-8?B?aMOpbGxv?="));
var_dump(mb_encode_numericentity("é", [0, 0xffff, 0, 0xffff], "UTF-8"), mb_decode_numericentity("&#233;", [0, 0xffff, 0, 0xffff], "UTF-8"));
var_dump(mb_check_encoding("héllo", "UTF-8"), mb_check_encoding("\xFF", "UTF-8"));
var_dump(mb_scrub("héllo"), mb_ord("A"), mb_ord("é"), mb_chr(65), mb_chr(233));
var_dump(mb_list_encodings()[0]);
var_dump(mb_language(), mb_http_input(), mb_http_output());
var_dump(mb_preferred_mime_name("UTF-8"), mb_encoding_aliases("UTF-8"));
var_dump(mb_detect_encoding("héllo", "UTF-8"), mb_detect_encoding("abc", "UTF-8, ASCII"));
var_dump(mb_get_info("internal_encoding"), mb_output_handler("passthrough", 1));
echo "done\n";
