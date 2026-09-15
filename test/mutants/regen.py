#!/usr/bin/env python3
"""Regenerate the copy-and-edit mutants from the macros they copy.

A mutant of the copy-and-edit kind is "that macro, with one edit". Keeping the copy by hand
does not hold that claim: Task 13's `error(` -> `tree_err(` sweep moved ten of them out from
under their originals at once, and nothing said so -- they went on killing, because a macro
from two commits ago still fails the tests a wrong macro fails. The kill was no longer
evidence about the edit.

So the copy is generated. For each mutant below this file

  * extracts the named macro(s) VERBATIM from `sql/*.sql` -- comment block included, so the
    diff between a mutant and its control is exactly the planted edit and nothing else;
  * writes `<file>.control.sql`, the copy with NO edit, which `test/run_mutants.py --verify`
    applies to prove the kill is caused by the edit rather than by the copy being stale;
  * applies the planted edit (each `old` must occur the stated number of times, or this
    script fails rather than writing a mutant that mutates nothing) and writes `<file>`.

The header of each mutant file -- everything above the MARKER line -- is hand-written and is
PRESERVED across regenerations: it is where the mutant says what it is and why it is wrong.
Everything below the marker is generated; edit the source macro or the `edits` here instead.

Mutants that are not copies (MN01, MN02, MN08, MN14, MN15) are listed with no `edits`: their
override is written from scratch and stays hand-written, but they still get a control file,
because "the listed suites pass with the original macro" is worth proving for them too.

Usage:  python3 test/mutants/regen.py [--check]
        --check writes nothing and exits non-zero if any file is out of date.
"""
import argparse, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.join(ROOT, "test/mutants")
MARKER = ("-- vvv GENERATED BELOW by test/mutants/regen.py from %s -- do not edit by hand vvv\n"
          "-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)")

# id -> (source file, [macro names], [(old, new, count), ...])
SPEC = {
    "MN01": ("sql/02_projection.sql", ["tree_sql_encoder_tiebreak"], []),
    "MN02": ("sql/02_projection.sql", ["tree_sql_parent_join"], []),
    "MN14": ("sql/07_match.sql", ["tree_sql_subtree", "tree_sql_children", "tree_sql_siblings"], []),
    "MN15": ("sql/04_dml.sql", ["tree_sql_p13_pred"], []),

    "MN03": ("sql/02_projection.sql", ["tree_compile_projection"], [
        ("THEN 'CAST(a.__size_raw AS BIGINT)' END", "THEN 'CAST(a.__size_raw AS BIGINT) - 1' END", 1)]),

    "MN05": ("sql/07_match.sql", ["tree_sql_chain"], [
        ("ELSE tree_sql_comb(COALESCE((steps[1]).op, 'desc'), anchor, (steps[1]).alias, p, elem)"
         " || ' AND (' || (steps[1]).pred || ')' END",
         "ELSE tree_sql_children(anchor, (steps[1]).alias)"
         " || ' AND (' || (steps[1]).pred || ')' END", 1)]),

    "MN06": ("sql/07_match.sql", ["tree_sql_comb", "tree_compile_match"], [
        ("    WHEN 'next'  THEN tree_sql_next_sibling(a, b, p, elem)\n"
         "    WHEN 'after' THEN tree_sql_after(a, b)\n",
         "    -- the mutation, half one: 'next' and 'after' fall through to the ELSE below\n", 1),
        ("    -- COALESCE: only the first step of the outer chain may carry a NULL op, and tree_sql_chain\n"
         "    -- defaults that one before it gets here, so a NULL arriving is hand-built IR -- which is\n"
         "    -- exactly the case that must be told what is wrong instead of receiving a NULL fragment.\n"
         "    ELSE tree_err('tree_match: unknown combinator ' || COALESCE(op, '<NULL>')) END;",
         "    -- ... which is a predicate that never raises and never matches\n"
         "    ELSE 'false' END;", 1),
        ("              WHEN (SELECT profile FROM t) = 'sibling_free'\n"
         "                   AND ((ir.kind = 'step' AND ir.op IN ('next', 'after'))\n"
         "                        OR (ir.kind = 'pseudo' AND list_contains(tree_builtin_pseudos(), ir.value)))\n"
         "              THEN tree_err('tree_match: tree ' || sch || '.' || nm || ' is sibling-free"
         " (no SIBLING_ORDER declared); SIBLING, FOLLOWING, :first-child and :last-child are unavailable')\n",
         "              -- the mutation, half two: the sibling-free refusal branch is gone\n", 1)]),

    "MN07": ("sql/07_match.sql", ["tree_sql_clause"], [
        ("WHEN 'pseudo_unknown' THEN 'false'",
         "-- the mutation\n    WHEN 'pseudo_unknown' THEN tree_err('tree_match: unknown pseudo-class ' || value)", 1)]),

    "MN12": ("sql/00_types.sql", ["tree_expand_pseudo"], [
        ("                      -- spec §7, amended: identity dedup. The spec's literal text excludes a\n"
         "                      -- candidate only by name collision; that alone double-binds a macro\n"
         "                      -- already claimed by a prefix declaration (e.g. sel_ast_leaf, which also\n"
         "                      -- starts with the shared tier's own \"sel_\") under a second, derived name.\n"
         "                      -- A prefix declaration is a namespace claim: a macro already bound under\n"
         "                      -- any name -- locally or via a prefix -- is not re-bound by the shared\n"
         "                      -- tier under another one.\n"
         "                      AND NOT list_contains(list_transform(lp.bound, lambda y: (y).name),"
         " substr(f.function_name, length(tree_shared_pseudo_prefix()) + 1))\n"
         "                      AND NOT list_contains(list_transform(lp.bound, lambda y: (y).macro), f.function_name)\n",
         "                      -- the mutation, edit (1): the name and macro dedup filters are gone\n", 1),
        ("\n)\nSELECT {type: (sem).type,",
         "\n),\n"
         "-- the mutation, edit (2): shared first, local/prefix second, and the FIRST occurrence of a\n"
         "-- name wins -- so the shared tier overrides what the tree declared. The dedup is needed\n"
         "-- because tree_sql_pseudo_map builds a MAP and a repeated key raises.\n"
         "allb AS (SELECT list_concat(shared.extra, lp.bound) AS v FROM lp, shared),\n"
         "ded AS (SELECT list_filter(v, lambda x, i:\n"
         "                 list_position(list_transform(v, lambda y: (y).name), (x).name) = i) AS v FROM allb)\n"
         "SELECT {type: (sem).type,", 1),
        ("ELSE list_concat(lp.bound, shared.extra) END", "ELSE ded.v END", 1),
        ("\nFROM lp, shared);", "\nFROM ded);", 1)]),

    "MN13": ("sql/07_match.sql", ["tree_sql_clause"], [
        ("        WHEN has_map\n"
         "          THEN 'COALESCE(' || CASE WHEN tree_sql_literal_type(arg) IS NULL\n"
         "                                   THEN alias || '._attr_map[' || tree_sql_lit(value) || ']'\n"
         "                                   ELSE 'TRY_CAST(' || alias || '._attr_map[' || tree_sql_lit(value)"
         " || '] AS ' || tree_sql_literal_type(arg) || ')' END\n"
         "               || ' ' || op || ' ' || arg || ', false)'\n",
         "        -- the mutation: no TRY_CAST on the map value; the literal is cast to VARCHAR instead\n"
         "        WHEN has_map\n"
         "          THEN 'COALESCE(' || alias || '._attr_map[' || tree_sql_lit(value) || ']'\n"
         "               || ' ' || op || ' ' || CASE WHEN tree_sql_literal_type(arg) IS NULL THEN arg\n"
         "                                           ELSE 'CAST(' || arg || ' AS VARCHAR)' END || ', false)'\n", 1)]),

    "MN17": ("sql/04_dml.sql", ["tree_compile_delete"], [
        ("'CREATE TEMP TABLE __duckent_gone AS SELECT DISTINCT _root::VARCHAR AS root_key FROM"
         " (SELECT DISTINCT _root, _root.* FROM ' || x.tbl || ') WHERE ' || root_predicate,",
         "-- the mutation, half one: the gone-roots computation reads the table directly\n"
         "    'CREATE TEMP TABLE __duckent_gone AS SELECT DISTINCT _root::VARCHAR AS root_key FROM '"
         " || x.tbl || ' WHERE ' || root_predicate,", 1),
        ("    tree_sql_delete_stmt(x.tbl, root_predicate),",
         "    -- the mutation, half two: and so does the DELETE -- row surgery\n"
         "    'DELETE FROM ' || x.tbl || ' WHERE ' || root_predicate,", 1)]),

    "MN18": ("sql/03_ddl.sql", ["tree_compile_create"], [
        ("COALESCE((shape).semantic.attr, CASE WHEN abstract THEN '' ELSE '*' END) AS attr_text,",
         "COALESCE((shape).semantic.attr, '*') AS attr_text,  -- the mutation", 1)]),

    "MN19": ("sql/07_match.sql", ["tree_sql_clause"], [
        ("WHEN 'where'  THEN 'EXISTS (SELECT 1 FROM (SELECT unnest(' || alias"
         " || ', recursive := false)) __w WHERE ' || value || ')'",
         "-- the mutation\n    WHEN 'where'  THEN 'EXISTS (SELECT 1 FROM read_parquet(''test/data/app.parquet'')"
         " __w WHERE __w.node_id = ' || alias || '._pre AND ' || value || ')'", 1)]),

    "MN21": ("sql/02_projection.sql", ["tree_sql_sem_cols"], [
        ("COALESCE((sem).type, '''node''')", "COALESCE((sem).type, 'NULL::VARCHAR')", 1)]),

    "MN22": ("sql/09_css.sql", ["tree_css_path"], [
        ("CREATE OR REPLACE MACRO tree_css_path(lvl, i0, a0, i1, a1, pos, a) AS\n  CASE lvl WHEN 0 THEN",
         "CREATE OR REPLACE MACRO tree_css_path(lvl, i0, a0, i1, a1, pos, a) AS\n"
         "  -- the mutation: the lowering consults ENGINE STATE before it places any row\n"
         "  CASE WHEN (SELECT count(*) FROM tree_state.partitions WHERE p13_ok = false) > 0\n"
         "         THEN tree_css_err('css: cannot lower a selector while a partition is not P13-clean')\n"
         "       ELSE CASE lvl WHEN 0 THEN", 1),
        ("i2: pos::INTEGER, a2: a::INTEGER} END;", "i2: pos::INTEGER, a2: a::INTEGER} END END;", 1)]),

    "MN24": ("sql/06_selector.sql", ["tree_selector_to_treeql"], [
        ("    FROM n g WHERE g.kind IN ('has', 'not')),",
         "    -- the mutation: NOT groups render as nothing and vanish from their step\n"
         "    FROM n g WHERE g.kind = 'has'),", 2)]),

    "MN25": ("sql/07_match.sql", ["tree_sql_clause"], [
        ("WHEN 'class'  THEN 'COALESCE(list_contains(' || alias || '._classes, ' || tree_sql_lit(value) || '), false)'",
         "-- the mutation\n"
         "    WHEN 'class'  THEN 'CASE WHEN COALESCE(len(' || alias || '._classes), 0) = 0'\n"
         "                       || ' THEN COALESCE(' || alias || '._pseudo[' || tree_sql_lit(value) || '], false)'\n"
         "                       || ' ELSE COALESCE(list_contains(' || alias || '._classes, '"
         " || tree_sql_lit(value) || '), false) END'", 1)]),
}


def extract(text, name):
    """The macro `name` exactly as the source file spells it, with the comment block that sits
    immediately above it. The forward scan stops at the first `;` outside quotes and parens, so
    a macro body full of SQL text literals (which is most of them) is not cut short by one."""
    lines = text.split("\n")
    head = pat = None
    pat = re.compile(r"^CREATE OR REPLACE MACRO " + re.escape(name) + r"\s*\(")
    for i, line in enumerate(lines):
        if pat.match(line):
            head = i
            break
    if head is None:
        sys.exit("regen: macro not found: " + name)
    top = head
    while top > 0 and lines[top - 1].lstrip().startswith("--"):
        top -= 1
    depth, quote, end = 0, None, None
    for i in range(head, len(lines)):
        line, j = lines[i], 0
        while j < len(line):
            c = line[j]
            if quote:
                if c == quote:
                    if j + 1 < len(line) and line[j + 1] == quote:
                        j += 1
                    else:
                        quote = None
            elif line.startswith("--", j):
                break
            elif c in ("'", '"'):
                quote = c
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            elif c == ";" and depth == 0:
                end = i
                break
            j += 1
        if end is not None:
            break
    if end is None:
        sys.exit("regen: no statement terminator for " + name)
    return "\n".join(lines[top:end + 1])


def header_of(path):
    """The hand-written part of a mutant file: everything above the marker. A file that has no
    marker yet keeps everything above its first CREATE, which is how the headers written before
    this script survive its first run."""
    if not os.path.exists(path):
        return "-- test/mutants/%s\n" % os.path.basename(path)
    text = open(path).read()
    for cut in ("-- vvv GENERATED", "CREATE OR REPLACE MACRO"):
        i = text.find(cut)
        if i >= 0:
            return text[:i]
    return text


CONTROL_NOTE = (
    "-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op\n"
    "-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies\n"
    "-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill\n"
    "-- evidence about the EDIT rather than about the copy having drifted from the source.\n")


def build(mid, spec, path, edits_on):
    """The whole file: the hand-written header (the mutant's own, preserved; a fixed one-liner
    plus the note for a control), the marker, then the macro(s) with or without the edit."""
    src, macros, edits = spec
    body = "\n\n".join(extract(open(os.path.join(ROOT, src)).read(), m) for m in macros)
    if edits_on:
        for old, new, count in edits:
            got = body.count(old)
            if got != count:
                sys.exit("regen: %s: planted edit matches %d times, expected %d:\n%s"
                         % (mid, got, count, old[:160]))
            body = body.replace(old, new)
        header = header_of(path).rstrip("\n") + "\n"
    else:
        header = "-- test/mutants/%s\n%s" % (os.path.basename(path), CONTROL_NOTE)
    return header + (MARKER % src) + "\n" + body.rstrip("\n") + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="write nothing; exit 1 if out of date")
    args = ap.parse_args()
    import yaml
    manifest = yaml.safe_load(open(os.path.join(HERE, "manifest.yaml")))
    stale = []
    for m in manifest:
        mid = m["id"]
        if mid not in SPEC:
            continue
        spec = SPEC[mid]
        mutant = os.path.join(HERE, m["file"])
        control = mutant[:-len(".sql")] + ".control.sql"
        targets = [(control, False)] + ([(mutant, True)] if spec[2] else [])
        for path, edits_on in targets:
            want = build(mid, spec, path, edits_on)
            have = open(path).read() if os.path.exists(path) else None
            if want == have:
                continue
            if args.check:
                stale.append(os.path.relpath(path, ROOT))
            else:
                open(path, "w").write(want)
                print("wrote", os.path.relpath(path, ROOT))
    if stale:
        print("out of date (run test/mutants/regen.py):", ", ".join(stale))
        sys.exit(1)
    if args.check:
        print("all generated mutant bodies and controls are current")


if __name__ == "__main__":
    main()
