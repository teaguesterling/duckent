-- sql/07_match.sql
CREATE OR REPLACE MACRO tree_canonical_columns() AS
  ['_root', '_pre', '_level', '_parent', '_size', '_children', '_next', '_type', '_id', '_classes', '_attr_map', '_element', '_pseudo'];

-- One fragment per relation, each the single definition shared by combinators, groups and traversal.
-- a and b are step aliases; p is the projection relation text (needed where a third row is scanned);
-- elem says whether the tree declares ELEMENT, in which case the sibling and positional relations
-- must scan for the nearest *element* neighbour instead of using the O(1) pre/size arithmetic.
-- Every fragment is a pure expression with no SELECT of its own: sql/08_traversal.sql splices the
-- text into query(), which in DuckDB 1.5.5 only accepts text from macros whose body has no
-- SELECT or subquery.
CREATE OR REPLACE MACRO tree_sql_subtree(a, b) AS
  b || '._root = ' || a || '._root AND ' || b || '._pre BETWEEN ' || a || '._pre + 1 AND ' || a || '._pre + ' || a || '._size';
CREATE OR REPLACE MACRO tree_sql_children(a, b) AS
  b || '._root = ' || a || '._root AND ' || b || '._parent = ' || a || '._pre';
CREATE OR REPLACE MACRO tree_sql_parent(a, b) AS
  b || '._root = ' || a || '._root AND ' || b || '._pre = ' || a || '._parent';
-- Ancestors are the subtree relation read backwards: b contains a. No recursion (I1).
CREATE OR REPLACE MACRO tree_sql_ancestors(a, b) AS tree_sql_subtree(b, a);
-- IS NOT DISTINCT FROM, not =: the level-0 rows of a partition all have a NULL parent
-- and are siblings of each other, which = would silently deny.
CREATE OR REPLACE MACRO tree_sql_siblings(a, b) AS
  b || '._root = ' || a || '._root AND ' || b || '._parent IS NOT DISTINCT FROM ' || a || '._parent AND ' || b || '._pre <> ' || a || '._pre';
-- Sibling relations see element rows only (spec D-N18), so the target row carries '_element'
-- unconditionally. On a tree with no ELEMENT declared _element is true on every row, so the
-- extra conjunct costs nothing and the text is still right.
CREATE OR REPLACE MACRO tree_sql_after(a, b) AS
  tree_sql_siblings(a, b) || ' AND ' || b || '._pre > ' || a || '._pre AND ' || b || '._element';
CREATE OR REPLACE MACRO tree_sql_before(a, b) AS
  tree_sql_siblings(a, b) || ' AND ' || b || '._pre < ' || a || '._pre AND ' || b || '._element';
CREATE OR REPLACE MACRO tree_sql_next_sibling(a, b, p, elem) AS
  CASE WHEN elem THEN tree_sql_after(a, b) || ' AND NOT EXISTS (SELECT 1 FROM ' || p || ' __c WHERE ' || tree_sql_siblings(a, '__c')
                        || ' AND __c._pre > ' || a || '._pre AND __c._pre < ' || b || '._pre AND __c._element)'
       ELSE tree_sql_siblings(a, b) || ' AND ' || b || '._pre = ' || a || '._pre + ' || a || '._size + 1' END;
CREATE OR REPLACE MACRO tree_sql_prev_sibling(a, b, p, elem) AS
  CASE WHEN elem THEN tree_sql_before(a, b) || ' AND NOT EXISTS (SELECT 1 FROM ' || p || ' __c WHERE ' || tree_sql_siblings(a, '__c')
                        || ' AND __c._pre < ' || a || '._pre AND __c._pre > ' || b || '._pre AND __c._element)'
       ELSE tree_sql_siblings(a, b) || ' AND ' || a || '._pre = ' || b || '._pre + ' || b || '._size + 1' END;
-- Positional fragments constrain the row a alone: combine with tree_sql_children to anchor it.
CREATE OR REPLACE MACRO tree_sql_first_child(a, p, elem) AS
  CASE WHEN elem THEN a || '._element AND NOT EXISTS (SELECT 1 FROM ' || p || ' __c WHERE ' || tree_sql_siblings(a, '__c') || ' AND __c._pre < ' || a || '._pre AND __c._element)'
       ELSE a || '._pre = ' || a || '._parent + 1' END;
CREATE OR REPLACE MACRO tree_sql_last_child(a, p, elem) AS
  CASE WHEN elem THEN a || '._element AND NOT EXISTS (SELECT 1 FROM ' || p || ' __c WHERE ' || tree_sql_siblings(a, '__c') || ' AND __c._pre > ' || a || '._pre AND __c._element)'
       ELSE 'NOT EXISTS (SELECT 1 FROM ' || p || ' __c WHERE ' || tree_sql_siblings(a, '__c') || ' AND __c._pre > ' || a || '._pre)' END;
-- The root test. Named tree_sql_is_root, not tree_sql_root as the M2 design table has it:
-- sql/02_projection.sql already owns tree_sql_root(root_csv, qual) (the ROOT key expression),
-- and CREATE OR REPLACE MACRO on a different arity drops the existing overload rather than
-- adding to it, so the one-argument spelling would silently break every projection compile.
CREATE OR REPLACE MACRO tree_sql_is_root(a) AS a || '._level = 0';

-- Combinator between the previous step alias a and this step alias b. MN14 mutates
-- tree_sql_subtree/tree_sql_children to drop the root equality.
CREATE OR REPLACE MACRO tree_sql_comb(op, a, b, p, elem) AS
  CASE op
    WHEN 'desc'  THEN tree_sql_subtree(a, b)
    WHEN 'child' THEN tree_sql_children(a, b)
    WHEN 'next'  THEN tree_sql_next_sibling(a, b, p, elem)
    WHEN 'after' THEN tree_sql_after(a, b)
    ELSE error('tree_match: unknown combinator ' || op) END;

-- Clause predicate on the step alias, which is passed in: a placeholder substituted afterwards
-- would rewrite any user text that happened to contain it. Attribute and pseudo filters are
-- NULL-definite. MN19 mutates the where branch.
CREATE OR REPLACE MACRO tree_sql_clause(kind, value, op, arg, alias) AS
  CASE kind
    WHEN 'type'   THEN alias || '._type = ' || tree_sql_lit(value)
    WHEN 'id'     THEN alias || '._id = ' || tree_sql_lit(value)
    WHEN 'class'  THEN 'COALESCE(list_contains(' || alias || '._classes, ' || tree_sql_lit(value) || '), false)'
    WHEN 'pseudo' THEN 'COALESCE(' || alias || '._pseudo[' || tree_sql_lit(value) || '], false)'
    WHEN 'attr'   THEN 'COALESCE(' || alias || '.' || tree_sql_ident(value) || ' ' || op || ' ' || arg || ', false)'
    -- One level only: recursive := true flattens _root's struct into its component columns, so
    -- _root itself stops being addressable and falls through to an enclosing step alias
    -- (ambiguous, or worse, silently the wrong row). Unqualified names resolve to this step's
    -- own row first; another step's alias is legal when qualified (spec 6.2).
    WHEN 'where'  THEN 'EXISTS (SELECT 1 FROM (SELECT unnest(' || alias || ', recursive := false)) __w WHERE ' || value || ')'
    WHEN 'pseudo_unknown' THEN 'false'
    ELSE error('tree_match: unknown clause kind ' || kind) END;

CREATE OR REPLACE MACRO tree_compile_match(sch, nm, sel, semantic := NULL) AS (
WITH t AS (
  SELECT tr.profile, tr.has_semantic OR semantic IS NOT NULL AS has_semantic,
         (SELECT list(name) FROM tree_catalog.pseudo_classes p WHERE p.database_name = current_database() AND p.schema_name = sch AND p.tree_name = nm) AS known_pseudos,
         -- whether any row can be a non-element: only then must the sibling fragments scan for
         -- the nearest element neighbour instead of using the O(1) pre/size form
         EXISTS (SELECT 1 FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND s.slot = 'ELEMENT')
           OR (semantic).element IS NOT NULL AS has_element
  FROM tree_catalog.trees tr WHERE tr.database_name = current_database() AND tr.schema_name = sch AND tr.tree_name = nm),
chk AS (SELECT CASE
  WHEN (SELECT count(*) FROM t) = 0 THEN error('tree_match: tree ' || sch || '.' || nm || ' not found')
  -- an overlay is an S group for this query only; it cannot widen the projection, and an
  -- overlay that sets nothing (or a selector with no steps) used to compile to NULL
  WHEN (semantic).attr IS NOT NULL THEN error('tree_match: a per-query SEMANTIC overlay cannot add attribute columns; use tree_ddl_alter')
  WHEN semantic IS NOT NULL AND (semantic).type IS NULL AND (semantic).id IS NULL AND (semantic).classes IS NULL
       AND (semantic).attr_map IS NULL AND (semantic).pseudo IS NULL THEN error('tree_match: semantic overlay is empty')
  WHEN (SELECT count(*) FROM (SELECT unnest(sel, recursive := true)) WHERE kind = 'step') = 0 THEN error('tree_match: selector has no steps')
  ELSE true END AS ok),
proj AS (
  SELECT CASE WHEN semantic IS NULL THEN 'tree_catalog.' || tree_sql_object_name('proj', sch, nm) || '()'
    ELSE '(SELECT * REPLACE (' || list_aggregate(list_filter([
        (semantic).type || ' AS _type', (semantic).id || ' AS _id', (semantic).classes || ' AS _classes', (semantic).attr_map || ' AS _attr_map',
        -- map_concat, not replace: the catalog's pseudo-classes stay bound, the overlay's
        -- entries are added, and the overlay (the second argument) wins on a shared name
        CASE WHEN (semantic).pseudo IS NULL THEN NULL ELSE 'map_concat(_pseudo, ' || tree_sql_pseudo_map(semantic) || ') AS _pseudo' END], lambda x: x IS NOT NULL), 'string_agg', ', ')
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
         COALESCE((SELECT string_agg(tree_sql_clause(c.kind, c.value, c.op, c.arg, s.alias), ' AND ' ORDER BY c.node_id) FROM n c WHERE c.parent_id = s.node_id), 'true') AS pred,
         lag(s.alias) OVER (ORDER BY s.node_id) AS prev_alias,
         row_number() OVER (ORDER BY s.node_id) AS rn,
         count(*) OVER () AS n_steps
  FROM n s WHERE s.kind = 'step'),
chain AS (
  SELECT string_agg(
           CASE WHEN rn = 1 THEN (SELECT p FROM proj) || ' ' || alias
                ELSE 'JOIN ' || (SELECT p FROM proj) || ' ' || alias || ' ON ' || tree_sql_comb(op, prev_alias, alias, (SELECT p FROM proj), (SELECT has_element FROM t)) || ' AND (' || pred || ')' END,
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
