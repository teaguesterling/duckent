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
-- b IS a. The relation css `:not(C)` needs: `:not` negates the SUBJECT row, so its group's
-- inner chain has to start at the step's own row rather than below it. Written as an equality
-- on the key rather than as an alias reuse, because a group compiles to an EXISTS over its own
-- copy of the projection -- the inner chain is a separate scan whatever it relates to.
CREATE OR REPLACE MACRO tree_sql_self(a, b) AS
  b || '._root = ' || a || '._root AND ' || b || '._pre = ' || a || '._pre';
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
--
-- Each has two spellings of ONE relation -- the O(1) arithmetic, and the scan for a nearer
-- element sibling that a tree declaring ELEMENT needs -- so they have to agree wherever both are
-- legal, and the place they did not was the ROOT row. A level-0 row has a NULL _parent, so
-- `_pre = _parent + 1` is NULL, which reads as false: a partition's first root was a first child
-- under the scan (no earlier level-0 sibling -- tree_sql_siblings relates level-0 rows through
-- IS NOT DISTINCT FROM, deliberately) and not under the arithmetic. It IS one in the only sense
-- the tree has -- the first row at level 0 -- so the COALESCE says so, and _pre = 0 is that row
-- because _pre is the partition's preorder index. last_child needs nothing: its O(1) form is the
-- scan with the element conjunct dropped, so it already answers the same on roots. 33_navigation
-- pins both, as row sets and as totals, against a tree that declares `element := 'true'`.
CREATE OR REPLACE MACRO tree_sql_first_child(a, p, elem) AS
  CASE WHEN elem THEN a || '._element AND NOT EXISTS (SELECT 1 FROM ' || p || ' __c WHERE ' || tree_sql_siblings(a, '__c') || ' AND __c._pre < ' || a || '._pre AND __c._element)'
       ELSE 'COALESCE(' || a || '._pre = ' || a || '._parent + 1, ' || a || '._pre = 0)' END;
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
-- 'self' only ever arrives here as a group's first inner step, which sql/06_selector.sql
-- enforces when the IR is built; nothing else in the compiler treats it specially.
CREATE OR REPLACE MACRO tree_sql_comb(op, a, b, p, elem) AS
  CASE op
    WHEN 'desc'  THEN tree_sql_subtree(a, b)
    WHEN 'child' THEN tree_sql_children(a, b)
    WHEN 'self'  THEN tree_sql_self(a, b)
    WHEN 'next'  THEN tree_sql_next_sibling(a, b, p, elem)
    WHEN 'after' THEN tree_sql_after(a, b)
    -- COALESCE: only the first step of the outer chain may carry a NULL op, and tree_sql_chain
    -- defaults that one before it gets here, so a NULL arriving is hand-built IR -- which is
    -- exactly the case that must be told what is wrong instead of receiving a NULL fragment.
    ELSE tree_err('tree_match: unknown combinator ' || COALESCE(op, '<NULL>')) END;

-- The pseudo-classes the language itself defines. They are structural, so every tree has them
-- whatever its SEMANTIC group binds, and they are never reported as unknown. One list, read by
-- tree_sql_builtin_pseudo (which compiles them) and by tree_compile_match -- which must not mark
-- them unknown, and must not refuse them on a tree with no SEMANTIC group: they read no S slot.
CREATE OR REPLACE MACRO tree_builtin_pseudos() AS ['first-child', 'last-child'];

-- The predicate a built-in pseudo-class compiles to, or NULL when `name` is not one of them --
-- which is what makes tree_builtin_pseudos() above the single list. The dispatch used to be a
-- second, hand-copied CASE inside tree_sql_clause, so adding a built-in meant remembering both
-- and forgetting either one left a built-in that compiled but was reported unknown (or the
-- reverse). The built-ins go through the navigation fragments rather than being spelled out
-- again, so a tree that declares ELEMENT gets the first *element* child instead of the row at
-- _parent + 1.
CREATE OR REPLACE MACRO tree_sql_builtin_pseudo(name, alias, p, elem) AS
  CASE WHEN NOT list_contains(tree_builtin_pseudos(), name) THEN NULL
       WHEN name = 'first-child' THEN tree_sql_first_child(alias, p, elem)
       WHEN name = 'last-child'  THEN tree_sql_last_child(alias, p, elem) END;

-- Whether a DESCRIBE column_type names a number. Spelled out rather than pattern-matched: the
-- alternation a regex would need (U?, INT vs INTEGER, the INT1..INT8 aliases) is longer than the
-- list, and a near-miss here silently changes how a comparison is compiled.
CREATE OR REPLACE MACRO tree_sql_is_numeric_type(t) AS
  upper(COALESCE(t, '')) IN ('TINYINT', 'SMALLINT', 'INTEGER', 'BIGINT', 'HUGEINT',
                             'UTINYINT', 'USMALLINT', 'UINTEGER', 'UBIGINT', 'UHUGEINT',
                             'FLOAT', 'DOUBLE', 'REAL', 'INT', 'INT1', 'INT2', 'INT4', 'INT8')
  OR starts_with(upper(COALESCE(t, '')), 'DECIMAL') OR starts_with(upper(COALESCE(t, '')), 'NUMERIC');

-- How a comparison against a PROJECTED column is spelled, given the column's declared type from
-- the attribute_columns artifact (NULL when the artifact predates types). The literal is spliced
-- as written except where that would mean something other than what it says:
--
--   * a quoted (or otherwise non-numeric) literal compares as written, as it always did;
--   * a number against a TEXT column compares as text -- `name = 5` used to compile to `name = 5`,
--     which DuckDB binds by casting the COLUMN, so the first row whose text is not a number
--     aborted the query instead of not matching (R7);
--   * a number against a numeric column keeps the numeric comparison, which is what corpus row
--     c16 (`.fn[params=2]`) reads;
--   * anything else -- a type the artifact does not record, or a column that is neither text nor
--     a number -- takes TRY_CAST, the reading that cannot abort. Same rule, and same reason, as
--     the ATTR MAP branch below.
CREATE OR REPLACE MACRO tree_sql_attr_col_cmp(alias, col, ctype, op, arg) AS
  CASE WHEN tree_sql_literal_type(arg) IS NULL
         THEN alias || '.' || tree_sql_ident(col) || ' ' || op || ' ' || arg
       WHEN upper(COALESCE(ctype, '')) = 'VARCHAR'
         THEN alias || '.' || tree_sql_ident(col) || ' ' || op || ' ' || tree_sql_lit(trim(arg))
       WHEN tree_sql_is_numeric_type(ctype)
         THEN alias || '.' || tree_sql_ident(col) || ' ' || op || ' ' || arg
       ELSE 'TRY_CAST(' || alias || '.' || tree_sql_ident(col) || ' AS ' || tree_sql_literal_type(arg) || ') '
            || op || ' ' || arg END;

-- Clause predicate on the step alias, which is passed in: a placeholder substituted afterwards
-- would rewrite any user text that happened to contain it. Attribute and pseudo filters are
-- NULL-definite. p is the projection relation text and elem the tree's ELEMENT flag, both only
-- for the positional built-ins. MN19 mutates the where branch.
CREATE OR REPLACE MACRO tree_sql_clause(kind, value, op, arg, alias, attr_cols, has_map, p, elem) AS
  CASE kind
    WHEN 'type'   THEN alias || '._type = ' || tree_sql_lit(value)
    WHEN 'id'     THEN alias || '._id = ' || tree_sql_lit(value)
    WHEN 'class'  THEN 'COALESCE(list_contains(' || alias || '._classes, ' || tree_sql_lit(value) || '), false)'
    -- The built-ins are compiled by tree_sql_builtin_pseudo, which returns NULL for every other
    -- name -- so this branch consults the one list rather than repeating it. A declared
    -- pseudo-class is a lookup in the projection's _pseudo map.
    WHEN 'pseudo' THEN COALESCE(tree_sql_builtin_pseudo(value, alias, p, elem),
                                'COALESCE(' || alias || '._pseudo[' || tree_sql_lit(value) || '], false)')
    -- An attribute resolves to a projected column first, then to ATTR MAP. The map is
    -- MAP(VARCHAR, VARCHAR), so a comparison against a number or a boolean has to cast the
    -- value ('3' > '10' is true as text); a quoted literal compares as text and needs none.
    -- TRY_CAST, not CAST: a row whose map holds text where a number was asked for should not
    -- match, not abort the query. MN13 mutates the cast.
    --
    -- The column lookup is CASE-INSENSITIVE, because SQL identifiers are and the projection's
    -- columns are SQL identifiers: `[Name=x]` on a tree whose column is `name` names that column.
    -- It used to be a byte comparison against the artifact, which on a MAP-less tree refused a
    -- mis-cased name outright and on a MAP tree did something worse -- fell past the column into
    -- the map, which serves every key, and answered no rows. The column is emitted with the
    -- spelling the projection STORES, so the generated SQL binds whatever the selector wrote.
    --
    -- A canonical column is not an attribute: it is the tree's own representation, and P14 says
    -- MATCH sees the projection's DECLARED attributes. Checked FIRST, before the map, for the
    -- same reason the case fold matters -- on an ATTR MAP tree `_level` would otherwise be a
    -- lookup for a key the map cannot hold, which reads as "no such row" rather than as "wrong
    -- question". WHERE is where a question about the representation belongs, so it is named.
    WHEN 'attr'   THEN CASE
        WHEN list_contains(tree_canonical_columns(), lower(COALESCE(value, '')))
          THEN tree_err('tree_match: attribute ' || value || ' is a canonical column, not an attribute; use a WHERE clause')
        WHEN len(list_filter(attr_cols, lambda c: lower((c).name) = lower(value))) > 0
          THEN 'COALESCE(' || tree_sql_attr_col_cmp(alias,
                 (list_filter(attr_cols, lambda c: lower((c).name) = lower(value))[1]).name,
                 (list_filter(attr_cols, lambda c: lower((c).name) = lower(value))[1])."type",
                 op, arg) || ', false)'
        WHEN has_map
          THEN 'COALESCE(' || CASE WHEN tree_sql_literal_type(arg) IS NULL
                                   THEN alias || '._attr_map[' || tree_sql_lit(value) || ']'
                                   ELSE 'TRY_CAST(' || alias || '._attr_map[' || tree_sql_lit(value) || '] AS ' || tree_sql_literal_type(arg) || ')' END
               || ' ' || op || ' ' || arg || ', false)'
        ELSE tree_err('tree_match: attribute ' || COALESCE(value, '<NULL>') || ' is neither a projected column nor served by ATTR MAP') END
    -- One level only: recursive := true flattens _root's struct into its component columns, so
    -- _root itself stops being addressable and falls through to an enclosing step alias
    -- (ambiguous, or worse, silently the wrong row). Unqualified names resolve to this step's
    -- own row first; another step's alias is legal when qualified (spec 6.2).
    WHEN 'where'  THEN 'EXISTS (SELECT 1 FROM (SELECT unnest(' || alias || ', recursive := false)) __w WHERE ' || value || ')'
    WHEN 'pseudo_unknown' THEN 'false'
    -- COALESCE for the same reason as the combinator above: a NULL kind is an IR node nothing
    -- in this codebase builds, so its refusal is the one a hand-built selector most needs.
    ELSE tree_err('tree_match: unknown clause kind ' || COALESCE(kind, '<NULL>')) END;

-- One step chain as FROM text. `steps` is STRUCT(node_id, alias, op, pred)[] in chain order and
-- `anchor` is the alias of the enclosing step when the chain is a group's, NULL when it is the
-- selector's own. Produces
--   <P> a1 JOIN <P> a2 ON <comb(a1, a2)> AND (<pred2>) ... WHERE <comb(anchor, a1) AND> <pred1>
-- The first step has nothing before it to join against, so its predicate becomes the WHERE. At
-- the top level that predicate is the whole WHERE and needs no parentheses; inside a group it is
-- ANDed with the relation to the anchor, so there it is parenthesized like every joined step's.
-- 1.5.5: list_transform's two-argument lambda indexes from 1, so steps[i - 1] is the previous step.
-- The empty-step refusal is the fragment's own guard, not the compiler's: a group with no inner
-- steps contributes no row to the fold's group pass, so nothing would call this for it. That case
-- is refused in chk. This branch is what stops a direct caller emitting a FROM with no relation.
CREATE OR REPLACE MACRO tree_sql_chain(p, steps, anchor, elem) AS
  CASE WHEN steps IS NULL OR len(steps) = 0 THEN tree_err('tree_match: empty group') ELSE
    list_aggregate(list_transform(steps, lambda s, i:
        CASE WHEN i = 1 THEN p || ' ' || (s).alias
             ELSE 'JOIN ' || p || ' ' || (s).alias || ' ON ' || tree_sql_comb((s).op, (steps[i - 1]).alias, (s).alias, p, elem)
                  || ' AND (' || (s).pred || ')' END), 'string_agg', ' ')
    || ' WHERE '
    -- COALESCE, although tree_steps already defaults a group's first inner step to desc: only the
    -- first step of the OUTER chain may carry a NULL op, and there anchor is NULL and no
    -- combinator is asked for. A hand-built IR that breaks that invariant would otherwise reach
    -- tree_sql_comb with a NULL op, whose refusal message concatenates to NULL and raises nothing.
    || CASE WHEN anchor IS NULL THEN (steps[1]).pred
            ELSE tree_sql_comb(COALESCE((steps[1]).op, 'desc'), anchor, (steps[1]).alias, p, elem) || ' AND (' || (steps[1]).pred || ')' END
  END;

-- A HAS/NOT group as a predicate on the step it hangs off: the group's own chain, anchored on
-- that step, under an (NOT) EXISTS. One definition, called once per unrolled pass of the fold --
-- which is also what filters `kind` down to 'has' or 'not' before it gets here.
CREATE OR REPLACE MACRO tree_sql_group(kind, p, steps, anchor, elem) AS
  CASE WHEN kind = 'not' THEN 'NOT ' ELSE '' END
  || 'EXISTS (SELECT 1 FROM ' || tree_sql_chain(p, steps, anchor, elem) || ')';

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
              -- The sibling-free refusal, which covers the POSITIONAL built-ins too: "first" and
              -- "last" mean nothing among siblings nothing orders. It tested the combinator
              -- alone, so `:first-child` on such a tree compiled to `_pre = _parent + 1` over a
              -- _pre no SIBLING_ORDER governs and answered with whatever rows happened to land
              -- there -- the one thing the sibling-free profile exists to prevent.
              WHEN (SELECT profile FROM t) = 'sibling_free'
                   AND ((ir.kind = 'step' AND ir.op IN ('next', 'after'))
                        OR (ir.kind = 'pseudo' AND list_contains(tree_builtin_pseudos(), ir.value)))
              THEN tree_err('tree_match: tree ' || sch || '.' || nm || ' is sibling-free (no SIBLING_ORDER declared); SIBLING, FOLLOWING, :first-child and :last-child are unavailable')
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

CREATE OR REPLACE MACRO tree_explain(sch, nm, sel, semantic := NULL, language := NULL) AS
  {treeql: tree_selector_to_treeql(sel), sql: tree_compile_match(sch, nm, sel, semantic := semantic, language := language),
   language: COALESCE(language, 'treeql')};
