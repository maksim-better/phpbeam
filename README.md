# phpbeam — PHP on the BEAM

**English** | [简体中文](README.zh-CN.md)

A tree-walking interpreter for a **subset of PHP 8.4**, implemented in Elixir and running on the Erlang VM (BEAM). This is stage one of "bringing PHP to the BEAM": a complete lexer → parser → evaluator pipeline whose semantics are pinned against a local PHP 8.4 via **byte-exact differential testing**.

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

## Quick start

```console
$ mix deps.get && mix escript.build   # builds ./phpx
$ ./phpx script.php                   # run a script
$ ./phpx -r 'echo "hi ", PHP_INT_MAX, "\n";'
$ ./phpx --repl                       # persistent REPL (vars/functions/classes kept across lines)
$ mix test                            # unit + differential tests (needs a local PHP 8.4 at /opt/homebrew/bin/php)
```

## Supported subset

| Layer | Capabilities |
| --- | --- |
| Lexer | `<?php`/`<?=`/inline HTML, line/block comments (incl. the `?>`-in-comment rule), all numeric literals (hex/oct/bin/underscores/64-bit overflow to float), single/double quotes, heredoc/nowdoc (7.3+ flexible indentation), escape sequences, simple and `{$...}` interpolation |
| Parser | full operator precedence (`or`/`and` bind looser than assignment, `**` binds tighter than unary minus, `??` right-associative), alternative syntax (`if: endif`), `match`, `list()` destructuring, closures/arrow functions/IIFE, traits (`insteadof`/`as`), classes/interfaces/abstract/final, static members, namespaces and `use` |
| Evaluation | PHP 8 type juggling (loose-equality matrix, numeric strings, arithmetic coercion, `"az"++`), ordered hash arrays (a slot scheme that preserves insertion order, key normalization incl. int64 boundaries), `max(int key)+1` auto-indexing, byte-exact var_dump/print_r/var_export/json formatting |
| Classes | single inheritance, interfaces, trait flattening, `self`/`static`/`parent` (late static binding), `::class`, `instanceof`, static properties, visibility, `__construct`/`__get`/`__set`/`__isset`/`__call`/`__callStatic`/`__toString`, object-handle semantics (writes propagate) |
| Exceptions | native `Throwable` hierarchy (Exception/Error and common subclasses), `throw`/`try`/`catch` (matching along the inheritance chain)/`finally`, arithmetic errors materialized as exception objects |
| References | `$a = &$b` shared cells, `foreach as &$v` write-back, `&` parameter write-back, `usort`-family in-place sorting |
| Functions | ~90 built-in functions + `call_user_func(_array)`/`array_map`/`array_filter`/`array_reduce`/`usort`/`uasort`/`uksort` higher-order functions, static variables, recursion, variadics, named arguments |

## Architecture

```
lib/phpbeam/
├── lexer.ex        # lexing: HTML/PHP mode switching, heredoc, interpolation scanning
├── parser.ex       # recursive-descent parsing: tokens → AST (node shapes in ast.ex)
├── interp.ex       # statement execution, control-flow signals (return/break/continue/throw pass through as values, state is never lost)
├── eval.ex         # expression evaluation, lvalue writes, function/method dispatch, higher-order builtins
├── classes.ex      # class model: registration (trait flattening), inheritance-chain lookup, native Throwables
├── value.ex        # the zval equivalent + all type-juggling rules (gcvt 14-digit float formatting, short representations)
├── parray.ex       # ordered hash array (monotonic slots preserve order)
├── render.ex       # var_dump/print_r/var_export (byte-exact against PHP)
├── builtin/        # string/math/array/var + evaluator-side higher-order functions
└── cli.ex          # the phpx CLI + persistent REPL
```

**Key design decisions:**

- **Control flow as values**: `return`/`break`/`throw` propagate through the evaluator as `{:unwind, signal}` tuples carrying the latest interpreter state — statics, the object registry, and output buffers all survive exception paths (Elixir exceptions would discard accumulated state, so they are not used for control flow).
- **Object registry**: values hold `{:object, id}` handles into `interp.objects`; property writes propagate to every holder, matching PHP's zval reference semantics.
- **Array slot scheme**: monotonically increasing slots preserve insertion order; deletions leave holes and replacements keep their position; `max(historical int keys)+1` auto-indexing (including negative keys and the high-water mark after unset).
- **Differential testing**: every `test/cases/*.php` runs on both local PHP 8.4 and phpx, with stdout compared byte for byte — 13 suites covering everything from arithmetic corners (`018` illegal octal, `"1abc"+1` warns then yields 1) to the full semantics of OOP, exceptions, and references.

## Known deviations

- `__destruct` timing is not guaranteed (BEAM GC semantics); destructors all run at script end
- No resource type or file I/O; no `eval()`, anonymous classes, `goto`, or enums
- The tree-walking interpreter is 1–2 orders of magnitude slower than php-src (expected; performance is a milestone of the future compiled backend)
- Visibility checks are lenient (private/protected reads are allowed; writes follow declarations)

## Roadmap

- A PHP → Elixir AST compilation backend (native BEAM performance + hot code loading; the lexer/parser/value model is fully reused)
- A Plug-based web runtime with one BEAM process per request (PHP's share-nothing model maps naturally onto BEAM processes)
- Elixir interop (PHP calling Elixir functions), `eval`/file I/O

## License

[MIT](LICENSE)
