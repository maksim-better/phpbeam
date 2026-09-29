<?php
$xml = "<root a=\"1\"><child id=\"x\">text</child><child id=\"y\"/></root>";

// expat layer
$p = xml_parser_create();
xml_parse_into_struct($p, $xml, $vals, $idx);
var_dump(count($vals), $vals[0], $vals[1], $idx["CHILD"]);
xml_parser_free($p);

// SimpleXML
$d = simplexml_load_string($xml);
echo (string)$d->child, "|", $d->child["id"], "|", $d["a"], "|", count($d->child), "|", $d->child[1]["id"], "\n";
foreach ($d->child as $c) echo $c["id"], ",";
echo "\n";
var_dump($d->getName(), $d->child->getName());
echo $d->asXML();
var_dump(simplexml_load_string("not xml") === false);

// DOM
$doc = new DOMDocument();
$doc->loadXML($xml);
var_dump($doc->documentElement->nodeName, $doc->getElementsByTagName("child")->length);
echo $doc->saveXML($doc->documentElement->firstChild), "\n";
$el = $doc->createElement("new", "val");
var_dump($doc->documentElement->appendChild($el) === $el);
echo trim($doc->saveXML());
var_dump($doc->documentElement->getAttribute("a"), $doc->documentElement->hasAttribute("a"), $doc->documentElement->hasAttribute("zz"));
$xp = new DOMXPath($doc);
$hits = $xp->query("//child");
var_dump($hits->length, $hits->item(0)->getAttribute("id"));
