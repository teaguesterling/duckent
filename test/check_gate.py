#!/usr/bin/env python3
"""Assert the gate actually RAN, not merely that nothing failed.

The plan repo's runner has DUCKENT_NO_SKIP, which turns a skip into a failure;
that mechanism is why an incident of 17 vacuous assertions was caught once.
DuckDB's `require` merely skips. The MVP has no `require` lines, so nothing can
skip -- which is a property to assert, not to assume.

This script reads a `make test` log and checks six things:
  1. a summary was actually present and parses -- and the two Catch2 shapes that mean
     "nothing meaningful ran" are recognized AS SUCH, not merely as unparseable
  2. the assertion count is >= EXPECTED_ASSERTIONS (a FLOOR -- the number has moved
     487 -> 497 -> 495 -> 1230 and will keep moving, so this is never an exact match)
  3. zero assertions failed
  4. zero test cases were skipped (nothing in this corpus uses `require`, so any skip at
     all means something regressed, not that a line was correctly elided)
  5. every suite in DUCKENT_SUITES appears in a RUN MARKER -- the runner's own
     `[N/M] (pct%): test/sql/<suite>.test` progress line -- not merely somewhere in the
     log text; and the runner's own declared total M agrees with the summary's test-case
     count, so two independently produced numbers have to agree
  6. the log carries no signature of the process dying

An unparseable summary is a FAILURE, not a pass. That is the actual point of this script:
the first version of this file declared EXPECTED_ASSERTIONS and never read it, so a log
with no recognizable summary -- or a smaller count -- read as green. Absence must never
look like success.

Checks 5 and 6 exist because of two measured holes in the version before this one, and
both are worth stating because they are the same mistake in two costumes.

  Check 5. The suite check used to be a context-free substring search for
  `test/sql/<suite>.test` anywhere in the log. Take a real log, remove 02_catalog's run
  markers, append `warning: could not stat test/sql/02_catalog.test, skipping` -- and the
  gate printed "all 16 suites ran" and exited 0. The assertion floor cannot cover for
  this: 02_catalog is ~37 assertions, so dropping it leaves well over 1100, far above the
  floor. The floor and the suite check LOOK like two independent guards and are not --
  only the suite check can see a dropped suite, so it is the one place that must not be
  loose. A run marker is emitted by the runner when it starts a file, which is a much
  harder thing to forge accidentally than the file's name appearing in prose.

  Check 6. This script reads text and never an exit code, so a crash AFTER Catch2 printed
  a passing summary -- a segfault in extension teardown, say -- was invisible here. It
  was also invisible in CI, because `make test 2>&1 | tee test.log` under GitHub's
  implicit `bash -e {0}` reports the exit status of `tee`. The CI fix is `shell: bash`
  plus `set -o pipefail`; this check is the second, independent one, so neither mechanism
  is the only thing standing between a crash and a green badge.
"""
import re, sys

EXPECTED_FILES = 16
EXPECTED_ASSERTIONS = 495  # a FLOOR, asserted with >=

DUCKENT_SUITES = {
    "00_smoke", "01_types", "02_catalog", "03_fixtures", "10_projection", "11_ddl",
    "12_dml", "13_alter", "20_derivations", "30_selector", "31_match", "32_traversal",
    "33_navigation", "34_groups", "35_attr_map", "36_pseudo",
}

# Catch2's ConsoleReporter::printTotals (duckdb/third_party/catch/catch.hpp:16921-16954)
# emits one of FOUR shapes, not two. In source order:
#
#   1. no test case ran at all:
#        No tests ran
#   2. every test case that existed was skipped:
#        All tests were skipped (total skipped 3)
#   3. everything that ran passed (the skipped-tests clause appears only when non-zero,
#      and the test-case count EXCLUDES skipped cases):
#        All tests passed (1230 assertions in 19 test cases)
#        All tests passed (2 skipped tests, 997 assertions in 13 test cases)
#   4. anything failed (zero-valued columns are omitted, so `skipped` may or may not
#      appear here either):
#        test cases:  14 |  13 passed | 1 failed
#        assertions: 998 | 997 passed | 1 failed | 2 skipped
#
# Shapes 1 and 2 used to fall through to "could not parse a summary", which exited 1 and
# so failed SAFE -- but it reported the wrong reason, in a script whose whole purpose is
# not overclaiming what it verified. They are named explicitly below.

NO_TESTS_RE = re.compile(r"^No tests ran$", re.MULTILINE)
ALL_SKIPPED_RE = re.compile(r"^All tests were skipped \(total skipped (\d+)\)$", re.MULTILINE)
ALL_PASSED_RE = re.compile(
    r"All tests passed \((?:(\d+) skipped tests?, )?(\d+) assertions? in (\d+) test cases?\)"
)
ASSERTIONS_LINE_RE = re.compile(r"^assertions:\s*(\d+)\s*\|(.*)$", re.MULTILINE)
CASES_LINE_RE = re.compile(r"^test cases:\s*(\d+)\s*\|", re.MULTILINE)
COLUMN_RE = re.compile(r"(\d+)\s+(passed|failed|skipped)")

# The runner's own progress line, emitted as it starts each file:
#   [17/19] (89%): test/sql/02_catalog.test
RUN_MARKER_RE = re.compile(
    r"^\[(\d+)/(\d+)\]\s+\(\d+%\):\s+test/sql/([^\s/]+)\.test\s*$", re.MULTILINE
)

# Signatures of the process dying rather than finishing. Deliberately limited to things
# that cannot plausibly appear inside a test's expected error text -- duckent's corpus
# pins a great many error MESSAGES, so a loose pattern here would fail on correct work.
# "Current transaction is aborted" is an asserted duckent message, which is why the
# pattern below is an anchored, capitalized, standalone `Aborted` and not the word.
CRASH_SIGNATURES = [
    (re.compile(r"Segmentation fault"), "a segmentation fault"),
    (re.compile(r"core dumped"), "a core dump"),
    (re.compile(r"^Aborted\b", re.MULTILINE), "SIGABRT"),
    (re.compile(r"^Bus error\b", re.MULTILINE), "SIGBUS"),
    (re.compile(r"terminate called after throwing"), "an uncaught C++ exception"),
    (re.compile(r"double free or corruption"), "heap corruption"),
    (re.compile(r"\*\*\* stack smashing detected"), "stack smashing"),
    (re.compile(r"(AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer)"),
     "a sanitizer report"),
]


def parse_counts(log):
    """Return (total_assertions, failed, skipped, cases) or a str naming why it cannot.

    A string return is a diagnosis, not a fallback: every branch here refuses with a
    reason, so a caller can never mistake "we could not tell" for "nothing was wrong".
    """
    if NO_TESTS_RE.search(log):
        return "the runner reported `No tests ran` -- zero test cases were discovered"

    m = ALL_SKIPPED_RE.search(log)
    if m:
        return (
            "the runner reported `All tests were skipped (total skipped %s)`. Nothing in "
            "this corpus uses `require`, so a universal skip is a harness or build "
            "failure, not an elision" % m.group(1)
        )

    m = ALL_PASSED_RE.search(log)
    if m:
        skipped = int(m.group(1) or 0)
        return int(m.group(2)), 0, skipped, int(m.group(3))

    m = ASSERTIONS_LINE_RE.search(log)
    if m:
        total = int(m.group(1))
        failed = 0
        skipped = 0
        for count, label in COLUMN_RE.findall(m.group(2)):
            if label == "failed":
                failed = int(count)
            elif label == "skipped":
                skipped = int(count)
        cases_m = CASES_LINE_RE.search(log)
        cases = int(cases_m.group(1)) if cases_m else None
        return total, failed, skipped, cases

    return (
        "no Catch2 summary was found in the log at all. An unparseable log is a failure, "
        "not a pass -- nothing in it proved whether the suite ran"
    )


def main(path):
    log = open(path).read()
    problems = []

    counts = parse_counts(log)
    if isinstance(counts, str):
        sys.stderr.write("gate FAILED: %s\n" % counts)
        sys.exit(1)

    total, failed, skipped, cases = counts

    if total < EXPECTED_ASSERTIONS:
        problems.append(
            "only %d assertions ran (floor is %d)" % (total, EXPECTED_ASSERTIONS)
        )
    if failed != 0:
        problems.append("%d assertion(s) failed" % failed)
    if skipped != 0:
        problems.append(
            "%d test case(s) were skipped (nothing in this corpus uses `require`, "
            "so any skip is a regression, not an elision)" % skipped
        )

    # Check 5: run markers, not free text.
    markers = RUN_MARKER_RE.findall(log)
    ran = {suite for _, _, suite in markers}
    missing = sorted(DUCKENT_SUITES - ran)
    if missing:
        problems.append(
            "these suites have no run marker in the log, so they did not run: %s"
            % ", ".join(missing)
        )
    if not markers:
        problems.append(
            "the log contains no `[N/M] (pct%): test/sql/<suite>.test` run markers at "
            "all -- either the runner's output format changed, in which case this script "
            "needs updating, or nothing ran"
        )
    else:
        declared = {int(m[1]) for m in markers}
        if len(declared) != 1:
            problems.append(
                "the run markers disagree about how many files there are: %s"
                % ", ".join(str(d) for d in sorted(declared))
            )
        elif cases is not None:
            # Shape 3's test-case count excludes skipped cases, so the runner's declared
            # total equals it only once skipped is zero -- which is asserted above. These
            # two numbers are produced by different code on different lines, so their
            # agreement is worth something that neither alone is.
            declared_total = declared.pop()
            expected_total = cases + skipped
            if declared_total != expected_total:
                problems.append(
                    "the runner declared %d files but the summary accounts for %d "
                    "(%d cases + %d skipped) -- a file was discovered and never "
                    "summarized" % (declared_total, expected_total, cases, skipped)
                )

    # Check 6: the process finished rather than died.
    for pattern, what in CRASH_SIGNATURES:
        if pattern.search(log):
            problems.append(
                "the log carries a signature of %s. A crash after the summary printed "
                "would otherwise read as a clean pass here" % what
            )

    if problems:
        sys.stderr.write("gate FAILED:\n")
        for p in problems:
            sys.stderr.write("  - " + p + "\n")
        sys.exit(1)

    print(
        "gate: all %d suites ran (by run marker), %d assertions (>= %d), 0 failures, "
        "0 skipped, no crash signature"
        % (EXPECTED_FILES, total, EXPECTED_ASSERTIONS)
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: check_gate.py <log-file>\n")
        sys.exit(2)
    main(sys.argv[1])
