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


def suite_result(test, overlay, env):
    """'pass', 'fail' (exit 1 with at least one FAIL record) or 'broken' (the overlay did not
    load, or the suite failed without a FAIL record). Memoized on the overlay's path."""
    key = (test, overlay, tuple(sorted((k, v) for k, v in env.items() if k.startswith("DUCKENT_"))))
    if key not in _cache:
        r = subprocess.run([sys.executable, os.path.join(ROOT, "test/run.py"), os.path.join(ROOT, test),
                            "--mutant", overlay], capture_output=True, text=True, env=env, cwd=ROOT)
        if r.returncode == 0:
            _cache[key] = "pass"
        elif r.returncode == 1 and any(l.startswith("FAIL ") and ".test:" in l for l in r.stdout.splitlines()):
            _cache[key] = "fail"
        else:
            _cache[key] = "broken"
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
    unknown = set(args.only or []) - {m["id"] for m in manifest}
    if unknown:
        sys.exit("unknown mutant id " + ", ".join(sorted(unknown)))

    alive, unverified, uncontrolled, broken_mutants, manual, verified_ok = [], [], [], [], [], []
    processed = [m for m in manifest if not args.only or m["id"] in args.only]
    for m in processed:
        path = os.path.join(ROOT, "test/mutants", m["file"])
        # A mutant whose mutation is PYTHON-side (the runner's own css parser, say) cannot be
        # expressed as a CREATE OR REPLACE MACRO override, so the manifest may carry an `env` map
        # that is added to the environment of every subprocess run for that mutant; its SQL file is
        # then comment-only. Keys are read by the runner, not by the SQL: see MN08.
        env = dict(os.environ, **{k: str(v) for k, v in (m.get("env") or {}).items()})
        results = {t: suite_result(t, path, env) for t in m["expect_fail"]}
        broken = [t for t, v in results.items() if v == "broken"]
        if broken:
            status = f"BROKEN (did not load or failed without a FAIL record): {', '.join(broken)}"
            broken_mutants.append(m["id"])
            note = ""
        elif all(v == "fail" for v in results.values()):
            status = "KILLED"
            note = f"  (by {', '.join(m['expect_fail'])})"
        else:
            survived_in = [t for t, v in results.items() if v != "fail"]
            status = f"SURVIVED in {', '.join(survived_in)}"
            alive.append(m["id"])
            note = ""

        # the control: the same copy without the planted edit. `control:` in the manifest names
        # one explicitly; otherwise it is <file>.control.sql, which regen.py writes.
        is_manual = m.get("control") == "manual"
        if is_manual:
            manual.append(m["id"])
            note += "  [manual control]"
        elif args.verify and status == "KILLED":
            control = os.path.join(ROOT, "test/mutants", m["control"]) if m.get("control") \
                else path[:-len(".sql")] + ".control.sql"
            if not os.path.exists(control):
                uncontrolled.append(m["id"])
                note += "  [no control]"
            else:
                control_broken = [t for t in m["expect_fail"] if suite_result(t, control, env) != "pass"]
                if control_broken:
                    unverified.append(m["id"])
                    note += f"  [CONTROL FAILS {', '.join(control_broken)} -- the kill is not evidence" \
                            f" about the planted edit; regenerate with test/mutants/regen.py]"
                else:
                    verified_ok.append(m["id"])
                    note += "  [control passes]"
        print(f"{m['id']} {status}: {m['what']}{note}")

    if broken_mutants:
        print("broken mutants (did not load, or failed without a FAIL record):", ", ".join(broken_mutants))
    if uncontrolled:
        print("no control file (kill cause not proved automatically):", ", ".join(uncontrolled))
    if alive:
        print("surviving mutants:", ", ".join(alive))
    if unverified:
        print("unverified kills:", ", ".join(unverified))
    if alive or unverified or broken_mutants:
        sys.exit(1)
    if args.verify:
        print("all mutants killed; %d of %d kills verified against a control; manual: %s" % (
            len(verified_ok), len(processed), ", ".join(manual) if manual else "none"))
    else:
        print("all mutants killed")


if __name__ == "__main__":
    main()
