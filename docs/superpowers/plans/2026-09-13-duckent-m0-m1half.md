# duckent M0 to M1½ Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macro-only reference implementation of duckent's catalog, projection compiler, derivations, and TREEQL match compiler, tested by sqllogictest files that will later run unchanged against the C++ extension.

**Architecture:** Every mutating operation is a pure SQL macro that returns SQL text (`tree_compile_*`) plus a thin executor; in this phase the executor is the Python test runner, which rewrites `CALL tree_ddl_*(...)`, the DML verbs, and `tree_match(...)` into their compiled SQL. Trees live in `tree_catalog` (declarations) and `tree_state` (state); a tree's canonical projection is a generated table macro emitting `_root, _pre, _level, _parent, _size, _children, _next, _type, _id, _classes, _attr_map, _pseudo` plus attribute columns. Matching compiles a `TREE_SELECTOR` (a flattened tree of rows) into a join chain over the projection by a bottom-up recursive-CTE fold.

**Tech Stack:** DuckDB 1.5.5 (CLI at `~/.local/bin/duckdb`, Python package `duckdb==1.5.5`), SQL macros, Python 3 for the runner, sitting_duck and markdown extensions only to regenerate fixtures.

**Spec:** `docs/superpowers/specs/2026-09-13-duckent-core-design.md`

## Global Constraints

- DuckDB version floor: 1.5.5. Lambdas use `lambda x: ...` syntax; the arrow form is deprecated and warns.
- Macro files load in filename order from `sql/`; every macro is `CREATE OR REPLACE`, every type is created only if absent (see Task 2 for the idiom).
- Canonical columns carry the `_` prefix: `_root, _pre, _level, _parent, _size, _children, _next, _type, _id, _classes, _attr_map, _pseudo`. `_pre` and `_level` are BIGINT.
- Object names: projection macro `tree_catalog."proj_<schema>_<name>"()`, storage table `tree_catalog."t_<schema>_<name>"`.
- Every refusal is raised with `error('<function>: <what is missing or wrong, naming the slot>')`.
- Attribute filters and pseudo-classes are NULL-definite: wrap in `COALESCE(..., false)`.
- Commit after every task with a message in the form `feat(m0): ...`, `feat(m1): ...`, `feat(m1.5): ...`, `test: ...`, or `docs: ...`, ending with the attribution lines the session prescribes.
- Never renumber a mutant id; retired ids stay reserved.
- Tests are sqllogictest `.test` files under `test/sql/`, run with `python3 test/run.py test/sql`.

---

## File structure

| path | responsibility |
|---|---|
| `sql/00_types.sql` | `TREE_SEMANTIC`, `TREE_SHAPE`, `TREE_SPEC`, `TREE_SELECTOR` types; `tree_semantic`, `tree_shape`, `tree_spec` constructors; string helpers |
| `sql/01_catalog.sql` | `tree_catalog` and `tree_state` schemas and tables; `tree_catalog_*()` introspection macros |
| `sql/02_projection.sql` | fragment macros (`tree_sql_*`) and `tree_compile_projection(shape, source, attr_text)` |
| `sql/03_ddl.sql` | `tree_shape_from_catalog`, `tree_shape_merge`, `tree_compile_create`, `tree_compile_drop`, `tree_compile_alter`, `tree_project` |
| `sql/04_dml.sql` | `tree_compile_p13`, `tree_compile_insert`, `tree_compile_replace`, `tree_compile_delete`, `tree_compile_check` |
| `sql/05_derivations.sql` | standalone `tree_derive_parent(source)` and `tree_encode(source, key, parent, sibling_order)` table macros |
| `sql/06_selector.sql` | `tree_steps(steps)` constructor and `tree_selector_to_treeql(sel)` printer |
| `sql/07_match.sql` | `tree_sql_comb`, `tree_sql_clause`, `tree_compile_match(sch, nm, sel, semantic)`, `tree_explain` |
| `sql/08_traversal.sql` | `tree_children`, `tree_descendants`, `tree_ancestors`, `tree_next_sibling`, `tree_first_child` |
| `test/run.py` | sqllogictest runner over the Python `duckdb` package with executor emulation |
| `test/run_mutants.py` | applies one mutant file and asserts the listed tests fail |
| `test/mutants/manifest.yaml`, `test/mutants/MN*.sql` | planted mutants |
| `test/gen_fixtures.py` | regenerates parquet fixtures with sitting_duck and markdown (not run in CI) |
| `test/data/*.parquet`, `test/data/*.csv`, `test/data/FIXTURES.md` | pinned fixtures and their provenance |
| `test/sql/*.test` | the suites |
| `FINDINGS.md` | what first contact showed |

---

### Task 1: Test runner with executor emulation

**Files:**
- Create: `test/run.py`
- Create: `test/sql/00_smoke.test`
- Create: `sql/.keep` (empty, so the loader has a directory)

**Interfaces:**
- Produces: `python3 test/run.py <paths...> [--mutant FILE]`, exit 0 on success. Rewrites `CALL tree_ddl_create|tree_ddl_drop|tree_ddl_alter|tree_insert|tree_replace|tree_delete|tree_check(<args>)` into `SELECT tree_compile_<verb>(<args>)` and executes each returned statement, rolling back on error if a transaction is open; rewrites every `tree_match(<args>)` occurrence into `(<compiled sql>)` by evaluating `SELECT tree_compile_match(<args>)`.
- Test file dialect: `# comment`, `require <extension>` (skip file if `LOAD` fails), `statement ok`, `statement error` with optional `----` expected-substring lines, `query <letters> [rowsort]` with `----` and tab-separated expected rows; `NULL` for nulls; statements end at a blank line or `----`.

- [ ] **Step 1: Write the smoke test that exercises every directive**

```sql
# name: test/sql/00_smoke.test
# description: runner directives and executor emulation

statement ok
CREATE TABLE t AS SELECT range AS i FROM range(5);

query I
SELECT count(*) FROM t;
----
5

query II rowsort
SELECT i, i * 2 FROM t WHERE i > 2;
----
3	6
4	8

statement error
SELECT * FROM missing_table;
----
does not exist

# executor emulation: a compile macro that returns statements
statement ok
CREATE MACRO tree_compile_check(sch, nm) AS ['BEGIN TRANSACTION', 'CREATE TABLE ' || nm || '(x INT)', 'INSERT INTO ' || nm || ' VALUES (1)', 'COMMIT'];

statement ok
CALL tree_check('main', 'emulated');

query I
SELECT x FROM emulated;
----
1

# a failing compiled statement rolls back the transaction
statement ok
CREATE OR REPLACE MACRO tree_compile_check(sch, nm) AS ['BEGIN TRANSACTION', 'CREATE TABLE ' || nm || '(x INT)', 'SELECT error(''boom'')', 'COMMIT'];

statement error
CALL tree_check('main', 'rolled_back');
----
boom

statement error
SELECT * FROM rolled_back;
----
does not exist

# tree_match rewriting
statement ok
CREATE MACRO tree_compile_match(sch, nm, sel, semantic := NULL) AS 'SELECT i FROM t WHERE i >= ' || sel;

query I rowsort
FROM tree_match('main', 't', 3) SELECT i;
----
3
4
```

- [ ] **Step 2: Run it to verify the runner does not exist yet**

Run: `python3 test/run.py test/sql/00_smoke.test`
Expected: `No such file or directory: test/run.py`

- [ ] **Step 3: Write the runner**

```python
#!/usr/bin/env python3
"""sqllogictest runner for duckent's macro phase.

Loads sql/*.sql into a fresh in-memory DuckDB per test file, then runs the
file. Emulates the executors the C++ extension will provide: CALL tree_ddl_*
and the DML verbs compile to statement lists and are executed; tree_match(...)
is replaced by its compiled query.
"""
import argparse, glob, os, re, sys
import duckdb

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SQL_DIR = os.path.join(ROOT, "sql")
EXEC_VERBS = ("tree_ddl_create", "tree_ddl_drop", "tree_ddl_alter",
              "tree_insert", "tree_replace", "tree_delete", "tree_check")
CALL_RE = re.compile(r"^\s*CALL\s+(" + "|".join(EXEC_VERBS) + r")\s*\((.*)\)\s*;?\s*$", re.S | re.I)


def split_statements(text):
    """Split SQL text on ';' outside quotes, dollar-quotes and comments."""
    out, buf, i, n = [], [], 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("--", i):
            j = text.find("\n", i); j = n if j < 0 else j
            buf.append(text[i:j]); i = j; continue
        if c in ("'", '"'):
            j = i + 1
            while j < n:
                if text[j] == c:
                    if j + 1 < n and text[j + 1] == c: j += 2; continue
                    break
                j += 1
            buf.append(text[i:j + 1]); i = j + 1; continue
        if text.startswith("$$", i):
            j = text.find("$$", i + 2); j = n if j < 0 else j + 2
            buf.append(text[i:j]); i = j; continue
        if c == ";":
            s = "".join(buf).strip()
            if s: out.append(s)
            buf = []; i += 1; continue
        buf.append(c); i += 1
    s = "".join(buf).strip()
    if s: out.append(s)
    return out


def find_call(text, fname):
    """Return (start, end, args) of the first fname(...) with balanced parens, or None."""
    m = re.search(r"\b" + fname + r"\s*\(", text)
    if not m: return None
    depth, i, n = 1, m.end(), len(text)
    quote = None
    while i < n and depth:
        c = text[i]
        if quote:
            if c == quote:
                if i + 1 < n and text[i + 1] == quote: i += 1
                else: quote = None
        elif c in ("'", '"'): quote = c
        elif c == "(": depth += 1
        elif c == ")": depth -= 1
        i += 1
    return (m.start(), i, text[m.end():i - 1])


class Session:
    def __init__(self, mutant=None):
        self.con = duckdb.connect()
        for path in sorted(glob.glob(os.path.join(SQL_DIR, "*.sql"))):
            self.run_script(open(path).read(), path)
        if mutant:
            self.run_script(open(mutant).read(), mutant)
        self.in_txn = False

    def run_script(self, text, label):
        for stmt in split_statements(text):
            try:
                self.con.execute(stmt)
            except Exception as e:
                raise RuntimeError(f"{label}: {e}\n  in: {stmt[:200]}") from e

    def rewrite_match(self, sql):
        while True:
            hit = find_call(sql, "tree_match")
            if not hit: return sql
            start, end, args = hit
            compiled = self.con.execute(f"SELECT tree_compile_match({args})").fetchone()[0]
            sql = sql[:start] + "(" + compiled + ")" + sql[end:]

    def execute(self, sql):
        """Execute one test statement with emulation. Returns a cursor or None."""
        m = CALL_RE.match(sql)
        if m:
            verb, args = m.group(1).lower(), m.group(2)
            stmts = self.con.execute(f"SELECT tree_compile_{verb}({args})").fetchone()[0]
            for s in stmts:
                try:
                    self.con.execute(s)
                    up = s.strip().upper()
                    if up.startswith("BEGIN"): self.in_txn = True
                    if up.startswith("COMMIT") or up.startswith("ROLLBACK"): self.in_txn = False
                except Exception:
                    if self.in_txn:
                        self.con.execute("ROLLBACK"); self.in_txn = False
                    raise
            return None
        return self.con.execute(self.rewrite_match(sql))


def fmt(v):
    if v is None: return "NULL"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, float):
        return str(int(v)) if v == int(v) else repr(v)
    return str(v)


def parse_records(lines):
    """Yield (kind, header, body_lines, expected_lines, lineno)."""
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if not line.strip() or line.startswith("#"):
            i += 1; continue
        header = line.strip(); lineno = i + 1; i += 1
        body, expected = [], []
        while i < n and lines[i].strip() and lines[i].strip() != "----":
            body.append(lines[i]); i += 1
        if i < n and lines[i].strip() == "----":
            i += 1
            while i < n and lines[i].strip():
                expected.append(lines[i].rstrip("\n")); i += 1
        yield header, "\n".join(body), expected, lineno


def run_file(path, mutant=None):
    lines = open(path).read().split("\n")
    sess = None
    failures = []
    for header, body, expected, lineno in parse_records(lines):
        words = header.split()
        if words[0] == "require":
            probe = duckdb.connect()
            try: probe.execute(f"LOAD {words[1]}")
            except Exception:
                print(f"SKIP {path} (require {words[1]})"); return []
            continue
        if sess is None: sess = Session(mutant)
        kind = words[0]
        try:
            if kind == "statement":
                want_error = words[1] == "error"
                try:
                    sess.execute(body)
                    if want_error:
                        failures.append((lineno, "expected error, statement succeeded", body))
                except Exception as e:
                    if not want_error:
                        failures.append((lineno, f"unexpected error: {e}", body))
                    elif expected and not any(exp.strip() in str(e) for exp in expected):
                        failures.append((lineno, f"error text mismatch\n    got: {e}\n    want: {expected}", body))
            elif kind == "query":
                cur = sess.execute(body)
                rows = [[fmt(v) for v in r] for r in cur.fetchall()]
                if "rowsort" in words: rows.sort()
                got = ["\t".join(r) for r in rows]
                if got != expected:
                    failures.append((lineno, f"result mismatch\n    got:  {got}\n    want: {expected}", body))
            else:
                failures.append((lineno, f"unknown directive {header}", body))
        except Exception as e:
            failures.append((lineno, f"runner error: {e}", body))
    for lineno, msg, body in failures:
        print(f"FAIL {path}:{lineno}: {msg}\n    sql: {body[:300]}")
    print(("PASS " if not failures else "FAIL ") + path)
    return failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--mutant", default=None)
    args = ap.parse_args()
    files = []
    for p in args.paths:
        files += sorted(glob.glob(os.path.join(p, "*.test"))) if os.path.isdir(p) else [p]
    total = 0
    for f in files:
        total += len(run_file(f, args.mutant))
    sys.exit(1 if total else 0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Create the empty macro directory and run the smoke test**

Run: `mkdir -p sql && touch sql/.keep && python3 test/run.py test/sql/00_smoke.test`
Expected: `PASS test/sql/00_smoke.test`, exit 0. If `duckdb.connect().execute` rejects the multi-statement macro file later, `split_statements` already splits, so nothing changes.

- [ ] **Step 5: Commit**

```bash
git add test/run.py test/sql/00_smoke.test sql/.keep
git commit -m "test: sqllogictest runner with executor emulation for the macro phase"
```

---

### Task 2: Types and constructors

**Files:**
- Create: `sql/00_types.sql`
- Create: `test/sql/01_types.test`

**Interfaces:**
- Produces: types `TREE_SEMANTIC`, `TREE_SHAPE`, `TREE_SPEC`, `TREE_SELECTOR`; macros `tree_semantic(type, id, classes, attr, attr_map, pseudo)`, `tree_shape(root, "order", key, level, parent, sibling_order, size, children, next, semantic)`, `tree_spec(shape, abstract := false, "like" := NULL, source := NULL, storage := 'materialized')`; helpers `tree_sql_lit(s)`, `tree_sql_ident(s)`, `tree_sql_list(csv)`, `tree_sql_is_ident(s)`.

- [ ] **Step 1: Write the failing test**

```sql
# name: test/sql/01_types.test
# description: TREE_SHAPE family and constructors

query I
SELECT (tree_shape(level := 'depth')).level;
----
depth

query I
SELECT (tree_shape(level := 'depth')).root IS NULL;
----
true

query I
SELECT (tree_shape(level := 'depth', semantic := tree_semantic(type := 'kind'))).semantic.type;
----
kind

query I
SELECT (tree_semantic(pseudo := [{name: 'leaf', body: 'descendant_count = 0'}])).pseudo[1].prefix IS NULL;
----
true

query I
SELECT (tree_spec(tree_shape(level := 'depth'))).storage;
----
materialized

query I
SELECT (tree_spec(tree_shape(level := 'depth'), "like" := 'ast', abstract := true))."like";
----
ast

statement error
SELECT tree_shape(levl := 'depth');
----
levl

query I
SELECT tree_sql_lit('it''s');
----
'it''s'

query I
SELECT tree_sql_ident('a"b');
----
"a""b"

query I
SELECT tree_sql_list(' a , b ');
----
[a, b]

query II
SELECT tree_sql_is_ident('file_path'), tree_sql_is_ident('lower(x)');
----
true	false

query I
SELECT typeof([{node_id: 0, parent_id: NULL, kind: 'selector'}]::TREE_SELECTOR) LIKE 'STRUCT(node_id INTEGER%';
----
true
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/run.py test/sql/01_types.test`
Expected: FAIL with `tree_shape` / `TREE_SELECTOR` not found.

- [ ] **Step 3: Write the types file**

DuckDB has no `CREATE TYPE IF NOT EXISTS`, and the runner uses a fresh database per file, so plain `CREATE TYPE` is correct here. (When these files are loaded into a persistent database later, wrap each in a `DROP TYPE IF EXISTS` first.)

```sql
-- sql/00_types.sql
CREATE TYPE TREE_SEMANTIC AS STRUCT(
  type VARCHAR, id VARCHAR, classes VARCHAR, attr VARCHAR, attr_map VARCHAR,
  pseudo STRUCT(name VARCHAR, body VARCHAR, prefix VARCHAR)[]);

CREATE TYPE TREE_SHAPE AS STRUCT(
  root VARCHAR, "order" VARCHAR, key VARCHAR, level VARCHAR, parent VARCHAR, sibling_order VARCHAR,
  size VARCHAR, children VARCHAR, next VARCHAR,
  semantic TREE_SEMANTIC);

CREATE TYPE TREE_SPEC AS STRUCT(shape TREE_SHAPE, abstract BOOLEAN, "like" VARCHAR, source VARCHAR, storage VARCHAR);

CREATE TYPE TREE_SELECTOR AS STRUCT(
  node_id INTEGER, parent_id INTEGER, kind VARCHAR, value VARCHAR, op VARCHAR, arg VARCHAR, alias VARCHAR)[];

CREATE OR REPLACE MACRO tree_semantic(type := NULL, id := NULL, classes := NULL, attr := NULL, attr_map := NULL, pseudo := NULL) AS
  {type: type, id: id, classes: classes, attr: attr, attr_map: attr_map, pseudo: pseudo}::TREE_SEMANTIC;

CREATE OR REPLACE MACRO tree_shape(root := NULL, "order" := NULL, key := NULL, level := NULL, parent := NULL, sibling_order := NULL,
                                   size := NULL, children := NULL, next := NULL, semantic := NULL) AS
  {root: root, "order": "order", key: key, level: level, parent: parent, sibling_order: sibling_order,
   size: size, children: children, next: next, semantic: semantic}::TREE_SHAPE;

CREATE OR REPLACE MACRO tree_spec(shape, abstract := false, "like" := NULL, source := NULL, storage := 'materialized') AS
  {shape: shape, abstract: abstract, "like": "like", source: source, storage: storage}::TREE_SPEC;

-- string helpers used by every compiler
CREATE OR REPLACE MACRO tree_sql_lit(s) AS '''' || replace(s, '''', '''''') || '''';
CREATE OR REPLACE MACRO tree_sql_ident(s) AS '"' || replace(s, '"', '""') || '"';
CREATE OR REPLACE MACRO tree_sql_list(csv) AS list_transform(string_split(csv, ','), lambda x: trim(x));
CREATE OR REPLACE MACRO tree_sql_is_ident(s) AS regexp_matches(s, '^[A-Za-z_][A-Za-z0-9_]*$');
```

- [ ] **Step 4: Run the test**

Run: `python3 test/run.py test/sql/01_types.test`
Expected: PASS. If the `"like" :=` named parameter is rejected by the parser, rename the field and parameter to `like_tree` in both the type and the constructor and update the spec's §3.1 accordingly.

- [ ] **Step 5: Commit**

```bash
git add sql/00_types.sql test/sql/01_types.test
git commit -m "feat(m0): TREE_SHAPE, TREE_SEMANTIC, TREE_SPEC, TREE_SELECTOR types and constructors"
```

---

### Task 3: Catalog schemas, tables, introspection

**Files:**
- Create: `sql/01_catalog.sql`
- Create: `test/sql/02_catalog.test`

**Interfaces:**
- Produces: schemas `tree_catalog`, `tree_state`; tables `tree_catalog.trees(database_name, schema_name, tree_name, is_abstract, like_tree, source_sql, basis, profile, storage, order_source, has_semantic, description)`, `tree_catalog.slots(database_name, schema_name, tree_name, block, slot, expression)`, `tree_catalog.pseudo_classes(database_name, schema_name, tree_name, name, kind, body, origin, purity)`, `tree_catalog.selector_languages(language, parser, printer, bare_safe)`, `tree_catalog.attachments(child_tree, parent_tree, join_sql)`, `tree_catalog.compiled(database_name, schema_name, tree_name, artifact, object_name, sql_text)`, `tree_state.partitions(database_name, schema_name, tree_name, root_key, epoch, row_count, p13_ok, loaded_at)`, `tree_state.assertions(database_name, schema_name, tree_name, artifact, status, checked_epoch, detail)`; table macros `tree_catalog_trees()`, `tree_catalog_slots()`, `tree_catalog_pseudo_classes()`, `tree_catalog_assertions()`, `tree_catalog_languages()`, `tree_catalog_classes(sch, nm)` (the last is a stub returning zero rows until Task 6 gives it a projection to read).

- [ ] **Step 1: Write the failing test**

```sql
# name: test/sql/02_catalog.test
# description: catalog and state schemas exist and are empty; treeql is registered

query I
SELECT count(*) FROM tree_catalog_trees();
----
0

query I
SELECT count(*) FROM tree_catalog_slots();
----
0

query III
SELECT language, printer, bare_safe FROM tree_catalog_languages();
----
treeql	tree_selector_to_treeql	true

query I
SELECT count(*) FROM tree_state.partitions;
----
0

query I
SELECT column_name FROM information_schema.columns WHERE table_schema = 'tree_catalog' AND table_name = 'trees' AND column_name = 'has_semantic';
----
has_semantic
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/run.py test/sql/02_catalog.test`
Expected: FAIL, `tree_catalog_trees` not found.

- [ ] **Step 3: Write the catalog file**

```sql
-- sql/01_catalog.sql
CREATE SCHEMA IF NOT EXISTS tree_catalog;
CREATE SCHEMA IF NOT EXISTS tree_state;

CREATE TABLE IF NOT EXISTS tree_catalog.trees(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  is_abstract BOOLEAN, like_tree VARCHAR, source_sql VARCHAR,
  basis VARCHAR, profile VARCHAR, storage VARCHAR, order_source VARCHAR,
  has_semantic BOOLEAN, description VARCHAR,
  PRIMARY KEY (database_name, schema_name, tree_name));

CREATE TABLE IF NOT EXISTS tree_catalog.slots(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  block VARCHAR, slot VARCHAR, expression VARCHAR);

CREATE TABLE IF NOT EXISTS tree_catalog.pseudo_classes(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  name VARCHAR, kind VARCHAR, body VARCHAR, origin VARCHAR, purity VARCHAR);

CREATE TABLE IF NOT EXISTS tree_catalog.selector_languages(
  language VARCHAR PRIMARY KEY, parser VARCHAR, printer VARCHAR, bare_safe BOOLEAN);
INSERT INTO tree_catalog.selector_languages VALUES ('treeql', NULL, 'tree_selector_to_treeql', true) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS tree_catalog.attachments(child_tree VARCHAR, parent_tree VARCHAR, join_sql VARCHAR);

CREATE TABLE IF NOT EXISTS tree_catalog.compiled(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  artifact VARCHAR, object_name VARCHAR, sql_text VARCHAR);

CREATE TABLE IF NOT EXISTS tree_state.partitions(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  root_key VARCHAR, epoch INTEGER, row_count BIGINT, p13_ok BOOLEAN, loaded_at TIMESTAMP);

CREATE TABLE IF NOT EXISTS tree_state.assertions(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  artifact VARCHAR, status VARCHAR, checked_epoch INTEGER, detail VARCHAR);

CREATE OR REPLACE MACRO tree_catalog_trees() AS TABLE SELECT * FROM tree_catalog.trees;
CREATE OR REPLACE MACRO tree_catalog_slots() AS TABLE SELECT * FROM tree_catalog.slots ORDER BY schema_name, tree_name, block, slot;
CREATE OR REPLACE MACRO tree_catalog_pseudo_classes() AS TABLE SELECT * FROM tree_catalog.pseudo_classes;
CREATE OR REPLACE MACRO tree_catalog_assertions() AS TABLE SELECT * FROM tree_state.assertions;
CREATE OR REPLACE MACRO tree_catalog_languages() AS TABLE SELECT * FROM tree_catalog.selector_languages;
-- filled in by Task 6 once projections exist
CREATE OR REPLACE MACRO tree_catalog_classes(sch, nm) AS TABLE SELECT NULL::VARCHAR AS class, 0::BIGINT AS row_count WHERE false;
```

- [ ] **Step 4: Run the test**

Run: `python3 test/run.py test/sql/02_catalog.test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add sql/01_catalog.sql test/sql/02_catalog.test
git commit -m "feat(m0): tree_catalog and tree_state schemas with introspection macros"
```

---

### Task 4: Fixtures

**Files:**
- Create: `test/gen_fixtures.py`
- Create: `test/data/employees.csv`, `test/data/categories.csv`, `test/data/coa.csv`, `test/data/ledger.csv`
- Create: `test/data/app.parquet`, `test/data/scripts.parquet`, `test/data/readme_blocks.parquet` (generated)
- Create: `test/data/FIXTURES.md`
- Create: `test/sql/03_fixtures.test`

**Interfaces:**
- Produces: `read_parquet('test/data/app.parquet')` with sitting_duck's 21 columns for `docs/examples/app.py` (54 rows, `file_path = 'app.py'`); `scripts.parquet` with `file_path` relative to the sitting_duck checkout (multi-tree); `readme_blocks.parquet` from `read_markdown_blocks('README.md')`; CSVs below.

- [ ] **Step 1: Write the hand-written CSVs**

`test/data/employees.csv`:
```csv
email,role,manager_email,hire_date
ada@co,cto,,2019-01-07
bo@co,manager,ada@co,2020-03-02
cy@co,manager,ada@co,2019-06-11
di@co,engineer,bo@co,2021-09-20
ed@co,engineer,bo@co,2020-11-16
fay@co,engineer,cy@co,2022-02-01
gus@co,intern,fay@co,2024-06-03
```

`test/data/categories.csv` (parent basis, no sibling key):
```csv
cat_id,name,parent_id
1,root,
2,tools,1
3,hand tools,2
4,power tools,2
5,garden,1
```

`test/data/coa.csv`:
```csv
account_id,name,parent_id
1,root,
2,opex,1
3,salaries,2
4,travel,2
5,capex,1
6,servers,5
7,airfare,4
```

`test/data/ledger.csv`:
```csv
entry_id,account_id,fy,amount
1,3,2026,120000
2,7,2026,4200
3,6,2026,80000
4,3,2025,110000
5,4,2026,900
```

- [ ] **Step 2: Write the generator**

```python
#!/usr/bin/env python3
"""Regenerate parquet fixtures. Needs sitting_duck and markdown installed. Run from repo root."""
import os, subprocess, duckdb
con = duckdb.connect()
con.execute("LOAD sitting_duck"); con.execute("LOAD markdown")
con.execute("""COPY (SELECT * REPLACE ('app.py' AS file_path) FROM read_ast('docs/examples/app.py'))
               TO 'test/data/app.parquet' (FORMAT PARQUET)""")
sd = os.path.expanduser("~/Projects/sitting_duck")
commit = subprocess.check_output(["git", "-C", sd, "rev-parse", "origin/main"]).decode().strip()
con.execute(f"""COPY (SELECT * REPLACE (replace(file_path, '{sd}/', '') AS file_path)
               FROM read_ast('{sd}/scripts/*.py')) TO 'test/data/scripts.parquet' (FORMAT PARQUET)""")
con.execute("COPY (FROM read_markdown_blocks('README.md')) TO 'test/data/readme_blocks.parquet' (FORMAT PARQUET)")
n_app = con.execute("SELECT count(*) FROM 'test/data/app.parquet'").fetchone()[0]
n_scr, n_files = con.execute("SELECT count(*), count(DISTINCT file_path) FROM 'test/data/scripts.parquet'").fetchone()
n_md = con.execute("SELECT count(*) FROM 'test/data/readme_blocks.parquet'").fetchone()[0]
open("test/data/FIXTURES.md", "w").write(f"""# Fixture provenance

Generated by `python3 test/gen_fixtures.py` with DuckDB {duckdb.__version__}.

| file | source | rows |
|---|---|---|
| app.parquet | sitting_duck `read_ast('docs/examples/app.py')` | {n_app} |
| scripts.parquet | sitting_duck `read_ast` over `sitting_duck/scripts/*.py` at commit `{commit}` | {n_scr} rows, {n_files} files |
| readme_blocks.parquet | markdown `read_markdown_blocks('README.md')` | {n_md} |
| employees.csv, categories.csv, coa.csv, ledger.csv | hand-written | see files |

Regenerating changes row counts if the sources changed; update the tests deliberately, never silently.
""")
print("ok", n_app, n_scr, n_files, n_md)
```

- [ ] **Step 3: Generate and write the fixture test**

Run: `python3 test/gen_fixtures.py`
Expected: prints `ok 54 <N> <F> <M>`. Put `<N>`, `<F>`, `<M>` into the test below in place of the placeholders shown as `N`, `F`, `M`; those are the only values the executor fills in from the generator's output.

```sql
# name: test/sql/03_fixtures.test
# description: pinned fixtures load with the expected shape

query II
SELECT count(*), max(node_id) FROM 'test/data/app.parquet';
----
54	53

query I
SELECT count(DISTINCT file_path) FROM 'test/data/scripts.parquet';
----
F

query I
SELECT count(*) FROM 'test/data/readme_blocks.parquet' WHERE kind = 'block' AND element_type = 'heading' AND content = 'duckent';
----
1

query I
SELECT count(*) FROM 'test/data/employees.csv';
----
7

query I
SELECT count(*) FROM 'test/data/categories.csv' WHERE parent_id IS NULL;
----
1
```

- [ ] **Step 4: Run the test**

Run: `python3 test/run.py test/sql/03_fixtures.test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/gen_fixtures.py test/data test/sql/03_fixtures.test
git commit -m "test: pinned fixtures (app, scripts, readme blocks, adjacency lists) and generator"
```

---

### Task 5: Projection compiler

**Files:**
- Create: `sql/02_projection.sql`
- Create: `test/sql/10_projection.test`

**Interfaces:**
- Consumes: `TREE_SHAPE`, `tree_sql_lit`, `tree_sql_ident`, `tree_sql_list`, `tree_sql_is_ident`.
- Produces: fragment macros `tree_sql_root(root_csv, qual)`, `tree_sql_pseudo_map(sem)`, `tree_sql_parent_join()`, `tree_sql_size_expr()`, `tree_sql_children_expr()`, `tree_sql_encoder_tiebreak()`; `tree_compile_projection(shape, source, attr_text) -> VARCHAR` returning one SELECT statement that emits the canonical columns plus attributes. `attr_text` is the effective ATTR list: `'*'` open, `''` closed, or a select list. The fragment macros exist so mutants can override one piece.

- [ ] **Step 1: Write the failing test**

The compile macro has no subqueries over tables, so `query()` can run its output directly.

```sql
# name: test/sql/10_projection.test
# description: projection compiler emits canonical columns; derivations equal sitting_duck's native columns

# level basis, ORDER declared, no O declared: derived _parent and _size must equal native columns
query III
WITH p AS (FROM query(tree_compile_projection(tree_shape(root := 'file_path', "order" := 'node_id', level := 'depth'), 'read_parquet(''test/data/app.parquet'')', '*')))
SELECT count(*),
       count(*) FILTER (WHERE _parent IS DISTINCT FROM parent_id),
       count(*) FILTER (WHERE _size <> descendant_count)
FROM p;
----
54	0	0

# _children equals native children_count, _next is pre + size + 1, _type defaults to 'node'
query III
WITH p AS (FROM query(tree_compile_projection(tree_shape("order" := 'node_id', level := 'depth'), 'read_parquet(''test/data/app.parquet'')', '*')))
SELECT count(*) FILTER (WHERE _children <> children_count), count(*) FILTER (WHERE _next <> _pre + _size + 1), min(_type) FROM p;
----
0	0	node

# declared O columns are used verbatim; TYPE, ID, pseudo map compile
query IIII
WITH p AS (FROM query(tree_compile_projection(
  tree_shape(root := 'file_path', "order" := 'node_id', level := 'depth', parent := 'parent_id', size := 'descendant_count', children := 'children_count',
             semantic := tree_semantic(type := 'type', id := 'name', pseudo := [{name: 'leaf', body: 'descendant_count = 0'}])),
  'read_parquet(''test/data/app.parquet'')', 'name, start_line')))
SELECT _type, _id, _pseudo['leaf'], start_line FROM p WHERE _pre = 6;
----
function_definition	greet	false	4

# closed attribute list: no source columns survive
query I
WITH p AS (FROM query(tree_compile_projection(tree_shape("order" := 'node_id', level := 'depth'), 'read_parquet(''test/data/app.parquet'')', '')))
SELECT count(*) FROM (DESCRIBE FROM p) WHERE column_name NOT LIKE '\_%' ESCAPE '\';
----
0

# frozen order: no ORDER, pre derived from scan order within root
query II
WITH p AS (FROM query(tree_compile_projection(tree_shape(root := 'file_path', level := 'depth'), 'read_parquet(''test/data/app.parquet'')', '*')))
SELECT min(_pre), count(*) FILTER (WHERE _pre <> node_id) FROM p;
----
0	0

# parent basis: encoder yields pre-order by sibling key, level from depth of chain
query IIII
WITH p AS (FROM query(tree_compile_projection(tree_shape(key := 'email', parent := 'manager_email', sibling_order := 'hire_date',
             semantic := tree_semantic(type := 'role', id := 'email')), 'read_csv(''test/data/employees.csv'')', '*')))
SELECT _pre, _level, _id, _parent FROM p ORDER BY _pre LIMIT 4;
----
0	0	ada@co	NULL
1	1	cy@co	0
2	2	fay@co	1
3	3	gus@co	2

# parent basis sizes: cto has 6 descendants, bo has 2
query II
WITH p AS (FROM query(tree_compile_projection(tree_shape(key := 'email', parent := 'manager_email', sibling_order := 'hire_date'), 'read_csv(''test/data/employees.csv'')', '*')))
SELECT (SELECT _size FROM p WHERE email = 'ada@co'), (SELECT _size FROM p WHERE email = 'bo@co');
----
6	2
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/run.py test/sql/10_projection.test`
Expected: FAIL, `tree_compile_projection` not found.

- [ ] **Step 3: Write the projection compiler**

```sql
-- sql/02_projection.sql
-- Fragment macros. Each returns SQL text. Mutants override exactly one of these.

-- ROOT struct literal: fields named after the columns when they are identifiers, r<i> otherwise; {r0: 0} when absent.
CREATE OR REPLACE MACRO tree_sql_root(root_csv, qual) AS
  CASE WHEN root_csv IS NULL THEN '{r0: 0}'
       ELSE '{' || list_aggregate(list_transform(tree_sql_list(root_csv),
              lambda x, i: (CASE WHEN tree_sql_is_ident(x) THEN x ELSE 'r' || i END) || ': ' || qual || x), 'string_agg', ', ') || '}' END;

-- MAP(VARCHAR, BOOLEAN) of expression-bodied pseudo-classes.
CREATE OR REPLACE MACRO tree_sql_pseudo_map(sem) AS
  CASE WHEN sem IS NULL OR sem.pseudo IS NULL OR len(list_filter(sem.pseudo, lambda p: p.name IS NOT NULL)) = 0
       THEN 'MAP([]::VARCHAR[], []::BOOLEAN[])'
       ELSE 'MAP([' || list_aggregate(list_transform(list_filter(sem.pseudo, lambda p: p.name IS NOT NULL), lambda p: tree_sql_lit(p.name)), 'string_agg', ', ')
            || '], [' || list_aggregate(list_transform(list_filter(sem.pseudo, lambda p: p.name IS NOT NULL), lambda p: '(' || p.body || ')'), 'string_agg', ', ')
            || '])::MAP(VARCHAR, BOOLEAN)' END;

-- Derived parent for level basis: nearest prior row at level - 1 within the root (ASOF join). MN2 mutates this.
CREATE OR REPLACE MACRO tree_sql_parent_join() AS
  '__p AS (SELECT a.*, b._pre AS _parent FROM __r a ASOF LEFT JOIN __r b ON a._root = b._root AND b._level = a._level - 1 AND b._pre < a._pre), ';

-- Derived size: distance to the next row at the same or higher level within the root. Quadratic; the C++ port replaces it with a stack walk.
CREATE OR REPLACE MACRO tree_sql_size_expr() AS
  'COALESCE((SELECT min(b._pre) FROM __p b WHERE b._root = a._root AND b._pre > a._pre AND b._level <= a._level), max(a._pre) OVER (PARTITION BY a._root) + 1) - a._pre - 1';

CREATE OR REPLACE MACRO tree_sql_children_expr() AS
  '(SELECT count(*) FROM __s b WHERE b._root = a._root AND b._parent = a._pre)';

-- Encoder tiebreak after the sibling key: source order of the key. MN1 mutates this to DESC.
CREATE OR REPLACE MACRO tree_sql_encoder_tiebreak() AS 'ASC';

CREATE OR REPLACE MACRO tree_compile_projection(shape, source, attr_text) AS (
WITH cfg AS (
  SELECT
    shape.level IS NOT NULL AS level_basis,
    shape.parent IS NOT NULL AS has_parent,
    tree_sql_root(shape.root, '') AS root_sql,
    tree_sql_root(shape.root, 'c.') AS root_sql_c,
    CASE WHEN attr_text = '' THEN '' ELSE attr_text || ', ' END AS attrs,
    CASE WHEN attr_text = '' THEN '' WHEN attr_text = '*' THEN 's.*, ' ELSE attr_text || ', ' END AS attrs_s,
    tree_sql_pseudo_map(shape.semantic) AS pseudo_sql,
    COALESCE(shape.semantic.type, '''node''') AS type_sql,
    COALESCE(shape.semantic.id, 'NULL::VARCHAR') AS id_sql,
    COALESCE(shape.semantic.classes, 'NULL::VARCHAR[]') AS classes_sql,
    COALESCE(shape.semantic.attr_map, 'NULL') AS attr_map_sql,
    COALESCE(shape.sibling_order || ', ', '') AS sib,
    COALESCE(list_aggregate(list_transform(tree_sql_list(shape.sibling_order), lambda x: 'c.' || x), 'string_agg', ', ') || ', ', '') AS sib_c,
    tree_sql_encoder_tiebreak() AS tiebreak
),
sem_cols AS (
  SELECT type_sql || ' AS _type, ' || id_sql || ' AS _id, ' || classes_sql || ' AS _classes, ' || attr_map_sql || ' AS _attr_map, ' || pseudo_sql || ' AS _pseudo' AS cols FROM cfg
),
lvl AS (
  SELECT 'WITH __src AS (SELECT * FROM ' || source || '), '
      || '__r AS (SELECT ' || attrs || root_sql || ' AS _root, CAST('
      || COALESCE(shape."order", 'row_number() OVER (PARTITION BY ' || root_sql || ') - 1')
      || ' AS BIGINT) AS _pre, CAST(' || shape.level || ' AS BIGINT) AS _level, ' || (SELECT cols FROM sem_cols) || ' FROM __src), '
      || CASE WHEN has_parent THEN '__p AS (SELECT a.*, CAST(a.' || shape.parent || ' AS BIGINT) AS _parent FROM __r a), '
              ELSE tree_sql_parent_join() END AS head
  FROM cfg),
par AS (
  SELECT 'WITH RECURSIVE __src AS (SELECT * FROM ' || source || '), '
      || '__walk USING KEY (__key) AS (SELECT ' || root_sql || ' AS _root, ' || shape.key || ' AS __key, 0 AS _level, '
      || '[row_number() OVER (PARTITION BY ' || root_sql || ' ORDER BY ' || sib || shape.key || ' ' || tiebreak || ')] AS __path '
      || 'FROM __src WHERE ' || shape.parent || ' IS NULL '
      || 'UNION ALL SELECT ' || root_sql_c || ' AS _root, c.' || shape.key || ', w._level + 1, '
      || 'w.__path || [row_number() OVER (PARTITION BY c.' || shape.parent || ' ORDER BY ' || sib_c || 'c.' || shape.key || ' ' || tiebreak || ')] '
      || 'FROM __src c JOIN __walk w ON c.' || shape.parent || ' = w.__key), '
      || '__r0 AS (SELECT ' || attrs_s || 'w._root, CAST(row_number() OVER (PARTITION BY w._root ORDER BY w.__path) - 1 AS BIGINT) AS _pre, '
      || 'CAST(w._level AS BIGINT) AS _level, s.' || shape.key || ' AS __key, s.' || shape.parent || ' AS __pkey, ' || (SELECT cols FROM sem_cols)
      || ' FROM __src s JOIN __walk w ON s.' || shape.key || ' = w.__key), '
      || '__p AS (SELECT a.* EXCLUDE (__key, __pkey), b._pre AS _parent FROM __r0 a LEFT JOIN __r0 b ON b.__key = a.__pkey AND b._root = a._root), ' AS head
  FROM cfg)
SELECT (CASE WHEN level_basis THEN (SELECT head FROM lvl) ELSE (SELECT head FROM par) END)
    || '__s AS (SELECT a.*, ' || COALESCE('CAST(a.' || shape.size || ' AS BIGINT)', tree_sql_size_expr()) || ' AS _size FROM __p a), '
    || '__c AS (SELECT a.*, ' || COALESCE('CAST(a.' || shape.children || ' AS BIGINT)', tree_sql_children_expr()) || ' AS _children, '
    || COALESCE('CAST(a.' || shape.next || ' AS BIGINT)', 'a._pre + a._size + 1') || ' AS _next FROM __s a) '
    || 'SELECT * FROM __c'
FROM cfg);
```

- [ ] **Step 4: Run the test**

Run: `python3 test/run.py test/sql/10_projection.test`
Expected: PASS. If `query()` complains that the argument is not constant, the compile macro has acquired a table subquery; keep it pure. If the pseudo-map row reads `true` for `_pre = 6`, the `leaf` body is being applied to the wrong row: check that `_pre` is cast from `node_id`.

- [ ] **Step 5: Commit**

```bash
git add sql/02_projection.sql test/sql/10_projection.test
git commit -m "feat(m0): projection compiler with derived parent, size, children, next and the parent-basis encoder"
```

---

### Task 6: Create, drop, alter, project

**Files:**
- Create: `sql/03_ddl.sql`
- Modify: `sql/01_catalog.sql` (replace the `tree_catalog_classes` stub)
- Create: `test/sql/11_ddl.test`

**Interfaces:**
- Consumes: catalog tables, `tree_compile_projection`, `TREE_SPEC`.
- Produces: `tree_shape_from_catalog(db, sch, nm) -> TREE_SHAPE` (NULL when absent), `tree_shape_merge(parent, child) -> TREE_SHAPE`, `tree_compile_create(sch, nm, spec) -> VARCHAR[]`, `tree_compile_drop(sch, nm) -> VARCHAR[]`, `tree_compile_alter(sch, nm, semantic) -> VARCHAR[]`, table macro `tree_project(sch, nm)`, table macro `tree_apply(shape, source)`, and the real `tree_catalog_classes(sch, nm)`. The runner turns `CALL tree_ddl_create(sch, nm, spec)` into `tree_compile_create` and executes the list.

- [ ] **Step 1: Write the failing test**

```sql
# name: test/sql/11_ddl.test
# description: create, LIKE, SHAPE ONLY, storage modes, refusals, drop, alter

# materialized concrete tree over the app fixture
statement ok
CALL tree_ddl_create('main', 'app', tree_spec(
  tree_shape(root := 'file_path', "order" := 'node_id', level := 'depth', size := 'descendant_count',
             semantic := tree_semantic(type := 'type', id := 'name', pseudo := [{name: 'leaf', body: 'descendant_count = 0'}])),
  source := 'read_parquet(''test/data/app.parquet'')'));

query IIIIII
SELECT is_abstract, basis, profile, storage, order_source, has_semantic FROM tree_catalog_trees() WHERE tree_name = 'app';
----
false	level	full	materialized	declared	true

query II rowsort
SELECT block, slot FROM tree_catalog_slots() WHERE tree_name = 'app';
----
O	SIZE
R	LEVEL
R	ORDER
R	ROOT
S	ATTR
S	ID
S	TYPE

query I
SELECT expression FROM tree_catalog_slots() WHERE tree_name = 'app' AND slot = 'ATTR';
----
*

query II
SELECT count(*), max(_pre) FROM tree_project('main', 'app');
----
54	53

query III
SELECT root_key, epoch, row_count FROM tree_state.partitions WHERE tree_name = 'app';
----
{'file_path': app.py}	1	54

query I
SELECT artifact FROM tree_catalog.compiled WHERE tree_name = 'app';
----
projection

# classes introspection is empty for a tree without CLASSES
query I
SELECT count(*) FROM tree_catalog_classes('main', 'app');
----
0

# duplicate name refused
statement error
CALL tree_ddl_create('main', 'app', tree_spec(tree_shape(level := 'depth'), source := 'read_parquet(''test/data/app.parquet'')'));
----
already exists

# abstract shape, closed by default
statement ok
CALL tree_ddl_create('main', 'ast_shape', tree_spec(tree_shape(root := 'file_path', "order" := 'node_id', level := 'depth', semantic := tree_semantic(type := 'type')), abstract := true));

query II
SELECT is_abstract, (SELECT expression FROM tree_catalog_slots() s WHERE s.tree_name = 'ast_shape' AND slot = 'ATTR') FROM tree_catalog_trees() WHERE tree_name = 'ast_shape';
----
true	(empty)

# abstract with a source refused; concrete without a source refused
statement error
CALL tree_ddl_create('main', 'bad1', tree_spec(tree_shape(level := 'depth'), abstract := true, source := 'read_parquet(''test/data/app.parquet'')'));
----
SHAPE ONLY

statement error
CALL tree_ddl_create('main', 'bad2', tree_spec(tree_shape(level := 'depth')));
----
SHAPE ONLY

# LIKE copies semantics, never source; instance stays closed
statement ok
CALL tree_ddl_create('main', 'code', tree_spec(tree_shape(), "like" := 'ast_shape', source := 'read_parquet(''test/data/app.parquet'')', storage := 'projection'));

query III
SELECT like_tree, storage, (SELECT expression FROM tree_catalog_slots() s WHERE s.tree_name = 'code' AND slot = 'TYPE') FROM tree_catalog_trees() WHERE tree_name = 'code';
----
ast_shape	projection	type

query I
SELECT count(*) FROM (DESCRIBE FROM tree_project('main', 'code')) WHERE column_name = 'peek';
----
0

# LIKE of an unknown tree refused, naming it
statement error
CALL tree_ddl_create('main', 'bad3', tree_spec(tree_shape(), "like" := 'nope', source := 'read_parquet(''test/data/app.parquet'')'));
----
nope

# R2: LEVEL or PARENT required
statement error
CALL tree_ddl_create('main', 'bad4', tree_spec(tree_shape("order" := 'node_id'), source := 'read_parquet(''test/data/app.parquet'')'));
----
LEVEL or PARENT

# parent basis requires KEY
statement error
CALL tree_ddl_create('main', 'bad5', tree_spec(tree_shape(parent := 'manager_email'), source := 'read_csv(''test/data/employees.csv'')'));
----
KEY

# projection mode requires ORDER
statement error
CALL tree_ddl_create('main', 'bad6', tree_spec(tree_shape(level := 'depth'), source := 'read_parquet(''test/data/app.parquet'')', storage := 'projection'));
----
ORDER

# ATTR alias colliding with the canonical prefix refused
statement error
CALL tree_ddl_create('main', 'bad7', tree_spec(tree_shape("order" := 'node_id', level := 'depth', semantic := tree_semantic(attr := 'name AS _pre')), source := 'read_parquet(''test/data/app.parquet'')'));
----
_pre

# duplicate pseudo names refused (S-coherence)
statement error
CALL tree_ddl_create('main', 'bad8', tree_spec(tree_shape("order" := 'node_id', level := 'depth', semantic := tree_semantic(pseudo := [{name: 'x', body: 'true'}, {name: 'x', body: 'false'}])), source := 'read_parquet(''test/data/app.parquet'')'));
----
S-coherence

# parent basis, sibling-free profile recorded
statement ok
CALL tree_ddl_create('main', 'cats', tree_spec(tree_shape(key := 'cat_id', parent := 'parent_id'), source := 'read_csv(''test/data/categories.csv'')'));

query II
SELECT basis, profile FROM tree_catalog_trees() WHERE tree_name = 'cats';
----
parent	sibling_free

# R-only tree: no SEMANTIC group, type defaults to node
statement ok
CALL tree_ddl_create('main', 'bare', tree_spec(tree_shape("order" := 'node_id', level := 'depth'), source := 'read_parquet(''test/data/app.parquet'')'));

query II
SELECT has_semantic, (SELECT min(_type) FROM tree_project('main', 'bare')) FROM tree_catalog_trees() WHERE tree_name = 'bare';
----
false	node

# alter adds the SEMANTIC group later and rebuilds
statement ok
CALL tree_ddl_alter('main', 'bare', tree_semantic(type := 'type', classes := '[type]'));

query II
SELECT has_semantic, (SELECT _type FROM tree_project('main', 'bare') WHERE _pre = 6) FROM tree_catalog_trees() WHERE tree_name = 'bare';
----
true	function_definition

query II
SELECT class, row_count FROM tree_catalog_classes('main', 'bare') WHERE class = 'function_definition';
----
function_definition	2

# ad hoc application of a shape to a bare source
query I
SELECT count(*) FROM tree_apply(tree_shape("order" := 'node_id', level := 'depth'), 'read_parquet(''test/data/app.parquet'')');
----
54

# drop removes everything
statement ok
CALL tree_ddl_drop('main', 'app');

query III
SELECT (SELECT count(*) FROM tree_catalog_trees() WHERE tree_name = 'app'), (SELECT count(*) FROM tree_catalog_slots() WHERE tree_name = 'app'), (SELECT count(*) FROM tree_state.partitions WHERE tree_name = 'app');
----
0	0	0

statement error
SELECT * FROM tree_project('main', 'app');
----
proj_main_app
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/run.py test/sql/11_ddl.test`
Expected: FAIL, `tree_compile_create` not found.

- [ ] **Step 3: Write the DDL compilers**

```sql
-- sql/03_ddl.sql

-- Rebuild a TREE_SHAPE from catalog rows. NULL when the tree does not exist.
CREATE OR REPLACE MACRO tree_shape_from_catalog(db, sch, nm) AS (
  SELECT CASE WHEN count(*) = 0 THEN NULL ELSE {
    root: max(expression) FILTER (WHERE slot = 'ROOT'),
    "order": max(expression) FILTER (WHERE slot = 'ORDER'),
    key: max(expression) FILTER (WHERE slot = 'KEY'),
    level: max(expression) FILTER (WHERE slot = 'LEVEL'),
    parent: max(expression) FILTER (WHERE slot = 'PARENT'),
    sibling_order: max(expression) FILTER (WHERE slot = 'SIBLING_ORDER'),
    size: max(expression) FILTER (WHERE slot = 'SIZE'),
    children: max(expression) FILTER (WHERE slot = 'CHILDREN'),
    next: max(expression) FILTER (WHERE slot = 'NEXT'),
    semantic: {
      type: max(expression) FILTER (WHERE slot = 'TYPE'),
      id: max(expression) FILTER (WHERE slot = 'ID'),
      classes: max(expression) FILTER (WHERE slot = 'CLASSES'),
      attr: max(expression) FILTER (WHERE slot = 'ATTR'),
      attr_map: max(expression) FILTER (WHERE slot = 'ATTR_MAP'),
      pseudo: (SELECT list({name: name, body: body, prefix: NULL::VARCHAR} ORDER BY name)
               FROM tree_catalog.pseudo_classes p WHERE p.database_name = db AND p.schema_name = sch AND p.tree_name = nm)
    }::TREE_SEMANTIC }::TREE_SHAPE END
  FROM tree_catalog.slots WHERE database_name = db AND schema_name = sch AND tree_name = nm);

-- Child fields win; pseudo lists union with the child shadowing by name.
CREATE OR REPLACE MACRO tree_shape_merge(p, c) AS
  CASE WHEN p IS NULL THEN c ELSE {
    root: COALESCE(c.root, p.root), "order": COALESCE(c."order", p."order"), key: COALESCE(c.key, p.key),
    level: COALESCE(c.level, p.level), parent: COALESCE(c.parent, p.parent), sibling_order: COALESCE(c.sibling_order, p.sibling_order),
    size: COALESCE(c.size, p.size), children: COALESCE(c.children, p.children), next: COALESCE(c.next, p.next),
    semantic: {
      type: COALESCE(c.semantic.type, p.semantic.type), id: COALESCE(c.semantic.id, p.semantic.id),
      classes: COALESCE(c.semantic.classes, p.semantic.classes), attr: COALESCE(c.semantic.attr, p.semantic.attr),
      attr_map: COALESCE(c.semantic.attr_map, p.semantic.attr_map),
      pseudo: list_concat(
        list_filter(COALESCE(p.semantic.pseudo, []), lambda x: NOT list_contains(list_transform(COALESCE(c.semantic.pseudo, []), lambda y: y.name), x.name)),
        COALESCE(c.semantic.pseudo, []))
    }::TREE_SEMANTIC }::TREE_SHAPE END;

CREATE OR REPLACE MACRO tree_compile_create(sch, nm, spec) AS (
WITH base AS (
  SELECT current_database() AS db,
         tree_shape_merge(CASE WHEN spec."like" IS NULL THEN NULL ELSE tree_shape_from_catalog(current_database(), sch, spec."like") END, spec.shape) AS shape,
         spec."like" IS NOT NULL AND tree_shape_from_catalog(current_database(), sch, spec."like") IS NULL AS like_missing,
         EXISTS (SELECT 1 FROM tree_catalog.trees t WHERE t.database_name = current_database() AND t.schema_name = sch AND t.tree_name = nm) AS exists_already,
         spec.abstract AS abstract, spec.source AS source, spec.storage AS storage
),
derived AS (
  SELECT *,
    shape.level IS NOT NULL AS level_basis,
    CASE WHEN shape.level IS NOT NULL THEN 'level' ELSE 'parent' END AS basis,
    CASE WHEN shape.level IS NULL AND shape.sibling_order IS NULL THEN 'sibling_free' ELSE 'full' END AS profile,
    CASE WHEN shape.level IS NULL OR shape."order" IS NOT NULL THEN 'declared' ELSE 'frozen' END AS order_source,
    COALESCE(shape.semantic.attr, CASE WHEN abstract THEN '' ELSE '*' END) AS attr_text,
    spec.shape.semantic IS NOT NULL OR (spec."like" IS NOT NULL AND tree_shape_from_catalog(current_database(), sch, spec."like").semantic.type IS NOT NULL) AS has_semantic,
    'tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm) AS proj_name,
    'tree_catalog.' || tree_sql_ident('t_' || sch || '_' || nm) AS tbl_name
  FROM base
),
checked AS (
  SELECT *,
    CASE
      WHEN exists_already THEN error('tree_ddl_create: tree ' || sch || '.' || nm || ' already exists')
      WHEN like_missing THEN error('tree_ddl_create: LIKE target ' || sch || '.' || spec."like" || ' not found')
      WHEN abstract AND source IS NOT NULL THEN error('tree_ddl_create: a SHAPE ONLY (abstract) tree cannot have a source')
      WHEN NOT abstract AND source IS NULL THEN error('tree_ddl_create: no source given; declare abstract := true (SHAPE ONLY) or pass source')
      WHEN storage NOT IN ('materialized', 'projection') THEN error('tree_ddl_create: storage must be materialized or projection')
      WHEN shape.level IS NULL AND shape.parent IS NULL THEN error('tree_ddl_create: declare LEVEL or PARENT (R2)')
      WHEN shape.level IS NULL AND shape.key IS NULL THEN error('tree_ddl_create: PARENT basis requires KEY (the column PARENT refers to)')
      WHEN shape.level IS NULL AND NOT (tree_sql_is_ident(shape.key) AND tree_sql_is_ident(shape.parent)) THEN error('tree_ddl_create: PARENT basis needs KEY and PARENT to be plain column names')
      WHEN NOT abstract AND storage = 'projection' AND level_basis AND shape."order" IS NULL THEN error('tree_ddl_create: ORDER is required for projection-mode trees (the source is not frozen)')
      WHEN NOT abstract AND order_source = 'frozen' AND NOT current_setting('preserve_insertion_order') THEN error('tree_ddl_create: ORDER is required because preserve_insertion_order is off')
      WHEN regexp_matches(attr_text, '(?i)\bAS\s+"?_') THEN error('tree_ddl_create: ATTR alias collides with the canonical prefix: ' || regexp_extract(attr_text, '(?i)\bAS\s+("?_[A-Za-z0-9_]*)', 1))
      WHEN len(list_distinct(list_transform(COALESCE(shape.semantic.pseudo, []), lambda x: x.name))) <> len(COALESCE(shape.semantic.pseudo, [])) THEN error('tree_ddl_create: S-coherence: a pseudo-class is bound twice')
      ELSE true END AS ok,
    CASE WHEN abstract THEN NULL ELSE tree_compile_projection(shape, source, attr_text) END AS proj_sql
  FROM derived
),
slot_rows AS (
  SELECT list_filter([
    {b: 'R', s: 'ROOT', e: shape.root}, {b: 'R', s: 'ORDER', e: shape."order"}, {b: 'R', s: 'KEY', e: shape.key},
    {b: 'R', s: 'LEVEL', e: shape.level}, {b: CASE WHEN level_basis THEN 'O' ELSE 'R' END, s: 'PARENT', e: shape.parent},
    {b: 'R', s: 'SIBLING_ORDER', e: shape.sibling_order},
    {b: 'S', s: 'TYPE', e: shape.semantic.type}, {b: 'S', s: 'ID', e: shape.semantic.id}, {b: 'S', s: 'CLASSES', e: shape.semantic.classes},
    {b: 'S', s: 'ATTR', e: attr_text}, {b: 'S', s: 'ATTR_MAP', e: shape.semantic.attr_map},
    {b: 'O', s: 'SIZE', e: shape.size}, {b: 'O', s: 'CHILDREN', e: shape.children}, {b: 'O', s: 'NEXT', e: shape.next}
  ], lambda x: x.e IS NOT NULL) AS rows, * FROM checked
)
SELECT list_filter(
  ['BEGIN TRANSACTION',
   'INSERT INTO tree_catalog.trees VALUES (' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || abstract || ', '
     || COALESCE(tree_sql_lit(spec."like"), 'NULL') || ', ' || COALESCE(tree_sql_lit(source), 'NULL') || ', ' || tree_sql_lit(basis) || ', ' || tree_sql_lit(profile) || ', '
     || tree_sql_lit(storage) || ', ' || tree_sql_lit(order_source) || ', ' || has_semantic || ', NULL)',
   'INSERT INTO tree_catalog.slots VALUES ' || list_aggregate(list_transform(rows, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit(x.b) || ', ' || tree_sql_lit(x.s) || ', ' || tree_sql_lit(x.e) || ')'), 'string_agg', ', '),
   CASE WHEN len(COALESCE(shape.semantic.pseudo, [])) = 0 THEN NULL ELSE
   'INSERT INTO tree_catalog.pseudo_classes VALUES ' || list_aggregate(list_transform(shape.semantic.pseudo, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit(x.name) || ', ''expression'', ' || tree_sql_lit(x.body) || ', ''local'', ''unknown'')'), 'string_agg', ', ') END,
   CASE WHEN abstract THEN NULL ELSE tree_compile_p13('(' || proj_sql || ')', sch || '.' || nm, shape.root IS NOT NULL) END,
   CASE WHEN abstract OR storage <> 'materialized' THEN NULL ELSE 'CREATE TABLE ' || tbl_name || ' AS ' || proj_sql END,
   CASE WHEN abstract THEN NULL WHEN storage = 'materialized' THEN 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE SELECT * FROM ' || tbl_name
        ELSE 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE ' || proj_sql END,
   CASE WHEN abstract OR storage <> 'materialized' THEN NULL ELSE
     'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', _root::VARCHAR, 1, count(*), true, now() FROM ' || tbl_name || ' GROUP BY _root' END,
   CASE WHEN abstract THEN NULL ELSE 'INSERT INTO tree_catalog.compiled VALUES (' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ''projection'', ' || tree_sql_lit(proj_name) || ', ' || tree_sql_lit(proj_sql) || ')' END,
   'COMMIT'], lambda x: x IS NOT NULL)
FROM slot_rows WHERE ok);

CREATE OR REPLACE MACRO tree_compile_drop(sch, nm) AS (
  SELECT ['BEGIN TRANSACTION',
    'DELETE FROM tree_catalog.trees WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.slots WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.pseudo_classes WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.compiled WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_state.partitions WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_state.assertions WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DROP MACRO TABLE IF EXISTS tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm),
    'DROP TABLE IF EXISTS tree_catalog.' || tree_sql_ident('t_' || sch || '_' || nm),
    'COMMIT']);

-- Replace the SEMANTIC group and rebuild the projection (and storage, when materialized).
CREATE OR REPLACE MACRO tree_compile_alter(sch, nm, semantic) AS (
WITH t AS (
  SELECT current_database() AS db, tr.storage, tr.source_sql, tr.is_abstract,
         tree_shape_from_catalog(current_database(), sch, nm) AS old_shape
  FROM tree_catalog.trees tr WHERE tr.database_name = current_database() AND tr.schema_name = sch AND tr.tree_name = nm
),
n AS (
  SELECT *,
    {root: old_shape.root, "order": old_shape."order", key: old_shape.key, level: old_shape.level, parent: old_shape.parent, sibling_order: old_shape.sibling_order,
     size: old_shape.size, children: old_shape.children, next: old_shape.next, semantic: semantic}::TREE_SHAPE AS shape,
    COALESCE(semantic.attr, CASE WHEN is_abstract THEN '' ELSE '*' END) AS attr_text,
    'tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm) AS proj_name,
    'tree_catalog.' || tree_sql_ident('t_' || sch || '_' || nm) AS tbl_name
  FROM t
),
c AS (
  SELECT *, CASE WHEN is_abstract THEN NULL ELSE tree_compile_projection(shape, source_sql, attr_text) END AS proj_sql,
    list_filter([
      {b: 'S', s: 'TYPE', e: semantic.type}, {b: 'S', s: 'ID', e: semantic.id}, {b: 'S', s: 'CLASSES', e: semantic.classes},
      {b: 'S', s: 'ATTR', e: attr_text}, {b: 'S', s: 'ATTR_MAP', e: semantic.attr_map}], lambda x: x.e IS NOT NULL) AS rows
  FROM n
)
SELECT CASE WHEN (SELECT count(*) FROM t) = 0 THEN error('tree_ddl_alter: tree ' || sch || '.' || nm || ' not found') ELSE
  list_filter(['BEGIN TRANSACTION',
   'DELETE FROM tree_catalog.slots WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND block = ''S''',
   'DELETE FROM tree_catalog.pseudo_classes WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
   'INSERT INTO tree_catalog.slots VALUES ' || list_aggregate(list_transform(rows, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit(x.b) || ', ' || tree_sql_lit(x.s) || ', ' || tree_sql_lit(x.e) || ')'), 'string_agg', ', '),
   CASE WHEN len(COALESCE(semantic.pseudo, [])) = 0 THEN NULL ELSE
   'INSERT INTO tree_catalog.pseudo_classes VALUES ' || list_aggregate(list_transform(semantic.pseudo, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit(x.name) || ', ''expression'', ' || tree_sql_lit(x.body) || ', ''local'', ''unknown'')'), 'string_agg', ', ') END,
   'UPDATE tree_catalog.trees SET has_semantic = true WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
   CASE WHEN is_abstract OR storage <> 'materialized' THEN NULL ELSE 'CREATE OR REPLACE TABLE ' || tbl_name || ' AS ' || proj_sql END,
   CASE WHEN is_abstract THEN NULL WHEN storage = 'materialized' THEN 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE SELECT * FROM ' || tbl_name
        ELSE 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE ' || proj_sql END,
   CASE WHEN is_abstract THEN NULL ELSE 'UPDATE tree_catalog.compiled SET sql_text = ' || tree_sql_lit(proj_sql) || ' WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''projection''' END,
   'COMMIT'], lambda x: x IS NOT NULL) END
FROM c);

-- The canonical projection of a registered tree. query() folds the concatenated literal to a constant.
CREATE OR REPLACE MACRO tree_project(sch, nm) AS TABLE
  FROM query('FROM tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm) || '()');

-- Ad hoc: a shape applied to a bare source, no registration. Open attributes, as for any concrete tree.
CREATE OR REPLACE MACRO tree_apply(shape, source) AS TABLE
  FROM query(tree_compile_projection(shape, source, '*'));

-- Classes are data: enumerate them per tree.
CREATE OR REPLACE MACRO tree_catalog_classes(sch, nm) AS TABLE
  SELECT unnest(_classes) AS class, count(*) AS row_count FROM tree_project(sch, nm) WHERE _classes IS NOT NULL GROUP BY ALL ORDER BY class;
```

Then delete the stub line for `tree_catalog_classes` from `sql/01_catalog.sql` (the real one now lives in `03_ddl.sql`, which loads later and would override it anyway; removing the stub keeps one definition).

- [ ] **Step 4: Write `tree_compile_p13` in `sql/04_dml.sql` now, since create uses it**

```sql
-- sql/04_dml.sql (first part; the DML compilers are added in Task 7)

-- P13: within each ROOT partition, the first row is level 0 and no row descends more than one level.
-- Returns a statement that raises when violated. MN15 mutates tree_sql_p13_pred.
CREATE OR REPLACE MACRO tree_sql_p13_pred() AS 'd > 1 OR (rn = 1 AND _level <> 0)';

CREATE OR REPLACE MACRO tree_compile_p13(rel_sql, label, has_root) AS
  'SELECT CASE WHEN count(*) > 0 THEN error(''P13 violated in tree ' || label || ': '' || count(*) || '' rows descend more than one level or start above level 0'
  || CASE WHEN has_root THEN '' ELSE '. If the relation holds more than one tree, declare ROOT' END
  || ''') END FROM (SELECT _level, _level - lag(_level, 1, -1) OVER (PARTITION BY _root ORDER BY _pre) AS d, row_number() OVER (PARTITION BY _root ORDER BY _pre) AS rn FROM ' || rel_sql || ') WHERE ' || tree_sql_p13_pred();
```

- [ ] **Step 5: Run the test**

Run: `python3 test/run.py test/sql/11_ddl.test`
Expected: PASS. Expected trouble spots: the `(empty)` expected value for the abstract tree's ATTR slot is how sqllogictest spells an empty string; if the runner prints `''` instead, change `fmt` in `test/run.py` to return `(empty)` for `""`. The `DROP MACRO TABLE` spelling is DuckDB's for table macros.

- [ ] **Step 6: Commit**

```bash
git add sql/03_ddl.sql sql/04_dml.sql sql/01_catalog.sql test/sql/11_ddl.test
git commit -m "feat(m0): tree_ddl_create/drop/alter compilers, tree_project, tree_apply, class introspection, P13 check"
```

---

### Task 7: Forest DML

**Files:**
- Modify: `sql/04_dml.sql`
- Create: `test/sql/12_dml.test`

**Interfaces:**
- Consumes: `tree_shape_from_catalog`, `tree_compile_projection`, `tree_compile_p13`.
- Produces: `tree_compile_insert(sch, nm, source) -> VARCHAR[]`, `tree_compile_replace(sch, nm, source) -> VARCHAR[]`, `tree_compile_delete(sch, nm, root_predicate) -> VARCHAR[]`, `tree_compile_check(sch, nm) -> VARCHAR[]`; runner turns `CALL tree_insert/replace/delete/check(...)` into these.

- [ ] **Step 1: Write the failing test**

```sql
# name: test/sql/12_dml.test
# description: tree-granular DML by ROOT, P13 on ingest, check

statement ok
CREATE TABLE src AS SELECT * FROM 'test/data/scripts.parquet';

statement ok
CREATE TABLE first_file AS SELECT * FROM src WHERE file_path = (SELECT min(file_path) FROM src);

statement ok
CREATE TABLE other_files AS SELECT * FROM src WHERE file_path <> (SELECT min(file_path) FROM src);

statement ok
CALL tree_ddl_create('main', 'scripts', tree_spec(tree_shape(root := 'file_path', "order" := 'node_id', level := 'depth', size := 'descendant_count'), source := 'first_file'));

query I
SELECT count(*) FROM tree_state.partitions WHERE tree_name = 'scripts';
----
1

# append trees
statement ok
CALL tree_insert('main', 'scripts', 'other_files');

query II
SELECT (SELECT count(*) FROM tree_state.partitions WHERE tree_name = 'scripts') = (SELECT count(DISTINCT file_path) FROM src),
       (SELECT count(*) FROM tree_project('main', 'scripts')) = (SELECT count(*) FROM src);
----
true	true

# re-inserting an existing ROOT is refused
statement error
CALL tree_insert('main', 'scripts', 'first_file');
----
already present

# replace re-derives one tree and bumps its epoch
statement ok
CALL tree_replace('main', 'scripts', 'first_file');

query I
SELECT epoch FROM tree_state.partitions WHERE tree_name = 'scripts' AND root_key = (SELECT {file_path: min(file_path)}::VARCHAR FROM src);
----
2

# delete by ROOT
statement ok
CALL tree_delete('main', 'scripts', 'file_path = (SELECT min(file_path) FROM src)');

query I
SELECT count(*) FROM tree_project('main', 'scripts') WHERE file_path = (SELECT min(file_path) FROM src);
----
0

# delete by a non-ROOT column is ill-typed (P21 / MN17)
statement error
CALL tree_delete('main', 'scripts', 'node_id = 3');
----
node_id

# P13 on ingest: a partition that descends two levels at once is rejected with the ROOT hint absent (ROOT declared)
statement ok
CREATE TABLE bad_levels(file_path VARCHAR, node_id INT, depth INT, descendant_count INT);

statement ok
INSERT INTO bad_levels VALUES ('x.py', 0, 0, 2), ('x.py', 1, 2, 0), ('x.py', 2, 1, 0);

statement error
CALL tree_insert('main', 'scripts', 'bad_levels');
----
P13 violated

# P13 with no ROOT declared names the hint
statement ok
CREATE TABLE two_trees(node_id INT, depth INT);

statement ok
INSERT INTO two_trees VALUES (0, 0), (1, 1), (0, 0), (1, 1), (2, 2), (5, 5);

statement error
CALL tree_ddl_create('main', 'unrooted', tree_spec(tree_shape("order" := 'node_id', level := 'depth'), source := 'two_trees'));
----
declare ROOT

# the failed create left nothing behind
query I
SELECT count(*) FROM tree_catalog_trees() WHERE tree_name = 'unrooted';
----
0

# check records a P13 assertion
statement ok
CALL tree_check('main', 'scripts');

query II
SELECT artifact, status FROM tree_catalog_assertions() WHERE tree_name = 'scripts';
----
assert_p13	ok
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/run.py test/sql/12_dml.test`
Expected: FAIL at the first `CALL tree_insert`, `tree_compile_insert` not found.

- [ ] **Step 3: Append the DML compilers to `sql/04_dml.sql`**

```sql
-- helper: the tree row and its shape, or an error
CREATE OR REPLACE MACRO tree_dml_context(verb, sch, nm) AS (
  SELECT CASE WHEN count(*) = 0 THEN error(verb || ': tree ' || sch || '.' || nm || ' not found')
              WHEN max(storage) <> 'materialized' THEN error(verb || ': tree ' || sch || '.' || nm || ' is projection-mode; DML needs storage := materialized')
              ELSE {db: current_database(), shape: tree_shape_from_catalog(current_database(), sch, nm),
                    attr: (SELECT expression FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND slot = 'ATTR'),
                    has_root: bool_or(EXISTS (SELECT 1 FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND slot = 'ROOT')),
                    tbl: 'tree_catalog.' || tree_sql_ident('t_' || sch || '_' || nm)} END
  FROM tree_catalog.trees WHERE database_name = current_database() AND schema_name = sch AND tree_name = nm);

CREATE OR REPLACE MACRO tree_compile_insert(sch, nm, source) AS (
  WITH c AS (SELECT tree_dml_context('tree_insert', sch, nm) AS x),
  p AS (SELECT x, tree_compile_projection(x.shape, source, x.attr) AS proj FROM c)
  SELECT ['BEGIN TRANSACTION',
    'CREATE TEMP TABLE __duckent_new AS ' || proj,
    'SELECT CASE WHEN count(*) > 0 THEN error(''tree_insert: ROOT values already present in ' || sch || '.' || nm || ': '' || string_agg(DISTINCT n._root::VARCHAR, '', '')) END FROM __duckent_new n JOIN tree_state.partitions p ON p.root_key = n._root::VARCHAR AND p.database_name = ' || tree_sql_lit(x.db) || ' AND p.schema_name = ' || tree_sql_lit(sch) || ' AND p.tree_name = ' || tree_sql_lit(nm),
    tree_compile_p13('__duckent_new', sch || '.' || nm, x.has_root),
    'INSERT INTO ' || x.tbl || ' SELECT * FROM __duckent_new',
    'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', _root::VARCHAR, 1, count(*), true, now() FROM __duckent_new GROUP BY _root',
    'DROP TABLE __duckent_new',
    'COMMIT'] FROM p);

CREATE OR REPLACE MACRO tree_compile_replace(sch, nm, source) AS (
  WITH c AS (SELECT tree_dml_context('tree_replace', sch, nm) AS x),
  p AS (SELECT x, tree_compile_projection(x.shape, source, x.attr) AS proj FROM c)
  SELECT ['BEGIN TRANSACTION',
    'CREATE TEMP TABLE __duckent_new AS ' || proj,
    tree_compile_p13('__duckent_new', sch || '.' || nm, x.has_root),
    'CREATE TEMP TABLE __duckent_epochs AS SELECT root_key, epoch FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT DISTINCT _root::VARCHAR FROM __duckent_new)',
    'DELETE FROM ' || x.tbl || ' WHERE _root::VARCHAR IN (SELECT root_key FROM __duckent_epochs)',
    'DELETE FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT root_key FROM __duckent_epochs)',
    'INSERT INTO ' || x.tbl || ' SELECT * FROM __duckent_new',
    'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', n._root::VARCHAR, COALESCE(e.epoch, 0) + 1, count(*), true, now() FROM __duckent_new n LEFT JOIN __duckent_epochs e ON e.root_key = n._root::VARCHAR GROUP BY n._root, e.epoch',
    'DROP TABLE __duckent_new', 'DROP TABLE __duckent_epochs',
    'COMMIT'] FROM p);

-- The predicate is evaluated over the ROOT columns only: a non-ROOT column is a binder error naming it (P21). MN17 mutates this to row surgery.
CREATE OR REPLACE MACRO tree_sql_delete_stmt(tbl, root_predicate) AS
  'DELETE FROM ' || tbl || ' WHERE _root IN (SELECT _root FROM (SELECT DISTINCT _root, _root.* FROM ' || tbl || ') WHERE ' || root_predicate || ')';

CREATE OR REPLACE MACRO tree_compile_delete(sch, nm, root_predicate) AS (
  WITH c AS (SELECT tree_dml_context('tree_delete', sch, nm) AS x)
  SELECT ['BEGIN TRANSACTION',
    'CREATE TEMP TABLE __duckent_gone AS SELECT DISTINCT _root::VARCHAR AS root_key FROM (SELECT DISTINCT _root, _root.* FROM ' || x.tbl || ') WHERE ' || root_predicate,
    tree_sql_delete_stmt(x.tbl, root_predicate),
    'DELETE FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT root_key FROM __duckent_gone)',
    'DROP TABLE __duckent_gone',
    'COMMIT'] FROM c);

-- Run the assertions and record them. P13 only for now; O assertions arrive in M3.
CREATE OR REPLACE MACRO tree_compile_check(sch, nm) AS (
  WITH c AS (SELECT tree_dml_context('tree_check', sch, nm) AS x)
  SELECT ['BEGIN TRANSACTION',
    'DELETE FROM tree_state.assertions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''assert_p13''',
    'INSERT INTO tree_state.assertions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ''assert_p13'', CASE WHEN count(*) = 0 THEN ''ok'' ELSE ''violated'' END, (SELECT max(epoch) FROM tree_state.partitions WHERE tree_name = ' || tree_sql_lit(nm) || '), count(*) || '' violating rows'' FROM (SELECT _level, _level - lag(_level, 1, -1) OVER (PARTITION BY _root ORDER BY _pre) AS d, row_number() OVER (PARTITION BY _root ORDER BY _pre) AS rn FROM ' || x.tbl || ') WHERE ' || tree_sql_p13_pred(),
    'COMMIT'] FROM c);
```

- [ ] **Step 4: Run the test**

Run: `python3 test/run.py test/sql/12_dml.test`
Expected: PASS. If `_root.*` does not expand a struct column in a subquery, replace `SELECT DISTINCT _root, _root.*` with `SELECT DISTINCT _root, unnest(_root)` (DuckDB unnests a struct into columns).

- [ ] **Step 5: Commit**

```bash
git add sql/04_dml.sql test/sql/12_dml.test
git commit -m "feat(m0): tree-granular insert, replace, delete, check with P13 on ingest"
```

---

### Task 8: Derivations and round trips (M1)

**Files:**
- Create: `sql/05_derivations.sql`
- Create: `test/sql/20_derivations.test`

**Interfaces:**
- Produces: table macros `tree_derive_parent(source, root_csv, order_col, level_col)` returning the source rows plus `_root, _pre, _level, _parent`; `tree_encode(source, key, parent, sibling_order)` returning the source rows plus `_root, _pre, _level`. Both are the standalone lemma implementations; the projection compiler emits the same text.

- [ ] **Step 1: Write the failing test**

```sql
# name: test/sql/20_derivations.test
# description: P17 round trips are identities; sibling-free profile refuses sibling combinators at create time metadata

# level -> parent -> level: deriving parent from level, then level from the derived parent chain, returns the original level
query I
WITH d AS (FROM tree_derive_parent('read_parquet(''test/data/app.parquet'')', 'file_path', 'node_id', 'depth')),
lvl AS (
  WITH RECURSIVE up USING KEY (_pre) AS (
    SELECT _pre, 0 AS l FROM d WHERE _parent IS NULL
    UNION ALL
    SELECT d._pre, up.l + 1 FROM d JOIN up ON d._parent = up._pre)
  SELECT * FROM up)
SELECT count(*) FILTER (WHERE d._level <> lvl.l) FROM d JOIN lvl USING (_pre);
----
0

# parent -> (order, level) -> parent: the encoder's pre-order, re-derived to parent via nearest prior row, matches the adjacency list
query I
WITH e AS (FROM tree_encode('read_csv(''test/data/employees.csv'')', 'email', 'manager_email', 'hire_date')),
back AS (SELECT a.email, b.email AS parent_email FROM e a ASOF LEFT JOIN e b ON a._root = b._root AND b._level = a._level - 1 AND b._pre < a._pre)
SELECT count(*) FILTER (WHERE back.parent_email IS DISTINCT FROM e.manager_email) FROM e JOIN back USING (email);
----
0

# the encoder is deterministic without a sibling key (falls back to key order) and still valid
query II
WITH e AS (FROM tree_encode('read_csv(''test/data/categories.csv'')', 'cat_id', 'parent_id', NULL))
SELECT list(_pre ORDER BY cat_id), list(_level ORDER BY cat_id) FROM e;
----
[0, 1, 2, 3, 4]	[0, 1, 2, 2, 1]

# P13 property: every valid level walk passes, every invalid one is rejected
statement ok
CREATE TABLE walks(name VARCHAR, node_id INT, depth INT);

statement ok
INSERT INTO walks VALUES
  ('ok_chain', 0, 0), ('ok_chain', 1, 1), ('ok_chain', 2, 2), ('ok_chain', 3, 1), ('ok_chain', 4, 0),
  ('ok_flat', 0, 0), ('ok_flat', 1, 0), ('ok_flat', 2, 0),
  ('bad_jump', 0, 0), ('bad_jump', 1, 2),
  ('bad_start', 0, 1), ('bad_start', 1, 2);

statement ok
CALL tree_ddl_create('main', 'ok_chain', tree_spec(tree_shape("order" := 'node_id', level := 'depth'), source := '(SELECT * FROM walks WHERE name = ''ok_chain'')'));

statement ok
CALL tree_ddl_create('main', 'ok_flat', tree_spec(tree_shape("order" := 'node_id', level := 'depth'), source := '(SELECT * FROM walks WHERE name = ''ok_flat'')'));

statement error
CALL tree_ddl_create('main', 'bad_jump', tree_spec(tree_shape("order" := 'node_id', level := 'depth'), source := '(SELECT * FROM walks WHERE name = ''bad_jump'')'));
----
P13 violated

statement error
CALL tree_ddl_create('main', 'bad_start', tree_spec(tree_shape("order" := 'node_id', level := 'depth'), source := '(SELECT * FROM walks WHERE name = ''bad_start'')'));
----
P13 violated

# sizes on the flat forest: every root is a leaf
query I
SELECT list(_size ORDER BY _pre) FROM tree_project('main', 'ok_flat');
----
[0, 0, 0]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/run.py test/sql/20_derivations.test`
Expected: FAIL, `tree_derive_parent` not found.

- [ ] **Step 3: Write the derivation macros**

```sql
-- sql/05_derivations.sql
-- Standalone lemmas. The projection compiler emits the same text; these exist for direct use and for the M1 identities.

CREATE OR REPLACE MACRO tree_derive_parent(source, root_csv, order_col, level_col) AS TABLE
  FROM query(
    'WITH __r AS (SELECT *, ' || tree_sql_root(root_csv, '') || ' AS _root, CAST(' || order_col || ' AS BIGINT) AS _pre, CAST(' || level_col || ' AS BIGINT) AS _level FROM ' || source || ') '
    || 'SELECT a.*, b._pre AS _parent FROM __r a ASOF LEFT JOIN __r b ON a._root = b._root AND b._level = a._level - 1 AND b._pre < a._pre');

CREATE OR REPLACE MACRO tree_encode(source, key, parent, sibling_order) AS TABLE
  FROM query(
    'WITH RECURSIVE __src AS (SELECT * FROM ' || source || '), '
    || '__walk USING KEY (__key) AS (SELECT {r0: 0} AS _root, ' || key || ' AS __key, 0 AS _level, '
    || '[row_number() OVER (ORDER BY ' || COALESCE(sibling_order || ', ', '') || key || ' ' || tree_sql_encoder_tiebreak() || ')] AS __path FROM __src WHERE ' || parent || ' IS NULL '
    || 'UNION ALL SELECT {r0: 0}, c.' || key || ', w._level + 1, w.__path || [row_number() OVER (PARTITION BY c.' || parent || ' ORDER BY '
    || COALESCE('c.' || sibling_order || ', ', '') || 'c.' || key || ' ' || tree_sql_encoder_tiebreak() || ')] FROM __src c JOIN __walk w ON c.' || parent || ' = w.__key) '
    || 'SELECT s.*, w._root, CAST(row_number() OVER (ORDER BY w.__path) - 1 AS BIGINT) AS _pre, CAST(w._level AS BIGINT) AS _level FROM __src s JOIN __walk w ON s.' || key || ' = w.__key');
```

- [ ] **Step 4: Run the test**

Run: `python3 test/run.py test/sql/20_derivations.test`
Expected: PASS. The source argument `(SELECT * FROM walks WHERE name = 'ok_chain')` shows that any FROM-able text works as a source, parentheses included.

- [ ] **Step 5: Commit**

```bash
git add sql/05_derivations.sql test/sql/20_derivations.test
git commit -m "feat(m1): standalone derivations with P17 round-trip and P13 property tests"
```

---

### Task 9: Selector IR constructor and TREEQL printer

**Files:**
- Create: `sql/06_selector.sql`
- Create: `test/sql/30_selector.test`

**Interfaces:**
- Produces: `tree_steps(steps) -> TREE_SELECTOR` where `steps` is a list of structs with optional fields `comb` (`desc`, `child`, `next`, `after`), `type`, `id`, `class`, `attr` (text `name op literal`), `pseudo`, `"where"`, `"as"`; `tree_selector_to_treeql(sel) -> VARCHAR`. IR layout: node 0 is `selector`; each step is a `step` node with `parent_id = 0`, `op` = combinator (NULL for the first step), `alias` = capture; clause nodes hang under their step with kinds `type`, `id`, `class`, `attr` (`value` = name, `op` = operator, `arg` = literal text), `pseudo`, `where`.

- [ ] **Step 1: Write the failing test**

```sql
# name: test/sql/30_selector.test
# description: tree_steps builds the IR; the printer renders canonical TREEQL

query I
SELECT len(tree_steps([{type: 'function_definition'}, {comb: 'child', type: 'block', "as": 'b'}]));
----
5

query IIII rowsort
SELECT node_id, parent_id, kind, COALESCE(value, op, alias) FROM (SELECT unnest(tree_steps([{type: 'function_definition'}, {comb: 'child', type: 'block', "as": 'b'}]), recursive := true));
----
0	NULL	selector	NULL
1	0	step	NULL
2	1	type	function_definition
3	0	step	child
4	3	type	block

query III
SELECT value, op, arg FROM (SELECT unnest(tree_steps([{attr: 'start_line > 100'}]), recursive := true)) WHERE kind = 'attr';
----
start_line	>	100

query I
SELECT tree_selector_to_treeql(tree_steps([
  {type: 'node'},
  {comb: 'child', id: 'parse_ast'},
  {comb: 'desc', class: 'fn'},
  {comb: 'next', attr: 'start_line > 100'},
  {comb: 'child', pseudo: 'leaf', "where": 'child_count > 2', "as": 'y'},
  {comb: 'after'}]));
----
(TYPE 'node')
CHILD (ID 'parse_ast')
DESCENDANT (CLASS 'fn')
SIBLING (ATTR start_line > 100)
CHILD (PSEUDO 'leaf', WHERE child_count > 2) AS y
FOLLOWING

# a step with no combinator after the first defaults to DESCENDANT
query I
SELECT tree_selector_to_treeql(tree_steps([{type: 'a'}, {type: 'b'}]));
----
(TYPE 'a')
DESCENDANT (TYPE 'b')
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/run.py test/sql/30_selector.test`
Expected: FAIL, `tree_steps` not found.

- [ ] **Step 3: Write the constructor and printer**

```sql
-- sql/06_selector.sql

-- Normalize any list of step structs to one fixed shape so missing fields read as NULL.
CREATE OR REPLACE MACRO tree_steps(steps) AS (
  WITH st AS (
    SELECT generate_subscripts(steps, 1) AS i,
           unnest(steps::STRUCT(comb VARCHAR, type VARCHAR, id VARCHAR, class VARCHAR, attr VARCHAR, pseudo VARCHAR, "where" VARCHAR, "as" VARCHAR)[]) AS s),
  nodes AS (
    SELECT 0 AS i, 0 AS sub, 'selector' AS kind, NULL::VARCHAR AS value, NULL::VARCHAR AS op, NULL::VARCHAR AS arg, NULL::VARCHAR AS alias
    UNION ALL SELECT i, 0, 'step', NULL, CASE WHEN i = 1 THEN NULL ELSE COALESCE(s.comb, 'desc') END, NULL, s."as" FROM st
    UNION ALL SELECT i, 1, 'type', s.type, NULL, NULL, NULL FROM st WHERE s.type IS NOT NULL
    UNION ALL SELECT i, 2, 'id', s.id, NULL, NULL, NULL FROM st WHERE s.id IS NOT NULL
    UNION ALL SELECT i, 3, 'class', s.class, NULL, NULL, NULL FROM st WHERE s.class IS NOT NULL
    UNION ALL SELECT i, 4, 'attr',
        regexp_extract(s.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 1),
        regexp_extract(s.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 2),
        regexp_extract(s.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 3), NULL FROM st WHERE s.attr IS NOT NULL
    UNION ALL SELECT i, 5, 'pseudo', s.pseudo, NULL, NULL, NULL FROM st WHERE s.pseudo IS NOT NULL
    UNION ALL SELECT i, 6, 'where', s."where", NULL, NULL, NULL FROM st WHERE s."where" IS NOT NULL),
  numbered AS (SELECT CAST(row_number() OVER (ORDER BY i, sub) - 1 AS INTEGER) AS node_id, * FROM nodes),
  parented AS (
    SELECT n.node_id,
           CASE n.kind WHEN 'selector' THEN NULL WHEN 'step' THEN 0 ELSE (SELECT p.node_id FROM numbered p WHERE p.kind = 'step' AND p.i = n.i) END AS parent_id,
           n.kind, n.value, n.op, n.arg, n.alias
    FROM numbered n)
  SELECT list({node_id: node_id, parent_id: parent_id, kind: kind, value: value, op: op, arg: arg, alias: alias} ORDER BY node_id)::TREE_SELECTOR FROM parented);

CREATE OR REPLACE MACRO tree_treeql_comb(op) AS
  CASE op WHEN 'desc' THEN 'DESCENDANT' WHEN 'child' THEN 'CHILD' WHEN 'next' THEN 'SIBLING' WHEN 'after' THEN 'FOLLOWING' ELSE NULL END;

CREATE OR REPLACE MACRO tree_treeql_clause(kind, value, op, arg) AS
  CASE kind WHEN 'type' THEN 'TYPE ' || tree_sql_lit(value)
            WHEN 'id' THEN 'ID ' || tree_sql_lit(value)
            WHEN 'class' THEN 'CLASS ' || tree_sql_lit(value)
            WHEN 'attr' THEN 'ATTR ' || value || ' ' || op || ' ' || arg
            WHEN 'pseudo' THEN 'PSEUDO ' || tree_sql_lit(value)
            WHEN 'where' THEN 'WHERE ' || value END;

-- Linear printer: one line per step. Nested HAS/NOT groups are M2.
CREATE OR REPLACE MACRO tree_selector_to_treeql(sel) AS (
  WITH n AS (SELECT unnest(sel, recursive := true)),
  steps AS (
    SELECT s.node_id, s.op, s.alias,
           (SELECT string_agg(tree_treeql_clause(c.kind, c.value, c.op, c.arg), ', ' ORDER BY c.node_id) FROM n c WHERE c.parent_id = s.node_id) AS clauses
    FROM n s WHERE s.kind = 'step')
  SELECT string_agg(
           COALESCE(tree_treeql_comb(op) || ' ', '') || COALESCE('(' || clauses || ')', '') || COALESCE(' AS ' || alias, ''),
           chr(10) ORDER BY node_id)
  FROM steps);
```

- [ ] **Step 4: Run the test**

Run: `python3 test/run.py test/sql/30_selector.test`
Expected: PASS. Note the bare-step line `FOLLOWING` has no trailing space: the `COALESCE(tree_treeql_comb(op) || ' ', '')` followed by an empty clause list yields `FOLLOWING ` with a trailing space, so add `rtrim(...)` around the per-step expression if the comparison fails on that line.

- [ ] **Step 5: Commit**

```bash
git add sql/06_selector.sql test/sql/30_selector.test
git commit -m "feat(m1.5): tree_steps IR constructor and TREEQL printer"
```

---

### Task 10: Match compiler

**Files:**
- Create: `sql/07_match.sql`
- Create: `test/sql/31_match.test`

**Interfaces:**
- Consumes: catalog, `tree_project`, `TREE_SELECTOR`, `tree_selector_to_treeql`.
- Produces: `tree_sql_comb(op, a, b) -> VARCHAR` (structural predicate text between step aliases `a` and `b`), `tree_sql_clause(kind, value, op, arg) -> VARCHAR` (predicate text with `§` standing for the step alias), `tree_compile_match(sch, nm, sel, semantic := NULL) -> VARCHAR` (one SELECT), `tree_explain(sch, nm, sel, semantic := NULL) -> STRUCT(treeql VARCHAR, sql VARCHAR)`. Output columns of a match: the subject step's source columns (canonical columns excluded), one STRUCT column per captured alias, `_match_tree`, `_match_language`, `_match_unknown_pseudos`.

- [ ] **Step 1: Write the failing test**

```sql
# name: test/sql/31_match.test
# description: TREEQL matching over projections; captures; refusals; NULL-definite semantics

statement ok
CALL tree_ddl_create('main', 'app', tree_spec(
  tree_shape(root := 'file_path', "order" := 'node_id', level := 'depth', size := 'descendant_count',
             semantic := tree_semantic(type := 'type', id := 'name', classes := '[semantic_type_to_string(semantic_type)]',
                                       pseudo := [{name: 'leaf', body: 'descendant_count = 0'}, {name: 'def', body: '(flags & 6) = 6'}])),
  source := 'read_parquet(''test/data/app.parquet'')'));

# the flagship: functions with no string anywhere in their body (the shipped-ast_select spelling), as a linear TREEQL chain is not expressible
# without NOT (M2), so first the positive form: functions that contain a string
query II rowsort
FROM tree_match('main', 'app', tree_steps([{type: 'function_definition', pseudo: 'def', "as": 'f'}, {comb: 'desc', type: 'string'}])) SELECT DISTINCT f.name, f.start_line;
----
greet	4

# subject row is the last step and carries source columns, not canonical ones
query I
SELECT count(*) FROM (DESCRIBE FROM tree_match('main', 'app', tree_steps([{type: 'function_definition'}]))) WHERE column_name LIKE '\_%' ESCAPE '\' AND column_name NOT LIKE '\_match\_%' ESCAPE '\';
----
0

# type + class + pseudo compound, child combinator
query I rowsort
FROM tree_match('main', 'app', tree_steps([{type: 'function_definition', pseudo: 'def'}, {comb: 'child', type: 'identifier'}])) SELECT name;
----
greet
shout

# captures: one row per embedding; alias is a struct usable in WHERE and SELECT
query II rowsort
FROM tree_match('main', 'app', tree_steps([{type: 'function_definition', pseudo: 'def', "as": 'fn'}, {comb: 'child', type: 'block', "as": 'b'}, {comb: 'child', type: 'return_statement'}]))
SELECT fn.name, b._pre WHERE fn.start_line > 1;
----
greet	14
shout	38

# a capture is not in the output unless selected
query I
SELECT count(*) FROM (DESCRIBE FROM tree_match('main', 'app', tree_steps([{type: 'function_definition', "as": 'fn'}, {comb: 'child', type: 'block'}]))) WHERE column_name = 'fn';
----
1

# attr with a typed comparison against an attribute column
query I rowsort
FROM tree_match('main', 'app', tree_steps([{type: 'function_definition', pseudo: 'def', attr: 'start_line > 5'}])) SELECT name;
----
shout

# NULL-definite: comparing a NULL column matches nothing
query I
SELECT count(*) FROM tree_match('main', 'app', tree_steps([{type: 'function_definition', pseudo: 'def', attr: 'signature_type = ''x'''}]));
----
0

# step WHERE sees the projection row; SIBLING and FOLLOWING work on the full profile
query I rowsort
FROM tree_match('main', 'app', tree_steps([{type: 'function_definition', pseudo: 'def', "as": 'a'}, {comb: 'next', type: 'function_definition', "where": '(flags & 6) = 6'}])) SELECT a.name;
----
greet

# unknown pseudo-class is preserved, matches nothing, and is counted
query II
SELECT count(*), max(_match_unknown_pseudos) FROM (FROM tree_match('main', 'app', tree_steps([{type: 'function_definition', pseudo: 'nope'}])) SELECT *, 1 AS one UNION ALL SELECT NULL, 0 FROM (SELECT 1) WHERE false);
----
0	NULL

query I
SELECT (tree_explain('main', 'app', tree_steps([{type: 'function_definition'}]))).treeql;
----
(TYPE 'function_definition')

# an S clause against an R-only tree refuses and names SEMANTIC
statement ok
CALL tree_ddl_create('main', 'bare', tree_spec(tree_shape("order" := 'node_id', level := 'depth'), source := 'read_parquet(''test/data/app.parquet'')'));

statement error
FROM tree_match('main', 'bare', tree_steps([{type: 'function_definition'}]));
----
SEMANTIC

# WHERE-only matching works on the R-only tree, and TYPE defaults to node (MN21)
query II
FROM tree_match('main', 'bare', tree_steps([{"where": 'depth = 0'}, {comb: 'child', "where": 'type = ''function_definition'''}])) SELECT count(*), min(_match_tree);
----
2	main.bare

# a per-query SEMANTIC overlay lights up TYPE on the bare tree
query I rowsort
FROM tree_match('main', 'bare', tree_steps([{type: 'function_definition'}]), semantic := tree_semantic(type := 'type')) SELECT name;
----
greet
shout

# sibling combinators refuse under the sibling-free profile, naming SIBLING_ORDER (MN6)
statement ok
CALL tree_ddl_create('main', 'cats', tree_spec(tree_shape(key := 'cat_id', parent := 'parent_id'), source := 'read_csv(''test/data/categories.csv'')'));

statement error
FROM tree_match('main', 'cats', tree_steps([{"where": 'name = ''tools'''}, {comb: 'next'}]));
----
SIBLING_ORDER

# structural matching on a parent-basis tree
statement ok
CALL tree_ddl_create('main', 'org', tree_spec(tree_shape(key := 'email', parent := 'manager_email', sibling_order := 'hire_date', semantic := tree_semantic(type := 'role', id := 'email')), source := 'read_csv(''test/data/employees.csv'')'));

query I rowsort
FROM tree_match('main', 'org', tree_steps([{type: 'manager', "as": 'm'}, {comb: 'child', type: 'engineer'}])) SELECT DISTINCT m.email;
----
bo@co
cy@co

# step WHERE compiles against the projection only: a closed shape cannot see undeclared source columns (MN19)
statement ok
CALL tree_ddl_create('main', 'closed', tree_spec(tree_shape(root := 'file_path', "order" := 'node_id', level := 'depth', semantic := tree_semantic(type := 'type', attr := 'name')), source := 'read_parquet(''test/data/app.parquet'')'));

statement error
FROM tree_match('main', 'closed', tree_steps([{type: 'function_definition', "where": 'peek LIKE ''def%'''}]));
----
peek
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/run.py test/sql/31_match.test`
Expected: FAIL at the first `tree_match`, `tree_compile_match` not found.

- [ ] **Step 3: Write the match compiler**

```sql
-- sql/07_match.sql
CREATE OR REPLACE MACRO tree_canonical_columns() AS
  ['_root', '_pre', '_level', '_parent', '_size', '_children', '_next', '_type', '_id', '_classes', '_attr_map', '_pseudo'];

-- Structural predicate between the previous step alias a and this step alias b. MN14 mutates this to drop the root equality.
CREATE OR REPLACE MACRO tree_sql_comb(op, a, b) AS
  CASE op
    WHEN 'desc'  THEN b || '._root = ' || a || '._root AND ' || b || '._pre BETWEEN ' || a || '._pre + 1 AND ' || a || '._pre + ' || a || '._size'
    WHEN 'child' THEN b || '._root = ' || a || '._root AND ' || b || '._parent = ' || a || '._pre'
    WHEN 'next'  THEN b || '._root = ' || a || '._root AND ' || b || '._parent = ' || a || '._parent AND ' || b || '._pre = ' || a || '._pre + ' || a || '._size + 1'
    WHEN 'after' THEN b || '._root = ' || a || '._root AND ' || b || '._parent = ' || a || '._parent AND ' || b || '._pre > ' || a || '._pre'
    ELSE error('tree_match: unknown combinator ' || op) END;

-- Clause predicate with § for the step alias. Attribute and pseudo filters are NULL-definite. MN19 mutates the where branch.
CREATE OR REPLACE MACRO tree_sql_clause(kind, value, op, arg) AS
  CASE kind
    WHEN 'type'   THEN '§._type = ' || tree_sql_lit(value)
    WHEN 'id'     THEN '§._id = ' || tree_sql_lit(value)
    WHEN 'class'  THEN 'COALESCE(list_contains(§._classes, ' || tree_sql_lit(value) || '), false)'
    WHEN 'pseudo' THEN 'COALESCE(§._pseudo[' || tree_sql_lit(value) || '], false)'
    WHEN 'attr'   THEN 'COALESCE(§.' || tree_sql_ident(value) || ' ' || op || ' ' || arg || ', false)'
    WHEN 'where'  THEN 'EXISTS (SELECT 1 FROM (SELECT §.*) __w WHERE ' || value || ')'
    WHEN 'pseudo_unknown' THEN 'false'
    ELSE error('tree_match: unknown clause kind ' || kind) END;

CREATE OR REPLACE MACRO tree_compile_match(sch, nm, sel, semantic := NULL) AS (
WITH t AS (
  SELECT tr.profile, tr.has_semantic OR semantic IS NOT NULL AS has_semantic,
         (SELECT list(name) FROM tree_catalog.pseudo_classes p WHERE p.database_name = current_database() AND p.schema_name = sch AND p.tree_name = nm) AS known_pseudos
  FROM tree_catalog.trees tr WHERE tr.database_name = current_database() AND tr.schema_name = sch AND tr.tree_name = nm),
chk AS (SELECT CASE WHEN (SELECT count(*) FROM t) = 0 THEN error('tree_match: tree ' || sch || '.' || nm || ' not found') ELSE true END AS ok),
proj AS (
  SELECT CASE WHEN semantic IS NULL THEN 'tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm) || '()'
    ELSE '(SELECT * REPLACE (' || list_aggregate(list_filter([
        semantic.type || ' AS _type', semantic.id || ' AS _id', semantic.classes || ' AS _classes', semantic.attr_map || ' AS _attr_map',
        CASE WHEN semantic.pseudo IS NULL THEN NULL ELSE tree_sql_pseudo_map(semantic) || ' AS _pseudo' END], lambda x: x IS NOT NULL), 'string_agg', ', ')
      || ') FROM tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm) || '())' END AS p),
-- IR rows; S clauses refused on S-less trees; unknown pseudo-classes marked; sibling combinators refused under sibling_free
n AS (
  SELECT node_id, parent_id,
         CASE WHEN kind = 'pseudo' AND NOT list_contains(COALESCE((SELECT known_pseudos FROM t), []), value)
                   AND (semantic IS NULL OR NOT list_contains(list_transform(COALESCE(semantic.pseudo, []), lambda x: x.name), value)) THEN 'pseudo_unknown' ELSE kind END AS kind,
         value, op, arg, COALESCE(alias, 's' || node_id) AS alias,
         CASE WHEN kind IN ('type', 'id', 'class', 'attr', 'pseudo') AND NOT (SELECT has_semantic FROM t)
              THEN error('tree_match: tree ' || sch || '.' || nm || ' has no SEMANTIC group; only combinators and WHERE are available. Add one with tree_ddl_alter or pass semantic :=')
              WHEN kind = 'step' AND op IN ('next', 'after') AND (SELECT profile FROM t) = 'sibling_free'
              THEN error('tree_match: tree ' || sch || '.' || nm || ' is sibling-free (no SIBLING_ORDER declared); SIBLING and FOLLOWING are unavailable')
              ELSE true END AS ok
  FROM (SELECT unnest(sel, recursive := true))),
steps AS (
  SELECT s.node_id, s.op, s.alias,
         COALESCE((SELECT string_agg(replace(tree_sql_clause(c.kind, c.value, c.op, c.arg), '§', s.alias), ' AND ' ORDER BY c.node_id) FROM n c WHERE c.parent_id = s.node_id), 'true') AS pred,
         lag(s.alias) OVER (ORDER BY s.node_id) AS prev_alias,
         row_number() OVER (ORDER BY s.node_id) AS rn,
         count(*) OVER () AS n_steps
  FROM n s WHERE s.kind = 'step'),
chain AS (
  SELECT string_agg(
           CASE WHEN rn = 1 THEN (SELECT p FROM proj) || ' ' || alias
                ELSE 'JOIN ' || (SELECT p FROM proj) || ' ' || alias || ' ON ' || tree_sql_comb(op, prev_alias, alias) || ' AND (' || pred || ')' END,
           ' ' ORDER BY node_id) AS from_sql,
         max(CASE WHEN rn = 1 THEN pred END) AS first_pred,
         max(CASE WHEN rn = n_steps THEN alias END) AS subject,
         list(alias ORDER BY node_id) FILTER (WHERE alias NOT LIKE 's%' OR alias <> 's' || node_id) AS captures
  FROM steps)
SELECT CASE WHEN NOT (SELECT ok FROM chk) OR NOT (SELECT bool_and(ok) FROM n) THEN NULL ELSE
  'SELECT ' || subject || '.* EXCLUDE (' || list_aggregate(tree_canonical_columns(), 'string_agg', ', ') || ')'
  || COALESCE(', ' || list_aggregate(list_transform(list_filter(captures, lambda a: a <> subject), lambda a: a || ' AS ' || a), 'string_agg', ', '), '')
  || ', ' || tree_sql_lit(sch || '.' || nm) || ' AS _match_tree, ''treeql'' AS _match_language, '
  || (SELECT count(*) FROM n WHERE kind = 'pseudo_unknown') || ' AS _match_unknown_pseudos'
  || ' FROM ' || from_sql || ' WHERE ' || first_pred END
FROM chain);

CREATE OR REPLACE MACRO tree_explain(sch, nm, sel, semantic := NULL) AS
  {treeql: tree_selector_to_treeql(sel), sql: tree_compile_match(sch, nm, sel, semantic := semantic)};
```

Notes for the implementer: the `captures` list keeps aliases the user set; the filter drops the generated `s<node_id>` names. A user alias that itself looks like `s7` is a known D-N9 collision and is out of scope. The `EXCLUDE` list removes canonical columns from the subject row only; captured aliases are whole projection rows as structs, which is why `b._pre` is readable in the test.

- [ ] **Step 4: Run the test**

Run: `python3 test/run.py test/sql/31_match.test`
Expected: PASS. Likely adjustments: (a) if `lag()` inside a CTE that also aggregates confuses the binder, compute `prev_alias` in a separate CTE before `chain`; (b) the `_match_unknown_pseudos` test expects zero rows with the count column absent, so the UNION trick yields `0 NULL`; if the runner reports a shape mismatch, simplify that test to `SELECT count(*) FROM tree_match(...)` expecting `0` and check `_match_unknown_pseudos` on a matching selector instead; (c) if `error()` inside a CASE is evaluated eagerly for non-matching rows, wrap the offending branch in a scalar subquery.

- [ ] **Step 5: Commit**

```bash
git add sql/07_match.sql test/sql/31_match.test
git commit -m "feat(m1.5): TREEQL match compiler with captures, NULL-definite clauses, and legible refusals"
```

---

### Task 11: Traversal macros

**Files:**
- Create: `sql/08_traversal.sql`
- Create: `test/sql/32_traversal.test`

**Interfaces:**
- Produces: table macros over `tree_project(sch, nm)`: `tree_children(sch, nm, root_key, pre)`, `tree_descendants(sch, nm, root_key, pre)`, `tree_ancestors(sch, nm, root_key, pre)`, `tree_next_sibling(sch, nm, root_key, pre)`, `tree_first_child(sch, nm, root_key, pre)`. `root_key` is the `_root` struct cast to VARCHAR, as stored in `tree_state.partitions.root_key`.

- [ ] **Step 1: Write the failing test**

```sql
# name: test/sql/32_traversal.test
# description: traversal building blocks by pre, size, level, parent

statement ok
CALL tree_ddl_create('main', 'app', tree_spec(tree_shape(root := 'file_path', "order" := 'node_id', level := 'depth', size := 'descendant_count'), source := 'read_parquet(''test/data/app.parquet'')'));

query I
SELECT list(_pre ORDER BY _pre) FROM tree_children('main', 'app', '{''file_path'': app.py}', 6);
----
[7, 8, 9, 13, 14]

query I
SELECT count(*) FROM tree_descendants('main', 'app', '{''file_path'': app.py}', 6);
----
23

query I
SELECT list(_pre ORDER BY _pre) FROM tree_ancestors('main', 'app', '{''file_path'': app.py}', 18);
----
[0, 6, 14, 15, 16]

query I
SELECT _pre FROM tree_next_sibling('main', 'app', '{''file_path'': app.py}', 6);
----
30

query I
SELECT _pre FROM tree_first_child('main', 'app', '{''file_path'': app.py}', 6);
----
7
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/run.py test/sql/32_traversal.test`
Expected: FAIL, `tree_children` not found.

- [ ] **Step 3: Write the traversal macros**

```sql
-- sql/08_traversal.sql
CREATE OR REPLACE MACRO tree_children(sch, nm, root_key, pre) AS TABLE
  SELECT * FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _parent = pre;

CREATE OR REPLACE MACRO tree_descendants(sch, nm, root_key, pre) AS TABLE
  WITH a AS (SELECT _pre, _size FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _pre = pre)
  SELECT p.* FROM tree_project(sch, nm) p, a WHERE p._root::VARCHAR = root_key AND p._pre BETWEEN a._pre + 1 AND a._pre + a._size;

-- Ancestors follow _parent upward. The C++ port replaces the recursion with a stack walk.
CREATE OR REPLACE MACRO tree_ancestors(sch, nm, root_key, pre) AS TABLE
  WITH RECURSIVE up USING KEY (_pre) AS (
    SELECT p.* FROM tree_project(sch, nm) p WHERE p._root::VARCHAR = root_key AND p._pre = (SELECT _parent FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _pre = pre)
    UNION ALL
    SELECT p.* FROM tree_project(sch, nm) p JOIN up ON p._root::VARCHAR = root_key AND p._pre = up._parent)
  SELECT * FROM up;

CREATE OR REPLACE MACRO tree_next_sibling(sch, nm, root_key, pre) AS TABLE
  WITH a AS (SELECT _next, _parent FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _pre = pre)
  SELECT p.* FROM tree_project(sch, nm) p, a WHERE p._root::VARCHAR = root_key AND p._pre = a._next AND p._parent IS NOT DISTINCT FROM a._parent;

CREATE OR REPLACE MACRO tree_first_child(sch, nm, root_key, pre) AS TABLE
  SELECT * FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _parent = pre AND _pre = pre + 1;
```

- [ ] **Step 4: Run the test**

Run: `python3 test/run.py test/sql/32_traversal.test`
Expected: PASS. The `root_key` literal must match DuckDB's struct-to-VARCHAR rendering, `{'file_path': app.py}`; if the rendering differs in this version, copy the value shown by `SELECT root_key FROM tree_state.partitions` into the test.

- [ ] **Step 5: Commit**

```bash
git add sql/08_traversal.sql test/sql/32_traversal.test
git commit -m "feat(m1.5): traversal macros over the canonical projection"
```

---

### Task 12: Mutant harness and planted mutants

**Files:**
- Create: `test/run_mutants.py`
- Create: `test/mutants/manifest.yaml`
- Create: `test/mutants/MN01_encoder_tiebreak_desc.sql`, `MN02_parent_same_level.sql`, `MN06_sibling_free_silent.sql`, `MN14_cross_partition.sql`, `MN15_p13_disabled.sql`, `MN17_row_surgery_delete.sql`, `MN18_abstract_open.sql`, `MN19_where_raw_relation.sql`, `MN21_type_default_null.sql`

**Interfaces:**
- Consumes: `test/run.py --mutant FILE`; the fragment macros named in Tasks 5 to 10.
- Produces: `python3 test/run_mutants.py` exits 0 only if every mutant is killed by at least one of its listed tests.

- [ ] **Step 1: Write the manifest**

```yaml
# test/mutants/manifest.yaml
# id is permanent. expect_fail lists test files that must FAIL when the mutant is applied.
- id: MN01
  file: MN01_encoder_tiebreak_desc.sql
  what: reverse the source-order tiebreak in DFS derivation
  expect_fail: [test/sql/10_projection.test, test/sql/20_derivations.test]
- id: MN02
  file: MN02_parent_same_level.sql
  what: derive parent as nearest prior row at the same level, not level - 1
  expect_fail: [test/sql/10_projection.test, test/sql/20_derivations.test]
- id: MN06
  file: MN06_sibling_free_silent.sql
  what: sibling combinators silently no-op under the sibling-free profile
  expect_fail: [test/sql/31_match.test]
- id: MN14
  file: MN14_cross_partition.sql
  what: descendant test crosses ROOT partitions
  expect_fail: [test/sql/12_dml.test, test/sql/31_match.test]
- id: MN15
  file: MN15_p13_disabled.sql
  what: INSERT of a partition violating P13 accepted
  expect_fail: [test/sql/12_dml.test, test/sql/20_derivations.test]
- id: MN17
  file: MN17_row_surgery_delete.sql
  what: pre-MATCH filter on a non-ROOT column accepted (row surgery)
  expect_fail: [test/sql/12_dml.test]
- id: MN18
  file: MN18_abstract_open.sql
  what: a closed abstract silently serves undeclared attributes
  expect_fail: [test/sql/11_ddl.test]
- id: MN19
  file: MN19_where_raw_relation.sql
  what: step WHERE compiled against the raw relation instead of the projection view
  expect_fail: [test/sql/31_match.test]
- id: MN21
  file: MN21_type_default_null.sql
  what: an S-empty tree fails structural matching (TYPE default lost)
  expect_fail: [test/sql/11_ddl.test, test/sql/31_match.test]
```

- [ ] **Step 2: Write the mutant files**

Each redefines exactly one macro with the wrong body.

```sql
-- test/mutants/MN01_encoder_tiebreak_desc.sql
CREATE OR REPLACE MACRO tree_sql_encoder_tiebreak() AS 'DESC';
```

```sql
-- test/mutants/MN02_parent_same_level.sql
CREATE OR REPLACE MACRO tree_sql_parent_join() AS
  '__p AS (SELECT a.*, b._pre AS _parent FROM __r a ASOF LEFT JOIN __r b ON a._root = b._root AND b._level = a._level AND b._pre < a._pre), ';
```

```sql
-- test/mutants/MN06_sibling_free_silent.sql
-- Drop the profile refusal: rebuild tree_compile_match's n CTE check by redefining the combinator to succeed and removing the error.
-- Simplest faithful mutant: make 'next' and 'after' compile to a no-op predicate so they silently return the empty or full set.
CREATE OR REPLACE MACRO tree_sql_comb(op, a, b) AS
  CASE op
    WHEN 'desc'  THEN b || '._root = ' || a || '._root AND ' || b || '._pre BETWEEN ' || a || '._pre + 1 AND ' || a || '._pre + ' || a || '._size'
    WHEN 'child' THEN b || '._root = ' || a || '._root AND ' || b || '._parent = ' || a || '._pre'
    ELSE 'false' END;
```

Note: MN06 must also bypass the refusal in `tree_compile_match`. Because the refusal lives in the `n` CTE, the mutant file additionally redefines `tree_compile_match` with the `WHEN kind = 'step' AND op IN ('next', 'after') ...` branch removed. Copy the macro from `sql/07_match.sql` into the mutant file and delete that one `WHEN` branch; the test `31_match.test` then fails at the `SIBLING_ORDER` expectation, which is the kill.

```sql
-- test/mutants/MN14_cross_partition.sql
CREATE OR REPLACE MACRO tree_sql_comb(op, a, b) AS
  CASE op
    WHEN 'desc'  THEN b || '._pre BETWEEN ' || a || '._pre + 1 AND ' || a || '._pre + ' || a || '._size'
    WHEN 'child' THEN b || '._parent = ' || a || '._pre'
    WHEN 'next'  THEN b || '._parent = ' || a || '._parent AND ' || b || '._pre = ' || a || '._pre + ' || a || '._size + 1'
    WHEN 'after' THEN b || '._parent = ' || a || '._parent AND ' || b || '._pre > ' || a || '._pre'
    ELSE error('tree_match: unknown combinator ' || op) END;
-- and the derived size must also ignore roots for the mutant to bite in 12_dml (multi-file scripts fixture)
CREATE OR REPLACE MACRO tree_sql_size_expr() AS
  'COALESCE((SELECT min(b._pre) FROM __p b WHERE b._pre > a._pre AND b._level <= a._level), max(a._pre) OVER () + 1) - a._pre - 1';
```

```sql
-- test/mutants/MN15_p13_disabled.sql
CREATE OR REPLACE MACRO tree_sql_p13_pred() AS 'false';
```

```sql
-- test/mutants/MN17_row_surgery_delete.sql
CREATE OR REPLACE MACRO tree_sql_delete_stmt(tbl, root_predicate) AS
  'DELETE FROM ' || tbl || ' WHERE ' || root_predicate;
```

```sql
-- test/mutants/MN18_abstract_open.sql
-- Abstract trees default to open attributes. Redefine tree_compile_create's attr default by wrapping: copy the macro from sql/03_ddl.sql
-- and change  COALESCE(shape.semantic.attr, CASE WHEN abstract THEN '' ELSE '*' END)  to  COALESCE(shape.semantic.attr, '*').
```

```sql
-- test/mutants/MN19_where_raw_relation.sql
-- The where clause looks at the raw source instead of the projection row. Copy tree_sql_clause from sql/07_match.sql and change the 'where' branch to:
--   WHEN 'where' THEN 'EXISTS (SELECT 1 FROM read_parquet(''test/data/app.parquet'') __w WHERE __w.node_id = §._pre AND ' || value || ')'
-- (the raw relation is the fixture the closed-shape test uses; the point is that `peek` resolves and the refusal disappears.)
```

```sql
-- test/mutants/MN21_type_default_null.sql
-- TYPE no longer defaults to 'node'. Copy tree_compile_projection from sql/02_projection.sql and change
--   COALESCE(shape.semantic.type, '''node''') AS type_sql   to   COALESCE(shape.semantic.type, 'NULL::VARCHAR') AS type_sql
```

For MN06, MN18, MN19, and MN21 the mutant file holds the full copied macro with the one edit described in its comment; the copy is made at implementation time from the then-current file so the mutant differs from the base in exactly one place.

- [ ] **Step 3: Write the harness**

```python
#!/usr/bin/env python3
"""Apply each mutant and require at least one listed test to fail."""
import os, subprocess, sys, yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
manifest = yaml.safe_load(open(os.path.join(ROOT, "test/mutants/manifest.yaml")))
alive = []
for m in manifest:
    path = os.path.join(ROOT, "test/mutants", m["file"])
    killed_by = []
    for t in m["expect_fail"]:
        r = subprocess.run([sys.executable, os.path.join(ROOT, "test/run.py"), os.path.join(ROOT, t), "--mutant", path],
                           capture_output=True, text=True)
        if r.returncode != 0:
            killed_by.append(t)
    status = "KILLED" if killed_by else "SURVIVED"
    print(f"{m['id']} {status}: {m['what']}" + (f"  (by {', '.join(killed_by)})" if killed_by else ""))
    if not killed_by:
        alive.append(m["id"])
if alive:
    print("surviving mutants:", ", ".join(alive)); sys.exit(1)
print("all mutants killed")
```

If `yaml` is not installed, `pip install pyyaml` or replace the manifest with a JSON file and `json.load`.

- [ ] **Step 4: Run the harness**

Run: `python3 test/run_mutants.py`
Expected: every line `KILLED`, exit 0. Also confirm the base suite still passes: `python3 test/run.py test/sql`. A surviving mutant means a missing test: add the test to the suite named in the manifest, never edit the manifest to drop the expectation.

- [ ] **Step 5: Commit**

```bash
git add test/run_mutants.py test/mutants
git commit -m "test: mutant harness and planted mutants MN1, MN2, MN6, MN14, MN15, MN17, MN18, MN19, MN21"
```

---

### Task 13: README, FINDINGS, and the runbook

**Files:**
- Modify: `README.md` (status block and a "Running the prototype" section)
- Create: `FINDINGS.md`

- [ ] **Step 1: Update the README status**

Replace the status blockquote with:

```markdown
> **Status: macro prototype.** `sql/` holds a macro-only reference implementation of M0, M1, and M1½: the catalog, the projection compiler, both basis derivations, forest DML with P13 on ingest, and TREEQL matching through `tree_steps`. It runs on DuckDB 1.5.5 with no extension dependency. `test/sql/` holds the sqllogictest suites and `test/mutants/` the planted mutants; both carry over unchanged to the C++ extension. The design is in [`docs/superpowers/specs/2026-09-13-duckent-core-design.md`](docs/superpowers/specs/2026-09-13-duckent-core-design.md).
```

Add before "Documents":

```markdown
## Running the prototype

```bash
pip install duckdb==1.5.5 pyyaml
python3 test/run.py test/sql          # the suites
python3 test/run_mutants.py           # every planted mutant must die
python3 test/gen_fixtures.py          # only to regenerate fixtures; needs sitting_duck and markdown
```

Quick tour in a DuckDB session after loading `sql/*.sql` in order (the runner does this for you):

```sql
CALL tree_ddl_create('main', 'app', tree_spec(
  tree_shape(root := 'file_path', "order" := 'node_id', level := 'depth', size := 'descendant_count',
             semantic := tree_semantic(type := 'type', id := 'name')),
  source := 'read_parquet(''test/data/app.parquet'')'));
FROM tree_match('main', 'app', tree_steps([{type: 'function_definition', "as": 'f'}, {comb: 'child', type: 'block'}])) SELECT f.name;
```

In the macro phase `CALL tree_ddl_*`, the DML verbs, and `tree_match` are executed by the test runner, which compiles them with the `tree_compile_*` macros; in a bare session call the compilers yourself and run the returned SQL.
```

- [ ] **Step 2: Seed FINDINGS.md**

```markdown
# FINDINGS

What first contact showed. Newest first. Every oracle divergence gets an entry with adjudication before any test changes.

## 2026-09-13 design-phase findings (DuckDB 1.5.5)

- `query()` refuses text produced by a macro containing any subquery ("Table function cannot contain subqueries"), so a macro that reads the catalog cannot feed `query()`. Consequence: in the macro phase the runner executes compiled `tree_match` and DDL; pure string-building compilers (projection, derivations) still run through `query()`.
- Inside a recursive CTE with several `UNION ALL` branches, everything but the last branch is the base case. The recursive term must be one SELECT, and `recurring.<cte>` is legal only in FROM-clause position, never inside a correlated EXISTS.
- sitting_duck's `depth` is UINTEGER; `depth - 1` overflows. All canonical `_pre` and `_level` are cast to BIGINT.
- Derived `_parent` by ASOF join and derived `_size` by nearest-following-shallower-row match sitting_duck's native `parent_id` and `descendant_count` on every row of `app.py` (54/54).
- Partial struct casts to a custom type fill NULLs and silently drop unknown fields; the named-parameter constructors exist to catch typos.
- `MAP[...]` bracket access returns the value directly (NULL when missing); `SELECT alias FROM ...` yields the row as a STRUCT; `* REPLACE` and `* EXCLUDE` are available. The arrow lambda is deprecated in favor of `lambda x: ...`.
- Shipped `ast_select` accepts only a type, `#id`, or `.class` inside `:has(...)`; `.fn:not(:has(:docblock))` is unsupported there, so the shared corpus for M2 uses `.fn:not(:has(string))` on the sitting_duck side.
```

- [ ] **Step 3: Run the whole suite one more time**

Run: `python3 test/run.py test/sql && python3 test/run_mutants.py`
Expected: all PASS, all KILLED.

- [ ] **Step 4: Commit**

```bash
git add README.md FINDINGS.md
git commit -m "docs: prototype status, runbook, and design-phase findings"
```

---

## Self-review

**Spec coverage.** §2 schemas: Task 3 (tables, `has_semantic`, `order_source`), Task 6 (rules at create: storage, ORDER, ATTR defaults, KEY, LIKE copying). §3 types: Task 2. §4 operations: Tasks 6, 7, 8, 9, 10, 11; `tree_explain` in Task 10. §5 projection: Task 5, including BIGINT casts and derived O columns. §6 match: Task 10 covers linear chains, captures, NULL-definite clauses, S-less refusals, sibling-free refusals, unknown pseudo counting, overlay; `has`/`not` groups and the CSS front-end are M2 and out of this plan by the spec's scope cut. §7 testing: sqllogictest runner (Task 1), fixtures (Task 4), mutants MN1, MN2, MN6, MN14, MN15, MN17, MN18, MN19, MN21 (Task 12); MN3, MN5, MN7, MN8, MN12, MN13, MN22 to MN25 belong to M2. §9 repository plan: no build action now. §10 port targets: noted in code comments. §12: recorded in FINDINGS (Task 13).

**Placeholders.** The only values an executor fills in are the fixture counts `N`, `F`, `M` in Task 4, taken from the generator's output; and the four mutant files that copy a base macro with one edit, each edit spelled out.

**Type consistency.** `tree_shape` fields: `root, "order", key, level, parent, sibling_order, size, children, next, semantic` everywhere. `tree_semantic` fields: `type, id, classes, attr, attr_map, pseudo`. `tree_spec` fields: `shape, abstract, "like", source, storage`. Runner verbs: `tree_ddl_create, tree_ddl_drop, tree_ddl_alter, tree_insert, tree_replace, tree_delete, tree_check`, each with a `tree_compile_<verb>` macro of the same arity. Fragment macros mutated: `tree_sql_encoder_tiebreak, tree_sql_parent_join, tree_sql_size_expr, tree_sql_p13_pred, tree_sql_delete_stmt, tree_sql_comb, tree_sql_clause`. `tree_compile_match(sch, nm, sel, semantic := NULL)` matches the runner's rewrite and `tree_explain`.
