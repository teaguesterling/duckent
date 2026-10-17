#!/usr/bin/env python3
"""Apply each planted defect and require the suites that claim to catch it to FAIL -- and prove
the failure is caused by the PLANTED EDIT rather than by the mutant file having drifted from the
macro it copies.

HOW A MUTANT IS APPLIED HERE, AND WHY IT IS NOT A REBUILD

The plan repo loads its macros from `sql/*.sql` at runtime, so its runner applies a mutant by
handing `test/run.py` an extra overlay file to execute after the base macros. This repo EMBEDS
the macros in the binary, which reads as though mutating one needs a rebuild -- 23 mutants plus
their 23 controls is 46 builds, and an hour-scale run nobody would keep.

It does not. A mutant is an OVERLAY: a `CREATE OR REPLACE MACRO` applied *after* the base macros,
and DuckDB's own sqllogictest already has a place to put one. `on_init` ("SQL statements to
execute on init", duckdb/test/helpers/test_config.cpp:44) is read by
TestConfiguration::OnInitCommand() (:266) and executed by SQLLogicTestRunner::Reconnect()
(duckdb/test/sqlite/sqllogic_test_runner.cpp:193) on the connection the test file will use --
which happens AFTER LoadDatabase() has loaded the statically linked extensions, so after
duckent's LoadEmbeddedMacros() has created the base macros. The extension creates them with a
plain Connection in the default catalog and schema, and the overlay's `CREATE OR REPLACE MACRO`
lands in the same schema, so it replaces them in place rather than shadowing them.

So a mutant run is: the repo's own `test/test_config.json` (which already carries
`statically_loaded_extensions` and is already how `make test` resolves duckent -- see the
Makefile) with the overlay SQL added as `on_init`, run against the already-built binary over
that mutant's expect_fail suites. Nothing is rebuilt and nothing in the repo is edited.

Measured, on MN21 against test/sql/11_ddl.test:
  no overlay           exit 0, "All tests passed (218 assertions in 1 test case)"
  mutant overlay       exit 1, "test/sql/11_ddl.test:491: FAILED:"
  control overlay      exit 0, "All tests passed (218 assertions in 1 test case)"
  deliberately broken  exit 1, "Startup queries provided via on_init failed: Parser Error: ..."

The fourth line is why `on_init` is safe to rely on: a mutant whose SQL does not load reports
itself as such instead of looking like a mutant that was applied and survived.

WHAT MAKES A KILL EVIDENCE

Three checks, and they answer different halves of the question. The first two are the plan
repo's; the third is this repo's, because this repo holds a COPY of the mutant corpus.

1. STRUCTURAL. `test/mutants/regen.py` generates each copy-and-edit mutant from the macro it
   copies plus its planted edit. This script rebuilds each in-scope mutant and its control the
   same way and compares, before touching a database. A copy that has drifted from its source is
   out of date whatever the tests say: the plan repo's `error(` -> `tree_err(` sweep left ten
   mutants quoting macros that no longer existed and every one went on being reported KILLED,
   because a macro from two commits ago fails the same tests a wrong macro does.

   regen.py resolves its sources as `<root>/sql/*.sql`; here they are `src/sql_macros/*.sql`, so
   it is imported and pointed at a directory whose `sql` is a symlink to them rather than edited
   -- it is a copy under scripts/check_macro_identity.py like every other file in test/mutants/.

2. BEHAVIOURAL -- the CONTROL. Next to each generated mutant, regen.py writes
   `<file>.control.sql`: the same copy with the edit LEFT OUT, so applying it is a no-op
   `CREATE OR REPLACE` of the current macro. --verify (on by default) applies it and requires
   every suite the mutant is expected to kill to PASS. A kill against a control that also fails
   proves nothing.

3. SCOPE, REPORTED RATHER THAN ASSUMED. This repo carries 16 of the plan repo's suites; the
   front-end ones (the css parser and its lowering, the sitting_duck differentials, the corpus
   and representation suites) belong to a later increment. A mutant whose expect_fail suites are
   all outside is not evidence here either way -- and a mutant that does not run looks exactly
   like a mutant that passed, which is the absence-assertion failure mode this project has
   already been bitten by. So every entry not run is named, with its reason, and counted.

   Scope is DERIVED, not marked. The increment is a set of suites (`INCREMENTS` below, taken
   from the gate's own `DUCKENT_SUITES` so there is one definition of what this repo runs), and
   an entry is in scope exactly when at least one of its expect_fail suites is in that set. Two
   entries straddle the boundary -- MN04 (11_ddl, 12_dml inside; 42_second_differential outside)
   and MN24 (34_groups inside; 38_css_lower outside) -- and they are run against their in-scope
   suites with the excluded ones named. Nothing about that is written down: a hand-written
   `increment:` key per entry would be 23 markings that can go stale the moment a suite moves
   into or out of the gate, and a stale marking is how a mutant stops running without saying so.

  python3 test/run_mutants.py                   staleness + kills + controls (the default)
  python3 test/run_mutants.py --no-verify       staleness + kills only
  python3 test/run_mutants.py --only MN21       just these ids (repeatable)
  python3 test/mutants/regen.py                 (in the PLAN repo) rewrite the generated copies
"""
import argparse, json, os, re, shutil, subprocess, sys, tempfile, time

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Mutants that plant their defect in CATALOG DATA rather than in a copied macro, and so have
# no regen.SPEC entry because there is no copy to rebuild. Named explicitly, never inferred from
# a missing SPEC entry -- "no entry" must keep meaning "something is wrong" for every mutant that
# IS a copy, which is all the others.
#
# MN30 arrived with the slot engine (duckent-plan#66), which turned the combinator vocabulary into
# rows: `UPDATE tree_catalog.combinators SET template = ... WHERE op = 'child'`. It is the first
# in-scope mutant of this shape. MN08 is the other non-generated mutant in the manifest and is out
# of scope for the mvp increment, which is why this category had not come up before.
DATA_MUTANTS = {
    "MN30": "mutates tree_catalog.combinators' child template; no macro copy exists to regenerate",
}

MUTANT_DIR = os.path.join(ROOT, "test", "mutants")
MANIFEST = os.path.join(MUTANT_DIR, "manifest.yaml")
BASE_CONFIG = os.path.join(ROOT, "test", "test_config.json")
DEFAULT_BINARY = os.path.join(ROOT, "build", "release", "test", "unittest")

sys.path.insert(0, os.path.join(ROOT, "test"))
import check_gate  # noqa: E402  -- the gate owns the list of suites this repo runs

# An increment is a SET OF SUITES, not a per-mutant marking. `mvp` is exactly what the gate
# asserts ran, so "in the MVP" has one definition in this repo and the two cannot disagree.
# Adding the front-end increment later means adding its suite set here -- not 23 markings.
INCREMENTS = {"mvp": frozenset(check_gate.DUCKENT_SUITES)}

# Catch2 prints a per-record failure as `test/sql/<suite>.test:<line>: FAILED:`. Requiring one
# distinguishes "the suite ran and a record disagreed" from every other way exit 1 happens.
FAIL_RECORD_RE = re.compile(r"^test/sql/[^\s:]+\.test:\d+: FAILED:", re.MULTILINE)
ALL_PASSED_RE = re.compile(r"^All tests passed \(", re.MULTILINE)
# sqllogic_test_runner.cpp:195 -- the overlay itself did not load.
ON_INIT_FAILED_RE = re.compile(r"Startup queries provided via on_init failed: (.*)")


def suite_name(test_path):
    """`test/sql/11_ddl.test` -> `11_ddl`, the spelling INCREMENTS and the gate both use."""
    return os.path.basename(test_path)[: -len(".test")]


class Runner:
    """Runs one suite under one overlay, memoized on (suite, overlay)."""

    def __init__(self, binary, tmpdir):
        self.binary = binary
        self.tmpdir = tmpdir
        self.base = json.load(open(BASE_CONFIG))
        self.cache = {}
        self.configs = {}
        self.runs = 0

    def config_for(self, overlay):
        """The repo's own test config plus the overlay as `on_init`. Everything else -- notably
        statically_loaded_extensions, which is how duckent resolves at all -- is inherited, so a
        mutant run differs from `make test` in exactly one key."""
        if overlay not in self.configs:
            cfg = dict(self.base)
            cfg["on_init"] = open(overlay).read()
            path = os.path.join(self.tmpdir, os.path.basename(overlay) + ".config.json")
            with open(path, "w") as fh:
                json.dump(cfg, fh, indent=2)
            self.configs[overlay] = path
        return self.configs[overlay]

    def result(self, test, overlay):
        """'pass', 'fail', or a 'broken: <reason>' string.

        'broken' is its own answer rather than folded into either of the others: an overlay that
        did not load, or a process that died, says nothing about the planted edit, and calling
        that a survival or a kill would be a claim the run does not support."""
        key = (test, overlay)
        if key in self.cache:
            return self.cache[key]
        self.runs += 1
        proc = subprocess.run(
            [self.binary, test, "--test-config", self.config_for(overlay)],
            capture_output=True, text=True, cwd=ROOT,
        )
        out = proc.stdout + proc.stderr

        verdict = None
        m = ON_INIT_FAILED_RE.search(out)
        if m:
            verdict = "broken: the overlay did not load -- " + m.group(1).strip()
        else:
            for pattern, what in check_gate.CRASH_SIGNATURES:
                if pattern.search(out):
                    verdict = "broken: the process died (%s)" % what
                    break
        if verdict is None:
            if proc.returncode == 0 and ALL_PASSED_RE.search(out):
                verdict = "pass"
            elif FAIL_RECORD_RE.search(out):
                verdict = "fail"
            else:
                verdict = ("broken: exit %d with no `<suite>.test:<line>: FAILED:` record and no "
                           "passing summary" % proc.returncode)
        self.cache[key] = verdict
        return verdict


def check_staleness(ids, manifest, problems):
    """Check 1: is every in-scope copy still the macro it copies plus its planted edit?

    regen.py is imported rather than run, because it resolves its sources as `<ROOT>/sql/*.sql`
    and this repo spells them `src/sql_macros/*.sql`. Pointing a copy of regen.ROOT at a
    directory whose `sql` symlinks to them keeps the file here byte-identical to the plan repo's
    -- which is what scripts/check_macro_identity.py requires of everything in test/mutants/.

    Only in-scope mutants are checked, and that is a real limit rather than a convenience: MN22
    copies from sql/09_css.sql, which this repo deliberately does not embed (it is the css
    front-end, OMITTED in the identity check), so there is nothing here to rebuild it from.
    """
    sys.path.insert(0, MUTANT_DIR)
    import regen  # noqa: E402

    shim = tempfile.mkdtemp(prefix="duckent-regen-")
    try:
        os.symlink(os.path.join(ROOT, "src", "sql_macros"), os.path.join(shim, "sql"))
        regen.ROOT = shim
        by_id = {m["id"]: m for m in manifest}
        for mid in ids:
            spec = regen.SPEC.get(mid)
            mutant = os.path.join(MUTANT_DIR, by_id[mid]["file"])
            if mid in DATA_MUTANTS and spec is None:
                # A mutant that plants its defect in catalog DATA has no macro copy, so there is
                # nothing for regen to rebuild and the SPEC requirement below does not apply. Its
                # structural evidence comes from its CONTROL instead, and that is not a weaker
                # claim here: the control re-asserts the CORRECT value, and the derivation gate in
                # 46_slot_registry.test -- which is listed in this mutant's expect_fail, so it must
                # PASS under the control -- compares every registry row against the macro it was
                # derived from. A control whose literal had drifted from that macro therefore fails
                # the control run loudly, which is exactly what the SPEC check buys for a copy.
                # The control must still exist; a data mutant with no control has no evidence at all.
                control = mutant[: -len(".sql")] + ".control.sql"
                if not os.path.exists(control):
                    problems.append(
                        "%s: listed in DATA_MUTANTS but has no .control.sql, so neither half of "
                        "the kill's evidence is present" % mid
                    )
                continue
            if spec is None:
                problems.append(
                    "%s: in scope for this increment but test/mutants/regen.py has no SPEC entry "
                    "for it, so its copy cannot be rebuilt from the macro it copies -- the "
                    "structural half of the kill's evidence is missing%s" % (
                        mid,
                        "" if mid in DATA_MUTANTS else
                        " (if it mutates catalog data rather than copying a macro, add it to "
                        "DATA_MUTANTS with a reason)",
                    )
                )
                continue
            control = mutant[: -len(".sql")] + ".control.sql"
            targets = [(control, False)] + ([(mutant, True)] if spec[2] else [])
            try:
                for path, edits_on in targets:
                    want = regen.build(mid, spec, path, edits_on)
                    have = open(path).read() if os.path.exists(path) else None
                    if want != have:
                        problems.append(
                            "%s: test/mutants/%s no longer matches the macro it copies plus its "
                            "planted edit, so a kill says nothing about the edit -- regenerate it "
                            "in the plan repo with python3 test/mutants/regen.py and re-copy"
                            % (mid, os.path.basename(path))
                        )
                if not spec[2]:
                    missing = regen.overridden_macros_missing_from_sql(open(mutant).read())
                    if missing:
                        problems.append(
                            "%s: test/mutants/%s overrides %s, which src/sql_macros/ no longer "
                            "defines -- the mutant mutates nothing the suites still call"
                            % (mid, os.path.basename(mutant), ", ".join(missing))
                        )
            except SystemExit as exc:
                # regen.build() exits when a planted edit no longer matches its source text.
                problems.append("%s: could not be rebuilt from its source macro -- %s" % (mid, exc))
            except FileNotFoundError as exc:
                problems.append("%s: could not be rebuilt -- %s" % (mid, exc))
    finally:
        shutil.rmtree(shim, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--increment", default="mvp", choices=sorted(INCREMENTS),
                    help="which increment's suites this repo can run (default: mvp)")
    ap.add_argument("--verify", dest="verify", action="store_true", default=True,
                    help="also require each mutant's control to PASS (the default)")
    ap.add_argument("--no-verify", dest="verify", action="store_false",
                    help="check kills only; do not run the controls")
    ap.add_argument("--only", action="append", metavar="ID",
                    help="run just these mutant ids (repeatable)")
    ap.add_argument("--binary", default=DEFAULT_BINARY,
                    help="the unittest binary to run (default: build/release/test/unittest)")
    args = ap.parse_args()

    if not os.path.exists(args.binary):
        sys.exit("no unittest binary at %s -- run `make` first" % args.binary)

    suites = INCREMENTS[args.increment]
    manifest = yaml.safe_load(open(MANIFEST))
    unknown = set(args.only or []) - {m["id"] for m in manifest}
    if unknown:
        sys.exit("unknown mutant id " + ", ".join(sorted(unknown)))

    # Scope, derived from the manifest against the increment's suite set.
    in_scope, out_of_scope, partial, refused = [], [], {}, []
    for m in manifest:
        inside = [t for t in m["expect_fail"] if suite_name(t) in suites]
        outside = [t for t in m["expect_fail"] if suite_name(t) not in suites]
        if not inside:
            out_of_scope.append((m["id"], outside))
            continue
        if m.get("env"):
            # The one `env` entry in the manifest (MN08) is a python-side mutation of the plan
            # repo's own css parser -- not expressible as a macro overlay at all, and front-end,
            # so out of scope here. This repo therefore does not port that mechanism. It refuses
            # rather than skipping, so that the day an in-scope entry grows an `env` map it is an
            # error naming the entry and not a mutant that quietly stopped being applied.
            refused.append(m["id"])
            continue
        in_scope.append(m)
        if outside:
            partial[m["id"]] = outside

    if refused:
        sys.exit(
            "in scope for the %s increment but carrying an `env` map: %s. An `env` mutation is "
            "python-side -- it mutates the plan repo's own runner, not a macro -- so it cannot be "
            "applied as a `CREATE OR REPLACE MACRO` overlay and this harness has no mechanism for "
            "it. Either the entry does not belong in this increment, or this harness needs "
            "extending; it must not be silently skipped."
            % (args.increment, ", ".join(refused))
        )

    problems = []

    # A suite excluded from the increment whose file is nonetheless present here means the gate's
    # suite set and the corpus have come apart -- the exclusion would be silently wrong, which is
    # the stale-marking failure derivation exists to prevent.
    for mid, excluded in list(out_of_scope) + list(partial.items()):
        for t in excluded:
            if os.path.exists(os.path.join(ROOT, t)):
                problems.append(
                    "%s: %s is excluded from the %s increment but the file exists in this repo -- "
                    "the gate's suite list and the corpus disagree; add it to the gate's suites or "
                    "remove the file" % (mid, t, args.increment)
                )

    processed = [m for m in in_scope if not args.only or m["id"] in args.only]
    check_staleness([m["id"] for m in processed], manifest, problems)
    if problems:
        sys.stderr.write("mutant harness refused to run:\n")
        for p in problems:
            sys.stderr.write("  - " + p + "\n")
        sys.exit(1)

    started = time.time()
    tmpdir = tempfile.mkdtemp(prefix="duckent-mutants-")
    alive, unverified, uncontrolled, broken, manual, verified_ok, killed = [], [], [], [], [], [], []
    try:
        runner = Runner(args.binary, tmpdir)
        for m in processed:
            path = os.path.join(MUTANT_DIR, m["file"])
            tests = [t for t in m["expect_fail"] if suite_name(t) in suites]
            results = {t: runner.result(t, path) for t in tests}

            bad = {t: v for t, v in results.items() if v.startswith("broken")}
            if bad:
                status = "BROKEN: " + "; ".join("%s -- %s" % (t, v) for t, v in bad.items())
                broken.append(m["id"])
                note = ""
            elif all(v == "fail" for v in results.values()):
                status = "KILLED"
                killed.append(m["id"])
                note = "  (by %s)" % ", ".join(tests)
            else:
                survived_in = [t for t, v in results.items() if v != "fail"]
                status = "SURVIVED in " + ", ".join(survived_in)
                alive.append(m["id"])
                note = ""

            if m.get("control") == "manual":
                manual.append(m["id"])
                note += "  [manual control]"
            elif args.verify and status == "KILLED":
                control = os.path.join(MUTANT_DIR, m["control"]) if m.get("control") \
                    else path[: -len(".sql")] + ".control.sql"
                if not os.path.exists(control):
                    uncontrolled.append(m["id"])
                    note += "  [no control]"
                else:
                    cresults = {t: runner.result(t, control) for t in tests}
                    cbad = [t for t, v in cresults.items() if v != "pass"]
                    if cbad:
                        unverified.append(m["id"])
                        note += ("  [CONTROL does not pass %s -- the kill is not evidence about "
                                 "the planted edit; regenerate the mutant]"
                                 % ", ".join("%s (%s)" % (t, cresults[t]) for t in cbad))
                    else:
                        verified_ok.append(m["id"])
                        note += "  [control passes]"

            if m["id"] in partial:
                note += ("  [%d of %d suites in scope; outside the %s increment, not run: %s]"
                         % (len(tests), len(m["expect_fail"]), args.increment,
                            ", ".join(partial[m["id"]])))
            print("%s %s: %s%s" % (m["id"], status, m["what"], note))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    elapsed = time.time() - started

    # Out of scope is REPORTED, with a count, every run. A mutant that does not run looks
    # exactly like a mutant that passed unless something says out loud that it did not run.
    if out_of_scope:
        print("\nout of scope for the %s increment (%d) -- every suite that claims to catch them "
              "is a front-end suite this repo does not carry:" % (args.increment, len(out_of_scope)))
        for mid, excluded in out_of_scope:
            print("  %s: needs %s" % (mid, ", ".join(excluded)))
    if partial:
        print("\nrun against part of their claim (%d) -- in scope, judged on the suites this repo "
              "has, with the rest deferred to a later increment:" % len(partial))
        for mid, excluded in sorted(partial.items()):
            print("  %s: not run here: %s" % (mid, ", ".join(excluded)))

    print()
    if broken:
        print("broken mutants (the overlay did not load, or the process died):", ", ".join(broken))
    if uncontrolled:
        print("no control file (kill cause not proved automatically):", ", ".join(uncontrolled))
    if alive:
        print("SURVIVING mutants:", ", ".join(alive))
    if unverified:
        print("unverified kills:", ", ".join(unverified))
    if alive or unverified or broken:
        print("%d of %d in-scope mutants killed in %.0fs (%d suite runs)"
              % (len(killed), len(processed), elapsed, runner.runs))
        sys.exit(1)

    print("%d of %d manifest entries in scope for the %s increment%s; all %d killed%s; "
          "out of scope: %d%s"
          % (len(in_scope), len(manifest), args.increment,
             " (%d of them selected by --only)" % len(processed) if args.only else "",
             len(processed),
             "; %d of %d kills verified against a control" % (len(verified_ok), len(processed))
             if args.verify else " (controls not run: --no-verify)",
             len(out_of_scope),
             "; manual: %s" % ", ".join(manual) if manual else ""))
    print("%d suite runs in %.0fs" % (runner.runs, elapsed))


if __name__ == "__main__":
    main()
