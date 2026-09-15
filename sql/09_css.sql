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
-- WHERE PARITY IS NOT POSSIBLE. Three v0 constructs this front-end refuses and the runner accepts.
-- None can produce a WRONG selector -- all three are refusals -- and a 3444-selector differential
-- (see the report) found no input the two accept and lower differently.
--
-- 1. A compound that begins with a QUOTED TYPE or a PSEUDO-CLASS, after a whitespace (descendant)
--    combinator: `a "select"`, `a :has(x)`, `a :first-child`. A bare space is the one combinator
--    with no token of its own, so tree-sitter-css has nothing telling it the selector continues
--    and reads what follows as css property syntax instead (`a :has(x)` becomes a `declaration`
--    whose value is a `call_expression`). The parse is not a selector at all, so there is nothing
--    to lower. Writing the combinator explicitly -- `a > :has(x)` -- or giving the compound a type
--    name parses fine; so does every other compound after a space (`a .c`, `a #i`, `a [n=1]`).
-- 2. An argument-less `:where` or `:is`. The css grammar knows those two names ONLY as functional
--    pseudo-classes, so written bare they do not form a pseudo_class_selector at all -- the `:`
--    and the name land loose under the container and the selector stops there. The runner keeps
--    any argument-less pseudo-class whatever its name (deciding it is unknown is the match
--    compiler's job), so it accepts them; there is nothing here to accept.
-- 3. HAS/NOT nested more than tree_group_depth_limit() deep. The runner builds those rows and
--    leaves the refusal to the printer and the compiler; here the path has one field pair per
--    level, so a level past the limit would collide with the level below it rather than overflow
--    visibly. It is refused where it is detected.
--
-- And one WORDING-ONLY divergence, on an input both front-ends refuse: trailing junk (`.fn!!`).
-- The runner names the offending character (`unexpected '!'`); tree-sitter reports junk as a
-- second child of the container without saying where it starts, so the refusal here names the
-- situation instead (`unexpected text after the selector`). Every other refusal in the corpus
-- agrees with the runner on its first distinguishing token.

-- Refuse with `msg`, and refuse even when building `msg` went wrong. `error(NULL)` does not raise
-- in 1.5.5 -- it evaluates to NULL -- so a refusal whose message concatenates a value that turns
-- out to be NULL would silently hand the caller a NULL TREE_SELECTOR instead of an error. Every
-- refusal in this file goes through here, so that failure mode cannot come back. The Task 13
-- audit found the same hazard outside this file and answered it with `tree_err` (sql/00_types.sql);
-- this one stays because its fallback names the css parse, which is the only thing that can
-- have gone wrong here.
CREATE OR REPLACE MACRO tree_css_err(msg) AS
  error(COALESCE(msg, 'css: internal: a refusal built a NULL message; the parse shape was not anticipated'));

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
          -- `not` is a keyword NODE in the css grammar, not a class_name, and it only surfaces
          -- when the `:not(` it opens was never closed -- the refusal reads the name off its type
          WHEN x.ty IN ('.', '#', ':', '[', ']', '(', ')', '=', '^=', '$=', '*=', '~=', '|=',
                        '>', '+', '~', ',', '"', '''', 'string_content', 'not') THEN 'punct'
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

  -- stage 3: the compound. One edge set carries every structural link inside a chain: a wrapper to
  -- its operand (its first child, when that child is a selector node), a combinator to each of its
  -- operands in written order. Three descents are read off it:
  --   * all of it        -- what belongs to the same chain (stage 5)
  --   * `rightmost`      -- the descent to the compound a postfix part belongs to (fact b), whose
  --                         end is the compound's ANCHOR
  --   * `leftmost` and not `relative` -- the descent to where a RELATIVE selector's leading
  --                         combinator would be (stage 4). It stops AT a relative combinator,
  --                         which is why that one edge is flagged rather than dropped.
  first_child AS (SELECT pid AS p, min(id) AS f FROM c WHERE pid IS NOT NULL GROUP BY pid),
  wrapped AS (SELECT w.id AS w, f.f AS i FROM c w JOIN first_child f ON f.p = w.id JOIN s k ON k.id = f.f
              WHERE w.cls = 'wrap'),
  opnd AS (SELECT p.id AS p, k.id AS k, row_number() OVER (PARTITION BY p.id ORDER BY k.id) AS side,
                  count(*) OVER (PARTITION BY p.id) AS nop, p.ty AS pty
           FROM c p JOIN s k ON k.pid = p.id WHERE p.cls = 'comb'),
  edge AS (SELECT w AS node, i AS "to", true AS leftmost, true AS rightmost, false AS relative FROM wrapped
           UNION ALL SELECT p, k, side = 1, side = nop, nop = 1 FROM opnd),
  anch AS (SELECT k.id AS node, k.id AS anchor FROM s k
             WHERE k.id NOT IN (SELECT node FROM edge WHERE rightmost)
           UNION ALL SELECT e.node, a.anchor FROM anch a JOIN edge e ON e."to" = a.node AND e.rightmost),
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
  -- A RELATIVE selector is a combinator written with only a right operand -- the `>` in
  -- `:has(> block)`. It is NOT in general the argument's root node: every postfix part and every
  -- later combinator wraps around it, so `:has(> x#i)` is id_selector(child_selector('> x')) and
  -- `:has(> x y)` is descendant_selector(child_selector('> x'), y). It sits at the LEFT-SPINE
  -- terminus of the argument's subtree, so that is where both the lead op and the legality check
  -- read it -- together, because reading it in only one place would turn a refusal into a silent
  -- DESCENDANT-for-CHILD row difference.
  lspine AS (SELECT k.id AS node, k.id AS head FROM s k
               WHERE k.id NOT IN (SELECT node FROM edge WHERE leftmost AND NOT relative)
             UNION ALL SELECT e.node, l.head FROM lspine l
               JOIN edge e ON e."to" = l.node AND e.leftmost AND NOT e.relative),
  relcomb AS (SELECT o.p AS id, o.pty AS ty, min_by(t.ty, t.id) AS tok
              FROM opnd o JOIN c t ON t.pid = o.p AND t.ty IN ('>', '+', '~')
              WHERE o.nop = 1 GROUP BY o.p, o.pty),
  -- what a group's inner chain actually is, and what its first step is anchored by: `:has(R)`
  -- anchors R on a descendant, or on R's own leading combinator when R is written relative;
  -- `:not(C)` anchors C on the subject row itself, which is what `self` is for
  -- (task-7-self-ruling.md). `head` is carried out so the legality check can see which relative
  -- combinators are the ones a `:has()` argument is entitled to.
  grp AS (SELECT g.g, g.gkind, g.step, COALESCE(co."to", g.argroot) AS root, l.head,
                 CASE WHEN g.gkind = 'not' AND co."to" IS NULL THEN 'self'
                      ELSE COALESCE(tree_css_comb(r.ty), 'desc') END AS lead
          FROM gnode g LEFT JOIN collapse co ON co.g = g.g
               JOIN lspine l ON l.node = COALESCE(co."to", g.argroot)
               LEFT JOIN relcomb r ON r.id = l.head),

  -- stage 5: the chains. A chain is one `complex` -- compounds joined by combinators. Its root is
  -- the selector's own top node or the single selector child of an `arguments`; membership
  -- follows wrapper operands and combinator operands, never an `arguments`, so each group's
  -- chain is its own. The steps of a chain are the distinct anchors among its nodes, and anchor
  -- ids rise left to right, so ordering by anchor is source order.
  container AS (SELECT COALESCE((SELECT min(id) FROM c WHERE cls = 'err'), (SELECT id FROM c WHERE pid IS NULL)) AS id),
  root_of AS (SELECT min(k.id) AS r, count(*) AS n FROM s k WHERE k.pid = (SELECT id FROM container)),
  chainof AS (SELECT (SELECT r FROM root_of) AS root, (SELECT r FROM root_of) AS node
              UNION ALL SELECT r, r FROM (SELECT root AS r FROM grp)
              UNION ALL SELECT ch.root, e."to" FROM chainof ch JOIN edge e ON e.node = ch.node),
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
  -- a `,` is a selector list, which v0 does not have. Named by its token so the refusal reads the
  -- way the runner parser's does.
  bad_list AS (SELECT count(*) AS n FROM c WHERE ty = ','),
  -- tree-sitter-css read the text as css PROPERTY syntax (`a :has(x)` becomes a declaration whose
  -- value is a call_expression) or as a comma-less selector list, rather than as a selector at
  -- all. That is the lossy family in note 1 of the header, so the refusal says what to write.
  -- The third shape is a pseudo-class that parsed COMPLETELY -- its parens are balanced -- but
  -- was left lying beside the selector instead of attached to it (`#i :has(b)`). Balance is what
  -- tells it from a truncated `.fn:has(block`, which leaves a `(` and no `)`.
  bad_property AS (SELECT count(*) AS n FROM c
                   WHERE ty IN ('declaration', 'property_name', 'call_expression', 'function_name')
                      OR (ty = 'selectors' AND (SELECT count(*) FROM c t WHERE t.ty = ',') = 0)
                      -- ... or a pseudo-class whose parens BALANCE -- so it parsed completely --
                      -- left lying beside the selector with its `)` loose under the container
                      -- instead of attached to it (`#i :has(b)`, `a :not(.c)`). Balance is what
                      -- tells those from a truncated `.fn:has(block`, which never closes; and a
                      -- combinator left loose beside the parens (`a:has(x > )`) means the argument
                      -- ran out mid-chain, which is a truncation too.
                      OR (ty = ')' AND pid = (SELECT id FROM container)
                          AND (SELECT count(*) FROM c t WHERE t.ty = '(')
                            = (SELECT count(*) FROM c t WHERE t.ty = ')')
                          AND (SELECT count(*) FROM c t WHERE t.ty IN ('>', '+', '~')
                                 AND t.pid = (SELECT id FROM container)) = 0)),
  -- an argument-less `:where` / `:is`: the css grammar knows those two names ONLY as functional
  -- pseudo-classes, so written bare they do not even form a pseudo_class_selector -- the `:` and
  -- the name land loose under the container. Note 2 of the header.
  -- ... which is a COMPLETE parse with a loose `:name` in it, not a truncated one, so it does not
  -- fire for `.fn:has(block` -- there the same two nodes come loose because the `(` was left open
  bad_bare_fn AS (SELECT min_by(k.nm, k.id) AS nm FROM c t JOIN c k ON k.pid = t.pid AND k.ty = 'class_name' AND k.id > t.id
                  WHERE t.ty = ':' AND t.pid = (SELECT id FROM container)
                    AND (SELECT count(*) FROM c x WHERE x.pid = (SELECT id FROM container)
                           AND x.ty IN ('(', '[', '"', '''')) = 0),
  -- a css node type this fold has no reading for: an at-rule, a block, a keyframe. Checked before
  -- the loose-token and shape tests, because a parse that went somewhere else entirely leaves
  -- BOTH -- and naming the construct the css grammar actually built says more than calling its
  -- wreckage junk.
  bad_type AS (SELECT min(ty) AS t FROM c WHERE cls = 'other'),
  -- a bracket, paren or quote left open stops tree-sitter mid-selector and its token lands loose
  -- under the ERROR node instead of inside a selector node. For a `(` the pseudo-class it belongs
  -- to is the class_name just before it, which is what makes this read `unclosed :has(`.
  -- the LAST one, so `.fn[name="sh]` -- which leaves both a `[` and a `"` loose -- is reported as
  -- the unclosed quote the runner parser reports, not as the bracket around it. `pseudo` is the
  -- pseudo-class an open `(` belongs to, read from the node just before it: normally a
  -- `class_name`, but for `not` the css grammar has a keyword node whose TYPE is the name and
  -- whose text is empty. It stays NULL when the `(` follows no pseudo at all (`a(`), which the
  -- refusal arm handles rather than concatenating a NULL into the message.
  bad_open AS (SELECT max_by(k.ty, k.id) AS t,
                      (SELECT max_by(CASE WHEN x.ty = 'not' THEN 'not' ELSE x.nm END, x.id) FROM c x
                       WHERE x.pid = (SELECT id FROM container) AND x.ty IN ('class_name', 'not')
                         AND x.id < max(k.id)) AS pseudo
               FROM c k WHERE k.pid = (SELECT id FROM container) AND k.ty IN ('(', '[', '"', '''')),
  -- a `)` loose under the container closes nothing: the selector ran out inside an argument list
  bad_close AS (SELECT count(*) AS n FROM c WHERE pid = (SELECT id FROM container) AND ty = ')'),
  -- the whole selector must be ONE selector node under the container. Nothing (an empty text), a
  -- trailing combinator token (the selector stopped mid-chain), or several children (trailing
  -- junk) is not a v0 selector.
  bad_shape AS (SELECT CASE WHEN (SELECT n FROM root_of) = 0 THEN 'end of selector'
                            WHEN (SELECT count(*) FROM c WHERE pid = (SELECT id FROM container)
                                    AND ty IN ('>', '+', '~')) > 0 THEN 'end of selector'
                            WHEN (SELECT count(*) FROM c WHERE pid = (SELECT id FROM container)) > 1
                              THEN 'text after the selector'
                            WHEN (SELECT count(*) FROM c WHERE cls = 'err') > 1 THEN 'text after the selector'
                            ELSE NULL END AS t),
  -- `:nth-child(2)` and friends: dropping the argument would silently change what is asked
  bad_pseudo AS (SELECT min(np.nm) AS nm FROM pname np JOIN pargs pa ON pa.id = np.id WHERE np.nm NOT IN ('has', 'not')),
  bad_arg AS (SELECT count(*) AS n FROM argroot WHERE n <> 1),
  -- `:not(<chain with combinators>)` has nothing for the chain to anchor on, and guessing an
  -- anchor is how `:not` came to mean a descendant test in the first place. Read over the whole
  -- inner chain, not just its root: `:not(> x#i)` hides its combinator one level down.
  bad_not AS (SELECT count(*) AS n FROM grp g JOIN chainof ch ON ch.root = g.root
                JOIN c k ON k.id = ch.node WHERE g.lead = 'self' AND k.cls = 'comb'),
  -- a relative combinator is legal exactly where a `:has()` argument opens with one; anywhere
  -- else -- `.fn >> .call`, a leading `> a` -- there is nothing for it to relate to
  bad_rel AS (SELECT min_by(r.tok, r.id) AS tok FROM relcomb r
              WHERE r.id NOT IN (SELECT head FROM grp WHERE lead <> 'self')),
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

  -- Every arm goes through tree_css_err, never through error() directly: `error(NULL)` RETURNS
  -- NULL instead of raising, so one NULL in a concatenated message would turn a refusal into a
  -- NULL TREE_SELECTOR handed back to the caller. Each arm below reads a value from a CTE, and any
  -- of those can be NULL for a parse shape that was not anticipated, so the guard is on the helper
  -- rather than on the arms one at a time.
  SELECT CASE
    WHEN (SELECT n FROM bad_where) > 0
      THEN tree_css_err('css: css has no host escape: mint a PSEUDO, or MATCH USING TREEQL')
    WHEN (SELECT n FROM bad_list) > 0 THEN tree_css_err('css: unexpected '','': v0 has no selector lists')
    WHEN (SELECT n FROM bad_property) > 0
      THEN tree_css_err('css: unexpected end of selector: tree-sitter-css read this as css property syntax, '
                 || 'not a selector -- after a space, a compound opening with a quoted type or a '
                 || 'pseudo-class needs its combinator written out (a > :has(x))')
    -- a `)` with nothing to close: the argument list ran out mid-chain (`a:has(x > )`)
    WHEN (SELECT n FROM bad_close) > 0 THEN tree_css_err('css: unexpected '')''')
    WHEN (SELECT nm FROM bad_bare_fn) IS NOT NULL
      THEN tree_css_err('css: :' || (SELECT nm FROM bad_bare_fn) || ' is not supported in v0 by this front-end: '
                 || 'the css grammar knows :' || (SELECT nm FROM bad_bare_fn)
                 || ' only with an argument, so written bare it does not parse as a selector '
                 || '(the runner parser accepts it as a plain PSEUDO clause)')
    WHEN (SELECT t FROM bad_type) IS NOT NULL
      THEN tree_css_err('css: unexpected ' || tree_sql_lit((SELECT t FROM bad_type))
                 || ': the css grammar did not read this as a v0 selector')
    -- an open `(` names the pseudo-class it belongs to when the parse left one next to it. With no
    -- pseudo there is nothing unclosed, just a paren where a selector was expected; and a pseudo
    -- that is not has/not was never going to be lowered, so it refuses as the unsupported one it is.
    WHEN (SELECT t FROM bad_open) = '(' AND (SELECT pseudo FROM bad_open) IS NULL
      THEN tree_css_err('css: unexpected ''(''')
    WHEN (SELECT t FROM bad_open) = '(' AND (SELECT pseudo FROM bad_open) NOT IN ('has', 'not')
      THEN tree_css_err('css: :' || (SELECT pseudo FROM bad_open) || '() is not supported in v0')
    WHEN (SELECT t FROM bad_open) = '(' THEN tree_css_err('css: unclosed :' || (SELECT pseudo FROM bad_open) || '(')
    WHEN (SELECT t FROM bad_open) = '[' THEN tree_css_err('css: unclosed [ in attribute selector')
    WHEN (SELECT t FROM bad_open) IS NOT NULL THEN tree_css_err('css: unclosed quote in selector')
    WHEN (SELECT t FROM bad_shape) IS NOT NULL THEN tree_css_err('css: unexpected ' || (SELECT t FROM bad_shape))
    WHEN (SELECT nm FROM bad_pseudo) IS NOT NULL
      THEN tree_css_err('css: :' || (SELECT nm FROM bad_pseudo) || '() is not supported in v0')
    WHEN (SELECT n FROM bad_arg) > 0
      THEN tree_css_err('css: unexpected '')'': :has()/:not() needs a selector between its parentheses')
    WHEN (SELECT n FROM bad_not) > 0 THEN tree_css_err('css: :not() takes a compound selector in v0')
    WHEN (SELECT tok FROM bad_rel) IS NOT NULL
      THEN tree_css_err('css: unexpected ''' || (SELECT tok FROM bad_rel) || ''': a combinator with nothing on its left')
    WHEN (SELECT nm FROM bad_attr) IS NOT NULL
      THEN tree_css_err('css: expected one of = ^= $= *= after attribute ' || (SELECT nm FROM bad_attr))
    WHEN (SELECT t FROM bad_qtype) IS NOT NULL
      THEN tree_css_err('css: expected a type name in quotes, got ' || tree_sql_lit((SELECT t FROM bad_qtype)))
    WHEN (SELECT n FROM bad_cap_second) > 0 THEN tree_css_err('css: unexpected second capture')
    WHEN (SELECT n FROM bad_cap_in_group) > 0 THEN tree_css_err('css: capture inside :has/:not has no row to bind')
    WHEN (SELECT d FROM bad_depth) > tree_group_depth_limit()
      THEN tree_css_err('css: groups nested deeper than ' || tree_group_depth_limit() || ' levels are not supported')
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
    WHEN sel IS NULL THEN tree_css_err('css: no selector text')
    -- the marker is an internal spelling; a selector that already used it would be read as a
    -- capture, so it is refused rather than quietly turned into one
    WHEN regexp_matches(sel, ':__cap_') THEN tree_css_err('css: :__cap_ is reserved for the @name capture rewrite')
    ELSE tree_css_lower(
      (SELECT list({node_id: node_id, parent_id: parent_id, type: type, name: name} ORDER BY node_id)
       FROM query('SELECT node_id, parent_id, type, name FROM parse_ast_list_table('
                  || tree_sql_lit(tree_css_capture_markers(sel)) || ', ''css'')'))) END);
