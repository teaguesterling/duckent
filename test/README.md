# Testing this extension
This directory contains all the tests for this extension. The `sql` directory holds tests that are written as [SQLLogicTests](https://duckdb.org/dev/sqllogictest/intro.html). DuckDB aims to have most its tests in this format as SQL statements, so for the quack extension, this should probably be the goal too.

The root makefile contains targets to build and run all of these tests. To run the SQLLogicTests:
```bash
make test
```
or 
```bash
make test_debug
```
## Fixtures and `test_config.json`

`data/` holds the fixtures the plan repo's suites read by relative path (`test/data/app.parquet`
and friends); they are copied from `duckent/test/data/`, whose `FIXTURES.md` records how each one
was generated. Because the corpus spells its sources `read_parquet('test/data/app.parquet')`,
`test_config.json` lists `parquet` alongside `core_functions`, `json` and `duckent`. That changes
only which already-statically-built extension the unittest binary loads at startup — the
extensions duckent itself links are still the three in `extension_config.cmake`. A `require
parquet` line in each test file would do the same job, but a `require` that fails to resolve SKIPs
the file silently instead of failing it, which is the vacuous-green failure mode the `--test-config`
override in the root Makefile exists to avoid.

## The mutant harness

```bash
python3 test/run_mutants.py --increment mvp
```

`mutants/` holds 27 planted defects copied from the plan repo (`scripts/check_macro_identity.py`
holds them byte-identical to it, in both directions), each a `CREATE OR REPLACE MACRO` overlay
with a manifest claim about which suites must fail when it is applied. 26 carry a control; MN08
has none, because its mutation is in the plan repo's runner rather than a macro. It is how this
repo knows its corpus has teeth rather than merely being large.

Count these from `mutants/` or from the harness's own last line, never from this paragraph — the
numbers here were stale twice before being written down this way.

Applying one needs no rebuild. The harness writes a copy of `test_config.json` with the overlay
SQL added as `on_init` — which DuckDB's sqllogictest executes on the test's own connection, after
the statically linked extensions have loaded and so after duckent has created the base macros —
and runs the already-built binary over that mutant's suites. 19 mutants and their 19 controls cost
one build, not 38 — measured at 11m41s on a 36-core machine, against 3m54s for `make test` itself.

Scope is derived, not marked: an increment is a set of suites (`INCREMENTS` in `run_mutants.py`,
taken from the gate's own `DUCKENT_SUITES`), and an entry is in scope exactly when one of its
`expect_fail` suites is in it. Eight entries are out of scope and reported with a count: six name
only front-end suites this repo does not carry, and MN32/MN33 name `48_treeql_parse.test`, the
reader's own proof, which is not mirrored here for the reasons
`scripts/check_macro_identity.py` records beside it. Two (MN04, MN24) straddle the boundary and
are run against their in-scope suites with the rest named. Nothing per-entry is written down, so
moving a suite into or out of the gate cannot leave a stale marking behind.

`mutants/regen.py` is the plan repo's generator, copied so the harness can import it and rebuild
each in-scope mutant from `src/sql_macros/` to prove the copy is still its source plus the planted
edit. Run it only in the plan repo — here it resolves its sources as `<root>/sql/`, which this
repo spells `src/sql_macros/`, and the harness points it at a shim rather than editing the copy.
