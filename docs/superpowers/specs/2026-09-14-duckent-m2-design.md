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
| `tree_sql_after(a, b)` | `tree_sql_siblings(a, b) AND b._pre > a._pre AND b.<element>` |
| `tree_sql_next_sibling(a, b)` | `tree_sql_after(a, b) AND NOT EXISTS (a sibling c with a._pre < c._pre < b._pre AND c.<element>)`; with no element predicate this reduces to `b._pre = a._pre + a._size + 1` |
| `tree_sql_before(a, b)` | `tree_sql_siblings(a, b) AND b._pre < a._pre AND b.<element>` |
| `tree_sql_prev_sibling(a, b)` | the mirror of `tree_sql_next_sibling` |
| `tree_sql_parent(a, b)` | `b._root = a._root AND b._pre = a._parent` |
| `tree_sql_ancestors(a, b)` | `b._root = a._root AND a._pre BETWEEN b._pre + 1 AND b._pre + b._size` (the mirror of subtree) |
| `tree_sql_first_child(a)` | `a._pre = a._parent + 1` when there is no element predicate; otherwise no element sibling precedes it |
| `tree_sql_last_child(a)` | no element sibling follows it |
| `tree_sql_root(a)` | `a._level = 0` |

This is the complete set of relations the basis can express with `_pre`, `_level`, `_parent`, `_size`: containment in both directions, parenthood in both directions, and sibling order in both directions, plus the two positional predicates and the root test. CSS v0 uses subtree, children, next, after, and first-child; the reverse axes (parent, ancestors, before, prev) exist so that TREEQL's `PARENT` and `ANCESTOR` steps and xpath's reverse axes cost nothing later, and so that `tree_ancestors` shares its definition with everything else.

**Element rows (D-N18, adopted for M2).** sitting_duck issue #141 shows the trap: `identifier + identifier` never matches because the comma between them is a sibling row. In the DOM, text nodes do not count as siblings; the analogue here is a shape-declared element predicate. `TREE_SEMANTIC` gains `element` (a row-scope boolean expression, default `true`), the projection emits `_element`, and the sibling relations and the positional predicates consider element rows only. `:first-child` then means "first element child", and the sitting_duck shape declares `element := is_construct(flags)` so punctuation and keyword tokens are invisible to `+`, `~`, `:first-child` and `:last-child`, exactly as they are to `.class` already. Subtree and children relations are unaffected: containment counts every row.

`tree_sql_comb` dispatches to these; the group compiler uses them for the anchor relation; every traversal table macro (`tree_descendants`, `tree_children`, `tree_ancestors`, `tree_next_sibling`, `tree_prev_sibling`, `tree_siblings`, `tree_parent`, `tree_first_child`, `tree_last_child`) is rewritten to `SELECT b.* FROM P a, P b WHERE a.<key> AND <fragment(a, b)>`. MN14 (cross-partition) now has one fragment to mutate for every surface.

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

**Known footguns, from sitting_duck's open selector bugs and the astcss-eval findings.** Each is a corpus row or a refusal in both parsers, not a note:

| upstream | defect there | duckent's rule, and where it is tested |
|---|---|---|
| #127 | `.class` aliases ignored as combinator steps; chains of 3+ steps return nothing | the compiler treats every step alike; corpus rows with alias steps and 3-, 4-, 5-step chains on both fixtures (40) |
| #128, astcss-eval | malformed selectors silently over-match or return 0: unclosed `[`, `:nonsense(`, `>>`, trailing junk, `[WHERE` | both parsers refuse with a positioned message; the corpus has a `refusals` set every parser must reject (44) |
| #130 | child combinator joins parents across files | every fragment carries `b._root = a._root` (MN14; 40, 41) |
| #133 | inside `:has`, `.class` also matches syntax-only keyword tokens | one accessor, consulted everywhere: the sitting_duck shape declares `CLASSES` as `CASE WHEN is_syntax_only(flags) THEN [] ELSE <aliases> END`, so `:has(.fn)` cannot see a `def` token because `.fn` never does (41) |
| #134 | `.comment` is kind-level and undocumented | vocabulary, not semantics: the sitting_duck shape's alias list is generated from `ast_type_map()`, and the corpus avoids `.comment` until upstream settles it |
| #141 | `A + B` counts punctuation as siblings | element rows (§4, D-N18); corpus rows `identifier + identifier` on both fixtures (40, 41 once upstream matches) |
| astcss-eval | captures `@f` silently ignored by `ast_select` | the differential strips captures before comparing key sets; capture semantics are tested only on duckent's side (40) |
| astcss-eval | attribute filters and pseudo-classes inside `:has` refused upstream | excluded from the `sitting_duck_supported` subset; tested on duckent's side only |
| astcss-eval | an unknown `.class` silently matches nothing | correct by the data/code doctrine (classes are data), and `tree_catalog_classes` is how you learn what exists; `tree_explain` reports classes named in the selector that occur nowhere in the tree |

**5.2 The runner parser (stand-in for the built-in).** `test/css_parser.py`: a recursive-descent parser for the v0 grammar (type, `.class`, `#id`, `[attr op value]`, compounds, the four combinators, `:not(...)`, `:has(...)` with a relative anchor allowed, `:first-child`, other pseudo-classes, postfix `@name`) producing the same `TREE_SELECTOR` rows. `test/run.py` rewrites `tree_match(sch, nm, '<css text>', language := 'css')` by parsing the literal and substituting the IR value, exactly as the C++ table function will bind. The parser is deliberately small and has its own unit test file.

**5.3 The parser differential (MN8).** For every css row of the corpus, both parsers must produce identical IR (compared as printed TREEQL and as row lists). A disagreement is a FINDING with adjudication; the corpus records which side was right.

## 6. `ATTR MAP` and typed comparison

The projection's `_attr_map` is `MAP(VARCHAR, VARCHAR)`, the declared expression cast at projection time; `NULL::MAP(VARCHAR, VARCHAR)` when undeclared. Attribute clause compilation:

1. If the attribute is a named column of the projection: `COALESCE(<alias>."name" <op> <literal>, false)` as today.
2. Else if the tree declares `ATTR MAP`: the map value is cast to the literal's type: an integer literal → `BIGINT`, a decimal → `DOUBLE`, `true`/`false` → `BOOLEAN`, a quoted literal → `VARCHAR`: `COALESCE(TRY_CAST(<alias>._attr_map['name'] AS <type>) <op> <literal>, false)`.
3. Else refuse at compile: `tree_match: attribute 'name' is neither a projected column nor served by ATTR MAP`.

Whether a name is a projected column is known at compile time from the compiled projection's column list, recorded at create in `tree_catalog.compiled` as a new `attribute_columns` artifact (a JSON list of names). MN13 becomes "a typed comparison served by string comparison" and its fixture has a map value where string and numeric order disagree (`'9'` versus `'10'`).

Before this lands, the semantic-column text of both projection branches is factored into `tree_sql_sem_cols(sem)`; the `ATTR MAP` cast is then one edit in one place.

## 7. Pseudo-class bindings: expression, macro, map, and parameterized prefix

Four binding forms, all landing as rows in `tree_catalog.pseudo_classes` and all compiled into the projection's `_pseudo` map:

| form | spelling | stored as |
|---|---|---|
| expression | `pseudo := [{name: 'leaf', body: 'descendant_count = 0'}]` | `kind = expression`, `body` |
| macro | `pseudo := [{name: 'docblock', macro: 'has_docblock', args: 'file_path, node_id'}]` | `kind = macro`, `body = 'has_docblock(file_path, node_id)'` |
| map | `pseudo_map := MAP {'docblock': 'has_docblock', 'busy': 'is_busy'}` with `pseudo_args := 'file_path, node_id'` | one `macro` row per entry, all with the shared `args` |
| prefix | `pseudo := [{prefix: 'sel_ast_', args: 'file_path, node_id'}]` | one `macro` row per catalog scalar macro whose name starts with the prefix, `name` = the remainder, `origin = prefix` |

The prefix form is parameterized by its `args`: the row-scope argument list every bound macro is called with, so a library of `sel_ast_*(file_path, node_id)` macros binds in one line. `TREE_SEMANTIC.pseudo` becomes `STRUCT(name, body, macro, args, prefix)[]`; `tree_semantic(...)` gains `pseudo_map` and `pseudo_args` and flattens the map into the list. Resolution order at compile is tree-local (expression, macro, map), then prefix, then the shared `sel_*` tier, then `pseudo_unknown`; a name bound in more than one tier resolves to the most local, and MN12 plants the reverse. Selector-bodied pseudo-classes (a macro whose body is a css selector) are inlined into the IR at compile with a cycle check; all other forms stay in `_pseudo`.

## 8. The differential harness

Two corpus sources. `test/corpus/selectors.tsv` is hand-written: columns `id`, `treeql` (a `tree_steps` literal), `css`, `fixture`, `tags` (space-separated: `portable`, `sitting_duck_supported`, `nested`, `sibling`, `attr`, `pseudo`, `refusal`); every row has both spellings. `test/corpus/astcss_eval.jsonl` is imported from the Tiiny work's astcss-eval set (`~/Projects/astcss-eval/pairs/accepted-*.jsonl`, 108 execution-verified pairs over tiers 1 to 4, 98 distinct selectors) with provenance: each pair carries its css, its fixture, and a frozen reference (a node set with a hash) produced by sitting_duck at a pinned commit. Two fixtures come with it: `repo-small-py` is sitting_duck's `scripts/` directory, which `scripts.parquet` already pins, and `py-variety` is sitting_duck's `test/data/python`, added as `py_variety.parquet` at the manifest's commit. The frozen references make the sitting_duck differential runnable without sitting_duck installed: suite 41 compares against the frozen sets first and against live `ast_select_from` only under `require`. The import fills each pair's empty `treeql` twin from our lowering, which feeds back to astcss-eval as its P22 fixtures.

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

D-N9 (capture collisions; `s<N>` already refused), D-N10 (language registration API; the `selector_languages` row is its placeholder), D-N13 (`FOLLOWING` for `~`), D-N15 (bare identifiers versus string literals in TREEQL; the constructor takes strings, the css lowering emits strings), D-N16 (`ATTR` spelling; unchanged). New: **D-N17** whether list-space navigation replaces `EXISTS` (decided by the spike's numbers); **D-N18** element rows (adopted for M2: a shape-declared element predicate governs sibling and positional relations; default true). **D-N19** (future, not M2): cycle-free Cypher as a registered selector language. A `MATCH (a:fn)-[:CHILD]->(b:block) WHERE ... RETURN a, b` pattern lowers to `TREE_SELECTOR` the same way css does: node patterns become steps, relationship types become combinators (`CHILD`, `DESCENDANT`, `SIBLING`, `FOLLOWING`, and the reverse axes of §4), node variables become captures, `WHERE` becomes step `WHERE` (Cypher is a host-door language like TREEQL, not a closed one like css). Cycles are refused at lowering because a tree pattern is a path or a rooted DAG of paths, so `MATCH` graphs with a cycle name no tree relation. Sits with xpath and tree-sitter-query in M-LANG (D-N10).
