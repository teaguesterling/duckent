-- sql/04_dml.sql (first part; the DML compilers are added in Task 7)

-- P13: within each ROOT partition, the first row is level 0 and no row descends more than one level.
-- Returns a statement that raises when violated. MN15 mutates tree_sql_p13_pred.
CREATE OR REPLACE MACRO tree_sql_p13_pred() AS 'd > 1 OR (rn = 1 AND _level <> 0)';

CREATE OR REPLACE MACRO tree_compile_p13(rel_sql, label, has_root) AS
  'SELECT CASE WHEN count(*) > 0 THEN error(''P13 violated in tree ' || label || ': '' || count(*) || '' rows descend more than one level or start above level 0'
  || CASE WHEN has_root THEN '' ELSE '. If the relation holds more than one tree, declare ROOT' END
  || ''') END FROM (SELECT _level, _level - lag(_level, 1, -1) OVER (PARTITION BY _root ORDER BY _pre) AS d, row_number() OVER (PARTITION BY _root ORDER BY _pre) AS rn FROM ' || rel_sql || ') WHERE ' || tree_sql_p13_pred();
