-- test/mutants/MN17_row_surgery_delete.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/04_dml.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- `CASE WHEN x IS NULL` is not dead code, and neither is its twin in tree_compile_check.
-- Every statement below is pure string concatenation over the identity, so when the identity is
-- NULL each one constant-folds to NULL *before* anything reads `x` -- and 1.5.5 then prunes the
-- column that holds tree_dml_context out of the plan, so the refusal inside it is never
-- evaluated at all. The verb returns a list of NULLs and the executor runs BEGIN, nothing,
-- COMMIT. tree_compile_insert and _replace escape this only by accident: they also call
-- tree_compile_projection(x.shape, ...), which forces the context. Reading `x` in a predicate
-- that cannot fold is what makes the refusal unconditional here.
CREATE OR REPLACE MACRO tree_compile_delete(sch, nm, root_predicate) AS (
  WITH c AS (SELECT tree_dml_context('tree_delete', sch, nm) AS x)
  SELECT CASE WHEN x IS NULL THEN tree_err('tree_delete: internal: no DML context') ELSE
   ['BEGIN TRANSACTION',
    'CREATE TEMP TABLE __duckent_gone AS SELECT DISTINCT _root::VARCHAR AS root_key FROM (SELECT DISTINCT _root, _root.* FROM ' || x.tbl || ') WHERE ' || root_predicate,
    tree_sql_delete_stmt(x.tbl, root_predicate),
    'DELETE FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT root_key FROM __duckent_gone)',
    'DROP TABLE __duckent_gone',
    'COMMIT'] END FROM c);
