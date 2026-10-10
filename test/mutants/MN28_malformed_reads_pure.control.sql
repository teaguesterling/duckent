-- test/mutants/MN28_malformed_reads_pure.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/00_types.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- VOLATILE and CONSISTENT_WITHIN_QUERY are both impure here: the first differs within one query,
-- the second between queries, and a predicate that moves between queries is the same defect.
-- A MACRO reports stability NULL whatever it calls -- measured: a macro over random() and one over
-- a constant are indistinguishable in duckdb_functions() -- so its own body is resolved, ONE level
-- deep. Beyond that the answer is 'unknown', recorded rather than guessed: claiming 'pure' for a
-- body nothing resolved is the false-positive verdict, and refusing it would reject a predicate
-- that is very likely fine. Transitive resolution is the obvious extension and would turn some of
-- today's 'unknown' into 'impure'.
CREATE OR REPLACE MACRO tree_sql_purity(expr) AS (
  WITH fns AS (SELECT DISTINCT function_name, function_type, stability, macro_definition FROM duckdb_functions()),
       d AS (SELECT unnest(tree_sql_expr_functions(expr)) AS fn),
       lvl1 AS (SELECT d.fn, f.function_type AS ft, f.stability AS st, f.macro_definition AS body
                FROM d LEFT JOIN fns f ON lower(f.function_name) = d.fn),
       lvl2 AS (SELECT unnest(tree_sql_expr_functions(body)) AS fn FROM lvl1
                WHERE ft = 'macro' AND body IS NOT NULL),
       lvl2c AS (SELECT l.fn, f.function_type AS ft, f.stability AS st
                 FROM lvl2 l LEFT JOIN fns f ON lower(f.function_name) = l.fn)
  SELECT CASE
    WHEN NOT tree_sql_expr_parses(expr) THEN 'malformed'
    WHEN (SELECT count(*) FROM lvl1  WHERE st IN ('VOLATILE', 'CONSISTENT_WITHIN_QUERY')) > 0 THEN 'impure'
    WHEN (SELECT count(*) FROM lvl2c WHERE st IN ('VOLATILE', 'CONSISTENT_WITHIN_QUERY')) > 0 THEN 'impure'
    WHEN (SELECT count(*) FROM lvl2c WHERE ft = 'macro') > 0 THEN 'unknown'
    ELSE 'pure' END);
