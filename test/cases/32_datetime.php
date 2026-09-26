<?php
// PHASE B1: date engine — parse grammar, format matrix, zones, relative,
// intervals, diff, mktime family, procedural API
$d = new DateTime("2026-01-02 03:04:05");
var_dump($d->format("Y-m-d H:i:s"), $d->format("U"), $d->getTimezone()->getName());
$d2 = new DateTime("2026-01-02 03:04:05.123456");
var_dump($d2->format("Y-m-d H:i:s.u"));
$ny = new DateTime("2026-01-02 03:04:05 America/New_York");
var_dump($ny->format("Y-m-d H:i:s T P e U"));
$summer = new DateTime("2026-07-04 12:00:00 America/New_York");
var_dump($summer->format("T P U"));
var_dump((new DateTime("@1767313445"))->format("Y-m-d H:i:s P e"));
foreach (["dDjlNSwzWFmMntLoYyaABgGhHisueIOPTZcrUv"] as $spec) {
  echo $spec, "=", $ny->format($spec), "\n";
}
// relative grammar
$m = new DateTime("2026-01-31");
var_dump($m->modify("+1 month")->format("Y-m-d"));
var_dump($m->modify("last day of next month")->format("Y-m-d"));
var_dump($m->modify("second sunday of march 2026")->format("Y-m-d"));
var_dump($m->modify("3 fridays")->format("Y-m-d"));
var_dump((new DateTime("2026-01-02"))->modify("next Thursday")->format("Y-m-d"));
var_dump((new DateTime("2026-01-02 10:30"))->modify("midnight")->format("H:i"));
// interval + add + diff
$iv = new DateInterval("P1Y2M3DT4H5M6S");
var_dump($iv->y, $iv->m, $iv->d, $iv->h, $iv->i, $iv->s);
$dd = (new DateTime("2026-01-01"))->add($iv);
var_dump($dd->format("Y-m-d H:i:s"));
$a = new DateTime("2026-01-02"); $b = new DateTime("2026-03-15 04:00:00");
$diff = $a->diff($b);
var_dump($diff->days, $diff->m, $diff->d, $diff->h, $diff->invert, $diff->format("%R%a days"));
// immutable
$i = new DateTimeImmutable("2026-06-15");
var_dump($i->format("Y-m-d"), $i === $i->modify("+1 day") ? "same" : "new", $i->format("Y-m-d"));
// createFromFormat
$cf = DateTime::createFromFormat("Y-m-d H:i", "2026-11-30 23:45");
var_dump($cf->format("Y-m-d H:i:s"));
// mktime family + checkdate
var_dump(mktime(3, 4, 5, 1, 2, 2026), gmmktime(3, 4, 5, 1, 2, 2026));
var_dump(mktime(0, 0, 0, 13, 1, 2026), mktime(0, 0, 0, 2, 30, 2026));
var_dump(checkdate(2, 29, 2024), checkdate(2, 29, 2023), checkdate(13, 1, 2026));
// procedural + timezone switching
$p = date_create("2026-01-02 03:04:05");
var_dump(date_format($p, "Y-m-d H:i:s"));
$p2 = date_modify($p, "+2 days");
var_dump(date_format($p2, "Y-m-d"), $p === $p2 ? "same" : "new");
var_dump(date_default_timezone_set("Asia/Tokyo"), date_default_timezone_get(), date("T", 1767000000));
date_default_timezone_set("UTC");
// strtotime
var_dump(strtotime("2026-03-15"), strtotime("2026-03-15 14:30:00 UTC") === strtotime("2026-03-15 14:30:00"));
echo "done\n";
