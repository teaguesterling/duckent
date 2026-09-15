# duckent

Tree semantics for ordered relations: the contract every duck sits on.

duckent is a (planned) DuckDB extension that implements **tree semantics over ordered relations**: the layer *below* every parser. It defines what makes a set of rows a tree, what a CSS-style selector means over those rows, and how a `MATCH` compiles to ordinary SQL. Parsers such as [sitting_duck](https://github.com/teaguesterling/sitting_duck) (ASTs) and [duck_block_utils](https://github.com/teaguesterling/duckdb_duck_block_utils) (documents), and every adjacency list already in your warehouse (org charts, category trees, BOMs, file hierarchies), become *vocabularies over one contract*.

> **Status: macro prototype, M2 runs.** `sql/` holds a macro-only reference implementation of M0, M1, M1½ and M2: the catalog, the projection compiler, both basis derivations, forest DML with P13 on ingest, TREEQL matching through `tree_steps`, and now nested `HAS`/`NOT` groups with a `SELF` relation, two css front-ends bound to each other by a row-level differential, a typed `ATTR MAP`, element rows, four pseudo-class binding forms with a shared `sel_*` tier, and a selector corpus checked against frozen sitting_duck references. It runs on DuckDB 1.5.5 with no extension dependency. `test/sql/` holds the sqllogictest suites and `test/mutants/` the planted mutants; both carry over unchanged to the C++ extension. The design is in [`docs/superpowers/specs/2026-09-13-duckent-core-design.md`](docs/superpowers/specs/2026-09-13-duckent-core-design.md) and, for M2, [`docs/superpowers/specs/2026-09-14-duckent-m2-design.md`](docs/superpowers/specs/2026-09-14-duckent-m2-design.md). Where the build differed from either, `FINDINGS.md` says so.

The name: Ents speak Tree, and Treebeard's policy of never saying anything unless it is worth taking a long time to say is bind-time checking's motto.

## The idea in one screen

Your ASTs were rows all along. A tree stored as its own depth-first traversal needs only two things to be selectable: **row order** and a **nesting column** (a `level`, or a `parent` from which level is derived). That encoding has a name and a history (pre/size/level, from the XML-database era), and sitting_duck's `node_id` / `depth` / `descendant_count` rebuilt it column for column.

```sql
-- Today, with sitting_duck (ast_select is a table macro; :docblock and
-- pseudo-classes inside :has() arrive with duckent's pseudo registry):
FROM ast_select('src/**/*.py', '.fn:not(:has(string))')
SELECT name, start_line;

-- Where duckent is headed (DuckDB 2.0 PEG parser):
CREATE TREE sitting_duck_ast (
  SHAPE ONLY,
  ROOT  (file_path),                                 -- forest key: one tree per file
  ORDER node_id,  LEVEL depth,
  TYPE  semantic_type_to_string(semantic_type),
  ATTR  (name := name, start_line := start_line),    -- named, typed attributes
  ATTRS MAP extra,                                   -- long-tail catch-all
  PSEUDO (docblock := has_docblock(file_path, node_id),
          leaf     := descendant_count = 0),
  SIZE descendant_count OPTIMIZE                     -- native column; test-equals its default
);

FROM 'code.parquet' USING TREE sitting_duck_ast MATCH .fn:not(:has(:docblock)) SELECT name;
```

The same compiler, pointed at a Markdown document, answers `section h2 + table`; pointed at an org chart declared with `PARENT manager_id`, it answers `manager:has(> engineer)`.

## Where it sits

```
sitting_duck_languages   duck_block_utils   adjacency shims (CMDB, LDAP, SBOM)
        \                       |                     /
         sitting_duckling  (parse engines -> conforming relations)
                                |
                             duckent   <- contract + selector semantics
                                |
                             DuckDB
```

duckent owns: what "selectable" means, how bases derive, how optimizations stay honest, and what a selector *does*. It does not own any grammar, any parser of code or documents, any taxonomy, or any policy semantics.

## The ROWS contract

Four blocks, taught in dependency order (R, S, O, W). Rearranged, the initials spell **ROWS**.

| Block | Name | What it governs |
|---|---|---|
| **R** | Required | Structure. `ROOT` (tree identity, required iff the relation holds more than one tree), row order, and a structural basis of `LEVEL` or `PARENT`. Either basis derives the other. R1 + R2 is the minimal treeness set. |
| **S** | Semantics | What selectors can say. `TYPE` (total, defaults to `'node'`), `ID`, `CLASSES`, two-tier attributes (named and typed, then a string-only map), and per-tree `PSEUDO` bindings whose values are plain row-scope expressions. |
| **O** | Optimizations | Cost only, never results. Native `PARENT`, `SIZE`, `CHILDREN`, `NEXT` columns register as overrides. Every override must test-equal its derivable default; a divergence is a corrupted encoding, not a fast path. |
| **W** | World | Linking trees without touching them. Root-restricted attachments, demand loaders with a tri-state frontier (loaded / unloaded / absent), and epoch manifests. Within-tree match sets are invariant under any change to W. |

## Doctrine

1. **One semantics, N surfaces.** Exactly one matcher. The built-in parser, tree-sitter-css, and a future PEG-native front-end are bound to it by differential test.
2. **Semantics consult declarations, never state.** Matching is a function of R, S, and attachment declarations. Caches and load status are visible to planning only, and module boundaries enforce it.
3. **Every claim is a test or is marked open.** Planted mutants must die. A suite no mutant can fail tests nothing.
4. **Fail legibly.** A selector needing a capability the tree does not declare fails at bind time with the missing slot named, never with an empty result.
5. **Unknowns are preserved, excluded, reported.** Unknown pseudo-classes parse, match nothing, and are counted.

## Settled syntax

- `CREATE TREE t (SHAPE ONLY, ...)` declares an abstract tree. `SHAPE ONLY` is required whenever there is no `AS` clause.
- `CREATE TREE t LIKE shape AS FROM ...` instantiates. `LIKE` copies semantics, never source.
- `FROM src USING TREE <name | (rules)> MATCH ...` applies a shape ad hoc, as a `USING SAMPLE`-style modifier on a FROM item.
- Bare `MATCH` flows into the clause pipeline and ends at the next top-level SQL keyword. `MATCH $( ... )` is the delimited form, required once a host escape appears.
- `*[WHERE <sql>]` is the host escape: a full SQL predicate at any node position, compiled against the node's projection view. It needs an explicit head; bare `[WHERE]` is a parse error.
- DML is tree-granular by `ROOT`: `INSERT INTO` appends trees, `DELETE` drops by key, `INSERT OR REPLACE` re-derives.
- Pre-2.0, all of this compiles to a macro bridge: a shape is a projection macro over canonical columns, and `MATCH` generates its query against those columns only. That mechanism is verified on shipped DuckDB and enforces the visibility rule for free.

## Milestones

| | Milestone | Gate |
|---|---|---|
| M0 | Shape and tree registry, projection compiler, per-partition well-formedness | Property tests over generated level sequences; sitting_duck output as oracle fixture |
| M1 | Basis derivations (level to parent, parent to order and level), sibling-free profile | Round-trip identities; legible refusals |
| M2 | Matcher core over R and S | Differential oracle against sitting_duck's shipped `ast_select` — **met**: 107 of 108 frozen references asserted and passing, the 108th adjudicated against upstream in `FINDINGS.md` (sitting_duck's bare type selector prefix-matches) |
| M3 | O layer and planner use of it | Auto-generated conformance assertions; module-boundary mutant |
| M4 | Pseudo-class dispatch, profiles, introspection, docs | Cheatsheet generated from catalog queries |

Planted mutants are listed in the handover document and tracked in `test/mutants/manifest.yaml`.
All must die before a milestone closes. Eighteen are planted today and all eighteen die; the
remaining ids are deferred or reserved — the W block, the O-layer one that arrives with M3, the
retired host-escape number, and one that waits on the selector-language work. A surviving mutant
is fixed by a test, never by a manifest edit, and a manifest states what a mutant does rather
than what one hopes it does.

A mutant of the copy-and-edit kind is *that macro, with one edit*, and that claim does not hold
by itself: a sweep over the sources leaves the copies quoting macros that no longer exist, and
they go on being killed, because a macro from two commits ago fails the same tests a wrong one
does. So the copies are generated (`test/mutants/regen.py`) from the macro plus a declared edit,
`--check` refuses a drifted one before any suite runs, and each generated mutant has a
`.control.sql` — the same copy with the edit left out — which the harness applies and requires to
PASS. A kill with no passing control is reported, not counted.

## Running the prototype

```bash
pip install duckdb==1.5.5 pyyaml
python3 test/run.py test/sql          # the suites
python3 test/run_mutants.py           # every planted mutant must die, and each kill is
                                      #   verified against its control (--no-verify skips)
python3 test/mutants/regen.py         # rewrite the generated mutant copies and controls
python3 test/test_css_parser.py       # unit tests for the runner's css parser
python3 test/spike_listspace.py       # the D-N17 measurement; prints timings, changes nothing
                                      #   --materialized also times the pre-built list form
python3 test/import_astcss_eval.py    # regenerates the corpus suites 40-44; idempotent
python3 test/gen_fixtures.py          # only to regenerate fixtures; needs sitting_duck and markdown
```

Three suites open with `require sitting_duck` — `38_css_lower`, `41b_live_sitting_duck` and
`44_parsers`, the ones that run the SQL css front-end or the live engine. The runner skips a file
whose `require` will not load, so the suite is green without the extension: the differential
itself (`41_differential_sitting_duck.test`) needs no `require`, because it compares against
**frozen** references committed with the corpus, and the fixtures carry the columns
(`css_classes`, `is_element`, `params`) that sitting_duck would otherwise have to supply.
`41b_live_sitting_duck.test` additionally reads the astcss-eval fixture directory, which the
runner cannot skip for — a `require` covers a missing extension, not a missing directory.

Quick tour in a DuckDB session after loading `sql/*.sql` in order (the runner does this for you):

```sql
CALL tree_ddl_create('main', 'app', tree_spec(
  tree_shape(root := 'file_path', "order" := 'node_id', level := 'depth', size := 'descendant_count',
             semantic := tree_semantic(type := 'type', id := 'name')),
  source := 'read_parquet(''test/data/app.parquet'')'));
FROM tree_match('main', 'app', tree_steps([{type: 'function_definition', "as": 'f'}, {comb: 'child', type: 'block'}])) SELECT f.name;
```

In the macro phase `CALL tree_ddl_*`, the DML verbs, and `tree_match` are executed by the test runner, which compiles them with the `tree_compile_*` macros; in a bare session call the compilers yourself and run the returned SQL.

## Documents

| File | What it is |
|---|---|
| [`docs/11-duckent-handover-v21.md`](docs/11-duckent-handover-v21.md) | The build brief. Identity, doctrine, the normative contract, API surface, milestones, planted mutants, open decisions. Usable verbatim as an engineer brief or a Claude Code session prompt. |
| [`docs/14-shape-syntax-options-v13.md`](docs/14-shape-syntax-options-v13.md) | The settled DDL and DML family, with the design-space enumeration, verdicts, and the experiment log showing every ingredient verified on DuckDB 1.x. |
| [`docs/12-tree-contract-lesson-v18.html`](docs/12-tree-contract-lesson-v18.html) | The public teaching layer: a hands-on lesson from `grep` to `CREATE TREE`. Self-contained HTML. Published at <https://teaguesterling.github.io/pages/static/tree-contract-lesson.html>. |
| [`docs/superpowers/specs/2026-09-13-duckent-core-design.md`](docs/superpowers/specs/2026-09-13-duckent-core-design.md) | The implementation architecture: catalog schema, types, operations, the projection, match evaluation, what the C++ port replaces. Amended at the close of M2. |
| [`docs/superpowers/specs/2026-09-14-duckent-m2-design.md`](docs/superpowers/specs/2026-09-14-duckent-m2-design.md) | The M2 design: nesting, the two css front-ends, the differential harness, the mutants. Marked "built"; the amended paragraphs say where the build and the design differ. |
| [`FINDINGS.md`](FINDINGS.md) | Every oracle divergence with its adjudication, every DuckDB 1.5.5 constraint the design had to bend around, the spike numbers, and the open items after M2. |

The handover names other companion documents (the assertion plan, the trees-to-rows paper, the sitting_duck verification pass) that are not yet in this repository.

## Related repositories

- [sitting_duck](https://github.com/teaguesterling/sitting_duck): ASTs as rows across 27 tree-sitter grammars, with `ast_select`. The M2 differential oracle.
- [duck_block_utils](https://github.com/teaguesterling/duckdb_duck_block_utils): documents as ordered, leveled block rows. Conforms by construction.
- [squackit](https://github.com/teaguesterling/squackit), [pluckit](https://github.com/teaguesterling/pluckit), [fledgling](https://github.com/teaguesterling/fledgling): consumers of the same selector semantics from Python, the shell, and a code index.
- [umwelt](https://github.com/teaguesterling/umwelt): CSS as a policy engine, the layer above.
