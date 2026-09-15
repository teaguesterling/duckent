-- test/mutants/MN06_sibling_free_silent.sql
-- Sibling combinators silently no-op under the sibling-free profile: 'next'/'after'
-- compile to a comparison that never raises (they still combine into a predicate,
-- just not a useful one), and the refusal branch in tree_compile_match is removed
-- so the compiler never objects to using them on a sibling-free tree.
CREATE OR REPLACE MACRO tree_sql_comb(op, a, b, p, elem) AS
  CASE op
    WHEN 'desc'  THEN tree_sql_subtree(a, b)
    WHEN 'child' THEN tree_sql_children(a, b)
    ELSE 'false' END;

-- Copied from sql/07_match.sql with the
--   WHEN kind = 'step' AND op IN ('next', 'after') AND (SELECT profile FROM t) = 'sibling_free' ...
-- refusal branch removed from the n CTE's CASE, and that CTE's comment trimmed to match.
CREATE OR REPLACE MACRO tree_compile_match(sch, nm, sel, semantic := NULL, language := NULL) AS (
WITH t AS (
  SELECT tr.profile, tr.has_semantic OR semantic IS NOT NULL AS has_semantic,
         (SELECT list(name) FROM tree_catalog.pseudo_classes p WHERE p.database_name = current_database() AND p.schema_name = sch AND p.tree_name = nm) AS known_pseudos,
         -- whether any row can be a non-element: only then must the sibling and positional
         -- fragments scan for the nearest element neighbour instead of using the O(1) pre/size form
         EXISTS (SELECT 1 FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND s.slot = 'ELEMENT')
           OR (semantic).element IS NOT NULL AS has_element,
         EXISTS (SELECT 1 FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND s.slot = 'ATTR_MAP')
           OR (semantic).attr_map IS NOT NULL AS has_map,
         -- the projection's non-canonical columns, recorded at create time: which bare names an
         -- ATTR clause may resolve to without describing the relation on every query
         COALESCE((SELECT from_json(c.sql_text, '["VARCHAR"]') FROM tree_catalog.compiled c
                   WHERE c.database_name = current_database() AND c.schema_name = sch AND c.tree_name = nm AND c.artifact = 'attribute_columns'), []::VARCHAR[]) AS attr_cols
  FROM tree_catalog.trees tr WHERE tr.database_name = current_database() AND tr.schema_name = sch AND tr.tree_name = nm),
-- The overlay with its macro-, map- and prefix-bound pseudo-classes turned into expression
-- bodies, exactly as the DDL compilers do before storing them: tree_sql_pseudo_map reads (p).body
-- only, so an unexpanded binding would compile the _pseudo map -- and with it the whole
-- projection text -- to NULL. A NULL overlay must stay NULL rather than become a struct of NULLs,
-- which is what tree_expand_pseudo(NULL) returns, hence the guard.
ov AS (SELECT CASE WHEN semantic IS NULL THEN NULL ELSE tree_expand_pseudo(semantic) END AS sem),
-- 1.5.5 refuses a subquery anywhere inside an expression that carries a lambda ("subqueries in
-- lambda expressions are not supported"), and macro inlining puts the argument text inside the
-- lambda. So everything a lambda-bearing fragment (tree_sql_pseudo_map, tree_sql_chain) or a
-- lambda here is handed has to arrive as a plain column reference, which is what ovp and cfg are
-- for: each is one row, joined in rather than read with (SELECT ... FROM ...).
ovp AS (SELECT sem, list_transform(COALESCE((sem).pseudo, []), lambda x: (x).name) AS names FROM ov),
chk AS (SELECT CASE
  WHEN (SELECT count(*) FROM t) = 0 THEN error('tree_match: tree ' || sch || '.' || nm || ' not found')
  -- an overlay is an S group for this query only; it cannot widen the projection, and an
  -- overlay that sets nothing (or a selector with no steps) used to compile to NULL
  WHEN (semantic).attr IS NOT NULL THEN error('tree_match: a per-query SEMANTIC overlay cannot add attribute columns; use tree_ddl_alter')
  WHEN semantic IS NOT NULL AND (semantic).type IS NULL AND (semantic).id IS NULL AND (semantic).classes IS NULL
       AND (semantic).attr_map IS NULL AND (semantic).pseudo IS NULL AND (semantic).element IS NULL
       THEN error('tree_match: semantic overlay is empty')
  WHEN (SELECT count(*) FROM (SELECT unnest(sel, recursive := true)) WHERE kind = 'step') = 0 THEN error('tree_match: selector has no steps')
  ELSE true END AS ok),
-- The relation every step alias ranges over: the stored projection, or a REPLACE over it when
-- the query carries an overlay. Each replaced column is spelled the way sql/02_projection.sql
-- spells it, so an overlaid tree and a declared one behave identically -- ATTR MAP cast to the
-- canonical map type, ELEMENT made NULL-definite.
proj AS (
  SELECT CASE WHEN semantic IS NULL THEN 'tree_catalog.' || tree_sql_object_name('proj', sch, nm) || '()'
    ELSE '(SELECT * REPLACE (' || list_aggregate(list_filter([
        (semantic).type || ' AS _type', (semantic).id || ' AS _id', (semantic).classes || ' AS _classes',
        CASE WHEN (semantic).attr_map IS NULL THEN NULL ELSE 'CAST(' || (semantic).attr_map || ' AS MAP(VARCHAR, VARCHAR)) AS _attr_map' END,
        CASE WHEN (semantic).element IS NULL THEN NULL ELSE 'COALESCE(' || (semantic).element || ', false) AS _element' END,
        -- map_concat, not replace: the catalog's pseudo-classes stay bound, the overlay's
        -- entries are added, and the overlay (the second argument) wins on a shared name
        CASE WHEN (semantic).pseudo IS NULL THEN NULL ELSE 'map_concat(_pseudo, ' || tree_sql_pseudo_map(sem) || ') AS _pseudo' END], lambda x: x IS NOT NULL), 'string_agg', ', ')
      || ') FROM tree_catalog.' || tree_sql_object_name('proj', sch, nm) || '())' END AS p
  FROM ovp),
-- The one row every text-building step joins against. A missing tree leaves t empty, so these are
-- scalar subqueries over a FROM-less SELECT rather than a join: cfg must still have its one row,
-- or chk would never get to raise "tree not found".
cfg AS (SELECT (SELECT p FROM proj) AS p, (SELECT has_element FROM t) AS elem,
               (SELECT has_map FROM t) AS has_map, (SELECT attr_cols FROM t) AS attr_cols),
-- IR rows, every level of them: S clauses refused on S-less trees, unknown pseudo-classes marked,
-- unnest(recursive := true) flattens the whole selector, so a clause inside a group is checked
-- exactly like a top-level one.
n AS (
  SELECT node_id, parent_id,
         CASE WHEN kind = 'pseudo' AND NOT list_contains(tree_builtin_pseudos(), value)
                   AND NOT list_contains(COALESCE((SELECT known_pseudos FROM t), []), value)
                   AND (semantic IS NULL OR NOT list_contains((SELECT names FROM ovp), value)) THEN 'pseudo_unknown' ELSE kind END AS kind,
         value, op, arg, COALESCE(alias, 's' || node_id) AS alias,
         CASE WHEN kind IN ('type', 'id', 'class', 'attr', 'pseudo') AND NOT (SELECT has_semantic FROM t)
              THEN error('tree_match: tree ' || sch || '.' || nm || ' has no SEMANTIC group; only combinators and WHERE are available. Add one with tree_ddl_alter or pass semantic :=')
              ELSE true END AS ok
  FROM (SELECT unnest(sel, recursive := true))),
-- (step node id, part node id, part text) for every clause: the same at every level. A child of a
-- step that is neither a clause nor a group reaches tree_sql_clause and is refused there.
clause AS (
  SELECT c.parent_id AS step, c.node_id AS id,
         tree_sql_clause(c.kind, c.value, c.op, c.arg, s.alias, cfg.attr_cols, cfg.has_map, cfg.p, cfg.elem) AS txt
  FROM n c JOIN n s ON s.node_id = c.parent_id AND s.kind = 'step' CROSS JOIN cfg
  WHERE c.kind NOT IN ('has', 'not', 'step')),
-- Each pass is two CTEs: the first gathers a group's inner chain into one list column, the second
-- renders it. They cannot be one, because tree_sql_chain's lambda may not be handed an aggregate
-- or a subquery -- only a column.
stepA AS (
  SELECT s.node_id, s.parent_id, s.op, s.alias,
         COALESCE((SELECT string_agg(x.txt, ' AND ' ORDER BY x.id) FROM clause x WHERE x.step = s.node_id), 'true') AS pred
  FROM n s WHERE s.kind = 'step'),
grpA0 AS (
  SELECT g.node_id, g.parent_id, g.kind, a.alias AS anchor,
         list({node_id: x.node_id, alias: x.alias, op: x.op, pred: x.pred} ORDER BY x.node_id) AS steps
  FROM n g JOIN n a ON a.node_id = g.parent_id JOIN stepA x ON x.parent_id = g.node_id
  WHERE g.kind IN ('has', 'not') GROUP BY g.node_id, g.parent_id, g.kind, a.alias),
grpA AS (
  SELECT g.node_id, g.parent_id, CASE WHEN g.kind = 'not' THEN 'NOT ' ELSE '' END
         || 'EXISTS (SELECT 1 FROM ' || tree_sql_chain(cfg.p, g.steps, g.anchor, cfg.elem) || ')' AS txt
  FROM grpA0 g CROSS JOIN cfg),
partB AS (SELECT step, id, txt FROM clause UNION ALL SELECT g.parent_id, g.node_id, g.txt FROM grpA g),
stepB AS (
  SELECT s.node_id, s.parent_id, s.op, s.alias,
         COALESCE((SELECT string_agg(x.txt, ' AND ' ORDER BY x.id) FROM partB x WHERE x.step = s.node_id), 'true') AS pred
  FROM n s WHERE s.kind = 'step'),
grpB0 AS (
  SELECT g.node_id, g.parent_id, g.kind, a.alias AS anchor,
         list({node_id: x.node_id, alias: x.alias, op: x.op, pred: x.pred} ORDER BY x.node_id) AS steps
  FROM n g JOIN n a ON a.node_id = g.parent_id JOIN stepB x ON x.parent_id = g.node_id
  WHERE g.kind IN ('has', 'not') GROUP BY g.node_id, g.parent_id, g.kind, a.alias),
grpB AS (
  SELECT g.node_id, g.parent_id, CASE WHEN g.kind = 'not' THEN 'NOT ' ELSE '' END
         || 'EXISTS (SELECT 1 FROM ' || tree_sql_chain(cfg.p, g.steps, g.anchor, cfg.elem) || ')' AS txt
  FROM grpB0 g CROSS JOIN cfg),
partC AS (SELECT step, id, txt FROM clause UNION ALL SELECT g.parent_id, g.node_id, g.txt FROM grpB g),
stepC AS (
  SELECT s.node_id, s.parent_id, s.op, s.alias,
         COALESCE((SELECT string_agg(x.txt, ' AND ' ORDER BY x.id) FROM partC x WHERE x.step = s.node_id), 'true') AS pred
  FROM n s WHERE s.kind = 'step'),
-- the outer chain: the steps whose parent is the selector root, which is where the fold stops
top AS (SELECT x.* FROM stepC x JOIN n r ON r.node_id = x.parent_id AND r.kind = 'selector'),
top0 AS (
  SELECT list({node_id: node_id, alias: alias, op: op, pred: pred} ORDER BY node_id) AS steps,
         max(alias) FILTER (WHERE node_id = (SELECT max(node_id) FROM top)) AS subject,
         list(alias ORDER BY node_id) FILTER (WHERE alias <> 's' || node_id) AS captures
  FROM top),
out AS (
  -- list() over no rows is NULL, and a selector with no steps is chk's to refuse in its own
  -- words: chk and this CTE are not ordered against each other, so tree_sql_chain's empty-group
  -- refusal must not get there first. Aggregating without GROUP BY keeps the one row either way.
  SELECT CASE WHEN g.steps IS NULL THEN NULL ELSE tree_sql_chain(cfg.p, g.steps, NULL, cfg.elem) END AS from_sql,
         g.subject, g.captures
  FROM top0 g CROSS JOIN cfg)
SELECT CASE WHEN NOT (SELECT ok FROM chk) OR NOT (SELECT bool_and(ok) FROM n) THEN NULL ELSE
  'SELECT ' || subject || '.* EXCLUDE (' || list_aggregate(tree_canonical_columns(), 'string_agg', ', ') || ')'
  || COALESCE(', ' || list_aggregate(list_transform(list_filter(captures, lambda a: a <> subject), lambda a: a || ' AS ' || a), 'string_agg', ', '), '')
  -- the language the selector was WRITTEN in, which only the caller knows. Not read from
  -- tree_catalog.settings: that row says how the runner parses selector text, and a selector
  -- handed over as IR was never parsed at all.
  || ', ' || tree_sql_lit(sch || '.' || nm) || ' AS _match_tree, ' || tree_sql_lit(COALESCE(language, 'treeql')) || ' AS _match_language, '
  || (SELECT count(*) FROM n WHERE kind = 'pseudo_unknown') || ' AS _match_unknown_pseudos'
  || ' FROM ' || from_sql END
FROM out);
