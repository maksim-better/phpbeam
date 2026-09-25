# phpbeam — PHP on the BEAM

**English** | [简体中文](README.zh-CN.md)

A tree-walking interpreter for a **subset of PHP 8.4**, written in Elixir and running on the Erlang VM (BEAM). It is stage one of a longer plan to **run WordPress on the BEAM**: the whole language pipeline (lexer → parser → evaluator) is complete, and every semantic decision is pinned **byte-for-byte against a real PHP 8.4** — first by differential tests, then by PHP's own official test suite (`.phpt`).

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
| php-src official tests (tests/{lang,strings,func,classes,basic,output}) | **273 / 697 passing** (visibility enforcement landed; Zend-suite regression under repair, see PLAN.md) |
| WordPress builtin-function demand covered (by call frequency) | **93%** (346 builtins; real MySQL via MyXQL) |
| Differential cases vs local PHP 8.4 (stdout byte-exact) | 19/19 |
| wp-load.php | unconfigured: error page **byte-identical**; with wp-config + live MySQL: completes, exit 0 |
| Codebase | ~16k lines of Elixir, 13 builtin modules |

## Quick start

```console
$ mix deps.get && mix escript.build   # builds ./phpx
$ ./phpx script.php                   # run a script (include/require work)
$ ./phpx -r 'echo "hi ", PHP_INT_MAX, "\n";'
$ ./phpx --repl                       # persistent REPL
$ mix test                            # unit + differential + .phpt suites
$ mix test --exclude phpt             # fast dev loop
```

The `.phpt` suites need an unpacked php-src tree (default `~/Downloads/php-8.4.24`, override with `PHP_SRC`).

## Verified semantics

Correctness is not claimed — it is **measured**, byte for byte, against `/opt/homebrew/bin/php` (8.4.2) and the official php-src 8.4.24 test corpus:

- **Warnings and errors render exactly like PHP 8.4**: `\nWarning: Undefined variable $x in /real/path.php on line 3`, multi-line uncaught errors with a real call stack including argument lists (`#0 /app/wp-load.php(5): require()`), link-time engine fatals without the Uncaught wrapper — all verified by probes and differential cases.
- **Language**: full PHP 8 operator precedence, `match`, `list()` destructuring, closures/arrow functions, traits (`insteadof`/`as`), namespaces, `include`/`require`(_once) with full-expression operands (`require_once ABSPATH . 'wp-settings.php'`), `eval()` in the calling scope, `__FILE__`/`__DIR__` with per-file stacks, goto-free control flow.
- **Types & values**: PHP 8 type juggling (loose equality matrix, numeric strings, `"az"++`), ordered hash arrays with slot-stable insertion order, int64 key normalization and auto-indexing, byte-exact `var_dump`/`print_r`/`var_export`/JSON.
- **OOP**: single inheritance, interfaces, traits, late static binding, magic methods, object handles with write-through semantics — and **link-time strictness**: abstract enforcement, visibility narrowing, static conflicts, `final` overrides, and signature compatibility with rendered signatures (`Declaration of D::f(array $a) must be compatible with A::f($a)`).
- **Throwables**: native Exception/Error hierarchy, `DivisionByZeroError`, `ValueError` from builtins, `Uncaught Error:` formatting with real stack frames.
- **Functions**: ~220 builtins across strings/math/arrays/files/output-buffering/serialize/regex; higher-order dispatch (`array_map`, `usort` family with by-ref writeback, `preg_replace_callback`), `func_get_args()` family, references (`$a = &$b`, `foreach as &$v`, `&` params).
- **PCRE**: the full `preg_*` family on raw PCRE — named groups (`$m['year']`), `PREG_OFFSET_CAPTURE`, `PATTERN_ORDER`/`SET_ORDER`, `$N`/`${N}`/`$name` replacement backrefs, `preg_split` flags.
- **I/O & state**: `include`/`require` with include_path resolution, string-based file functions (`file_get_contents`, `file_put_contents`, `scandir`, ...), output buffering (`ob_*` family capturing warnings too), `serialize`/`unserialize` with visibility-mangled property names and shortest-roundtrip floats, array cursors (`current`/`next`/`key`/...).

## How correctness is enforced

Three layers, all run by `mix test`:

1. **Unit tests** for the lexer, parser, value model, and ordered arrays.
2. **Differential tests** (`test/cases/*.php`): every case runs on local PHP and on phpx; **stdout must match byte for byte** — warnings, error text, line numbers, and all.
3. **The official php-src acceptance harness** (`test/phpbeam/phpt_test.exs`): ~700 `.phpt` cases from the php-8.4.24 distribution, run with `run-tests.php` semantics (PHP-style `trim`, the exact `expectf_to_regex` code table). Failures are triaged with class tags (`undef_fn`, `parse_error`, `mismatch`, …) so each milestone attacks the largest bucket.

## Architecture

```
lib/phpbeam/
├── lexer.ex        # PHP 8 lexer: HTML/PHP modes, heredoc, interpolation scanning
├── parser.ex       # recursive descent → AST; every statement carries its line
├── interp.ex       # statement execution; warnings/fatals, file stack, call stack
├── eval.ex         # expressions, lvalues, call dispatch (+ higher-order preg/sorts)
├── classes.ex      # class model, link-time inheritance checks, native Throwables
├── value.ex        # zval equivalent: all type-juggling rules, float formatting
├── parray.ex       # ordered hash array (monotonic slots) + internal cursor
├── pattern.ex      # preg_* engine on raw PCRE (:re), named-group index scanner
├── render.ex       # var_dump / print_r / var_export (byte-exact vs PHP)
├── env.ex          # scopes: locals/statics/captures + per-frame arg snapshots
├── builtin/        # 11 registry modules: string, math, array, var, file, io,
│                   # runtime/ini, output buffering, serialize, cursors, preg
└── cli.ex          # phpx CLI + persistent REPL
```

**Key design decisions:**

- **Control flow as values.** `return`/`break`/`throw` propagate as `{:unwind, signal}` tuples that always carry the latest interpreter state — statics, the object registry, and output buffers survive exception paths (Elixir exceptions would discard accumulated state).
- **The interpreter state is threaded, never shared.** `{result, env, interp}` flows through everything; side effects (warnings, ob writes, argument evaluation) must return the new state or they are silently lost — a whole family of bugs this project has fixed the hard way.
- **Objects are handles.** `{:object, id}` into `interp.objects`; property writes flow through the registry so every holder sees them — PHP reference semantics for free.
- **Errors carry positions.** Statements wrap their source line; `Interp.cur_line` + a per-file stack feed every warning/fatal, and function calls push frames (with rendered arguments) for PHP 8.4-style uncaught traces.
- **PCRE is PCRE.** Erlang's `:re` *is* PCRE, so patterns pass through with only delimiter/modifier translation.

## Roadmap to WordPress

Measured against the actual WordPress source (every function it calls):

1. ✅ Language core, include chain, preg_*, serialize, output buffering — **80% of WP's builtin demand covered**
2. ▶ String/misc builtin sweep (`is_callable`, `parse_url`, `md5`, `ord`/`chr`, `compact`, …) → ~85%
3. ◻ Resource streams (`fopen`/`fread`/`fseek` … — needs a resource value type), `trigger_error`, date/time family
4. ◻ SPL (`ArrayObject`, iterators), sessions, `filter_var`
5. ◻ `mysqli`/PDO over Elixir database drivers — the gate for a real site
6. ◻ Performance: a PHP→Elixir AST compile backend (lexer/parser/value model fully reused) — the tree walker is 1–2 orders slower than php-src

## License

[MIT](LICENSE)
