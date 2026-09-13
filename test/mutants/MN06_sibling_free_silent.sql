-- test/mutants/MN06_sibling_free_silent.sql
-- Sibling combinators silently no-op under the sibling-free profile: 'next'/'after'
-- compile to a comparison that never raises (they still combine into a predicate,
-- just not a useful one), and the refusal branch in tree_compile_match is removed
-- so the compiler never objects to using them on a sibling-free tree.
CREATE OR REPLACE MACRO tree_sql_comb(op, a, b) AS
  CASE op
    WHEN 'desc'  THEN b || '._root = ' || a || '._root AND ' || b || '._pre BETWEEN ' || a || '._pre + 1 AND ' || a || '._pre + ' || a || '._size'
    WHEN 'child' THEN b || '._root = ' || a || '._root AND ' || b || '._parent = ' || a || '._pre'
    ELSE 'false' END;

-- Copied from sql/07_match.sql with the
--   WHEN kind = 'step' AND op IN ('next', 'after') AND (SELECT profile FROM t) = 'sibling_free' ...
-- refusal branch removed from the n CTE's CASE.
CREATE OR REPLACE MACRO tree_compile_match(sch, nm, sel, semantic := NULL) AS (
WITH t AS (
  SELECT tr.profile, tr.has_semantic OR semantic IS NOT NULL AS has_semantic,
         (SELECT list(name) FROM tree_catalog.pseudo_classes p WHERE p.database_name = current_database() AND p.schema_name = sch AND p.tree_name = nm) AS known_pseudos
  FROM tree_catalog.trees tr WHERE tr.database_name = current_database() AND tr.schema_name = sch AND tr.tree_name = nm),
chk AS (SELECT CASE WHEN (SELECT count(*) FROM t) = 0 THEN error('tree_match: tree ' || sch || '.' || nm || ' not found') ELSE true END AS ok),
proj AS (
  SELECT CASE WHEN semantic IS NULL THEN 'tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm) || '()'
    ELSE '(SELECT * REPLACE (' || list_aggregate(list_filter([
        (semantic).type || ' AS _type', (semantic).id || ' AS _id', (semantic).classes || ' AS _classes', (semantic).attr_map || ' AS _attr_map',
        CASE WHEN (semantic).pseudo IS NULL THEN NULL ELSE tree_sql_pseudo_map(semantic) || ' AS _pseudo' END], lambda x: x IS NOT NULL), 'string_agg', ', ')
      || ') FROM tree_catalog.' || tree_sql_ident('proj_' || sch || '_' || nm) || '())' END AS p),
-- IR rows; S clauses refused on S-less trees; unknown pseudo-classes marked
n AS (
  SELECT node_id, parent_id,
         CASE WHEN kind = 'pseudo' AND NOT list_contains(COALESCE((SELECT known_pseudos FROM t), []), value)
                   AND (semantic IS NULL OR NOT list_contains(list_transform(COALESCE((semantic).pseudo, []), lambda x: (x).name), value)) THEN 'pseudo_unknown' ELSE kind END AS kind,
         value, op, arg, COALESCE(alias, 's' || node_id) AS alias,
         CASE WHEN kind IN ('type', 'id', 'class', 'attr', 'pseudo') AND NOT (SELECT has_semantic FROM t)
              THEN error('tree_match: tree ' || sch || '.' || nm || ' has no SEMANTIC group; only combinators and WHERE are available. Add one with tree_ddl_alter or pass semantic :=')
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
