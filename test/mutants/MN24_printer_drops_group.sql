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
-- so the step it hangs off prints without it. This is a COPY, not a fragment override -- the
-- group text is built inline in each pass and there is no fragment for it -- so the copy is
-- GENERATED from sql/06_selector.sql by test/mutants/regen.py and cannot drift from it;
-- .control.sql is the same copy with the edit left out.
--
-- NOTE for the manifest: 40_corpus cannot see this. Its printed-TREEQL records compare
-- tree_selector_to_treeql(<ir>) against tree_explain(...).treeql, and BOTH sides go through
-- this same mutated printer, so the equality still holds. Only a record comparing the printed
-- text against a FROZEN literal catches it -- 34_groups and 38_css_lower have those.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/06_selector.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- Printer: one line per top-level step. A HAS/NOT group renders inline in its step's clause list
-- as `HAS ( <inner chain> )`, the inner chain being the same per-step rendering joined by single
-- spaces; ordering a step's parts by node_id puts the groups after the step's own clauses, since
-- the constructor numbers a step's clauses before its groups.
--
-- The render alternates two passes from the inside out, unrolled to tree_group_depth_limit() group
-- levels rather than recursed: `stepA` renders a step from its clauses alone (right for the
-- innermost steps, which have no groups), `grpA` renders each group from stepA (right for the
-- innermost groups), `stepB` adds the grpA text to a step's parts, and so on outwards -- only the
-- pass that is right for a level is ever read at that level. Raising tree_group_depth_limit() means
-- adding one stepN/grpN pair here. Because the unrolling is fixed, a selector nesting groups deeper
-- than the limit would silently lose its innermost groups, so it is refused instead; node kinds are
-- a whitelist for the same reason, so a kind this printer does not know refuses rather than
-- rendering as nothing.
--
-- 1.5.5: the passes are written out rather than factored into one level-parameterized macro pair.
-- Handing the rendered parts from such a macro to the next pass through CTE references trips a
-- binder bug -- INTERNAL Error: Failed to bind column reference: inequal types (INTEGER != BIGINT),
-- raised before the query runs -- so the copies stay until that is fixed.
CREATE OR REPLACE MACRO tree_selector_to_treeql(sel) AS (
  WITH n AS (SELECT unnest(sel, recursive := true)),
  -- COALESCE inside the aggregate, not outside it: `min(kind)` over a NULL-kind node is NULL,
  -- so the arm below read "IS NOT NULL" as "no bad kind" and the node was dropped instead of
  -- refused -- a guard that did not fire, the same family as the error(NULL) audit. NULL is
  -- named in the whitelist test too, since `kind NOT IN (...)` is NULL for a NULL kind.
  bad_kind AS (
    SELECT min(COALESCE(kind, '<NULL>')) AS k FROM n
    WHERE kind IS NULL
       OR kind NOT IN ('selector', 'step', 'has', 'not', 'type', 'id', 'class', 'attr', 'pseudo', 'where')),
  -- Node ids are the parent links, so a repeated one makes the parent relation a graph rather
  -- than a tree and the depth walk below a cycle. Refused before any walk is asked for.
  bad_dup AS (SELECT count(*) <> count(DISTINCT node_id) AS bad FROM n),
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
    -- the mutation: NOT groups render as nothing and vanish from their step
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
    -- the mutation: NOT groups render as nothing and vanish from their step
    FROM n g WHERE g.kind = 'has'),
  partC AS (SELECT step, id, t FROM clause UNION ALL SELECT g.parent_id, g.node_id, g.t FROM grpB g),
  stepC AS (
    SELECT s.node_id, s.parent_id, s.op, s.alias,
           (SELECT string_agg(p.t, ', ' ORDER BY p.id) FROM partC p WHERE p.step = s.node_id) AS body
    FROM n s WHERE s.kind = 'step')
  SELECT CASE
    WHEN (SELECT k FROM bad_kind) IS NOT NULL
      THEN tree_err('tree_selector_to_treeql: unknown node kind ' || (SELECT k FROM bad_kind))
    WHEN (SELECT bad FROM bad_dup)
      THEN tree_err('tree_selector_to_treeql: selector node ids are not unique')
    WHEN tree_selector_group_depth(sel) > tree_group_depth_limit()
      THEN tree_err('tree_selector_to_treeql: groups nested deeper than ' || tree_group_depth_limit() || ' levels are not supported')
    ELSE (SELECT string_agg(tree_treeql_step(op, body, alias), chr(10) ORDER BY node_id)
          FROM stepC WHERE parent_id IN (SELECT node_id FROM n WHERE kind = 'selector')) END);
