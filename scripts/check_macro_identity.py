#!/usr/bin/env python3
"""Every embedded .sql file, and every copied test suite, must be byte-identical
to the plan repo's.

Embedding the macros puts the same semantics in two repositories. The only
permitted difference is WHICH files the extension embeds -- 09_css.sql is a
front-end and is omitted. Any difference in a file that IS embedded is a fork,
and a fork is exactly what this gate exists to prevent.

The test suites under test/sql/ are copies of the same kind, for the same reason:
test/sql/*.test is the corpus that proves the embedded macros, so an un-guarded
copy of it can drift exactly like an un-guarded macro can -- two corrections had
already been hand-carried forward before this check existed. The rule mirrors the
macro check's: a file with a counterpart in the plan repo must be byte-identical
to it, and a file with no counterpart must be explicitly named as extension-only
(EXTENSION_ONLY_TESTS below) rather than silently passing by virtue of having
nothing to compare against -- an unlisted new file is a drift finding, the same
way an un-embedded new macro file is one below.
"""
import argparse, hashlib, os, sys

OMITTED = {"09_css.sql"}

# .test files that exist only in this repo (no counterpart in the plan repo's
# test/sql/): the C++ verb-executor tests, and the two files that prove the
# extension loads its statically-linked dependencies and embedded macros at all.
EXTENSION_ONLY_TESTS = {"12_verb_executor.test", "90_loads.test", "91_macros_load.test"}

# The reverse direction, which the first version of this check did not have: plan-repo
# .test files this repo deliberately does NOT mirror. Everything here belongs to the
# front-end increment -- the css parser and its lowering, the sitting_duck differentials,
# the corpus and representation suites -- none of which a core-only build can run.
#
# Without this set, a NEW suite appearing in the plan repo is silence: the forward check
# only ever looks at files that exist HERE, so a suite added there and never copied here
# would never be mentioned by anything. That is the same defect shape as every other one
# this project has hit, and it is the reason OMITTED exists for the macros. The cost of
# the list is that adding a deliberately-unmirrored suite needs a line here; the benefit
# is that forgetting to mirror one cannot pass quietly.
NOT_MIRRORED_TESTS = {
    "37_css_parser.test",
    "38_css_lower.test",
    "40_corpus.test",
    "41_differential_sitting_duck.test",
    "41b_live_sitting_duck.test",
    "42_second_differential.test",
    "43_representation.test",
    "44_parsers.test",
    "45_duck_blocks.test",
}

def digest(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()

def check_macros(root, plan_repo, bad):
    here = os.path.join(root, "src", "sql_macros")
    there = os.path.join(plan_repo, "sql")

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

def check_test_corpus(root, plan_repo, bad):
    here = os.path.join(root, "test", "sql")
    there = os.path.join(plan_repo, "test", "sql")

    for name in sorted(os.listdir(here)):
        if not name.endswith(".test"):
            continue
        mine, theirs = os.path.join(here, name), os.path.join(there, name)
        has_counterpart = os.path.exists(theirs)

        if name in EXTENSION_ONLY_TESTS:
            if has_counterpart:
                bad.append(
                    f"{name}: listed as extension-only in EXTENSION_ONLY_TESTS, but the plan "
                    "repo now has a file by this name -- remove it from EXTENSION_ONLY_TESTS "
                    "and let the identity check compare it"
                )
            continue

        if not has_counterpart:
            bad.append(
                f"{name}: no counterpart in the plan repo's test/sql/, and not listed in "
                "EXTENSION_ONLY_TESTS (add it there with a reason, or confirm it should be "
                "copied from the plan repo)"
            )
        elif digest(mine) != digest(theirs):
            bad.append(f"{name}: differs from the plan repo's test/sql/{name}")

    # The reverse direction: every plan-repo suite is either mirrored here or declared
    # unmirrored. A suite added there and forgotten here is otherwise invisible, because
    # the loop above only ever walks files that already exist in this repo.
    for name in sorted(os.listdir(there)):
        if not name.endswith(".test"):
            continue
        if name in NOT_MIRRORED_TESTS:
            if os.path.exists(os.path.join(here, name)):
                bad.append(
                    f"{name}: listed in NOT_MIRRORED_TESTS but present here -- remove it "
                    "from that list so the identity check compares it"
                )
            continue
        if not os.path.exists(os.path.join(here, name)):
            bad.append(
                f"{name}: in the plan repo's test/sql/ but not copied here, and not listed "
                "in NOT_MIRRORED_TESTS (copy it, or add it there with a reason)"
            )

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan-repo", required=True, help="path to the duckent plan repo")
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    bad = []

    check_macros(root, args.plan_repo, bad)
    check_test_corpus(root, args.plan_repo, bad)

    if bad:
        sys.stderr.write("macro identity check FAILED:\n")
        for b in bad:
            sys.stderr.write("  - " + b + "\n")
        sys.exit(1)
    print("macro identity: every embedded macro and copied test suite matches the plan repo")

if __name__ == "__main__":
    main()
