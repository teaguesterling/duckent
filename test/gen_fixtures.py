#!/usr/bin/env python3
"""Regenerate parquet fixtures. Needs sitting_duck and markdown installed. Run from repo root.

    python3 test/gen_fixtures.py                    # all four
    python3 test/gen_fixtures.py app readme         # just these, no astcss-eval checkout needed

`scripts` and `py_variety` are pinned by the astcss-eval manifest, so those two (and FIXTURES.md,
which records their commits) need that checkout; `app` and `readme` come from this repo alone and
must stay runnable without it, which is why the manifest is read lazily below.
"""
import hashlib, json, os, sys, duckdb

# astcss-eval pins both AST fixtures by content: `repo-small-py` is sitting_duck's `scripts/` at
# commit 4eeeee6 (our scripts.parquet), `py-variety` is its python test data at db1b043. The
# commits below are read from that manifest, and the bytes we read are checked against it, so the
# provenance recorded in FIXTURES.md cannot drift away from what was actually parsed.
ASTCSS = os.path.expanduser("~/Projects/astcss-eval")
_MANIFEST = []


def manifest():
    """The astcss-eval fixture manifest, read on first use. Reading it at import time would make
    a checkout of astcss-eval a precondition of regenerating app.parquet, which does not use it."""
    if not _MANIFEST:
        path = os.path.join(ASTCSS, "fixtures", "MANIFEST.json")
        if not os.path.exists(path):
            raise SystemExit("%s is missing: scripts, py_variety and FIXTURES.md are pinned by it. "
                             "Run `python3 test/gen_fixtures.py app readme` for the fixtures that "
                             "do not need it." % path)
        _MANIFEST.append(json.load(open(path))["fixtures"])
    return _MANIFEST[0]


def pinned_commit(fixture, directory):
    """The manifest commit for `fixture`, after checking every pinned file's sha256 in `directory`."""
    entry = manifest()[fixture]
    for f in entry["files"]:
        path = os.path.join(directory, f["path"])
        got = hashlib.sha256(open(path, "rb").read()).hexdigest()
        if got != f["sha256"]:
            raise SystemExit(f"{path} is not the pinned {fixture} byte content ({got} != {f['sha256']})")
    return entry["commit"]



# The corpus aliases: sitting_duck's `.<alias>` class filter is `is_semantic_type(semantic_type,
# upper(alias))` restricted to construct rows. Baking the result into the fixture as a plain
# VARCHAR[] is what lets every corpus tree declare CLASSES and every frozen-reference test run
# WITHOUT sitting_duck loaded.
ALIASES = ["fn", "class", "call", "try", "catch", "throw", "finally", "import",
           "loop", "if", "comp", "mod", "jump", "coll", "comment", "str", "def"]
ALIAS_LIST = "[" + ", ".join("'%s'" % a for a in ALIASES) + "]"

# `css_classes`  the aliases this row carries;   `is_element`  sitting_duck's ELEMENT predicate;
# `params`  the arity `[params=N]` compares against (sitting_duck reads `len(parameters)`).
DERIVED = f"""*,
    CASE WHEN is_construct(flags)
         THEN list_filter({ALIAS_LIST}, lambda a: is_semantic_type(semantic_type, upper(a)))
         ELSE []::VARCHAR[] END AS css_classes,
    is_construct(flags) AS is_element,
    len(parameters)::INTEGER AS params"""


def gen_app(con):
    con.execute(f"""COPY (SELECT {DERIVED} FROM (SELECT * REPLACE ('app.py' AS file_path)
                         FROM read_ast('docs/examples/app.py')))
                   TO 'test/data/app.parquet' (FORMAT PARQUET)""")


def gen_scripts(con):
    """Returns the manifest commit the bytes were checked against."""
    sd = os.path.expanduser("~/Projects/sitting_duck")
    commit = pinned_commit("repo-small-py", os.path.join(sd, "scripts"))
    con.execute(f"""COPY (SELECT {DERIVED} FROM (SELECT * REPLACE (replace(file_path, '{sd}/', '') AS file_path)
                         FROM read_ast('{sd}/scripts/*.py')))
                   TO 'test/data/scripts.parquet' (FORMAT PARQUET)""")
    return commit


def gen_py_variety(con):
    pv = os.path.join(ASTCSS, "fixtures", "py-variety")
    pv_commit = pinned_commit("py-variety", pv)
    con.execute(f"""COPY (SELECT {DERIVED} FROM (SELECT * REPLACE (regexp_replace(file_path, '.*/', '') AS file_path)
                         FROM read_ast('{pv}/*.py')))
                   TO 'test/data/py_variety.parquet' (FORMAT PARQUET)""")
    return pv_commit


def gen_readme(con):
    con.execute("COPY (FROM read_markdown_blocks('README.md')) TO 'test/data/readme_blocks.parquet' (FORMAT PARQUET)")


ALL = ("app", "scripts", "py_variety", "readme")
want = sys.argv[1:] or list(ALL)
for name in want:
    if name not in ALL:
        raise SystemExit("unknown fixture %r: pick from %s" % (name, ", ".join(ALL)))

con = duckdb.connect()
if set(want) - {"readme"}:
    con.execute("LOAD sitting_duck")
if "readme" in want:
    con.execute("LOAD markdown")
if "app" in want:
    gen_app(con)
commit = gen_scripts(con) if "scripts" in want else None
pv_commit = gen_py_variety(con) if "py_variety" in want else None
if "readme" in want:
    gen_readme(con)

# FIXTURES.md records every fixture's row count and the two pinned commits, so it can only be
# rewritten by a run that regenerated all four. A partial run leaves the committed file alone
# rather than writing a half-true one.
if set(want) != set(ALL):
    print("ok (partial: %s) -- test/data/FIXTURES.md left alone" % ", ".join(want))
    raise SystemExit(0)
n_app = con.execute("SELECT count(*) FROM 'test/data/app.parquet'").fetchone()[0]
n_scr, n_files = con.execute("SELECT count(*), count(DISTINCT file_path) FROM 'test/data/scripts.parquet'").fetchone()
n_pv, n_pv_files = con.execute("SELECT count(*), count(DISTINCT file_path) FROM 'test/data/py_variety.parquet'").fetchone()
n_md = con.execute("SELECT count(*) FROM 'test/data/readme_blocks.parquet'").fetchone()[0]
open("test/data/FIXTURES.md", "w").write(f"""# Fixture provenance

Generated by `python3 test/gen_fixtures.py` with DuckDB {duckdb.__version__}.

| file | source | rows |
|---|---|---|
| app.parquet | sitting_duck `read_ast('docs/examples/app.py')` | {n_app} |
| scripts.parquet | sitting_duck `read_ast` over `sitting_duck/scripts/*.py` at commit `{commit}` | {n_scr} rows, {n_files} files |
| py_variety.parquet | sitting_duck `read_ast` over `~/Projects/astcss-eval/fixtures/py-variety/*.py` at manifest commit `{pv_commit}` | {n_pv} rows, {n_pv_files} files |
| readme_blocks.parquet | markdown `read_markdown_blocks('README.md')` | {n_md} |
| employees.csv, categories.csv, coa.csv, ledger.csv | hand-written | see files |

`scripts.parquet` is astcss-eval's `repo-small-py` fixture; `py_variety.parquet` is its `py-variety`
fixture, both at the commits `~/Projects/astcss-eval/fixtures/MANIFEST.json` pins. `file_path` is the
basename (`scripts.parquet` keeps the `scripts/` directory it was read from; every file of a fixture
lives in one directory, so ordering by `file_path` is ordering by basename either way).

The three AST parquets carry three derived columns beyond `read_ast`'s own, so the corpus trees can
declare CLASSES, ELEMENT and the `params` attribute without sitting_duck at query time:

| column | type | derivation |
|---|---|---|
| `css_classes` | `VARCHAR[]` | the corpus aliases ({', '.join('`%s`' % a for a in ALIASES)}) filtered by `is_semantic_type(semantic_type, upper(alias))` on construct rows, `[]` elsewhere |
| `is_element` | `BOOLEAN` | `is_construct(flags)` |
| `params` | `INTEGER` | `len(parameters)` — what sitting_duck's `[params=N]` compares |

Regenerating changes row counts if the sources changed; update the tests deliberately, never silently.
""")
print("ok", n_app, n_scr, n_files, n_pv, n_pv_files, n_md)
