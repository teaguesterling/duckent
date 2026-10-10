#!/usr/bin/env python3
"""Every embedded .sql file must be byte-identical to the plan repo's.

Embedding the macros puts the same semantics in two repositories. The only
permitted difference is WHICH files the extension embeds -- 09_css.sql is a
front-end and is omitted. Any difference in a file that IS embedded is a fork,
and a fork is exactly what this gate exists to prevent.
"""
import argparse, hashlib, os, sys

OMITTED = {"09_css.sql"}

def digest(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan-repo", required=True, help="path to the duckent plan repo")
    args = ap.parse_args()

    here = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src", "sql_macros")
    there = os.path.join(args.plan_repo, "sql")
    bad = []

    for name in sorted(os.listdir(here)):
        if not name.endswith(".sql"):
            continue
        mine, theirs = os.path.join(here, name), os.path.join(there, name)
        if not os.path.exists(theirs):
            bad.append(f"{name}: embedded here but absent from the plan repo")
        elif digest(mine) != digest(theirs):
            bad.append(f"{name}: differs from the plan repo")

    for name in sorted(os.listdir(there)):
        if name.endswith(".sql") and name not in OMITTED and not os.path.exists(os.path.join(here, name)):
            bad.append(f"{name}: in the plan repo but not embedded (add it, or add it to OMITTED with a reason)")

    if bad:
        sys.stderr.write("macro identity check FAILED:\n")
        for b in bad:
            sys.stderr.write("  - " + b + "\n")
        sys.exit(1)
    print("macro identity: every embedded file matches the plan repo")

if __name__ == "__main__":
    main()
