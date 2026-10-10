-- test/mutants/MN18_abstract_open.sql
-- Abstract trees default to open attributes. Copied from sql/03_ddl.sql with
-- the attr_text default changed from
--   COALESCE((shape).semantic.attr, CASE WHEN abstract THEN '' ELSE '*' END)
-- to
--   COALESCE((shape).semantic.attr, '*')
-- so a closed abstract with no ATTR declared silently serves undeclared attributes.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/03_ddl.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
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
    COALESCE((shape).semantic.attr, '*') AS attr_text,  -- the mutation
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
