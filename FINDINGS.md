# FINDINGS

What first contact showed. Newest first. Every oracle divergence gets an entry with adjudication before any test changes.

## D-N17 list-space spike

`test/spike_listspace.py` (2026-09-15, DuckDB 1.5.5, one machine, best of three runs after a
warm-up). Two forms of the flagship pair `.fn:has(string)` and `.fn:not(:has(string))`: (a) what
`tree_compile_match` emits today, `[NOT] EXISTS (SELECT 1 FROM P h1 WHERE <subtree> AND …)`,
compiled through the real compiler on a tree declared exactly like the corpus trees and executed;
(b) a hand-written list-space form — `list(_pre)` of each node's subtree materialized by a
self-join and `GROUP BY`, tested with `list_has_any` against the root's list of `string` nodes.
Inputs: `scripts.parquet` (14,265 rows, 15 roots) and ten copies of it with distinct roots
(`file_path || '#' || i`; 142,650 rows, 150 roots). Both trees declare `SIZE`.

| input | selector | EXISTS | list-space | ratio | same answer |
|---|---|---|---|---|---|
| scripts | `.fn:has(string)` | 0.004 s | 0.059 s | 0.08× | yes (38 rows) |
| scripts | `.fn:not(:has(string))` | 0.004 s | 0.061 s | 0.07× | yes (1 row) |
| scripts10 | `.fn:has(string)` | 0.010 s | 0.530 s | 0.02× | yes (380 rows) |
| scripts10 | `.fn:not(:has(string))` | 0.008 s | 0.510 s | 0.02× | yes (10 rows) |

Row counts and key hashes (`md5` over the sorted `file_path:node_id` list) are equal in every
cell, so the two forms are the same query, not two different questions.

**Decision: keep `EXISTS`. D-N17 is closed against list-space.** The rule set in advance was
"adopt unless list-space wins by 3× on the larger input"; it loses by 50× to 60× there, and the
gap *widens* with size (0.08× at 14k rows, 0.02× at 143k). The reason is structural, not a
tuning detail: DuckDB turns `EXISTS` into a semi-join, which stops at the first match and
materializes nothing, while the list-space form must build every node's subtree list first —
a self-join whose output is the sum of all subtree sizes, which is O(n · depth) rows for a tree
that `EXISTS` never has to visit. The list form pays for all subtrees to answer about a few.

Two things the spike settled along the way, both worth carrying:

- **The brief's sketch of the list-space form is cross-root-unsound.** Taking the string-node
  list as `(SELECT list(_pre) FROM P WHERE _type = 'string')` is sitting_duck #130 in list form:
  `_pre` is unique only within a root, so a global list answers `:has(string)` with a string in
  another file. The measured form groups both lists by `_root`, because any honest list-space
  implementation has to.
- **Derived `_size` did not dominate these timings, and the reason matters for M3.** The
  quadratic is *within a root*, and `scripts10` multiplies the number of roots, not their size,
  so it never reaches the quadratic term:

  | input | rows | rows/root | declared SIZE | derived `_size` | ratio |
  |---|---|---|---|---|---|
  | scripts | 14,265 | ~951 | 0.045 s | 0.167 s | 3.7× |
  | scripts10 | 142,650 | ~951 | 0.306 s | 0.793 s | 2.6× |
  | scripts_deep | 142,650 | ~9,510 | 0.280 s | 3.644 s | 13.0× |

  `scripts_deep` is the same 142,650 rows under the original 15 roots (a cost probe, not a
  well-formed forest — it is never created as a tree, only its projection text is timed). Ten
  times the rows *per root* costs 4.6× the derived time while the declared time is flat. That
  is the M3 case in one line: the O(n²) derivation is invisible on a forest of small files and
  is the whole cost on one big one, which is exactly the shape a whole-repository parse has.
  No timeout guard fired; nothing had to be skipped.

## M2 differential adjudications

The corpus import (`test/import_astcss_eval.py`) runs all 108 accepted astcss-eval pairs against
their frozen references. References are never edited: where we disagree, the row is adjudicated
here, and only a row adjudicated **against** upstream loses its assertion (it is tagged
`divergent:<reason>` in `test/corpus/astcss_eval.jsonl` and `41_differential_sitting_duck.test`
emits it as a commented no-op naming the reason). 107 of 108 references are asserted and pass.

- **`lambda` on `repo-small-py` (t1-p21) — 2 rows here, 3 in the reference; the reference is
  wrong. Tagged `divergent:sd-type-prefix-match`.** The reference's extra node is
  `update_test_names.py:247`, whose `type` is `lambda_parameters`, not `lambda`. Reproduced live
  against the installed sitting_duck on the same fixture: `ast_select_from(rs, 'lambda')` returns
  3 rows, `ast_select_from(rs, 'lambda_parameters')` returns exactly that node, and the probe
  `ast_select_from(rs, 'lambd')` returns **both** types — so sitting_duck's bare type selector is
  a *prefix* match, not equality. (`with` likewise selects `with_item`, `with_statement`, `with`
  and `with_clause`; `while` selects `while` and `while_statement`.) A css type selector is
  equality on the node type — `lambda` cannot silently mean `lambda*` — so duckent's 2 rows are
  right. This is not one of the tracked issues (#127, #128, #130, #133, #134, #141); it is a new
  upstream bug, and the reason the corpus's other bare-type rows (`with_statement`,
  `while_statement`, `decorated_definition`, `continue_statement`) pass is only that no other
  type in those fixtures shares their prefix.

- **Embedding multiplicity, not a divergence: `.import ~ .class` (t3-p11, 9 rows vs 3),
  `.import ~ .fn` (t3-p22, 126 vs 27), `.fn ~ .class` (t3-p38, 6 vs 5), `.loop .call#print`
  (t3-p39, 20 vs 19).** The node *sets* are identical in all four; only the row counts differ.
  duckent's match is a join and its contract is "one output row per full-pattern embedding"
  (core design §6.3) — that is what makes a `@capture` a joinable relation alias — so a node with
  three preceding `.import` siblings is three rows here and one row in sitting_duck, which emits
  the subject set. The M2 design already specifies the sitting_duck differential as *identical
  `(file_path, node_id)` sets, checked by `EXCEPT` in both directions* (§8), so
  `41_differential_sitting_duck.test` aggregates its keys from `SELECT DISTINCT file_path,
  node_id`. That is a projection of our bag to its set, not a relaxation of the reference: the
  key list and the sha256 are still compared against the reference verbatim.

- **Scoping note for `41b_live_sitting_duck.test`: the installed sitting_duck has regressed on
  issue #127.** All 31 corpus rows whose chain has a combinator (`.loop .call`, `.mod > .fn`,
  `.import + .import`, …) return **0 rows** from today's `ast_select_from`, while their frozen
  references — captured on the `sd-20260914-1835` build, which had #127 fixed — carry 21, 26 and
  16 nodes. duckent matches the *frozen* references on all 31 (modulo the multiplicity above), so
  41 keeps them; 41b covers the 76 single-compound rows the installed engine still answers, and
  lists the skipped rows with their reason at the foot of the file. When upstream is fixed again,
  deleting the `top_level_combinator` skip in the importer and regenerating restores full live
  coverage.

## Mutant kill map corrections

The M2 design's §9 mutant table names a killing suite per mutant. Planting the nine remaining
mutants (task 12) showed six of those rows are wrong or incomplete. Every line below was
established by running `python3 test/run.py <suite> --mutant test/mutants/<file>` on the suite in
question, in both directions where a suite was expected to fail and did not. **Task 13 should
correct the spec table from this entry.** The manifest (`test/mutants/manifest.yaml`) is the live
record; this is the reasoning behind it.

| mutant | §9 says | actually killed by | why the difference |
|---|---|---|---|
| MN03 | 42 | **42 only** | 40 and 41 PASS, although both declare SIZE — see below |
| MN05 | 40/41 | **40, 41, 34_groups** | table is right; 34 is a third witness |
| MN07 | 40 | **40, 37, 31, 34, 36** | only after corpus row c17 was added; 41 PASSES |
| MN08 | 44 | **44, 37** | — |
| MN12 | 40 | **36_pseudo only** | no corpus tree declares a pseudo a `sel_*` could shadow |
| MN13 | 40 | **35_attr_map** | the `'9'` vs `'10'` row moved to 35 before this task |
| MN22 | 40 | **44_parsers** | 40 never reaches the SQL lowering |
| MN24 | 40 | **34_groups, 38_css_lower** | 40 cannot see a symmetric printer mutation |
| MN25 | 43 | **43** | only after `rep_class_none` was added; the promotion records alone cannot discriminate |

Three of these are the same lesson, and it is worth stating once: **a differential suite cannot see
a mutation that moves both of its sides.** 40_corpus compares two SPELLINGS of one selector against
each other on ONE tree.

- **MN22** (the css lowering reads `tree_state`) is invisible to 40 because 40's
  `language := 'css'` selectors are rewritten by `test/run.py`'s `rewrite_selectors`, which calls
  the RUNNER's parser (`test/css_parser.py`). No record in 40 reaches `tree_css_lower` at all. The
  suite that runs the SQL front-end is 44_parsers, which is where the bait row lives.
- **MN24** (the printer omits NOT groups) is invisible to 40 because its printed-TREEQL records
  compare `tree_selector_to_treeql(<ir>)` with `tree_explain(...).treeql` — both sides go through
  the same printer, so a symmetric mutation cancels. Only a record comparing the print against a
  FROZEN literal catches it: 34_groups and 38_css_lower have those.
- **MN03** (a declared SIZE compiles one short of a derived one) is invisible to 40 for the same
  reason — both spellings run against the same tree, so a shortened `_size` moves both key lists
  identically. It is invisible to 41 for a different reason: a range one short drops only a
  subtree's LAST descendant, and on these fixtures that row is almost always an anonymous token no
  selector can name. That is the same fact that made 42 write `SIZE_WITNESS` (`attribute
  identifier`) by hand rather than rely on the corpus. 42 is the only suite that sees MN03, and it
  sees it twice: on the record comparing the two projections column for column, and on
  SIZE_WITNESS. (This entry exists because the first version of MN03's manifest row claimed 40 and
  41 as `also_kills` without running them. They pass. F14/MN21 precedent: a manifest states what a
  mutant does, not what one hopes it does.)

Two mutants had nothing in the suite that could kill them, so the corpora gained bait, each
commented in place with the mutant it serves:

- **MN07** — no corpus row carried an unknown pseudo-class (the 108 astcss rows use only `:has` and
  `:not`). Hand-corpus row **c17**, `.fn:not(:nope)`, was added. The unknown name sits inside a
  `:not()` because a compound carrying one directly matches no row, and 40's records are written so
  that an empty match FAILS rather than passing vacuously.
- **MN25** — 43's two promotion records cannot discriminate: on `rep_class` every `def` row already
  has a non-empty CLASSES list, so a fallback that fires only on an empty one never fires. Tree
  `rep_class_none` (binds `def` as a PSEUDO, declares `classes := '[]::VARCHAR[]'`) was added, with
  a record asserting `.def` selects nothing there while `:def` still selects every def.

And one mechanism: **MN08** mutates the runner's css parser, which is Python, not a macro, so no
`CREATE OR REPLACE MACRO` override can express it. `test/mutants/manifest.yaml` rows may now carry
an optional `env:` map that `test/run_mutants.py` adds to each subprocess environment; the mutant's
SQL file is comment-only, so every mutant is still one id, one file, one row.

Two mutants are also shaped differently from the §9 table's sentence, for reasons task 13 should
carry into the spec text:

- **MN3** as §9 words it ("the compiler reads `_size` through a fragment that consults
  declared-versus-derived status") would die trivially: a fragment that reads the catalog cannot be
  spliced into `query()`, which is where the projection text goes. The planted mutant is instead a
  copy of `tree_compile_projection` whose DECLARED size branch is `CAST(a.__size_raw AS BIGINT) - 1`
  — the smallest edit that makes a declared O column diverge from its derived default.
- **MN22** is a one-fragment override of `tree_css_path` (the fragment stage 9 of the lowering calls
  for every emitted row) rather than a copy of the whole 365-line `tree_css_lower`, which §9's last
  paragraph anticipates. The state read still happens where the lowering decides where a row goes.
- **MN13** drops the typed cast by casting the LITERAL to VARCHAR rather than by removing
  `TRY_CAST` outright. Removing it outright is a *binder* error in 1.5.5 ("Cannot compare values of
  type VARCHAR and type INTEGER_LITERAL"), which would make MN13 a loud mutant that any suite
  comparing a map against a number kills. Casting the literal instead is the plausible wrong
  implementation: it binds, it runs, and it answers that `'10'` is not greater than `9`.

## Spec deviations in this milestone

Where the prototype knowingly differs from `docs/superpowers/specs/2026-09-13-duckent-core-design.md`. Each is a deviation to carry forward or close in M2, not an accident.

- `tree_state.partitions.root_key` is `VARCHAR` (the ROOT struct cast to text), not the STRUCT §2.2 describes; one column type serves every tree's ROOT shape. Tests compare against `{...}::VARCHAR` renderings.
- `tree_catalog.compiled` records only the `projection` artifact. `encoder`, `ingest`, `assert_p13` and `assert_o_<slot>` rows are not written.
- `tree_compile_encoder`, `tree_compile_ingest` and `tree_compile_assertions` do not exist as separate compilers: the encoder is a branch of `tree_compile_projection`, ingest is `tree_compile_insert`/`_replace`, and the P13 assertion is `tree_compile_p13` called from create, the DML compilers and `tree_compile_check`.
- ~~`tree_explain` and `tree_compile_match` take no `language` parameter; `_match_language` is the constant `'treeql'`.~~ Closed in M2: both take `language :=`, and `_match_language` is `COALESCE(language, 'treeql')`. The compiler does not read `tree_catalog.settings` for it -- that row governs how a front-end parses selector *text*, and a selector handed over as IR was never parsed.
- The levels fixtures §7 names (`levels_*.csv`) are an inline `walks` table in `test/sql/20_derivations.test` instead of generated CSVs.
- `coa.csv` and `ledger.csv` are committed for M2 and unused by this milestone's suite.
- ~~The match compiler is a linear chain over `lag(alias)`, not the `WITH RECURSIVE … USING KEY` bottom-up fold of §6.1.~~ Closed in M2: it is a bottom-up fold over the IR, but unrolled to `tree_group_depth_limit()` group levels rather than run as a `USING KEY` recursion — the readiness test that shape needs is a `recurring.<cte>` reference inside a correlated `NOT EXISTS`, which 1.5.5 refuses (see the design-phase findings). The number of levels is fixed by the IR's own ceiling, so the unrolling is total, and `sql/06_selector.sql`'s printer is unrolled the same way for the same reason.
- `tree_ddl_alter` refuses outright when a materialized tree holds partitions ingested after create (C1 below), which §4 does not mention.
- ~~An unknown attribute name in a match refuses through DuckDB's binder, not through a compile-time check against `_attr_map`.~~ Closed in M2: `tree_sql_clause` resolves an attribute against the `attribute_columns` artifact first, then against `ATTR MAP` with a cast implied by the comparison literal, and refuses at compile time naming the attribute when neither serves it. Note the limit of "neither serves the name": a map's keys are data, so on a tree that declares `ATTR MAP` every name is servable and an absent key reads as no match. §6.1's compile-time refusal can only ever mean "no projected column and no map".
- Coverage note (M2 task 11, `test/sql/42_second_differential.test`): a wrong SIZE or CHILDREN is all but invisible through selectors. `_children` is read by no fragment in `sql/07_match.sql` or `sql/08_traversal.sql` (it appears only in `tree_canonical_columns()`), and `_size` is read by `tree_sql_subtree` plus the O(1) sibling/positional forms — which a tree that declares ELEMENT never uses, because those fragments then scan for the nearest *element* neighbour instead. On `app.parquet` that leaves exactly one selector whose answer moves when SIZE is perturbed by one (`attribute identifier`: app.py:50 is the last descendant of its `attribute`). 42 therefore compares the declared and derived *projections* column for column as well as running the corpus selectors; a suite that only ran selectors would not have caught a broken derivation of either column.
- Mutant coverage: the derived parent join's `a._root = b._root` scoping is now covered by a test in `test/sql/10_projection.test` over `scripts.parquet`, but no mutant id is reserved for it (MN22–MN25 are already assigned by the handover). It is recorded as `also_kills` under MN02 in `test/mutants/manifest.yaml`; if the convention later allows a new id, that is the mutant to plant.

## 2026-09-14 review of PR #1

Sixteen defects, each confirmed by live reproduction before the fix and covered by a test that failed first.

- **F1 `tree_ancestors` aborted the process on a projection-mode level-basis tree.** The recursive CTE inlined the projection macro, whose derived-parent ASOF join 1.5.5 refuses inside a recursive CTE ("AsOf joins are not supported in recursive CTEs yet"), and the process then died with a corrupted heap; ancestors are now the rows whose `(_pre, _size)` range contains the node, with no recursion at all (`sql/08_traversal.sql`).
- **F2 positional `INSERT` misfiled reordered attribute columns.** `tree_insert`/`tree_replace` wrote `INSERT INTO <tbl> SELECT * FROM __duckent_new`, so a source listing the same columns in another order silently swapped same-typed values (857 of 857 rows in the covering test); both use `INSERT ... BY NAME` now (`sql/04_dml.sql`).
- **F3 the canonical-prefix guard missed implicit and quoted aliases.** The regex only sees an explicit `AS _x`, so `CAST(depth AS BIGINT) _size` walked straight through; create, alter, insert and replace now also DESCRIBE the compiled relation and refuse when DuckDB has renamed a displaced canonical duplicate to `_size_1` (`tree_sql_shadow_check` in `sql/00_types.sql`).
- **F4 generated object names collided.** `('a_b','c')` and `('a','b_c')` both compiled to `proj_a_b_c`, so the second create replaced the first's macro and either drop took out both; `tree_sql_object_name(kind, sch, nm)` length-prefixes the schema — `proj_<len(sch)>_<sch>_<nm>` — which is injective (`sql/00_types.sql`, used everywhere). Doubling the underscores, the first attempt, was not: `('a_','c')` and `('a','_c')` both double to `a__c`, and the re-review caught it.
- **F5 a NULL `abstract` or a NULL pseudo body silently dropped required statements.** Both compiled an interpolated statement to NULL, which `list_filter` then removed, leaving a catalog row with no table or a table with no catalog row; both refuse now, and the create statement list fails closed if BEGIN, the trees INSERT, the slots INSERT or COMMIT is NULL (`sql/00_types.sql`, `sql/03_ddl.sql`).
- **F6 `tree_ddl_alter` rebuilt storage from `source_sql` whatever the data had done.** Alter changes S only, so any drift between the source and `tree_state.partitions` — a root the source gained, a root whose row count changed — now refuses naming the drifted roots, alongside the existing C1 refusal, and alter emits the P13 and shadow checks create emits (`sql/03_ddl.sql`).
- **F7 `next`/`after` compared `b._parent = a._parent`.** That is NULL for every level-0 row, so the root rows of a partition were never each other's siblings; both use `IS NOT DISTINCT FROM`, as `tree_next_sibling` already did, and §6.1 of the spec now says so (`sql/07_match.sql`).
- **F8 ingest ignored the frozen-order guard.** Create refuses `order_source = 'frozen'` while `preserve_insertion_order` is off, but `tree_insert`/`tree_replace` would happily freeze an arbitrary scan order into `_pre`; they emit the same refusal now (`tree_sql_frozen_guard`, `sql/04_dml.sql`).
- **F9 a LIKE child's `has_semantic` was read off the parent's TYPE slot.** A parent declaring only ID produced a child whose every S clause refused with "has no SEMANTIC group"; the child now inherits the parent's own `has_semantic` (`sql/03_ddl.sql`).
- **F10 the `§` placeholder rewrote user text.** The clause compiler emitted `§` and the caller replaced it with the step alias, so a WHERE or an ID containing `§` was silently rewritten to `s1`; the alias is a parameter of `tree_sql_clause` now (`sql/07_match.sql`, MN19 follows).
- **F11 `tree_compile_alter` on a nonexistent tree returned NULL.** The existence check lived inside `FROM c WHERE ok`, which has no rows when the tree is missing, so the executor got nothing to run instead of a refusal; the check is evaluated outside the FROM (`sql/03_ddl.sql`).
- **F12 `tree_compile_match` returned NULL for an empty selector or an empty overlay, and ignored an overlay's ATTR.** All three refuse: "selector has no steps", "semantic overlay is empty", and a per-query overlay cannot add attribute columns (`sql/07_match.sql`).
- **F13 a user alias `s<N>` collided with the generated step aliases.** `tree_steps` refuses an `as` matching `^s[0-9]+$` (`sql/06_selector.sql`).
- **F14 MN02's manifest claim was false for `20_derivations.test`, and `tree_encode` qualified only the first sibling_order column.** `tree_derive_parent` held its own copy of the parent-join text, out of the mutant's reach; it now builds the join from `tree_sql_parent_join()` and MN02 is killed by both listed tests. `tree_encode` qualifies every sibling key column, so a second column no longer binds to the walk relation (`sql/05_derivations.sql`).
- **F15 a `semantic :=` pseudo overlay replaced the whole `_pseudo` map.** Every catalog pseudo-class was orphaned for that query; the overlay is `map_concat(_pseudo, <overlay>)`, which keeps the catalog's bindings and lets the overlay win on a shared name (`sql/07_match.sql`).
- **F16 DML verbs on an abstract tree failed with a raw catalog error.** An abstract tree records `storage = materialized` but owns no table; `tree_dml_context` refuses first, naming SHAPE ONLY (`sql/04_dml.sql`).

Deferred cleanups the review named, not addressed here:

- `tree_sql_size_expr` is O(n²) — the review measured 0.64s at 20k rows and 2.52s at 40k. The M3 replacement is a per-level ASOF form (and the C++ port's stack walk).
- Create and alter run the compiled projection more than once: once per guard plus the materialization. This wave made it worse on purpose (the shadow check and, on alter, the drift check each re-run it); the guards are cheap to fold together once a compiled artifact is materialized first and the checks run over it.
- `tree_shape_from_catalog` is called three times per LIKE create (merge, missing-check, and the S inheritance read).
- MN21's manifest also claimed `test/sql/31_match.test`, which it never failed (the R-only match test there uses WHERE clauses only, so the lost TYPE default never shows); the claim was corrected to `test/sql/11_ddl.test` alone in this wave. A manifest states what a mutant does, not what one hopes it does.

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
- A subquery anywhere inside an expression that carries a lambda is refused ("Binder Error: subqueries in lambda expressions are not supported"), and macro inlining puts an argument's text inside the lambda. So a macro whose body uses `list_transform`/`list_filter`/`list_aggregate` (`tree_sql_pseudo_map`, `tree_sql_chain`) may not be handed `(SELECT ... FROM cte)` — nor an aggregate. `tree_compile_match` therefore carries its one-row settings as CTEs joined in (`cfg`, `ovp`) and aggregates a group's inner chain into a list column one CTE before rendering it.
- Declared O columns (parent, size, children, next) must be carried through the projection stages under hidden aliases (`__size_raw` etc.) because a closed or explicit ATTR list otherwise drops the source column before the stage that reads it.
- A runner-level lesson: a stub macro in a smoke test must be CREATE OR REPLACE because the real macro of the same name exists once the suite matures.
- Mutant lessons: a fragment macro can be shadowed by an earlier guard (MN17's delete predicate was already ROOT-restricted by the gone-partition computation), so the mutant had to override the whole compiler; and a mutant with no test surface survives silently (MN14 needed a multi-root match test).
