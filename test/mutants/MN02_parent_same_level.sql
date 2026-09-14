-- test/mutants/MN02_parent_same_level.sql
CREATE OR REPLACE MACRO tree_sql_parent_join() AS
  '__p AS (SELECT a.*, b._pre AS _parent FROM __r a ASOF LEFT JOIN __r b ON a._root = b._root AND b._level = a._level AND b._pre < a._pre), ';
