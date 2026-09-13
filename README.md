# duckent

Tree semantics for ordered relations: the contract every duck sits on.

duckent is a (planned) DuckDB extension that implements **tree semantics over ordered relations**: the layer *below* every parser. It defines what makes a set of rows a tree, what a CSS-style selector means over those rows, and how a `MATCH` compiles to ordinary SQL. Parsers such as [sitting_duck](https://github.com/teaguesterling/sitting_duck) (ASTs) and [duck_block_utils](https://github.com/teaguesterling/duckdb_duck_block_utils) (documents), and every adjacency list already in your warehouse (org charts, category trees, BOMs, file hierarchies), become *vocabularies over one contract*.

> **Status: design stage.** This repository currently holds the design documents. No extension code has landed yet. The build plan, the settled DDL, and a public lesson are in [`docs/`](docs/).

The name: Ents speak Tree, and Treebeard's policy of never saying anything unless it is worth taking a long time to say is bind-time checking's motto.

## The idea in one screen

Your ASTs were rows all along. A tree stored as its own depth-first traversal needs only two things to be selectable: **row order** and a **nesting column** (a `level`, or a `parent` from which level is derived). That encoding has a name and a history (pre/size/level, from the XML-database era), and sitting_duck's `node_id` / `depth` / `descendant_count` rebuilt it column for column.

```sql
-- Today, with sitting_duck:
FROM read_ast('src/**/*.py')
SELECT name, start_line
WHERE ast_select(node, '.fn:not(:has(:docblock))');

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
| M2 | Matcher core over R and S | Differential oracle against sitting_duck's shipped `ast_select` |
| M3 | O layer and planner use of it | Auto-generated conformance assertions; module-boundary mutant |
| M4 | Pseudo-class dispatch, profiles, introspection, docs | Cheatsheet generated from catalog queries |

Twenty-one planted mutants are listed in the handover document. All must die before a milestone closes.

## Documents

| File | What it is |
|---|---|
| [`docs/11-duckent-handover-v21.md`](docs/11-duckent-handover-v21.md) | The build brief. Identity, doctrine, the normative contract, API surface, milestones, planted mutants, open decisions. Usable verbatim as an engineer brief or a Claude Code session prompt. |
| [`docs/14-shape-syntax-options-v13.md`](docs/14-shape-syntax-options-v13.md) | The settled DDL and DML family, with the design-space enumeration, verdicts, and the experiment log showing every ingredient verified on DuckDB 1.x. |
| [`docs/12-tree-contract-lesson-v14.html`](docs/12-tree-contract-lesson-v14.html) | The public teaching layer: a hands-on lesson from `grep` to `CREATE TREE`. Self-contained HTML. Published at <https://teaguesterling.github.io/pages/static/tree-contract-lesson.html>. |

The handover names other companion documents (the assertion plan, the trees-to-rows paper, the sitting_duck verification pass) that are not yet in this repository.

## Related repositories

- [sitting_duck](https://github.com/teaguesterling/sitting_duck): ASTs as rows across 27 tree-sitter grammars, with `ast_select`. The M2 differential oracle.
- [duck_block_utils](https://github.com/teaguesterling/duckdb_duck_block_utils): documents as ordered, leveled block rows. Conforms by construction.
- [squackit](https://github.com/teaguesterling/squackit), [pluckit](https://github.com/teaguesterling/pluckit), [fledgling](https://github.com/teaguesterling/fledgling): consumers of the same selector semantics from Python, the shell, and a code index.
- [umwelt](https://github.com/teaguesterling/umwelt): CSS as a policy engine, the layer above.
