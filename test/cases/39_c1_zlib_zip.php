<?php
// zlib one-shot codecs (byte-level against php)
$d = gzdeflate("hello hello hello hello world", 6);
var_dump(bin2hex($d), gzinflate($d) === "hello hello hello hello world");
var_dump(bin2hex(gzcompress("hello world")), gzuncompress(gzcompress("hello world")));
$e = gzencode("hello world");
var_dump(strlen($e), bin2hex($e), gzdecode($e));
var_dump(bin2hex(zlib_encode("hi", ZLIB_ENCODING_DEFLATE)), zlib_decode(gzcompress("hi")));
var_dump(gzinflate(gzdeflate("", 9)) === "", zlib_get_coding_type());
try { gzinflate("garbage!!"); } catch (Throwable $x) { echo get_class($x), "\n"; }

// incremental contexts
$ctx = deflate_init(ZLIB_ENCODING_GZIP);
$a = deflate_add($ctx, "hello ", ZLIB_NO_FLUSH);
$b = deflate_add($ctx, "world", ZLIB_FINISH);
var_dump(gzdecode($a . $b));
$ic = inflate_init(ZLIB_ENCODING_GZIP);
var_dump(inflate_add($ic, $a), inflate_add($ic, $b), inflate_get_status($ic), inflate_get_read_len($ic));
try { deflate_add("nope", "x"); } catch (Throwable $x) { echo get_class($x), ": ", $x->getMessage(), "\n"; }
try { deflate_init(99); } catch (Throwable $x) { echo get_class($x), ": ", $x->getMessage(), "\n"; }

// gz file family (fixture written by the case itself)
$gz = __DIR__ . "/39_fixture.gz";
file_put_contents($gz, gzencode("line1\nline2\n", 6));
$zp = gzopen($gz, "rb");
var_dump(gzgets($zp), gzeof($zp), gzread($zp, 100), gzeof($zp), gztell($zp));
gzrewind($zp);
var_dump(gzread($zp, 5), gzseek($zp, 6), gzgetc($zp), gzgets($zp));
gzclose($zp);
var_dump(readgzfile($gz), gzfile($gz));
$w = gzopen($gz, "wb9");
gzwrite($w, "written ");
gzputs($w, "line");
gzclose($w);
var_dump(bin2hex(file_get_contents($gz)));
unlink($gz);

// ZipArchive round trip
$zp2 = __DIR__ . "/39_fixture.zip";
@unlink($zp2);
$z = new ZipArchive();
var_dump($z->open($zp2, ZipArchive::CREATE));
var_dump($z->addFromString("a.txt", "alpha"), $z->addFromString("dir/b.txt", "beta"), $z->numFiles);
var_dump($z->close());
$z2 = new ZipArchive();
var_dump($z2->open($zp2));
var_dump($z2->numFiles, $z2->getNameIndex(0), $z2->getNameIndex(1), $z2->locateName("a.txt"), $z2->locateName("zz"));
echo $z2->getFromName("dir/b.txt"), "\n";
var_dump($z2->statIndex(0)["name"], $z2->statIndex(0)["size"], $z2->statIndex(1)["name"]);
var_dump($z2->renameName("a.txt", "renamed.txt"), $z2->getFromName("renamed.txt"));
$z2->deleteName("dir/b.txt");
var_dump($z2->numFiles);
$z2->close();
unlink($zp2);

// legacy zip_* API with its deprecation warnings
$zp3 = __DIR__ . "/39_legacy.zip";
$zc = new ZipArchive();
$zc->open($zp3, ZipArchive::CREATE);
$zc->addFromString("a.txt", "alpha");
$zc->close();
$zr = zip_open($zp3);
$ent = zip_read($zr);
var_dump(zip_entry_name($ent), zip_entry_filesize($ent), zip_entry_compressedsize($ent), zip_entry_compressionmethod($ent));
var_dump(zip_entry_open($zr, $ent), zip_entry_read($ent), zip_entry_close($ent));
var_dump(zip_read($zr) == false);
zip_close($zr);
var_dump(zip_open("/definitely/not/here.zip"));
unlink($zp3);
