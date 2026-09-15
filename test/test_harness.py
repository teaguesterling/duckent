"""The runner's and the mutant harness's own rules, tested on throwaway .test files."""
import os, subprocess, sys, tempfile, textwrap, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN = [sys.executable, os.path.join(ROOT, "test/run.py")]


def run_test_text(text, *extra, env=None):
    with tempfile.NamedTemporaryFile("w", suffix=".test", delete=False, dir=os.path.join(ROOT, "test")) as f:
        f.write(textwrap.dedent(text))
        path = f.name
    try:
        return subprocess.run(RUN + [path, *extra], capture_output=True, text=True, cwd=ROOT,
                              env=dict(os.environ, **(env or {})))
    finally:
        os.unlink(path)


class RunnerRules(unittest.TestCase):
    def test_a_file_that_asserts_nothing_fails(self):
        r = run_test_text("""
            statement ok
            SELECT 1;
            """)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("asserts nothing", r.stdout)

    def test_require_after_a_record_is_an_error(self):
        r = run_test_text("""
            query I
            SELECT 1;
            ----
            1

            require no_such_extension_xyz
            """)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("require must come before the first record", r.stdout)

    def test_a_skip_fails_under_no_skip(self):
        r = run_test_text("""
            require no_such_extension_xyz

            query I
            SELECT 1;
            ----
            1
            """, env={"DUCKENT_NO_SKIP": "1"})
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("SKIP", r.stdout)

    def test_expected_error_text_does_not_match_the_echoed_sql(self):
        # DuckDB appends "LINE 1: SELECT nosuchcolumn_zz ..." to the message; the word only
        # appears in that echo when the message itself names something else.
        r = run_test_text("""
            statement error
            SELECT 1 +;
            ----
            SELECT 1
            """)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("error text mismatch", r.stdout)

    def test_a_mutant_that_does_not_load_exits_3(self):
        with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as m:
            m.write("CREATE OR REPLACE MACRO tree_sql_p13_pred() AS 'd > 1' OR;\n")
            mutant = m.name
        try:
            r = run_test_text("""
                query I
                SELECT 1;
                ----
                1
                """, "--mutant", mutant)
        finally:
            os.unlink(mutant)
        self.assertEqual(r.returncode, 3, r.stdout)
        self.assertIn("MUTANT DID NOT LOAD", r.stdout)


class MutantHarnessRules(unittest.TestCase):
    def test_unknown_only_id_is_refused(self):
        r = subprocess.run([sys.executable, os.path.join(ROOT, "test/run_mutants.py"), "--only", "MN99"],
                           capture_output=True, text=True, cwd=ROOT)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unknown mutant id MN99", r.stdout + r.stderr)

    def test_regen_check_refuses_a_hand_written_mutant_overriding_a_missing_macro(self):
        from importlib import util
        spec = util.spec_from_file_location("regen", os.path.join(ROOT, "test/mutants/regen.py"))
        regen = util.module_from_spec(spec); spec.loader.exec_module(regen)
        missing = regen.overridden_macros_missing_from_sql(
            "CREATE OR REPLACE MACRO tree_sql_no_such_fragment() AS 'x';\n")
        self.assertEqual(missing, ["tree_sql_no_such_fragment"])


if __name__ == "__main__":
    unittest.main()
