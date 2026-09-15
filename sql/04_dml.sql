-- sql/04_dml.sql (first part; the DML compilers are added in Task 7)

-- P13: within each ROOT partition, the first row is level 0 and no row descends more than one level.
-- Returns a statement that raises when violated. MN15 mutates tree_sql_p13_pred.
CREATE OR REPLACE MACRO tree_sql_p13_pred() AS 'd > 1 OR (rn = 1 AND _level <> 0)';

-- `label` lands inside a single-quoted literal of the generated statement, so its own quotes
-- are doubled; a tree named it's would otherwise compile to a syntax error.
CREATE OR REPLACE MACRO tree_compile_p13(rel_sql, label, has_root) AS
  'SELECT CASE WHEN count(*) > 0 THEN error(''P13 violated in tree ' || replace(label, '''', '''''') || ': '' || count(*) || '' rows descend more than one level or start above level 0'
  || CASE WHEN has_root THEN '' ELSE '. If the relation holds more than one tree, declare ROOT' END
  || ''') END FROM (SELECT _level, _level - lag(_level, 1, -1) OVER (PARTITION BY _root ORDER BY _pre) AS d, row_number() OVER (PARTITION BY _root ORDER BY _pre) AS rn FROM ' || rel_sql || ') WHERE ' || tree_sql_p13_pred();

-- helper: the tree row and its shape, or an error
--
-- The identity is COALESCEd into every message: a NULL schema or name makes the lookup empty,
-- so the FIRST branch is the one that fires -- and without the COALESCE its message would be
-- NULL, error(NULL) evaluates to NULL in 1.5.5, the whole context struct would be NULL, every
-- statement the verb builds from it would be NULL, and list_filter would drop them. The verb
-- would then run BEGIN ... COMMIT over nothing instead of refusing. tree_err covers the case
-- where the message goes NULL for some other reason; this covers the one we know about.
CREATE OR REPLACE MACRO tree_dml_context(verb, sch, nm) AS (
  SELECT CASE WHEN count(*) = 0 THEN tree_err(COALESCE(verb, '<NULL>') || ': tree ' || COALESCE(sch, '<NULL>') || '.' || COALESCE(nm, '<NULL>') || ' not found')
              -- an abstract tree records storage = materialized but owns no table, so without
              -- this the verb fails with a raw "table t_... does not exist" catalog error
              WHEN bool_or(is_abstract) THEN tree_err(verb || ': tree ' || sch || '.' || nm || ' is SHAPE ONLY (abstract); it has no storage')
              WHEN max(storage) <> 'materialized' THEN tree_err(verb || ': tree ' || sch || '.' || nm || ' is projection-mode; '
                                                             || CASE WHEN verb = 'tree_check' THEN 'assertions need' ELSE 'DML needs' END || ' storage := materialized')
              ELSE {db: current_database(), shape: tree_shape_from_catalog(current_database(), sch, nm),
                    order_source: max(order_source),
                    attr: (SELECT expression FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND slot = 'ATTR'),
                    has_root: bool_or(EXISTS (SELECT 1 FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND slot = 'ROOT')),
                    tbl: 'tree_catalog.' || tree_sql_object_name('t', sch, nm)} END
  FROM tree_catalog.trees WHERE database_name = current_database() AND schema_name = sch AND tree_name = nm);

-- `frozen` means _pre is the source's scan order; taking it while preserve_insertion_order
-- is off would freeze an arbitrary order into the tree. Create refuses this; so must ingest.
CREATE OR REPLACE MACRO tree_sql_frozen_guard(order_source, verb) AS
  CASE WHEN order_source <> 'frozen' THEN NULL ELSE
    'SELECT CASE WHEN NOT current_setting(''preserve_insertion_order'') THEN error(''' || verb || ': ORDER is required because preserve_insertion_order is off'') END' END;

CREATE OR REPLACE MACRO tree_compile_insert(sch, nm, source) AS (
  WITH c AS (SELECT tree_dml_context('tree_insert', sch, nm) AS x),
  p AS (SELECT x, tree_compile_projection(x.shape, source, x.attr) AS proj FROM c)
  SELECT list_filter(['BEGIN TRANSACTION',
    tree_sql_frozen_guard(x.order_source, 'tree_insert'),
    'CREATE TEMP TABLE __duckent_new AS ' || proj,
    tree_sql_shadow_check('__duckent_new', 'tree_insert'),
    'SELECT CASE WHEN count(*) > 0 THEN error(''tree_insert: ROOT values already present in ' || replace(sch || '.' || nm, '''', '''''') || ': '' || string_agg(DISTINCT n._root::VARCHAR, '', '')) END FROM __duckent_new n JOIN tree_state.partitions p ON p.root_key = n._root::VARCHAR AND p.database_name = ' || tree_sql_lit(x.db) || ' AND p.schema_name = ' || tree_sql_lit(sch) || ' AND p.tree_name = ' || tree_sql_lit(nm),
    tree_compile_p13('__duckent_new', sch || '.' || nm, x.has_root),
    -- BY NAME: the projection's column order follows the source's select list, which need
    -- not match the stored table's, and a positional INSERT misfiles same-typed columns
    'INSERT INTO ' || x.tbl || ' BY NAME SELECT * FROM __duckent_new',
    'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', _root::VARCHAR, 1, count(*), true, now() FROM __duckent_new GROUP BY _root',
    'DROP TABLE __duckent_new',
    'COMMIT'], lambda s: s IS NOT NULL) FROM p);

CREATE OR REPLACE MACRO tree_compile_replace(sch, nm, source) AS (
  WITH c AS (SELECT tree_dml_context('tree_replace', sch, nm) AS x),
  p AS (SELECT x, tree_compile_projection(x.shape, source, x.attr) AS proj FROM c)
  SELECT list_filter(['BEGIN TRANSACTION',
    tree_sql_frozen_guard(x.order_source, 'tree_replace'),
    'CREATE TEMP TABLE __duckent_new AS ' || proj,
    tree_sql_shadow_check('__duckent_new', 'tree_replace'),
    tree_compile_p13('__duckent_new', sch || '.' || nm, x.has_root),
    'CREATE TEMP TABLE __duckent_epochs AS SELECT root_key, epoch FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT DISTINCT _root::VARCHAR FROM __duckent_new)',
    'DELETE FROM ' || x.tbl || ' WHERE _root::VARCHAR IN (SELECT root_key FROM __duckent_epochs)',
    'DELETE FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT root_key FROM __duckent_epochs)',
    'INSERT INTO ' || x.tbl || ' BY NAME SELECT * FROM __duckent_new',
    'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', n._root::VARCHAR, COALESCE(e.epoch, 0) + 1, count(*), true, now() FROM __duckent_new n LEFT JOIN __duckent_epochs e ON e.root_key = n._root::VARCHAR GROUP BY n._root, e.epoch',
    'DROP TABLE __duckent_new', 'DROP TABLE __duckent_epochs',
    'COMMIT'], lambda s: s IS NOT NULL) FROM p);

-- The predicate is evaluated over the ROOT columns only: a non-ROOT column is a binder error naming it (P21). MN17 mutates this to row surgery.
CREATE OR REPLACE MACRO tree_sql_delete_stmt(tbl, root_predicate) AS
  'DELETE FROM ' || tbl || ' WHERE _root IN (SELECT _root FROM (SELECT DISTINCT _root, _root.* FROM ' || tbl || ') WHERE ' || root_predicate || ')';

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
    'CREATE TEMP TABLE __duckent_gone AS SELECT DISTINCT _root::VARCHAR AS root_key FROM (SELECT DISTINCT _root, _root.* FROM ' || x.tbl || ') WHERE ' || root_predicate,
    tree_sql_delete_stmt(x.tbl, root_predicate),
    'DELETE FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT root_key FROM __duckent_gone)',
    'DROP TABLE __duckent_gone',
    'COMMIT'] END FROM c);

-- Run the assertions and record them. P13 only for now; O assertions arrive in M3.
CREATE OR REPLACE MACRO tree_compile_check(sch, nm) AS (
  WITH c AS (SELECT tree_dml_context('tree_check', sch, nm) AS x)
  -- see tree_compile_delete on why the context is read in a predicate
  SELECT CASE WHEN x IS NULL THEN tree_err('tree_check: internal: no DML context') ELSE
   ['BEGIN TRANSACTION',
    'DELETE FROM tree_state.assertions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''assert_p13''',
    'INSERT INTO tree_state.assertions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ''assert_p13'', CASE WHEN count(*) = 0 THEN ''ok'' ELSE ''violated'' END, (SELECT max(epoch) FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || '), count(*) || '' violating rows'' FROM (SELECT _level, _level - lag(_level, 1, -1) OVER (PARTITION BY _root ORDER BY _pre) AS d, row_number() OVER (PARTITION BY _root ORDER BY _pre) AS rn FROM ' || x.tbl || ') WHERE ' || tree_sql_p13_pred(),
    'COMMIT'] END FROM c);
