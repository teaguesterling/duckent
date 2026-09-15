# duckent core design: catalog, operations, match evaluation

*Status: approved design, 2026-09-13. Scope: the implementation architecture for M0 through M1½, plus the seams M2 onward will use. This document does not restate the ROWS contract; it says how the contract is realized. Where it names a handover rule it cites it. Baseline: handover v26, TREEQL proposal v2, Builder Delta 2.*

## 1. Decisions that frame everything

| decision | choice | why |
|---|---|---|
| deliverable | implementation architecture; the contract stays as written | the handover already fixes R, S, O, W, milestones, and mutants |
| substrate | SQL macros first, as the executable reference; C++ extension later, from the DuckDB extension template | semantics must stop moving before they are ported; macros run today on DuckDB 1.5.5 |
| surface | functional API first; grammar lowers to it later | DuckDB 1.5.5 has no runtime grammar API; DuckDB main has a preview `GrammarExtension` API (PR 24919, merged 2026-09-04) that is not in any tagged release |
| default selector language | `treeql` initially, flipped to `css` by setting before first public release — *(amended 2026-09-15: flipped at the close of M2; `tree_catalog.settings` seeds `css`)* | TREEQL needs no parser to start and mirrors the S block; CSS lands as a translation into tested semantics |
| evaluation | one compiler: selector IR to SQL text, executed by the test runner now and by a bound table function in the extension | one matcher (doctrine 1); handles TREEQL step `WHERE`; DuckDB plans the whole query |
| tests | sqllogictest `.test` files from day one | identical files run under the Python `duckdb` package now and under the extension's `unittest` binary later |

## 2. Information schema

Two schemas. Declarations are consulted by matching; state is visible to planning and DML only (handover doctrine 2). The namespace split is the module boundary.

### 2.1 `tree_catalog` (declarations)

Every tree row is identified by `(database_name, schema_name, tree_name)`. Source references are stored the same way.

| table | one row per | columns |
|---|---|---|
| `trees` | abstract or concrete tree | identity; `is_abstract`; `like_tree` (three-part name of the LIKE parent, nullable); `source_sql` (null when abstract); `basis` (`level` or `parent`); `profile` (`full` or `sibling_free`); `storage` (`materialized` or `projection`); `order_source` (`declared` or `frozen`); `has_semantic` (true iff a SEMANTIC group was declared); `description` |
| `slots` | one slot of one tree | identity; `block` (`R`, `S`, `O`); `slot` (`ROOT`, `ORDER`, `KEY`, `LEVEL`, `PARENT`, `SIBLING_ORDER`, `TYPE`, `ID`, `CLASSES`, `ATTR`, `ATTR_MAP`, `ELEMENT`, `PSEUDO_ARGS`, `SIZE`, `CHILDREN`, `NEXT`); `expression` (SQL text in row scope; list slots hold their comma-separated list text; `ATTR` holds a whole select list). The S slots (`TYPE` through `PSEUDO_ARGS`, plus `pseudo_classes`) together form the tree's `SEMANTIC` group, which may be absent |
| `pseudo_classes` | one pseudo-class binding of one tree | identity; `name`; `kind` (`expression` or `macro`, *amended 2026-09-15: a macro-bound entry stores `body` as `'macro(args)'`, from which `macro` and `args` are recovered on read-back; the `selector` kind waits for selector-bodied pseudos*); `body`; `origin` (`local`, `prefix`, `shared`); `purity` (`pure`, `volatile`, `unknown`) |
| `selector_languages` | one registered selector language | `language`; `parser` (function name: text to `TREE_SELECTOR`); `printer` (function name: `TREE_SELECTOR` to text, nullable); `bare_safe BOOLEAN` |
| `attachments` | one W1 attachment | `child_tree`, `parent_tree` (three-part names); `join_sql`. Interface only, per D-N4 |
| `compiled` | one generated artifact of one tree | identity; `artifact` (`projection`, `encoder`, `ingest`, `assert_p13`, `assert_o_<slot>`); `object_name`; `sql_text` |

Rules encoded by the schema:

- **`KEY` names the row identity a `PARENT` column refers to.** It is required for parent-basis trees, where `PARENT`, `KEY`, `ROOT`, and `SIBLING_ORDER` must be plain column names so the encoder can qualify them. Level-basis trees with a `PARENT` override refer to `ORDER` values and need no `KEY`.
- **`PARENT` is basis or override by derivation, not by flag.** If `LEVEL` is also declared, `PARENT` is the O1 override and `basis = level`; otherwise `basis = parent`. `SIZE`, `CHILDREN`, `NEXT` are O-only, so declaring them is declaring an override. No `optimize` column exists.
- **Storage is explicit.** A tree created with a source and `storage = materialized` owns a canonical table `tree_catalog."t_<schema>_<name>"`, and every tree gets a projection macro `tree_catalog."proj_<schema>_<name>"()`; forest DML applies to the table. `storage = projection` is a macro over the live source; no storage, no DML. The generated name length-prefixes the schema — `t_<len(schema)>_<schema>_<name>`, `proj_<len(schema)>_<schema>_<name>` — because no escaping of the separator is injective on its own (doubling underscores still maps `('a_','c')` and `('a','_c')` to the same `a__c`). Reading a name back is unambiguous: the number, then exactly that many characters of schema, then the separator, then the rest is the tree name. So `('a_b','c')` is `proj_3_a_b_c`, `('a','b_c')` is `proj_1_a_b_c`, `('a_','c')` is `proj_2_a__c` and `('a','_c')` is `proj_1_a__c` — never the same object.
- **Trees are ordered.** Pre-order traversal is the ground everything else stands on, so every tree has `_pre`. A level-basis tree declares `ORDER`, or, as the undesirable but supported case, is materialized from a source whose insertion order is taken as pre-order and frozen into `_pre` at ingest (`order_source = frozen`; requires `preserve_insertion_order` on at ingest, refused otherwise): the scan sequence is captured first with `row_number() OVER ()` and the per-root pre-order is numbered from it, since the partitioned form alone does not preserve scan order on 1.5.5. A projection-mode tree over a live source must declare `ORDER`; without it, create refuses and names the slot. Parent-basis sources get `_pre` from the encoder, which is always `declared`.
- **ATTR is a select list; ATTR MAP is a typed catch-all.** `ATTR ( foo + 3 AS bar, COLUMNS(* EXCLUDE (baz)) )` is legal; output column names are attribute names; attributes are typed columns of the projection. Defaults: a concrete tree defaults to `ATTR (*)`; a `SHAPE ONLY` tree defaults to `ATTR ()` and must say `ATTR (*)` to be open. `ATTR MAP <expr>` holds the long tail, and the compiler dispatches on the expression's type: `MAP(VARCHAR, V)` reads `map[name]` and compares in `V`; `JSON` reads `->> name` and casts to the literal's type; `VARIANT` reads the variant with its own type preserved; `STRUCT` reads the field. `ATTR JSON <expr>` is an explicit spelling of the JSON case. Named attributes win; the map serves undeclared names; neither yields a legible refusal naming the attribute. Output names colliding with the canonical prefix are refused at create.
- **R first, S later.** A tree is complete with R alone: `tree_shape(order := 'node_id', level := 'depth')`. The `SEMANTIC` group can be added to the catalog afterwards with `tree_ddl_alter`, or overlaid per query. Against a tree with no `SEMANTIC` group, only structural combinators and `WHERE` clauses are legal in a match; a `TYPE`, `ID`, `CLASS`, `ATTR`, or `PSEUDO` clause refuses and names the `SEMANTIC` slot. `TYPE` still defaults to `'node'` so `*` and every combinator work (MN21).
- **LIKE copies rows**, never source: `trees`, `slots`, `pseudo_classes` rows are copied under the new identity, then the new spec is merged over them.

### 2.2 `tree_state` (state)

| table | one row per | columns |
|---|---|---|
| `partitions` | one ROOT value of one materialized tree | identity; `root_key` (STRUCT of the ROOT columns); `epoch`; `row_count`; `p13_ok`; `loaded_at` |
| `assertions` | last run of one conformance assertion | identity; `artifact`; `status`; `checked_epoch`; `detail` |

### 2.3 Introspection views

`tree_catalog_trees()`, `tree_catalog_slots()`, `tree_catalog_pseudo_classes()`, `tree_catalog_assertions()`, `tree_catalog_languages()`, and `tree_catalog_classes(schema, tree)` which enumerates distinct S2 values per tree and epoch. No view enumerates pseudo-class truths: classes are data, pseudos are code (Delta 2 §4). The M4 cheatsheet is generated from these views.

## 3. Types

### 3.1 `TREE_SHAPE`

*(amended 2026-09-15, M2 build: `TREE_SEMANTIC` gained `element` and `pseudo_args`, and the
pseudo entry gained `macro` and `args`.)*

```sql
CREATE TYPE TREE_SEMANTIC AS STRUCT(
  type VARCHAR, id VARCHAR, classes VARCHAR, attr VARCHAR, attr_map VARCHAR,
  element VARCHAR, pseudo_args VARCHAR,
  pseudo STRUCT(name VARCHAR, body VARCHAR, macro VARCHAR, args VARCHAR, prefix VARCHAR)[]);
CREATE TYPE TREE_SHAPE AS STRUCT(
  root VARCHAR, "order" VARCHAR, key VARCHAR, level VARCHAR, parent VARCHAR, sibling_order VARCHAR,
  size VARCHAR, children VARCHAR, next VARCHAR,
  semantic TREE_SEMANTIC);
CREATE TYPE TREE_SPEC AS STRUCT(shape TREE_SHAPE, abstract BOOLEAN, "like" VARCHAR, source VARCHAR, storage VARCHAR);
```

`element` is a row-scope boolean expression, default true, that governs the sibling and
positional relations (D-N18; M2 design §4): rows for which it is false are invisible to `+`,
`~`, `:first-child` and `:last-child`, as text nodes are in the DOM. Containment is unaffected —
subtree and child relations count every row. `pseudo_args` is the default row-scope argument
list for macro-bound pseudo-classes, and declaring it is what opts a tree into the shared
`sel_*` tier (M2 design §7). R and O fields sit at the top level; the S block is the nested
`semantic` group and may be NULL. Every text field is SQL expression text in the source's row scope. `CAST({level: 'depth'} AS TREE_SHAPE)` fills absent fields with NULL (verified on 1.5.5). The cast silently drops unknown fields, so the recommended constructors are the macros `tree_shape(order := 'node_id', level := 'depth', semantic := tree_semantic(type := 'kind', …))` with named parameters, which refuse an unknown name at bind. The full spec passed to create is a `TREE_SPEC`, built with `tree_spec(shape, abstract := false, like := NULL, source := NULL, storage := 'materialized')`; `source` is FROM-able SQL text such as `read_parquet('test/data/app.parquet')` or a table name.

### 3.2 `TREE_SELECTOR`

The selector intermediate representation: a LIST of STRUCT `(node_id, parent_id, kind, value, op, arg, alias)`, a flattened pre-order tree. Every selector language parses to it; the TREEQL printer prints it; the compiler consumes it. Kinds:

| kind | children | meaning |
|---|---|---|
| `step` | clauses, optional groups | one TREEQL step; `op` holds the combinator relative to the previous step: `desc`, `child`, `next`, `after`, or NULL for the first step; `alias` holds the capture name |
| `type`, `id`, `class`, `pseudo` | none | S0 to S4 clauses; `value` is the operand |
| `attr` | none | `value` is the attribute name, `op` the comparison operator, `arg` the literal; compiles against the projection's attribute columns |
| `where` | none | TREEQL host predicate text in `value`; compiles against the projection alias only |
| `has`, `not` | a step chain | nested group anchored at the current node (D-N14, adopted) |
| `pseudo_unknown` | none | preserved, matches nothing, counted in provenance |

DuckDB structs cannot recurse; the flattened list is the one representation that handles nesting as a single value, compares in differentials, and is itself queryable.

## 4. Operations

Rule: every mutating operation is a pure compiler plus a thin executor. Compilers are macros returning SQL text; executors run the text and record it in `tree_catalog.compiled`. Macros cannot execute statements, so executors are the one place C++ is required; until then the test runner executes the compiled text. The same applies to `tree_match`: `query()` refuses text produced by a macro that contains any subquery (verified on 1.5.5), and the match compiler must read the catalog, so in the macro phase the runner rewrites `tree_match(...)` to the compiled query and `CALL tree_ddl_*(...)` and the DML verbs to their compiled statement lists. Tests are written against the final call shapes and do not change when the C++ executors arrive.

| family | functions | touches |
|---|---|---|
| `tree_ddl_*` | `tree_ddl_create(schema, name, spec)`, `tree_ddl_alter(schema, name, semantic := TREE_SEMANTIC)` (adds or replaces the S group and recompiles the projection), `tree_ddl_drop(schema, name)` | the catalog |
| `tree_*` data | `tree_insert(schema, name, source)`, `tree_replace(schema, name, source)`, `tree_delete(schema, name, root_predicate)`, `tree_check(schema, name)` | a tree's storage and `tree_state` |
| `tree_*` read | `tree_project(schema, name)`, `tree_apply(shape, source)`, `tree_match(sch, nm, sel, semantic := NULL, language := NULL)` (a non-NULL `semantic` overlays an S group for this query only), `tree_explain(sch, nm, sel, semantic := NULL, language := NULL) → {treeql, sql, language}` | nothing |
| `tree_*` traversal | `tree_children`, `tree_descendants`, `tree_ancestors`, `tree_next_sibling`, `tree_first_child`, each over a projection by `_pre`, `_level`, `_size`, `_parent` | nothing |
| `tree_*` derivation | `tree_encode(source, parent_expr, sibling_order)`, `tree_derive_parent(source)` | nothing |
| `tree_compile_*` | `tree_compile_projection`, `tree_compile_encoder`, `tree_compile_ingest`, `tree_compile_assertions`, `tree_compile_match` | nothing; return SQL text |
| selectors | `tree_steps(steps)` (TREEQL functional constructor), `tree_parse_selector(text, language)`, `tree_selector_to_treeql(selector)` | nothing |

Validation at `tree_ddl_create`, all bind-time, each naming the missing or offending slot: `LEVEL` or `PARENT` required; `PARENT` without `SIBLING_ORDER` records `profile = sibling_free`; abstract with a source, or concrete without one, refused; `ATTR` names colliding with the canonical prefix refused; a pseudo-class bound both locally and via prefix refused (S-coherence); `ORDER` absent on a projection-mode tree refused; `ORDER` absent on a materialized tree with `preserve_insertion_order` off refused. ROOT-absent-but-multiple-trees is not knowable at create; it surfaces as a P13 failure at ingest with the hint to declare `ROOT`.

DML semantics: `tree_insert` appends whole partitions and refuses an existing ROOT value; `tree_replace` drops matching partitions, re-ingests, bumps epoch; `tree_delete` accepts predicates over ROOT columns only; a predicate on a non-ROOT column is ill-typed (P21).

**The `language` parameter and what it is for** *(amended 2026-09-15, M2 build)*. `selector` is
either a `TREE_SELECTOR` value or selector text. `language := ` is **provenance**, not a
directive: the compiler reports `_match_language = COALESCE(language, 'treeql')` and never reads
the catalog for it. The reason is mechanical — by the time the compiler sees a selector it is
IR, so it cannot tell whether that IR was parsed from text or constructed. So an IR selector
reports `treeql` (TREEQL is the IR's own spelling; it was never parsed), and a selector reports
`css` exactly when its caller says the text was written in css. `tree_explain` returns the same
value in its `language` field beside the printed `treeql` and the compiled `sql`.

A second setting, `tree_catalog.settings.tree_default_selector_language`, governs one different
thing: which front-end parses a selector handed over as **text** with no language named. That is
the runner's job in the macro phase (`test/run.py` rewrites the text to IR before the call) and
the binder's job in the extension. It was seeded `treeql` and flipped to `css` by the last M2
task, as §1 said it would be.

**A front-end that applies the default records it** *(amended 2026-09-15, M2 build)*. The two
settings meet at exactly one point, and it is the front-end's: when it parses text that names no
language, it writes `language := '<default>'` into the call it rewrites. So a bare text selector
reports the language it was actually parsed as — `css` after M2 — while the compiler's rule is
unchanged, `COALESCE(language, 'treeql')` read off the argument and never off the catalog. A
selector handed over as `TREE_SELECTOR` still reports `treeql`: nothing parsed it, and `treeql`
is the IR's own spelling. The rule generalizes to every future front-end: whoever parses the
text names the language, because it is the only party that knows.

## 5. The projection

`tree_compile_projection(spec)` emits a table macro over the source that always produces:

| column | from |
|---|---|
| `_root` | STRUCT of the ROOT expressions, fields named after the columns when they are identifiers and `r<i>` otherwise; the constant `{r0: 0}` when ROOT is absent |
| `_pre` | ORDER expression; or the encoder; or, for `order_source = frozen`, the scan sequence captured with `row_number() OVER ()` and then numbered per root, taken once at ingest (§2.1; the partitioned form alone does not preserve scan order on 1.5.5). Cast to BIGINT, as is `_level`, since producers emit unsigned types and the derivations subtract |
| `_level` | LEVEL expression, or the encoder |
| `_parent` | PARENT expression when declared, else derived: nearest prior row at `_level − 1` within `_root` |
| `_size` | SIZE expression when declared, else derived: distance to the next row at the same or higher level within `_root` |
| `_children` | CHILDREN when declared, else `count(*)` of rows whose `_parent` is this row |
| `_next` | NEXT when declared, else `_pre + _size + 1` |
| `_type` | TYPE expression, default `'node'` |
| `_id`, `_classes` | ID and CLASSES expressions, NULL when undeclared |
| `_attr_map` | ATTR MAP expression, NULL when undeclared; access compiled by its type (MAP, JSON, VARIANT, STRUCT) |
| `_element` | ELEMENT expression made NULL-definite (`COALESCE(<expr>, false)`), `true` when undeclared *(amended 2026-09-15, M2 build; D-N18)* |
| `_pseudo` | `MAP(VARCHAR, BOOLEAN)` of every expression-bodied pseudo-class, evaluated per row |
| attribute columns | the ATTR select list, verbatim |

The O columns are present whether declared or derived, so the compiler never branches on which; the conformance assertion proves the two equal (handover O law). Derived `_size` is quadratic in the worst case; that is acceptable for the reference implementation and is exactly the tradeoff the O block names. The C++ port replaces all derivations and the P13 check with one stack walk over `(_pre, _level)` (§10).

MATCH physically cannot see a column the projection did not emit; that is the mechanical form of P14.

## 6. Match evaluation

### 6.1 Compiler

`tree_compile_match(schema, name, selector)` is a bottom-up fold over the `TREE_SELECTOR` rows whose rows are `(node_id, sql_fragment)`; each pass compiles the nodes whose children are all compiled.

*(amended 2026-09-15, M2 build.)* The fold is **unrolled to a fixed depth**, not run as a `WITH RECURSIVE … USING KEY` CTE. 1.5.5 refuses a `recurring.<cte>` reference inside a correlated subquery, and a group's `[NOT] EXISTS` is exactly that, so the recursive form cannot be written. The unrolling is total rather than approximate because the IR has its own ceiling: `tree_group_depth_limit()` = 2 group levels, stated once and enforced identically by `tree_steps`, `tree_steps_group`, the printer, and the compiler. The compiler does not trust its caller — IR can arrive hand-built or from a front-end — so it **refuses** rather than drops: a group nested past the ceiling, a group with no inner steps, and a clause hung off anything but a step each raise. All three would otherwise widen the match set silently, which is the worst way for a matcher to fail. `sql/06_selector.sql`'s printer is unrolled the same way for the same reason.

Emission per kind:

- clauses become predicates on the step's alias: `_type = v`, `_id = v`, `list_contains(_classes, v)`, `<attr> <op> <literal>` against the attribute column, else against `_attr_map` by its type (refused at compile if neither serves the name), and any S clause refused when the tree has no `SEMANTIC` group, `_pseudo[v]` (refused if undeclared and not `pseudo_unknown`), and `where` text inlined against the step alias;
- a step chain becomes a join chain over `tree_project(schema, name)` with structural predicates: `desc` as `b._root = a._root AND b._pre BETWEEN a._pre + 1 AND a._pre + a._size`; `child` as `b._parent = a._pre`; `next` as `b._parent IS NOT DISTINCT FROM a._parent AND b._pre = a._pre + a._size + 1`; `after` as `b._parent IS NOT DISTINCT FROM a._parent AND b._pre > a._pre` (the sibling comparison is NULL-blind, not NULL-definite: the level-0 rows of one partition all have a NULL `_parent` and are siblings of each other, as `tree_next_sibling` already has it). `next` and `after` are refused when `trees.profile = sibling_free`, naming `SIBLING_ORDER`;
- `has` and `not` become `EXISTS` and `NOT EXISTS` subqueries whose inner chain is anchored at the enclosing step's alias;
- the final query joins the subject step and every captured alias back to source rows on `(_root, _pre)`, emitting the subject row's columns, one STRUCT column per capture, and provenance columns `_match_tree`, `_match_language`, `_match_unknown_pseudos`.

`tree_match` is the compiled query executed: by the runner in the macro phase, by a bound table function in the extension. Column-valued selectors are out of scope for v0.

Semantics inherited from sitting_duck and adopted into the contract: attribute filters and pseudo-classes are NULL-definite, so a comparison over NULL matches nothing and its `NOT` matches the node. Unknown attribute names refuse; unknown pseudo-classes are preserved and counted.

### 6.2 Selector languages

`treeql` is the initial default and the canonical form *(amended 2026-09-15: it remains the canonical form and the IR's own spelling; `css` is the default from the close of M2 — see §4 on which of those two claims the setting actually governs)*. The functional constructor `tree_steps` and the printer `tree_selector_to_treeql` ship in M1½; the text parser ships in M-LANG. `css` ships in M2 as a translation to `TREE_SELECTOR`, parsed in the prototype through sitting_duck's tree-sitter-css output reshaped by a normalizing macro, and in the extension through embedded tree-sitter.

*(amended 2026-09-15, M2 build.)* M2 ships **two** css front-ends, not one, and binds them to each other by test. The SQL lowering (`tree_css_lower` / `tree_parse_css`) is the reference; the runner's recursive-descent parser (`test/css_parser.py`) stands in for the built-in the extension will have, and is what makes MN8 testable today. A row-level differential over 3,444 selectors found **0 divergences** — same IR, same refusal reason — and three lossy families are documented in the lowering rather than papered over:

1. a compound that follows a whitespace descendant combinator and begins with a pseudo-class or a quoted type (`a :has(x)`, `a "b"`): tree-sitter-css reads that shape as CSS property syntax. The lowering refuses; write the combinator explicitly. A `*` universal-selector rewrite could close this family and is an M-LANG item;
2. argument-less `:where` / `:is`;
3. a depth case — plus, separately, a wording-only difference on trailing junk (both refuse, at the same token, saying it differently).

Two front-ends are not a hedge: the differential is what a semantics has instead of a proof, and it is the same discipline §5 applies to the sitting_duck oracle. CSS has no host escape; a `[WHERE` token refuses with the hint "css has no host escape: mint a PSEUDO, or MATCH USING TREEQL". CSS keeps postfix `@name` captures. TREEQL step `WHERE` is the system's only host door and compiles against the projection alias only. A step `WHERE` may reference other steps' aliases explicitly; unqualified names resolve to the step's own row first (every alias is a projection of the same tree, so P14 holds on columns either way), and the row is unnested one level only so `_root` and the other canonical columns stay addressable. `$( )` is required only for language tags and quoting certainty.

The IR is the semantic anchor: a language that cannot lower a construct refuses it; no language interprets privately.

The front-ends after css are xpath, tree-sitter-query, the TREEQL text parser, and — added at the close of M2 — **cycle-free Cypher (D-N19)**: node patterns become steps, relationship types become combinators, node variables become captures, and `WHERE` becomes step `WHERE`, because Cypher is a host-door language like TREEQL rather than a closed one like css. A pattern graph with a cycle names no tree relation and is refused at lowering. All of them sit in M-LANG behind the language-registration API (D-N10); the statement of D-N19 is in the M2 design §12.

### 6.3 Captures

`(TYPE 'x') AS y` in TREEQL and `@y` in CSS name a step. Matching is a join, so a capture is a joined relation alias with statement scope, exactly like a table alias in FROM: usable in `WHERE`, `GROUP BY`, and `SELECT` after the match, and not part of the output unless selected. `SELECT *` is the subject row's columns; `SELECT *, z` adds the captured row as a STRUCT column named `z`; `WHERE baz IN y.ipsum` reads through the alias. One output row per full-pattern embedding. In the functional form, where a table function has a single output relation, `tree_match` returns the subject columns followed by one STRUCT column per alias; the grammar restores statement-scope aliasing when it arrives. Captures inside `has` or `not` refuse at parse: a negated or existential context has no row to bind.

## 7. Testing

Format: sqllogictest `.test` files, run by a small Python runner over the `duckdb` package that loads the macro files first; later run unchanged by the extension's `unittest` with `require duckent`.

Fixtures are pinned parquet or CSV under `test/data/`, generated once and committed: `app.parquet` (sitting_duck on `docs/examples/app.py`), `scripts.parquet` (sitting_duck on a pinned commit of `sitting_duck/scripts/*.py`, multi-tree, the M0 oracle fixture), `readme_blocks.parquet` (markdown on this README), `employees.csv` (parent basis with sibling key), `categories.csv` (parent basis, sibling-free), `coa.csv` and `ledger.csv`, and generated `levels_*.csv` for P13 property tests. Only the differential suite needs sitting_duck installed.

The selector corpus is one file of `(treeql, css, fixture, tags)` rows; tags are `portable`, `sitting_duck_supported`, `v0`. Every corpus row carries its TREEQL spelling from the start, so the CSS front-end's first test is the round trip.

*(amended 2026-09-15, M2 build.)* There are two corpus sources, not one: the hand-written `test/corpus/selectors.tsv` above, and `test/corpus/astcss_eval.jsonl` — 108 execution-verified css/fixture pairs imported from the astcss-eval set, each carrying a **frozen reference** (a node set and a hash) produced by sitting_duck at a pinned commit. A third fixture, `py_variety.parquet`, comes with it. The frozen references are what make the differential runnable with no extension installed, and what make it an oracle rather than a comparison: a reference is never edited, and a row we disagree with is adjudicated in `FINDINGS.md` before any test changes.

Suites by milestone:

| milestone | tests | mutants planted |
|---|---|---|
| M0 | create, LIKE, SHAPE ONLY, ATTR defaults and collisions, R-only trees and `tree_ddl_alter` adding the S group later, S-clause refusals on S-less trees, ORDER rules (declared, frozen, refused), P13 per partition on ingest, DML granularity, introspection | MN14, MN15, MN17, MN18, MN21 |
| M1 | `level → parent → level` and `parent → (order, level) → parent` identities on every fixture; sibling-free refusals | MN1, MN2, MN6 |
| M1½ | `tree_steps` semantics on `app` and `employees`; printer round trip; captures and multiplicity; step WHERE against projection only; NULL-definite semantics; unknown attr refuses | MN19 (re-scoped) |
| M2 | CSS front-end; differential versus `ast_select_from` on the `sitting_duck_supported` subset (key sets equal by `EXCEPT` both ways); second differential (`SIZE` declared versus derived); P22 normal-form equality; P23 representation swaps; unknown pseudo counted; S-coherence | MN3, MN5, MN7, MN8, MN12, MN13, MN22, MN24, MN25 |
| M3 | generated assertions per `OPTIMIZE`; corruption flagged as corruption; phantom-join benchmark on a large parse kept out of the repo (`EXPLAIN` must show no join from `not`/`has` branches for a simple selector) | MN4 |
| M4 | cheatsheet generated from views and diffed | none |
| deferred | W: MN9, MN10, MN11, MN16. Host-escape MN20 retired, number reserved. MN23 with M-LANG | listed as open in the manifest |

Mutants in a macro codebase: a mutant is a file `test/mutants/MN02_parent_same_level.sql` that `CREATE OR REPLACE`s exactly one macro; a manifest maps each mutant to the tests expected to fail; the runner passes only if at least one listed test fails. A surviving mutant is fixed by a test, never by a manifest edit.

P23 as a fixture pattern: register each S accessor twice (materialized column versus expression) and run the battery; take a pseudo, materialize it as a class at ingest, and check `:x` before equals `.x` after. Any difference is MN25.

FINDINGS.md records every oracle divergence with adjudication before any test changes. One adjudication is decided now: sitting_duck's bare-keyword prefix tier (`function` matching `function_definition`) is vocabulary, not selector semantics; the shared corpus uses exact types and `.class` aliases, and the sitting_duck shape declares `CLASSES` from `ast_type_map()`.

## 8. The syntax seam

The grammar lowers to three things that already exist: a `TREE_SHAPE` value, a `TREE_SELECTOR` value, and a `tree_ddl_*` or `tree_*` call. `CREATE TREE t (…) AS FROM …` is `tree_ddl_create`; `FROM src USING TREE s MATCH …` is `tree_apply` piped into `tree_match`; `INSERT OR REPLACE INTO t FROM …` is `tree_replace`; `MATCH USING <lang> …` selects the parser through `selector_languages`, and `bare_safe` decides whether the language may appear undelimited. Transformers under DuckDB's `GrammarExtension` API build values and emit calls; they contain no semantics. Until 2.0 the string forms of the same calls are the surface, and the surface tests are written against them.

## 9. Repository plan

This repository holds the design and, during the macro phase, the macros, fixtures, and tests. When the C++ build starts, this repository is renamed `duckent-plan` via `gh`, and a new `duckent` repository is created from the DuckDB extension template. The macro files move into the extension's `src/sql_macros/` in the sitting_duck layout, the `.test` files move unchanged, and the executors become C++ table functions. Nothing in this design depends on which repository it lives in.

## 10. What the C++ port replaces

Recursive CTEs in the macro phase are executable specifications, each with a named replacement:

| macro-phase mechanism | port |
|---|---|
| derived `_parent`, `_size`, `_children`, `_next`, and the P13 check | one O(n) stack walk over `(_pre, _level)` per root: parent is the stack entry at `level − 1`; size is known at pop; the R2 invariant is checked in passing |
| `tree_encode` recursive CTE | hash-based in-memory DFS from the adjacency list, O(n) |
| `tree_compile_match` recursive fold | a recursive function over the IR; negligible either way |
| `query()` execution of compiled text | a bound table function; lifts the literal-only restriction on selectors |
| tree-sitter-css via sitting_duck | embedded tree-sitter, which also serves tree-sitter query syntax later |

Matching itself is joins with range predicates and never was recursive.

## 11. Open decisions carried

D-N3 refuse per query (adopted). D-N4 attachment interface in core, registry above. D-N5 tri-state frontier and load callback slot in core. D-N8 O3/O4 spellings provisional. D-N9 capture residue: alias/table-name collisions. D-N10 language registration API. D-N12 no first-step keyword (adopted). D-N13 `FOLLOWING` for `~` (candidate). D-N14 nested `HAS`/`NOT` step groups in TREEQL (adopted here; to be reflected in the proposal). D-N15 clause operands as bare identifiers (`TYPE foo`) versus string literals (`TYPE 'foo'`); the proposal's examples use both. D-N16 the `ATTR` / `ATTRS` spelling; this document uses `ATTR` for the list, `ATTR MAP`, and `ATTR JSON`.

*(amended 2026-09-15, M2 build — three decisions settled or opened in M2, mirrored from the M2 design §12.)*

- **D-N17 list-space navigation — closed, against.** `EXISTS` stays. Measured (`test/spike_listspace.py`, numbers in FINDINGS): the list-space form loses by 50× to 60× on 143k rows and the gap widens with size, because DuckDB answers `EXISTS` with a semi-join that stops at the first match while list-space must materialize every node's subtree to answer about a few.
- **D-N18 element rows — adopted.** A shape-declared row-scope `element` predicate, default true, governs the sibling and positional relations only.
- **D-N19 cycle-free Cypher as a registered selector language — future, not M2.** Node patterns become steps, relationship types become combinators, node variables become captures, `WHERE` becomes step `WHERE` (Cypher is a host-door language like TREEQL, not a closed one like css); a pattern graph with a cycle names no tree relation and is refused at lowering. It sits with xpath and tree-sitter-query in M-LANG (D-N10), and is the fourth front-end the one-semantics doctrine is meant to pay for. The full statement is in the M2 design §12.

Two open items M2 leaves for M-LANG, both from the css work: the `:not` self relation's spelling in TREEQL text (the IR op is `self`), and the three lossy families of §6.2 — of which the first, the whitespace-descendant compound, could be closed by rewriting the combinator through the universal selector.

## 12. Verified during design

On DuckDB 1.5.5: partial struct cast to a custom type fills NULLs and drops unknown fields; a macro constructor with named parameters refuses unknown names; `query()` runs macro-produced text with literal arguments, including inside a parameterized table macro; a `USING KEY` recursive CTE can fold a flattened selector AST bottom-up against a projection (`function_definition:not(:has(string))` on `app.py` returned `shout`, matching shipped `ast_select`), with the constraint that the recursive term must be a single SELECT and may reference `recurring.<cte>` only in FROM-clause position — *(amended 2026-09-15: that constraint turned out to rule the form out entirely for the real compiler, because a group compiles to a correlated `[NOT] EXISTS`; see §6.1)*; `USING SAMPLE`, `TABLE src`, `COLUMNS(...) AS '\1'`, and `query_table` all behave as the syntax reference recorded. On DuckDB main at 2026-09-11: `GrammarExtension` with `GrammarChange::{AddRule, AddChoice, PrependChoice, ReplaceRule, SetTransformProcess, AddTerminalRuleOverride}`, activated by `SET active_grammar_extensions`, exists and is marked preview.
