-- sql/03_ddl.sql

-- Rebuild a TREE_SHAPE from catalog rows. NULL when the tree does not exist.
CREATE OR REPLACE MACRO tree_shape_from_catalog(db, sch, nm) AS (
  SELECT CASE WHEN count(*) = 0 THEN NULL ELSE {
    root: max(expression) FILTER (WHERE slot = 'ROOT'),
    "order": max(expression) FILTER (WHERE slot = 'ORDER'),
    unique_key: max(expression) FILTER (WHERE slot = 'UNIQUE KEY'),
    level: max(expression) FILTER (WHERE slot = 'LEVEL'),
    parent: max(expression) FILTER (WHERE slot = 'PARENT'),
    sibling_order: max(expression) FILTER (WHERE slot = 'SIBLING_ORDER'),
    size: max(expression) FILTER (WHERE slot = 'SIZE'),
    children: max(expression) FILTER (WHERE slot = 'CHILDREN'),
    next: max(expression) FILTER (WHERE slot = 'NEXT'),
    semantic: {
      type: max(expression) FILTER (WHERE slot = 'TYPE'),
      key: max(expression) FILTER (WHERE slot = 'KEY'),
      tags: max(expression) FILTER (WHERE slot = 'TAGS'),
      attr: max(expression) FILTER (WHERE slot = 'ATTR'),
      attr_map: max(expression) FILTER (WHERE slot = 'ATTR_MAP'),
      element: max(expression) FILTER (WHERE slot = 'ELEMENT'),
      predicate_args: max(expression) FILTER (WHERE slot = 'PREDICATE_ARGS'),
      -- kind = 'macro' rows store body as 'macro_name(args)' (tree_sql_predicate_insert), so both
      -- are recoverable by parsing instead of dropped: without macro, a LIKE child's shared-tier
      -- scan cannot recognize that an inherited entry already claims a catalog macro (the
      -- identity exclusion in tree_expand_predicate needs (x).macro), and re-binds it a second time
      -- under a different derived name. origin is carried back as a provenance-only prefix
      -- marker, so a LIKE child re-inserting this entry (tree_sql_predicate_insert) records the
      -- right origin instead of flattening every inherited row to 'local'. tree_shared_predicate_prefix()
      -- specifically reuses tree_expand_predicate's own shared-tier marker; any other non-NULL value
      -- just needs to be distinct from it so the origin CASE falls through to 'prefix'.
      predicate: (SELECT list({name: name, body: body,
                            macro: CASE WHEN kind = 'macro' THEN split_part(body, '(', 1) END,
                            args: CASE WHEN kind = 'macro' THEN NULLIF(regexp_extract(body, '^[^(]*\((.*)\)$', 1), '') END,
                            prefix: CASE origin WHEN 'shared' THEN tree_shared_predicate_prefix() WHEN 'prefix' THEN 'prefix' ELSE NULL END} ORDER BY name)
               FROM tree_catalog.predicates p WHERE p.database_name = db AND p.schema_name = sch AND p.tree_name = nm)
    }::TREE_SEMANTIC }::TREE_SHAPE END
  FROM tree_catalog.slots WHERE database_name = db AND schema_name = sch AND tree_name = nm);

-- Child fields win; predicate lists union with the child shadowing by name.
CREATE OR REPLACE MACRO tree_shape_merge(p, c) AS
  CASE WHEN p IS NULL THEN c ELSE {
    root: COALESCE((c).root, (p).root), "order": COALESCE((c)."order", (p)."order"), unique_key: COALESCE((c).unique_key, (p).unique_key),
    level: COALESCE((c).level, (p).level), parent: COALESCE((c).parent, (p).parent), sibling_order: COALESCE((c).sibling_order, (p).sibling_order),
    size: COALESCE((c).size, (p).size), children: COALESCE((c).children, (p).children), next: COALESCE((c).next, (p).next),
    semantic: {
      type: COALESCE((c).semantic.type, (p).semantic.type), key: COALESCE((c).semantic.key, (p).semantic.key),
      tags: COALESCE((c).semantic.tags, (p).semantic.tags), attr: COALESCE((c).semantic.attr, (p).semantic.attr),
      attr_map: COALESCE((c).semantic.attr_map, (p).semantic.attr_map),
      element: COALESCE((c).semantic.element, (p).semantic.element),
      predicate_args: COALESCE((c).semantic.predicate_args, (p).semantic.predicate_args),
      predicate: list_concat(
        list_filter(COALESCE((p).semantic.predicate, []), lambda x: NOT list_contains(list_transform(COALESCE((c).semantic.predicate, []), lambda y: (y).name), (x).name)),
        COALESCE((c).semantic.predicate, []))
    }::TREE_SEMANTIC }::TREE_SHAPE END;

-- The predicates rows for an already expanded predicate list, shared by create and alter so the
-- two cannot record a binding differently. NULL when there is nothing to insert (the caller's
-- statement list drops NULLs). kind and origin record how the body was bound: macro when a macro
-- name was named, prefix when the entry came from a prefix binding, shared when it came from the
-- sel_* shared tier. tree_expand_predicate marks every prefix-derived entry's `prefix` field with
-- the literal prefix that produced it (or, for the shared tier specifically, with 'sel_' -- its
-- own marker); a NULL prefix means the entry was bound locally (or, for a LIKE-inherited
-- expression/macro row, was already local at the parent). A prefix of exactly 'sel_' is
-- ambiguous on its own: it also marks the case where the tree itself declared an explicit
-- {prefix: 'sel_'} binding (a legitimate, if unusual, prefix form). `explicit_sel_prefix` --
-- computed by the caller from the tree's own unexpanded PREDICATE declaration, never from a
-- merged/inherited one -- breaks the tie: shared only when the tree did not itself ask for that
-- literal prefix. purity is computed by tree_sql_purity (M4): pure, impure, unknown or
-- malformed, with the first two decidable and refused by tree_sql_check_purity before this runs.
-- Built over the list's INDICES rather than with list_transform, because tree_sql_purity is a
-- subquery macro and DuckDB refuses a subquery inside a lambda. `ORDER BY i` keeps the emission
-- order identical to the list's, which list_aggregate gave for free -- the expanded list is not
-- name-ordered (the shared tier is, the local entries are as written), so ordering by name here
-- would have quietly reordered what the catalog records.
CREATE OR REPLACE MACRO tree_sql_predicate_insert(db, sch, nm, predicate, explicit_sel_prefix) AS
  CASE WHEN len(COALESCE(predicate, [])) = 0 THEN NULL ELSE
  'INSERT INTO tree_catalog.predicates VALUES ' || (
    SELECT string_agg(r, ', ' ORDER BY i) FROM (
      SELECT i,
        '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', '
        || tree_sql_lit((predicate[i]).name) || ', '
        || CASE WHEN (predicate[i]).macro IS NULL THEN '''expression''' ELSE '''macro''' END || ', '
        || tree_sql_lit((predicate[i]).body) || ', '
        || CASE WHEN (predicate[i]).prefix IS NULL THEN '''local'''
                WHEN (predicate[i]).prefix = tree_shared_predicate_prefix() AND NOT explicit_sel_prefix THEN '''shared'''
                ELSE '''prefix''' END || ', '
        || tree_sql_lit(tree_sql_purity((predicate[i]).body)) || ')' AS r
      FROM generate_series(1, len(predicate)) t(i))) END;

-- The attribute_columns artifact: the projection's non-canonical columns -- name AND declared
-- type -- in projection order, as a JSON list of `{"name": ..., "type": ...}` objects. Recorded
-- rather than recomputed because the front-ends (and the CSS lowering M2 adds) need to know which
-- bare names are attributes without describing the relation on every query. The projection macro
-- is described, not the source, so it is right for both storage modes -- a materialized tree's
-- macro selects from its table.
--
-- The TYPE was added by the PR #2 fix wave (R7). Without it the clause compiler could only splice
-- the literal as written, so an unquoted css number against a text column (`[name=5]`) compiled to
-- `name = 5`, which DuckDB binds by casting the COLUMN -- and the first row whose text is not a
-- number aborted the whole query. tree_sql_attr_col_cmp (sql/07_match.sql) reads the type and
-- picks the comparison; an artifact written before this change is a bare list of names and reads
-- back with a NULL type, which that macro also handles.
--
-- 1.5.5 notes: DESCRIBE takes a statement, not a table-function call ("DESCRIBE proj()" is a
-- parser error, "DESCRIBE SELECT * FROM proj()" is not), and its output has no column_index,
-- so projection order is recovered with row_number() OVER () over the describe rows.
CREATE OR REPLACE MACRO tree_sql_attr_cols_insert(db, sch, nm, proj_name) AS
  'INSERT INTO tree_catalog.compiled SELECT ' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm)
  || ', ''attribute_columns'', '''', to_json(COALESCE(list({''name'': column_name, ''type'': column_type} ORDER BY i), []))'
  || ' FROM (SELECT column_name, column_type, row_number() OVER () AS i FROM (DESCRIBE SELECT * FROM ' || proj_name || '()))'
  || ' WHERE column_name NOT LIKE ''\_%'' ESCAPE ''\''';

CREATE OR REPLACE MACRO tree_compile_create(sch, nm, spec) AS (
WITH base AS (
  SELECT current_database() AS db,
         tree_shape_merge(CASE WHEN (spec)."like" IS NULL THEN NULL ELSE tree_shape_from_catalog(current_database(), sch, (spec)."like") END, (spec).shape) AS merged,
         (spec)."like" IS NOT NULL AND tree_shape_from_catalog(current_database(), sch, (spec)."like") IS NULL AS like_missing,
         EXISTS (SELECT 1 FROM tree_catalog.trees t WHERE t.database_name = current_database() AND t.schema_name = sch AND t.tree_name = nm) AS exists_already,
         -- DuckDB identifiers are case-insensitive, so two trees whose names differ only by case
         -- would share every generated table and macro name (tree_sql_object_name does not fold
         -- case). min() picks a deterministic collision partner to name in the refusal; the
         -- exact-name case is excluded here so a re-create of the same tree keeps the
         -- "already exists" refusal above instead of this one.
         (SELECT min(t.schema_name || '.' || t.tree_name) FROM tree_catalog.trees t
           WHERE t.database_name = current_database() AND lower(t.schema_name) = lower(sch) AND lower(t.tree_name) = lower(nm)
             AND NOT (t.schema_name = sch AND t.tree_name = nm)) AS collides_with,
         (spec).abstract AS abstract, (spec).source AS source, (spec).storage AS storage
),
-- Macro-, map- and prefix-bound predicates become expression bodies here, before validation
-- and before anything is stored: tree_sql_predicate_map reads (p).body only, so an unexpanded
-- binding would compile the predicate map -- and with it the projection -- to NULL. The catalog
-- then holds the expanded body, so nothing downstream has to re-expand (and a prefix binding
-- is resolved once, against the macros that existed at create time).
expanded AS (
  SELECT * EXCLUDE (merged),
    -- the group as WRITTEN, kept alongside the expanded one for tree_sql_check_prefixes: a prefix
    -- that bound no macro leaves no trace in the expansion (sql/00_types.sql)
    (merged).semantic AS raw_semantic,
    {root: (merged).root, "order": (merged)."order", unique_key: (merged).unique_key, level: (merged).level, parent: (merged).parent,
     sibling_order: (merged).sibling_order, size: (merged).size, children: (merged).children, next: (merged).next,
     semantic: tree_expand_predicate((merged).semantic)}::TREE_SHAPE AS shape,
    -- Tested against this create's own declared PREDICATE, never the LIKE-merged one: a parent's
    -- already-resolved shared/prefix rows round-trip with a provenance marker of their own
    -- (tree_shape_from_catalog), and that marker must never be mistaken for a fresh explicit
    -- declaration by this tree.
    len(list_filter(COALESCE((spec).shape.semantic.predicate, []), lambda p: (p).prefix = tree_shared_predicate_prefix())) > 0 AS explicit_sel_prefix
  FROM base
),
derived AS (
  SELECT *,
    -- R2 defaults to LEVEL 0 (M3 §2.6): the level basis is taken whenever LEVEL is declared and
    -- whenever NEITHER LEVEL NOR PARENT is, so a table declaring no structure at all registers as
    -- a forest of one-node trees instead of being refused. Everything downstream that asks which
    -- basis this is reads THIS name -- profile, order_source and the refusal ladder included -- so
    -- the basis cannot end up spelled two ways that disagree on the shape that declares neither.
    ((shape).level IS NOT NULL OR (shape).parent IS NULL) AS level_basis,
    CASE WHEN level_basis THEN 'level' ELSE 'parent' END AS basis,
    CASE WHEN NOT level_basis AND (shape).sibling_order IS NULL THEN 'sibling_free' ELSE 'full' END AS profile,
    CASE WHEN NOT level_basis OR (shape)."order" IS NOT NULL THEN 'declared' ELSE 'frozen' END AS order_source,
    -- The KEY the walk is driven by, or NULL when there is no walk: the two parent-basis ingest
    -- checks are NULL-gated on it, so the level basis passes NULL here rather than each call site
    -- re-deciding which basis this is. A level-basis tree may still DECLARE a KEY, so this asks
    -- the basis, not whether a KEY exists.
    -- reach_key_expr gates the REACH check, which walks PARENT, so it is meaningless without one and
    -- stays NULL on a level basis. UNIQUENESS is a property of the DECLARATION, not of the basis:
    -- it was gated with the reach check, so a level-basis tree's declared KEY was recorded in the
    -- slot list below and never verified, while the same declaration was enforced on a parent
    -- basis. Two claims, two gates.
    CASE WHEN level_basis THEN NULL ELSE (shape).unique_key END AS reach_key_expr,
    (shape).unique_key AS unique_key_expr,
    COALESCE((shape).semantic.attr, CASE WHEN abstract THEN '' ELSE '*' END) AS attr_text,
    -- Whether the tree has an S GROUP, which is what tree_match reads to decide whether an S
    -- clause (TYPE, ID, CLASS, ATTR, PSEUDO) may be asked for at all. The question -- does this
    -- SEMANTIC declare an S slot? -- is tree_semantic_declares (sql/00_types.sql), the one
    -- predicate create, alter and the match compiler's overlay check all read, so the three
    -- cannot drift apart (they had: see that macro's comment).
    --
    -- The slots are read off the LIKE-MERGED shape, so an inherited slot counts as a declared
    -- one; the last term carries a parent whose own S group this shape cannot see, because
    -- reading the parent's TYPE alone made an ID-only parent invisible.
    tree_semantic_declares((shape).semantic)
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
      WHEN sch IS NULL OR nm IS NULL THEN tree_err('tree_ddl_create: schema and name are required')
      WHEN abstract IS NULL THEN tree_err('tree_ddl_create: abstract must be true or false')
      WHEN exists_already THEN tree_err('tree_ddl_create: tree ' || sch || '.' || nm || ' already exists')
      WHEN collides_with IS NOT NULL
        THEN tree_err('tree_ddl_create: tree ' || sch || '.' || nm || ' collides with existing tree ' || collides_with || ' (names are case-insensitive)')
      WHEN like_missing THEN tree_err('tree_ddl_create: LIKE target ' || sch || '.' || (spec)."like" || ' not found')
      WHEN abstract AND source IS NOT NULL THEN tree_err('tree_ddl_create: a SHAPE ONLY (abstract) tree cannot have a source')
      WHEN NOT abstract AND source IS NULL THEN tree_err('tree_ddl_create: no source given; declare abstract := true (SHAPE ONLY) or pass source')
      WHEN storage IS NULL OR storage NOT IN ('materialized', 'projection') THEN tree_err('tree_ddl_create: storage must be materialized or projection')
      WHEN NOT level_basis AND (shape).unique_key IS NULL THEN tree_err('tree_ddl_create: PARENT basis requires UNIQUE KEY (the column PARENT refers to)')
      WHEN NOT level_basis AND NOT (tree_sql_is_ident((shape).unique_key) AND tree_sql_is_ident((shape).parent)) THEN tree_err('tree_ddl_create: PARENT basis needs UNIQUE KEY and PARENT to be plain column names')
      -- SIBLING_ORDER belongs to the PARENT basis and to nothing else. The level basis derives the
      -- sibling order from ORDER by construction (_pre is the rank of ORDER within the root), and
      -- the level-basis arm of tree_compile_projection never reads (shape).sibling_order -- it is
      -- spliced only into the recursive walk of the parent-basis arm, where it is what makes the
      -- DFS numbering deterministic. So a SIBLING_ORDER here is not an unused refinement, it is a
      -- SECOND, CONTRADICTING ordering that the catalog recorded as in force while :first-child,
      -- :last-child and the sibling combinators went on answering by ORDER -- and, because nothing
      -- ever compiled the expression, it was recorded even when it named no column at all.
      -- Refused rather than honoured: honouring it would mean a level-basis tree whose _pre and
      -- whose sibling order disagree, and every O(1) form downstream of _pre assumes they cannot.
      -- Asks the BASIS, never the LEVEL slot: LEVEL and PARENT together is still the level basis,
      -- and so is a shape that declares neither (R2 defaults to LEVEL 0).
      WHEN level_basis AND (shape).sibling_order IS NOT NULL
        THEN tree_err('tree_ddl_create: LEVEL basis does not take SIBLING_ORDER (ORDER already is the sibling order there); declare it on a PARENT basis, whose DFS numbering it makes deterministic')
      WHEN NOT abstract AND storage = 'projection' AND level_basis AND (shape)."order" IS NULL THEN tree_err('tree_ddl_create: ORDER is required for projection-mode trees (the source is not frozen)')
      WHEN NOT abstract AND order_source = 'frozen' AND NOT current_setting('preserve_insertion_order') THEN tree_err('tree_ddl_create: ORDER is required because preserve_insertion_order is off')
      -- both halves of the S ladder: the prefix check reads the group as written (a prefix that
      -- bound nothing is gone from the expansion), the rest reads the expanded one
      ELSE tree_sql_check_prefixes(raw_semantic, 'tree_ddl_create')
           AND tree_sql_check_semantic((shape).semantic, attr_text, 'tree_ddl_create')
           -- purity reads the EXPANDED group: a macro- or prefix-bound entry is judged on the
           -- body it actually compiles to, not on the name that bound it
           AND tree_sql_check_purity((shape).semantic, 'tree_ddl_create') END AS ok,
    CASE WHEN abstract THEN NULL ELSE tree_compile_projection(shape, source, attr_text) END AS proj_sql
  FROM derived
),
slot_rows AS (
  SELECT list_filter([
    {b: 'R', s: 'ROOT', e: (shape).root}, {b: 'R', s: 'ORDER', e: (shape)."order"}, {b: 'R', s: 'UNIQUE KEY', e: (shape).unique_key},
    {b: 'R', s: 'LEVEL', e: (shape).level}, {b: CASE WHEN level_basis THEN 'O' ELSE 'R' END, s: 'PARENT', e: (shape).parent},
    {b: 'R', s: 'SIBLING_ORDER', e: (shape).sibling_order},
    {b: 'S', s: 'TYPE', e: (shape).semantic.type}, {b: 'S', s: 'KEY', e: (shape).semantic.key}, {b: 'S', s: 'TAGS', e: (shape).semantic.tags},
    {b: 'S', s: 'ATTR', e: attr_text}, {b: 'S', s: 'ATTR_MAP', e: (shape).semantic.attr_map},
    {b: 'S', s: 'ELEMENT', e: (shape).semantic.element}, {b: 'S', s: 'PREDICATE_ARGS', e: (shape).semantic.predicate_args},
    {b: 'O', s: 'SIZE', e: (shape).size}, {b: 'O', s: 'CHILDREN', e: (shape).children}, {b: 'O', s: 'NEXT', e: (shape).next}
  ], lambda x: (x).e IS NOT NULL) AS rows, * FROM checked
),
-- Each statement is built as a named column so the list can fail closed: an optional
-- statement is NULL by construction, but a required one going NULL means an interpolated
-- value was NULL, and filtering it away is how a half-registered tree gets created (I3).
built AS (
  SELECT
   'INSERT INTO tree_catalog.trees VALUES (' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || abstract || ', '
     || COALESCE(tree_sql_lit((spec)."like"), 'NULL') || ', ' || COALESCE(tree_sql_lit(source), 'NULL') || ', ' || tree_sql_lit(basis) || ', ' || tree_sql_lit(profile) || ', '
     || tree_sql_lit(storage) || ', ' || tree_sql_lit(order_source) || ', ' || has_semantic || ', NULL)' AS s_trees,
   'INSERT INTO tree_catalog.slots VALUES ' || list_aggregate(list_transform(rows, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit((x).b) || ', ' || tree_sql_lit((x).s) || ', ' || tree_sql_lit((x).e) || ')'), 'string_agg', ', ') AS s_slots,
   tree_sql_predicate_insert(db, sch, nm, (shape).semantic.predicate, explicit_sel_prefix) AS s_predicate,
   -- ORDER first, and over the SOURCE rather than the projection: it must precede every statement
   -- that evaluates proj_sql, because a tie is numbered away by row_number() and, under a declared
   -- PARENT, multiplies rows through the __order join (M3 §3.2). Emitted for projection-mode trees
   -- too -- a tie there makes _pre change between queries.
   CASE WHEN abstract THEN NULL ELSE tree_compile_order_check((shape)."order", (shape).root, source, sch || '.' || nm) END AS s_order,
   -- The parent basis's two, in this order and both ahead of everything that evaluates proj_sql:
   -- a repeated KEY multiplies or collapses the walk, so the reach check run first would report
   -- that as unreachable rows and name the wrong defect.
   CASE WHEN abstract THEN NULL ELSE tree_compile_unique_key_check(unique_key_expr, (shape).root, source, sch || '.' || nm) END AS s_key,
   CASE WHEN abstract THEN NULL ELSE tree_compile_reach_check(reach_key_expr, (shape).root, source, '(' || proj_sql || ')', sch || '.' || nm, attr_text) END AS s_reach,
   CASE WHEN abstract THEN NULL ELSE tree_sql_shadow_check('(' || proj_sql || ')', 'tree_ddl_create') END AS s_shadow,
   CASE WHEN abstract THEN NULL ELSE tree_compile_p13('(' || proj_sql || ')', sch || '.' || nm, (shape).root IS NOT NULL, (shape).level) END AS s_p13,
   -- O conformance (M3 §3.1), after P13 so a malformed level is reported as that rather than as
   -- the disagreeing SIZE it goes on to produce. MATERIALIZED ONLY: this statement pins what is
   -- about to be STORED, and a projection-mode tree stores nothing -- its source can change
   -- under it between any two queries, so a create-time refusal would be a promise the storage
   -- mode cannot keep. tree_check RECORDS the same comparison for those trees instead (§3.4).
   CASE WHEN abstract OR storage <> 'materialized' THEN NULL
        ELSE tree_compile_o_conformance(shape, '(' || proj_sql || ')', sch || '.' || nm, tree_sql_o_order_col(shape, attr_text), attr_text) END AS s_conform,
   CASE WHEN abstract OR storage <> 'materialized' THEN NULL ELSE 'CREATE TABLE ' || tbl_name || ' AS ' || proj_sql END AS s_table,
   CASE WHEN abstract THEN NULL WHEN storage = 'materialized' THEN 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE SELECT * FROM ' || tbl_name
        ELSE 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE ' || proj_sql END AS s_macro,
   CASE WHEN abstract OR storage <> 'materialized' THEN NULL ELSE
     'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', _root::VARCHAR, 1, count(*), true, now() FROM ' || tbl_name || ' GROUP BY _root' END AS s_partitions,
   CASE WHEN abstract THEN NULL ELSE 'INSERT INTO tree_catalog.compiled VALUES (' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ''projection'', ' || tree_sql_lit(proj_name) || ', ' || tree_sql_lit(proj_sql) || ')' END AS s_compiled,
   CASE WHEN abstract THEN NULL ELSE tree_sql_attr_cols_insert(db, sch, nm, proj_name) END AS s_attr_cols,
  FROM slot_rows WHERE ok
)
SELECT CASE WHEN s_trees IS NULL OR s_slots IS NULL
            -- plain tree_err(), not (SELECT tree_err(...)): an uncorrelated scalar subquery is
            -- evaluated once, eagerly, and would refuse every valid create
            THEN tree_err('tree_ddl_create: internal: a required statement compiled to NULL')
            ELSE list_filter([s_trees, s_slots, s_predicate, s_order, s_key, s_reach, s_shadow, s_p13, s_conform, s_table, s_macro, s_partitions, s_compiled, s_attr_cols], lambda x: x IS NOT NULL) END
FROM built);

-- A missing tree refuses outright: without this check, dropping a mistyped or never-created
-- name (e.g. a case variant of an existing tree, since names collide case-insensitively but the
-- catalog lookup here stays exact) would still run every DROP/DELETE below -- and since
-- tree_sql_object_name does not fold case, those statements target a case-differing
-- neighbour's real table and macro (F11-style: fail closed, don't run statements for an
-- identity that was never registered).
CREATE OR REPLACE MACRO tree_compile_drop(sch, nm) AS (
  SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM tree_catalog.trees t WHERE t.database_name = current_database() AND t.schema_name = sch AND t.tree_name = nm)
    THEN tree_err('tree_ddl_drop: tree ' || COALESCE(sch, '<NULL>') || '.' || COALESCE(nm, '<NULL>') || ' not found')
    ELSE [
    'DELETE FROM tree_catalog.trees WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.slots WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.predicates WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_catalog.compiled WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_state.partitions WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DELETE FROM tree_state.assertions WHERE database_name = current_database() AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
    'DROP MACRO TABLE IF EXISTS tree_catalog.' || tree_sql_object_name('proj', sch, nm),
    'DROP TABLE IF EXISTS tree_catalog.' || tree_sql_object_name('t', sch, nm),
    ] END);

-- Replace the SEMANTIC group and rebuild the projection (and storage, when materialized).
-- Alter changes S only, never the row SET. Four guards keep it from being a back door: the S
-- validation ladder is the same fragment create uses (so a closed tree stays closed and the
-- `_` prefix stays reserved); a materialized tree whose partitions no longer all come from
-- source_sql refuses outright, because rebuilding with CREATE OR REPLACE TABLE would drop
-- what tree_insert added (C1); any other drift between the source and the stored
-- partitions -- a root the source gained, or a root whose row count changed -- refuses too,
-- because the rebuild would silently ingest or discard rows as a side effect of an S change;
-- and the frozen-order guard refuses a rebuild that would re-freeze an arbitrary scan order,
-- which the drift checks cannot see because they compare row COUNTS. That last one is why this
-- says "the row set" rather than "data": in an order_source = 'frozen' tree the ORDER is the
-- tree, and a rebuild reorders without changing a single count.
-- The same P13 and shadow checks create runs are emitted before the table is rebuilt.
CREATE OR REPLACE MACRO tree_compile_alter(sch, nm, semantic) AS (
WITH t AS (
  SELECT current_database() AS db, tr.storage, tr.source_sql, tr.is_abstract, tr.order_source,
         tree_shape_from_catalog(current_database(), sch, nm) AS old_shape
  FROM tree_catalog.trees tr WHERE tr.database_name = current_database() AND tr.schema_name = sch AND tr.tree_name = nm
),
-- Same expansion create does, for the same reason: the stored body and the compiled predicate
-- map are expression text, never a macro name (00_types.sql, tree_expand_predicate). Tested
-- against this alter's own `semantic` argument (never `sem`, its expansion): an explicit
-- {prefix: 'sel_'} declaration is what this flag means, not the shared tier's own marker.
ex AS (SELECT *, tree_expand_predicate(semantic) AS sem,
              len(list_filter(COALESCE((semantic).predicate, []), lambda p: (p).prefix = tree_shared_predicate_prefix())) > 0 AS explicit_sel_prefix
       FROM t),
n AS (
  SELECT *,
    {root: (old_shape).root, "order": (old_shape)."order", unique_key: (old_shape).unique_key, level: (old_shape).level, parent: (old_shape).parent, sibling_order: (old_shape).sibling_order,
     size: (old_shape).size, children: (old_shape).children, next: (old_shape).next, semantic: sem}::TREE_SHAPE AS shape,
    COALESCE((sem).attr, (old_shape).semantic.attr, CASE WHEN is_abstract THEN '' ELSE '*' END) AS attr_text,
    -- see create's reach_key_expr: NULL in the level basis, which NULL-gates the reach check. Uniqueness
    -- is gated on the declaration instead, so altering a tree re-verifies a KEY on either basis.
    -- Alter never touches R, so the basis is the one the stored shape already carries.
    CASE WHEN (old_shape).level IS NOT NULL OR (old_shape).parent IS NULL THEN NULL ELSE (old_shape).unique_key END AS reach_key_expr,
    (old_shape).unique_key AS unique_key_expr,
    -- Whether the tree has an S GROUP after this alter, which is what tree_match reads to decide
    -- whether an S clause may be asked for. The same predicate create reads (tree_semantic_declares,
    -- sql/00_types.sql), asked of THIS ALTER'S semantic and nothing else.
    --
    -- Nothing is OR'd in from the flag the tree already carried. Alter REPLACES the S group -- the
    -- statement list below DELETEs every S slot of the tree and re-inserts only the ones this
    -- semantic declares -- so a flag that survived its slots was a flag about slots that are gone:
    -- a TYPE tree altered to an ATTR-only semantic stayed marked S-ful, and a TYPE clause then
    -- compiled against the 'node' default and returned nothing where a refusal was owed. 13_alter
    -- carries the record. (The comment here used to say "alter adds to what create declared",
    -- which the DELETE two dozen lines below has always made false.)
    tree_semantic_declares(sem) AS has_semantic,
    'tree_catalog.' || tree_sql_object_name('proj', sch, nm) AS proj_name,
    'tree_catalog.' || tree_sql_object_name('t', sch, nm) AS tbl_name
  FROM ex
),
c AS (
  SELECT *, CASE WHEN is_abstract THEN NULL ELSE tree_compile_projection(shape, source_sql, attr_text) END AS proj_sql,
    -- the same two halves create runs, in this verb's words: the prefix check reads `semantic`,
    -- the argument as written, because a prefix that bound no macro is gone from `sem`
    tree_sql_check_prefixes(semantic, 'tree_ddl_alter')
      AND tree_sql_check_semantic(sem, attr_text, 'tree_ddl_alter')
      AND tree_sql_check_purity(sem, 'tree_ddl_alter') AS ok,
    list_filter([
      {b: 'S', s: 'TYPE', e: (sem).type}, {b: 'S', s: 'KEY', e: (sem).key}, {b: 'S', s: 'TAGS', e: (sem).tags},
      {b: 'S', s: 'ATTR', e: attr_text}, {b: 'S', s: 'ATTR_MAP', e: (sem).attr_map},
      {b: 'S', s: 'ELEMENT', e: (sem).element}, {b: 'S', s: 'PREDICATE_ARGS', e: (sem).predicate_args}], lambda x: (x).e IS NOT NULL) AS rows
  FROM n
)
SELECT CASE WHEN semantic IS NULL THEN tree_err('tree_ddl_alter: semantic is NULL; nothing to alter')
  -- evaluated outside FROM c: when the tree does not exist c has no rows, and a compiler
  -- that returns NULL instead of refusing hands the executor nothing to run (F11). The
  -- COALESCEs close the same hole by the other route: a NULL schema or name makes this the
  -- branch that fires AND makes its message NULL, and error(NULL) is NULL in 1.5.5.
  WHEN NOT EXISTS (SELECT 1 FROM t) THEN tree_err('tree_ddl_alter: tree ' || COALESCE(sch, '<NULL>') || '.' || COALESCE(nm, '<NULL>') || ' not found') ELSE
  (SELECT list_filter([
   -- First, as in insert and replace: an `order_source = 'frozen'` tree takes _pre from the
   -- source's scan order, and alter REBUILDS the stored table from that source, so with
   -- preserve_insertion_order off it would freeze an arbitrary order into _pre and so into
   -- _parent, _size and every positional answer. The drift checks below cannot stand in for
   -- this -- they compare per-root row COUNTS, which a reshuffle leaves alone. Create refuses
   -- the shape and both ingest verbs refuse the data; this is the same guard, same message.
   tree_sql_frozen_guard(order_source, 'tree_ddl_alter'),
   -- ahead of the two drift checks as well as of the shadow and P13 ones: all four evaluate
   -- proj_sql, and a tied ORDER under a declared PARENT multiplies its rows, which would be
   -- reported as a drifted row count rather than as the malformed ORDER it is
   CASE WHEN is_abstract THEN NULL ELSE tree_compile_order_check((old_shape)."order", (old_shape).root, source_sql, sch || '.' || nm) END,
   -- ahead of the drift checks for the same reason the order check is: both evaluate proj_sql, and
   -- a source whose KEY repeats walks to the wrong number of rows, which would be reported as drift
   CASE WHEN is_abstract THEN NULL ELSE tree_compile_unique_key_check(unique_key_expr, (old_shape).root, source_sql, sch || '.' || nm) END,
   CASE WHEN is_abstract THEN NULL ELSE tree_compile_reach_check(reach_key_expr, (old_shape).root, source_sql, '(' || proj_sql || ')', sch || '.' || nm, attr_text) END,
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
   CASE WHEN is_abstract THEN NULL ELSE tree_compile_p13('(' || proj_sql || ')', sch || '.' || nm, (old_shape).root IS NOT NULL, (old_shape).level) END,
   -- Alter changes S only, but it REBUILDS the stored table from the source, so the rows it is
   -- about to write get the same conformance check create gives the rows it writes. The O group
   -- rides on the old shape (alter never touches R or O), so this asks about the source, not
   -- about the semantic being installed.
   CASE WHEN is_abstract OR storage <> 'materialized' THEN NULL
        ELSE tree_compile_o_conformance(shape, '(' || proj_sql || ')', sch || '.' || nm, tree_sql_o_order_col(shape, attr_text), attr_text) END,
   'DELETE FROM tree_catalog.slots WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND block = ''S''',
   'DELETE FROM tree_catalog.predicates WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
   'INSERT INTO tree_catalog.slots VALUES ' || list_aggregate(list_transform(rows, lambda x:
       '(' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ' || tree_sql_lit((x).b) || ', ' || tree_sql_lit((x).s) || ', ' || tree_sql_lit((x).e) || ')'), 'string_agg', ', '),
   tree_sql_predicate_insert(db, sch, nm, (sem).predicate, explicit_sel_prefix),
   'UPDATE tree_catalog.trees SET has_semantic = ' || has_semantic || ' WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm),
   CASE WHEN is_abstract OR storage <> 'materialized' THEN NULL ELSE 'CREATE OR REPLACE TABLE ' || tbl_name || ' AS ' || proj_sql END,
   CASE WHEN is_abstract THEN NULL WHEN storage = 'materialized' THEN 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE SELECT * FROM ' || tbl_name
        ELSE 'CREATE OR REPLACE MACRO ' || proj_name || '() AS TABLE ' || proj_sql END,
   CASE WHEN is_abstract THEN NULL ELSE 'UPDATE tree_catalog.compiled SET sql_text = ' || tree_sql_lit(proj_sql) || ' WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''projection''' END,
   -- deleted and re-inserted rather than updated: the new column list is computed by describing
   -- the rebuilt projection, which an UPDATE ... SET sql_text = (subquery) cannot do portably
   CASE WHEN is_abstract THEN NULL ELSE 'DELETE FROM tree_catalog.compiled WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''attribute_columns''' END,
   CASE WHEN is_abstract THEN NULL ELSE tree_sql_attr_cols_insert(db, sch, nm, proj_name) END,
   ], lambda x: x IS NOT NULL) FROM c WHERE ok) END);

-- The canonical projection of a registered tree. query() folds the concatenated literal to a constant.
CREATE OR REPLACE MACRO tree_project(sch, nm) AS TABLE
  FROM query('FROM tree_catalog.' || tree_sql_object_name('proj', sch, nm) || '()');

-- Ad hoc: a shape applied to a bare source, no registration. Open attributes, as for any concrete tree.
CREATE OR REPLACE MACRO tree_apply(shape, source) AS TABLE
  FROM query(tree_compile_projection(shape, source, '*'));

-- Tags are data: enumerate them per tree.
-- 1.5.5 note: `SELECT unnest(_tags) ... GROUP BY ALL` fails ("Cannot group on an
-- UNNEST or UNLIST clause") because DuckDB won't group on an UNNEST expression in the
-- select list. Unnesting in the FROM clause instead (a lateral UNNEST(...) AS u(tag))
-- produces a plain column that GROUP BY ALL can group on; the compiled result is the
-- same set of (tag, row_count) pairs the brief's version intended.
CREATE OR REPLACE MACRO tree_catalog_tags(sch, nm) AS TABLE
  SELECT tag, count(*) AS row_count FROM tree_project(sch, nm), UNNEST(_tags) AS u(tag) WHERE _tags IS NOT NULL GROUP BY ALL ORDER BY tag;
