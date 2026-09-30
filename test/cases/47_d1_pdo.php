<?php
$pdo = new PDO("mysql:host=127.0.0.1;dbname=information_schema", "root", "root");
var_dump($pdo->getAttribute(PDO::ATTR_SERVER_VERSION));
var_dump($pdo->query("SELECT 1+1 AS s, \"x\" AS t")->fetch(PDO::FETCH_ASSOC));
$st = $pdo->prepare("SELECT :a AS a, :b AS b");
$st->execute([":a" => 1, ":b" => "z"]);
var_dump($st->fetch(PDO::FETCH_ASSOC), $st->rowCount(), $st->columnCount());
$st2 = $pdo->prepare("SELECT ? AS a, ? AS b");
$st2->execute([1, "z"]);
var_dump($st2->fetch(PDO::FETCH_NUM), $st2->fetch(PDO::FETCH_NUM));

$pdo->exec("CREATE DATABASE IF NOT EXISTS phpbeam_test");
$pdo->exec("USE phpbeam_test");
$pdo->exec("DROP TABLE IF EXISTS t1");
$pdo->exec("CREATE TABLE t1 (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(20))");
var_dump($pdo->exec("INSERT INTO t1 (name) VALUES (\"alice\"), (\"bob\")"));
var_dump($pdo->lastInsertId());
var_dump($pdo->query("SELECT * FROM t1")->fetchAll(PDO::FETCH_ASSOC));
var_dump((int)$pdo->query("SELECT COUNT(*) FROM t1")->fetchColumn());

var_dump($pdo->beginTransaction(), $pdo->inTransaction());
$pdo->exec("INSERT INTO t1 (name) VALUES (\"carol\")");
$pdo->rollBack();
var_dump((int)$pdo->query("SELECT COUNT(*) FROM t1")->fetchColumn());

$pdo->beginTransaction();
$pdo->exec("INSERT INTO t1 (name) VALUES (\"carol\")");
$pdo->commit();
var_dump((int)$pdo->query("SELECT COUNT(*) FROM t1")->fetchColumn());

var_dump($pdo->quote("a\"b"), $pdo->errorCode());

$up = $pdo->prepare("UPDATE t1 SET name = :n WHERE id = :i");
$up->execute([":n" => "ALICE", ":i" => 1]);
var_dump($up->rowCount());
var_dump($pdo->query("SELECT name FROM t1 WHERE id = 1")->fetchColumn());

try { $pdo->query("SELECT * FROM nope"); } catch (PDOException $e) {
    echo get_class($e), ": ", $e->getMessage(), "\n";
}
$del = $pdo->prepare("DELETE FROM t1 WHERE id > :i");
$del->execute([":i" => 1]);
var_dump((int)$pdo->query("SELECT COUNT(*) FROM t1")->fetchColumn());
