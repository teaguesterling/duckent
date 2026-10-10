#!/usr/bin/env python3
"""Assert the gate actually RAN, not merely that nothing failed.

The plan repo's runner has DUCKENT_NO_SKIP, which turns a skip into a failure;
that mechanism is why an incident of 17 vacuous assertions was caught once.
DuckDB's `require` merely skips. The MVP has no `require` lines, so nothing can
skip -- which is a property to assert, not to assume.

This script reads a `make test` log and checks four things:
  1. an assertion count was actually present in the log and parses to >= EXPECTED_ASSERTIONS
     (a FLOOR -- the number has moved 487 -> 497 -> 495 and will keep moving, so this is
     never an exact match)
  2. zero assertions failed
  3. zero test cases were skipped (nothing in this corpus uses `require`, so any skip at
     all means something regressed, not that a line was correctly elided)
  4. every suite named in DUCKENT_SUITES actually appears in the log

An unparseable assertion-count line is treated as a FAILURE, not a pass. That is the
actual point of this script: the earlier version of this file declared EXPECTED_ASSERTIONS
and never read it, so a log with no recognizable summary line -- or a smaller count -- would
have read as green. Absence must never look like success.
"""
import re, sys

EXPECTED_FILES = 16
EXPECTED_ASSERTIONS = 495  # a FLOOR, asserted with >=

DUCKENT_SUITES = {
    "00_smoke", "01_types", "02_catalog", "03_fixtures", "10_projection", "11_ddl",
    "12_dml", "13_alter", "20_derivations", "30_selector", "31_match", "32_traversal",
    "33_navigation", "34_groups", "35_attr_map", "36_pseudo",
}

# Catch2's ConsoleReporter::printTotals (duckdb/third_party/catch/catch.hpp) emits one of two
# shapes:
#
#   All tests passed (1018 assertions in 14 test cases)
#   All tests passed (2 skipped tests, 997 assertions in 13 test cases)
#
# or, whenever anything failed (zero-valued columns are omitted, so "skipped" may or may not
# be present even in this branch):
#
#   test cases:  14 |  13 passed | 1 failed
#   assertions: 998 | 997 passed | 1 failed | 2 skipped
#
# Both are handled below. Verified against real output from this repo's own `make test`
# (both a clean pass and an injected failure), not just the two samples in the brief.

ALL_PASSED_RE = re.compile(
    r"All tests passed \((?:(\d+) skipped tests?, )?(\d+) assertions? in \d+ test cases?\)"
)
SUMMARY_LINE_RE = re.compile(r"^assertions:\s*(\d+)\s*\|(.*)$", re.MULTILINE)
COLUMN_RE = re.compile(r"(\d+)\s+(passed|failed|skipped)")


def parse_counts(log):
    """Return (total_assertions, failed, skipped), or None if no summary line parses."""
    m = ALL_PASSED_RE.search(log)
    if m:
        skipped = int(m.group(1) or 0)
        total = int(m.group(2))
        return total, 0, skipped

    m = SUMMARY_LINE_RE.search(log)
    if m:
        total = int(m.group(1))
        failed = 0
        skipped = 0
        for count, label in COLUMN_RE.findall(m.group(2)):
            if label == "failed":
                failed = int(count)
            elif label == "skipped":
                skipped = int(count)
        return total, failed, skipped

    return None


def main(path):
    log = open(path).read()
    problems = []

    counts = parse_counts(log)
    if counts is None:
        sys.stderr.write(
            "gate FAILED: could not find or parse an assertion-count summary line in the "
            "log. An unparseable log is a failure, not a pass -- it means nothing proved\n"
            "whether the suite ran.\n"
        )
        sys.exit(1)

    total, failed, skipped = counts

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

    ran = {s for s in DUCKENT_SUITES if re.search(r"test/sql/%s\.test\b" % re.escape(s), log)}
    missing = sorted(DUCKENT_SUITES - ran)
    if missing:
        problems.append("these suites did not run: %s" % ", ".join(missing))

    if problems:
        sys.stderr.write("gate FAILED:\n")
        for p in problems:
            sys.stderr.write("  - " + p + "\n")
        sys.exit(1)

    print(
        "gate: all %d suites ran, %d assertions (>= %d), 0 failures, 0 skipped"
        % (EXPECTED_FILES, total, EXPECTED_ASSERTIONS)
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write("usage: check_gate.py <log-file>\n")
        sys.exit(2)
    main(sys.argv[1])
