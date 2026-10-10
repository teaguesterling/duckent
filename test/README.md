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
