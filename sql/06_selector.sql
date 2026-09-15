-- sql/06_selector.sql

-- How many levels of HAS/NOT a selector may nest. The ceiling is not a taste: the constructor
-- spells it out as a cast type (TREE_STEP_L0/L1/L2), the printer unrolls one rendering pass per
-- level, and Task 5's compiler folds the same fixed number of levels. Everything that enforces it
-- refuses in terms of this number, so raising it means touching each of those in step.
CREATE OR REPLACE MACRO tree_group_depth_limit() AS 2;

-- The language a selector was WRITTEN in, read off the IR itself.
--
-- Provenance used to be `COALESCE(language, 'treeql')` in the compiler: the caller's argument, or
-- a guess. The guess was wrong for every selector that reached the compiler as IR from the css
-- front-ends, which is most of them -- a selector parsed as css and handed over as rows reported
-- `treeql`, a language nothing had parsed. The front-end is the only thing that knows, so every
-- front-end now STAMPS the `selector` root row's `value` with its own name (tree_steps 'treeql',
-- test/css_parser.py and tree_css_lower 'css') and the compiler reads it. An explicit `language :=`
-- still wins -- it is the caller saying what they wrote -- and hand-built IR that stamps nothing
-- still reads as treeql, because it was never parsed at all.
--
-- The root row's value is otherwise unused: the printer renders steps and their clauses, and the
-- compiler's fold starts at the steps whose parent is the root, so a root carrying a value changes
-- no printed text and no compiled SQL.
CREATE OR REPLACE MACRO tree_selector_language(sel) AS (
  SELECT COALESCE(min((x).value), 'treeql') FROM (SELECT unnest(sel::TREE_SELECTOR) AS x) WHERE (x).kind = 'selector');

-- How deep the HAS/NOT groups of a built selector actually nest: 0 for a selector with no groups,
-- 1 for `HAS ( ... )`, 2 for `HAS ( ... HAS ( ... ) )`. Walks the parent links, so it reports a
-- depth past tree_group_depth_limit() honestly rather than capping -- which is what lets the
-- printer and tree_steps_group refuse a selector they cannot render or build.
-- 1.5.5: a plain (non-USING KEY) recursive CTE binds inside a scalar macro body, so the walk does
-- not have to be unrolled here the way the constructor's levels are.
--
-- The walk follows parent links, and a hand-built IR can repeat a node_id -- which makes those
-- links a cycle (`0 -> 1, 1 -> 2, 2 -> 1`) and the walk non-terminating. The callers refuse a
-- selector whose node ids are not unique before they ask for a depth, but this macro is also
-- public, so it carries its own bound: `lv` counts NODE levels, not group levels, and stops the
-- recursion past the deepest node a legal selector can have. Each group level costs two node
-- levels (the group node and its first inner step) on top of the root and the top-level step,
-- and one more level carries the innermost step's clauses; the +3 is that clause level plus the
-- headroom that lets a group ONE level past the ceiling still be counted, which is what makes
-- the "nested deeper than N levels" refusals fire instead of silently reading as legal.
CREATE OR REPLACE MACRO tree_selector_group_depth(sel) AS (
  WITH RECURSIVE n AS (SELECT unnest(sel::TREE_SELECTOR) AS x),
  walk(id, d, lv) AS (
      SELECT (x).node_id, 0, 0 FROM n WHERE (x).parent_id IS NULL
    UNION ALL
      SELECT (x).node_id, w.d + CASE WHEN (x).kind IN ('has', 'not') THEN 1 ELSE 0 END, w.lv + 1
      FROM walk w, n WHERE (x).parent_id = w.id AND w.lv < 2 * tree_group_depth_limit() + 3)
  SELECT COALESCE(max(d), 0) FROM walk);

-- Normalize any list of step structs to one fixed shape so missing fields read as NULL, and
-- emit the selector IR: node 0 is the `selector` root, every step is its child, every clause a
-- child of its step, and a HAS/NOT group is a `has`/`not` child of its step whose own children
-- are the group's inner steps. Groups nest two deep (three literal step levels), which is what
-- TREE_STEP_L2 spells out; the ceiling is in the type, not in a recursion.
--
-- Node ids are dense and increase in *depth-first* document order: a step is followed by its
-- clauses, then by each of its groups, and a group node is followed by every row of its inner
-- chain -- nested groups included -- before the step's next group or the chain's next step. The
-- order is carried as a `path` struct, which 1.5.5 orders and compares field by field, so one
-- column is the whole sort key and a row's `ppath` (its parent's path) is the whole parent link.
-- The path alternates index and slot per level: {i0, a0, i1, a1, i2, a2}, where `i` is the 1-based
-- position in a chain and `a` says which of the step's parts comes next -- 0 the step's own row,
-- 1..6 its clause slots, 6 + g its g-th group. Ancestry therefore precedes depth in the key, which
-- is what makes it depth-first; putting the level first would number breadth-first.
--
-- Refusals guard the normalization, each for something the cast would otherwise swallow: the cast
-- drops fields the shapes do not name (a typo would silently do nothing), so the keys are
-- enumerated first with json_keys -- at every level, since a group's steps are cast the same way --
-- and checked against the allowed set; a group written on a step at the last level tree_group_depth_limit()
-- allows has nowhere in the shapes to go, so it refuses instead of vanishing; an empty group tests
-- nothing; an ATTR text the operator regex cannot parse would yield empty name/op/arg, so it
-- refuses naming the text; and a capture inside a group has no row of its own to bind.
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
  -- every step at every level as one relation: its path components, its parent's path, its fields.
  -- The first step of the outer chain has no combinator; the first step of a group's chain defaults
  -- to desc like any later step, so a group's chain always starts from a combinator the compiler
  -- can read. `depth` is the step's group depth, which says which path slot its clauses occupy.
  allsteps AS (
    SELECT i0, 0 AS a0, 0 AS i1, 0 AS a1, 0 AS i2, 0 AS a2, 0 AS depth,
           {i0: 0, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0} AS ppath,
           CASE WHEN i0 = 1 THEN NULL ELSE COALESCE((s).comb, 'desc') END AS op,
           -- the combinator as WRITTEN, which the SELF guard below reads: the first step of a
           -- chain drops it for NULL, so the computed op cannot tell a written SELF from none
           (s).comb AS comb, i0 AS chain_i,
           (s).type AS type, (s).id AS id, (s).class AS class, (s).attr AS attr,
           (s).pseudo AS pseudo, (s)."where" AS "where", (s)."as" AS "as"
    FROM lvl0
    UNION ALL
    SELECT i0, 6 + g1, i1, 0, 0, 0, 1,
           {i0: i0, a0: 6 + g1, i1: 0, a1: 0, i2: 0, a2: 0},
           COALESCE((s).comb, 'desc'), (s).comb, i1,
           (s).type, (s).id, (s).class, (s).attr, (s).pseudo, (s)."where", (s)."as"
    FROM lvl1
    UNION ALL
    SELECT i0, 6 + g1, i1, 6 + g2, i2, 0, 2,
           {i0: i0, a0: 6 + g1, i1: i1, a1: 6 + g2, i2: 0, a2: 0},
           COALESCE((s).comb, 'desc'), (s).comb, i2,
           (s).type, (s).id, (s).class, (s).attr, (s).pseudo, (s)."where", (s)."as"
    FROM lvl2),
  -- one row per clause, from that one relation, so the extraction is written once and not once per
  -- level; `sub` is the clause slot, placed into the path slot of the step's own level below
  clauses AS (
    SELECT a.*, 1 AS sub, 'type' AS ckind, a.type AS cvalue, NULL::VARCHAR AS cop, NULL::VARCHAR AS carg
      FROM allsteps a WHERE a.type IS NOT NULL
    UNION ALL SELECT a.*, 2, 'id', a.id, NULL, NULL FROM allsteps a WHERE a.id IS NOT NULL
    UNION ALL SELECT a.*, 3, 'class', a.class, NULL, NULL FROM allsteps a WHERE a.class IS NOT NULL
    UNION ALL SELECT a.*, 4, 'attr',
        regexp_extract(a.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 1),
        regexp_extract(a.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 2),
        regexp_extract(a.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 3)
      FROM allsteps a WHERE a.attr IS NOT NULL
    UNION ALL SELECT a.*, 5, 'pseudo', a.pseudo, NULL, NULL FROM allsteps a WHERE a.pseudo IS NOT NULL
    UNION ALL SELECT a.*, 6, 'where', a."where", NULL, NULL FROM allsteps a WHERE a."where" IS NOT NULL),
  -- the group nodes: a depth-1 group hangs off its outer step, a depth-2 group off its inner step
  allgrp AS (
    SELECT {i0: i0, a0: 6 + g1, i1: 0, a1: 0, i2: 0, a2: 0} AS path,
           {i0: i0, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0} AS ppath, gkind FROM grp1
    UNION ALL
    SELECT {i0: i0, a0: 6 + g1, i1: i1, a1: 6 + g2, i2: 0, a2: 0},
           {i0: i0, a0: 6 + g1, i1: i1, a1: 0, i2: 0, a2: 0}, gkind FROM grp2),
  -- the untyped input as one JSON object per step at every level, for the unknown-field check.
  -- json_extract with a wildcard path returns a JSON[], empty for a path no step has, so the
  -- nested paths cost nothing when there are no groups. 1.5.5: a cross join between two CTEs that
  -- unnest inside a macro body binds as a correlated UNNEST and is refused, so the paths are
  -- concatenated into one list instead of joined against a CTE of paths.
  -- jdeep is the last level tree_group_depth_limit() allows: its steps are cast to a shape with no
  -- has/not at all, so a group there is a level too deep and is refused rather than dropped.
  jdeep AS (SELECT unnest(
      json_extract(to_json(steps), '$[*].has[*].has[*]')
      || json_extract(to_json(steps), '$[*].has[*].not[*]')
      || json_extract(to_json(steps), '$[*].not[*].has[*]')
      || json_extract(to_json(steps), '$[*].not[*].not[*]')) AS j),
  jall AS (SELECT unnest(
      json_extract(to_json(steps), '$[*]')
      || json_extract(to_json(steps), '$[*].has[*]')
      || json_extract(to_json(steps), '$[*].not[*]')) AS j
    UNION ALL SELECT j FROM jdeep),
  bad_key AS (
    SELECT min(k) AS k FROM (SELECT unnest(json_keys(j)) AS k FROM jall)
    WHERE k NOT IN ('comb', 'type', 'id', 'class', 'attr', 'pseudo', 'where', 'as', 'has', 'not')),
  bad_depth AS (
    SELECT count(*) AS n FROM (SELECT unnest(json_keys(j)) AS k FROM jdeep) WHERE k IN ('has', 'not')),
  bad_empty AS (
    SELECT count(*) AS n FROM (SELECT kids FROM grp1 UNION ALL SELECT kids FROM grp2) WHERE len(kids) = 0),
  bad_capture AS (
    SELECT min(a."as") AS a FROM allsteps a WHERE a.depth > 0 AND a."as" IS NOT NULL),
  bad_alias AS (
    SELECT min(a."as") AS a FROM allsteps a WHERE a."as" IS NOT NULL AND regexp_matches(a."as", '^s[0-9]+$')),
  -- An alias becomes a SQL relation alias and an output column name, so it has to be an
  -- identifier. `my-cap` passed every producer -- this constructor, the printer, both css
  -- front-ends -- and then died in DuckDB's binder on `... AS my-cap`, an error naming nothing
  -- the user wrote. All three front-ends and the match compiler refuse it now (R13).
  bad_alias_ident AS (
    SELECT min(a."as") AS a FROM allsteps a WHERE a."as" IS NOT NULL AND NOT tree_sql_is_ident(a."as")),
  bad_attr AS (
    SELECT min(a.attr) AS a FROM allsteps a WHERE a.attr IS NOT NULL
      AND NOT regexp_matches(a.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$')),
  -- SELF says the step IS the row the group hangs off, which only means anything for the first
  -- step of a group's chain. A later step relates to the step before it, and the first step of
  -- the OUTER chain has nothing to relate to at all -- there its comb is dropped for NULL, so
  -- without this guard a written SELF would vanish instead of refusing.
  bad_self AS (
    SELECT count(*) AS n FROM allsteps a
    WHERE a.comb = 'self' AND NOT (a.depth > 0 AND a.chain_i = 1)),
  -- The first step of the OUTER chain has nothing before it to relate to, so its written comb
  -- is dropped for NULL above. Dropping it silently is the one thing this constructor does that
  -- the css parser does not: there a leading combinator refuses (`a combinator with nothing on
  -- its left`), so a selector that means nothing reads as an error in one front-end and as a
  -- different selector in the other. It refuses here too (M7).
  bad_first_comb AS (
    SELECT min(a.comb) AS c FROM allsteps a WHERE a.depth = 0 AND a.chain_i = 1 AND a.comb IS NOT NULL),
  nodes AS (
    -- the root: a ppath no row carries, so the parent join leaves its parent_id NULL. Its value
    -- is this front-end's name -- the provenance tree_selector_language reads back (R10)
    SELECT {i0: 0, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0} AS path,
           {i0: -1, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0} AS ppath,
           'selector' AS kind, 'treeql'::VARCHAR AS value, NULL::VARCHAR AS op, NULL::VARCHAR AS arg, NULL::VARCHAR AS alias
    UNION ALL SELECT g.path, g.ppath, g.gkind, NULL, NULL, NULL, NULL FROM allgrp g
    UNION ALL SELECT {i0: a.i0, a0: a.a0, i1: a.i1, a1: a.a1, i2: a.i2, a2: a.a2}, a.ppath,
                     'step', NULL, a.op, NULL, a."as" FROM allsteps a
    UNION ALL SELECT {i0: c.i0, a0: CASE WHEN c.depth = 0 THEN c.sub ELSE c.a0 END,
                      i1: c.i1, a1: CASE WHEN c.depth = 1 THEN c.sub ELSE c.a1 END,
                      i2: c.i2, a2: CASE WHEN c.depth = 2 THEN c.sub ELSE c.a2 END},
                     {i0: c.i0, a0: c.a0, i1: c.i1, a1: c.a1, i2: c.i2, a2: c.a2},
                     c.ckind, c.cvalue, c.cop, c.carg, NULL FROM clauses c),
  -- every path is unique, so the parent link is one struct comparison
  numbered AS (SELECT CAST(row_number() OVER (ORDER BY path) - 1 AS INTEGER) AS node_id, * FROM nodes),
  parented AS (
    SELECT n.node_id, p.node_id AS parent_id, n.kind, n.value, n.op, n.arg, n.alias
    FROM numbered n LEFT JOIN numbered p ON p.path = n.ppath)
  SELECT CASE
    WHEN (SELECT k FROM bad_key) IS NOT NULL THEN tree_err('tree_steps: unknown step field ' || (SELECT k FROM bad_key))
    WHEN (SELECT n FROM bad_depth) > 0
      THEN tree_err('tree_steps: groups nested deeper than ' || tree_group_depth_limit() || ' levels are not supported')
    -- a group with no steps tests nothing; accepting it would leave a node in the IR that the
    -- printer has no text for and the compiler no predicate for
    WHEN (SELECT n FROM bad_empty) > 0 THEN tree_err('tree_steps: empty HAS/NOT group')
    -- a step inside HAS/NOT is a test, not a row of the result, so there is nothing to name
    WHEN (SELECT a FROM bad_capture) IS NOT NULL THEN tree_err('tree_steps: capture inside HAS/NOT has no row to bind')
    WHEN (SELECT a FROM bad_attr) IS NOT NULL THEN tree_err('tree_steps: cannot parse ATTR clause: ' || (SELECT a FROM bad_attr))
    WHEN (SELECT n FROM bad_self) > 0
      THEN tree_err('tree_steps: SELF is only legal as the first step of a HAS/NOT group')
    -- after bad_self, so `{comb: 'self'}` written first still refuses in SELF's own words
    WHEN (SELECT c FROM bad_first_comb) IS NOT NULL
      THEN tree_err('tree_steps: the first step takes no combinator')
    -- s<N> is what the match compiler names step N when the user names nothing; a user
    -- alias of that shape would collide with another step's generated alias
    WHEN (SELECT a FROM bad_alias) IS NOT NULL THEN tree_err('tree_steps: alias ' || (SELECT a FROM bad_alias) || ' is reserved for generated step aliases')
    WHEN (SELECT a FROM bad_alias_ident) IS NOT NULL THEN tree_err('tree_steps: alias ' || (SELECT a FROM bad_alias_ident) || ' is not an identifier')
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
  -- the same identifier rule tree_steps applies, read on the rows being spliced: `sel` may be
  -- hand-built IR, and an alias that is not an identifier dies in the binder rather than here
  bad_alias AS (
    SELECT min((r).alias) AS a FROM s WHERE (r).kind = 'step' AND (r).alias IS NOT NULL AND NOT tree_sql_is_ident((r).alias)),
  base AS (SELECT max((r).node_id) + 1 AS g FROM s),
  -- one pass over the inner selector's steps: how many there are, whether any is captured, and
  -- whether a SELF sits anywhere but first in the chain being re-parented. The inner selector's
  -- own top-level steps become the group's inner chain, so SELF is legal on the first of them
  -- and nowhere else -- the same rule tree_steps applies, read here on the chain after the
  -- splice rather than before it. tree_steps refuses to BUILD such an inner selector (there the
  -- SELF is on a top-level step), so only hand-built IR reaches this.
  inner_steps AS (
    SELECT count(*) AS n, min((r).alias) AS cap,
           count(*) FILTER (WHERE (r).op = 'self' AND (r).parent_id = 0
                              AND (r).node_id <> (SELECT min((r).node_id) FROM i WHERE (r).kind = 'step' AND (r).parent_id = 0)) AS bad_self
    FROM i WHERE (r).kind = 'step'),
  spliced AS (
    SELECT ((SELECT list(r ORDER BY (r).node_id) FROM s)
      || [{node_id: (SELECT g FROM base), parent_id: (SELECT node_id FROM target), kind: kind,
           value: NULL::VARCHAR, op: NULL::VARCHAR, arg: NULL::VARCHAR, alias: NULL::VARCHAR}]
      || (SELECT COALESCE(list({node_id: (SELECT g FROM base) + (r).node_id,
                                parent_id: (SELECT g FROM base) + (r).parent_id,
                                kind: (r).kind, value: (r).value,
                                op: CASE WHEN (r).kind = 'step' THEN COALESCE((r).op, 'desc') ELSE (r).op END,
                                arg: (r).arg, alias: (r).alias} ORDER BY (r).node_id), [])
          FROM i WHERE (r).kind <> 'selector'))::TREE_SELECTOR AS v)
  SELECT CASE
    WHEN kind IS NULL OR kind NOT IN ('has', 'not') THEN tree_err('tree_steps_group: kind must be has or not')
    -- a NULL alias matches no step, and concatenating it into the message would make the whole
    -- refusal NULL, so the message names it explicitly
    WHEN (SELECT node_id FROM target) IS NULL
      THEN tree_err('tree_steps_group: no step aliased ' || COALESCE(step_alias, 'NULL'))
    WHEN (SELECT a FROM bad_alias) IS NOT NULL
      THEN tree_err('tree_steps_group: alias ' || (SELECT a FROM bad_alias) || ' is not an identifier')
    WHEN (SELECT n FROM inner_steps) = 0 THEN tree_err('tree_steps_group: inner selector has no steps')
    -- the same reason tree_steps refuses a capture written inside a group
    WHEN (SELECT cap FROM inner_steps) IS NOT NULL
      THEN tree_err('tree_steps_group: capture inside HAS/NOT has no row to bind')
    WHEN (SELECT bad_self FROM inner_steps) > 0
      THEN tree_err('tree_steps_group: SELF is only legal as the first step of a HAS/NOT group')
    -- the splice adds a group level below the target step, so an inner selector that already nests
    -- groups can push the result past what the printer and the compiler unroll. Measuring the
    -- spliced result rather than the parts counts the target step's own depth for free.
    WHEN tree_selector_group_depth((SELECT v FROM spliced)) > tree_group_depth_limit()
      THEN tree_err('tree_steps_group: groups nested deeper than ' || tree_group_depth_limit() || ' levels are not supported')
    ELSE (SELECT v FROM spliced) END);

CREATE OR REPLACE MACRO tree_treeql_comb(op) AS
  CASE op WHEN 'desc' THEN 'DESCENDANT' WHEN 'child' THEN 'CHILD' WHEN 'next' THEN 'SIBLING' WHEN 'after' THEN 'FOLLOWING'
          WHEN 'self' THEN 'SELF' ELSE NULL END;

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
  SELECT CASE
    WHEN (SELECT k FROM bad_kind) IS NOT NULL
      THEN tree_err('tree_selector_to_treeql: unknown node kind ' || (SELECT k FROM bad_kind))
    WHEN (SELECT bad FROM bad_dup)
      THEN tree_err('tree_selector_to_treeql: selector node ids are not unique')
    WHEN tree_selector_group_depth(sel) > tree_group_depth_limit()
      THEN tree_err('tree_selector_to_treeql: groups nested deeper than ' || tree_group_depth_limit() || ' levels are not supported')
    ELSE (SELECT string_agg(tree_treeql_step(op, body, alias), chr(10) ORDER BY node_id)
          FROM stepC WHERE parent_id IN (SELECT node_id FROM n WHERE kind = 'selector')) END);
