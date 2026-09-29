<?php
// phar fixture embedded base64 (built by php 8.4 with phar.readonly=0)
$bin = base64_decode("PD9waHAgZWNobyAicyI7IF9fSEFMVF9DT01QSUxFUigpOyA/Pg0KfgAAAAIAAAARAAAAAQAAAAAAFAAAAGE6MTp7czozOiJ0b3AiO2I6MTt9BQAAAGEudHh0BQAAANmxu2oFAAAAajng0KQBAAASAAAAYToxOntzOjE6ImsiO2k6MTt9CQAAAGRpci9iLnR4dAwAAADZsbtqDAAAAAYzWrCkAQAAAAAAAGFscGhhYmV0YSBjb250ZW50C+uWHatIfOKZqQLsJYNf9wt60IYWTgGK28ob4b73+QcDAAAAR0JNQg==");
$pharPath = __DIR__ . "/40_fixture.phar";
file_put_contents($pharPath, $bin);

// Phar class reads
$p = new Phar($pharPath);
var_dump($p->count(), $p->offsetExists("a.txt"), $p->offsetExists("nope"));
var_dump($p->getSignature()["hash_type"], strlen($p->getSignature()["hash"]));
var_dump($p->getMetadata());
$fi = $p["dir/b.txt"];
var_dump(get_class($fi), $fi->getPathname());
var_dump($fi->getContent());

// phar:// wrapper
var_dump(file_get_contents("phar://" . $pharPath . "/a.txt"));
var_dump(md5_file("phar://" . $pharPath . "/dir/b.txt"));
var_dump(filesize("phar://" . $pharPath . "/a.txt"));

// compress.zlib:// wrapper
$gz = __DIR__ . "/40_fixture.gz";
file_put_contents($gz, gzencode("wrapped\n", 6));
var_dump(file_get_contents("compress.zlib://" . $gz));

// zip:// wrapper
$zp = __DIR__ . "/40_fixture.zip";
@unlink($zp);
$z = new ZipArchive();
$z->open($zp, ZipArchive::CREATE);
$z->addFromString("e.txt", "zed");
$z->close();
var_dump(file_get_contents("zip://" . $zp . "#e.txt"));

// statics
var_dump(Phar::isValidPharFilename("x.phar"), Phar::canCompress(), Phar::apiVersion());

unlink($pharPath); unlink($gz); unlink($zp);
