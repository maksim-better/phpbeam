# phpbeam — PHP on the BEAM

**English** | [简体中文](README.zh-CN.md)

A tree-walking interpreter for **PHP 8.4**, written in Elixir and running on the Erlang VM (BEAM). The acceptance criterion is **semantic equivalence with real PHP**: every claim is measured **byte-for-byte against a real PHP 8.4** — differential tests first, then PHP's own official test suite (`.phpt`). The end state is a **complete PHP runtime on the BEAM** — arbitrary PHP 8.4 programs running with identical observable behavior (see PLAN.md for the acceptance definition and the phase plan).

```
$ ./phpx test/cases/13_showcase.php
phpbeam cart: 3 items, €26.74
in USD: 24.60
elixir > beam > php
cart had 3 items
caught: Division by zero
1+4+9+16+25 = 55
interpolation: 3 items for ~€26.74
```

## Status at a glance

| Metric | Value |
| --- | --- |
| php-src official tests ingested (tests/{lang,strings,func,classes,basic,output,security,run-test} + Zend/tests/exit) | **348 / 760 passing** (per-directory shard baselines; failures triaged three ways: fix / exempt / defer — see PLAN.md) |
| Full-suite target | **20,766 cases** across Zend/tests + all implemented extension dirs, ingested phase by phase (`scripts/criterion.sh` judges mechanically) |
| Builtins implemented | **~1,040 functions** across the std/date/mbstring/SPL/hash/xml/openssl/curl/sockets/DB (PDO+mysqli+pgsql+sqlite3)/zlib/zip/phar/posix/proc families |
| Differential cases vs local PHP 8.4 (stdout+stderr byte-exact) | **54** (`test/cases/*.php`) |
| Laravel smoke | `artisan` boots through composer autoload, DI container, config load (Symfony Finder chain), Carbon — into Kernel command dispatch |
| Codebase | ~25k lines of Elixir; 30+ builtin/class modules |

## Quick start

```console
$ mix deps.get && mix escript.build   # builds ./phpx (git deps go over SSH; see PLAN.md if hex/github are blocked)
$ ./phpx script.php                   # run a script ($argv/$argc seeded; include/require work)
$ ./phpx -r 'echo "hi ", PHP_INT_MAX, "\n";'
$ ./phpx --repl                       # persistent REPL
$ ./phpx serve <docroot> --port=8080  # HTTP SAPI ($_GET/$_POST/$_FILES/$_COOKIE, keep-alive)

$ scripts/gate.sh --lane fast         # build + non-phpt suites green (the everyday gate)
$ scripts/gate.sh --lane dirs -- lang # only the phpt shards your change touched
$ scripts/gate.sh --lane full         # all ingested phpt shards + shard-sum self-check
$ scripts/gate.sh --record            # re-record failure baselines (green suites only)

$ mix test                            # unit + differential + phpt suites
$ mix test --exclude phpt             # fast dev loop
```

The `.phpt` suites need an unpacked php-src tree (default `~/Downloads/php-8.4.25`, override with `PHP_SRC`) and the oracle binary at `/opt/homebrew/bin/php` (8.4.17 on the dev box). Failure baselines live in `tmp/baseline/<dir>.txt` (gitignored) and may only shrink.

## Verified semantics

Correctness is not claimed — it is **measured**, byte for byte, against `/opt/homebrew/bin/php` and the php-src corpus:

- **Errors & diagnostics render like PHP 8.4**: display copy on stdout + `log_errors` copy on stderr, `PHP Deprecated:`/`PHP Fatal error:` prefixes, multi-line uncaught errors with real call stacks, `expectf`-level parse-error wording (reserved `exit`/`die` in declaration slots — with the canonical token name even when the source says `die`).
- **Language**: full operator precedence incl. short-circuit `and`/`or`, `match`, first-class callable syntax, closures with identity semantics (`$f === $f` after copy; generator factories), traits (`insteadof`/`as` with declaration-site `self`/`parent` binding and owner-scoped visibility), enums, readonly/promoted properties in declaration order, namespaces, `@include` suppression, `new static::$prop(...)`.
- **OOP**: single inheritance, interfaces (with the native `Iterator`/`IteratorAggregate` → `Traversable` chain), abstract-method rules that treat trait abstracts as requirements on the *using* class, signature compatibility with `self`/`static` expansion, family-shared static property storage (one slot per declaring class, php semantics).
- **SPL & iterators**: ArrayObject/ArrayIterator, the DLL/Heap/PriorityQueue family, SplFileInfo family, and the iterator family — `IteratorIterator`, `FilterIterator` (accept-driven with live `$this->current()`), `DirectoryIterator`/`FilesystemIterator`/`RecursiveDirectoryIterator` (raw readdir order, `getSubPath`/`getSubPathname`), `GlobIterator`, `RecursiveIteratorIterator` (LEAVES_ONLY/SELF_FIRST/CHILD_FIRST) — enough that Symfony Finder boots.
- **Runtime**: process execution (`proc_open` with fd plumbing, `exec`/`system`/`passthru`/`shell_exec`), streams with the filter chain and the `php://` family, sessions on real files, INI layer (286-entry registry, `-c/-n/-d`, `.user.ini`), CLI `$argv`/`argc` with `$_SERVER` mirroring.
- **Clients & storage**: PDO (mysql/sqlite) + mysqli (prepared protocol) + pgsql, zlib/zip/phar, openssl (AES/RSA/X509), curl (file+http(s)), sockets on gen_tcp, `WeakMap`.

## How correctness is enforced

Three layers:

1. **Unit tests** for the lexer, parser, value model, and ordered arrays.
2. **Differential tests** (`test/cases/*.php`): every case runs on local PHP and on phpx; **stdout must match byte for byte** (and stderr for the error-path cases).
3. **The official php-src acceptance harness** (`test/phpbeam/phpt_test.exs`): `.phpt` cases run with `run-tests.php` semantics. Ingestion is phased (Zend/tests first, then extension dirs); each batch is triaged into **fix / exempt (`docs/matrix/exempt.md`) / defer (`docs/matrix/deferred.md`)** — nothing is silently skipped. `scripts/criterion.sh` turns the frozen criterion ("failure set ⊆ exempt set") into a mechanical check.

Discipline: one module per commit, gated by `scripts/gate.sh`; failure baselines only shrink; version-pinned machine constants (php version, libcurl, sqlite) are recorded in `docs/matrix/drift.md` when the oracle moves. See **PLAN.md** for the live plan and **ARCHITECTURE_DESIGN.md** for the module contract.
