# duckent M2 design: nesting, the css front-end, and the differential

*Status: built; see FINDINGS for deviations. Designed 2026-09-14, built 2026-09-15. Scope: milestone M2 as a macro prototype on DuckDB 1.5.5, on top of the M0–M1½ code merged in PR #1. Baseline: the core design (`2026-09-13-duckent-core-design.md`), handover v26, TREEQL proposal v2 with D-N14 adopted, Builder Delta 2. Where this document and the core design disagree, this document wins for M2; the core design was amended at the end of the milestone and carries the same amendments.*

*Paragraphs marked "(amended 2026-09-15, M2 build)" record what the build decided where it differed from the design. Nothing here is a plan any more: every row of every table below either shipped or is named as carried.*

## 1. Decisions that frame M2

| decision | choice | why |
|---|---|---|
| substrate | macros, same runner and harness as M0–M1½ | semantics still moving; the differential is the semantic gate and macros are the cheapest place to iterate |
| nesting | one compiler: a bottom-up fold over the selector IR emitting `EXISTS` / `NOT EXISTS` groups — *(amended 2026-09-15: unrolled to a fixed depth, not a recursive CTE; §3 says why 1.5.5 leaves no choice)* | one evaluator (doctrine 1); the linear case is the fold on a tree with no branches |
| css parsing | two front-ends to one IR: a macro lowering tree-sitter-css rows (via sitting_duck, `require`-gated) and a small Python parser in the runner standing in for the C++ built-in | MN8 becomes testable now; the runner parser has the shape the extension's parser will take |
| `ATTR MAP` | `MAP(VARCHAR, VARCHAR)` only, with literal-typed casts on comparison | one type first; typed operators route through `TRY_CAST`, so MN13 dies by correct routing rather than by refusal |
| navigation | one predicate fragment per relation, shared by the combinators, the group compiler, and the traversal macros | a mutant on one fragment reaches every surface; the reviewer's fragment discipline extended |
| list-space | a measured spike, default `EXISTS` — *(amended 2026-09-15: measured, `EXISTS` kept, D-N17 closed)* | do not guess at performance; record the numbers in FINDINGS |

## 2. IR extension

`TREE_SELECTOR` rows are unchanged in type. Two clause kinds gain children:

| kind | parent | children | meaning |
|---|---|---|---|
| `has` | a `step` | an inner step chain (`step` nodes whose `parent_id` is the `has` node) | the step matches iff the inner chain, anchored at the step, has at least one embedding |
| `not` | a `step` | an inner step chain | the step matches iff the inner chain has no embedding |

The first inner step's `op` is its relation to the anchor (`desc` by default; `child`, `next`, `after` allowed). Inner steps may carry their own `has`/`not` clauses, so nesting is unbounded in the IR's *type* — though not in what the constructors will build; see the ceiling below. Captures (`alias`) inside a group refuse at construction: a negated or existential context has no row to bind (spec §6.3). Group nodes carry `value = NULL`, `op = NULL`.

**A fifth op: `self`** *(amended 2026-09-15, M2 build)*. css `:not(C)` negates a compound **on the subject row itself**, and the IR as designed had no way to say that — every group's inner chain was anchored by a descendant relation, which is wrong for `:not(.x)` and wrong for `:not(:has(S))` when `S` is a direct child (the descendant-anchored NOT finds no intermediate row and the negation silently passes). `self` is that relation: same root, same `_pre`, compiled by the fragment `tree_sql_self(a, b)`, dispatched by `tree_sql_comb`, printed as the keyword `SELF`. It is legal **only** as the `op` of a group's first inner step, and `tree_steps` / `tree_steps_group` refuse it anywhere else.

The name is XPath's. `self` is XPath's `self` axis (`.`) — the context node itself — and duckent's ops and navigation fragments are that axis family: `DESCENDANT`, `CHILD`, `SIBLING`/`FOLLOWING`, and the `parent`, `ancestor` and preceding fragments of §4. So an xpath front-end maps `self::` onto it directly, with nothing to invent; css's word for the same row is "subject". It is a traversal axis, not a host-language keyword borrowed for the occasion.

**Node ids are depth-first document order** *(amended 2026-09-15, M2 build)*: a group node is immediately followed by its whole inner chain, so reading the flattened list top to bottom reads the selector left to right. The first construction pass numbered breadth-first, which made an inner chain's rows sort away from the group they belong to.

**What refuses at construction** *(amended 2026-09-15, M2 build)*: an empty group, a fourth nesting level, an unknown group kind, and the capture-inside-a-group above. Each refuses in all three places that can meet it — `tree_steps` / `tree_steps_group`, the printer, and the compiler — because each would otherwise be *dropped*, and a dropped group matches more than it should. The ceiling is stated once, as `tree_group_depth_limit()` = 2 (three literal step levels), and the three refusals quote it identically.

`tree_steps(steps)` accepts `has` and `not` fields on a step holding a nested step list. DuckDB structs cannot recurse, so the constructor's fixed cast type nests three levels (step → group → step → group → step); deeper nesting is built by composing `tree_steps` results with `tree_steps_group(kind, anchor_alias, inner_selector)`, which splices an already-built `TREE_SELECTOR` under a step. Three literal levels cover every corpus selector; composition covers the rest.

The printer renders groups inline after the step's clauses: `(TYPE 'fn', NOT ( DESCENDANT (PSEUDO 'docblock') ))` on one line per outer step, inner chains space-separated. TREEQL's canonical text for the flagship selector is therefore:

```
(CLASS 'fn', NOT ( DESCENDANT (PSEUDO 'docblock') ))
```

## 3. The compiler as a fold

`tree_compile_match` becomes a bottom-up fold over the IR rows, executed by the runner as today. Base case: every clause node compiles to its predicate text with the alias supplied as a parameter. Each pass compiles every node whose children are all compiled:

*(amended 2026-09-15, M2 build.)* The fold is written as a **fixed number of unrolled passes**, not as `WITH RECURSIVE m USING KEY (node_id)`. 1.5.5 refuses a `recurring.<cte>` reference inside a correlated subquery, and a group compiles to exactly that (`[NOT] EXISTS (...)`), so the recursive spelling cannot be written at all. The unrolling is total, not an approximation: the IR's own ceiling is `tree_group_depth_limit()` = 2 group levels, so two passes plus the root reach every node, and anything deeper is refused before the fold runs. The printer in `sql/06_selector.sql` is unrolled the same way — a level-parameterized pass hit an `INTERNAL Error: Failed to bind column reference: inequal types (INTEGER != BIGINT)` when chained in 1.5.5.

| node | compiles to |
|---|---|
| `step` | the AND of its clause texts, `true` when empty |
| `has` / `not` | `[NOT] EXISTS (SELECT 1 FROM P h1 [JOIN P h2 ON <comb(h1, h2)> AND (<pred h2>)]… WHERE <comb(anchor, h1)> AND (<pred h1>))`, with `anchor` the enclosing step's alias and `h<i>` the inner steps' aliases |
| `selector` (root) | the final `SELECT <subject cols>, <captures>, <provenance> FROM P s1 JOIN … WHERE <pred s1>` |

Aliases are `s<node_id>` unless the user named the step; `s<N>` user aliases are refused *(amended 2026-09-15, final fix wave: by `tree_steps`, by both css front-ends, and by `tree_compile_match` itself — see §12 on why "already" was not true of the css ones)* — and so, in the same four places, is an alias that is not a SQL identifier at all, since an alias becomes a relation alias and an output column name *(added 2026-09-15, PR #2 fix wave: `@my-cap` passed every producer and died in the binder)*. Provenance gains `_match_language`, whose value is the caller's `language :=` or the language the front-end stamped on the IR's root row (core design §4). The compiled text for a linear selector is byte-identical to today's output, which is the regression test for the refactor.

## 4. Navigation fragments

New fragment macros in `sql/07_match.sql`, each returning predicate text over two aliases, and each the single definition of its relation:

| fragment | predicate |
|---|---|
| `tree_sql_subtree(a, b)` | `b._root = a._root AND b._pre BETWEEN a._pre + 1 AND a._pre + a._size` |
| `tree_sql_children(a, b)` | `b._root = a._root AND b._parent = a._pre` |
| `tree_sql_siblings(a, b)` | `b._root = a._root AND b._parent IS NOT DISTINCT FROM a._parent AND b._pre <> a._pre` |
| `tree_sql_after(a, b)` | `tree_sql_siblings(a, b) AND b._pre > a._pre AND b.<element>` |
| `tree_sql_next_sibling(a, b, p, elem)` | `tree_sql_after(a, b) AND NOT EXISTS (a sibling c with a._pre < c._pre < b._pre AND c.<element>)`; with no element predicate this reduces to `b._pre = a._pre + a._size + 1` |
| `tree_sql_before(a, b)` | `tree_sql_siblings(a, b) AND b._pre < a._pre AND b.<element>` |
| `tree_sql_prev_sibling(a, b, p, elem)` | the mirror of `tree_sql_next_sibling` |
| `tree_sql_parent(a, b)` | `b._root = a._root AND b._pre = a._parent` |
| `tree_sql_ancestors(a, b)` | `b._root = a._root AND a._pre BETWEEN b._pre + 1 AND b._pre + b._size` (the mirror of subtree) |
| `tree_sql_self(a, b)` | `b._root = a._root AND b._pre = a._pre` *(added 2026-09-15, M2 build; §2)* |
| `tree_sql_first_child(a, p, elem)` | `a._pre = a._parent + 1` when there is no element predicate; otherwise no element sibling precedes it |
| `tree_sql_last_child(a, p, elem)` | no element sibling follows it |
| `tree_sql_is_root(a)` | `a._level = 0` |

*(amended 2026-09-15, M2 build — the signatures above as built.)*

- **`tree_sql_root(a)` is named `tree_sql_is_root(a)`.** `tree_sql_root(root_csv, qual)` already existed, and in 1.5.5 `CREATE OR REPLACE MACRO` with a different arity **drops the other overload** rather than adding to it: the one-argument spelling would have silently unbound every projection compile. The name is the whole fix.
- **`tree_sql_comb(op, a, b, p, elem)`** and **`tree_sql_clause(kind, value, op, arg, alias, attr_cols, has_map, p, elem)`**. Both were widened by `p` (the projection relation text) and `elem` (the tree's ELEMENT flag) so that `first-child` and `last-child` compile *through the fragments* rather than being spelled out a second time in the clause compiler. That is the fragment discipline: a tree that declares ELEMENT gets the first *element* child from the same definition `tree_first_child` uses.
- **`tree_sql_chain(p, steps, anchor, elem)`** renders one step chain as FROM text; **`tree_sql_group(kind, p, steps, anchor, elem)`** wraps it in `[NOT] EXISTS`. The group renderer exists because the two group kinds differed by one keyword and had been written twice.
- **The traversal macros pass `elem := true` unconditionally.** That is always *correct* — it selects the element-aware form, which degenerates to the O(1) form on a tree whose every row is an element. Only the compiler consults its `has_element` flag, and only to pick the cheaper spelling when it is safe. Cost, never results.
- **Built-in pseudo-classes: `first-child`, `last-child`.** They are structural, so every tree has them whatever its SEMANTIC group binds, they are listed once in `tree_builtin_pseudos()`, and they are never reported as unknown. *(amended 2026-09-15, PR #2 fix wave — three consequences of "structural" that had not been drawn. They read no S slot, so the S-less refusal does **not** cover them: they work on an R-only tree. They mean nothing where siblings have no order, so the **sibling-free** refusal **does** cover them, and its sentence now reads "SIBLING, FOLLOWING, `:first-child` and `:last-child` are unavailable". And `tree_builtin_pseudos()` is consulted rather than re-listed: `tree_sql_builtin_pseudo(name, alias, p, elem)` returns the predicate or NULL, so the list and the dispatch cannot fall out of step.)*
- **A partition's first root is a first child, in both forms** *(amended 2026-09-15, PR #2 fix wave)*. The O(1) spelling was `a._pre = a._parent + 1`, which is NULL — and so false — on a level-0 row, while the element-aware scan called that row a first child (no earlier level-0 sibling; `tree_sql_siblings` relates level-0 rows through `IS NOT DISTINCT FROM`, deliberately). Two spellings of one relation disagreeing is the thing the fragment discipline exists to prevent, so the O(1) form is now `COALESCE(a._pre = a._parent + 1, a._pre = 0)`. `last-child` needed nothing — its O(1) form is the scan with the element conjunct dropped — and `33_navigation.test` pins both against a tree declaring `element := 'true'`, where the two spellings must answer identically.

This is the complete set of relations the basis can express with `_pre`, `_level`, `_parent`, `_size`: containment in both directions, parenthood in both directions, and sibling order in both directions, plus the two positional predicates and the root test. CSS v0 uses subtree, children, next, after, and first-child; the reverse axes (parent, ancestors, before, prev) exist so that TREEQL's `PARENT` and `ANCESTOR` steps and xpath's reverse axes cost nothing later, and so that `tree_ancestors` shares its definition with everything else.

**Element rows (D-N18, adopted for M2).** sitting_duck issue #141 shows the trap: `identifier + identifier` never matches because the comma between them is a sibling row. In the DOM, text nodes do not count as siblings; the analogue here is a shape-declared element predicate. `TREE_SEMANTIC` gains `element` (a row-scope boolean expression, default `true`), the projection emits `_element`, and the sibling relations and the positional predicates consider element rows only — *(amended 2026-09-15, M2 build, naming the one exception as built)* **with `tree_siblings` / `tree_sql_siblings` excluded: "siblings" is every row sharing a parent, element or not, and it is the shared base the element-aware relations are built on.** `after`, `before`, `next`, `prev`, `first-child` and `last-child` each add the `_element` conjunct themselves, so they are element-aware; asking for the sibling SET is asking a structural question and gets a structural answer. The inconsistency that leaves — `tree_siblings` unfiltered beside `tree_next_sibling` filtered — is recorded in FINDINGS under "Open after M2" and pinned by a record in `test/sql/33_navigation.test`, so a decision to change it has to change that record first. `:first-child` then means "first element child", and the sitting_duck shape declares `element := is_construct(flags)` so punctuation and keyword tokens are invisible to `+`, `~`, `:first-child` and `:last-child`, exactly as they are to `.class` already. Subtree and children relations are unaffected: containment counts every row.

`tree_sql_comb` dispatches to these; the group compiler uses them for the anchor relation; every traversal table macro (`tree_descendants`, `tree_children`, `tree_ancestors`, `tree_next_sibling`, `tree_prev_sibling`, `tree_siblings`, `tree_parent`, `tree_first_child`, `tree_last_child`) is rewritten to `SELECT b.* FROM P a, P b WHERE a.<key> AND <fragment(a, b)>`. MN14 (cross-partition) now has one fragment to mutate for every surface. *(amended 2026-09-15, PR #2 fix wave: both anchors are COALESCEd to the literal word `NULL` before they reach `query()`, which refuses a NULL argument outright — a NULL root key raised a parser error where the empty answer M1 gave was owed. And `pre` is cast through DOUBLE, not BIGINT, which **rounded**: `5.7` became 6 and the traversal answered about an anchor the caller never named.)*

**List-space spike.** A throwaway experiment, not shipped code: materialize `list(_pre)` of each node's subtree as a column, express `:has` as `list_has_any(subtree_pres, <matching pres>)`, and time both forms on `scripts.parquet` (14,265 rows) and on a larger input. *(amended 2026-09-15, M2 build.)* Run as `test/spike_listspace.py`; the larger input is ten copies of the fixture with distinct roots (142,650 rows, 150 roots). **`EXISTS` wins and D-N17 is closed against list-space**: it is better than 10× faster at 14k rows and 50–60× faster at 143k, and the gap widens with size because `EXISTS` plans as a semi-join that stops at the first match while list-space must materialize every node's subtree to answer about a few. Full numbers in FINDINGS under "D-N17 list-space spike", including the derived-versus-declared `SIZE` measurement the spike carried along, which is the M3 motivation.

## 5. The css front-ends

Two parsers, one IR, one differential between them.

**5.1 The macro lowering (reference).** `tree_css_lower(rows)` takes the rows of `parse_ast_list_table(selector, 'css')` (sitting_duck's tree-sitter-css parse, columns `node_id, parent_id, depth, type, name`) and returns a `TREE_SELECTOR`. tree-sitter-css nests every postfix selector as a wrapper around the selector so far, so the lowering is a bottom-up fold that tracks, for every css node, the id of the rightmost compound in its subtree:

| css node | lowers to |
|---|---|
| `tag_name` / `identifier` at compound position | `type` clause |
| `class_selector` → `class_name` | `class` clause |
| `id_selector` → `id_name` | `id` clause |
| `attribute_selector` → `attribute_name`, operator token, `string_value`/`plain_value`/`integer_value` | `attr` clause; `=`, `^=`, `$=`, `*=` map to `=`, `LIKE 'v%'`, `LIKE '%v'`, `LIKE '%v%'` *(amended 2026-09-15, PR #2 fix wave: the three affix forms **escape** `\`, `%` and `_` in the value and emit the pattern with `ESCAPE '\'`, carried inside the clause's `arg` since a clause is spliced as `<op> <arg>`. They say "these characters"; unescaped, `[name$="_t"]` asked for any character followed by `t`. Both front-ends, or it is a divergence. A number is `-?\d+(\.\d+)?` and no more: an exponent is refused in both, because the two front-ends tokenize `1e3` differently and would otherwise accept two selectors under one text)* |
| `pseudo_class_selector` named `has` / `not` with `arguments` | a group whose inner chain is the lowered argument selector (see the group table below) |
| `pseudo_class_selector` named `first-child` | `pseudo` clause `first-child`, compiled through `tree_sql_first_child` *(amended 2026-09-15: not `_pre = _parent + 1`, which is wrong on a tree that declares ELEMENT)* |
| any other `pseudo_class_selector` | `pseudo` clause; unknown at match time becomes `pseudo_unknown` |
| `descendant_selector`, `child_selector`, `adjacent_sibling_selector`, `sibling_selector` | a new step with `op` `desc`, `child`, `next`, `after`; its clauses are the right operand's compound |
| postfix `@name` (tokenized before parsing) | the step's `alias` |
| `[WHERE` | refused: `css has no host escape: mint a PSEUDO, or MATCH USING TREEQL` |

It is registered in `tree_catalog.selector_languages` as `css` with `parser = 'tree_css_lower'` and `bare_safe = true`, and is exercised only under `require sitting_duck`.

**How the groups lower** *(amended 2026-09-15, M2 build — the design's single "anchored at the current node" rule was wrong for `:not`, which negates the subject row itself; §2 adds the `self` op that makes this expressible).*

| css | lowers to |
|---|---|
| `:has(R)` | `HAS(R)` anchored by R's leading combinator, or `DESCENDANT` when it has none |
| `:not(C)`, C a compound | `NOT(SELF C)` |
| `:not(:has(R))` alone in the compound | collapses to `NOT(R)` — which is why the flagship's canonical TREEQL text is unchanged |
| `:not(<anything with a combinator>)` | refused: `:not() takes a compound selector in v0` |
| `:nth-child(...)` and every other parenthesized pseudo-class | refused in v0 |

**Clause order within a compound** is fixed — type, id, class, attr, pseudo, then groups in written order — so that the two front-ends print a compound identically whatever order it was written in. That is what makes the printed-TREEQL half of the P22 comparison meaningful.

**Captures for the SQL lowering** are pre-rewritten: `@name` is not css, so tree-sitter-css cannot see it. It is rewritten to a `:__cap_name` pseudo-class marker before parsing and recovered as the step's `alias` afterwards.

**Three lossy families**, found by the row-level differential against the runner parser and accepted for M2 rather than hidden. The differential runs 3,444 selectors and finds **0 row divergences and 0 refusal-reason divergences**; what it does find is 147 selectors the lowering refuses and the runner parser accepts, and they fall entirely into these families:

1. a compound that follows a **whitespace** descendant combinator and begins with a pseudo-class or a quoted type (`a :has(x)`, `a "b"`) — tree-sitter-css reads that shape as CSS property syntax. The lowering refuses and its message names the fix: write the combinator explicitly. 144 of the 147. No corpus selector has this shape (checked). A `*` universal-selector rewrite could close the family; it is an M-LANG item.
2. argument-less `:where` / `:is`: 2 of the 147.
3. one depth case: the last of the 147.

Separately, and not a divergence in result: two inputs of trailing junk where both front-ends refuse, at the same token, in different words. tree-sitter reports junk as a second child of the container without saying where it starts, so the lowering names the situation (`unexpected text after the selector`) where the runner names the character.

`tree_parse_css` reaches sitting_duck's `parse_ast_list_table` through core `query()`, because 1.5.5 binds table- and scalar-function **names** at `CREATE MACRO` time; the consequence for callers is that the selector argument must be constant-foldable.

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
| astcss-eval | an unknown `.class` silently matches nothing | correct by the data/code doctrine (classes are data), and `tree_catalog_classes` is how you learn what exists *(amended 2026-09-15, M2 build: the original row also claimed `tree_explain` reports classes named in the selector that occur nowhere in the tree. It does not — `tree_explain` returns `{treeql, sql, language}` and nothing else. Reporting them is an M-LANG item, not a shipped behaviour)* |

*(added 2026-09-15, PR #2 fix wave: nine more, from the sitting_duck issues opened since the table was written. Every one of them is a place where duckent's answer comes out of a declaration rather than out of engine behaviour, which is the whole reason the table exists.)*

| upstream | defect there | duckent's rule, and where it is tested |
|---|---|---|
| #139 | a `.class` selector matches sub-nodes of the construct it names, and misses the construct itself | duckent's `CLASSES` is **declared data**, so the question is what the declaration says, not what an engine decides. Our fixtures' `css_classes` column was generated from sitting_duck at fixture time and reproduces its alias test — so the corpus rows that use `.import` (t1-p06, t3-p10, t3-p11, t3-p22) **inherit #139's sub-node semantics by construction**, and their references agree with us for that reason and not because the semantics are right. Noted in the FINDINGS adjudications so a fixture regenerated against a fixed upstream is read as a change, not a break (40, 41) |
| #145 | `:scope(S)` | an engine builtin with prose semantics. In duckent a pseudo-class is a **declared row-scope binding** (`PSEUDO`), tested by P23 in 43 — the tree says what `:name` means. An argument-taking form is **D-N20** (§12); v0 refuses it |
| #146 | `:calls(name)` | same: a declared binding, and the argument-taking form is D-N20. v0 refuses `:calls('print')` in both front-ends (`:calls() is not supported in v0`) |
| #147 | `:is-referenced` | a declared binding like any other; nothing engine-side decides it (36, 43) |
| #148 | `:exported` | likewise. The four together are why §7's binding forms exist: the engine ships no vocabulary of its own beyond `:first-child` / `:last-child`, which are structural |
| #149 | `[receiver=X]` collapses chained receivers, so `a.b.c()` answers to `receiver=a` | attribute semantics belong to the **projection**, not the selector: whatever a `receiver` column or `ATTR MAP` key holds is what `[receiver=X]` compares against, and the shape's author decides what that is. duckent mints no attribute of its own (§6; 35) |
| #150 | attribute filters inside `:has` refused upstream | duckent lowers them like any other clause — a group's inner chain is a chain, and its steps take the clauses every step takes. Parity record `a:has(> x[n=1])` in 38, and hand corpus row **c18** (`.fn:has(> block[params=0])`) in 40/44. Not in the `sitting_duck_supported` subset, so 41/41b do not compare it |
| #131 | operator classes assigned by token text | vocabulary, not semantics, and the corpus does not use them: `CLASSES` is declared, so an operator class exists here exactly when a shape declares one |
| #140 | names do not bind for Bash, Go or Java | `ID` is a **declaration** (`semantic := tree_semantic(id := ...)`), so a shape for those languages declares whatever column names its nodes; our fixtures are Python, where upstream binds, so no corpus row is affected and nothing here is inherited from the bug |
| #151 | a bare type selector is a **prefix** match, so `lambda` also selects `lambda_parameters` | a css type selector is equality on the node type; `lambda` cannot silently mean `lambda*`. Found by the M2 corpus differential (t1-p21: 2 rows here, 3 in the frozen reference), reproduced live, adjudicated against upstream in FINDINGS and filed as sitting_duck #151. Tagged `divergent:sd-type-prefix-match`, which is the one row of 108 whose reference assertion is commented out (41) |
| #117 | dynamic attribute allowlist and a published `SEMANTIC_TYPE` | converges with what M2 already records: `attribute_columns` (§10, now `[{name, type}]`) is duckent's allowlist, published in `tree_catalog.compiled` and read by the clause compiler, and `css_classes` is the published vocabulary. The difference is where it lives — in the catalog, per tree, rather than in the engine |

**5.2 The runner parser (stand-in for the built-in).** `test/css_parser.py`: a recursive-descent parser for the v0 grammar (type, `.class`, `#id`, `[attr op value]`, compounds, the four combinators, `:not(...)`, `:has(...)` with a relative anchor allowed, `:first-child`, other pseudo-classes, postfix `@name`) producing the same `TREE_SELECTOR` rows. The parser is deliberately small and has its own unit test file.

*(amended 2026-09-15, M2 build — what the runner actually does.)* `test/run.py` rewrites
`tree_match(sch, nm, '<text>'[, language := '<lang>'])` by parsing the text literal and
substituting the IR value, exactly as the C++ table function will bind. A call that names **no**
language is not an error: the runner reads
`tree_catalog.settings.tree_default_selector_language` — `css` from the close of M2 — parses with
that front-end, **and writes `language := '<the default>'` back into the call it rewrites**, so
the match reports the language its text was actually parsed as. A call that names its language
keeps the one it named, and `language := 'treeql'` still refuses until M-LANG, which is why the
one record that asks for TREEQL text has to name it. A selector handed over as `TREE_SELECTOR` is
not text and is not touched.

**5.3 The parser differential (MN8).** For every css row of the corpus, both parsers must produce identical IR (compared as printed TREEQL and as row lists). A disagreement is a FINDING with adjudication; the corpus records which side was right.

## 6. `ATTR MAP` and typed comparison

The projection's `_attr_map` is `MAP(VARCHAR, VARCHAR)`, the declared expression cast at projection time; `NULL::MAP(VARCHAR, VARCHAR)` when undeclared. Attribute clause compilation:

1. If the attribute is a named column of the projection: `COALESCE(<alias>."name" <op> <literal>, false)` as today. *(amended 2026-09-15, PR #2 fix wave — two corrections. The name is matched **case-insensitively**, because SQL identifiers are and the projection's columns are SQL identifiers, and the column is emitted with the spelling the projection stores; a byte comparison refused a mis-cased name on a MAP-less tree and, worse, fell past the column into the map on a MAP-bearing one. And the literal is compared **in the column's type**: a number against a text column compares as text (`"name" = '5'`, not `"name" = 5`, which DuckDB binds by casting the column and which aborted the query on the first row that was not a number), a number against a numeric column stays numeric, and an unrecorded or other type takes `TRY_CAST` — the same reading, and the same reason, as the map branch below.)*
2. Else if the tree declares `ATTR MAP`: the map value is cast to the literal's type: an integer literal → `BIGINT`, a decimal → `DOUBLE`, `true`/`false` → `BOOLEAN`, a quoted literal → `VARCHAR`: `COALESCE(TRY_CAST(<alias>._attr_map['name'] AS <type>) <op> <literal>, false)`.
3. Else refuse at compile: `tree_match: attribute 'name' is neither a projected column nor served by ATTR MAP`.

0. *(added 2026-09-15, PR #2 fix wave, and checked **before** all three.)* A **canonical** `_`-prefixed column is not an attribute at all: it is the tree's own representation, and P14 says MATCH sees the projection's *declared* attributes. `[_level=0]` refuses, naming the `WHERE` clause, where a question about the representation belongs. Checked first for the same reason the case fold matters — on an ATTR MAP tree it would otherwise be a lookup for a key the map cannot hold, and read as "no such row".

Whether a name is a projected column is known at compile time from the compiled projection's column list, recorded at create in `tree_catalog.compiled` as a new `attribute_columns` artifact *(amended 2026-09-15, PR #2 fix wave: a JSON list of `{name, type}` objects, not of names — the clause compiler needs the column's type to decide how a numeric literal compares against it, and a bare list of names still reads, with a NULL type)*. MN13 becomes "a typed comparison served by string comparison" and its fixture has a map value where string and numeric order disagree (`'9'` versus `'10'`).

*(amended 2026-09-15, M2 build.)* Step 3 needs stating exactly, because it is weaker than "an unknown attribute refuses" sounds. **A map's keys are data.** On a tree that declares `ATTR MAP`, *every* name is servable, so the compile-time refusal can only ever mean "no projected column **and** no map declared". On a tree that does declare one, an unknown key reads as no match — which is the NULL-definite rule of §6.1, not a silent failure. The corpus record that pins the refusal therefore has to use a map-less tree; on a map-bearing one there is nothing to refuse.

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

*(amended 2026-09-15, M2 build — five things the build settled.)*

- **The shared tier dedups by macro identity, not only by name.** A macro already bound under *any* name, locally or through a prefix, is not bound again by the shared tier. A prefix declaration is a namespace claim: `{prefix: 'sel_ast_'}` says "these macros are mine, under these names", and letting the shared tier re-bind `sel_ast_docblock` a second time as `ast_docblock` would double every library. This is a deviation from the "most local wins" sentence above, which resolves *collisions* and does not speak to the same macro arriving twice under two names.
- **The shared tier binds only when `pseudo_args` is declared.** There is no other way to know what to call the macros with, so a tree that does not declare it simply has no shared tier.
- **A LIKE child resolves the shared tier at *its own* create time**, so a child created after the catalog grew may carry bindings its parent does not. That is by design — the tier is a view of the catalog, not a copy — and it is the one way a LIKE child's S group legitimately differs from its parent's.
- **`tree_shared_pseudo_prefix()` = `'sel_'`**, stated once and read by both the expansion and the catalog read-back.
- **A prefix that binds no macro refuses at DDL** *(added 2026-09-15, PR #2 fix wave)*: `tree_ddl_create: PSEUDO prefix nosuch_ binds no macro`. Expansion replaces a prefix entry with one binding per matching macro, so when none matches it replaces it with *nothing*, and by the time the S validation ladder sees the group a misspelled prefix is indistinguishable from one that was never written — the tree was created with an empty PSEUDO block and every `:name` its author meant to mint compiled to false. `tree_sql_check_prefixes(sem, verb)` therefore reads the group as **written**, and both DDL compilers call it.
- **Provenance survives a catalog round trip.** `origin` is `local | prefix | shared` and `kind` is `expression | macro`; `macro` and `args` are *recovered from* `body` on read-back (a `macro` row stores `body` as `'name(args)'`), because without them a LIKE child's shared-tier scan cannot see that an inherited entry already claims a catalog macro, and binds it a second time under a derived name.

## 8. The differential harness

Two corpus sources. `test/corpus/selectors.tsv` is hand-written: columns `id`, `treeql` (a `tree_steps` literal), `css`, `fixture`, `tags` (space-separated: `portable`, `sitting_duck_supported`, `nested`, `sibling`, `attr`, `pseudo`, `refusal`); every row has both spellings. `test/corpus/astcss_eval.jsonl` is imported from the Tiiny work's astcss-eval set (`~/Projects/astcss-eval/pairs/accepted-*.jsonl`, 108 execution-verified pairs over tiers 1 to 4, 98 distinct selectors) with provenance: each pair carries its css, its fixture, and a frozen reference (a node set with a hash) produced by sitting_duck at a pinned commit. Two fixtures come with it: `repo-small-py` is sitting_duck's `scripts/` directory, which `scripts.parquet` already pins, and `py-variety` is sitting_duck's `test/data/python`, added as `py_variety.parquet` at the manifest's commit. The frozen references make the sitting_duck differential runnable without sitting_duck installed: suite 41 compares against the frozen sets first and against live `ast_select_from` only under `require`. The import fills each pair's empty `treeql` twin from our lowering, which feeds back to astcss-eval as its P22 fixtures.

Suites:

| suite | requires | asserts |
|---|---|---|
| `40_corpus.test` | nothing | each row compiles and runs on its fixture in both languages, and both languages return identical key sets (P22 on results) and identical printed TREEQL (P22 on normal forms) |
| `41_differential_sitting_duck.test` | nothing *(amended 2026-09-15: the frozen references are committed, so this half needs no extension)* | for `sitting_duck_supported` rows, `tree_match` versus the frozen reference returns identical `(file_path, node_id)` sets, checked by `EXCEPT` in both directions; the sitting_duck shape declares `CLASSES` from `ast_type_map()` aliases and `ID name` |
| `41b_live_sitting_duck.test` *(added 2026-09-15)* | sitting_duck, and the astcss-eval fixture directory | 76 of the 108 rows against **live** `read_ast` / `ast_select_from`; 31 are skipped because the installed build has regressed on #127 and 1 is the adjudicated divergence |
| `42_second_differential.test` | nothing | every corpus row returns identical key sets with `SIZE`/`PARENT`/`CHILDREN` declared and derived (MN3), **plus** the two projections compared column for column and a hand-written `SIZE_WITNESS` — the corpus rows alone cannot see a wrong `_size` |
| `43_representation.test` | nothing | P23: `TYPE` as a column versus an expression; one pseudo-class promoted to a class at ingest; identical key sets (MN25) |
| `38_css_lower.test` *(added 2026-09-15)* | sitting_duck | `tree_css_lower` against the IR the runner parser builds, every expectation **generated** from the runner parser and pasted verbatim, so a mismatch is a real disagreement and never a typo; the printed TREEQL beside each one is what gives a legible diff (and what kills MN24) |
| `44_parsers.test` | sitting_duck | MN8: both css parsers produce identical IR for every css row |

Divergences are recorded in `FINDINGS.md` with adjudication before any test changes. One is adjudicated in advance: sitting_duck's bare-keyword prefix tier (`function` matching `function_definition`) is vocabulary, not selector semantics; the corpus uses exact types and `.class` aliases only.

*(amended 2026-09-15, M2 build — what the corpus and the suites actually carry.)*

- Each astcss row carries **both** its IR (`treeql_ir`, the runner parser's literal) and its printed form (`treeql`), so 40 can compare the two spellings without re-parsing.
- **40** compares `file_path:node_id` lists. **41** compares DISTINCT node *sets* — duckent's contract is one row per full-pattern embedding, sitting_duck's is the subject set, so four rows differ in multiplicity and in none of them does the node set differ — plus the sha256 recipe `sha256(string_agg(basename || ':' || node_id, ',' ORDER BY file_path, node_id))` against the frozen reference verbatim.
- **41b** is the live half, running `read_ast` over the fixture directory. It currently skips the 31 rows whose chain carries a top-level combinator: the installed sitting_duck has **regressed on #127**, and those rows return 0 from today's `ast_select_from` while their frozen references (captured on a build that had #127 fixed) carry them. Marked `TODO(sd#127)`; deleting the skip in the importer and regenerating restores full live coverage.
- The fixtures carry `css_classes`, `is_element` and `params` as columns derived at fixture time, so **41 runs without sitting_duck installed** — the frozen references are the oracle, and the live engine is a second opinion.
- **Adjudication:** t1-p21 `lambda` diverges from its reference because sitting_duck's bare type selector **prefix-matches** (`lambd` selects both `lambda` and `lambda_parameters`). A css type selector is equality on the node type, so duckent's 2 rows are right and the reference's 3 are wrong. This is a new upstream bug, not one of the tracked issues, and is unfiled. 107 of 108 references are asserted and pass.

## 9. Mutants planted in M2

*(amended 2026-09-15, M2 build. The table below is the corrected one: `test/mutants/manifest.yaml` is the live record and its `expect_fail` lists are reproduced here verbatim; FINDINGS' "Mutant kill map corrections" is the reasoning. Six of the nine rows as designed were wrong or incomplete, and every correction was established by running the suite in question under the mutant, in both directions.)*

| id | wrong implementation, as built | `expect_fail` | also verified |
|---|---|---|---|
| MN3 | a **declared** SIZE compiles to a subtree range one short of a derived one | 42 | nothing else. 40 and 41 **pass** under it, although both declare SIZE |
| MN5 | a group's first inner step is joined as a CHILD whatever its op, so `:has()` is child-only | 40 | 34_groups, 41 |
| MN7 | an unknown pseudo-class raises instead of selecting nothing | 40 | 37, 31, 34, 36 |
| MN8 | the runner parser records a child combinator as a descendant, so `a > b c` groups as `a b c` | 44, 37 | — |
| MN12 | the shared `sel_*` tier shadows a tree's own local or prefix binding | 36_pseudo | nothing: no corpus tree declares a pseudo a `sel_*` could shadow |
| MN13 | the ATTR MAP comparison casts the **literal** to text instead of the map value to the literal's type | 35_attr_map | — |
| MN22 | the css lowering consults `tree_state` and refuses while a partition is not P13-clean | 44_parsers | nothing: 40's css goes through the **runner** parser and never reaches `tree_css_lower` |
| MN24 | the printer omits NOT groups, so `.fn:not(:has(string))` prints as `.fn` | 34_groups, 38_css_lower | — |
| MN25 | a CLASS clause is answered from the pseudo-class of the same name when CLASSES is empty | 43 | — |

Three of those corrections are one lesson, and it is the one to carry: **a differential suite cannot see a mutation that moves both of its sides.** 40_corpus compares two *spellings* of one selector against each other on *one* tree, so a symmetric mutation — the printer (MN24), a shortened `_size` (MN3) — cancels exactly. Only a comparison against something frozen catches those.

Three shapes differ from the sentences above, and the difference is the point in each case:

- **MN3** as designed ("a fragment that consults declared-versus-derived status") would have died trivially: a fragment that reads the catalog cannot be spliced into `query()`, which is where the projection text goes. The planted mutant is a copy of `tree_compile_projection` whose declared-SIZE branch is `CAST(a.__size_raw AS BIGINT) - 1` — the smallest edit that makes a declared O column diverge from its derived default.
- **MN13** drops the typed cast by casting the **literal** to VARCHAR rather than removing `TRY_CAST`. Removing it outright is a *binder* error in 1.5.5, which would make MN13 a loud mutant any suite kills; casting the literal is the plausible wrong implementation — it binds, it runs, and it answers that `'10'` is not greater than `9`.
- **MN22** overrides the one fragment stage 9 of the lowering calls for every emitted row (`tree_css_path`) rather than copying the whole 365-line macro. The state read still happens where the lowering decides where a row goes.

**Two corpora gained bait**, each commented in place with the mutant it serves, because nothing in the suite could otherwise kill the mutant: row **c17** (`.fn:not(:nope)`) for MN07 — the 108 astcss rows use only `:has` and `:not`, so no row carried an unknown pseudo-class — and tree **`rep_class_none`** for MN25, which binds `def` as a PSEUDO and declares an empty CLASSES list, so `.def` must select nothing there. 43's two promotion records cannot discriminate on their own.

**And one mechanism.** MN08 mutates the runner's css parser, which is Python: no `CREATE OR REPLACE MACRO` override can express it. Manifest rows may now carry an `env:` map that `test/run_mutants.py` adds to each subprocess environment (`DUCKENT_MUTANT`). The mutant's SQL file is comment-only, so every mutant is still one id, one file, one row.

Each remaining mutant is a one-fragment override where a fragment exists.

## 10. Operations and catalog changes

- `tree_match(sch, nm, sel, semantic := NULL, language := NULL)`: `selector` may be a `TREE_SELECTOR` or text (parsed by the registered language). `tree_explain` likewise, returning `{treeql, sql, language}`. *(amended 2026-09-15: `language :=` is provenance, not a directive — `_match_language` is `COALESCE(language, 'treeql')` and never reads the catalog. See the core design §4.)* *(amended 2026-09-15, PR #2 fix wave: the fallback is no longer the literal `'treeql'` but the language the FRONT-END stamped on the IR's `selector` root row — `tree_steps` `treeql`, both css front-ends `css` — read back by `tree_selector_language(sel)`. `language :=` still wins; IR that stamps nothing still reads `treeql`.)*
- `tree_default_selector_language` is a catalog row in a new `tree_catalog.settings(name, value)` table, `treeql` until the css front-end lands, then `css`, flipped by the last M2 task. **Done: the seed is `css`.** It governs one thing — which front-end parses a selector handed over as *text*.
- `tree_catalog.compiled` gains the `attribute_columns` artifact per tree. *(amended 2026-09-15: it is read on every `tree_compile_match`, and the read is `from_json` on the stored text. Folding it into the compile is an efficiency item, not a correctness one.)* *(amended 2026-09-15, PR #2 fix wave: its shape is `[{"name": ..., "type": ...}]`, the type being DESCRIBE's `column_type`; the reader accepts a bare list of names as well, deciding by the first element's `json_type`, so a catalog written before the change still resolves its names — with no type, which the comparison rule reads as "take the cast that cannot abort".)*
- `tree_catalog.pseudo_classes.origin` is populated for `prefix` bindings — and for `shared` ones, and survives a LIKE copy (§7).
- *(amended 2026-09-15)* `tree_sql_clause` has the nine-argument signature of §4, and the `slots` table has the `ELEMENT` and `PSEUDO_ARGS` rows.

## 11. Scope

**In:** sections 2 to 10; the `tree_sql_sem_cols` refactor; the list-space spike; `tree_siblings`. **Out:** the per-level ASOF derived size and the rest of the O layer (M3); xpath and tree-sitter-query front-ends; the TREEQL text parser and language-registration API (M-LANG); attachments (W); the C++ port.

*(amended 2026-09-15, M2 build: everything listed **in** shipped, and nothing listed **out** was pulled forward. What the build added beyond this list is the `self` op of §2, which `:not` could not be lowered without. FINDINGS' "Open after M2" is the triage list of what the milestone leaves behind.)*

## 12. Open decisions carried

D-N9 (capture collisions; `s<N>` refused — *(amended 2026-09-15, final fix wave: this said "already refused" and was **false for the default language**. Only `tree_steps` refused it; both css front-ends accepted `@s1` (the capture column was silently dropped while `tree_explain` still printed `AS s1`) and `@s3` (two relations aliased `s3`, a raw Binder Error). All three front-ends refuse it now, and so does `tree_compile_match`, which is where IR from any of them converges)*), D-N10 (language registration API; the `selector_languages` row is its placeholder), D-N13 (`FOLLOWING` for `~`), D-N15 (bare identifiers versus string literals in TREEQL; the constructor takes strings, the css lowering emits strings), D-N16 (`ATTR` spelling; unchanged). New: **D-N17** whether list-space navigation replaces `EXISTS` — *(amended 2026-09-15: **closed, against.** The spike's numbers are in FINDINGS; `EXISTS` is 50× to 60× faster on the larger input and the gap widens with size.)*; **D-N18** element rows (adopted for M2: a shape-declared element predicate governs sibling and positional relations; default true).

*(amended 2026-09-15, M2 build — new open items for M-LANG, carried out of the css work.)*

- **The `:not` self relation** has an IR op (`self`) and a printer keyword (`SELF`), but no TREEQL *text* spelling, because TREEQL has no text parser yet. M-LANG decides what one writes.
- **The three lossy families of §5.1.** The first — a compound after a whitespace descendant combinator beginning with a pseudo-class or a quoted type — is the one worth closing, and rewriting the combinator through the `*` universal selector is the candidate.

**D-N20** *(added 2026-09-15, PR #2 fix wave)* **parameterized pseudo-classes.** sitting_duck's #145–#148 are argument-taking pseudo-classes (`:scope(S)`, `:calls(name)`, alongside the argument-less `:is-referenced`, `:exported`), and duckent has the binding machinery for the argument-less half already: a `PSEUDO` is a declared row-scope expression, and §7's macro and prefix forms already pass *fixed* arguments (`has_docblock(file_path, node_id)`). What v0 has no answer for is an argument written at the **call site**, and there are two different shapes of it:

(a) **scalar arguments** — `:calls('print')`. These map onto the macro binding form with the call-site arguments appended: the binding names a macro and the tree's `PSEUDO_ARGS` supply the row columns, so `:calls('print')` would compile to `calls(file_path, node_id, 'print')`. The open question is only syntax and arity checking, not evaluation.

(b) **selector arguments** — `:scope(S)`, where the argument is a selector and the test is "some ancestor matches S". That is a GROUP, not a clause: a `has`/`not` node whose inner chain is anchored by an **`ancestor`** relation. The fragment exists (`tree_sql_ancestors(a, b)`, sql/07_match.sql, the subtree relation read backwards), so this needs one more legal first-inner-step op alongside `self` — and the same "legal only as a group's first inner step" rule that `self` already carries.

**v0 refuses both**, in both css front-ends, through the rule that already refuses every argument-taking pseudo-class but `:has` and `:not` (`:calls() is not supported in v0`). M-LANG decides the syntax; this entry decides what it would lower to, so that the decision is about spelling rather than about semantics.

**D-N19** (future, not M2): cycle-free Cypher as a registered selector language. A `MATCH (a:fn)-[:CHILD]->(b:block) WHERE ... RETURN a, b` pattern lowers to `TREE_SELECTOR` the same way css does: node patterns become steps, relationship types become combinators (`CHILD`, `DESCENDANT`, `SIBLING`, `FOLLOWING`, and the reverse axes of §4), node variables become captures, `WHERE` becomes step `WHERE` (Cypher is a host-door language like TREEQL, not a closed one like css). Cycles are refused at lowering because a tree pattern is a path or a rooted DAG of paths, so `MATCH` graphs with a cycle name no tree relation. Sits with xpath and tree-sitter-query in M-LANG (D-N10).
