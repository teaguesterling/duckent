#!/usr/bin/env python3
"""Apply each mutant and require at least one listed test to fail -- and prove the failure is
caused by the PLANTED EDIT rather than by the mutant file having drifted from the macro it
copies.

A copy-and-edit mutant is "that macro, with one edit". A kill only says something about the
edit while that claim holds, and it stops holding silently: Task 13's `error(` -> `tree_err(`
sweep left ten mutants copying macros that no longer existed, and every one of them went on
being KILLED -- a two-commits-old macro fails the same tests a wrong macro does. The harness
could not tell the difference, so it reported none.

Two checks hold the claim up, and they answer different halves of it.

1. STRUCTURAL, and the one that would have caught the sweep: `test/mutants/regen.py --check`
   rebuilds each generated mutant from the macro it copies plus its planted edit and compares.
   A copy that has drifted from its source is out of date by construction, whatever the tests
   say. It runs first here, on every invocation, because it costs no database at all.

2. BEHAVIOURAL: the CONTROL. regen.py writes, next to each generated mutant,
   `<file>.control.sql` -- the same copy with the edit left out, so applying it is a no-op
   CREATE OR REPLACE of the current macro. --verify (on by default) applies it and requires
   every suite the mutant is expected to kill to PASS, which is what says the kill comes from
   the difference between mutant and control rather than from the copy at large.

  python3 test/run_mutants.py               staleness + kills + controls (the default)
  python3 test/run_mutants.py --no-verify    staleness + kills only
  python3 test/mutants/regen.py              rewrite the generated copies from the macros
"""
import argparse, os, subprocess, sys, yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_cache = {}


def suite_passes(test, overlay, env):
    """Run one test file with `overlay` applied as --mutant. True when it PASSES. Memoized:
    several mutants copy the same macro, so their controls are the same file."""
    key = (test, overlay, tuple(sorted((k, v) for k, v in env.items() if k.startswith("DUCKENT_"))))
    if key not in _cache:
        r = subprocess.run([sys.executable, os.path.join(ROOT, "test/run.py"),
                            os.path.join(ROOT, test), "--mutant", overlay],
                           capture_output=True, text=True, env=env)
        _cache[key] = r.returncode == 0
    return _cache[key]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", dest="verify", action="store_true", default=True,
                    help="also require each mutant's control to PASS (the default)")
    ap.add_argument("--no-verify", dest="verify", action="store_false",
                    help="check kills only; do not run the controls")
    ap.add_argument("--only", action="append", metavar="ID",
                    help="run just these mutant ids (repeatable)")
    args = ap.parse_args()

    # Check 1, before anything touches a database: is every generated copy still the macro it
    # copies plus its planted edit? This is the check that would have caught the tree_err sweep.
    stale = subprocess.run([sys.executable, os.path.join(ROOT, "test/mutants/regen.py"), "--check"],
                           capture_output=True, text=True)
    sys.stdout.write(stale.stdout)
    sys.stderr.write(stale.stderr)
    if stale.returncode != 0:
        sys.exit("mutants are stale: their copies no longer match the macros they copy, so a kill "
                 "says nothing about the planted edit. Run python3 test/mutants/regen.py")

    manifest = yaml.safe_load(open(os.path.join(ROOT, "test/mutants/manifest.yaml")))
    alive, unverified, uncontrolled = [], [], []
    for m in manifest:
        if args.only and m["id"] not in args.only:
            continue
        path = os.path.join(ROOT, "test/mutants", m["file"])
        # A mutant whose mutation is PYTHON-side (the runner's own css parser, say) cannot be
        # expressed as a CREATE OR REPLACE MACRO override, so the manifest may carry an `env` map
        # that is added to the environment of every subprocess run for that mutant; its SQL file is
        # then comment-only. Keys are read by the runner, not by the SQL: see MN08.
        env = dict(os.environ, **{k: str(v) for k, v in (m.get("env") or {}).items()})
        killed_by = [t for t in m["expect_fail"] if not suite_passes(t, path, env)]
        status = "KILLED" if killed_by else "SURVIVED"
        note = f"  (by {', '.join(killed_by)})" if killed_by else ""
        if not killed_by:
            alive.append(m["id"])

        # the control: the same copy without the planted edit. `control:` in the manifest names
        # one explicitly; otherwise it is <file>.control.sql, which regen.py writes.
        control = os.path.join(ROOT, "test/mutants", m["control"]) if m.get("control") \
            else path[:-len(".sql")] + ".control.sql"
        if args.verify and killed_by:
            if not os.path.exists(control):
                uncontrolled.append(m["id"])
                note += "  [no control]"
            else:
                broken = [t for t in m["expect_fail"] if not suite_passes(t, control, env)]
                if broken:
                    unverified.append(m["id"])
                    note += f"  [CONTROL FAILS {', '.join(broken)} -- the kill is not evidence" \
                            f" about the planted edit; regenerate with test/mutants/regen.py]"
                else:
                    note += "  [control passes]"
        print(f"{m['id']} {status}: {m['what']}{note}")

    if uncontrolled:
        print("no control file (kill cause not proved automatically):", ", ".join(uncontrolled))
    if alive:
        print("surviving mutants:", ", ".join(alive))
    if unverified:
        print("unverified kills:", ", ".join(unverified))
    if alive or unverified:
        sys.exit(1)
    print("all mutants killed" + (", every kill verified against its control" if args.verify else ""))


if __name__ == "__main__":
    main()
