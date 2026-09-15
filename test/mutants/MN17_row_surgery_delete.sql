-- test/mutants/MN17_row_surgery_delete.sql
-- The predicate should be evaluated over the ROOT columns only (P21): a non-ROOT
-- column reference must be a binder error naming it. This mutant applies
-- root_predicate directly to the table instead, in both the gone-roots
-- computation and the delete statement itself -- row surgery. Overriding
-- tree_sql_delete_stmt alone cannot model this: tree_compile_delete's
-- __duckent_gone computation already restricts root_predicate to ROOT columns
-- and runs before tree_sql_delete_stmt, so it silently shadows a fragment-only
-- mutation. Copied from sql/04_dml.sql with both statements changed.
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
--
-- What the arm SAYS, though, is a backstop and not the tested path. tree_dml_context refuses on
-- its own account -- tree not found, abstract, projection-mode -- and each of those messages
-- COALESCEs the identity, so it raises rather than returning NULL; that is the message 12_dml
-- pins, and it is the message a caller sees. `x IS NULL` therefore fires only if the context
-- macro ever returns NULL without raising, which nothing here can currently make it do. It says
-- "internal" because reaching it is a duckent bug, not a user error.
CREATE OR REPLACE MACRO tree_compile_delete(sch, nm, root_predicate) AS (
  WITH c AS (SELECT tree_dml_context('tree_delete', sch, nm) AS x)
  SELECT CASE WHEN x IS NULL THEN tree_err('tree_delete: internal: no DML context') ELSE
   ['BEGIN TRANSACTION',
    -- the mutation, half one: the gone-roots computation reads the table directly
    'CREATE TEMP TABLE __duckent_gone AS SELECT DISTINCT _root::VARCHAR AS root_key FROM ' || x.tbl || ' WHERE ' || root_predicate,
    -- the mutation, half two: and so does the DELETE -- row surgery
    'DELETE FROM ' || x.tbl || ' WHERE ' || root_predicate,
    'DELETE FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT root_key FROM __duckent_gone)',
    'DROP TABLE __duckent_gone',
    'COMMIT'] END FROM c);
