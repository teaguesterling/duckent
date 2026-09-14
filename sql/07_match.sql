-- sql/07_match.sql
CREATE OR REPLACE MACRO tree_canonical_columns() AS
  ['_root', '_pre', '_level', '_parent', '_size', '_children', '_next', '_type', '_id', '_classes', '_attr_map', '_pseudo'];

-- Structural predicate between the previous step alias a and this step alias b. MN14 mutates this to drop the root equality.
CREATE OR REPLACE MACRO tree_sql_comb(op, a, b) AS
  CASE op
    WHEN 'desc'  THEN b || '._root = ' || a || '._root AND ' || b || '._pre BETWEEN ' || a || '._pre + 1 AND ' || a || '._pre + ' || a || '._size'
    WHEN 'child' THEN b || '._root = ' || a || '._root AND ' || b || '._parent = ' || a || '._pre'
    WHEN 'next'  THEN b || '._root = ' || a || '._root AND ' || b || '._parent = ' || a || '._parent AND ' || b || '._pre = ' || a || '._pre + ' || a || '._size + 1'
    WHEN 'after' THEN b || '._root = ' || a || '._root AND ' || b || '._parent = ' || a || '._parent AND ' || b || '._pre > ' || a || '._pre'
    ELSE error('tree_match: unknown combinator ' || op) END;

-- Clause predicate with § for the step alias. Attribute and pseudo filters are NULL-definite. MN19 mutates the where branch.
CREATE OR REPLACE MACRO tree_sql_clause(kind, value, op, arg) AS
  CASE kind
    WHEN 'type'   THEN '§._type = ' || tree_sql_lit(value)
    WHEN 'id'     THEN '§._id = ' || tree_sql_lit(value)
    WHEN 'class'  THEN 'COALESCE(list_contains(§._classes, ' || tree_sql_lit(value) || '), false)'
    WHEN 'pseudo' THEN 'COALESCE(§._pseudo[' || tree_sql_lit(value) || '], false)'
    WHEN 'attr'   THEN 'COALESCE(§.' || tree_sql_ident(value) || ' ' || op || ' ' || arg || ', false)'
    -- One level only: recursive := true flattens _root's struct into its component columns, so
    -- _root itself stops being addressable and falls through to an enclosing step alias
    -- (ambiguous, or worse, silently the wrong row). Unqualified names resolve to this step's
    -- own row first; another step's alias is legal when qualified (spec 6.2).
    WHEN 'where'  THEN 'EXISTS (SELECT 1 FROM (SELECT unnest(§, recursive := false)) __w WHERE ' || value || ')'
    WHEN 'pseudo_unknown' THEN 'false'
    ELSE error('tree_match: unknown clause kind ' || kind) END;

CREATE OR REPLACE MACRO tree_compile_match(sch, nm, sel, semantic := NULL) AS (
WITH t AS (
  SELECT tr.profile, tr.has_semantic OR semantic IS NOT NULL AS has_semantic,
         (SELECT list(name) FROM tree_catalog.pseudo_classes p WHERE p.database_name = current_database() AND p.schema_name = sch AND p.tree_name = nm) AS known_pseudos
  FROM tree_catalog.trees tr WHERE tr.database_name = current_database() AND tr.schema_name = sch AND tr.tree_name = nm),
chk AS (SELECT CASE WHEN (SELECT count(*) FROM t) = 0 THEN error('tree_match: tree ' || sch || '.' || nm || ' not found') ELSE true END AS ok),
proj AS (
  SELECT CASE WHEN semantic IS NULL THEN 'tree_catalog.' || tree_sql_object_name('proj', sch, nm) || '()'
    ELSE '(SELECT * REPLACE (' || list_aggregate(list_filter([
        (semantic).type || ' AS _type', (semantic).id || ' AS _id', (semantic).classes || ' AS _classes', (semantic).attr_map || ' AS _attr_map',
        CASE WHEN (semantic).pseudo IS NULL THEN NULL ELSE tree_sql_pseudo_map(semantic) || ' AS _pseudo' END], lambda x: x IS NOT NULL), 'string_agg', ', ')
      || ') FROM tree_catalog.' || tree_sql_object_name('proj', sch, nm) || '())' END AS p),
-- IR rows; S clauses refused on S-less trees; unknown pseudo-classes marked; sibling combinators refused under sibling_free
n AS (
  SELECT node_id, parent_id,
         CASE WHEN kind = 'pseudo' AND NOT list_contains(COALESCE((SELECT known_pseudos FROM t), []), value)
                   AND (semantic IS NULL OR NOT list_contains(list_transform(COALESCE((semantic).pseudo, []), lambda x: (x).name), value)) THEN 'pseudo_unknown' ELSE kind END AS kind,
         value, op, arg, COALESCE(alias, 's' || node_id) AS alias,
         CASE WHEN kind IN ('type', 'id', 'class', 'attr', 'pseudo') AND NOT (SELECT has_semantic FROM t)
              THEN error('tree_match: tree ' || sch || '.' || nm || ' has no SEMANTIC group; only combinators and WHERE are available. Add one with tree_ddl_alter or pass semantic :=')
              WHEN kind = 'step' AND op IN ('next', 'after') AND (SELECT profile FROM t) = 'sibling_free'
              THEN error('tree_match: tree ' || sch || '.' || nm || ' is sibling-free (no SIBLING_ORDER declared); SIBLING and FOLLOWING are unavailable')
              ELSE true END AS ok
  FROM (SELECT unnest(sel, recursive := true))),
steps AS (
  SELECT s.node_id, s.op, s.alias,
         COALESCE((SELECT string_agg(replace(tree_sql_clause(c.kind, c.value, c.op, c.arg), '§', s.alias), ' AND ' ORDER BY c.node_id) FROM n c WHERE c.parent_id = s.node_id), 'true') AS pred,
         lag(s.alias) OVER (ORDER BY s.node_id) AS prev_alias,
         row_number() OVER (ORDER BY s.node_id) AS rn,
         count(*) OVER () AS n_steps
  FROM n s WHERE s.kind = 'step'),
chain AS (
  SELECT string_agg(
           CASE WHEN rn = 1 THEN (SELECT p FROM proj) || ' ' || alias
                ELSE 'JOIN ' || (SELECT p FROM proj) || ' ' || alias || ' ON ' || tree_sql_comb(op, prev_alias, alias) || ' AND (' || pred || ')' END,
           ' ' ORDER BY node_id) AS from_sql,
         max(CASE WHEN rn = 1 THEN pred END) AS first_pred,
         max(CASE WHEN rn = n_steps THEN alias END) AS subject,
         list(alias ORDER BY node_id) FILTER (WHERE alias NOT LIKE 's%' OR alias <> 's' || node_id) AS captures
  FROM steps)
SELECT CASE WHEN NOT (SELECT ok FROM chk) OR NOT (SELECT bool_and(ok) FROM n) THEN NULL ELSE
  'SELECT ' || subject || '.* EXCLUDE (' || list_aggregate(tree_canonical_columns(), 'string_agg', ', ') || ')'
  || COALESCE(', ' || list_aggregate(list_transform(list_filter(captures, lambda a: a <> subject), lambda a: a || ' AS ' || a), 'string_agg', ', '), '')
  || ', ' || tree_sql_lit(sch || '.' || nm) || ' AS _match_tree, ''treeql'' AS _match_language, '
  || (SELECT count(*) FROM n WHERE kind = 'pseudo_unknown') || ' AS _match_unknown_pseudos'
  || ' FROM ' || from_sql || ' WHERE ' || first_pred END
FROM chain);

CREATE OR REPLACE MACRO tree_explain(sch, nm, sel, semantic := NULL) AS
  {treeql: tree_selector_to_treeql(sel), sql: tree_compile_match(sch, nm, sel, semantic := semantic)};
