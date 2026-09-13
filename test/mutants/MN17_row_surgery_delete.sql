-- test/mutants/MN17_row_surgery_delete.sql
CREATE OR REPLACE MACRO tree_sql_delete_stmt(tbl, root_predicate) AS
  'DELETE FROM ' || tbl || ' WHERE ' || root_predicate;
