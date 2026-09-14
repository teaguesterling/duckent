# duckent M2 design: nesting, the css front-end, and the differential

*Status: approved design, 2026-09-14. Scope: milestone M2 as a macro prototype on DuckDB 1.5.5, on top of the M0–M1½ code merged in PR #1. Baseline: the core design (`2026-09-13-duckent-core-design.md`), handover v26, TREEQL proposal v2 with D-N14 adopted, Builder Delta 2. Where this document and the core design disagree, this document wins for M2 and the core design is amended at the end of the milestone.*

## 1. Decisions that frame M2

| decision | choice | why |
|---|---|---|
| substrate | macros, same runner and harness as M0–M1½ | semantics still moving; the differential is the semantic gate and macros are the cheapest place to iterate |
| nesting | one compiler: a recursive-CTE fold over the selector IR emitting `EXISTS` / `NOT EXISTS` groups | one evaluator (doctrine 1); the linear case is the fold on a tree with no branches |
| css parsing | two front-ends to one IR: a macro lowering tree-sitter-css rows (via sitting_duck, `require`-gated) and a small Python parser in the runner standing in for the C++ built-in | MN8 becomes testable now; the runner parser has the shape the extension's parser will take |
| `ATTR MAP` | `MAP(VARCHAR, VARCHAR)` only, with literal-typed casts on comparison | one type first; typed operators route through `TRY_CAST`, so MN13 dies by correct routing rather than by refusal |
| navigation | one predicate fragment per relation, shared by the combinators, the group compiler, and the traversal macros | a mutant on one fragment reaches every surface; the reviewer's fragment discipline extended |
| list-space | a measured spike, default `EXISTS` | do not guess at performance; record the numbers in FINDINGS |

## 2. IR extension

`TREE_SELECTOR` rows are unchanged in type. Two clause kinds gain children:

| kind | parent | children | meaning |
|---|---|---|---|
| `has` | a `step` | an inner step chain (`step` nodes whose `parent_id` is the `has` node) | the step matches iff the inner chain, anchored at the step, has at least one embedding |
| `not` | a `step` | an inner step chain | the step matches iff the inner chain has no embedding |

The first inner step's `op` is its relation to the anchor (`desc` by default; `child`, `next`, `after` allowed). Inner steps may carry their own `has`/`not` clauses, so nesting is unbounded in the IR. Captures (`alias`) inside a group refuse at construction: a negated or existential context has no row to bind (spec §6.3). Group nodes carry `value = NULL`, `op = NULL`.

`tree_steps(steps)` accepts `has` and `not` fields on a step holding a nested step list. DuckDB structs cannot recurse, so the constructor's fixed cast type nests three levels (step → group → step → group → step); deeper nesting is built by composing `tree_steps` results with `tree_steps_group(kind, anchor_alias, inner_selector)`, which splices an already-built `TREE_SELECTOR` under a step. Three literal levels cover every corpus selector; composition covers the rest.

The printer renders groups inline after the step's clauses: `(TYPE 'fn', NOT ( DESCENDANT (PSEUDO 'docblock') ))` on one line per outer step, inner chains space-separated. TREEQL's canonical text for the flagship selector is therefore:

```
(CLASS 'fn', NOT ( DESCENDANT (PSEUDO 'docblock') ))
```

## 3. The compiler as a fold

`tree_compile_match` becomes a `WITH RECURSIVE m USING KEY (node_id)` fold over the IR rows, executed by the runner as today. Base case: every clause node compiles to its predicate text with the alias supplied as a parameter. Each iteration compiles every node whose children are all present in `recurring.m`:

| node | compiles to |
|---|---|
| `step` | the AND of its clause texts, `true` when empty |
| `has` / `not` | `[NOT] EXISTS (SELECT 1 FROM P h1 [JOIN P h2 ON <comb(h1, h2)> AND (<pred h2>)]… WHERE <comb(anchor, h1)> AND (<pred h1>))`, with `anchor` the enclosing step's alias and `h<i>` the inner steps' aliases |
| `selector` (root) | the final `SELECT <subject cols>, <captures>, <provenance> FROM P s1 JOIN … WHERE <pred s1>` |

Aliases are `s<node_id>` unless the user named the step; `s<N>` user aliases are already refused. Provenance gains `_match_language`. The compiled text for a linear selector is byte-identical to today's output, which is the regression test for the refactor.

## 4. Navigation fragments

New fragment macros in `sql/07_match.sql`, each returning predicate text over two aliases, and each the single definition of its relation:

| fragment | predicate |
|---|---|
| `tree_sql_subtree(a, b)` | `b._root = a._root AND b._pre BETWEEN a._pre + 1 AND a._pre + a._size` |
| `tree_sql_children(a, b)` | `b._root = a._root AND b._parent = a._pre` |
| `tree_sql_siblings(a, b)` | `b._root = a._root AND b._parent IS NOT DISTINCT FROM a._parent AND b._pre <> a._pre` |
| `tree_sql_next_sibling(a, b)` | `tree_sql_siblings(a, b) AND b._pre = a._pre + a._size + 1` |
| `tree_sql_after(a, b)` | `tree_sql_siblings(a, b) AND b._pre > a._pre` |

`tree_sql_comb` dispatches to these; the group compiler uses them for the anchor relation; `tree_descendants`, `tree_children`, `tree_next_sibling`, and a new `tree_siblings` table macro are rewritten to `SELECT b.* FROM P a, P b WHERE a.<key> AND <fragment(a, b)>`. MN14 (cross-partition) now has one fragment to mutate for every surface.

**List-space spike.** A throwaway experiment, not shipped code: materialize `list(_pre)` of each node's subtree as a column, express `:has` as `list_has_any(subtree_pres, <matching pres>)`, and time both forms on `scripts.parquet` (14,265 rows) and on one larger local parse (a sitting_duck parse of the DuckDB source tree if available, else ten concatenated copies of the fixture). The numbers go to FINDINGS; the compiler keeps `EXISTS` unless list-space wins by a factor that survives the larger input.

## 5. The css front-ends

Two parsers, one IR, one differential between them.

**5.1 The macro lowering (reference).** `tree_css_lower(rows)` takes the rows of `parse_ast_list_table(selector, 'css')` (sitting_duck's tree-sitter-css parse, columns `node_id, parent_id, depth, type, name`) and returns a `TREE_SELECTOR`. tree-sitter-css nests every postfix selector as a wrapper around the selector so far, so the lowering is a bottom-up fold that tracks, for every css node, the id of the rightmost compound in its subtree:

| css node | lowers to |
|---|---|
| `tag_name` / `identifier` at compound position | `type` clause |
| `class_selector` → `class_name` | `class` clause |
| `id_selector` → `id_name` | `id` clause |
| `attribute_selector` → `attribute_name`, operator token, `string_value`/`plain_value`/`integer_value` | `attr` clause; `=`, `^=`, `$=`, `*=` map to `=`, `LIKE 'v%'`, `LIKE '%v'`, `LIKE '%v%'` |
| `pseudo_class_selector` named `has` / `not` with `arguments` | a group whose inner chain is the lowered argument selector |
| `pseudo_class_selector` named `first-child` | `pseudo` clause `first-child`, compiled as `_pre = _parent + 1` |
| any other `pseudo_class_selector` | `pseudo` clause; unknown at match time becomes `pseudo_unknown` |
| `descendant_selector`, `child_selector`, `adjacent_sibling_selector`, `sibling_selector` | a new step with `op` `desc`, `child`, `next`, `after`; its clauses are the right operand's compound |
| postfix `@name` (tokenized before parsing) | the step's `alias` |
| `[WHERE` | refused: `css has no host escape: mint a PSEUDO, or MATCH USING TREEQL` |

It is registered in `tree_catalog.selector_languages` as `css` with `parser = 'tree_css_lower'` and `bare_safe = true`, and is exercised only under `require sitting_duck`.

**5.2 The runner parser (stand-in for the built-in).** `test/css_parser.py`: a recursive-descent parser for the v0 grammar (type, `.class`, `#id`, `[attr op value]`, compounds, the four combinators, `:not(...)`, `:has(...)` with a relative anchor allowed, `:first-child`, other pseudo-classes, postfix `@name`) producing the same `TREE_SELECTOR` rows. `test/run.py` rewrites `tree_match(sch, nm, '<css text>', language := 'css')` by parsing the literal and substituting the IR value, exactly as the C++ table function will bind. The parser is deliberately small and has its own unit test file.

**5.3 The parser differential (MN8).** For every css row of the corpus, both parsers must produce identical IR (compared as printed TREEQL and as row lists). A disagreement is a FINDING with adjudication; the corpus records which side was right.

## 6. `ATTR MAP` and typed comparison

The projection's `_attr_map` is `MAP(VARCHAR, VARCHAR)`, the declared expression cast at projection time; `NULL::MAP(VARCHAR, VARCHAR)` when undeclared. Attribute clause compilation:

1. If the attribute is a named column of the projection: `COALESCE(<alias>."name" <op> <literal>, false)` as today.
2. Else if the tree declares `ATTR MAP`: the map value is cast to the literal's type: an integer literal → `BIGINT`, a decimal → `DOUBLE`, `true`/`false` → `BOOLEAN`, a quoted literal → `VARCHAR`: `COALESCE(TRY_CAST(<alias>._attr_map['name'] AS <type>) <op> <literal>, false)`.
3. Else refuse at compile: `tree_match: attribute 'name' is neither a projected column nor served by ATTR MAP`.

Whether a name is a projected column is known at compile time from the compiled projection's column list, recorded at create in `tree_catalog.compiled` as a new `attribute_columns` artifact (a JSON list of names). MN13 becomes "a typed comparison served by string comparison" and its fixture has a map value where string and numeric order disagree (`'9'` versus `'10'`).

Before this lands, the semantic-column text of both projection branches is factored into `tree_sql_sem_cols(sem)`; the `ATTR MAP` cast is then one edit in one place.

## 7. `PSEUDO PREFIX` and shared pseudo-classes

`PSEUDO PREFIX 'sel_ast_'` records origin `prefix` in `tree_catalog.pseudo_classes` for every scalar macro in the catalog whose name starts with the prefix, body `<macro>(<row-scope args>)`; resolution order at compile is tree-local, then prefix, then the shared `sel_*` tier, then `pseudo_unknown`. A name bound in more than one tier resolves to the most local; MN12 plants the reverse. Selector-bodied pseudo-classes (a macro whose body is a css selector) are inlined into the IR at compile with a cycle check; expression-bodied ones stay in `_pseudo`.

## 8. The differential harness

`test/corpus/selectors.tsv`: columns `id`, `treeql` (a `tree_steps` literal), `css`, `fixture` (`app` or `scripts`), `tags` (space-separated: `portable`, `sitting_duck_supported`, `nested`, `sibling`, `attr`, `pseudo`). Every row has both spellings.

Suites:

| suite | requires | asserts |
|---|---|---|
| `40_corpus.test` | nothing | each row compiles and runs on its fixture in both languages, and both languages return identical key sets (P22 on results) and identical printed TREEQL (P22 on normal forms) |
| `41_differential_sitting_duck.test` | sitting_duck | for `sitting_duck_supported` rows, `tree_match` versus `ast_select_from` on `app` and `scripts` return identical `(file_path, node_id)` sets, checked by `EXCEPT` in both directions; the sitting_duck shape declares `CLASSES` from `ast_type_map()` aliases and `ID name` |
| `42_second_differential.test` | nothing | every corpus row returns identical key sets with `SIZE`/`PARENT`/`CHILDREN` declared and derived (MN3) |
| `43_representation.test` | nothing | P23: `TYPE` as a column versus an expression; one pseudo-class promoted to a class at ingest; identical key sets (MN25) |
| `44_parsers.test` | sitting_duck | MN8: both css parsers produce identical IR for every css row |

Divergences are recorded in `FINDINGS.md` with adjudication before any test changes. One is adjudicated in advance: sitting_duck's bare-keyword prefix tier (`function` matching `function_definition`) is vocabulary, not selector semantics; the corpus uses exact types and `.class` aliases only.

## 9. Mutants planted in M2

| id | wrong implementation | killed by |
|---|---|---|
| MN3 | the compiler reads `_size` through a fragment that consults declared-versus-derived status | 42 |
| MN5 | `has` compiled child-only | 40, 41 |
| MN7 | unknown pseudo-class raises | 40 |
| MN8 | the runner parser groups `a > b c` as `(a > b) c` differently from the lowering | 44 |
| MN12 | shared-tier pseudo shadows a tree-local one | 40 |
| MN13 | map comparison without the literal-typed cast | 40 (the `'9'` versus `'10'` row) |
| MN22 | the css lowering consults `tree_state` (load status) | 40 |
| MN24 | printer omits a group, so `lang → TREEQL → plan` ≠ `lang → plan` | 40 |
| MN25 | representation swap changes a match set: the promoted class compiled from the pseudo's body instead of the stored column | 43 |

Each is a one-fragment override where a fragment exists; the ones that are not (MN8, MN22) mutate the runner parser and the lowering macro respectively, by copy with one documented edit.

## 10. Operations and catalog changes

- `tree_match(sch, nm, selector, language := <default>, semantic := NULL)`: `selector` may be a `TREE_SELECTOR` (language ignored) or text (parsed by the registered language). `tree_explain` likewise, returning `{treeql, sql, language}`.
- `tree_default_selector_language` is a catalog row in a new `tree_catalog.settings(name, value)` table, `treeql` until the css front-end lands, then `css`, flipped by the last M2 task.
- `tree_catalog.compiled` gains the `attribute_columns` artifact per tree.
- `tree_catalog.pseudo_classes.origin` is populated for `prefix` bindings.

## 11. Scope

**In:** sections 2 to 10; the `tree_sql_sem_cols` refactor; the list-space spike; `tree_siblings`. **Out:** the per-level ASOF derived size and the rest of the O layer (M3); xpath and tree-sitter-query front-ends; the TREEQL text parser and language-registration API (M-LANG); attachments (W); the C++ port.

## 12. Open decisions carried

D-N9 (capture collisions; `s<N>` already refused), D-N10 (language registration API; the `selector_languages` row is its placeholder), D-N13 (`FOLLOWING` for `~`), D-N15 (bare identifiers versus string literals in TREEQL; the constructor takes strings, the css lowering emits strings), D-N16 (`ATTR` spelling; unchanged). New: **D-N17** whether list-space navigation replaces `EXISTS` (decided by the spike's numbers).
