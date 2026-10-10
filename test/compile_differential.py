#!/usr/bin/env python3
"""Compare each verb's compiled statement list: plan repo vs extension.

Both call the same tree_compile_* macro, so identical inputs must give identical
text. A divergence is argument marshalling in the C++ layer -- the bug class the
corpus is blind to, because the corpus only ever sees the EFFECT of the
statements, never the statements themselves.

Two distinct comparisons live here, and they test two different things:

  CASES (via `check_macro_cases`): calls `SELECT tree_compile_X(args)` directly
  on both sides, with `args` spliced as literal SQL text (matching what
  test/run.py's Session.execute does for the plan repo, and what a bare SQL
  macro call does on the extension). Because src/sql_macros/*.sql is enforced
  byte-identical to the plan repo's sql/*.sql (scripts/check_macro_identity.py),
  this mostly measures whether the two runtimes evaluate the same macro body
  the same way given the same literal arguments -- environment parity, and a
  broad regression net over argument shapes (including the adversarial ones
  below) that no corpus assertion happens to pin.

  It does NOT exercise src/duckent_sql.cpp's CompileStatements: that C++
  function only runs when a verb is invoked as a table function (`CALL
  tree_ddl_alter(...)`), where DuckDB folds arguments to bound Values before
  the macro ever sees them -- a direct `SELECT tree_compile_alter(...)` call
  never goes through that folding. This is exactly the asymmetry commit
  704f8b8 measured: a bare NULL against a LogicalType::ANY table-function
  parameter arrives as a NULL of type INTEGER, which misbinds, while the same
  NULL spliced as literal text into a direct macro call never did.

  VERB_CASES (via `check_verb_cases`): runs the real `CALL verb(args)` against
  the built extension -- the one path that drives CompileStatements -- and
  compares its observable outcome (refusal message, or success) against the
  plan repo's reference behavior for the identical CALL, via
  test/run.py's own Session.execute (which compiles by splicing argument TEXT,
  the behavor CompileStatements is written to reproduce). This is the half
  that actually exercises the marshalling bug class the corpus cannot see;
  CASES alone cannot (see above), so VERB_CASES exists to cover it.
"""
import argparse
import json
import os
import subprocess
import sys

# ---------------------------------------------------------------------------
# Setup fragments, run inside the SAME session as the measured call. Most
# tree_compile_* macros refuse outright (tree_dml_context, or the EXISTS
# check in tree_compile_drop) when the tree named by (sch, nm) is not already
# registered in the catalog -- only tree_compile_create is meant to be called
# against a name that does not exist yet. So every macro except create needs
# a real tree in place first, built by actually running tree_ddl_create.
SETUP_CREATE_APP = [
    "CALL tree_ddl_create('main', 'app', tree_spec("
    "tree_shape(root := 'file_path', \"order\" := 'node_id', level := 'depth'), "
    "source := 'read_parquet(''test/data/app.parquet'')'));"
]

# ---------------------------------------------------------------------------
# CASES: (label, macro, args, setup)
#
# Argument lists were checked against the actual macro signatures in the plan
# repo's sql/ (and test/run.py's compile_macro_name) before being written here;
# see the task report for what the brief's version got wrong. In short: the
# brief's seven happy-path calls were right about argument ORDER and NAMES,
# but wrong to assume a fresh session -- six of the seven macros
# (tree_compile_drop/alter/insert/replace/delete/check) raise "not found"
# against a catalog that was never seeded. The `setup` field fixes that; the
# calls after each macro's happy-path case are the adversarial ones Task 9's
# brief did not include.
CASES = [
    # --- one happy path per macro, in signature order -----------------------
    ("create: happy path", "tree_compile_create", [
        "'main'", "'app'",
        "tree_spec(tree_shape(root := 'file_path', \"order\" := 'node_id', level := 'depth'), "
        "source := 'read_parquet(''test/data/app.parquet'')')",
    ], []),
    ("drop: happy path", "tree_compile_drop", ["'main'", "'app'"], SETUP_CREATE_APP),
    ("alter: happy path", "tree_compile_alter",
     ["'main'", "'app'", "tree_semantic(type := 'type')"], SETUP_CREATE_APP),
    ("insert: happy path", "tree_compile_insert",
     ["'main'", "'app'", "'(SELECT * FROM read_parquet(''test/data/app.parquet''))'"], SETUP_CREATE_APP),
    ("replace: happy path", "tree_compile_replace",
     ["'main'", "'app'", "'(SELECT * FROM read_parquet(''test/data/app.parquet''))'"], SETUP_CREATE_APP),
    ("delete: happy path", "tree_compile_delete", ["'main'", "'app'", "'true'"], SETUP_CREATE_APP),
    ("check: happy path", "tree_compile_check", ["'main'", "'app'"], SETUP_CREATE_APP),

    # --- bare NULL, and the typed spellings the 704f8b8 fix is about,
    #     in every position that accepts one -----------------------------
    ("alter: bare NULL semantic", "tree_compile_alter",
     ["'main'", "'app'", "NULL"], SETUP_CREATE_APP),
    ("alter: NULL::TREE_SEMANTIC semantic", "tree_compile_alter",
     ["'main'", "'app'", "NULL::TREE_SEMANTIC"], SETUP_CREATE_APP),
    ("alter: NULL::STRUCT(...) semantic", "tree_compile_alter",
     ["'main'", "'app'", "NULL::STRUCT(abstract BOOLEAN)"], SETUP_CREATE_APP),
    ("create: bare NULL spec", "tree_compile_create",
     ["'main'", "'newtree'", "NULL"], []),
    ("create: NULL::TREE_SPEC spec", "tree_compile_create",
     ["'main'", "'newtree'", "NULL::TREE_SPEC"], []),
    ("insert: bare NULL source", "tree_compile_insert",
     ["'main'", "'app'", "NULL"], SETUP_CREATE_APP),
    ("replace: bare NULL source", "tree_compile_replace",
     ["'main'", "'app'", "NULL"], SETUP_CREATE_APP),
    ("delete: bare NULL root_predicate", "tree_compile_delete",
     ["'main'", "'app'", "NULL"], SETUP_CREATE_APP),
    ("drop: bare NULL nm", "tree_compile_drop", ["'main'", "NULL"], []),
    ("alter: bare NULL nm", "tree_compile_alter",
     ["'main'", "NULL", "tree_semantic(type := 'type')"], []),

    # --- string arguments with characters that would break the generated
    #     SQL if nm were spliced unquoted instead of going through
    #     tree_sql_lit/tree_sql_ident; abstract+no-source keeps each case
    #     small and free of the parquet fixture ----------------------------
    ("create: nm has a single quote", "tree_compile_create",
     ["'main'", "'weird''s name'", "tree_spec(tree_shape(level := 'depth'), abstract := true)"], []),
    ("create: nm has a double quote", "tree_compile_create",
     ["'main'", "'weird\"name'", "tree_spec(tree_shape(level := 'depth'), abstract := true)"], []),
    ("create: nm has a backslash", "tree_compile_create",
     ["'main'", "'weird\\name'", "tree_spec(tree_shape(level := 'depth'), abstract := true)"], []),
    ("create: nm has a semicolon", "tree_compile_create",
     ["'main'", "'weird;name'", "tree_spec(tree_shape(level := 'depth'), abstract := true)"], []),
    ("create: nm has --", "tree_compile_create",
     ["'main'", "'weird--name'", "tree_spec(tree_shape(level := 'depth'), abstract := true)"], []),
    ("create: nm has $$", "tree_compile_create",
     ["'main'", "'weird$$name'", "tree_spec(tree_shape(level := 'depth'), abstract := true)"], []),
    ("create: nm is empty", "tree_compile_create",
     ["'main'", "''", "tree_spec(tree_shape(level := 'depth'), abstract := true)"], []),
    ("create: nm has a newline", "tree_compile_create",
     ["'main'", "'weird\nname'", "tree_spec(tree_shape(level := 'depth'), abstract := true)"], []),
    ("create: nm is hostile (all of the above, at once)", "tree_compile_create",
     ["'main'", "'it''s \"all\" together; -- $$ \\ done\nstill going'",
      "tree_spec(tree_shape(level := 'depth'), abstract := true)"], []),
]

# ---------------------------------------------------------------------------
# VERB_CASES: (label, verb, args, setup) -- the historical bug, exercised
# through the real CALL path on the extension (which drives CompileStatements)
# against test/run.py's Session.execute as the reference (which splices
# argument TEXT and so cannot misbind, by construction -- it is what
# CompileStatements's NULL-as-literal fix is written to reproduce).
VERB_CASES = [
    ("CALL tree_ddl_alter: bare NULL semantic", "tree_ddl_alter",
     ["'main'", "'bare'", "NULL"], None),
    ("CALL tree_ddl_alter: NULL::TREE_SEMANTIC semantic", "tree_ddl_alter",
     ["'main'", "'bare'", "NULL::TREE_SEMANTIC"], None),
    ("CALL tree_ddl_alter: NULL::STRUCT(...) semantic", "tree_ddl_alter",
     ["'main'", "'bare'", "NULL::STRUCT(abstract BOOLEAN)"], None),
]
VERB_SETUP = (
    "CALL tree_ddl_create('main', 'bare', tree_spec(tree_shape(level := 'depth'), "
    "source := 'read_parquet(''test/data/app.parquet'')'));"
)


def error_message(text):
    """DuckDB's message without the SQL it echoes back ("\\nLINE 1: ..."), matching
    test/run.py's own error_message -- so a comparison can only fail on what an
    error SAYS, never on the statement that raised it or where it was raised."""
    return text.split("\nLINE ")[0].strip()


# ---------------------------------------------------------------------------
# CASES: direct macro-level comparison
#
# Case data (setup statements, the SQL to run) crosses the subprocess boundary
# as JSON on stdin, not as text substituted into a Python source string: the
# adversarial args deliberately contain quotes, backslashes and newlines, and
# any of those breaks naive `"...%s..." % arg`-style embedding. JSON handles
# the escaping; the harness script itself is fixed, case-independent text.
PLAN_SCRIPT = """
import sys, json
sys.path.insert(0, 'test')
from run import Session
req = json.loads(sys.stdin.read())
s = Session()
for stmt in req['setup']:
    s.execute(stmt)
try:
    r = s.con.execute(req['sql']).fetchone()[0]
    print(json.dumps({"ok": r}))
except Exception as e:
    print(json.dumps({"error": str(e).split(chr(10) + "LINE ")[0].strip()}))
"""


def _run_plan_script(plan_repo, script, setup, sql):
    out = subprocess.run([sys.executable, "-c", script],
                         input=json.dumps({"setup": setup, "sql": sql}),
                         capture_output=True, text=True, cwd=plan_repo)
    if out.returncode != 0:
        return {"error": "harness failure (plan repo): " + out.stderr.strip()[-800:]}
    try:
        return json.loads(out.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": "harness failure (plan repo): no parseable output: " + out.stdout[-800:]}


def via_plan_repo(plan_repo, setup, macro, args):
    sql = "SELECT %s(%s)" % (macro, ", ".join(args))
    return _run_plan_script(plan_repo, PLAN_SCRIPT, setup, sql)


def via_extension(duckdb_bin, setup, macro, args):
    sql = "\n".join(setup) + ("\n" if setup else "") + \
        "SELECT to_json(%s(%s));" % (macro, ", ".join(args))
    out = subprocess.run([duckdb_bin, "-noheader", "-list", "-c", sql],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return {"error": error_message(out.stderr.strip())}
    lines = [l for l in out.stdout.strip().splitlines() if l.strip()]
    if not lines:
        return {"error": "harness failure (extension): no output"}
    try:
        return {"ok": json.loads(lines[-1])}
    except ValueError:
        return {"error": "harness failure (extension): no parseable output: " + lines[-1][:800]}


def check_macro_cases(plan_repo, duckdb_bin):
    bad = []
    for label, macro, args, setup in CASES:
        a = via_plan_repo(plan_repo, setup, macro, args)
        b = via_extension(duckdb_bin, setup, macro, args)
        if a != b:
            bad.append((label, macro, a, b))
    return bad


# ---------------------------------------------------------------------------
# VERB_CASES: real CALL vs. the plan repo's reference CALL handling

PLAN_VERB_SCRIPT = """
import sys, json
sys.path.insert(0, 'test')
from run import Session
req = json.loads(sys.stdin.read())
s = Session()
s.execute(req['setup'])
try:
    s.execute(req['call'])
    print(json.dumps({"ok": True}))
except Exception as e:
    print(json.dumps({"error": str(e).split(chr(10) + "LINE ")[0].strip()}))
"""


def via_plan_repo_call(plan_repo, setup, verb, args):
    call = "CALL %s(%s);" % (verb, ", ".join(args))
    out = subprocess.run([sys.executable, "-c", PLAN_VERB_SCRIPT],
                         input=json.dumps({"setup": setup, "call": call}),
                         capture_output=True, text=True, cwd=plan_repo)
    if out.returncode != 0:
        return {"error": "harness failure (plan repo): " + out.stderr.strip()[-800:]}
    try:
        return json.loads(out.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": "harness failure (plan repo): no parseable output: " + out.stdout[-800:]}


def via_extension_call(duckdb_bin, setup, verb, args):
    sql = (setup + "\n" if setup else "") + "CALL %s(%s);" % (verb, ", ".join(args))
    out = subprocess.run([duckdb_bin, "-noheader", "-list", "-c", sql],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return {"error": error_message(out.stderr.strip())}
    return {"ok": True}


def check_verb_cases(plan_repo, duckdb_bin):
    bad = []
    for label, verb, args, setup in VERB_CASES:
        setup = setup if setup is not None else VERB_SETUP
        a = via_plan_repo_call(plan_repo, setup, verb, args)
        b = via_extension_call(duckdb_bin, setup, verb, args)
        if a != b:
            bad.append((label, verb, a, b))
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan-repo", required=True)
    ap.add_argument("--duckdb", required=True, help="the built duckdb shell with duckent linked")
    args = ap.parse_args()

    # Refuse legibly when --plan-repo is not the plan repo, instead of reporting every case
    # as a divergence. Measured: pointing this at the extension itself -- the mistake a stale
    # CI checkout would now make, since `teaguesterling/duckent` names the extension and the
    # reference is `teaguesterling/duckent-plan` -- reported 29 DIVERGENCEs whose `plan` side
    # was all the same `ModuleNotFoundError: No module named 'run'`. That exits non-zero, so
    # it is not a vacuous pass, but "29 divergences" is a wrong diagnosis of "wrong
    # directory", and a wrong diagnosis in a differential is expensive to chase.
    runner = os.path.join(args.plan_repo, "test", "run.py")
    if not os.path.isfile(runner):
        sys.stderr.write(
            "compile differential FAILED: --plan-repo %s is not the duckent plan repo "
            "(no test/run.py).\n  The plan repo is teaguesterling/duckent-plan; "
            "`teaguesterling/duckent` is now this extension.\n"
            % os.path.abspath(args.plan_repo)
        )
        sys.exit(1)

    bad_macros = check_macro_cases(args.plan_repo, args.duckdb)
    bad_verbs = check_verb_cases(args.plan_repo, args.duckdb)

    for label, macro, a, b in bad_macros:
        sys.stderr.write("DIVERGENCE in %s (%s)\n  plan: %r\n  ext : %r\n" % (label, macro, a, b))
    for label, verb, a, b in bad_verbs:
        sys.stderr.write("DIVERGENCE in %s (CALL %s)\n  plan: %r\n  ext : %r\n" % (label, verb, a, b))

    if bad_macros or bad_verbs:
        sys.exit(1)
    print("compile differential: all %d macro cases and %d verb cases agree"
          % (len(CASES), len(VERB_CASES)))


if __name__ == "__main__":
    main()
