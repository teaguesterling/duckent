-- sql/03_ddl.sql

-- Rebuild a TREE_SHAPE from catalog rows. NULL when the tree does not exist.
CREATE OR REPLACE MACRO tree_shape_from_catalog(db, sch, nm) AS (
  SELECT CASE WHEN count(*) = 0 THEN NULL ELSE {
    root: max(expression) FILTER (WHERE slot = 'ROOT'),
    "order": max(expression) FILTER (WHERE slot = 'ORDER'),
    key: max(expression) FILTER (WHERE slot = 'KEY'),
    level: max(expression) FILTER (WHERE slot = 'LEVEL'),
    parent: max(expression) FILTER (WHERE slot = 'PARENT'),
    sibling_order: max(expression) FILTER (WHERE slot = 'SIBLING_ORDER'),
    size: max(expression) FILTER (WHERE slot = 'SIZE'),
    children: max(expression) FILTER (WHERE slot = 'CHILDREN'),
    next: max(expression) FILTER (WHERE slot = 'NEXT'),
    semantic: {
      type: max(expression) FILTER (WHERE slot = 'TYPE'),
      id: max(expression) FILTER (WHERE slot = 'ID'),
      classes: max(expression) FILTER (WHERE slot = 'CLASSES'),
      attr: max(expression) FILTER (WHERE slot = 'ATTR'),
      attr_map: max(expression) FILTER (WHERE slot = 'ATTR_MAP'),
      pseudo: (SELECT list({name: name, body: body, prefix: NULL::VARCHAR} ORDER BY name)
               FROM tree_catalog.pseudo_classes p WHERE p.database_name = db AND p.schema_name = sch AND p.tree_name = nm)
    }::TREE_SEMANTIC }::TREE_SHAPE END
  FROM tree_catalog.slots WHERE database_name = db AND schema_name = sch AND tree_name = nm);

-- Child fields win; pseudo lists union with the child shadowing by name.
CREATE OR REPLACE MACRO tree_shape_merge(p, c) AS
  CASE WHEN p IS NULL THEN c ELSE {
    root: COALESCE((c).root, (p).root), "order": COALESCE((c)."order", (p)."order"), key: COALESCE((c).key, (p).key),
    level: COALESCE((c).level, (p).level), parent: COALESCE((c).parent, (p).parent), sibling_order: COALESCE((c).sibling_order, (p).sibling_order),
    size: COALESCE((c).size, (p).size), children: COALESCE((c).children, (p).children), next: COALESCE((c).next, (p).next),
    semantic: {
      type: COALESCE((c).semantic.type, (p).semantic.type), id: COALESCE((c).semantic.id, (p).semantic.id),
      classes: COALESCE((c).semantic.classes, (p).semantic.classes), attr: COALESCE((c).semantic.attr, (p).semantic.attr),
      attr_map: COALESCE((c).semantic.attr_map, (p).semantic.attr_map),
      pseudo: list_concat(
        list_filter(COALESCE((p).semantic.pseudo, []), lambda x: NOT list_contains(list_transform(COALESCE((c).semantic.pseudo, []), lambda y: (y).name), (x).name)),
        COALESCE((c).semantic.pseudo, []))
    }::TREE_SEMANTIC }::TREE_SHAPE END;

CREATE OR REPLACE MACRO tree_compile_create(sch, nm, spec) AS (
WITH base AS (
  SELECT current_database() AS db,
         tree_shape_merge(CASE WHEN (spec)."like" IS NULL THEN NULL ELSE tree_shape_from_catalog(current_database(), sch, (spec)."like") END, (spec).shape) AS shape,
         (spec)."like" IS NOT NULL AND tree_shape_from_catalog(current_database(), sch, (spec)."like") IS NULL AS like_missing,
         EXISTS (SELECT 1 FROM tree_catalog.trees t WHERE t.database_name = current_database() AND t.schema_name = sch AND t.tree_name = nm) AS exists_already,
         (spec).abstract AS abstract, (spec).source AS source, (spec).storage AS storage
),
derived AS (
  SELECT *,
    (shape).level IS NOT NULL AS level_basis,
    CASE WHEN (shape).level IS NOT NULL THEN 'level' ELSE 'parent' END AS basis,
    CASE WHEN (shape).level IS NULL AND (shape).sibling_order IS NULL THEN 'sibling_free' ELSE 'full' END AS profile,
    CASE WHEN (shape).level IS NULL OR (shape)."order" IS NOT NULL THEN 'declared' ELSE 'frozen' END AS order_source,
    COALESCE((shape).semantic.attr, CASE WHEN abstract THEN '' ELSE '*' END) AS attr_text,
    (spec).shape.semantic IS NOT NULL OR ((spec)."like" IS NOT NULL AND tree_shape_from_catalog(current_database(), sch, (spec)."like").semantic.type IS NOT NULL) AS has_semantic,
    'tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm) AS proj_name,
    'tree_catalog.' || tree_sql_ident('t_' || sch || '_' || nm) AS tbl_name
  FROM base
),
checked AS (
  SELECT *,
    CASE
      -- NULL in any value interpolated into a generated statement would compile that whole
      -- statement to NULL and drop it from the list, so identity and storage are checked first.
      WHEN sch IS NULL OR nm IS NULL THEN error('tree_ddl_create: schema and name are required')
      WHEN exists_already THEN error('tree_ddl_create: tree ' || sch || '.' || nm || ' already exists')
      WHEN like_missing THEN error('tree_ddl_create: LIKE target ' || sch || '.' || (spec)."like" || ' not found')
      WHEN abstract AND source IS NOT NULL THEN error('tree_ddl_create: a SHAPE ONLY (abstract) tree cannot have a source')
      WHEN NOT abstract AND source IS NULL THEN error('tree_ddl_create: no source given; declare abstract := true (SHAPE ONLY) or pass source')
      WHEN storage IS NULL OR storage NOT IN ('materialized', 'projection') THEN error('tree_ddl_create: storage must be materialized or projection')
      WHEN (shape).level IS NULL AND (shape).parent IS NULL THEN error('tree_ddl_create: declare LEVEL or PARENT (R2)')
      WHEN (shape).level IS NULL AND (shape).key IS NULL THEN error('tree_ddl_create: PARENT basis requires KEY (the column PARENT refers to)')
      WHEN (shape).level IS NULL AND NOT (tree_sql_is_ident((shape).key) AND tree_sql_is_ident((shape).parent)) THEN error('tree_ddl_create: PARENT basis needs KEY and PARENT to be plain column names')
      WHEN NOT abstract AND storage = 'projection' AND level_basis AND (shape)."order" IS NULL THEN error('tree_ddl_create: ORDER is required for projection-mode trees (the source is not frozen)')
      WHEN NOT abstract AND order_source = 'frozen' AND NOT current_setting('preserve_insertion_order') THEN error('tree_ddl_create: ORDER is required because preserve_insertion_order is off')
      ELSE tree_sql_check_semantic((shape).semantic, attr_text, 'tree_ddl_create') END AS ok,
    CASE WHEN abstract THEN NULL ELSE tree_compile_projection(shape, source, attr_text) END AS proj_sql
  FROM derived
),
slot_rows AS (
  SELECT list_filter([
    {b: 'R', s: 'ROOT', e: (shape).root}, {b: 'R', s: 'ORDER', e: (shape)."order"}, {b: 'R', s: 'KEY', e: (shape).key},
    {b: 'R', s: 'LEVEL', e: (shape).level}, {b: CASE WHEN level_basis THEN 'O' ELSE 'R' END, s: 'PARENT', e: (shape).parent},
    {b: 'R', s: 'SIBLING_ORDER', e: (shape).sibling_order},
    {b: 'S', s: 'TYPE', e: (shape).semantic.type}, {b: 'S', s: 'ID', e: (shape).semantic.id}, {b: 'S', s: 'CLASSES', e: (shape).semantic.classes},
    {b: 'S', s: 'ATTR', e: attr_text}, {b: 'S', s: 'ATTR_MAP', e: (shape).semantic.attr_map},
    {b: 'O', s: 'SIZE', e: (shape).size}, {b: 'O', s: 'CHILDREN', e: (shape).children}, {b: 'O', s: 'NEXT', e: (shape).next}
  ], lambda x: (x).e IS NOT NULL) AS rows, * FROM checked
)
SELECT list_filter(
  ['BEGIN TRANSACTION',
   'INSERT INTO tree_catalog.trees VALUES (' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || abstract || ', '
     || COALESCE(tree_sql_lit((spec)."like"), 'NULL') || ', ' || COALESCE(tree_sql_lit(source), 'NULL') || ', ' || tree_sql_lit(basis) || ', ' || tree_sql_lit(profile) || ', '
     || tree_sql_lit(storage) || ', ' || tree_sql_lit(order_source) || ', ' || has_semantic || ', NULL)',
   'INSERT INTO tree_catalog.slots VALUES ' || list_aggregate(list_transform(rows, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit((x).b) || ', ' || tree_sql_lit((x).s) || ', ' || tree_sql_lit((x).e) || ')'), 'string_agg', ', '),
   CASE WHEN len(COALESCE((shape).semantic.pseudo, [])) = 0 THEN NULL ELSE
   'INSERT INTO tree_catalog.pseudo_classes VALUES ' || list_aggregate(list_transform((shape).semantic.pseudo, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit((x).name) || ', ''expression'', ' || tree_sql_lit((x).body) || ', ''local'', ''unknown'')'), 'string_agg', ', ') END,
   CASE WHEN abstract THEN NULL ELSE tree_compile_p13('(' || proj_sql || ')', sch || '.' || nm, (shape).root IS NOT NULL) END,
   CASE WHEN abstract OR storage <> 'materialized' THEN NULL ELSE 'CREATE TABLE ' || tbl_name || ' AS ' || proj_sql END,
   CASE WHEN abstract THEN NULL WHEN storage = 'materialized' THEN 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE SELECT * FROM ' || tbl_name
        ELSE 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE ' || proj_sql END,
   CASE WHEN abstract OR storage <> 'materialized' THEN NULL ELSE
     'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', _root::VARCHAR, 1, count(*), true, now() FROM ' || tbl_name || ' GROUP BY _root' END,
   CASE WHEN abstract THEN NULL ELSE 'INSERT INTO tree_catalog.compiled VALUES (' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ''projection'', ' || tree_sql_lit(proj_name) || ', ' || tree_sql_lit(proj_sql) || ')' END,
   'COMMIT'], lambda x: x IS NOT NULL)
FROM slot_rows WHERE ok);

CREATE OR REPLACE MACRO tree_compile_drop(sch, nm) AS (
  SELECT ['BEGIN TRANSACTION',
    'DELETE FROM tree_catalog.trees WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.slots WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.pseudo_classes WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.compiled WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_state.partitions WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_state.assertions WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DROP MACRO TABLE IF EXISTS tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm),
    'DROP TABLE IF EXISTS tree_catalog.' || tree_sql_ident('t_' || sch || '_' || nm),
    'COMMIT']);

-- Replace the SEMANTIC group and rebuild the projection (and storage, when materialized).
-- Two guards keep alter from being a back door: the S validation ladder is the same fragment
-- create uses (so a closed tree stays closed and the `_` prefix stays reserved), and a
-- materialized tree whose partitions no longer all come from source_sql refuses outright,
-- because rebuilding with CREATE OR REPLACE TABLE would drop what tree_insert added.
CREATE OR REPLACE MACRO tree_compile_alter(sch, nm, semantic) AS (
WITH t AS (
  SELECT current_database() AS db, tr.storage, tr.source_sql, tr.is_abstract,
         tree_shape_from_catalog(current_database(), sch, nm) AS old_shape
  FROM tree_catalog.trees tr WHERE tr.database_name = current_database() AND tr.schema_name = sch AND tr.tree_name = nm
),
n AS (
  SELECT *,
    {root: (old_shape).root, "order": (old_shape)."order", key: (old_shape).key, level: (old_shape).level, parent: (old_shape).parent, sibling_order: (old_shape).sibling_order,
     size: (old_shape).size, children: (old_shape).children, next: (old_shape).next, semantic: semantic}::TREE_SHAPE AS shape,
    COALESCE((semantic).attr, (old_shape).semantic.attr, CASE WHEN is_abstract THEN '' ELSE '*' END) AS attr_text,
    'tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm) AS proj_name,
    'tree_catalog.' || tree_sql_ident('t_' || sch || '_' || nm) AS tbl_name
  FROM t
),
c AS (
  SELECT *, CASE WHEN is_abstract THEN NULL ELSE tree_compile_projection(shape, source_sql, attr_text) END AS proj_sql,
    tree_sql_check_semantic(semantic, attr_text, 'tree_ddl_alter') AS ok,
    list_filter([
      {b: 'S', s: 'TYPE', e: (semantic).type}, {b: 'S', s: 'ID', e: (semantic).id}, {b: 'S', s: 'CLASSES', e: (semantic).classes},
      {b: 'S', s: 'ATTR', e: attr_text}, {b: 'S', s: 'ATTR_MAP', e: (semantic).attr_map}], lambda x: (x).e IS NOT NULL) AS rows
  FROM n
)
SELECT CASE WHEN semantic IS NULL THEN error('tree_ddl_alter: semantic is NULL; nothing to alter')
  WHEN (SELECT count(*) FROM t) = 0 THEN error('tree_ddl_alter: tree ' || sch || '.' || nm || ' not found') ELSE
  list_filter(['BEGIN TRANSACTION',
   CASE WHEN is_abstract OR storage <> 'materialized' THEN NULL ELSE
   'SELECT CASE WHEN count(*) > 0 THEN error(''tree_ddl_alter: tree ' || replace(sch || '.' || nm, '''', '''''')
     || ' holds '' || count(*) || '' partition(s) ingested after create; altering would drop them. tree_delete them or re-ingest with tree_replace after altering'') END'
     || ' FROM tree_state.partitions p WHERE p.database_name = ' || tree_sql_lit(db) || ' AND p.schema_name = ' || tree_sql_lit(sch) || ' AND p.tree_name = ' || tree_sql_lit(nm)
     || ' AND p.root_key NOT IN (SELECT DISTINCT _root::VARCHAR FROM (' || proj_sql || '))' END,
   'DELETE FROM tree_catalog.slots WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND block = ''S''',
   'DELETE FROM tree_catalog.pseudo_classes WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
   'INSERT INTO tree_catalog.slots VALUES ' || list_aggregate(list_transform(rows, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit((x).b) || ', ' || tree_sql_lit((x).s) || ', ' || tree_sql_lit((x).e) || ')'), 'string_agg', ', '),
   CASE WHEN len(COALESCE((semantic).pseudo, [])) = 0 THEN NULL ELSE
   'INSERT INTO tree_catalog.pseudo_classes VALUES ' || list_aggregate(list_transform((semantic).pseudo, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit((x).name) || ', ''expression'', ' || tree_sql_lit((x).body) || ', ''local'', ''unknown'')'), 'string_agg', ', ') END,
   'UPDATE tree_catalog.trees SET has_semantic = true WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
   CASE WHEN is_abstract OR storage <> 'materialized' THEN NULL ELSE 'CREATE OR REPLACE TABLE ' || tbl_name || ' AS ' || proj_sql END,
   CASE WHEN is_abstract THEN NULL WHEN storage = 'materialized' THEN 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE SELECT * FROM ' || tbl_name
        ELSE 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE ' || proj_sql END,
   CASE WHEN is_abstract THEN NULL ELSE 'UPDATE tree_catalog.compiled SET sql_text = ' || tree_sql_lit(proj_sql) || ' WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''projection''' END,
   'COMMIT'], lambda x: x IS NOT NULL) END
FROM c WHERE ok);

-- The canonical projection of a registered tree. query() folds the concatenated literal to a constant.
CREATE OR REPLACE MACRO tree_project(sch, nm) AS TABLE
  FROM query('FROM tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm) || '()');

-- Ad hoc: a shape applied to a bare source, no registration. Open attributes, as for any concrete tree.
CREATE OR REPLACE MACRO tree_apply(shape, source) AS TABLE
  FROM query(tree_compile_projection(shape, source, '*'));

-- Classes are data: enumerate them per tree.
-- 1.5.5 note: `SELECT unnest(_classes) ... GROUP BY ALL` fails ("Cannot group on an
-- UNNEST or UNLIST clause") because DuckDB won't group on an UNNEST expression in the
-- select list. Unnesting in the FROM clause instead (a lateral UNNEST(...) AS u(class))
-- produces a plain column that GROUP BY ALL can group on; the compiled result is the
-- same set of (class, row_count) pairs the brief's version intended.
CREATE OR REPLACE MACRO tree_catalog_classes(sch, nm) AS TABLE
  SELECT class, count(*) AS row_count FROM tree_project(sch, nm), UNNEST(_classes) AS u(class) WHERE _classes IS NOT NULL GROUP BY ALL ORDER BY class;
