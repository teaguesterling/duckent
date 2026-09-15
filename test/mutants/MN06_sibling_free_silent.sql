-- test/mutants/MN06_sibling_free_silent.sql
-- Sibling combinators silently no-op under the sibling-free profile: 'next'/'after'
-- compile to a comparison that never raises (they still combine into a predicate,
-- just not a useful one), and the refusal branch in tree_compile_match is removed
-- so the compiler never objects to using them on a sibling-free tree.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/07_match.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- Combinator between the previous step alias a and this step alias b. MN14 mutates
-- tree_sql_subtree/tree_sql_children to drop the root equality.
-- 'self' only ever arrives here as a group's first inner step, which sql/06_selector.sql
-- enforces when the IR is built; nothing else in the compiler treats it specially.
CREATE OR REPLACE MACRO tree_sql_comb(op, a, b, p, elem) AS
  CASE op
    WHEN 'desc'  THEN tree_sql_subtree(a, b)
    WHEN 'child' THEN tree_sql_children(a, b)
    WHEN 'self'  THEN tree_sql_self(a, b)
    -- the mutation, half one: 'next' and 'after' fall through to the ELSE below
    -- ... which is a predicate that never raises and never matches
    ELSE 'false' END;

-- The compiler is a fold over the IR: every node's text is built from its children's, so the
-- chain and the HAS/NOT groups hanging off its steps are compiled by the same two rules applied
-- at each level rather than by a chain rule with group special cases bolted on.
--
-- The fold is unrolled to tree_group_depth_limit() group levels instead of being run as a
-- recursive CTE, for the same reason sql/06_selector.sql's printer is: the number of levels is
-- fixed by the IR's own ceiling, so the passes alternate from the inside out and only the pass
-- that is right for a level is ever read at that level. `stepA` is a step built from its clauses
-- alone (right for the innermost steps, which have no groups), `grpA` a group built from stepA
-- (right for the innermost groups), `stepB` a step built from its clauses AND its grpA text, and
-- so on outwards; `stepC` is right for the top-level steps. Raising tree_group_depth_limit() means
-- adding one stepN/grpN pair here and one in the printer.
-- A USING KEY fold over the same IR was the design's first shape; 1.5.5 refuses the readiness
-- test it needs (a recurring.<cte> reference inside a correlated NOT EXISTS), and the LEFT JOIN
-- form that replaces it costs more than the two extra passes the fixed ceiling already pays for.
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
         -- The projection's non-canonical columns, recorded at create time: which bare names an
         -- ATTR clause may resolve to, and in what type, without describing the relation on every
         -- query. Two shapes are read, because the artifact gained its types in the PR #2 fix
         -- wave and a catalog written before that still says what its columns are called: a list
         -- of `{name, type}` objects, or a bare list of names, which reads back with a NULL type
         -- (tree_sql_attr_col_cmp then takes the reading that cannot abort the query). The shape
         -- is decided by the first element's json_type rather than by a version flag, so an
         -- artifact and its reader cannot disagree about which they are looking at.
         COALESCE((SELECT CASE WHEN json_type(c.sql_text, '$[0]') = 'OBJECT'
                               THEN from_json(c.sql_text, '[{"name": "VARCHAR", "type": "VARCHAR"}]')
                               ELSE list_transform(from_json(c.sql_text, '["VARCHAR"]'),
                                                   lambda x: {name: x, "type": NULL::VARCHAR}) END
                   FROM tree_catalog.compiled c
                   WHERE c.database_name = current_database() AND c.schema_name = sch AND c.tree_name = nm AND c.artifact = 'attribute_columns'),
                  []::STRUCT(name VARCHAR, "type" VARCHAR)[]) AS attr_cols
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
-- the selector's rows, flattened once and read by both the checks below and the n CTE
ir AS (SELECT * FROM (SELECT unnest(sel, recursive := true))),
-- Structure the unrolled fold cannot reach. Its passes are inner joins over a fixed number of
-- levels, so anything out of reach is missing from the compiled text rather than wrong in it,
-- which is the worst way for a matcher to fail: a group nested past the ceiling loses its
-- innermost level (and so matches more than it should), a group with no inner steps disappears
-- (same), and a clause hung off anything but a step is never compiled (same). None of these can
-- come out of tree_steps, but the compiler also takes IR built by hand or by a front-end, so it
-- refuses them here rather than trusting its caller. The depth refusal is worded exactly as the
-- printer's, since it is the same ceiling.
bad_empty AS (
  SELECT count(*) AS n FROM ir g
  WHERE g.kind IN ('has', 'not') AND NOT EXISTS (SELECT 1 FROM ir s WHERE s.parent_id = g.node_id AND s.kind = 'step')),
bad_clause AS (
  SELECT min(c.kind) AS k FROM ir c
  WHERE c.kind IN ('type', 'id', 'class', 'attr', 'pseudo', 'where')
    AND NOT EXISTS (SELECT 1 FROM ir s WHERE s.node_id = c.parent_id AND s.kind = 'step')),
-- Node ids ARE the parent links, so a repeated one turns the parent relation into a graph: the
-- depth walk tree_selector_group_depth runs below then never terminates (0 -> 1, 1 -> 2, 2 -> 1).
-- Refused before any walk is asked for; the walk carries its own level bound as a second guard.
bad_dup AS (SELECT count(*) <> count(DISTINCT node_id) AS bad FROM ir),
-- s<N> is the alias this compiler generates for step N when the user named nothing, and the
-- capture list below drops any alias of that shape (`FILTER (WHERE alias <> 's' || node_id)`).
-- A user alias of that shape therefore either vanishes from the output while the printer still
-- shows it, or -- when N is some OTHER step's id -- names two relations the same and the whole
-- query dies in the binder. tree_steps refuses it; both css front-ends refuse it; this is the
-- convergence point, so IR that reached the compiler by any other road is refused here too.
bad_alias AS (
  SELECT min(alias) AS a FROM ir WHERE kind = 'step' AND alias IS NOT NULL AND regexp_matches(alias, '^s[0-9]+$')),
-- Every kind the fold knows, and NULL named rather than skipped: `kind NOT IN (...)` is NULL for
-- a NULL kind, and a NULL kind also slips through the clause CTE's own NOT IN filter, so without
-- this a NULL-kind node is silently dropped wherever it sits. A node under a STEP is in clause
-- position and tree_sql_clause refuses it by name ('unknown clause kind bogus'), which says more;
-- this arm covers the positions the clause compiler never sees -- under the root, under a group.
bad_kind AS (
  SELECT min(c.node_id) AS id, min_by(COALESCE(c.kind, '<NULL>'), c.node_id) AS k
  FROM ir c LEFT JOIN ir p ON p.node_id = c.parent_id
  WHERE c.kind IS NULL
     OR (c.kind NOT IN ('selector', 'step', 'has', 'not', 'type', 'id', 'class', 'attr', 'pseudo', 'where')
         AND p.kind IS DISTINCT FROM 'step')),
-- The shape of the IR, as one rule: what may hang off what. The fold reaches a node only through
-- the parent link its kind is expected to have, so a node hung somewhere else is not compiled --
-- a step whose parent_id points at a clause never joins the chain, a group under the root never
-- becomes an EXISTS -- and every one of those widens the match set silently. Checked after
-- bad_clause, which says the same thing about a misplaced clause in the words that record froze.
bad_parent AS (
  SELECT min(c.node_id) AS id, min_by(c.kind, c.node_id) AS k, min_by(COALESCE(p.kind, '<none>'), c.node_id) AS pk
  FROM ir c LEFT JOIN ir p ON p.node_id = c.parent_id
  WHERE c.kind IN ('step', 'has', 'not', 'type', 'id', 'class', 'attr', 'pseudo', 'where')
    AND NOT COALESCE(CASE WHEN c.kind = 'step' THEN p.kind IN ('selector', 'has', 'not')
                          ELSE p.kind = 'step' END, false)),
-- SELF says the step IS the row the group hangs off, which only means anything for the first
-- step of a group's chain: a later step relates to the step before it, and a top-level step has
-- nothing to relate to at all. tree_steps and tree_steps_group enforce it on what they BUILD;
-- the compiler also takes hand-built IR, and a misplaced SELF there compiles to an equality that
-- quietly turns a chain into a filter on one row.
bad_self AS (
  SELECT count(*) AS n FROM ir s
  WHERE s.kind = 'step' AND s.op = 'self'
    AND NOT EXISTS (SELECT 1 FROM ir g WHERE g.node_id = s.parent_id AND g.kind IN ('has', 'not')
                      AND s.node_id = (SELECT min(x.node_id) FROM ir x WHERE x.kind = 'step' AND x.parent_id = g.node_id))),
chk AS (SELECT CASE
  -- COALESCE: a NULL schema or name leaves t empty, so this is the branch that fires, and its
  -- message would otherwise be NULL -- which in 1.5.5 means the compiler returns NULL and the
  -- caller runs nothing at all. The later branches need no COALESCE: they are reached only
  -- when the tree was found, and a found tree has a non-NULL identity.
  WHEN (SELECT count(*) FROM t) = 0 THEN tree_err('tree_match: tree ' || COALESCE(sch, '<NULL>') || '.' || COALESCE(nm, '<NULL>') || ' not found')
  -- an overlay is an S group for this query only; it cannot widen the projection, and an
  -- overlay that sets nothing (or a selector with no steps) used to compile to NULL
  WHEN (semantic).attr IS NOT NULL THEN tree_err('tree_match: a per-query SEMANTIC overlay cannot add attribute columns; use tree_ddl_alter')
  -- ... and "sets nothing" is the question create and alter ask of a SEMANTIC group, through the
  -- predicate all three now share. The copy that stood here had already drifted from theirs: it
  -- omitted PSEUDO_ARGS, so an overlay that set only pseudo_args -- which binds the whole shared
  -- pseudo tier, and whose names ovp already treated as known -- was refused as empty.
  WHEN semantic IS NOT NULL AND NOT tree_semantic_declares(semantic)
       THEN tree_err('tree_match: semantic overlay is empty')
  WHEN (SELECT count(*) FROM ir WHERE kind = 'step') = 0 THEN tree_err('tree_match: selector has no steps')
  -- before the depth walk, which is the thing a duplicated node id makes non-terminating
  WHEN (SELECT bad FROM bad_dup) THEN tree_err('tree_match: selector node ids are not unique')
  WHEN (SELECT a FROM bad_alias) IS NOT NULL
    THEN tree_err('tree_match: alias ' || (SELECT a FROM bad_alias) || ' is reserved for generated step aliases')
  WHEN tree_selector_group_depth(sel) > tree_group_depth_limit()
    THEN tree_err('tree_match: groups nested deeper than ' || tree_group_depth_limit() || ' levels are not supported')
  WHEN (SELECT n FROM bad_empty) > 0 THEN tree_err('tree_match: empty group')
  WHEN (SELECT k FROM bad_clause) IS NOT NULL
    THEN tree_err('tree_match: clause ' || (SELECT k FROM bad_clause) || ' is not attached to a step')
  WHEN (SELECT k FROM bad_kind) IS NOT NULL
    THEN tree_err('tree_match: node ' || (SELECT id FROM bad_kind) || ' has an unknown kind ' || (SELECT k FROM bad_kind))
  WHEN (SELECT k FROM bad_parent) IS NOT NULL
    THEN tree_err('tree_match: node ' || (SELECT id FROM bad_parent) || ' has kind ' || (SELECT k FROM bad_parent)
                  || ' which is not allowed under ' || (SELECT pk FROM bad_parent))
  WHEN (SELECT n FROM bad_self) > 0
    THEN tree_err('tree_match: SELF is only legal as the first step of a HAS/NOT group')
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
        -- Gated on (sem).pseudo -- the EXPANDED overlay -- not the raw (semantic).pseudo: an
        -- overlay that sets only pseudo_args (no pseudo declared at all) still expands to a
        -- non-NULL shared-tier binding list, and ovp.names (below) already treats those names
        -- as known. Gating on the raw, undeclared field left the projection's _pseudo map
        -- without the shared binding while the matcher believed it was bound -- a lookup that
        -- silently matched nothing instead of raising or actually binding.
        CASE WHEN (sem).pseudo IS NULL THEN NULL ELSE 'map_concat(_pseudo, ' || tree_sql_pseudo_map(sem) || ') AS _pseudo' END], lambda x: x IS NOT NULL), 'string_agg', ', ')
      || ') FROM tree_catalog.' || tree_sql_object_name('proj', sch, nm) || '())' END AS p
  FROM ovp),
-- The one row every text-building step joins against. A missing tree leaves t empty, so these are
-- scalar subqueries over a FROM-less SELECT rather than a join: cfg must still have its one row,
-- or chk would never get to raise "tree not found". `known` says whether the tree is there at
-- all, which is what gates the clause compiler below.
cfg AS (SELECT (SELECT p FROM proj) AS p, (SELECT has_element FROM t) AS elem,
               (SELECT has_map FROM t) AS has_map, (SELECT attr_cols FROM t) AS attr_cols,
               (SELECT count(*) FROM t) > 0 AS known),
-- IR rows, every level of them: S clauses refused on S-less trees, unknown pseudo-classes marked,
-- sibling combinators refused under sibling_free. unnest(recursive := true) flattens the whole
-- selector, so a clause or a combinator inside a group is checked exactly like a top-level one.
n AS (
  SELECT node_id, parent_id,
         CASE WHEN kind = 'pseudo' AND NOT list_contains(tree_builtin_pseudos(), value)
                   AND NOT list_contains(COALESCE((SELECT known_pseudos FROM t), []), value)
                   AND (semantic IS NULL OR NOT list_contains((SELECT names FROM ovp), value)) THEN 'pseudo_unknown' ELSE kind END AS kind,
         value, op, arg, COALESCE(alias, 's' || node_id) AS alias,
         -- The S-less refusal, with the built-in positional pseudo-classes exempted: they are
         -- structural (they compile through the navigation fragments, read no S slot and bind
         -- nothing from the SEMANTIC group), so there is nothing about them for an R-only tree to
         -- be missing. Refusing them said "this tree has no SEMANTIC group" about a clause that
         -- never wanted one. An unknown pseudo on the same tree still refuses: `ir.kind` is read
         -- here, not the `pseudo_unknown` the column above computes.
         CASE WHEN ir.kind IN ('type', 'id', 'class', 'attr', 'pseudo') AND NOT (SELECT has_semantic FROM t)
                   AND NOT (ir.kind = 'pseudo' AND list_contains(tree_builtin_pseudos(), ir.value))
              THEN tree_err('tree_match: tree ' || sch || '.' || nm || ' has no SEMANTIC group; only combinators and WHERE are available. Add one with tree_ddl_alter or pass semantic :=')
              -- the mutation, half two: the sibling-free refusal branch is gone
              ELSE true END AS ok
  FROM ir),
-- (step node id, part node id, part text) for every clause: the same at every level. A child of a
-- step that is neither a clause nor a group reaches tree_sql_clause and is refused there.
-- cfg.known gates the whole CTE: an unknown tree has no attribute_columns artifact, so every ATTR
-- clause would be refused for a name the tree might well carry. Compiling no clauses at all
-- leaves chk to say what is actually wrong, and it says it whatever the selector asks for.
clause AS (
  SELECT c.parent_id AS step, c.node_id AS id,
         tree_sql_clause(c.kind, c.value, c.op, c.arg, s.alias, cfg.attr_cols, cfg.has_map, cfg.p, cfg.elem) AS txt
  FROM n c JOIN n s ON s.node_id = c.parent_id AND s.kind = 'step' CROSS JOIN cfg
  WHERE c.kind NOT IN ('has', 'not', 'step') AND cfg.known),
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
  SELECT g.node_id, g.parent_id, tree_sql_group(g.kind, cfg.p, g.steps, g.anchor, cfg.elem) AS txt
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
  SELECT g.node_id, g.parent_id, tree_sql_group(g.kind, cfg.p, g.steps, g.anchor, cfg.elem) AS txt
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
