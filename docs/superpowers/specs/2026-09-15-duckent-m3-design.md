# duckent M3 design: an honest, cheap O layer

*Status: approved design, 2026-09-15. Scope: milestone M3 as a macro prototype on DuckDB 1.5.5, on top of M2 (PR #2, merge `4bdd207`). Baseline documents: the core design (`2026-09-13-duckent-core-design.md`), the M2 design (`2026-09-14-duckent-m2-design.md`, amended to what was built), handover v21 §O and §M3. Where this document and an earlier one disagree, this document wins for M3 and the earlier one is amended at the end of the milestone.*

## 1. Decisions

| question | decision | why |
|---|---|---|
| when a declared O column is checked | at ingest, fail closed, wherever P13 runs for materialized trees; projection-mode trees on demand through `tree_check` | handover §O: a divergence is a corrupted encoding, surfaced at that severity |
| planner-side use of O, EXPLAIN benchmark | out of M3 in macros; they belong to the C++ port | the macro prototype has no planner; the compiled SQL already uses `_size` ranges and the O(1) sibling forms |
| what `_pre` holds | the dense rank of ORDER within ROOT: `row_number() OVER (PARTITION BY root ORDER BY order) - 1` | every O(1) form assumes a 0-based, gap-free position per root; ORDER may then be any orderable expression |
| what `_next` and `tree_siblings` mean | structural: the successor position `_pre + _size + 1`, and every row sharing a parent; the element-aware relations live in the fragments | cheap to verify, and what a declared NEXT must equal |
| how `_size` is derived | a level-expanded ASOF join, replacing the correlated scan | exact on every fixture, linear; 19.7 s → 0.24 s on one 143k-row root |
| one projection per query | the compiled SQL and the traversal text open with a plain `WITH __proj AS (…)`; the engine decides whether to materialize | measured: same benefit as `MATERIALIZED` on projection-mode trees, no pushdown loss on stored trees |
| the MN3 / MN4 numbering | the M2 file named MN03 becomes MN04 (its edit is MN4's claim); MN03 is re-planted as the handover states it | permanent ids must mean what the handover says they mean |

Vocabulary stays the handover's. **R0°** ROOT partitions the relation into trees; **R1** is row order, significant per partition; **R2** is the structural basis, LEVEL or PARENT. `_pre` is R1 made canonical within R0°; `_level` is R2 and M3 does not change how it is derived.

## 2. Derived structure (`sql/02_projection.sql`)

**2.1 Position.** In the level basis, `_pre := row_number() OVER (PARTITION BY <root> ORDER BY <order>) - 1`, and the declared ORDER expression is carried as a hidden `__order` column that is excluded from the projection's output. The frozen-order branch (no ORDER declared) and the parent basis already number this way and do not change. For sources whose ORDER is already dense and 0-based per root (sitting_duck's `node_id`), `_pre` equals ORDER and nothing observable changes. ORDER is no longer required to be an integer.

Example, one root with a gapped ORDER:

| ORDER | LEVEL | `_level` | `_pre` before M3 | `_pre` after M3 |
|---|---|---|---|---|
| 7 | 0 | 0 | 7 | 0 |
| 10 | 1 | 1 | 10 | 1 |
| 13 | 2 | 2 | 13 | 2 |
| 16 | 1 | 1 | 16 | 3 |

Measured on 143k rows with a gapped, offset ORDER: the window costs 0.04 s and every root starts at 0.

**2.2 Declared PARENT and NEXT are values in ORDER space.** The projection translates them to positions with one join on `__order` within the root instead of casting them. A declared NEXT that names no row (the last subtree of a partition) falls back to `_pre + _size + 1`, the handover's O4 default. SIZE and CHILDREN are counts and pass through unchanged. Measured: a declared PARENT translated through the normalization equals the derived parent on 142,650 of 142,650 rows.

**2.3 Derived `_size`.** One fragment, `tree_sql_size_join()`, replaces `tree_sql_size_expr()` in both bases:

```sql
__mx AS (SELECT _root, max(_level) AS __ml, max(_pre) AS __mp FROM __p GROUP BY _root),
__cand AS (SELECT p._root, p._pre, unnest(range(p._level, m.__ml + 1)) AS __lvl
           FROM __p p JOIN __mx m USING (_root)),
__end AS (SELECT a._root, a._pre, c._pre AS __nx
          FROM __p a ASOF JOIN __cand c ON c._root = a._root AND c.__lvl = a._level AND c._pre > a._pre),
__s AS (SELECT a.*, COALESCE(e.__nx, m.__mp + 1) - a._pre - 1 AS _size
        FROM __p a JOIN __mx m USING (_root) LEFT JOIN __end e USING (_root, _pre))
```

Each row is a candidate subtree boundary for every level at or below its own depth, so the nearest later candidate at a row's own level is the first row after its subtree. The expansion is `n × (max level − level + 1)` rows, about 8× on the fixtures; the join is linear. Measured against the declared `descendant_count`: 0 mismatches on `scripts` (14,265 rows), `py_variety` (3,272), and a 10× forest (142,650). Against the correlated scan on a single root: 0.21 s → 0.03 s at 14k rows, 19.7 s → 0.24 s at 143k.

**2.4 Derived `_children`** becomes a grouped count joined back (`count(*) … GROUP BY _root, _parent`) instead of a correlated subquery, so the conformance check and the projection share one shape.

**2.5 `_next` stays structural.** The column comment and the M2 spec's §4 say so: `_next` is the successor position, the element-aware next sibling is `tree_sql_next_sibling`, and `tree_siblings` is the structural sibling set the element-aware relations are built on.

Everything above stays inside the projection's SQL text, so `tree_compile_projection` remains a pure expression that `query()` accepts. ORDER ties are refused at ingest (§3), not here.

## 3. O conformance at ingest (`sql/04_dml.sql`, `sql/03_ddl.sql`)

**3.1 One compiler.** `tree_compile_o_conformance(shape, source_sql, label, has_root)` compiles the projection twice, as declared and with SIZE, PARENT, CHILDREN and NEXT stripped to their derived defaults, joins the two on `(_root, _pre)`, and raises on the first disagreement in `(_root, _pre)` order:

```
O conformance violated in tree main.t: SIZE disagrees with its derived default at root <key>, row <pre>: declared 8, derived 9 (a corrupted encoding, not a fast path)
```

Only declared slots are compared; a tree with no O override compiles to no statement. PARENT and NEXT are compared after the §2.2 translation. In the parent basis PARENT is R2, not an override, so only SIZE, CHILDREN and NEXT are compared there.

**3.2 ORDER ties** refuse in the same statement when ORDER is declared: `ORDER is not a traversal in tree main.t: root <key> has <n> rows with ORDER value <v>`. This keeps the handover's rule that an unpartitioned, resetting ORDER column is rejected.

**3.3 Where it runs.** Immediately after the P13 statement, for materialized trees, in `tree_compile_create`, `tree_compile_alter`, `tree_compile_insert` and `tree_compile_replace`, inside the same transaction, so a refusal rolls the statement list back. Projection-mode trees are not checked at create (their source can change afterwards); P13 still is, as today.

**3.4 On demand.** `tree_check` accepts projection-mode trees for assertions (DML still refuses them), runs P13 and conformance over the live projection, and records one row per declared slot in `tree_state.assertions`: `assert_o_size`, `assert_o_parent`, `assert_o_children`, `assert_o_next`, beside `assert_p13`.

**3.5 The module boundary.** Matching never reads `tree_state` or the O slot rows of `tree_catalog.slots`; MN03 (§6) proves it.

## 4. One projection per query (`sql/07_match.sql`, `sql/08_traversal.sql`)

**4.1** The compiled SQL opens with `WITH __proj AS (SELECT * FROM <projection macro call>)`, and the projection text the compiler passes to every fragment is `__proj`: step aliases, HAS/NOT subqueries, and element scans all read it. A per-query `semantic` overlay moves inside the CTE (`SELECT * REPLACE (…) FROM <projection macro call>`) instead of being repeated at each reference. `tree_nav` builds its `query()` text the same way.

**4.2 No forced materialization.** Observed on DuckDB 1.5.5: a CTE referenced more than once is materialized without being asked. Measured on a projection-mode `scripts` tree, three-reference selectors: 0.34 s through repeated macro references, 0.16 s with a plain CTE, 0.15 s with `MATERIALIZED`, 0.33 s with `NOT MATERIALIZED`. On a 285k-row stored tree every form costs 0.00–0.03 s, so a plain CTE neither helps nor hurts there and does not block scan pushdown.

**4.3** Nothing observable changes: output columns, captures and provenance are the same. The byte-for-byte linear SQL pin in `31_match.test` moves once, deliberately, and the MN06 copy is regenerated.

## 5. Parked M2 items closed

- **Provenance has one mechanism.** The runner's `language :=` splice (`test/run.py`) retires; the selector root-row stamp (M2, R10) is the only source of `_match_language`. The `37_css_parser.test` records on the default-language path are re-pinned against the stamp, and the Open-after-M2 bullet closes.
- **The first-root O(1) form** (`COALESCE(a._pre = a._parent + 1, a._pre = 0)`) is correct for every declared ORDER once §2.1 lands. The M2 spec's "in both forms" sentence stands, backed by a gapped-ORDER record comparing an ELEMENT tree with a plain one.
- **`_next` and `tree_siblings`**: documented per §2.5; no code.

## 6. Mutants and evidence

| id | wrong implementation | killed by |
|---|---|---|
| MN03 (re-planted) | a semantics-path function reads an O accessor: the compiler looks up whether SIZE is declared in `tree_catalog.slots` and emits a different descendant form when it is not | 42's new boundary record: for every app corpus selector, the compiled SQL for `app_declared` and `app_derived` is identical apart from the projection name and the `_match_tree` literal |
| MN04 (the M2 file formerly named MN03) | the declared SIZE path of the projection returns `size + 1` | conformance at create (11_ddl, 12_dml records that create or insert a declared-SIZE tree) and 42 |

The M2 file's rename is recorded in FINDINGS: the number MN3 was used for MN4's claim in M2, corrected here so a permanent id keeps the handover's meaning. MN01, MN02 and MN14 touch the fragments §2 rewrites and are regenerated with `test/mutants/regen.py`.

Records (all in existing suites unless named):

- a source with one corrupted `descendant_count` refuses at create and at insert, naming SIZE, the root and the row;
- a source with a corrupted `parent_id` refuses naming PARENT;
- an ORDER tie refuses; an unpartitioned resetting ORDER refuses;
- a gapped, offset ORDER tree (`node_id * 3 + 7`) returns the same `file_path:node_id` sets as its dense twin for every app corpus selector, and the same first-child and last-child totals with and without ELEMENT;
- `tree_check` on a projection-mode tree records `assert_o_*` rows;
- the derived size equals the declared one on all three fixtures (projection-level record in 42, extended to `py_variety`).

The single-root timing lives in `test/spike_listspace.py` (a new `--sizes` mode) and FINDINGS, not in a timed test.

**Harness.** `test/run_mutants.py --verify` stops re-running a full-suite baseline per control file: the green suite run already proves the baseline, so each control needs only its own `expect_fail` suites.

## 7. Well-formedness and the duck_block_utils review

A review from the duck_block_utils side (2026-09-15, all suites and mutants green on DuckDB 1.5.5 with sitting_duck loaded) found defects none of the M2 reviews did. M3 absorbs all of them, because §2 and §3 rewrite most of the code they live in. Items marked *verified* were reproduced by the reviewer against test files.

**7.1 Wrong results.**

| # | defect | rule |
|---|---|---|
| W1 | a numeric literal compared through `TRY_CAST(… AS BIGINT)` rounds: `[n=2]` matches `'1.5'` and `'2.4'` (*verified*; `tree_sql_attr_col_cmp`'s TRY_CAST arm and the ATTR MAP arm of `tree_sql_clause`) | every cast of a stored value for a numeric literal targets `DOUBLE`; `tree_sql_literal_type` keeps classifying literals, and a new `tree_sql_numeric_cast_type(arg)` returns `DOUBLE` for both integer and decimal literals and NULL otherwise |
| W2 | an empty affix value (`[a^=""]`, `$=""`, `*=""`) lowers to `LIKE '%'`-style patterns and matches every row (*verified*) | in CSS an empty affix value matches nothing; both front-ends lower it to an `attr` clause with `op = 'LIKE'` and `arg = 'NULL'`, which the clause's `COALESCE(…, false)` makes false; the printer shows `ATTR a LIKE NULL` |
| W3 | `:first-child` wrong on a gapped or offset ORDER (*verified*) | closed by §2.1 |
| W4 | a capture named `@__c` collides with the compiler's own `__c` subquery alias and turns `+` into `~` | aliases beginning `__` are reserved like `s<N>`: refused by `tree_steps`, `tree_steps_group`, both css front-ends and the compiler's `bad_alias` (`alias __c is reserved: names beginning with __ belong to the compiler`) |
| W5 | the SQL `@name` rewrite splits on `"` first, so a `"` inside a single-quoted value corrupts the text | `tree_css_capture_markers` tokenizes quoted strings with one pattern (`'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|[^'"]+`) and rewrites only the unquoted tokens |
| W6 | `b:not(:nope)` matches every `b`: the unknown pseudo-class compiles to `false` inside a NOT, which widens the step | "unknowns match nothing" holds for the whole step: a HAS or NOT group containing an unknown pseudo-class at any depth compiles to `false`, so its step matches nothing; `_match_unknown_pseudos` still counts it |

**7.2 Data loss.** Tree names that differ only in case share generated objects, because DuckDB identifiers are case-insensitive: creating `App` overwrote `app`'s table, and `tree_ddl_drop` of a tree that does not exist runs its `DROP … IF EXISTS` statements anyway, so dropping a mistyped `App` destroys `app`'s storage while `app`'s catalog rows stay (*verified*). Rules: `tree_compile_create` refuses when a tree exists whose schema and name match case-insensitively (`tree_ddl_create: tree main.App collides with existing tree main.app (names are case-insensitive)`); `tree_compile_drop` refuses a tree that does not exist, matched exactly (`tree_ddl_drop: tree main.App not found`). Identity stays case-sensitive in the catalog; uniqueness is case-insensitive.

**7.3 Well-formedness at ingest (P13 and the bases).** P13 today checks only level jumps and the first row's level. Wherever P13 runs, the following refuse, each with its own message naming the tree and root:

- a NULL or negative `_level`;
- a NULL ORDER value, or two rows of one root with the same ORDER value (§3.2), checked against the source's ORDER expression before normalization, since `row_number()` would otherwise number NULLs and ties arbitrarily;
- a partition whose first row starts above level 0: the message now says `rows start at level <n>; if the source's levels are <n>-based, declare LEVEL as '<level> - <n>'`, and keeps the ROOT hint only for the case it describes (an undeclared ROOT whose levels reset).

A ROOT partition with several level-0 rows is **not** refused. The handover allows it ("multiple roots legal — R2 permits level returning to 0"): ROOT delimits independent trees for DML and attachments, it does not require one root row. The reviewer read it as a defect; FINDINGS records the adjudication.

**7.4 The parent basis respects ROOT.** The DFS walk joins a child to its parent by key alone, so a valid forest whose keys repeat per root is refused, orphans vanish, and a duplicate key duplicates rows or never terminates (*verified*). Rules: the walk's recursive join also requires the child's ROOT to equal the walker's; before the walk, ingest refuses a key that repeats within a root (`KEY <k> appears <n> times in root <r>`) and any row the walk cannot reach from a NULL parent within its root (`<n> rows are not reachable from a root in root <r>: orphans or a cycle, e.g. key <k>`). Those two checks are emitted before any statement that evaluates the projection.

**7.5 Smaller items.** A ROOT declaration splits on every comma, so an expression containing one cannot be declared: `tree_sql_list` splits on top-level commas only, honoring one level of parentheses and quotes, and a deeper nesting refuses with a hint to project a column. Selectors that reach a raw DuckDB error instead of a duckent refusal, and inputs the two css front-ends treat differently, are found by one sweep (`test/sweep_selectors.py`, reusing the Task 9 differential generator) over `app`, and each class found gets a fix and a record.

**7.6 The harness.**

- A mutant that fails to load is counted as a kill. `test/run.py --mutant` exits `3` with `MUTANT DID NOT LOAD` when applying the overlay raises, and `run_mutants.py` counts only exit `1` with at least one `FAIL <file>:<line>` record as a kill; exit `3` fails the run.
- MN08 has no control but the summary says every kill was verified. The manifest marks it `control: manual`, and the summary reads `<k> of <n> kills verified against a control; manual: MN08`.
- A file with no assertions passes, and a `require` that cannot load returns `[]`, discarding earlier failures. `run.py` fails a file that executes no `query` and no `statement error` record; `require` is legal only before the first record; `DUCKENT_NO_SKIP=1` turns a skip into a failure (CI sets it).
- Expected error text matches by substring against DuckDB's message *including* its echoed SQL (`LINE n: …`), so `01_types.test:34` passes only because `levl` appears in the echo (*verified*). The runner compares against the message with everything from `\nLINE ` onward removed, and the one record that relied on the echo asserts the real message.
- Suite 38 compares against a frozen snapshot of the runner parser's IR, not a live parser: its header and the README say so, and suite 44 is named as the live parser differential.

**7.7 duck_block_utils.** The README's claim that duck_block_utils documents "conform by construction" is false: duck_blocks puts top-level blocks at level 1, so P13 refuses the repo's own markdown fixture, and its hint says to declare ROOT (*verified*). Rules: the README says documents conform with one declaration, `level := 'level - 1'`; its `section h2 + table` example is marked as needing a section projection duckent does not build; a new suite `45_duck_blocks.test` declares `test/data/readme_blocks.parquet` as a tree (ORDER `element_order`, LEVEL `level - 1`, TYPE `element_type`) and pins `heading + table` against a result computed independently in SQL; `test/data/FIXTURES.md` records the markdown extension version the fixture was generated with (community `2ba1321`). duckent has no notion of a block's body, so spec-1.4 metadata and value subtrees are ordinary nodes to it: recorded as **D-N22**, not built.

**7.8 Mutants.** The review's harness findings change what a kill means (§7.6) but plant no new ids. W2, W4, W6, 7.2 and 7.4 each get a record that fails under a hand-reverted fix during implementation; none is promoted to a permanent mutant id.

## 8. What M3 does not fix: compile cost

Profiled on the corpus suites (2026-09-15): a 40_corpus record spends 67–107 ms in `tree_compile_match`, 29–59 ms in the printer and 2–10 ms executing the match; a `tree_steps` literal costs 28 ms. The suites are slow because DuckDB binds very large macro expansions, not because of the derivation or the joins. The C++ port removes this cost; M3 records the numbers and does not chase them (no compiled-selector cache: it would be state consulted by matching).

## 9. Scope

**In:** §2–§7. **Out:** planner-side use of O and the EXPLAIN-shape benchmark (C++ port); attachments and loaders (W); M-LANG (TREEQL text, D-N20 parameterized pseudo-classes); compile-cost caching.

## 10. Open decisions carried

D-N9, D-N10, D-N13, D-N15, D-N16, D-N19, D-N20 unchanged. New: **D-N21** whether projection-mode trees should run conformance at create as P13 does (M3 checks them on demand only; the asymmetry is deliberate and one line to change). **D-N22** whether duckent models a block's body (duck_blocks spec-1.4 metadata and value subtrees) or leaves it to the vocabulary.
