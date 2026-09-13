-- test/mutants/MN18_abstract_open.sql
-- Abstract trees default to open attributes. Copied from sql/03_ddl.sql with
-- the attr_text default changed from
--   COALESCE((shape).semantic.attr, CASE WHEN abstract THEN '' ELSE '*' END)
-- to
--   COALESCE((shape).semantic.attr, '*')
-- so a closed abstract with no ATTR declared silently serves undeclared attributes.
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
    COALESCE((shape).semantic.attr, '*') AS attr_text,
    (spec).shape.semantic IS NOT NULL OR ((spec)."like" IS NOT NULL AND tree_shape_from_catalog(current_database(), sch, (spec)."like").semantic.type IS NOT NULL) AS has_semantic,
    'tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm) AS proj_name,
    'tree_catalog.' || tree_sql_ident('t_' || sch || '_' || nm) AS tbl_name
  FROM base
),
checked AS (
  SELECT *,
    CASE
      WHEN exists_already THEN error('tree_ddl_create: tree ' || sch || '.' || nm || ' already exists')
      WHEN like_missing THEN error('tree_ddl_create: LIKE target ' || sch || '.' || (spec)."like" || ' not found')
      WHEN abstract AND source IS NOT NULL THEN error('tree_ddl_create: a SHAPE ONLY (abstract) tree cannot have a source')
      WHEN NOT abstract AND source IS NULL THEN error('tree_ddl_create: no source given; declare abstract := true (SHAPE ONLY) or pass source')
      WHEN storage NOT IN ('materialized', 'projection') THEN error('tree_ddl_create: storage must be materialized or projection')
      WHEN (shape).level IS NULL AND (shape).parent IS NULL THEN error('tree_ddl_create: declare LEVEL or PARENT (R2)')
      WHEN (shape).level IS NULL AND (shape).key IS NULL THEN error('tree_ddl_create: PARENT basis requires KEY (the column PARENT refers to)')
      WHEN (shape).level IS NULL AND NOT (tree_sql_is_ident((shape).key) AND tree_sql_is_ident((shape).parent)) THEN error('tree_ddl_create: PARENT basis needs KEY and PARENT to be plain column names')
      WHEN NOT abstract AND storage = 'projection' AND level_basis AND (shape)."order" IS NULL THEN error('tree_ddl_create: ORDER is required for projection-mode trees (the source is not frozen)')
      WHEN NOT abstract AND order_source = 'frozen' AND NOT current_setting('preserve_insertion_order') THEN error('tree_ddl_create: ORDER is required because preserve_insertion_order is off')
      WHEN regexp_matches(attr_text, '(?i)\bAS\s+"?_') THEN error('tree_ddl_create: ATTR alias collides with the canonical prefix: ' || regexp_extract(attr_text, '(?i)\bAS\s+("?_[A-Za-z0-9_]*)', 1))
      WHEN len(list_distinct(list_transform(COALESCE((shape).semantic.pseudo, []), lambda x: (x).name))) <> len(COALESCE((shape).semantic.pseudo, [])) THEN error('tree_ddl_create: S-coherence: a pseudo-class is bound twice')
      ELSE true END AS ok,
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
