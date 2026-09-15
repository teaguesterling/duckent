-- test/mutants/MN24_printer_drops_group.sql
-- The printer renders HAS groups and silently drops NOT groups, so `.fn:not(:has(string))` and
-- `.fn` print as the same canonical TREEQL. The printed form is what a caller reads back, what
-- tree_explain reports and what a round-trip through another front-end is compared against, so
-- a printer that omits a part of the selector makes two different selectors indistinguishable
-- on the page while they still match different rows.
--
-- Copied from sql/06_selector.sql's tree_selector_to_treeql with one edit, applied to both
-- unrolled passes: grpA and grpB read `WHERE g.kind IN ('has', 'not')` in the base and
-- `WHERE g.kind = 'has'` here. A group with no rendered text contributes nothing to partB/partC,
-- so the step it hangs off prints without it. Comments trimmed to the passes they explain.
--
-- NOTE for the manifest: 40_corpus cannot see this. Its printed-TREEQL records compare
-- tree_selector_to_treeql(<ir>) against tree_explain(...).treeql, and BOTH sides go through
-- this same mutated printer, so the equality still holds. Only a record comparing the printed
-- text against a FROZEN literal catches it -- 34_groups and 38_css_lower have those.
CREATE OR REPLACE MACRO tree_selector_to_treeql(sel) AS (
  WITH n AS (SELECT unnest(sel, recursive := true)),
  bad_kind AS (
    SELECT min(kind) AS k FROM n
    WHERE kind NOT IN ('selector', 'step', 'has', 'not', 'type', 'id', 'class', 'attr', 'pseudo', 'where')),
  -- (step node id, part node id, part text) for every clause: the same at every level
  clause AS (
    SELECT c.parent_id AS step, c.node_id AS id, tree_treeql_clause(c.kind, c.value, c.op, c.arg) AS t
    FROM n c WHERE c.kind IN ('type', 'id', 'class', 'attr', 'pseudo', 'where')),
  stepA AS (
    SELECT s.node_id, s.parent_id, s.op, s.alias,
           (SELECT string_agg(p.t, ', ' ORDER BY p.id) FROM clause p WHERE p.step = s.node_id) AS body
    FROM n s WHERE s.kind = 'step'),
  grpA AS (
    SELECT g.node_id, g.parent_id, upper(g.kind) || ' ( '
             || (SELECT string_agg(tree_treeql_step(x.op, x.body, x.alias), ' ' ORDER BY x.node_id)
                 FROM stepA x WHERE x.parent_id = g.node_id) || ' )' AS t
    -- THE MUTATION: NOT groups render to nothing
  FROM n g WHERE g.kind = 'has'),
  partB AS (SELECT step, id, t FROM clause UNION ALL SELECT g.parent_id, g.node_id, g.t FROM grpA g),
  stepB AS (
    SELECT s.node_id, s.parent_id, s.op, s.alias,
           (SELECT string_agg(p.t, ', ' ORDER BY p.id) FROM partB p WHERE p.step = s.node_id) AS body
    FROM n s WHERE s.kind = 'step'),
  grpB AS (
    SELECT g.node_id, g.parent_id, upper(g.kind) || ' ( '
             || (SELECT string_agg(tree_treeql_step(x.op, x.body, x.alias), ' ' ORDER BY x.node_id)
                 FROM stepB x WHERE x.parent_id = g.node_id) || ' )' AS t
    -- THE MUTATION: NOT groups render to nothing
  FROM n g WHERE g.kind = 'has'),
  partC AS (SELECT step, id, t FROM clause UNION ALL SELECT g.parent_id, g.node_id, g.t FROM grpB g),
  stepC AS (
    SELECT s.node_id, s.parent_id, s.op, s.alias,
           (SELECT string_agg(p.t, ', ' ORDER BY p.id) FROM partC p WHERE p.step = s.node_id) AS body
    FROM n s WHERE s.kind = 'step')
  SELECT CASE
    WHEN (SELECT k FROM bad_kind) IS NOT NULL
      THEN error('tree_selector_to_treeql: unknown node kind ' || (SELECT k FROM bad_kind))
    WHEN tree_selector_group_depth(sel) > tree_group_depth_limit()
      THEN error('tree_selector_to_treeql: groups nested deeper than ' || tree_group_depth_limit() || ' levels are not supported')
    ELSE (SELECT string_agg(tree_treeql_step(op, body, alias), chr(10) ORDER BY node_id)
          FROM stepC WHERE parent_id IN (SELECT node_id FROM n WHERE kind = 'selector')) END);
