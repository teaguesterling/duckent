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
import argparse, multiprocessing, os, queue, statistics, sys, time

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

# --- the M3 derivation cost probe (--sizes) -----------------------------------------------
# The shapes spec 2.3 names as the derived SIZE's best and worst cases, each a relation of
# file_path / node_id / depth / descendant_count. The descendant_count is EXACT and is computed
# in SQL from the generated rows -- by aggregates over them, never typed by hand and never by
# the boundary rule being measured -- so "sizes agree" is an independent check rather than a
# restatement of the derivation.
SIZE_SHAPES = {
    # Best case for a declared SIZE and worst for the derivation: one root, 5000 levels, so the
    # candidate expansion is SUM(5000 - level) ~ n^2/2 rows.
    "chain depth 5000":
        "SELECT 'r' AS file_path, i AS node_id, i AS depth, 4999 - i AS descendant_count"
        " FROM range(5000) t(i)",
    # The opposite: one level-0 row and 199,999 leaves, so every row expands to at most 2 levels.
    "flat 200k":
        "SELECT 'r' AS file_path, i AS node_id, (i > 0)::INT AS depth,"
        " CASE WHEN i = 0 THEN 199999 ELSE 0 END AS descendant_count FROM range(200000) t(i)",
    # The shape the comment in sql/02_projection.sql warns about: a deep spine BESIDE many
    # shallow rows, so the 100k shallow rows each expand over the spine's full depth.
    "2k spine + 100k shallow": """
WITH gen AS (SELECT i AS node_id, i AS depth FROM range(2001) t(i)
             UNION ALL SELECT 2001 + i, 1 FROM range(100000) t(i)),
     agg AS (SELECT count(*) AS n, max(depth) AS mx,
                    max(node_id) FILTER (WHERE node_id = depth) AS spine_last FROM gen)
SELECT 'r' AS file_path, g.node_id, g.depth,
       CASE WHEN g.node_id = 0 THEN a.n - 1
            WHEN g.node_id <= a.spine_last THEN a.mx - g.depth
            ELSE 0 END AS descendant_count
FROM gen g CROSS JOIN agg a""",
    # A real parse, ten times over, as ONE root: scripts' 15 files concatenated under a synthetic
    # level-0 row, every real row pushed down one level. Each file's rows stay contiguous and the
    # next block opens at level 1, so every original descendant_count still names the same subtree
    # and carries over unchanged; the synthetic root owns everything.
    "scripts x10 as one root": """
WITH base AS (SELECT * FROM read_parquet('%s') CROSS JOIN range(10) t(i)),
     ord AS (SELECT row_number() OVER (ORDER BY i, file_path, node_id) AS rn,
                    depth, descendant_count FROM base)
SELECT 'one' AS file_path, 0 AS node_id, 0 AS depth, (SELECT count(*) FROM ord) AS descendant_count
UNION ALL
SELECT 'one', rn, depth + 1, descendant_count FROM ord""" % SCRIPTS,
}

SIZE_DECL = ("tree_shape(root := 'file_path', \"order\" := 'node_id', level := 'depth',"
             " size := 'descendant_count')")
SIZE_DERIV = "tree_shape(root := 'file_path', \"order\" := 'node_id', level := 'depth')"


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


def _derived_child(source, attr, mem, spill, q):
    """Time the derived-size projection in a child process, so the parent can give up on it."""
    try:
        s = runner.Session()
        child_guard(s.con, mem, spill)
        shape_nosize = SHAPE.replace(" size := 'descendant_count',", "")
        sql = s.con.execute("SELECT tree_compile_projection(%s, ?, ?)" % shape_nosize,
                            [source, attr]).fetchone()[0]
        t0 = time.perf_counter()
        n = s.con.execute("SELECT count(*), sum(_size) FROM (%s)" % sql).fetchone()
        q.put(("ok", time.perf_counter() - t0, n))
    except Exception as e:  # pragma: no cover - diagnostic path
        q.put(("err", str(e), None))


# Both probes below run a form that may not finish in a child process, so the parent can give up
# on it. Collecting that child's answer is where they used to go wrong, and identically, so it is
# written once here.
#
# THREE outcomes, not two. A child that is still running at `timeout` is terminated and reported;
# a child that FINISHED and posted is read; and a child that exited WITHOUT posting -- which is
# what the kernel's OOM killer leaves behind -- is reported as dead with its exit code. That third
# case is why this helper exists: `q.get()` on a queue nothing was ever put on blocks forever, and
# the --siblings probe sat on exactly that get for two hours after its 3000-row scanning cell was
# OOM-killed at 19.5 GB RSS. `pr.is_alive()` was already false, so the timeout branch did not fire.
#
# The children bound their own memory (see child_guard) so this path stays rare, but a bound the
# kernel enforces instead of DuckDB is always possible and must not hang the probe.
def run_child(target, args, timeout):
    """Run `target(*args, q)` in a child process; return its ('ok'|'err', value, extra) tuple.

    ('over', timeout, None) when it was still running at `timeout`, and ('died', exitcode, None)
    when it exited without posting."""
    q = multiprocessing.Queue()
    pr = multiprocessing.Process(target=target, args=tuple(args) + (q,))
    pr.start()
    pr.join(timeout)
    if pr.is_alive():
        pr.terminate(); pr.join()
        return ("over", timeout, None)
    try:
        return q.get(timeout=10)
    # Empty is the clean case: the child exited and wrote nothing. A child killed or broken
    # mid-write -- or one that died before its interpreter finished starting -- tears the pipe
    # down instead, and that surfaces as EOFError or ConnectionResetError from the same get.
    # All three mean the same thing here, and none of them may be allowed to propagate: the
    # whole point of this helper is that a dead child is a reported cell, not a failed probe.
    except (queue.Empty, EOFError, ConnectionResetError, OSError):
        return ("died", pr.exitcode, None)


# A child inherits none of the parent's limits, and an unbounded DuckDB in a child is how the
# machine gets an OOM kill instead of an error. Bounding memory turns "the kernel killed it" into
# "DuckDB raised Out of Memory", which the probe can catch, report, and carry on from -- and
# bounding the spill keeps a runaway form from filling the disk with .tmp as one already did.
# The two budgets are separate on purpose. `mem` is RAM, and a form that exceeds it SPILLS rather
# than failing -- that is DuckDB working as intended, and the scanning form is meant to be allowed
# to do it, since spilling is how it finished at all when 33_navigation measured it. `spill` caps
# the .tmp directory so a runaway form cannot fill the disk, which one already did to 16 GB.
# Setting the two equal (an earlier version of this guard did) turns every spill into a failure and
# reports "out of memory" for a form that would have finished.
def child_guard(con, mem, spill):
    con.execute("SET enable_progress_bar = false")
    if mem:
        con.execute("SET memory_limit = '%s'" % mem)
    if spill:
        con.execute("SET max_temp_directory_size = '%s'" % spill)


def derived_cost(con, source, timeout, mem=None, spill=None):
    """(declared seconds, derived seconds or None, rows) for one source."""
    sql = con.execute("SELECT tree_compile_projection(%s, ?, ?)" % SHAPE, [source, "*"]).fetchone()[0]
    t0 = time.perf_counter()
    declared = con.execute("SELECT count(*), sum(_size) FROM (%s)" % sql).fetchone()
    dt = time.perf_counter() - t0

    status, value, rows = run_child(_derived_child, (source, "*", mem, spill), timeout)
    if status == "over":
        return dt, None, declared, None
    if status == "died":
        return dt, None, declared, "child exited without a result (exit code %s)" % value
    if status != "ok":
        return dt, None, declared, "failed: " + str(value)
    return dt, value, declared, ("derived sums match" if rows == declared else
                                 "DIVERGED: declared %s, derived %s" % (declared, rows))


def run_sizes(con, reps):
    """--sizes: the derived SIZE against a declared one on each shape spec 2.3 names.

    Both sides are compiled by the real projection compiler from the same relation; only the
    shape differs (one declares `size := 'descendant_count'`, the other declares nothing and
    derives). `sizes agree` compares the derived `_size` row for row against the relation's own
    descendant_count, which the shape computed independently of the boundary rule."""
    print("M3 derivation cost -- derived SIZE against a declared one (spec 2.3 shapes).\n")
    print("%-26s %9s %11s %10s %8s  %s"
          % ("shape", "rows", "declared s", "derived s", "ratio", "sizes agree"))
    for name, gen in SIZE_SHAPES.items():
        src = "(" + gen + ")"
        decl = con.execute("SELECT tree_compile_projection(%s, ?, ?)" % SIZE_DECL,
                           [src, "*"]).fetchone()[0]
        deriv = con.execute("SELECT tree_compile_projection(%s, ?, ?)" % SIZE_DERIV,
                            [src, "*"]).fetchone()[0]
        d_best, _, _ = timeit(con, "SELECT count(*), sum(_size) FROM (%s)" % decl, reps)
        v_best, _, rows = timeit(con, "SELECT count(*), sum(_size) FROM (%s)" % deriv, reps)
        bad = con.execute("SELECT count(*) FROM (%s) WHERE _size IS DISTINCT FROM descendant_count"
                          % deriv).fetchone()[0]
        print("%-26s %9d %11.3f %10.3f %8.2fx  %s"
              % (name, rows[0][0], d_best, v_best, v_best / d_best if d_best else float("nan"),
                 "yes" if bad == 0 else "NO -- %d rows differ" % bad))


# --- the M3 sibling-relation probe (--siblings) -------------------------------------------
# Before M3 Task 8 the element-aware sibling and positional relations asked "is there a nearer
# element sibling?" as a NOT EXISTS correlated to each candidate PAIR, which is quadratic in the
# width of ONE parent. Task 8 replaced that with a single window pass (the __sib CTE) carrying
# each row's nearest element neighbour on either side. This probe is the two forms on the shape
# that makes the difference visible: one flat root, every third row a non-element.
#
# The scanning form is spelled out here rather than reached through the macros -- the macros no
# longer emit it -- and runs in a CHILD PROCESS under a timeout, because on the larger inputs it
# does not finish in any useful time. A cell that does not finish is reported as such rather than
# quietly dropped.
#
# `independent` is NEITHER form: a plain lead()/row_number() over the element rows, which answers
# what the DEFINITIONS say and is linear at every size. It is what says the window form is right
# at the sizes where the scanning form cannot be asked at all.
SIB_SHAPE = ("tree_shape(root := 'file_path', \"order\" := 'node_id', level := 'depth',"
             " size := 'descendant_count',"
             " semantic := tree_semantic(type := 'type', element := 'type <> ''punct'''))")
SIB_RELS = ("next", "first-child", "last-child")
SIB_SEL = {
    "next": "tree_steps([{type: 'item'}, {comb: 'next', type: 'item'}])",
    "first-child": "tree_steps([{type: 'item', pseudo: 'first-child'}])",
    "last-child": "tree_steps([{type: 'item', pseudo: 'last-child'}])",
}
# the sibling relation itself, as tree_sql_siblings spells it (IS NOT DISTINCT FROM, so the
# level-0 rows of a partition are siblings of each other through their shared NULL _parent)
SIB_SIBS = ("{c}._root = a._root AND {c}._parent IS NOT DISTINCT FROM a._parent"
            " AND {c}._pre <> a._pre")


def sib_source(n):
    """One root and n-1 children, every third child a non-element ('punct')."""
    return ("(SELECT 'w' AS file_path, i AS node_id, (i > 0)::INT AS depth,"
            " CASE WHEN i = 0 THEN %d ELSE 0 END AS descendant_count,"
            " CASE WHEN i %% 3 = 1 THEN 'punct' ELSE 'item' END AS type"
            " FROM range(%d) t(i))" % (n - 1, n))


def sib_setup(con, n):
    """Create the flat element tree of n rows; returns (tree name, projection relation text).

    The rows are MATERIALIZED into a table first, and the tree is built on that table rather than
    on the generating subquery. This is fidelity, not convenience: the scanning form names the
    projection relation THREE times (two step aliases and the correlated `__c`), so with a
    generating subquery as the source every correlated probe re-runs `range(n)` through the
    projection, which is a cost the compiled form never had. The 33_navigation record builds its
    `wide` tree on a table, and so does every real source. Against the subquery form the scanning
    cell did not merely run slower -- it was OOM-killed at 19.5 GB on 3000 rows, which would have
    been reported as a fact about the scanning form when it was really a fact about the harness.
    (The scanning form does not finish at 3000 rows on a table source either, but it finishes at
    2400, and that is the difference between a measurable curve and no curve at all.)"""
    tree = "sib%d" % n
    con.execute("CREATE OR REPLACE TABLE %s_src AS SELECT * FROM %s" % (tree, sib_source(n)))
    for stmt in con.execute("SELECT tree_compile_create('main', ?, tree_spec(%s, source := ?))"
                            % SIB_SHAPE, [tree, tree + "_src"]).fetchone()[0]:
        con.execute(stmt)
    return tree, proj(con, tree)


def _nearer(p, cond):
    """The scanning form's inner question: is there a nearer ELEMENT sibling of a?"""
    return ("NOT EXISTS (SELECT 1 FROM %s __c WHERE %s AND %s AND __c._element)"
            % (p, SIB_SIBS.format(c="__c"), cond))


def sib_old_sql(p, rel):
    """The pre-Task-8 scanning form, written out as the fragments used to emit it."""
    if rel == "next":
        return ("SELECT count(*) FROM %s a, %s b WHERE %s AND b._pre > a._pre AND b._element"
                " AND a._type = 'item' AND b._type = 'item' AND %s"
                % (p, p, SIB_SIBS.format(c="b"),
                   _nearer(p, "__c._pre > a._pre AND __c._pre < b._pre")))
    cond = "__c._pre < a._pre" if rel == "first-child" else "__c._pre > a._pre"
    return ("SELECT count(*) FROM %s a WHERE a._type = 'item' AND a._element AND %s"
            % (p, _nearer(p, cond)))


def sib_new_sql(con, tree, rel):
    """What the compiler emits today: the __proj / __sib CTEs and a lookup in the window."""
    body = con.execute("SELECT tree_compile_match('main', ?, %s)" % SIB_SEL[rel],
                       [tree]).fetchone()[0]
    return "SELECT count(*) FROM (%s)" % body


def sib_ref_sql(p, rel):
    """The definitions in plain window SQL -- independent of both implementations."""
    e = "(SELECT _root, _pre, _parent FROM %s WHERE _element AND _type = 'item')" % p
    if rel == "next":
        return ("SELECT count(*) FROM (SELECT lead(_pre) OVER (PARTITION BY _root, _parent"
                " ORDER BY _pre) AS nx FROM %s) WHERE nx IS NOT NULL" % e)
    order = "_pre" if rel == "first-child" else "_pre DESC"
    return ("SELECT count(*) FROM (SELECT row_number() OVER (PARTITION BY _root, _parent"
            " ORDER BY %s) AS rn FROM %s) WHERE rn = 1" % (order, e))


def _sib_child(n, rel, mem, spill, q):
    """Time the scanning form in a child process, so the parent can give up on it."""
    try:
        s = runner.Session()
        child_guard(s.con, mem, spill)
        _, p = sib_setup(s.con, n)
        sql = sib_old_sql(p, rel)
        t0 = time.perf_counter()
        rows = s.con.execute(sql).fetchall()
        q.put(("ok", time.perf_counter() - t0, rows[0][0]))
    except Exception as e:  # pragma: no cover - diagnostic path
        q.put(("err", str(e), None))


def sib_old_timed(n, rel, timeout, mem, spill):
    """(seconds, count, note) for the scanning form.

    Only the first outcome carries a time. The other three say WHY there is none, each
    distinguishable from the others, because "the scanning form ran out of memory at 3000 rows"
    and "the scanning form was still going at 180 s" are different findings and the table should
    not print one when the other happened."""
    status, value, count = run_child(_sib_child, (n, rel, mem, spill), timeout)
    if status == "ok":
        return value, count, None
    if status == "over":
        return None, None, "over %gs" % value
    if status == "died":
        return None, None, "killed (%s)" % value
    return None, None, "out of memory" if "Out of Memory" in str(value) else "failed"


def run_siblings(con, reps, timeout, sizes, mem, spill):
    """--siblings: the scanning sibling/positional forms against the __sib window."""
    print("M3 sibling relations -- the scanning forms against the __sib window"
          " (DuckDB 1.5.5, best of %d after a warm-up).\n" % reps)
    print("One flat root, every third row a non-element. `next` matches item+item; the positional")
    print("relations match item rows. The last column checks the window form against `independent`")
    print("-- a plain lead()/row_number() over the element rows, computed from the definitions and")
    print("from neither implementation -- and against the scanning form wherever it finished.\n")
    print("%8s %-12s %12s %11s %9s  %s"
          % ("rows", "relation", "scanning s", "window s", "speedup", "counts"))
    for n in sizes:
        tree, p = sib_setup(con, n)
        for rel in SIB_RELS:
            w_best, _, w_rows = timeit(con, sib_new_sql(con, tree, rel), reps)
            w_count = w_rows[0][0]
            ref = con.execute(sib_ref_sql(p, rel)).fetchone()[0]
            o_secs, o_count, why = sib_old_timed(n, rel, timeout, mem, spill)
            agree = (w_count == ref) and (o_count is None or o_count == w_count)
            if o_secs is None:
                scan, speed = why, "--"
            else:
                scan = "%.3f" % o_secs
                speed = ("%.0fx" % (o_secs / w_best)) if w_best else "--"
            if not agree:
                note = ("DISAGREE -- window %s, scanning %s, independent %s"
                        % (w_count, o_count, ref))
            elif o_secs is None:
                note = "window = independent (%d); scanning gave no answer" % w_count
            else:
                note = "all three agree (%d)" % w_count
            print("%8d %-12s %12s %11.4f %9s  %s" % (n, rel, scan, w_best, speed, note))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--derived-timeout", type=float, default=300.0)
    ap.add_argument("--materialized", action="store_true",
                    help="also time the list-space form with both lists pre-built as temp tables,"
                         " so its build cost is paid once instead of per query")
    ap.add_argument("--sizes", action="store_true",
                    help="instead of the D-N17 list-space comparison, measure the DERIVED SIZE"
                         " against a declared one on the spec 2.3 shapes (the M3 cost table)")
    ap.add_argument("--siblings", action="store_true",
                    help="instead of the D-N17 list-space comparison, measure the sibling and"
                         " positional relations: the pre-Task-8 scanning forms against the"
                         " __sib window, on one flat root")
    ap.add_argument("--sib-timeout", type=float, default=180.0,
                    help="seconds to allow each scanning-form cell before giving up on it")
    ap.add_argument("--sib-sizes", default="3000,10000,40000",
                    help="comma-separated row counts for --siblings")
    ap.add_argument("--sib-mem", default="4GB",
                    help="memory and spill budget for the scanning form's child process; it is"
                         " bounded so a runaway form spills instead of being killed by the kernel")
    ap.add_argument("--sib-spill", default="24GB",
                    help="cap on the child's .tmp spill, so a runaway form cannot fill the disk")
    args = ap.parse_args()

    s = runner.Session()
    con = s.con
    con.execute("SET enable_progress_bar = false")
    if args.sizes:
        run_sizes(con, args.reps)
        return
    if args.siblings:
        run_siblings(con, args.reps, args.sib_timeout,
                     [int(x) for x in args.sib_sizes.split(",")], args.sib_mem, args.sib_spill)
        return
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
