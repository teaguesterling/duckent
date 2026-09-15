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
      element: max(expression) FILTER (WHERE slot = 'ELEMENT'),
      pseudo_args: max(expression) FILTER (WHERE slot = 'PSEUDO_ARGS'),
      -- kind = 'macro' rows store body as 'macro_name(args)' (tree_sql_pseudo_insert), so both
      -- are recoverable by parsing instead of dropped: without macro, a LIKE child's shared-tier
      -- scan cannot recognize that an inherited entry already claims a catalog macro (the
      -- identity exclusion in tree_expand_pseudo needs (x).macro), and re-binds it a second time
      -- under a different derived name. origin is carried back as a provenance-only prefix
      -- marker, so a LIKE child re-inserting this entry (tree_sql_pseudo_insert) records the
      -- right origin instead of flattening every inherited row to 'local'. tree_shared_pseudo_prefix()
      -- specifically reuses tree_expand_pseudo's own shared-tier marker; any other non-NULL value
      -- just needs to be distinct from it so the origin CASE falls through to 'prefix'.
      pseudo: (SELECT list({name: name, body: body,
                            macro: CASE WHEN kind = 'macro' THEN split_part(body, '(', 1) END,
                            args: CASE WHEN kind = 'macro' THEN NULLIF(regexp_extract(body, '^[^(]*\((.*)\)$', 1), '') END,
                            prefix: CASE origin WHEN 'shared' THEN tree_shared_pseudo_prefix() WHEN 'prefix' THEN 'prefix' ELSE NULL END} ORDER BY name)
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
      element: COALESCE((c).semantic.element, (p).semantic.element),
      pseudo_args: COALESCE((c).semantic.pseudo_args, (p).semantic.pseudo_args),
      pseudo: list_concat(
        list_filter(COALESCE((p).semantic.pseudo, []), lambda x: NOT list_contains(list_transform(COALESCE((c).semantic.pseudo, []), lambda y: (y).name), (x).name)),
        COALESCE((c).semantic.pseudo, []))
    }::TREE_SEMANTIC }::TREE_SHAPE END;

-- The pseudo_classes rows for an already expanded pseudo list, shared by create and alter so the
-- two cannot record a binding differently. NULL when there is nothing to insert (the caller's
-- statement list drops NULLs). kind and origin record how the body was bound: macro when a macro
-- name was named, prefix when the entry came from a prefix binding, shared when it came from the
-- sel_* shared tier. tree_expand_pseudo marks every prefix-derived entry's `prefix` field with
-- the literal prefix that produced it (or, for the shared tier specifically, with 'sel_' -- its
-- own marker); a NULL prefix means the entry was bound locally (or, for a LIKE-inherited
-- expression/macro row, was already local at the parent). A prefix of exactly 'sel_' is
-- ambiguous on its own: it also marks the case where the tree itself declared an explicit
-- {prefix: 'sel_'} binding (a legitimate, if unusual, prefix form). `explicit_sel_prefix` --
-- computed by the caller from the tree's own unexpanded PSEUDO declaration, never from a
-- merged/inherited one -- breaks the tie: shared only when the tree did not itself ask for that
-- literal prefix. purity is not computed yet.
CREATE OR REPLACE MACRO tree_sql_pseudo_insert(db, sch, nm, pseudo, explicit_sel_prefix) AS
  CASE WHEN len(COALESCE(pseudo, [])) = 0 THEN NULL ELSE
  'INSERT INTO tree_catalog.pseudo_classes VALUES ' || list_aggregate(list_transform(pseudo, lambda x:
      '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit((x).name) || ', '
      || CASE WHEN (x).macro IS NULL THEN '''expression''' ELSE '''macro''' END || ', ' || tree_sql_lit((x).body) || ', '
      || CASE WHEN (x).prefix IS NULL THEN '''local'''
              WHEN (x).prefix = tree_shared_pseudo_prefix() AND NOT explicit_sel_prefix THEN '''shared'''
              ELSE '''prefix''' END || ', ''unknown'')'), 'string_agg', ', ') END;

-- The attribute_columns artifact: the projection's non-canonical column names, in projection
-- order, as a JSON list. Recorded rather than recomputed because the front-ends (and the CSS
-- lowering M2 adds) need to know which bare names are attributes without describing the
-- relation on every query. The projection macro is described, not the source, so it is right
-- for both storage modes -- a materialized tree's macro selects from its table.
-- 1.5.5 notes: DESCRIBE takes a statement, not a table-function call ("DESCRIBE proj()" is a
-- parser error, "DESCRIBE SELECT * FROM proj()" is not), and its output has no column_index,
-- so projection order is recovered with row_number() OVER () over the describe rows.
CREATE OR REPLACE MACRO tree_sql_attr_cols_insert(db, sch, nm, proj_name) AS
  'INSERT INTO tree_catalog.compiled SELECT ' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm)
  || ', ''attribute_columns'', '''', to_json(COALESCE(list(column_name ORDER BY i), []))'
  || ' FROM (SELECT column_name, row_number() OVER () AS i FROM (DESCRIBE SELECT * FROM ' || proj_name || '()))'
  || ' WHERE column_name NOT LIKE ''\_%'' ESCAPE ''\''';

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
     semantic: tree_expand_pseudo((merged).semantic)}::TREE_SHAPE AS shape,
    -- Tested against this create's own declared PSEUDO, never the LIKE-merged one: a parent's
    -- already-resolved shared/prefix rows round-trip with a provenance marker of their own
    -- (tree_shape_from_catalog), and that marker must never be mistaken for a fresh explicit
    -- declaration by this tree.
    len(list_filter(COALESCE((spec).shape.semantic.pseudo, []), lambda p: (p).prefix = tree_shared_pseudo_prefix())) > 0 AS explicit_sel_prefix
  FROM base
),
derived AS (
  SELECT *,
    (shape).level IS NOT NULL AS level_basis,
    CASE WHEN (shape).level IS NOT NULL THEN 'level' ELSE 'parent' END AS basis,
    CASE WHEN (shape).level IS NULL AND (shape).sibling_order IS NULL THEN 'sibling_free' ELSE 'full' END AS profile,
    CASE WHEN (shape).level IS NULL OR (shape)."order" IS NOT NULL THEN 'declared' ELSE 'frozen' END AS order_source,
    COALESCE((shape).semantic.attr, CASE WHEN abstract THEN '' ELSE '*' END) AS attr_text,
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
      OR len(COALESCE((shape).semantic.pseudo, [])) > 0 OR (shape).semantic.pseudo_args IS NOT NULL
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
    {b: 'S', s: 'ELEMENT', e: (shape).semantic.element}, {b: 'S', s: 'PSEUDO_ARGS', e: (shape).semantic.pseudo_args},
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
   tree_sql_pseudo_insert(db, sch, nm, (shape).semantic.pseudo, explicit_sel_prefix) AS s_pseudo,
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

CREATE OR REPLACE MACRO tree_compile_drop(sch, nm) AS (
  SELECT ['BEGIN TRANSACTION',
    'DELETE FROM tree_catalog.trees WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.slots WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.pseudo_classes WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.compiled WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_state.partitions WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_state.assertions WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DROP MACRO TABLE IF EXISTS tree_catalog.' || tree_sql_object_name('proj', sch, nm),
    'DROP TABLE IF EXISTS tree_catalog.' || tree_sql_object_name('t', sch, nm),
    'COMMIT']);

-- Replace the SEMANTIC group and rebuild the projection (and storage, when materialized).
-- Alter changes S only, never data. Three guards keep it from being a back door: the S
-- validation ladder is the same fragment create uses (so a closed tree stays closed and the
-- `_` prefix stays reserved); a materialized tree whose partitions no longer all come from
-- source_sql refuses outright, because rebuilding with CREATE OR REPLACE TABLE would drop
-- what tree_insert added (C1); and any other drift between the source and the stored
-- partitions -- a root the source gained, or a root whose row count changed -- refuses too,
-- because the rebuild would silently ingest or discard rows as a side effect of an S change.
-- The same P13 and shadow checks create runs are emitted before the table is rebuilt.
CREATE OR REPLACE MACRO tree_compile_alter(sch, nm, semantic) AS (
WITH t AS (
  SELECT current_database() AS db, tr.storage, tr.source_sql, tr.is_abstract,
         tree_shape_from_catalog(current_database(), sch, nm) AS old_shape
  FROM tree_catalog.trees tr WHERE tr.database_name = current_database() AND tr.schema_name = sch AND tr.tree_name = nm
),
-- Same expansion create does, for the same reason: the stored body and the compiled pseudo
-- map are expression text, never a macro name (00_types.sql, tree_expand_pseudo). Tested
-- against this alter's own `semantic` argument (never `sem`, its expansion): an explicit
-- {prefix: 'sel_'} declaration is what this flag means, not the shared tier's own marker.
ex AS (SELECT *, tree_expand_pseudo(semantic) AS sem,
              len(list_filter(COALESCE((semantic).pseudo, []), lambda p: (p).prefix = tree_shared_pseudo_prefix())) > 0 AS explicit_sel_prefix
       FROM t),
n AS (
  SELECT *,
    {root: (old_shape).root, "order": (old_shape)."order", key: (old_shape).key, level: (old_shape).level, parent: (old_shape).parent, sibling_order: (old_shape).sibling_order,
     size: (old_shape).size, children: (old_shape).children, next: (old_shape).next, semantic: sem}::TREE_SHAPE AS shape,
    COALESCE((sem).attr, (old_shape).semantic.attr, CASE WHEN is_abstract THEN '' ELSE '*' END) AS attr_text,
    'tree_catalog.' || tree_sql_object_name('proj', sch, nm) AS proj_name,
    'tree_catalog.' || tree_sql_object_name('t', sch, nm) AS tbl_name
  FROM ex
),
c AS (
  SELECT *, CASE WHEN is_abstract THEN NULL ELSE tree_compile_projection(shape, source_sql, attr_text) END AS proj_sql,
    tree_sql_check_semantic(sem, attr_text, 'tree_ddl_alter') AS ok,
    list_filter([
      {b: 'S', s: 'TYPE', e: (sem).type}, {b: 'S', s: 'ID', e: (sem).id}, {b: 'S', s: 'CLASSES', e: (sem).classes},
      {b: 'S', s: 'ATTR', e: attr_text}, {b: 'S', s: 'ATTR_MAP', e: (sem).attr_map},
      {b: 'S', s: 'ELEMENT', e: (sem).element}, {b: 'S', s: 'PSEUDO_ARGS', e: (sem).pseudo_args}], lambda x: (x).e IS NOT NULL) AS rows
  FROM n
)
SELECT CASE WHEN semantic IS NULL THEN error('tree_ddl_alter: semantic is NULL; nothing to alter')
  -- evaluated outside FROM c: when the tree does not exist c has no rows, and a compiler
  -- that returns NULL instead of refusing hands the executor nothing to run
  WHEN NOT EXISTS (SELECT 1 FROM t) THEN error('tree_ddl_alter: tree ' || sch || '.' || nm || ' not found') ELSE
  (SELECT list_filter(['BEGIN TRANSACTION',
   CASE WHEN is_abstract OR storage <> 'materialized' THEN NULL ELSE
   'SELECT CASE WHEN count(*) > 0 THEN error(''tree_ddl_alter: tree ' || replace(sch || '.' || nm, '''', '''''')
     || ' holds '' || count(*) || '' partition(s) ingested after create; altering would drop them. tree_delete them or re-ingest with tree_replace after altering'') END'
     || ' FROM tree_state.partitions p WHERE p.database_name = ' || tree_sql_lit(db) || ' AND p.schema_name = ' || tree_sql_lit(sch) || ' AND p.tree_name = ' || tree_sql_lit(nm)
     || ' AND p.root_key NOT IN (SELECT DISTINCT _root::VARCHAR FROM (' || proj_sql || '))' END,
   CASE WHEN is_abstract OR storage <> 'materialized' THEN NULL ELSE
   'SELECT CASE WHEN count(*) > 0 THEN error(''tree_ddl_alter: source has drifted from the stored partitions ('' || string_agg(COALESCE(s.root_key, p.root_key), '', '') || ''); tree_replace or tree_delete first'') END'
     || ' FROM (SELECT _root::VARCHAR AS root_key, count(*) AS n FROM (' || proj_sql || ') GROUP BY _root) s'
     || ' FULL OUTER JOIN (SELECT root_key, row_count FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(db)
     || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ') p ON s.root_key = p.root_key'
     || ' WHERE s.root_key IS NULL OR p.root_key IS NULL OR s.n <> p.row_count' END,
   CASE WHEN is_abstract THEN NULL ELSE tree_sql_shadow_check('(' || proj_sql || ')', 'tree_ddl_alter') END,
   CASE WHEN is_abstract THEN NULL ELSE tree_compile_p13('(' || proj_sql || ')', sch || '.' || nm, (old_shape).root IS NOT NULL) END,
   'DELETE FROM tree_catalog.slots WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND block = ''S''',
   'DELETE FROM tree_catalog.pseudo_classes WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
   'INSERT INTO tree_catalog.slots VALUES ' || list_aggregate(list_transform(rows, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit((x).b) || ', ' || tree_sql_lit((x).s) || ', ' || tree_sql_lit((x).e) || ')'), 'string_agg', ', '),
   tree_sql_pseudo_insert(db, sch, nm, (sem).pseudo, explicit_sel_prefix),
   'UPDATE tree_catalog.trees SET has_semantic = true WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
   CASE WHEN is_abstract OR storage <> 'materialized' THEN NULL ELSE 'CREATE OR REPLACE TABLE ' || tbl_name || ' AS ' || proj_sql END,
   CASE WHEN is_abstract THEN NULL WHEN storage = 'materialized' THEN 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE SELECT * FROM ' || tbl_name
        ELSE 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE ' || proj_sql END,
   CASE WHEN is_abstract THEN NULL ELSE 'UPDATE tree_catalog.compiled SET sql_text = ' || tree_sql_lit(proj_sql) || ' WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''projection''' END,
   -- deleted and re-inserted rather than updated: the new column list is computed by describing
   -- the rebuilt projection, which an UPDATE ... SET sql_text = (subquery) cannot do portably
   CASE WHEN is_abstract THEN NULL ELSE 'DELETE FROM tree_catalog.compiled WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''attribute_columns''' END,
   CASE WHEN is_abstract THEN NULL ELSE tree_sql_attr_cols_insert(db, sch, nm, proj_name) END,
   'COMMIT'], lambda x: x IS NOT NULL) FROM c WHERE ok) END);

-- The canonical projection of a registered tree. query() folds the concatenated literal to a constant.
CREATE OR REPLACE MACRO tree_project(sch, nm) AS TABLE
  FROM query('FROM tree_catalog.' || tree_sql_object_name('proj', sch, nm) || '()');

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
