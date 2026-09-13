# FINDINGS

What first contact showed. Newest first. Every oracle divergence gets an entry with adjudication before any test changes.

## Spec deviations in this milestone

Where the prototype knowingly differs from `docs/superpowers/specs/2026-09-13-duckent-core-design.md`. Each is a deviation to carry forward or close in M2, not an accident.

- `tree_state.partitions.root_key` is `VARCHAR` (the ROOT struct cast to text), not the STRUCT §2.2 describes; one column type serves every tree's ROOT shape. Tests compare against `{...}::VARCHAR` renderings.
- `tree_catalog.compiled` records only the `projection` artifact. `encoder`, `ingest`, `assert_p13` and `assert_o_<slot>` rows are not written.
- `tree_compile_encoder`, `tree_compile_ingest` and `tree_compile_assertions` do not exist as separate compilers: the encoder is a branch of `tree_compile_projection`, ingest is `tree_compile_insert`/`_replace`, and the P13 assertion is `tree_compile_p13` called from create, the DML compilers and `tree_compile_check`.
- `tree_explain` and `tree_compile_match` take no `language` parameter; `_match_language` is the constant `'treeql'`. The parameter arrives with the CSS front-end in M2.
- The levels fixtures §7 names (`levels_*.csv`) are an inline `walks` table in `test/sql/20_derivations.test` instead of generated CSVs.
- `coa.csv` and `ledger.csv` are committed for M2 and unused by this milestone's suite.
- The match compiler is a linear chain over `lag(alias)`, not the `WITH RECURSIVE … USING KEY` bottom-up fold of §6.1; the fold arrives with `HAS`/`NOT` in M2.
- `tree_ddl_alter` refuses outright when a materialized tree holds partitions ingested after create (C1 below), which §4 does not mention.
- An unknown attribute name in a match refuses through DuckDB's binder (the message names the column), not through a compile-time check against `_attr_map`. §6.1's "refused at compile if neither serves the name" needs the `_attr_map` type dispatch, which is M2.
- Mutant coverage: the derived parent join's `a._root = b._root` scoping is now covered by a test in `test/sql/10_projection.test` over `scripts.parquet`, but no mutant id is reserved for it (MN22–MN25 are already assigned by the handover). It is recorded as `also_kills` under MN02 in `test/mutants/manifest.yaml`; if the convention later allows a new id, that is the mutant to plant.

## 2026-09-13 final-review fix wave

- `tree_ddl_alter` on a materialized tree rebuilds the projection from `trees.source_sql` alone, so every partition added afterwards by `tree_insert`/`tree_replace` would be dropped by the `CREATE OR REPLACE TABLE`. The wave's ruling is to refuse, naming the count of partitions "ingested after create". Lifting the refusal needs per-partition ingest provenance (the source text, or at least the relation, recorded per `tree_state.partitions` row) so alter can re-derive each partition from what produced it; that is M2 work and stays an **open decision** until the partitions table carries it.

## 2026-09-13 design-phase findings (DuckDB 1.5.5)

- `query()` refuses text produced by a macro containing any subquery ("Table function cannot contain subqueries"), so a macro that reads the catalog cannot feed `query()`. Consequence: in the macro phase the runner executes compiled `tree_match` and DDL; pure string-building compilers (projection, derivations) still run through `query()`.
- Inside a recursive CTE with several `UNION ALL` branches, everything but the last branch is the base case. The recursive term must be one SELECT, and `recurring.<cte>` is legal only in FROM-clause position, never inside a correlated EXISTS.
- sitting_duck's `depth` is UINTEGER; `depth - 1` overflows. All canonical `_pre` and `_level` are cast to BIGINT.
- Derived `_parent` by ASOF join and derived `_size` by nearest-following-shallower-row match sitting_duck's native `parent_id` and `descendant_count` on every row of `app.py` (54/54).
- Partial struct casts to a custom type fill NULLs and silently drop unknown fields; the named-parameter constructors exist to catch typos.
- `MAP[...]` bracket access returns the value directly (NULL when missing); `SELECT alias FROM ...` yields the row as a STRUCT; `* REPLACE` and `* EXCLUDE` are available. The arrow lambda is deprecated in favor of `lambda x: ...`.
- Shipped `ast_select` accepts only a type, `#id`, or `.class` inside `:has(...)`; `.fn:not(:has(:docblock))` is unsupported there, so the shared corpus for M2 uses `.fn:not(:has(string))` on the sitting_duck side.
- `query()` refuses text from a macro whose body contains any SELECT, even `(SELECT 'x')` with no FROM; only pure expression macros (CASE, COALESCE, string concatenation, list functions) can feed it. `tree_compile_projection` is written that way for this reason; `tree_compile_match` and the DDL compilers read the catalog and are executed by the runner instead.
- `row_number() OVER (PARTITION BY x)` with no ORDER BY does not preserve scan order on 1.5.5; `row_number() OVER ()` does. Frozen order therefore computes `__seq` with the empty window first and orders the partitioned row_number by it.
- Inside macro bodies, struct field access must be parenthesized: `(shape).level`, not `shape.level`, or the binder may resolve it as table.column; inside lambdas an unparenthesized `p.name` was observed to yield the literal string 'p.name'.
- Declared O columns (parent, size, children, next) must be carried through the projection stages under hidden aliases (`__size_raw` etc.) because a closed or explicit ATTR list otherwise drops the source column before the stage that reads it.
- A runner-level lesson: a stub macro in a smoke test must be CREATE OR REPLACE because the real macro of the same name exists once the suite matures.
- Mutant lessons: a fragment macro can be shadowed by an earlier guard (MN17's delete predicate was already ROOT-restricted by the gone-partition computation), so the mutant had to override the whole compiler; and a mutant with no test surface survives silently (MN14 needed a multi-root match test).
