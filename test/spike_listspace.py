#!/usr/bin/env python3
"""D-N17: does list-space navigation beat the compiled EXISTS form?

A throwaway experiment, not shipped code (M2 design section 4, "List-space spike").
The compiler emits `[NOT] EXISTS (SELECT 1 FROM P h1 WHERE <subtree(a, h1)> AND ...)`
for `:has` / `:not(:has())`. The alternative under test materializes each node's
subtree as a LIST of `_pre` values once, and answers `:has(string)` with
`list_has_any(subtree, <the root's string _pre list>)`.

Two inputs:

  scripts        test/data/scripts.parquet, 14,265 rows over 15 roots
  scripts10      ten copies of it with distinct roots (`file_path || '#' || i`),
                 142,650 rows over 150 roots

Both trees declare SIZE (`descendant_count`), because the derived `_size` is
quadratic and would otherwise dominate every timing here. Its cost is measured
once, separately, at the foot of this script -- that measurement is the M3
motivation, not part of the D-N17 comparison. A third input, `scripts_deep`,
exists only for that measurement: the quadratic is per ROOT, and `scripts10`
grows the number of roots rather than their size, so it never reaches it.

Two selectors, the flagship pair:

  .fn:has(string)          -> EXISTS
  .fn:not(:has(string))    -> NOT EXISTS

The list-space form is written by hand below. Note that it is grouped BY ROOT:
the brief's sketch takes `(SELECT list(_pre) FROM P WHERE _type = 'string')`
globally, which is sitting_duck #130 in list form -- `_pre` is only unique within
a root, so a global list matches a string in another file. Any honest list-space
implementation pays for that grouping, so the timing includes it.

Run: python3 test/spike_listspace.py [--reps N] [--derived-timeout SECONDS]
"""
import argparse, multiprocessing, os, statistics, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import css_parser
import run as runner

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "test", "data", "scripts.parquet")

# Ten copies with distinct roots; `i` reaches only the ROOT expression. Both texts are handed
# to the compilers as BOUND parameters, never interpolated, so their quotes need no doubling.
SRC = {
    "scripts": "read_parquet('%s')" % SCRIPTS,
    "scripts10": ("(SELECT * REPLACE (file_path || '#' || i AS file_path) "
                  "FROM read_parquet('%s') CROSS JOIN range(10) t(i))" % SCRIPTS),
}

# The derived `_size` is quadratic WITHIN a root, and scripts10 grows the number of roots, not
# their size -- so it says nothing about the quadratic. These probe it: ten copies under the
# SAME 15 roots (node_id offset so _pre stays unique), which is what a ten-times-bigger FILE
# would cost. The relation is not a well-formed forest -- ten level-0 rows per root, so P13 would
# refuse it -- and it is never created as a tree; only the projection text is timed.
DEEP = {
    "scripts_deep": ("(SELECT * REPLACE (node_id + i * 100000 AS node_id) "
                     "FROM read_parquet('%s') CROSS JOIN range(10) t(i))" % SCRIPTS),
}
DEEP_NOTE = ("scripts_deep is scripts10's rows under the ORIGINAL 15 roots: same 142,650 rows, "
             "~9,510 per root instead of ~951. It is a cost probe, not a tree -- its levels do "
             "not form one, so the declared and derived sums are not expected to agree.")

SHAPE = """tree_shape(
  root := 'file_path', "order" := 'node_id', level := 'depth', size := 'descendant_count',
  semantic := tree_semantic(type := 'type', id := 'name', classes := 'css_classes',
    element := 'is_element', pseudo := [{name: 'def', body: '(flags & 6) = 6'}]))"""

SELECTORS = [".fn:has(string)", ".fn:not(:has(string))"]


def timeit(con, sql, reps):
    """Run `sql` reps+1 times; discard the first (cache warm-up), return (best, median, rows)."""
    con.execute(sql).fetchall()
    times, rows = [], None
    for _ in range(reps):
        t0 = time.perf_counter()
        out = con.execute(sql).fetchall()
        times.append(time.perf_counter() - t0)
        rows = out
    return min(times), statistics.median(times), rows


def proj(con, tree):
    """The projection relation text for a tree, as tree_compile_match would spell it."""
    return con.execute(
        "SELECT 'tree_catalog.' || tree_sql_object_name('proj', 'main', ?) || '()'", [tree]).fetchone()[0]


def exists_sql(con, tree, selector):
    """What the compiler emits today, wrapped so the timing measures matching, not printing."""
    ir = css_parser.to_sql(css_parser.parse(selector))
    body = con.execute("SELECT tree_compile_match('main', ?, %s)" % ir, [tree]).fetchone()[0]
    return ("SELECT count(*), md5(string_agg(k, ',' ORDER BY k)) FROM "
            "(SELECT file_path || ':' || node_id AS k FROM (%s))" % body)


SUB_SQL = """SELECT a._root, a._pre, list(b._pre) AS subtree
  FROM {p} a JOIN {p} b ON b._root = a._root AND b._pre BETWEEN a._pre + 1 AND a._pre + a._size
  GROUP BY 1, 2"""
ST_SQL = "SELECT _root, list(_pre) AS pres FROM {p} WHERE _type = 'string' GROUP BY 1"
LIST_BODY = """SELECT count(*), md5(string_agg(k, ',' ORDER BY k)) FROM (
  SELECT a.file_path || ':' || a.node_id AS k
  FROM {p} a
  LEFT JOIN {sub} sub ON sub._root = a._root AND sub._pre = a._pre
  LEFT JOIN {st} st ON st._root = a._root
  WHERE COALESCE(list_contains(a._classes, 'fn'), false) AND {neg}{test})"""
LIST_TEST = "COALESCE(list_has_any(COALESCE(sub.subtree, []), COALESCE(st.pres, [])), false)"


def listspace_sql(p, negated, sub="sub", st="st", inline=True):
    """The hand-written list-space form of `.fn:has(string)` / `.fn:not(:has(string))`.

    `sub` is the brief's subtree-list CTE; `st` is the string-node list, per root
    (see the module docstring on why the global form is unsound). A node with no
    descendants has no `sub` row and a root with no strings has no `st` row, so
    both joins are LEFT and the list defaults to [] -- which is exactly the
    NOT EXISTS case that must still answer true under negation.

    With `inline=False` the two lists are read from relations built beforehand
    (--materialized), so the timing excludes the cost of building them."""
    head = ("WITH sub AS (%s),\nst AS (%s)\n" % (SUB_SQL.format(p=p), ST_SQL.format(p=p))) if inline else ""
    return "\n" + head + LIST_BODY.format(p=p, sub=sub, st=st, test=LIST_TEST,
                                          neg="NOT " if negated else "")


def materialize(con, tree, p):
    """Build the two lists as TEMP TABLES once. Returns (sub relation, st relation, seconds).

    This is the most generous reading of the list-space proposal: pay for the subtree lists and
    the string-node list ONCE, up front, and let every later selector read them for free. It is
    generous to the point of being unfair to EXISTS -- these tables are stale the moment a row
    is inserted, so a real implementation would owe their maintenance -- which is the point: if
    list-space loses even here, it loses."""
    sub, st = "mat_sub_" + tree, "mat_st_" + tree
    t0 = time.perf_counter()
    con.execute("CREATE OR REPLACE TEMP TABLE %s AS %s" % (sub, SUB_SQL.format(p=p)))
    con.execute("CREATE OR REPLACE TEMP TABLE %s AS %s" % (st, ST_SQL.format(p=p)))
    return sub, st, time.perf_counter() - t0


def _derived_child(source, attr, q):
    """Time the derived-size projection in a child process, so the parent can give up on it."""
    try:
        s = runner.Session()
        s.con.execute("SET enable_progress_bar = false")
        shape_nosize = SHAPE.replace(" size := 'descendant_count',", "")
        sql = s.con.execute("SELECT tree_compile_projection(%s, ?, ?)" % shape_nosize,
                            [source, attr]).fetchone()[0]
        t0 = time.perf_counter()
        n = s.con.execute("SELECT count(*), sum(_size) FROM (%s)" % sql).fetchone()
        q.put(("ok", time.perf_counter() - t0, n))
    except Exception as e:  # pragma: no cover - diagnostic path
        q.put(("err", str(e), None))


def derived_cost(con, source, timeout):
    """(declared seconds, derived seconds or None, rows) for one source."""
    sql = con.execute("SELECT tree_compile_projection(%s, ?, ?)" % SHAPE, [source, "*"]).fetchone()[0]
    t0 = time.perf_counter()
    declared = con.execute("SELECT count(*), sum(_size) FROM (%s)" % sql).fetchone()
    dt = time.perf_counter() - t0

    q = multiprocessing.Queue()
    p = multiprocessing.Process(target=_derived_child, args=(source, "*", q))
    p.start()
    p.join(timeout)
    if p.is_alive():
        p.terminate(); p.join()
        return dt, None, declared, None
    status, value, rows = q.get()
    if status != "ok":
        return dt, None, declared, "failed: " + value
    return dt, value, declared, ("derived sums match" if rows == declared else
                                 "DIVERGED: declared %s, derived %s" % (declared, rows))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--derived-timeout", type=float, default=300.0)
    ap.add_argument("--materialized", action="store_true",
                    help="also time the list-space form with both lists pre-built as temp tables,"
                         " so its build cost is paid once instead of per query")
    args = ap.parse_args()

    s = runner.Session()
    con = s.con
    con.execute("SET enable_progress_bar = false")
    for tree, src in SRC.items():
        for stmt in con.execute("SELECT tree_compile_create('main', ?, tree_spec(%s, source := ?))"
                                % SHAPE, [tree, src]).fetchone()[0]:
            con.execute(stmt)
        n = con.execute("SELECT count(*), count(DISTINCT _root) FROM %s" % proj(con, tree)).fetchone()
        print("%-10s %7d rows, %3d roots" % (tree, n[0], n[1]))
    print()

    extra = "%10s %8s  " % ("mat s", "ratio") if args.materialized else ""
    print("%-10s %-24s %10s %10s %8s  %s%s"
          % ("tree", "selector", "EXISTS s", "list s", "ratio", extra, "same answer"))
    verdict, mat_verdict, build = [], [], {}
    for tree in SRC:
        p = proj(con, tree)
        mat = materialize(con, tree, p) if args.materialized else None
        if mat:
            build[tree] = mat[2]
        for selector in SELECTORS:
            negated = ":not(" in selector
            e_best, _, e_rows = timeit(con, exists_sql(con, tree, selector), args.reps)
            l_best, _, l_rows = timeit(con, listspace_sql(p, negated), args.reps)
            same = e_rows == l_rows
            cells = ""
            if mat:
                m_best, _, m_rows = timeit(con, listspace_sql(p, negated, mat[0], mat[1], inline=False),
                                           args.reps)
                same = same and m_rows == e_rows
                cells = "%10.3f %8.2fx  " % (m_best, e_best / m_best if m_best else float("nan"))
                mat_verdict.append((tree, selector, e_best, m_best))
            print("%-10s %-24s %10.3f %10.3f %8.2fx  %s%s  (%d rows)"
                  % (tree, selector, e_best, l_best, e_best / l_best if l_best else float("nan"),
                     cells, "yes" if same else "NO -- " + repr((e_rows, l_rows)), e_rows[0][0]))
            verdict.append((tree, selector, e_best, l_best, same))
    print()
    for tree, seconds in build.items():
        print("one-time build of the two lists on %s: %.3f s" % (tree, seconds))
    if mat_verdict:
        big = [v for v in mat_verdict if v[0] == "scripts10"]
        print("pre-materialized, on the larger input: list-space still %.1fx to %.1fx SLOWER"
              % (min(m / e for _, _, e, m in big), max(m / e for _, _, e, m in big)))
        print()

    big = [v for v in verdict if v[0] == "scripts10"]
    speedup = min(e / l for _, _, e, l, _ in big if l)
    agree = all(v[4] for v in verdict)
    print("row-count and key-hash equality on every cell: %s" % ("yes" if agree else "NO"))
    print("list-space speedup on the larger input, worst case: %.2fx" % speedup)
    print("D-N17: %s" % ("adopt list-space" if (agree and speedup >= 3.0)
                         else "keep EXISTS (list-space does not win by 3x on the larger input)"))
    print()

    print("Derived versus declared SIZE (the M3 motivation, not part of D-N17):")
    probes = [(t, s, True) for t, s in SRC.items()] + [(t, s, False) for t, s in DEEP.items()]
    for tree, src, compare in probes:
        dt, derived, rows, note = derived_cost(con, src, args.derived_timeout)
        if not compare:
            note = "cost probe only; sums are not compared"
        if derived is None:
            print("  %-12s declared %7.3f s, derived SKIPPED (%s)"
                  % (tree, dt, note or "over the %.0f s timeout" % args.derived_timeout))
        else:
            print("  %-12s declared %7.3f s, derived %8.3f s  (%.1fx)   %s"
                  % (tree, dt, derived, derived / dt, note))
    print("\n  (%s)" % DEEP_NOTE)


if __name__ == "__main__":
    main()
