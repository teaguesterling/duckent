-- sql/04_dml.sql (first part; the DML compilers are added in Task 7)

-- P13: within each ROOT partition, the first row is level 0 and no row descends more than one level.
-- Returns a statement that raises when violated. MN15 mutates tree_sql_p13_pred.
CREATE OR REPLACE MACRO tree_sql_p13_pred() AS 'd > 1 OR (rn = 1 AND _level <> 0)';

CREATE OR REPLACE MACRO tree_compile_p13(rel_sql, label, has_root) AS
  'SELECT CASE WHEN count(*) > 0 THEN error(''P13 violated in tree ' || label || ': '' || count(*) || '' rows descend more than one level or start above level 0'
  || CASE WHEN has_root THEN '' ELSE '. If the relation holds more than one tree, declare ROOT' END
  || ''') END FROM (SELECT _level, _level - lag(_level, 1, -1) OVER (PARTITION BY _root ORDER BY _pre) AS d, row_number() OVER (PARTITION BY _root ORDER BY _pre) AS rn FROM ' || rel_sql || ') WHERE ' || tree_sql_p13_pred();

-- helper: the tree row and its shape, or an error
CREATE OR REPLACE MACRO tree_dml_context(verb, sch, nm) AS (
  SELECT CASE WHEN count(*) = 0 THEN error(verb || ': tree ' || sch || '.' || nm || ' not found')
              WHEN max(storage) <> 'materialized' THEN error(verb || ': tree ' || sch || '.' || nm || ' is projection-mode; DML needs storage := materialized')
              ELSE {db: current_database(), shape: tree_shape_from_catalog(current_database(), sch, nm),
                    attr: (SELECT expression FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND slot = 'ATTR'),
                    has_root: bool_or(EXISTS (SELECT 1 FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND slot = 'ROOT')),
                    tbl: 'tree_catalog.' || tree_sql_ident('t_' || sch || '_' || nm)} END
  FROM tree_catalog.trees WHERE database_name = current_database() AND schema_name = sch AND tree_name = nm);

CREATE OR REPLACE MACRO tree_compile_insert(sch, nm, source) AS (
  WITH c AS (SELECT tree_dml_context('tree_insert', sch, nm) AS x),
  p AS (SELECT x, tree_compile_projection(x.shape, source, x.attr) AS proj FROM c)
  SELECT ['BEGIN TRANSACTION',
    'CREATE TEMP TABLE __duckent_new AS ' || proj,
    'SELECT CASE WHEN count(*) > 0 THEN error(''tree_insert: ROOT values already present in ' || sch || '.' || nm || ': '' || string_agg(DISTINCT n._root::VARCHAR, '', '')) END FROM __duckent_new n JOIN tree_state.partitions p ON p.root_key = n._root::VARCHAR AND p.database_name = ' || tree_sql_lit(x.db) || ' AND p.schema_name = ' || tree_sql_lit(sch) || ' AND p.tree_name = ' || tree_sql_lit(nm),
    tree_compile_p13('__duckent_new', sch || '.' || nm, x.has_root),
    'INSERT INTO ' || x.tbl || ' SELECT * FROM __duckent_new',
    'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', _root::VARCHAR, 1, count(*), true, now() FROM __duckent_new GROUP BY _root',
    'DROP TABLE __duckent_new',
    'COMMIT'] FROM p);

CREATE OR REPLACE MACRO tree_compile_replace(sch, nm, source) AS (
  WITH c AS (SELECT tree_dml_context('tree_replace', sch, nm) AS x),
  p AS (SELECT x, tree_compile_projection(x.shape, source, x.attr) AS proj FROM c)
  SELECT ['BEGIN TRANSACTION',
    'CREATE TEMP TABLE __duckent_new AS ' || proj,
    tree_compile_p13('__duckent_new', sch || '.' || nm, x.has_root),
    'CREATE TEMP TABLE __duckent_epochs AS SELECT root_key, epoch FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT DISTINCT _root::VARCHAR FROM __duckent_new)',
    'DELETE FROM ' || x.tbl || ' WHERE _root::VARCHAR IN (SELECT root_key FROM __duckent_epochs)',
    'DELETE FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT root_key FROM __duckent_epochs)',
    'INSERT INTO ' || x.tbl || ' SELECT * FROM __duckent_new',
    'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', n._root::VARCHAR, COALESCE(e.epoch, 0) + 1, count(*), true, now() FROM __duckent_new n LEFT JOIN __duckent_epochs e ON e.root_key = n._root::VARCHAR GROUP BY n._root, e.epoch',
    'DROP TABLE __duckent_new', 'DROP TABLE __duckent_epochs',
    'COMMIT'] FROM p);

-- The predicate is evaluated over the ROOT columns only: a non-ROOT column is a binder error naming it (P21). MN17 mutates this to row surgery.
CREATE OR REPLACE MACRO tree_sql_delete_stmt(tbl, root_predicate) AS
  'DELETE FROM ' || tbl || ' WHERE _root IN (SELECT _root FROM (SELECT DISTINCT _root, _root.* FROM ' || tbl || ') WHERE ' || root_predicate || ')';

CREATE OR REPLACE MACRO tree_compile_delete(sch, nm, root_predicate) AS (
  WITH c AS (SELECT tree_dml_context('tree_delete', sch, nm) AS x)
  SELECT ['BEGIN TRANSACTION',
    'CREATE TEMP TABLE __duckent_gone AS SELECT DISTINCT _root::VARCHAR AS root_key FROM (SELECT DISTINCT _root, _root.* FROM ' || x.tbl || ') WHERE ' || root_predicate,
    tree_sql_delete_stmt(x.tbl, root_predicate),
    'DELETE FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT root_key FROM __duckent_gone)',
    'DROP TABLE __duckent_gone',
    'COMMIT'] FROM c);

-- Run the assertions and record them. P13 only for now; O assertions arrive in M3.
CREATE OR REPLACE MACRO tree_compile_check(sch, nm) AS (
  WITH c AS (SELECT tree_dml_context('tree_check', sch, nm) AS x)
  SELECT ['BEGIN TRANSACTION',
    'DELETE FROM tree_state.assertions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''assert_p13''',
    'INSERT INTO tree_state.assertions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ''assert_p13'', CASE WHEN count(*) = 0 THEN ''ok'' ELSE ''violated'' END, (SELECT max(epoch) FROM tree_state.partitions WHERE tree_name = ' || tree_sql_lit(nm) || '), count(*) || '' violating rows'' FROM (SELECT _level, _level - lag(_level, 1, -1) OVER (PARTITION BY _root ORDER BY _pre) AS d, row_number() OVER (PARTITION BY _root ORDER BY _pre) AS rn FROM ' || x.tbl || ') WHERE ' || tree_sql_p13_pred(),
    'COMMIT'] FROM c);
