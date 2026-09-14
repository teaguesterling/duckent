-- test/mutants/MN17_row_surgery_delete.sql
-- The predicate should be evaluated over the ROOT columns only (P21): a non-ROOT
-- column reference must be a binder error naming it. This mutant applies
-- root_predicate directly to the table instead, in both the gone-roots
-- computation and the delete statement itself -- row surgery. Overriding
-- tree_sql_delete_stmt alone cannot model this: tree_compile_delete's
-- __duckent_gone computation already restricts root_predicate to ROOT columns
-- and runs before tree_sql_delete_stmt, so it silently shadows a fragment-only
-- mutation. Copied from sql/04_dml.sql with both statements changed.
CREATE OR REPLACE MACRO tree_compile_delete(sch, nm, root_predicate) AS (
  WITH c AS (SELECT tree_dml_context('tree_delete', sch, nm) AS x)
  SELECT ['BEGIN TRANSACTION',
    'CREATE TEMP TABLE __duckent_gone AS SELECT DISTINCT _root::VARCHAR AS root_key FROM ' || x.tbl || ' WHERE ' || root_predicate,
    'DELETE FROM ' || x.tbl || ' WHERE ' || root_predicate,
    'DELETE FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT root_key FROM __duckent_gone)',
    'DROP TABLE __duckent_gone',
    'COMMIT'] FROM c);
