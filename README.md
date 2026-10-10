# duckent

A DuckDB extension for querying trees in SQL: declare a relation's tree shape once, then select
nodes with a structural selector language instead of hand-writing recursive CTEs.

```sql
CALL tree_ddl_create('main', 'app', tree_spec(
  tree_shape(root := 'file_path', "order" := 'node_id', level := 'depth',
             size := 'descendant_count',
             semantic := tree_semantic(type := 'type', key := 'name')),
  source := 'read_parquet(''test/data/app.parquet'')'));

-- every string literal inside a function definition, one row per match
FROM tree_match('main', 'app', tree_steps([
  {type: 'function_definition', "as": 'fn'},
  {comb: 'desc', type: 'string'}
])) SELECT fn.name AS fn, name AS literal;
```

```
┌───────┬───────────────────────────────────┐
│  fn   │              literal              │
├───────┼───────────────────────────────────┤
│ greet │ f"Hello, {name}"                  │
│ greet │ """Return a greeting for name.""" │
└───────┴───────────────────────────────────┘
```

That runs as written against this repository's own fixture, which is why the source path is
`test/data/app.parquet`: an example nobody has executed is a claim with nothing verifying it, and
this project has spent a lot of effort on not shipping those.

## What this build is

This is the **MVP increment**: the TREEQL slot matcher and the seven catalog verbs, with no
selector front-end. It is a port of a complete, tested prototype — duckent's semantics were
developed as DuckDB SQL macros, and this extension **embeds those macros unchanged**.

That is the central design fact, and it is enforced rather than merely intended:

- **The macros are the semantics.** `src/sql_macros/00_types.sql` … `08_traversal.sql` are
  byte-identical copies of the reference implementation's `sql/`. CI fails if any of them drifts
  by a single byte, in either direction.
- **The C++ is an executor layer only.** It marshals arguments, runs compiled statement lists,
  and registers functions. It decides nothing about trees. There is no C++ reimplementation of
  any rule the macros already state, and a corpus assertion that could only be made to pass by
  editing a `.sql` file is treated as a semantics change belonging upstream, not here.

### Surface

Seven `CALL` verbs — `tree_ddl_create`, `tree_ddl_drop`, `tree_ddl_alter`, `tree_insert`,
`tree_replace`, `tree_delete`, `tree_check` — plus the table function `tree_match`.

Each verb compiles its statement list through its own `tree_compile_*` macro and executes it on a
connection of its own, with an explicit `BEGIN`/`COMMIT` and a `ROLLBACK` on error. The mechanism,
the three alternatives that were measured and rejected, and why one of them deadlocks are in
[`docs/executor-mechanism.md`](docs/executor-mechanism.md).

**Verbs and `tree_match` refuse inside an explicit transaction.** They work on connections of
their own, so inside a caller's `BEGIN` a verb's writes would survive the caller's `ROLLBACK`, and
`tree_match` would answer from the database as of the transaction's start — a silent stale read.
Both refuse instead, with a message naming which consequence applies. This matches what DuckDB
itself does: `CHECKPOINT` and a nested `BEGIN` also refuse in a transaction, and also end it.

### Selector languages

`tree_match` takes IR — the list of step structs that `tree_steps()` builds. A **text** selector
is refused by a registry lookup, not a hardcoded branch: `tree_catalog.selector_languages` holds
the languages that are registered and which of them have a parser.

This build registers `treeql` and defaults to it. **CSS-style selectors are a separate extension**
that registers itself into that same table, which is why the registry is a table rather than a
compile-time list. Load it and `tree_catalog_languages()` gains a `css` row; nothing in this
extension changes.

## Verification

The durable asset here is the test corpus, not the code. These are the numbers this build is
gated on, all measured on the committed tree:

| Gate | What it proves | State |
|---|---|---|
| `make test` | the 16 reference suites plus 3 extension-only ones | **19 cases, 1230 assertions, 0 failures, 0 skipped** |
| `test/check_gate.py` | that the corpus **ran**, not merely that nothing failed | all 16 suites present by run marker; floor of 495 assertions; no crash signature |
| `scripts/check_macro_identity.py` | no drift in the embedded macros, the copied suites, or the copied mutants — in both directions | green |
| `test/compile_differential.py` | the two implementations compile identical SQL from identical arguments | 26 macro cases + 3 verb cases agree |
| `test/run_mutants.py --increment mvp` | the corpus has teeth | **17 of 23 planted defects in scope, all 17 killed, 17/17 controls pass**, 6 reported out of scope by name |

Two of these exist because the corpus alone cannot see certain bugs:

- **The compile differential** exists because both implementations run the *same* macros, so the
  corpus only ever observes the *effect* of the compiled statements, never the statements
  themselves. Argument marshalling is the one bug class this layer introduces, and this is the
  only thing that can see it. Its verb-level cases drive the real `CALL` path, because a direct
  macro call never reaches the C++ at all — a macro-only differential would pass with the
  marshalling code deleted.
- **The gate** exists because the reference runner has `DUCKENT_NO_SKIP`, which turns a skip into
  a failure, and DuckDB's `require` merely skips. A suite dropping out of the glob would otherwise
  read as a smaller green number rather than as a failure.

Running the gates:

```sh
make                                    # build
set -o pipefail; make test 2>&1 | tee test.log
python3 test/check_gate.py test.log
python3 scripts/check_macro_identity.py --plan-repo ../duckent
python3 test/compile_differential.py --plan-repo ../duckent --duckdb ./build/release/duckdb
python3 test/run_mutants.py --increment mvp
```

`test/README.md` covers the fixtures, `test_config.json`, and how the mutant harness applies a
mutant without rebuilding.

## Not in this increment

- **No text selector front-end.** CSS-style selectors are a separate extension, as above.
- **No sequence or representation layer.** The reference implementation's `40_corpus`,
  `41_differential_sitting_duck`, `42_second_differential`, `43_representation`, `44_parsers` and
  `45_duck_blocks` suites are not carried here, and the 6 mutants they guard are reported as out
  of scope by name rather than silently skipped.

### Known issue

Loading the built extension into a client where `json` and `core_functions` are not yet installed
fails with an unhelpful message:

```
duckent: internal: refusal with a NULL message; see FINDINGS on error(NULL) in 1.5.5
```

The dependency handling itself is correct — `INSTALL json; INSTALL core_functions` once, and
autoload handles it from then on, with no explicit `LOAD` needed. It is the diagnostic that is
wrong, at the worst possible moment. The from-source build is unaffected, because both are
statically linked via `extension_config.cmake`.

## Building

DuckDB 1.5.5. `core_functions` and `json` must be statically linked ahead of duckent —
autoload is not sufficient, because `TryAutoLoadAvailableExtension` resolves from
`~/.duckdb/extensions/<version>/<platform>/` and silently no-ops in a from-source build.
`extension_config.cmake` is the only guarantee, and the `from-source-load` CI job is the only
place that failure would show up.

```sh
git clone --recurse-submodules <this repo>
make
./build/release/duckdb -c "SELECT tree_canonical_columns()[1];"
```

[`docs/README.md`](docs/README.md) is the upstream extension template's own documentation, kept
unmodified for its build and distribution instructions.

## Design documents

The design spec and implementation plan live in the reference repository, alongside the macros
this extension embeds:

- `docs/superpowers/specs/2026-10-09-duckent-cpp-mvp-design.md` — what the MVP is and why
- `docs/superpowers/plans/2026-10-09-duckent-cpp-mvp.md` — how it was built
- `docs/cheatsheet.md` there is generated *from* a live catalog, so it cannot describe a
  declaration the implementation does not honour.
