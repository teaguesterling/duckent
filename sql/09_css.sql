-- sql/09_css.sql
--
-- The second css front-end: tree-sitter-css parse rows folded into the selector IR.
--
-- test/css_parser.py is the first one -- a recursive-descent parser over the selector TEXT. This
-- file lowers the PARSE TREE sitting_duck's tree-sitter-css grammar builds for the same text, and
-- the two are bound by a differential (test/sql/38_css_lower.test): for every v0 selector they
-- must produce the same rows -- same node ids, parents, kinds, values, ops, args, aliases -- and
-- refuse the same inputs with the same words. Two independent readings of one grammar is the
-- point; agreeing by construction would prove nothing.
--
-- What tree-sitter-css hands us, and the three facts the fold is built on (all read off real
-- parses, recorded in .superpowers/sdd/2026-09-14-duckent-m2/task-9-report.md):
--
-- 1. A bare selector is not a stylesheet, so the whole thing arrives wrapped in one ERROR node
--    under `stylesheet`. Punctuation (`.` `#` `:` `[` `]` `(` `)` `>` `+` `~` the `=`-family,
--    quotes) are child nodes too.
-- 2. A postfix simple selector nests around EVERYTHING to its left: `.fn#greet` parses as
--    id_selector(class_selector(`.fn`)), and `block > x:first-child` as
--    pseudo_class_selector(child_selector(block, x)). So a wrapper's clause belongs not to its
--    own subtree but to the RIGHTMOST compound inside it. Following that descent to its end
--    gives the compound's ANCHOR, which is what identifies a compound here.
-- 3. Because the nesting is postfix, the wrappers of one compound are numbered OUTERMOST FIRST
--    in the parse's preorder -- so DESCENDING node id is the order the parts were WRITTEN in,
--    which is the order the IR needs for two clauses of one kind and for groups.
--
-- The IR's own numbering is the numbering tree_steps uses (sql/06_selector.sql): dense, depth
-- first, a step followed by its clauses in slot order (type, id, class, attr, pseudo) and then by
-- its groups, a group node followed by every row of its inner chain. It is carried the same way
-- too, as a {i0, a0, i1, a1, i2, a2} path that 1.5.5 sorts and compares field by field, so one
-- column is the whole sort key and a row's parent path is the whole parent link.
--
-- WHERE PARITY IS NOT POSSIBLE. Two v0 constructs this front-end refuses and the runner accepts.
-- Neither can produce a WRONG selector -- both are refusals -- and a 3026-selector differential
-- (see the report) found no input the two accept and lower differently.
--
-- 1. A compound that begins with a QUOTED TYPE or a PSEUDO-CLASS, after a whitespace (descendant)
--    combinator: `a "select"`, `a :has(x)`, `a :first-child`. A bare space is the one combinator
--    with no token of its own, so tree-sitter-css has nothing telling it the selector continues
--    and reads what follows as css property syntax instead (`a :has(x)` becomes a `declaration`
--    whose value is a `call_expression`). The parse is not a selector at all, so there is nothing
--    to lower. Writing the combinator explicitly -- `a > :has(x)` -- or giving the compound a type
--    name parses fine; so does every other compound after a space (`a .c`, `a #i`, `a [n=1]`).
-- 2. HAS/NOT nested more than tree_group_depth_limit() deep. The runner builds those rows and
--    leaves the refusal to the printer and the compiler; here the path has one field pair per
--    level, so a level past the limit would collide with the level below it rather than overflow
--    visibly. It is refused where it is detected.

-- A combinator node type as the IR op it means.
CREATE OR REPLACE MACRO tree_css_comb(t) AS
  CASE t WHEN 'child_selector' THEN 'child'
         WHEN 'descendant_selector' THEN 'desc'
         WHEN 'adjacent_sibling_selector' THEN 'next'
         WHEN 'sibling_selector' THEN 'after' END;

-- The document-order path of one row, and of its parent. `lvl` is the row's group depth, `pos`
-- its 1-based place in its chain and `a` which of the step's parts it is: 0 the step's own row,
-- 1..n its parts in emitted order. Unlike tree_steps, which can give a clause its fixed slot
-- number because no tree_steps literal can carry two clauses of one kind, css can (`.b.a`), so
-- `a` is the part's RANK after the slot sort rather than the slot itself. Only the order matters
-- -- the numbers never leave this file.
CREATE OR REPLACE MACRO tree_css_path(lvl, i0, a0, i1, a1, pos, a) AS
  CASE lvl WHEN 0 THEN {i0: pos::INTEGER, a0: a::INTEGER, i1: 0, a1: 0, i2: 0, a2: 0}
           WHEN 1 THEN {i0: i0::INTEGER, a0: a0::INTEGER, i1: pos::INTEGER, a1: a::INTEGER, i2: 0, a2: 0}
           ELSE        {i0: i0::INTEGER, a0: a0::INTEGER, i1: i1::INTEGER, a1: a1::INTEGER, i2: pos::INTEGER, a2: a::INTEGER} END;
-- A step's parent: the selector root at level 0, else the group node its chain hangs under --
-- which is the row at the chain's prefix with the rest of the path zeroed.
CREATE OR REPLACE MACRO tree_css_ppath(lvl, i0, a0, i1, a1) AS
  CASE lvl WHEN 0 THEN {i0: 0, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0}
           WHEN 1 THEN {i0: i0::INTEGER, a0: a0::INTEGER, i1: 0, a1: 0, i2: 0, a2: 0}
           ELSE        {i0: i0::INTEGER, a0: a0::INTEGER, i1: i1::INTEGER, a1: a1::INTEGER, i2: 0, a2: 0} END;

-- Lower a tree-sitter-css parse -- `rows` is STRUCT(node_id BIGINT, parent_id BIGINT, type VARCHAR,
-- name VARCHAR)[] as parse_ast_list_table(sel, 'css') returns it -- to a TREE_SELECTOR.
--
-- One CTE per stage, each naming the css node types it reads. Nothing here re-reads the selector
-- text: `name` is used only where it carries an identifier or a literal the parse already
-- isolated (a class_name, an attribute_name, a string_value's quoted body). Recursive CTEs and
-- window functions are free here -- unlike the compiler's macros, a selector is never fed to
-- query().
CREATE OR REPLACE MACRO tree_css_lower(rows) AS (
  WITH RECURSIVE
  -- stage 1: the parse rows, and the role each css node type plays in a selector
  n AS (SELECT (r).node_id AS id, (r).parent_id AS pid, (r).type AS ty, (r).name AS nm
        FROM (SELECT unnest(rows) AS r)),
  c AS (SELECT x.id, x.pid, x.ty, x.nm, CASE
          WHEN x.ty IN ('child_selector', 'descendant_selector', 'adjacent_sibling_selector', 'sibling_selector') THEN 'comb'
          WHEN x.ty IN ('class_selector', 'id_selector', 'attribute_selector', 'pseudo_class_selector') THEN 'wrap'
          WHEN x.ty = 'tag_name' THEN 'tag'
          -- a selector that is nothing but a type name arrives as a bare `identifier` rather than
          -- a `tag_name` (there is no combinator to make tree-sitter commit to a selector); under
          -- a name carrier the same node is that carrier's text repeated, which is noise
          WHEN x.ty = 'identifier'
            THEN CASE WHEN p.ty IN ('class_name', 'id_name', 'attribute_name') THEN 'punct' ELSE 'tag' END
          WHEN x.ty = 'string_value' THEN 'str'
          WHEN x.ty = 'arguments' THEN 'args'
          WHEN x.ty IN ('class_name', 'id_name', 'attribute_name') THEN 'name'
          WHEN x.ty IN ('integer_value', 'float_value', 'plain_value') THEN 'val'
          WHEN x.ty = 'ERROR' THEN 'err'
          WHEN x.ty = 'stylesheet' THEN 'root'
          WHEN x.ty IN ('.', '#', ':', '[', ']', '(', ')', '=', '^=', '$=', '*=', '~=', '|=',
                        '>', '+', '~', ',', '"', '''', 'string_content') THEN 'punct'
          ELSE 'other' END AS cls
        FROM n x LEFT JOIN n p ON p.id = x.pid),

  -- stage 2: the attribute selector's parts. The comparison token tells the value slot apart
  -- from a quoted TYPE in the same node (`"select"[n=1]` has a string_value on either side of it).
  attr_op AS (SELECT p.id AS sel, min(t.id) AS tok, min_by(t.ty, t.id) AS op
              FROM c p JOIN c t ON t.pid = p.id
              WHERE p.ty = 'attribute_selector' AND t.ty IN ('=', '^=', '$=', '*=', '~=', '|=')
              GROUP BY p.id),
  attr_val AS (SELECT o.sel, min(v.id) AS id FROM attr_op o JOIN c v ON v.pid = o.sel
               WHERE v.ty IN ('string_value', 'integer_value', 'float_value', 'plain_value') AND v.id > o.tok
               GROUP BY o.sel),
  attr_name AS (SELECT p.id AS sel, min_by(k.nm, k.id) AS nm FROM c p JOIN c k ON k.pid = p.id AND k.ty = 'attribute_name'
                WHERE p.ty = 'attribute_selector' GROUP BY p.id),
  -- the selector nodes: what a compound and a chain are built out of. A string_value is a TYPE
  -- in quotes -- the v0 spelling that lets a host keyword be a node type -- unless it is the
  -- value slot of an attribute selector.
  s AS (SELECT * FROM c WHERE cls IN ('comb', 'wrap', 'tag')
        UNION ALL SELECT * FROM c WHERE cls = 'str' AND id NOT IN (SELECT id FROM attr_val)),

  -- stage 3: the compound. `wrapped` is a wrapper's operand (its first child, when that child is a
  -- selector node); `opnd` are a combinator's operands in written order. `down` is the descent to
  -- the compound a postfix part belongs to: a wrapper into its operand, a combinator into its
  -- RIGHT operand. Following it to its end gives the compound's anchor.
  first_child AS (SELECT pid AS p, min(id) AS f FROM c WHERE pid IS NOT NULL GROUP BY pid),
  wrapped AS (SELECT w.id AS w, f.f AS i FROM c w JOIN first_child f ON f.p = w.id JOIN s k ON k.id = f.f
              WHERE w.cls = 'wrap'),
  opnd AS (SELECT p.id AS p, k.id AS k, row_number() OVER (PARTITION BY p.id ORDER BY k.id) AS side,
                  count(*) OVER (PARTITION BY p.id) AS nop, p.ty AS pty
           FROM c p JOIN s k ON k.pid = p.id WHERE p.cls = 'comb'),
  down AS (SELECT w AS node, i AS "to" FROM wrapped
           UNION ALL SELECT p, k FROM opnd WHERE side = nop),
  anch AS (SELECT k.id AS node, k.id AS anchor FROM s k WHERE k.id NOT IN (SELECT node FROM down)
           UNION ALL SELECT d.node, a.anchor FROM anch a JOIN down d ON d."to" = a.node),
  -- the parts of a compound: its anchor and every postfix wrapper that re-associated onto it.
  -- Combinator nodes carry no clause, so they are not parts.
  part AS (SELECT a.anchor, k.id, k.ty, k.cls, k.nm FROM anch a JOIN c k ON k.id = a.node WHERE k.cls <> 'comb'),

  -- stage 4: the pseudo-class. Its name is a `class_name` child of pseudo_class_selector; an
  -- `arguments` child means it was written with an argument.
  pname AS (SELECT p.id, min_by(k.nm, k.id) AS nm FROM c p JOIN c k ON k.pid = p.id AND k.ty = 'class_name'
            WHERE p.ty = 'pseudo_class_selector' GROUP BY p.id),
  pargs AS (SELECT p.id, min(k.id) AS a FROM c p JOIN c k ON k.pid = p.id AND k.ty = 'arguments'
            WHERE p.ty = 'pseudo_class_selector' GROUP BY p.id),
  argroot AS (SELECT g.id AS a, min(k.id) AS r, count(k.id) AS n FROM c g LEFT JOIN s k ON k.pid = g.id
              WHERE g.ty = 'arguments' GROUP BY g.id),
  -- the HAS/NOT groups, each on the step its pseudo-class re-associated onto
  gnode AS (SELECT np.id AS g, np.nm AS gkind, ar.r AS argroot, pt.anchor AS step
            FROM pname np JOIN pargs pa ON pa.id = np.id JOIN argroot ar ON ar.a = pa.a
                 JOIN part pt ON pt.id = np.id
            WHERE np.nm IN ('has', 'not')),
  -- the collapse: `:not(:has(R))`, the argument being exactly one `:has(...)` and nothing else,
  -- is NOT ( R ) -- "no descendant matches R" IS "not a row that has a descendant matching R".
  -- It keeps the spec's flagship at one group level and makes the rows tree_steps' rows for
  -- [{..., "not": [R]}]. Recognised here as a `not` whose argument root is a has-group carrying
  -- no operand of its own.
  collapse AS (SELECT g.g, h.argroot AS "to" FROM gnode g JOIN gnode h ON h.g = g.argroot
               WHERE g.gkind = 'not' AND h.gkind = 'has' AND h.g NOT IN (SELECT w FROM wrapped)),
  -- what a group's inner chain actually is, and what its first step is anchored by: `:has(R)`
  -- anchors R on a descendant (or on R's own leading combinator, written relative); `:not(C)`
  -- anchors C on the subject row itself, which is what `self` is for (task-7-self-ruling.md).
  grp AS (SELECT g.g, g.gkind, g.step, COALESCE(co."to", g.argroot) AS root,
                 CASE WHEN g.gkind = 'not' AND co."to" IS NULL THEN 'self'
                      ELSE COALESCE((SELECT tree_css_comb(o.pty) FROM opnd o
                                     WHERE o.p = COALESCE(co."to", g.argroot) AND o.nop = 1), 'desc') END AS lead
          FROM gnode g LEFT JOIN collapse co ON co.g = g.g),

  -- stage 5: the chains. A chain is one `complex` -- compounds joined by combinators. Its root is
  -- the selector's own top node or the single selector child of an `arguments`; membership
  -- follows wrapper operands and combinator operands, never an `arguments`, so each group's
  -- chain is its own. The steps of a chain are the distinct anchors among its nodes, and anchor
  -- ids rise left to right, so ordering by anchor is source order.
  container AS (SELECT COALESCE((SELECT min(id) FROM c WHERE cls = 'err'), (SELECT id FROM c WHERE pid IS NULL)) AS id),
  root_of AS (SELECT min(k.id) AS r, count(*) AS n FROM s k WHERE k.pid = (SELECT id FROM container)),
  chainof AS (SELECT (SELECT r FROM root_of) AS root, (SELECT r FROM root_of) AS node
              UNION ALL SELECT r, r FROM (SELECT root AS r FROM grp)
              UNION ALL SELECT ch.root, e."to" FROM chainof ch JOIN
                (SELECT w AS node, i AS "to" FROM wrapped UNION ALL SELECT p, k FROM opnd) e ON e.node = ch.node),
  steps AS (SELECT root, anchor, row_number() OVER (PARTITION BY root ORDER BY anchor) AS pos
            FROM (SELECT DISTINCT ch.root, a.anchor FROM chainof ch JOIN anch a ON a.node = ch.node)),
  -- the combinator a step's compound hangs off. A relative combinator (`:has(> block)`) has one
  -- operand and gives its chain's LEAD op instead, so only binary ones are read here.
  sop AS (SELECT a.anchor, tree_css_comb(o.pty) AS op FROM opnd o JOIN anch a ON a.node = o.k
          WHERE o.nop = 2 AND o.side = 2),

  -- stage 6: one row per emitted clause, with the slot tree_steps numbers it in. Written order
  -- within a compound is DESCENDING node id (fact 3), which is the tiebreak inside a slot.
  clause AS (
    SELECT anchor, id, 1 AS slot, 'type' AS kind, nm AS value, NULL::VARCHAR AS op, NULL::VARCHAR AS arg
      FROM part WHERE cls = 'tag'
    UNION ALL SELECT anchor, id, 1, 'type', substr(nm, 2, length(nm) - 2), NULL, NULL FROM part WHERE cls = 'str'
    UNION ALL SELECT p.anchor, p.id, 2, 'id', min_by(k.nm, k.id), NULL, NULL
      FROM part p JOIN c k ON k.pid = p.id AND k.ty = 'id_name' WHERE p.ty = 'id_selector' GROUP BY p.anchor, p.id
    UNION ALL SELECT p.anchor, p.id, 3, 'class', min_by(k.nm, k.id), NULL, NULL
      FROM part p JOIN c k ON k.pid = p.id AND k.ty = 'class_name' WHERE p.ty = 'class_selector' GROUP BY p.anchor, p.id
    -- the attribute operators v0 gives a meaning: `=` compares, the three affix forms become LIKE
    -- with the wildcard built in. A bare number under `=` is left unquoted so an ATTR MAP lookup
    -- is cast to its type before comparing; everything else is a quoted text literal.
    UNION ALL SELECT p.anchor, p.id, 4, 'attr', an.nm,
        CASE WHEN o.op = '=' THEN '=' ELSE 'LIKE' END,
        CASE WHEN o.op = '=' AND v.ty IN ('integer_value', 'float_value') THEN raw.t
             WHEN o.op = '=' THEN tree_sql_lit(raw.t)
             WHEN o.op = '^=' THEN tree_sql_lit(raw.t || '%')
             WHEN o.op = '$=' THEN tree_sql_lit('%' || raw.t)
             ELSE tree_sql_lit('%' || raw.t || '%') END
      FROM part p JOIN attr_op o ON o.sel = p.id JOIN attr_name an ON an.sel = p.id
           JOIN attr_val av ON av.sel = p.id JOIN c v ON v.id = av.id
           JOIN (SELECT v2.id, CASE WHEN v2.ty = 'string_value' THEN substr(v2.nm, 2, length(v2.nm) - 2) ELSE v2.nm END AS t
                 FROM c v2) raw ON raw.id = v.id
      WHERE p.ty = 'attribute_selector'
    -- an argument-less pseudo-class is kept whatever its name: deciding it is unknown is the
    -- match compiler's job, and it counts one. The capture marker is not one of these -- it is
    -- the `@name` tree_parse_css rewrote, and it binds the step, not the row (stage 7).
    UNION ALL SELECT p.anchor, p.id, 5, 'pseudo', np.nm, NULL, NULL
      FROM part p JOIN pname np ON np.id = p.id
      WHERE p.ty = 'pseudo_class_selector' AND p.id NOT IN (SELECT id FROM pargs)
        AND NOT starts_with(np.nm, '__cap_')),
  ranked AS (SELECT anchor, id, kind, value, op, arg,
                    row_number() OVER (PARTITION BY anchor ORDER BY slot, id DESC) AS a,
                    count(*) OVER (PARTITION BY anchor) AS nclause
             FROM clause),
  -- a step's groups come after every one of its clauses, in written order
  granked AS (SELECT g.g, g.step, g.gkind, g.root, g.lead,
                     COALESCE((SELECT max(r.nclause) FROM ranked r WHERE r.anchor = g.step), 0)
                       + row_number() OVER (PARTITION BY g.step ORDER BY g.g DESC) AS a
              FROM grp g),

  -- stage 7: the capture. `@name` has no css spelling, so tree_parse_css rewrote it to a marker
  -- pseudo-class before parsing; here it comes back off the step as its alias.
  alias AS (SELECT p.anchor, min_by(substr(np.nm, 7), p.id) AS a, count(*) AS n
            FROM part p JOIN pname np ON np.id = p.id
            WHERE p.ty = 'pseudo_class_selector' AND starts_with(np.nm, '__cap_')
            GROUP BY p.anchor),

  -- stage 8: place every chain at its group depth, carrying the path prefix its ancestors used.
  -- The top chain is level 0; each group on one of its steps opens a chain one level down.
  chains AS (SELECT (SELECT r FROM root_of) AS root, NULL::VARCHAR AS lead, 0 AS lvl,
                    0 AS i0, 0 AS a0, 0 AS i1, 0 AS a1
             UNION ALL
             SELECT g.root, g.lead, ch.lvl + 1,
                    CASE ch.lvl WHEN 0 THEN st.pos ELSE ch.i0 END,
                    CASE ch.lvl WHEN 0 THEN g.a ELSE ch.a0 END,
                    CASE ch.lvl WHEN 1 THEN st.pos ELSE ch.i1 END,
                    CASE ch.lvl WHEN 1 THEN g.a ELSE ch.a1 END
             FROM chains ch JOIN steps st ON st.root = ch.root JOIN granked g ON g.step = st.anchor),
  -- every step that reaches the IR, with its op: the combinator it hangs off, or its chain's lead
  placed AS (SELECT ch.lvl, ch.i0, ch.a0, ch.i1, ch.a1, st.pos, st.anchor,
                    COALESCE(so.op, ch.lead) AS op, al.a AS alias
             FROM chains ch JOIN steps st ON st.root = ch.root
                  LEFT JOIN sop so ON so.anchor = st.anchor
                  LEFT JOIN alias al ON al.anchor = st.anchor),

  -- stage 9: the IR rows, as paths to be numbered
  nodes AS (
    SELECT {i0: 0, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0} AS path,
           {i0: -1, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0} AS ppath,
           'selector' AS kind, NULL::VARCHAR AS value, NULL::VARCHAR AS op, NULL::VARCHAR AS arg, NULL::VARCHAR AS alias
    UNION ALL
    SELECT tree_css_path(p.lvl, p.i0, p.a0, p.i1, p.a1, p.pos, 0), tree_css_ppath(p.lvl, p.i0, p.a0, p.i1, p.a1),
           'step', NULL, p.op, NULL, p.alias FROM placed p
    UNION ALL
    SELECT tree_css_path(p.lvl, p.i0, p.a0, p.i1, p.a1, p.pos, r.a),
           tree_css_path(p.lvl, p.i0, p.a0, p.i1, p.a1, p.pos, 0),
           r.kind, r.value, r.op, r.arg, NULL FROM placed p JOIN ranked r ON r.anchor = p.anchor
    UNION ALL
    SELECT tree_css_path(p.lvl, p.i0, p.a0, p.i1, p.a1, p.pos, g.a),
           tree_css_path(p.lvl, p.i0, p.a0, p.i1, p.a1, p.pos, 0),
           g.gkind, NULL, NULL, NULL, NULL FROM placed p JOIN granked g ON g.step = p.anchor),
  numbered AS (SELECT CAST(row_number() OVER (ORDER BY path) - 1 AS INTEGER) AS node_id, * FROM nodes),
  parented AS (SELECT n.node_id, p.node_id AS parent_id, n.kind, n.value, n.op, n.arg, n.alias
               FROM numbered n LEFT JOIN numbered p ON p.path = n.ppath),

  -- stage 10: the refusals, each for something the fold would otherwise swallow. They are checked
  -- in the order below, which is why each reads only what the ones before it have let through.
  --
  -- WHERE is TREEQL's host escape into raw SQL. css has no such escape, and `[WHERE ...]` does not
  -- reach the fold as an attribute at all -- tree-sitter reads `[WHERE x > 2]` as a bracket, a
  -- descendant selector and a stray `>` -- so it is caught first, on the name that follows a `[`.
  bad_where AS (SELECT count(*) AS n FROM c b JOIN c k
                  ON k.id = (SELECT min(x.id) FROM c x WHERE x.id > b.id
                               AND x.ty IN ('attribute_name', 'tag_name', 'identifier', 'plain_value', 'class_name', 'id_name'))
                WHERE b.ty = '[' AND upper(k.nm) = 'WHERE'),
  -- a css node type this fold has no reading for: a selector list (`a, b`), an at-rule, a
  -- declaration. Checked before the loose-token and shape tests, because a parse that went
  -- somewhere else entirely leaves BOTH -- and naming the construct the css grammar actually
  -- built says more than calling its wreckage junk.
  bad_type AS (SELECT min(ty) AS t FROM c WHERE cls = 'other'),
  -- a bracket, paren or quote left open stops tree-sitter mid-selector and its token lands loose
  -- under the ERROR node instead of inside a selector node
  bad_open AS (SELECT min_by(k.ty, k.id) AS t FROM c k
               WHERE k.pid = (SELECT id FROM container) AND k.ty IN ('(', '[', '"', '''')),
  -- the whole selector must be ONE selector node under the container. Nothing (an empty text),
  -- several (trailing junk), or a loose token (a dangling combinator) is not a v0 selector.
  bad_shape AS (SELECT CASE WHEN (SELECT n FROM root_of) = 0 THEN 'end of selector'
                            WHEN (SELECT count(*) FROM c WHERE pid = (SELECT id FROM container)) > 1
                              THEN 'text after the selector'
                            WHEN (SELECT count(*) FROM c WHERE cls = 'err') > 1 THEN 'text after the selector'
                            ELSE NULL END AS t),
  -- a combinator with one operand is a RELATIVE selector, which only `:has()` gives an anchor to
  bad_rel AS (SELECT count(*) AS n FROM opnd o JOIN c p ON p.id = o.p JOIN c g ON g.id = p.pid
              WHERE o.nop = 1 AND g.ty <> 'arguments'),
  -- `:nth-child(2)` and friends: dropping the argument would silently change what is asked
  bad_pseudo AS (SELECT min(np.nm) AS nm FROM pname np JOIN pargs pa ON pa.id = np.id WHERE np.nm NOT IN ('has', 'not')),
  bad_arg AS (SELECT count(*) AS n FROM argroot WHERE n <> 1),
  -- `:not(<chain with combinators>)` has nothing for the chain to anchor on, and guessing an
  -- anchor is how `:not` came to mean a descendant test in the first place
  bad_not AS (SELECT count(*) AS n FROM gnode g JOIN c r ON r.id = g.argroot WHERE g.gkind = 'not' AND r.cls = 'comb'),
  bad_attr AS (SELECT min(an.nm) AS nm FROM attr_name an LEFT JOIN attr_op o ON o.sel = an.sel
                 LEFT JOIN attr_val av ON av.sel = an.sel
               WHERE o.sel IS NULL OR av.sel IS NULL OR o.op NOT IN ('=', '^=', '$=', '*=')),
  -- the quotes let a KEYWORD be a type name; they do not let anything else be one
  bad_qtype AS (SELECT min(nm) AS t FROM part
                WHERE cls = 'str' AND NOT regexp_matches(substr(nm, 2, length(nm) - 2), '^[A-Za-z_][A-Za-z0-9_-]*$')),
  bad_cap_second AS (SELECT count(*) AS n FROM alias WHERE n > 1),
  -- a step inside HAS/NOT is a test, not a row of the result, so there is nothing to name
  bad_cap_in_group AS (SELECT count(*) AS n FROM alias a JOIN placed p ON p.anchor = a.anchor WHERE p.lvl > 0),
  bad_depth AS (SELECT max(lvl) AS d FROM chains)

  SELECT CASE
    WHEN (SELECT n FROM bad_where) > 0
      THEN error('css: css has no host escape: mint a PSEUDO, or MATCH USING TREEQL')
    WHEN (SELECT t FROM bad_type) IS NOT NULL
      THEN error('css: unexpected ' || (SELECT t FROM bad_type) || ': the css grammar did not read this as a v0 selector')
    WHEN (SELECT t FROM bad_open) IS NOT NULL
      THEN error('css: unclosed ' || (SELECT t FROM bad_open) || ' in selector')
    WHEN (SELECT t FROM bad_shape) IS NOT NULL THEN error('css: unexpected ' || (SELECT t FROM bad_shape))
    WHEN (SELECT n FROM bad_rel) > 0 THEN error('css: unexpected combinator with nothing on its left')
    WHEN (SELECT nm FROM bad_pseudo) IS NOT NULL
      THEN error('css: :' || (SELECT nm FROM bad_pseudo) || '() is not supported in v0')
    WHEN (SELECT n FROM bad_arg) > 0 THEN error('css: unexpected empty :has()/:not() argument')
    WHEN (SELECT n FROM bad_not) > 0 THEN error('css: :not() takes a compound selector in v0')
    WHEN (SELECT nm FROM bad_attr) IS NOT NULL
      THEN error('css: expected one of = ^= $= *= after attribute ' || (SELECT nm FROM bad_attr))
    WHEN (SELECT t FROM bad_qtype) IS NOT NULL
      THEN error('css: expected a type name in quotes, got ' || (SELECT t FROM bad_qtype))
    WHEN (SELECT n FROM bad_cap_second) > 0 THEN error('css: unexpected second capture')
    WHEN (SELECT n FROM bad_cap_in_group) > 0 THEN error('css: capture inside :has/:not has no row to bind')
    WHEN (SELECT d FROM bad_depth) > tree_group_depth_limit()
      THEN error('css: groups nested deeper than ' || tree_group_depth_limit() || ' levels are not supported')
    ELSE list({node_id: node_id, parent_id: parent_id, kind: kind, value: value,
               op: op, arg: arg, alias: alias} ORDER BY node_id)::TREE_SELECTOR END
  FROM parented);

-- `@name` is duckent's capture syntax and tree-sitter-css has never heard of it, so the text is
-- rewritten before it is parsed: each `@name` becomes the marker pseudo-class `:__cap_name`,
-- which the css grammar does accept and stage 7 reads back off the step as its alias. A `@` inside
-- a quoted value is left alone -- the text is split on the quote character and only the segments
-- OUTSIDE a string are rewritten.
CREATE OR REPLACE MACRO tree_css_capture_markers(t) AS
  array_to_string(list_transform(str_split(t, '"'), (seg, i) -> CASE WHEN i % 2 = 1
      THEN array_to_string(list_transform(str_split(seg, ''''), (sub, j) -> CASE WHEN j % 2 = 1
             THEN regexp_replace(sub, '@([A-Za-z_][A-Za-z0-9_-]*)', ':__cap_\1', 'g') ELSE sub END), '''')
      ELSE seg END), '"');

-- Parse selector text with tree-sitter-css and lower it. This is the only macro here that needs
-- sitting_duck; the table function is reached through query() so that THIS FILE still loads on a
-- build without the extension (1.5.5 binds a table-function name at CREATE MACRO time, so writing
-- parse_ast_list_table directly would make sql/09_css.sql unloadable there). Calling it without
-- the extension then fails with the catalog error naming parse_ast_list_table, which says what is
-- missing. The selector text has to be a constant, which it is: like the runner's parser, this
-- runs at the point a selector is written, not per row.
CREATE OR REPLACE MACRO tree_parse_css(sel) AS (
  SELECT CASE
    WHEN sel IS NULL THEN error('css: no selector text')
    -- the marker is an internal spelling; a selector that already used it would be read as a
    -- capture, so it is refused rather than quietly turned into one
    WHEN regexp_matches(sel, ':__cap_') THEN error('css: :__cap_ is reserved for the @name capture rewrite')
    ELSE tree_css_lower(
      (SELECT list({node_id: node_id, parent_id: parent_id, type: type, name: name} ORDER BY node_id)
       FROM query('SELECT node_id, parent_id, type, name FROM parse_ast_list_table('
                  || tree_sql_lit(tree_css_capture_markers(sel)) || ', ''css'')'))) END);
