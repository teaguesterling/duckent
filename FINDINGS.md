# FINDINGS

What first contact showed. Newest first. Every oracle divergence gets an entry with adjudication before any test changes.

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
