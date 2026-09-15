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
         tree_shape_merge(CASE WHEN (spec)."like" IS NULL THEN NULL ELSE tree_shape_from_catalog(current_database(), sch, (spec)."like") END, (spec).shape) AS merged,
         (spec)."like" IS NOT NULL AND tree_shape_from_catalog(current_database(), sch, (spec)."like") IS NULL AS like_missing,
         EXISTS (SELECT 1 FROM tree_catalog.trees t WHERE t.database_name = current_database() AND t.schema_name = sch AND t.tree_name = nm) AS exists_already,
         (spec).abstract AS abstract, (spec).source AS source, (spec).storage AS storage
),
-- Macro-, map- and prefix-bound pseudo-classes become expression bodies here, before validation
-- and before anything is stored: tree_sql_pseudo_map reads (p).body only, so an unexpanded
-- binding would compile the pseudo map -- and with it the projection -- to NULL. The catalog
-- then holds the expanded body, so nothing downstream has to re-expand (and a prefix binding
-- is resolved once, against the macros that existed at create time).
expanded AS (
  SELECT * EXCLUDE (merged),
    {root: (merged).root, "order": (merged)."order", key: (merged).key, level: (merged).level, parent: (merged).parent,
     sibling_order: (merged).sibling_order, size: (merged).size, children: (merged).children, next: (merged).next,
     semantic: tree_expand_pseudo((merged).semantic)}::TREE_SHAPE AS shape
  FROM base
),
derived AS (
  SELECT *,
    (shape).level IS NOT NULL AS level_basis,
    CASE WHEN (shape).level IS NOT NULL THEN 'level' ELSE 'parent' END AS basis,
    CASE WHEN (shape).level IS NULL AND (shape).sibling_order IS NULL THEN 'sibling_free' ELSE 'full' END AS profile,
    CASE WHEN (shape).level IS NULL OR (shape)."order" IS NOT NULL THEN 'declared' ELSE 'frozen' END AS order_source,
    COALESCE((shape).semantic.attr, '*') AS attr_text,
    -- A LIKE child has an S group when it declares one or when its parent has one, whatever
    -- slot the parent filled: reading the parent's TYPE alone made an ID-only parent invisible.
    -- Every S slot counts: ELEMENT, ATTR MAP and PSEUDO are S declarations as much as TYPE is.
    -- ATTR is the one exception and must not appear below: every tree stores an S/ATTR slot
    -- ('' closed, '*' open), so tree_shape_from_catalog gives every LIKE child a non-NULL
    -- semantic.attr, and counting it would make every child S-ful -- opening the S-clause back
    -- door tree_match refuses on an S-less tree. The per-slot terms are otherwise redundant
    -- (a locally declared group is caught by the first term, an inherited one by the last), and
    -- are spelled out so that a slot added later is not silently missed here.
    (spec).shape.semantic IS NOT NULL
      OR (shape).semantic.type IS NOT NULL OR (shape).semantic.id IS NOT NULL OR (shape).semantic.classes IS NOT NULL
      OR (shape).semantic.attr_map IS NOT NULL OR (shape).semantic.element IS NOT NULL
      OR len(COALESCE((shape).semantic.pseudo, [])) > 0
      OR COALESCE((SELECT tr.has_semantic FROM tree_catalog.trees tr
                   WHERE tr.database_name = current_database() AND tr.schema_name = sch AND tr.tree_name = (spec)."like"), false) AS has_semantic,
    'tree_catalog.' || tree_sql_object_name('proj', sch, nm) AS proj_name,
    'tree_catalog.' || tree_sql_object_name('t', sch, nm) AS tbl_name
  FROM expanded
),
checked AS (
  SELECT *,
    CASE
      -- NULL in any value interpolated into a generated statement would compile that whole
      -- statement to NULL and drop it from the list, so identity and storage are checked first.
      WHEN sch IS NULL OR nm IS NULL THEN error('tree_ddl_create: schema and name are required')
      WHEN abstract IS NULL THEN error('tree_ddl_create: abstract must be true or false')
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
    {b: 'S', s: 'ELEMENT', e: (shape).semantic.element},
    {b: 'O', s: 'SIZE', e: (shape).size}, {b: 'O', s: 'CHILDREN', e: (shape).children}, {b: 'O', s: 'NEXT', e: (shape).next}
  ], lambda x: (x).e IS NOT NULL) AS rows, * FROM checked
),
-- Each statement is built as a named column so the list can fail closed: an optional
-- statement is NULL by construction, but a required one going NULL means an interpolated
-- value was NULL, and filtering it away is how a half-registered tree gets created (I3).
built AS (
  SELECT 'BEGIN TRANSACTION' AS s_begin,
   'INSERT INTO tree_catalog.trees VALUES (' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || abstract || ', '
     || COALESCE(tree_sql_lit((spec)."like"), 'NULL') || ', ' || COALESCE(tree_sql_lit(source), 'NULL') || ', ' || tree_sql_lit(basis) || ', ' || tree_sql_lit(profile) || ', '
     || tree_sql_lit(storage) || ', ' || tree_sql_lit(order_source) || ', ' || has_semantic || ', NULL)' AS s_trees,
   'INSERT INTO tree_catalog.slots VALUES ' || list_aggregate(list_transform(rows, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit((x).b) || ', ' || tree_sql_lit((x).s) || ', ' || tree_sql_lit((x).e) || ')'), 'string_agg', ', ') AS s_slots,
   tree_sql_pseudo_insert(db, sch, nm, (shape).semantic.pseudo) AS s_pseudo,
   CASE WHEN abstract THEN NULL ELSE tree_sql_shadow_check('(' || proj_sql || ')', 'tree_ddl_create') END AS s_shadow,
   CASE WHEN abstract THEN NULL ELSE tree_compile_p13('(' || proj_sql || ')', sch || '.' || nm, (shape).root IS NOT NULL) END AS s_p13,
   CASE WHEN abstract OR storage <> 'materialized' THEN NULL ELSE 'CREATE TABLE ' || tbl_name || ' AS ' || proj_sql END AS s_table,
   CASE WHEN abstract THEN NULL WHEN storage = 'materialized' THEN 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE SELECT * FROM ' || tbl_name
        ELSE 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE ' || proj_sql END AS s_macro,
   CASE WHEN abstract OR storage <> 'materialized' THEN NULL ELSE
     'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', _root::VARCHAR, 1, count(*), true, now() FROM ' || tbl_name || ' GROUP BY _root' END AS s_partitions,
   CASE WHEN abstract THEN NULL ELSE 'INSERT INTO tree_catalog.compiled VALUES (' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ''projection'', ' || tree_sql_lit(proj_name) || ', ' || tree_sql_lit(proj_sql) || ')' END AS s_compiled,
   CASE WHEN abstract THEN NULL ELSE tree_sql_attr_cols_insert(db, sch, nm, proj_name) END AS s_attr_cols,
   'COMMIT' AS s_commit
  FROM slot_rows WHERE ok
)
SELECT CASE WHEN s_begin IS NULL OR s_trees IS NULL OR s_slots IS NULL OR s_commit IS NULL
            -- plain error(), not (SELECT error(...)): an uncorrelated scalar subquery is
            -- evaluated once, eagerly, and would refuse every valid create
            THEN error('tree_ddl_create: internal: a required statement compiled to NULL')
            ELSE list_filter([s_begin, s_trees, s_slots, s_pseudo, s_shadow, s_p13, s_table, s_macro, s_partitions, s_compiled, s_attr_cols, s_commit], lambda x: x IS NOT NULL) END
FROM built);
