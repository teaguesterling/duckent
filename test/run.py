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


def compile_macro_name(verb):
    """Map a CALL verb to its compile macro name by stripping the
    tree_ddl_ or tree_ prefix, e.g. tree_ddl_create -> tree_compile_create,
    tree_insert -> tree_compile_insert, tree_check -> tree_compile_check."""
    if verb.startswith("tree_ddl_"):
        return "tree_compile_" + verb[len("tree_ddl_"):]
    if verb.startswith("tree_"):
        return "tree_compile_" + verb[len("tree_"):]
    return "tree_compile_" + verb


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
            macro = compile_macro_name(verb)
            stmts = self.con.execute(f"SELECT {macro}({args})").fetchone()[0]
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
    if isinstance(v, (list, tuple)):
        return '[' + ', '.join(fmt(x) for x in v) + ']'
    if isinstance(v, dict):
        return '{' + ', '.join(f"'{k}': {fmt(val)}" for k, val in v.items()) + '}'
    if isinstance(v, float):
        return str(int(v)) if v == int(v) else repr(v)
    if v == "": return "(empty)"
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
                got = []
                for r in rows:
                    # Single-column values may embed newlines (e.g. the TREEQL printer's
                    # multi-line output) and are split into separate lines; multi-column
                    # rows stay tab-joined as one line so an embedded newline in a
                    # non-final column can't desync column alignment. Revisit if
                    # DuckDB's own runner needs this too.
                    if len(r) == 1:
                        got.extend(r[0].split("\n"))
                    else:
                        got.append("\t".join(r))
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
