-- sql/06_selector.sql

-- Normalize any list of step structs to one fixed shape so missing fields read as NULL, and
-- emit the selector IR: node 0 is the `selector` root, every step is its child, every clause a
-- child of its step, and a HAS/NOT group is a `has`/`not` child of its step whose own children
-- are the group's inner steps. Groups nest two deep (three literal step levels), which is what
-- TREE_STEP_L2 spells out; the ceiling is in the type, not in a recursion.
--
-- Node ids are dense and increase in document order: the outer chain (each step followed by its
-- clauses), then each depth-1 group node followed by its inner chain, then the depth-2 ones. The
-- ordering is carried as a `path` struct -- 1.5.5 orders and compares a STRUCT field by field,
-- so one column is the whole (depth, step index, group, inner index, ...) sort key -- and a row's
-- `ppath` is its parent's path, which is all the parent link needs: parents always carry sub = 0.
--
-- Refusals guard the normalization: the cast to the fixed shapes drops fields the shapes do
-- not name (a typo would silently do nothing), so the keys are enumerated first with json_keys --
-- at every level, since a group's steps are cast the same way -- and checked against the allowed
-- set; an ATTR text the operator regex cannot parse would yield empty name/op/arg, so it refuses
-- naming the text; and a capture inside a group has no row of its own to bind.
-- 1.5.5 note: a list literal of structs unifies its element types, filling missing fields
-- with NULL, so json_keys(to_json(s)) returns the same unified key set for every step -- which
-- is what the check wants: one unknown field anywhere in the list is caught.
CREATE OR REPLACE MACRO tree_steps(steps) AS (
  WITH
  -- the steps of each literal level, with the document-order path of each
  lvl0 AS (SELECT generate_subscripts(steps, 1)::INTEGER AS i0, unnest(steps::TREE_STEP_L2[]) AS s),
  grp1 AS (SELECT i0, 1 AS g1, 'has' AS gkind, (s).has AS kids FROM lvl0 WHERE (s).has IS NOT NULL
           UNION ALL SELECT i0, 2, 'not', (s)."not" FROM lvl0 WHERE (s)."not" IS NOT NULL),
  lvl1 AS (SELECT i0, g1, generate_subscripts(kids, 1)::INTEGER AS i1, unnest(kids) AS s FROM grp1),
  grp2 AS (SELECT i0, g1, i1, 1 AS g2, 'has' AS gkind, (s).has AS kids FROM lvl1 WHERE (s).has IS NOT NULL
           UNION ALL SELECT i0, g1, i1, 2, 'not', (s)."not" FROM lvl1 WHERE (s)."not" IS NOT NULL),
  lvl2 AS (SELECT i0, g1, i1, g2, generate_subscripts(kids, 1)::INTEGER AS i2, unnest(kids) AS s FROM grp2),
  -- every step at every level as one relation: its path, its parent's path, its fields. The first
  -- step of the outer chain has no combinator; the first step of a group's chain defaults to desc
  -- like any later step, so a group's chain always starts from a combinator the compiler can read.
  allsteps AS (
    SELECT {d: 0, i0: i0, g1: 0, i1: 0, g2: 0, i2: 0} AS path,
           {d: -1, i0: 0, g1: 0, i1: 0, g2: 0, i2: 0} AS ppath, 0 AS depth,
           CASE WHEN i0 = 1 THEN NULL ELSE COALESCE((s).comb, 'desc') END AS op,
           (s).type AS type, (s).id AS id, (s).class AS class, (s).attr AS attr,
           (s).pseudo AS pseudo, (s)."where" AS "where", (s)."as" AS "as"
    FROM lvl0
    UNION ALL
    SELECT {d: 1, i0: i0, g1: g1, i1: i1, g2: 0, i2: 0},
           {d: 1, i0: i0, g1: g1, i1: 0, g2: 0, i2: 0}, 1,
           COALESCE((s).comb, 'desc'),
           (s).type, (s).id, (s).class, (s).attr, (s).pseudo, (s)."where", (s)."as"
    FROM lvl1
    UNION ALL
    SELECT {d: 2, i0: i0, g1: g1, i1: i1, g2: g2, i2: i2},
           {d: 2, i0: i0, g1: g1, i1: i1, g2: g2, i2: 0}, 2,
           COALESCE((s).comb, 'desc'),
           (s).type, (s).id, (s).class, (s).attr, (s).pseudo, (s)."where", (s)."as"
    FROM lvl2),
  -- the group nodes: a depth-1 group hangs off its outer step, a depth-2 group off its inner step
  allgrp AS (
    SELECT {d: 1, i0: i0, g1: g1, i1: 0, g2: 0, i2: 0} AS path,
           {d: 0, i0: i0, g1: 0, i1: 0, g2: 0, i2: 0} AS ppath, gkind FROM grp1
    UNION ALL
    SELECT {d: 2, i0: i0, g1: g1, i1: i1, g2: g2, i2: 0},
           {d: 1, i0: i0, g1: g1, i1: i1, g2: 0, i2: 0}, gkind FROM grp2),
  -- the untyped input as one JSON object per step at every level, for the unknown-field check.
  -- json_extract with a wildcard path returns a JSON[], empty for a path no step has, so the six
  -- nested paths cost nothing when there are no groups. 1.5.5: a cross join between two CTEs that
  -- unnest inside a macro body binds as a correlated UNNEST and is refused, so the paths are
  -- concatenated into one list instead of joined against a CTE of paths.
  jall AS (SELECT unnest(
      json_extract(to_json(steps), '$[*]')
      || json_extract(to_json(steps), '$[*].has[*]')
      || json_extract(to_json(steps), '$[*].not[*]')
      || json_extract(to_json(steps), '$[*].has[*].has[*]')
      || json_extract(to_json(steps), '$[*].has[*].not[*]')
      || json_extract(to_json(steps), '$[*].not[*].has[*]')
      || json_extract(to_json(steps), '$[*].not[*].not[*]')) AS j),
  bad_key AS (
    SELECT min(k) AS k FROM (SELECT unnest(json_keys(j)) AS k FROM jall)
    WHERE k NOT IN ('comb', 'type', 'id', 'class', 'attr', 'pseudo', 'where', 'as', 'has', 'not')),
  bad_capture AS (
    SELECT min(a."as") AS a FROM allsteps a WHERE a.depth > 0 AND a."as" IS NOT NULL),
  bad_alias AS (
    SELECT min(a."as") AS a FROM allsteps a WHERE a."as" IS NOT NULL AND regexp_matches(a."as", '^s[0-9]+$')),
  bad_attr AS (
    SELECT min(a.attr) AS a FROM allsteps a WHERE a.attr IS NOT NULL
      AND NOT regexp_matches(a.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$')),
  nodes AS (
    -- the root: a ppath no row carries, so the parent join leaves its parent_id NULL
    SELECT {d: -1, i0: 0, g1: 0, i1: 0, g2: 0, i2: 0} AS path, 0 AS sub,
           {d: -2, i0: 0, g1: 0, i1: 0, g2: 0, i2: 0} AS ppath,
           'selector' AS kind, NULL::VARCHAR AS value, NULL::VARCHAR AS op, NULL::VARCHAR AS arg, NULL::VARCHAR AS alias
    UNION ALL SELECT g.path, 0, g.ppath, g.gkind, NULL, NULL, NULL, NULL FROM allgrp g
    UNION ALL SELECT a.path, 0, a.ppath, 'step', NULL, a.op, NULL, a."as" FROM allsteps a
    UNION ALL SELECT a.path, 1, a.path, 'type', a.type, NULL, NULL, NULL FROM allsteps a WHERE a.type IS NOT NULL
    UNION ALL SELECT a.path, 2, a.path, 'id', a.id, NULL, NULL, NULL FROM allsteps a WHERE a.id IS NOT NULL
    UNION ALL SELECT a.path, 3, a.path, 'class', a.class, NULL, NULL, NULL FROM allsteps a WHERE a.class IS NOT NULL
    UNION ALL SELECT a.path, 4, a.path, 'attr',
        regexp_extract(a.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 1),
        regexp_extract(a.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 2),
        regexp_extract(a.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 3), NULL
      FROM allsteps a WHERE a.attr IS NOT NULL
    UNION ALL SELECT a.path, 5, a.path, 'pseudo', a.pseudo, NULL, NULL, NULL FROM allsteps a WHERE a.pseudo IS NOT NULL
    UNION ALL SELECT a.path, 6, a.path, 'where', a."where", NULL, NULL, NULL FROM allsteps a WHERE a."where" IS NOT NULL),
  numbered AS (SELECT CAST(row_number() OVER (ORDER BY path, sub) - 1 AS INTEGER) AS node_id, * FROM nodes),
  parented AS (
    SELECT n.node_id, p.node_id AS parent_id, n.kind, n.value, n.op, n.arg, n.alias
    FROM numbered n LEFT JOIN numbered p ON p.path = n.ppath AND p.sub = 0)
  SELECT CASE
    WHEN (SELECT k FROM bad_key) IS NOT NULL THEN error('tree_steps: unknown step field ' || (SELECT k FROM bad_key))
    -- a step inside HAS/NOT is a test, not a row of the result, so there is nothing to name
    WHEN (SELECT a FROM bad_capture) IS NOT NULL THEN error('tree_steps: capture inside HAS/NOT has no row to bind')
    WHEN (SELECT a FROM bad_attr) IS NOT NULL THEN error('tree_steps: cannot parse ATTR clause: ' || (SELECT a FROM bad_attr))
    -- s<N> is what the match compiler names step N when the user names nothing; a user
    -- alias of that shape would collide with another step's generated alias
    WHEN (SELECT a FROM bad_alias) IS NOT NULL THEN error('tree_steps: alias ' || (SELECT a FROM bad_alias) || ' is reserved for generated step aliases')
    ELSE list({node_id: node_id, parent_id: parent_id, kind: kind, value: value, op: op, arg: arg, alias: alias} ORDER BY node_id)::TREE_SELECTOR END
  FROM parented);

-- Splice an already built inner selector under the step of `sel` aliased `step_alias` as a
-- `kind` ('has' | 'not') group. The inner selector's own root is dropped and its rows are shifted
-- by max(node_id) + 1, which is the new group node's id -- so the shift re-parents the inner
-- chain's top-level steps (parent 0 in `inner`) onto the group node with no special case. Only
-- the first step of a chain can carry a NULL op, so COALESCE alone applies the desc default.
-- 1.5.5: `inner` is a reserved word, so the parameter is spelled quoted; the name is still
-- `inner` for a named-argument call.
CREATE OR REPLACE MACRO tree_steps_group(sel, step_alias, kind, "inner") AS (
  WITH s AS (SELECT unnest(sel::TREE_SELECTOR) AS r),
  i AS (SELECT unnest("inner"::TREE_SELECTOR) AS r),
  target AS (SELECT min((r).node_id) AS node_id FROM s WHERE (r).kind = 'step' AND (r).alias = step_alias),
  base AS (SELECT max((r).node_id) + 1 AS g FROM s)
  SELECT CASE
    WHEN (SELECT node_id FROM target) IS NULL THEN error('tree_steps_group: no step aliased ' || step_alias)
    ELSE ((SELECT list(r ORDER BY (r).node_id) FROM s)
      || [{node_id: (SELECT g FROM base), parent_id: (SELECT node_id FROM target), kind: kind,
           value: NULL::VARCHAR, op: NULL::VARCHAR, arg: NULL::VARCHAR, alias: NULL::VARCHAR}]
      || (SELECT COALESCE(list({node_id: (SELECT g FROM base) + (r).node_id,
                                parent_id: (SELECT g FROM base) + (r).parent_id,
                                kind: (r).kind, value: (r).value,
                                op: CASE WHEN (r).kind = 'step' THEN COALESCE((r).op, 'desc') ELSE (r).op END,
                                arg: (r).arg, alias: (r).alias} ORDER BY (r).node_id), [])
          FROM i WHERE (r).kind <> 'selector'))::TREE_SELECTOR END);

CREATE OR REPLACE MACRO tree_treeql_comb(op) AS
  CASE op WHEN 'desc' THEN 'DESCENDANT' WHEN 'child' THEN 'CHILD' WHEN 'next' THEN 'SIBLING' WHEN 'after' THEN 'FOLLOWING' ELSE NULL END;

CREATE OR REPLACE MACRO tree_treeql_clause(kind, value, op, arg) AS
  CASE kind WHEN 'type' THEN 'TYPE ' || tree_sql_lit(value)
            WHEN 'id' THEN 'ID ' || tree_sql_lit(value)
            WHEN 'class' THEN 'CLASS ' || tree_sql_lit(value)
            WHEN 'attr' THEN 'ATTR ' || value || ' ' || op || ' ' || arg
            WHEN 'pseudo' THEN 'PSEUDO ' || tree_sql_lit(value)
            WHEN 'where' THEN 'WHERE ' || value END;

-- One step's text: its combinator keyword, its clause list in parentheses, its capture.
CREATE OR REPLACE MACRO tree_treeql_step(op, clauses, alias) AS
  rtrim(COALESCE(tree_treeql_comb(op) || ' ', '') || COALESCE('(' || clauses || ')', '') || COALESCE(' AS ' || alias, ''));

-- Printer: one line per top-level step. A HAS/NOT group renders inline in its step's clause list
-- as `HAS ( <inner chain> )`, the inner chain being the same per-step rendering joined by single
-- spaces; ordering a step's parts by node_id puts the groups after the step's own clauses, since
-- the constructor allocates group ids after the whole chain.
--
-- Groups nest two deep, so this is a fixed three-pass bottom-up fold rather than a recursion:
-- `stepA` renders a step from its clauses alone (right for the innermost steps, which have no
-- groups), `grpA` renders each group from stepA (right for the depth-2 groups), `stepB` adds the
-- grpA text to a step's parts (right for the steps inside a depth-1 group), and so outwards --
-- only the pass that is right for a level is ever read at that level.
CREATE OR REPLACE MACRO tree_selector_to_treeql(sel) AS (
  WITH n AS (SELECT unnest(sel, recursive := true)),
  -- (step node id, part node id, part text) for every clause: the same at every level
  clause AS (
    SELECT c.parent_id AS step, c.node_id AS id, tree_treeql_clause(c.kind, c.value, c.op, c.arg) AS t
    FROM n c WHERE c.kind NOT IN ('selector', 'step', 'has', 'not')),
  stepA AS (
    SELECT s.node_id, s.parent_id, s.op, s.alias,
           (SELECT string_agg(p.t, ', ' ORDER BY p.id) FROM clause p WHERE p.step = s.node_id) AS body
    FROM n s WHERE s.kind = 'step'),
  grpA AS (
    SELECT g.node_id, g.parent_id, upper(g.kind) || ' ( '
             || (SELECT string_agg(tree_treeql_step(x.op, x.body, x.alias), ' ' ORDER BY x.node_id)
                 FROM stepA x WHERE x.parent_id = g.node_id) || ' )' AS t
    FROM n g WHERE g.kind IN ('has', 'not')),
  partB AS (SELECT step, id, t FROM clause UNION ALL SELECT g.parent_id, g.node_id, g.t FROM grpA g),
  stepB AS (
    SELECT s.node_id, s.parent_id, s.op, s.alias,
           (SELECT string_agg(p.t, ', ' ORDER BY p.id) FROM partB p WHERE p.step = s.node_id) AS body
    FROM n s WHERE s.kind = 'step'),
  grpB AS (
    SELECT g.node_id, g.parent_id, upper(g.kind) || ' ( '
             || (SELECT string_agg(tree_treeql_step(x.op, x.body, x.alias), ' ' ORDER BY x.node_id)
                 FROM stepB x WHERE x.parent_id = g.node_id) || ' )' AS t
    FROM n g WHERE g.kind IN ('has', 'not')),
  partC AS (SELECT step, id, t FROM clause UNION ALL SELECT g.parent_id, g.node_id, g.t FROM grpB g),
  stepC AS (
    SELECT s.node_id, s.parent_id, s.op, s.alias,
           (SELECT string_agg(p.t, ', ' ORDER BY p.id) FROM partC p WHERE p.step = s.node_id) AS body
    FROM n s WHERE s.kind = 'step')
  SELECT string_agg(tree_treeql_step(op, body, alias), chr(10) ORDER BY node_id)
  FROM stepC WHERE parent_id IN (SELECT node_id FROM n WHERE kind = 'selector'));
