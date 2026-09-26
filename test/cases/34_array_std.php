<?php
// PHASE B3: standard array family — u* callbacks, key preservation,
// natural sorts, replace family, finders, ip2long
$a = ['a'=>1, 'b'=>2, 'c'=>3]; $b = [2, 4];
$cmp = fn($x, $y) => $x <=> $y;
var_dump(array_uintersect($a, $b, $cmp));
var_dump(array_intersect($a, $b));
var_dump(array_intersect_assoc($a, [1=>'x', 'b'=>2]));
var_dump(array_intersect_key($a, ['b'=>0, 'c'=>9]));
var_dump(array_diff($a, $b), array_diff_key($a, ['b'=>1]), array_diff_assoc($a, ['a'=>9, 'b'=>2]));
echo "--udiff\n"; var_dump(array_udiff($a, $b, $cmp));
echo "--udiff_assoc\n"; var_dump(array_udiff_assoc($a, ['b'=>2], $cmp));
echo "--uintersect_assoc\n"; var_dump(array_uintersect_assoc($a, [2, 9], $cmp));
echo "--intersect_ukey\n"; var_dump(array_intersect_ukey($a, ['B'=>1], fn($x,$y) => strcasecmp($x, $y)));
echo "--diff_ukey\n"; var_dump(array_diff_ukey($a, ['B'=>1], fn($x,$y) => strcasecmp($x, $y)));
echo "--diff_uassoc\n"; var_dump(array_diff_uassoc($a, ['A'=>1], fn($x,$y) => strcasecmp($x, $y)));
// natural sorts
$pics = ["img12.png", "img10.png", "img2.png", "img1.png"];
natsort($pics); var_dump($pics);
$p2 = ["IMG0.png", "img12.png", "IMG10.png"];
natcasesort($p2); var_dump($p2);
// count / replace
var_dump(array_count_values(["a","b","a","1",1]));
var_dump(array_replace(['a'=>1,'b'=>2], ['b'=>3,'c'=>4]));
var_dump(array_replace_recursive(['a'=>['x'=>1]], ['a'=>['y'=>2]]));
var_dump(array_replace_recursive(['a'=>['x'=>1,'y'=>1]], ['a'=>['x'=>5]], ['q'=>1]));
// finders (php 8.4)
var_dump(array_find([1,2,3,4], fn($v) => $v > 2), array_find([1], fn($v) => $v > 9), array_find_key(['a'=>1,'b'=>2], fn($v) => $v === 2));
// shuffle determinism: sorted-restore shape
$s = [1,2,3,4,5]; shuffle($s); sort($s); var_dump($s);
$r = [1,2,3,4]; $kr = array_rand($r, 2); sort($kr); var_dump(count($kr), $kr[0] < 4, $kr[1] < 4);
var_dump(count((array)array_rand($r)));
// multisort V1: first array sorted
$mx = [3,1,2]; array_multisort($mx); var_dump($mx);
// ip family
var_dump(ip2long("127.0.0.1"), ip2long("255.255.255.255"), ip2long("256.1.1.1"), ip2long(""), long2ip(2130706433), long2ip(4294967295), long2ip(-1), long2ip(0));
var_dump(str_shuffle("") === "");
echo "done\n";
