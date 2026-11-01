-- test/mutants/MN33_clauses_after_groups.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/10_treeql.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- TREEQL TEXT to a TREE_SELECTOR, node ids included. This is the macro that makes the exact
-- theorem true: tree_parse_treeql(tree_selector_to_treeql(sel)) = sel as a WHOLE VALUE --
-- EXCEPT on the shapes test/sweep_treeql.py's KNOWN_EXACT_FAILURES enumerates, which is where the
-- exceptions are counted and declared rather than described. EXACT does NOT hold universally over
-- the printer's image, and this sentence said it did until fix round 4.
--
-- HOW THE NUMBERING IS REPRODUCED, and why it is not a counter. tree_steps numbers by sorting a
-- PATH struct {i0, a0, i1, a1, i2, a2} -- `i` the 1-based position in a chain, `a` which of a
-- step's parts comes next -- and taking row_number() over that order. This macro rebuilds the
-- same struct from the TEXT and numbers it the same way, so the two agree by construction rather
-- than by two counters that happen to count alike. Ancestry precedes depth in the key, which is
-- what makes the order depth-first; a row's parent link is its parent's path, so the parent join
-- is one struct comparison and no arithmetic on ids is done anywhere.
--
-- `a` IS THE PART'S TEXTUAL POSITION, NOT tree_steps' SLOT NUMBER, and that is a deliberate
-- difference. Only the RELATIVE order of paths survives row_number(), and the printer emits a
-- step's parts `ORDER BY node_id`, so on canonical IR the textual order of the parts IS their
-- slot order and the two numberings produce identical ids. Reading the slot number instead would
-- need a clause ORDINAL, and the registry has none: measured, tree_clause_kinds() returns the
-- kinds in SCAN order and not in slot order -- the registry has no order column, which
-- test/css_parser.py's CLAUSE_SLOT exemption also records -- so list_position() over it would be
-- wrong, quietly and for most selectors. Clauses are still
-- ordered BEFORE groups (requirement 2) rather than purely by position, which costs nothing and
-- matches the constructor for a hand-written `(HAS ( ... ), TYPE 'a')` as well.
--
-- GROUPS UNROLL, three step levels and two group levels, and do not recurse: DuckDB macros cannot
-- self-recurse, which is the same reason the printer unrolls to the same depth and the same reason
-- TREE_STEP_L0/L1/L2 spell the ceiling out as types. Raising tree_group_depth_limit() means adding
-- one level here, in the printer and in the type list together.
--
-- WHY NOT list_transform. tree_treeql_step_parse and tree_treeql_clause_parse both query the
-- catalog, so both are subqueries, and a subquery is illegal anywhere inside an expression
-- carrying a lambda. Every level is therefore set-based: `unnest()` of the splitters' list forms
-- over a relation, with the readers applied per row.
--
-- THE FIRST STEP OF THE OUTER CHAIN keeps whatever combinator the text gives it, which for
-- printer output is none. A LATER TOP-LEVEL step defaults to desc (requirement 4), which is what
-- tree_steps does. A step of a GROUP's chain does NOT -- see R35 at stp1 below: the printer emits
-- no combinator word for a NULL op, so the no-word form inside a group means NULL and not desc.
--
-- R34: A COMBINATOR WRITTEN ON THE FIRST STEP IS ASSEMBLED AS WRITTEN, and that is adjudicated
-- rather than overlooked. `tree_steps` refuses to BUILD that IR -- measured,
-- `tree_steps([{type: 'a', comb: 'child'}])` raises "the first step takes no combinator" -- but
-- the PRINTER emits `CHILD (TYPE 'a')` for it from hand-built IR, and `parse(print(ir)) = ir` is
-- exactly TRUE for it. A refusal here would therefore reject printer output and break the exact
-- theorem, which is what the Global Constraint forbids. The printer/constructor disagreement is
-- reported to the repo owner instead; this parser stays exactly as tolerant as the host door.
CREATE OR REPLACE MACRO tree_parse_treeql(txt) AS (
WITH
-- LEVEL 0: the top-level chain. Requirement 1 -- the split is on a DEPTH-0 newline, so a newline
-- inside a quoted value or a clause list cannot end a step.
raw0 AS (SELECT (x).ord AS ord, (x).part AS part
         FROM (SELECT unnest(tree_treeql_split_parts(txt, chr(10))) AS x)),
-- R26/R31: A BLANK TOP-LEVEL PART IS DROPPED, WITH ONE EXCEPTION KEPT -- see R31 below, the
-- empty FIRST step. A trailing newline otherwise assembled an INVENTED
-- step -- op 'desc', no clauses -- and that step is not inert: it compiles to a DESCENDANT with
-- no predicate and matches different rows. Every file and every editor adds that newline unasked,
-- and Task 6 reads selector text out of a table where it comes with the data.
--
-- THE TWO SEPARATORS ARE DELIBERATELY NOT SYMMETRIC, which is what keeps this from contradicting
-- R6. R6 makes an empty part in the CLAUSE list a syntax error, and that is right there: the
-- separator is a comma, and nobody types a comma by accident. Here the separator is a NEWLINE,
-- which comes from the medium and not from the author, so dropping it is whitespace tolerance of
-- the same kind that makes keyword case free -- "tolerant input, canonical output". Clause-list
-- behaviour is untouched; an empty clause part still comes back as a part.
--
-- THE RENUMBERING IS LOAD-BEARING. `i0` decides which step is FIRST, and only the first step of
-- the outer chain keeps a NULL combinator. Filter on the splitter's own ordinals and a LEADING
-- newline leaves the surviving step at i0 = 2, which then defaults to desc -- so the selector
-- would gain a combinator its text does not contain. Measured: with the renumbering removed the
-- leading-newline assertion in 48_treeql_parse.test is the one record that fails.
--
-- If this leaves NO parts the selector has no steps, which the refusal set below reports; Task 5
-- owns the wording for it.
--
-- R30: ONE BLANK PART IS NOT NOISE -- THE EMPTY FIRST STEP. A step with no clauses and no
-- combinator prints as NOTHING, and only the FIRST step can be in that position, because every
-- later step carries a combinator the printer emits as a keyword. Measured over the whole empty
-- step space: an empty step LAST prints "(TYPE 'a')\nDESCENDANT" and an empty step in the MIDDLE
-- prints "(TYPE 'a')\nDESCENDANT\nCHILD (TYPE 'b')", both of which already round-tripped; an
-- empty FIRST step prints "\nCHILD (TYPE 'b')", and R26 threw that leading blank away. The
-- printer is injective here, so the theorem was achievable and R26 was simply too wide.
--
-- THE RULE IS COMPLETE AND NOT A PATCH FOR ONE CASE: a leading blank part is an empty first step
-- IFF the next part begins with a combinator keyword. Every other blank part stays dropped, so
-- the trailing newline, the CRLF pair and the blank line between two steps are unaffected.
--
-- WHY THAT TEST IS SOUND. A legitimate first step can never lead with a combinator -- measured,
-- `tree_steps([{comb: 'child', type: 'b'}])` is refused by name with "the first step takes no
-- combinator" -- so the only reading this rule takes away is input the constructor already
-- rejects. The keyword is resolved by tree_treeql_step_parse, which looks the leading word up in
-- tree_catalog.combinators (R23), so no keyword is written here and the lexing is not restated.
--
-- BOTH HALVES OF THIS RULE ARE GATED, shown by mutation rather than argued. The records are
-- named by their INPUT and not by line, because adding a comment above them moves the line
-- and the citation goes stale -- which is exactly what happened to the first draft of this
-- very block.
--
-- Replacing the combinator lookup with "any leading word"
-- (`regexp_matches(nxt, '^[A-Za-z_]')`) fails exactly ONE record in 48_treeql_parse.test:
-- `chr(10) || 'TYPE ''a'''`, whose next part is a CLAUSE keyword. That record is the only one
-- separating this rule from the sloppier one, which is why it exists.
--
-- Dropping the test entirely, leaving a bare `ord = 1`, fails THREE: that same record, the
-- `chr(10) || '(TYPE ''a'')'` one, and the `tree_parse_treeql('')` refusal -- the last
-- because a lone blank part then survives and the no-steps arm stops firing.
--
-- Both counts were predicted before the mutants were run.
--
-- A LONE blank part is deliberately NOT kept: `nxt` is NULL for it, so a selector that is
-- nothing but an empty step stays unreadable. It has to -- it prints as the empty string, and no
-- parser can recover a step from no characters. That it can be BUILT at all is a gap in
-- tree_steps, which this task may not edit.
mark0 AS (SELECT ord, part,
            trim(part, tree_treeql_ws()) = '' AS blank,
            lead(part) OVER (ORDER BY ord) AS nxt
          FROM raw0),
lvl0 AS (SELECT CAST(row_number() OVER (ORDER BY ord) AS INTEGER) AS i0, part
         FROM mark0
         WHERE NOT blank
            OR (ord = 1 AND (tree_treeql_step_parse(nxt)).op IS NOT NULL)),
rd0 AS (SELECT i0, part, tree_treeql_step_parse(part) AS p FROM lvl0),
stp0 AS (SELECT i0, part,
           CASE WHEN i0 = 1 THEN (p).op ELSE COALESCE((p).op, 'desc') END AS op,
           (p).body AS body, (p).alias AS alias, (p).unknown_word AS uw
         FROM rd0),
pt0 AS (SELECT i0, (x).ord AS n, (x).part AS part
        FROM (SELECT i0, unnest(tree_treeql_clause_parts(body)) AS x
              FROM stp0 WHERE body IS NOT NULL)),
-- A PART IS A CLAUSE OR A GROUP, and the two readers are asked in that order: a clause keyword is
-- never a group keyword (the registries are disjoint and 48_treeql_parse.test asserts it), so a
-- part the clause reader claims cannot also be a group. A part the clause reader returns NULL for
-- is a group when its LEADING WORD is a group kind -- which is exactly what Task 3 leaves in
-- unknown_word.
cg0 AS (SELECT i0, n, part, tree_treeql_clause_parse(part) AS cl,
               tree_treeql_step_parse(part) AS gp
        FROM pt0),
-- `gtail` reads the parentheses off the RAW part text on purpose. tree_treeql_step_parse STRIPS
-- them, so after it `HAS ( X )` and `HAS X` carry the same body, and a parenless group would be
-- built from a chain nobody wrote instead of refused.
kd0 AS (SELECT i0, n, part, cl,
          CASE WHEN cl IS NULL AND (gp).unknown_word IS NOT NULL
                    AND list_contains(tree_treeql_group_kinds(), lower((gp).unknown_word))
               THEN lower((gp).unknown_word) END AS gkind,
          (gp).unknown_word AS guw, (gp).body AS gbody,
          CASE WHEN (gp).unknown_word IS NOT NULL
               THEN trim(part[length((gp).unknown_word) + 1 : ], tree_treeql_ws()) END AS gtail
        FROM cg0),
sl0 AS (SELECT *, CAST(row_number() OVER (PARTITION BY i0
            ORDER BY CASE WHEN gkind IS NULL THEN 0 ELSE 1 END, n) AS INTEGER) AS a0
        FROM kd0),
gr0 AS (SELECT i0, a0, gkind, gbody FROM sl0 WHERE gkind IS NOT NULL),

-- LEVEL 1: each depth-1 group's inner chain, and the same four passes over it.
lvl1 AS (SELECT i0, a0, (x).ord AS i1, (x).part AS part
         FROM (SELECT i0, a0, unnest(tree_treeql_chain_parts(gbody)) AS x FROM gr0)),
rd1 AS (SELECT i0, a0, i1, part, tree_treeql_step_parse(part) AS p FROM lvl1),
-- R35: AN INNER STEP WITH NO COMBINATOR WORD KEEPS op NULL. There is no `desc` default here any
-- more, and its absence is the ruling rather than an omission. The printer writes no combinator
-- word for an inner step whose op is NULL -- measured, it emits `(TYPE 'a', HAS ( (TYPE 'b') ))`
-- for that IR -- so coalescing to desc made `print(parse(print(ir)))` differ from `print(ir)` and
-- the normalising theorem FALSE for it. The printer is the specification.
--
-- WHAT COVERS THE INPUT THE DEFAULT USED TO: a PARENLESS inner step with no combinator is now
-- refused by name (R36), because nothing separates its clause list from the next step's, and a
-- PARENTHESISED one is unambiguous and lands here with op NULL. So every text the default could
-- still have applied to is either refused or has a combinator of its own, and
-- test/sql/48_treeql_parse.test gates that by re-adding the COALESCE as a mutant.
--
-- THAT SENTENCE WAS FALSE ON RAW-BODIED TEXT until Task 7, and the history is kept because it is
-- how the hole was found. Measured in fix round 3: a THIRD case existed that the sentence did not
-- allow for -- a parenless inner step whose text carries a WHERE or ATTR body was NEITHER refused
-- NOR given a combinator of its own. It was accepted, with the raw body swallowing the step that
-- follows, so `(TYPE 'a', HAS ( WHERE a = 1 TYPE 'b' ))` parsed to a single inner step whose where
-- value was `a = 1 TYPE 'b'`. The R36 arm stood down on raw bodies and nothing downstream caught it.
--
-- TASK 7 REMOVED THAT STAND-DOWN, so the sentence is true again: every text the default could have
-- applied to is now either refused or has a combinator of its own, raw-bodied text included. The
-- reasoning and the measurement that made the removal safe are at the `parenless` arms below.
--
-- The mutant the sentence points at gates what it always gated -- the DEFAULT's absence on text the
-- arm can read. It never gated the raw-bodied case; what gates that now is the arm firing on it,
-- recorded in the FIX ROUND 3 block.
--
-- The TOP-LEVEL default in stp0 is untouched: there the separator is a newline, the first step is
-- the only one that may carry no combinator, and R35 is scoped to inner steps.
stp1 AS (SELECT i0, a0, i1, part, (p).op AS op,
           (p).body AS body, (p).alias AS alias, (p).unknown_word AS uw
         FROM rd1),
pt1 AS (SELECT i0, a0, i1, (x).ord AS n, (x).part AS part
        FROM (SELECT i0, a0, i1, unnest(tree_treeql_clause_parts(body)) AS x
              FROM stp1 WHERE body IS NOT NULL)),
cg1 AS (SELECT i0, a0, i1, n, part, tree_treeql_clause_parse(part) AS cl,
               tree_treeql_step_parse(part) AS gp
        FROM pt1),
kd1 AS (SELECT i0, a0, i1, n, part, cl,
          CASE WHEN cl IS NULL AND (gp).unknown_word IS NOT NULL
                    AND list_contains(tree_treeql_group_kinds(), lower((gp).unknown_word))
               THEN lower((gp).unknown_word) END AS gkind,
          (gp).unknown_word AS guw, (gp).body AS gbody,
          CASE WHEN (gp).unknown_word IS NOT NULL
               THEN trim(part[length((gp).unknown_word) + 1 : ], tree_treeql_ws()) END AS gtail
        FROM cg1),
sl1 AS (SELECT *, CAST(row_number() OVER (PARTITION BY i0, a0, i1
            ORDER BY CASE WHEN gkind IS NULL THEN 0 ELSE 1 END, n) AS INTEGER) AS a1
        FROM kd1),
gr1 AS (SELECT i0, a0, i1, a1, gkind, gbody FROM sl1 WHERE gkind IS NOT NULL),

-- LEVEL 2: the last level tree_group_depth_limit() allows. Its steps may carry clauses and they
-- may carry a group KEYWORD, but a group here has nowhere to go -- so the group's own node is
-- still emitted below and its inside is never read. That is what lets the depth measure see 3.
lvl2 AS (SELECT i0, a0, i1, a1, (x).ord AS i2, (x).part AS part
         FROM (SELECT i0, a0, i1, a1, unnest(tree_treeql_chain_parts(gbody)) AS x FROM gr1)),
rd2 AS (SELECT i0, a0, i1, a1, i2, part, tree_treeql_step_parse(part) AS p FROM lvl2),
-- R35 again, at the second group level. The rule is the chain reader's and not the level's, so it
-- is the same rule here; the block above stp1 carries it.
stp2 AS (SELECT i0, a0, i1, a1, i2, part, (p).op AS op,
           (p).body AS body, (p).alias AS alias, (p).unknown_word AS uw
         FROM rd2),
pt2 AS (SELECT i0, a0, i1, a1, i2, (x).ord AS n, (x).part AS part
        FROM (SELECT i0, a0, i1, a1, i2, unnest(tree_treeql_clause_parts(body)) AS x
              FROM stp2 WHERE body IS NOT NULL)),
cg2 AS (SELECT i0, a0, i1, a1, i2, n, part, tree_treeql_clause_parse(part) AS cl,
               tree_treeql_step_parse(part) AS gp
        FROM pt2),
kd2 AS (SELECT i0, a0, i1, a1, i2, n, part, cl,
          CASE WHEN cl IS NULL AND (gp).unknown_word IS NOT NULL
                    AND list_contains(tree_treeql_group_kinds(), lower((gp).unknown_word))
               THEN lower((gp).unknown_word) END AS gkind,
          (gp).unknown_word AS guw, (gp).body AS gbody,
          CASE WHEN (gp).unknown_word IS NOT NULL
               THEN trim(part[length((gp).unknown_word) + 1 : ], tree_treeql_ws()) END AS gtail
        FROM cg2),
sl2 AS (SELECT *, CAST(row_number() OVER (PARTITION BY i0, a0, i1, a1, i2
            ORDER BY CASE WHEN gkind IS NULL THEN 0 ELSE 1 END, n) AS INTEGER) AS a2
        FROM kd2),

-- EVERY NODE AT EVERY LEVEL as one relation, each carrying its own path and its parent's path.
-- Requirement 2's pre-order falls out of the struct order and is not re-stated as a traversal.
nodes AS (
  -- the root: a ppath no row carries, so the parent join leaves its parent_id NULL. Its value is
  -- this front-end's name -- the provenance tree_selector_language reads back (requirement 3).
  -- Canonical IR already carries it, which is what leaves the exact theorem undisturbed.
  SELECT {i0: 0, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0} AS path,
         {i0: -1, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0} AS ppath,
         'selector' AS kind, 'treeql'::VARCHAR AS value, NULL::VARCHAR AS op,
         NULL::VARCHAR AS arg, NULL::VARCHAR AS alias
  UNION ALL SELECT {i0: i0, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0},
                   {i0: 0, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0},
                   'step', NULL, op, NULL, alias FROM stp0
  UNION ALL SELECT {i0: i0, a0: a0, i1: 0, a1: 0, i2: 0, a2: 0},
                   {i0: i0, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0},
                   (cl).kind, (cl).value, (cl).op, (cl).arg, NULL FROM sl0 WHERE cl IS NOT NULL
  UNION ALL SELECT {i0: i0, a0: a0, i1: 0, a1: 0, i2: 0, a2: 0},
                   {i0: i0, a0: 0, i1: 0, a1: 0, i2: 0, a2: 0},
                   gkind, NULL, NULL, NULL, NULL FROM sl0 WHERE gkind IS NOT NULL
  UNION ALL SELECT {i0: i0, a0: a0, i1: i1, a1: 0, i2: 0, a2: 0},
                   {i0: i0, a0: a0, i1: 0, a1: 0, i2: 0, a2: 0},
                   'step', NULL, op, NULL, alias FROM stp1
  UNION ALL SELECT {i0: i0, a0: a0, i1: i1, a1: a1, i2: 0, a2: 0},
                   {i0: i0, a0: a0, i1: i1, a1: 0, i2: 0, a2: 0},
                   (cl).kind, (cl).value, (cl).op, (cl).arg, NULL FROM sl1 WHERE cl IS NOT NULL
  UNION ALL SELECT {i0: i0, a0: a0, i1: i1, a1: a1, i2: 0, a2: 0},
                   {i0: i0, a0: a0, i1: i1, a1: 0, i2: 0, a2: 0},
                   gkind, NULL, NULL, NULL, NULL FROM sl1 WHERE gkind IS NOT NULL
  UNION ALL SELECT {i0: i0, a0: a0, i1: i1, a1: a1, i2: i2, a2: 0},
                   {i0: i0, a0: a0, i1: i1, a1: a1, i2: 0, a2: 0},
                   'step', NULL, op, NULL, alias FROM stp2
  UNION ALL SELECT {i0: i0, a0: a0, i1: i1, a1: a1, i2: i2, a2: a2},
                   {i0: i0, a0: a0, i1: i1, a1: a1, i2: i2, a2: 0},
                   (cl).kind, (cl).value, (cl).op, (cl).arg, NULL FROM sl2 WHERE cl IS NOT NULL
  -- the TOO-DEEP group: its node and nothing under it, so tree_selector_group_depth below
  -- measures tree_group_depth_limit() + 1 and the refusal fires. Dropping it instead would leave
  -- a selector measuring exactly the limit, the arm would never fire, and the innermost group
  -- would be silently lost -- which is the failure that refusal exists to prevent.
  UNION ALL SELECT {i0: i0, a0: a0, i1: i1, a1: a1, i2: i2, a2: a2},
                   {i0: i0, a0: a0, i1: i1, a1: a1, i2: i2, a2: 0},
                   gkind, NULL, NULL, NULL, NULL FROM sl2 WHERE gkind IS NOT NULL),
-- every path is unique, so the parent link is one struct comparison. The cast to INTEGER is
-- load-bearing: row_number() is BIGINT, and TREE_SELECTOR's node_id is INTEGER, so without it
-- whole-value equality against canonical IR fails on TYPE alone.
nmb AS (SELECT CAST(row_number() OVER (ORDER BY path) - 1 AS INTEGER) AS node_id, * FROM nodes),
prt AS (SELECT n.node_id, p.node_id AS parent_id, n.kind, n.value, n.op, n.arg, n.alias
        FROM nmb n LEFT JOIN nmb p ON p.path = n.ppath),
asm AS (SELECT list({node_id: node_id, parent_id: parent_id, kind: kind, value: value,
                     op: op, arg: arg, alias: alias} ORDER BY node_id)::TREE_SELECTOR AS v
        FROM prt),
-- THE REFUSALS. R25 left Task 4's one provisional message here -- `cannot read <fragment>` --
-- holding an INVARIANT rather than a vocabulary: nothing the assembly cannot build returns clean
-- IR, and the message names the offending text so that this task could specialise without
-- re-deriving it. It did; the invariant is unchanged and the generic message survives as the
-- catch-all for a fault that carries no word worth naming.
--
-- WHAT IS NEW HERE, beside the wording: two faults that were not refused at all, because the
-- reader returned clean IR for them. An unterminated quoted value and a parenless inner step
-- both parsed, silently and wrongly, so the arms for them required fixing tree_treeql_depths'
-- two callers first. R38 has the measurements.
--
-- EVERY RULE IS ROUTED THROUGH ITS EXISTING HOLDER rather than restated: tree_sql_is_ident for
-- an alias (inside tree_treeql_step_parse), tree_selector_group_depth against
-- tree_group_depth_limit() for nesting, tree_treeql_group_kinds() for HAS and NOT, and the two
-- catalog registries for the two open vocabularies. No clause kind and no combinator keyword
-- appears in this file.
--
-- THE STEPS WHOSE LEADING WORD IS IN NEITHER REGISTRY, at all three levels, with the raw tail
-- the word was taken off. The tail is re-derived from `part` and NOT read from `body`, for the
-- same reason `gtail` is below: tree_treeql_step_parse STRIPS the parentheses, so after it
-- `HAS ( X )` and `HAS X` carry the same body and the one difference that matters is gone.
uws AS (SELECT part, uw, body, trim(part[length(uw) + 1 : ], tree_treeql_ws()) AS utail
        FROM stp0 WHERE uw IS NOT NULL
        UNION ALL SELECT part, uw, body, trim(part[length(uw) + 1 : ], tree_treeql_ws())
        FROM stp1 WHERE uw IS NOT NULL
        UNION ALL SELECT part, uw, body, trim(part[length(uw) + 1 : ], tree_treeql_ws())
        FROM stp2 WHERE uw IS NOT NULL),
-- R37: DOES WHAT FOLLOWS THE UNKNOWN WORD READ AS A LEGAL CLAUSE LIST? That one question
-- separates an unknown COMBINATOR from an unknown CLAUSE KEYWORD, and it is asked of the clause
-- reader rather than guessed from the word's shape. Measured: `SIDEWAYS (TYPE 'b')` leaves the
-- body `TYPE 'b'`, which reads as a clause, so SIDEWAYS was meant to be a combinator;
-- `FROBNICATE 'x'` leaves `'x'`, which does not, so FROBNICATE was meant to be a clause keyword.
--
-- EVERY part must read as a clause, which is why this is a count and not an EXISTS: a body of
-- `TYPE 'a', 42` is not a legal clause list, and naming SIDEWAYS an unknown combinator there
-- would point at the wrong token.
uwp AS (SELECT part, uw, (x).part AS cpart
        FROM (SELECT part, uw, unnest(tree_treeql_clause_parts(body)) AS x
              FROM uws WHERE body IS NOT NULL)),
uwc AS (SELECT part, uw,
               count(*) FILTER (WHERE tree_treeql_clause_parse(cpart) IS NOT NULL) = count(*)
                 AS body_is_clauses
        FROM uwp GROUP BY part, uw),
-- A LEFT JOIN and not a correlated EXISTS: R22's binder wall is an inner correlated subquery, and
-- every caller of this macro from Task 6 on passes a COLUMN. A step with no body at all (`KID`
-- printed bare) has no uwp rows, so COALESCE decides it, and `false` sends it to the clause-keyword
-- arm -- R37's third rule, which is what "else" means there.
uwk AS (SELECT u.part, u.uw, u.utail,
               list_contains(tree_treeql_group_kinds(), lower(u.uw)) AS is_group,
               COALESCE(c.body_is_clauses, false) AS body_is_clauses
        FROM uws u LEFT JOIN uwc c ON c.part = u.part AND c.uw = u.uw),
-- EVERY CLAUSE-LIST PART AT EVERY LEVEL as one relation, so each rule below is written once
-- instead of three times. The three sl CTEs were the three copies the old refusal set carried.
cps AS (SELECT part, cl, gkind, gtail, gbody FROM sl0
        UNION ALL SELECT part, cl, gkind, gtail, gbody FROM sl1
        UNION ALL SELECT part, cl, gkind, gtail, gbody FROM sl2),
-- EVERY FAULT, CLASSIFIED. Task 4 left one generic message here and R25 said Task 5 owns the
-- wording; this is that wording. Each row carries its CODE and the offending FRAGMENT, and the
-- CASE below reads them in priority order.
--
-- WHY A PRIORITY ORDER AND NOT min() ALONE. One input can carry more than one fault, and the old
-- `min(f)` picked the alphabetically smallest FRAGMENT -- arbitrary once the messages differ.
-- ONE ordering is load-bearing and one is not, both measured by mutation:
--   * PARENLESS BEFORE GENERIC is GATED, because `HAS ( TYPE 'b' TYPE 'c' )` is ALSO a clause
--     whose literal cannot be read, and `cannot read TYPE 'b' TYPE 'c'` names the symptom instead
--     of the mistake. Silencing the parenless arm fails three records.
--   * UNTERMINATED BEFORE UNBALANCED is NOT gated since the odd-quote stand-down. The reasoning
--     holds -- an unterminated quote stops the parentheses after it from being counted, so a
--     quote fault presents as a paren fault -- but tree_treeql_balanced now stands down on an odd
--     count, so the input that needed the order never reaches the unbalanced arm. Measured:
--     swapping the two arms now fails ZERO records, where before the stand-down it failed one.
--     Kept as the correct order if that stand-down is ever narrowed, and named UNGATED here so
--     the harmless swap is not mistaken for the arms being interchangeable.
-- The order lives in the CASE below, where it is visible, and not in a sort key here.
prob AS (
  -- NO STEPS AT ALL. R26 drops a blank top-level part, so empty, whitespace-only and NULL text
  -- all arrive here. The fragment is unused by this message and is kept non-NULL anyway, because
  -- a NULL fragment in a GROUP BY row would make the arm's test miss.
      SELECT 'nosteps' AS code, COALESCE(txt, '<NULL>') AS frag
        WHERE NOT EXISTS (SELECT 1 FROM lvl0)
  -- AN UNTERMINATED QUOTED VALUE, detected as an ODD number of quote characters in one part.
  --
  -- WHY PARITY AND NOT tree_treeql_lit_ok, WHICH IS A NARROWING OF R38. R38's anchored pattern
  -- says whether a body is a well-formed literal; it does not say WHY it is not one. Both of
  -- R38's own named inputs -- `TYPE 'a` and `TYPE 'it''s` -- have an odd quote count, because a
  -- quote was opened and never closed, and that is what "unterminated" states. An EVEN count
  -- that still fails the pattern is a different fault: `TYPE 'a' SIDEWAYS TYPE 'b'` closed every
  -- quote it opened and then carried trailing text, so calling it unterminated would tell the
  -- author the wrong thing. Those go to the generic arm below, which names the fragment and
  -- claims nothing about the cause. Refused either way -- that is R38's requirement.
  --
  -- CANNOT REJECT PRINTER OUTPUT, and the OTHER TWO THIRDS of this condition are what make that
  -- true. A part's quote count is evidence about a VALUE only when the part IS a value; this rule
  -- shipped twice believing otherwise, so the reasoning is written out rather than summarised.
  --
  -- A WHERE OR ATTR BODY IS NOT A LITERAL. The printer emits it unquoted and unescaped -- see this
  -- file's header -- so it never passes through tree_sql_lit and its quote count can be ODD.
  -- Measured, from the ordinary constructor: `(WHERE "o'k" = 1)`, a double-quoted IDENTIFIER
  -- holding an apostrophe, legal DuckDB SQL, and it round-tripped at BASE. So `lit_ok` decides a
  -- clause part, because tree_treeql_clause_parse already answers "is this body's quoting well
  -- formed, FOR THIS KIND" and that is the holder of the per-kind rule.
  --
  -- AND A GROUP PART IS NOT A VALUE EITHER, which is the second defect of the same shape and the
  -- one `lit_ok` alone did not stop. A group part carries a whole nested CHAIN, so any WHERE body
  -- anywhere inside it contributes to the part's count -- measured, the printer emits
  -- `(TYPE 'a', HAS ( DESCENDANT (TYPE 'b', WHERE "o'k" = 1) ))` with FIVE quotes, `cl` is NULL
  -- because a group is not a clause, and the rule fired on a part whose own quoting is perfect.
  -- `gkind IS NULL` excludes it: a part the assembly reads as a group is judged by the group
  -- rules, never by counting characters across its contents. An unterminated value INSIDE the
  -- group is still caught, by this same rule applied to the inner part at the inner level.
  --
  -- WHAT IS LEFT, and it is the only shape where the count is evidence: a part that is a
  -- value-carrying clause whose literal is malformed (`TYPE 'a`), or a part the readers could make
  -- nothing of at all (`(TYPE 'c`). Neither can be printer output.
  --
  -- AND R42's THIRD TERM: a part carrying a RAW body is not judged by counting its quotes either.
  -- Measured, `step2+has+nested` and `step2+not+nested` are printer output and were refused here as
  -- `unterminated quoted value` with every literal terminated -- the part was a fragment of a
  -- mis-split, and its odd count came from a WHERE body rather than from an unclosed value.
  UNION ALL SELECT 'unterminated', part FROM cps
        WHERE NOT tree_treeql_quotes_even(part)
          AND tree_treeql_no_raw_body(part)
          AND gkind IS NULL
          AND (cl IS NULL OR NOT (cl).lit_ok)
  -- UNBALANCED PARENTHESES, counted quote-aware over the WHOLE input. It runs AFTER the
  -- unterminated arm deliberately: an unterminated quote swallows the rest of the text, so the
  -- parentheses after it stop being counted and a quote fault LOOKS like a paren fault.
  -- Measured, the input that shows it: `(CLASS 'f', HAS ( CHILD (TYPE 'b') ))<LF>CHILD (TYPE 'c`
  -- is unbalanced only because the value never closed.
  --
  -- CANNOT REJECT PRINTER OUTPUT -- but NOT for the reason this comment carried until d4dd0da.
  -- The old reason was: the printer emits '(' and ')' only as a matched pair, and a value's own
  -- parenthesis is inside a literal, where tree_treeql_depths does not count it. That second
  -- half was MEASURED FALSE. tree_treeql_depths DECIDED "inside a literal" by PARITY then, and a
  -- WHERE or ATTR body is raw host SQL, so one unpaired apostrophe in it flipped the scanner and
  -- made it skip parentheses that are REAL. TWO such bodies sum to an EVEN count, which is why
  -- the odd-quote stand-down did not catch it. Printer output in that shape was refused here.
  -- PAST TENSE SINCE R41: tree_treeql_depths reads tree_treeql_quote_mask, so it knows `'...'`
  -- and `"..."` as regions and no longer counts parity at all. The arm's safety still rests on
  -- the stand-down below rather than on the scan, which is why the paragraph stays.
  --
  -- WHAT MAKES THE ARM SAFE NOW is tree_treeql_balanced standing down on untrusted quoting: it
  -- answers true unless tree_treeql_quotes_trusted(txt) holds, which needs an even quote count
  -- AND no clause kind with a raw body anywhere in the text. The guard is the stand-down, not a
  -- literal hiding a parenthesis from the count.
  -- The printed text, the quote counts and the four records are in R42 FOR THE PAREN SCAN, near
  -- the end of test/sql/48_treeql_parse.test. Not repeated here, so it cannot drift.
  UNION ALL SELECT 'unbalanced', COALESCE(txt, '<NULL>') WHERE NOT tree_treeql_balanced(txt)
  -- A GROUP WHOSE CHAIN IS NOT PARENTHESISED (R37's first rule). Two shapes, one message: the
  -- group keyword as a clause-list PART, which is the shape the printer emits, and as a STEP's
  -- leading word.
  --
  -- NARROWED TO THE UNWRAPPED TAIL, which R37's wording does not say and which measurement
  -- requires. `HAS ( )` HAS its parentheses, and so does a top-level bare `HAS ( (TYPE 'b') )`;
  -- telling their author to add parentheses that are already there is worse than saying nothing.
  -- Both fall to the generic arm instead.
  --
  -- CANNOT REJECT PRINTER OUTPUT: tree_selector_to_treeql's group pass emits
  -- `upper(kind) || ' ( ' || chain || ' )'` at every level, so a printed group always wraps.
  --
  -- AND R42 HERE TOO, which is the arm's SECOND correction. Fixing tree_treeql_wrapped was not
  -- enough: on raw-bodied text the splitters hand this arm a FRAGMENT, and a fragment's tail can
  -- genuinely lack its closing parenthesis because the split fell wrong, not because the author
  -- omitted it. Measured, `has+not+nested` and two more printer-output shapes were refused here
  -- with their parentheses present. The group keyword is still not trustworthy evidence of a
  -- missing parenthesis unless the text around it could be read at all.
  --
  -- BOTH ARMS GUARD ON THE CONTAINER, not on the tail they test: the trust question is asked of
  -- `part`, while the parenthesis question is asked of `gtail` or `utail`. That is deliberate.
  -- A tail is a slice of `part`, so a raw body ANYWHERE in the part is what makes the slice
  -- itself untrustworthy. Guarding on the wider text stands the arm down more often, which is
  -- the safe direction: a stood-down arm falls to the generic rows below and still refuses.
  UNION ALL SELECT 'groupparen', part FROM cps
        WHERE gkind IS NOT NULL AND NOT tree_treeql_wrapped(gtail)
          AND tree_treeql_no_raw_body(part)
  UNION ALL SELECT 'groupparen', uw FROM uwk
        WHERE is_group AND NOT tree_treeql_wrapped(utail)
          AND tree_treeql_no_raw_body(part)
  -- A PARENLESS INNER STEP WITH NO COMBINATOR (R36). Inside a group the steps are separated by a
  -- SPACE, so a step with neither a combinator keyword nor parentheses has nothing marking where
  -- its clause list ends and the next step's begins. At BASE this returned clean IR:
  -- `HAS ( TYPE 'b' TYPE 'c' )` became one type clause whose value was `b' TYPE 'c`.
  --
  -- LEVELS 1 AND 2 ONLY, never level 0: a parenless clause list at top level is requirement 6 --
  -- `CLASS fn` is legal -- and there the separator is a newline, which marks the boundary this
  -- rule is about.
  --
  -- `part NOT LIKE '(%'` IS THE TEST, so this says "parenless" and nothing more. A step whose
  -- text starts with '(' but does not WRAP is a different fault and goes to the generic arm, where
  -- the message names the fragment instead of asking for parentheses it has.
  --
  -- THIS ARM DOES REJECT PRINTER OUTPUT, and the sentence here said it cannot. The reasoning it
  -- gave was about ONE shape and was read as a guarantee over all of them: "tree_treeql_step wraps
  -- a step's clause list in parentheses whenever the step HAS one, so a printed step with clauses
  -- and no combinator word always carries its own parentheses and this rule requires their
  -- absence." True of that shape. It says nothing about a step whose RAW BODY swallowed the
  -- group that follows it, which is how printer output reaches this arm.
  --
  -- MEASURED, duckdb 1.5.5, and driven in test/sweep_treeql.py since before `19097d6` found
  -- this -- `k09` and `k10`, which are family-A cases and so printer output BY CONSTRUCTION:
  --
  --     tree_steps([{"where": 'a = 1, HAS ( TYPE ''b'' )'}])
  --       prints   (WHERE a = 1, HAS ( TYPE 'b' ))
  --       parses   REFUSED: a step inside HAS/NOT needs a combinator or parentheses, ...
  --     the same for the NOT form, `k10`.
  --
  -- That message is emitted only under `code = 'parenless'`, so the arm is identified rather than
  -- guessed; which of its two rows fires is NOT isolated here.
  --
  -- NOBODY HAD TO DRIVE A NEW CASE TO SEE THIS. The cases were already in the corpus and the
  -- sentence was already here; what was missing was reading the two together. A per-arm "cannot
  -- reject printer output" claim is only as good as the last time someone checked it against the
  -- cases that reach the arm, and nothing re-checks it.
  --
  -- NOT FIXED HERE. `k09`/`k10` are declared EXACT failures: the raw body is cut at `, HAS`, the
  -- remainder reads as nothing, and the merge would need the clause kinds' slot order to know
  -- better. The refusal is the symptom of that cut, not a defect of this arm's condition.
  --
  -- THE R42 STAND-DOWN IS GONE FROM THIS ARM, and that is F2's fix. It read
  -- `AND tree_treeql_no_raw_body(part)`, on the reasoning that the chain reader splits on quote
  -- parity, so a mis-split fragment of raw-bodied text could arrive here looking parenless when
  -- the printed step had its parentheses -- a refusal naming a cause the text does not have.
  --
  -- WHAT THE STAND-DOWN COST, measured and recorded here before it was removed: on raw-bodied text
  -- this arm did not fire AND nothing downstream caught it, so a WHERE or ATTR body SWALLOWED THE
  -- STEP THAT FOLLOWED IT and the parse was silently wrong.
  --
  --     (TYPE 'a', HAS ( WHERE a = 1 TYPE 'b' ))   was ACCEPTED, where value = `a = 1 TYPE 'b'`
  --     (TYPE 'a', HAS ( ATTR a = 1 TYPE 'b' ))    was ACCEPTED, attr arg  = `1 TYPE 'b'`
  --     (TYPE 'a', HAS ( TYPE 'b' TYPE 'c' ))      REFUSED -- the arm worked where it could fire
  --
  -- A CLEAN WRONG PARSE IS THE WORSE FAILURE, which this file says itself at R42's counterweight:
  -- suppressing an arm "would turn a refusal into a clean WRONG PARSE ... which is the worse of the
  -- two failures". The guard bought a true message on a shape nobody could show, and paid for it
  -- with a wrong answer on a shape that is measured right here.
  --
  -- WHY REMOVING IT IS SAFE, and this is a MEASUREMENT rather than the argument the guard rested
  -- on. The risk was a FALSE `parenless` on text the splitter mis-split -- printer output from the
  -- ordinary constructor carrying odd-quoted raw bodies, which test/sweep_treeql.py drives.
  -- MEASURED AT `02931a3`, duckdb 1.5.5: with this guard removed, none of the shapes driven THEN
  -- reached this arm and each kept the answer it had. A DATE, NOT A GUARANTEE: which arm a case
  -- reaches is not gate-checked -- measuring it needs a probe that reads `pb` directly -- so this
  -- sentence is what was true at that commit and nothing re-checks it as cases are added.
  --
  -- WHAT IS RE-CHECKED, and the half to rely on: the sweep reports its DIVERGENT entries every
  -- run and FAILS when one moves. The R42 wording records in test/sql/48_treeql_parse.test name
  -- `unterminated`, `groupparen` and `unbalanced`, and the suite asserts them every run.
  --
  -- WHAT IT DOES COST, stated rather than discovered later: a HAND-WRITTEN parenless group whose
  -- part carries a raw body now gets THIS message instead of the generic one, because the
  -- `groupparen` arm above still stands down on raw bodies and this arm now fires first in that
  -- situation. Measured: `(TYPE 'a', HAS WHERE a = 1)` moves from `cannot read HAS WHERE a = 1` to
  -- this sentence. Both refuse and both point at missing parentheses; this one names the inner
  -- step where the group's own parentheses are what is missing, so it is less precise and not
  -- false. It is NOT printer output, so R42's rule about never rejecting printer output is
  -- untouched. test/sweep_treeql.py carries it as a declared divergence.
  UNION ALL SELECT 'parenless', part FROM stp1
        WHERE op IS NULL AND uw IS NULL AND part NOT LIKE '(%'
  UNION ALL SELECT 'parenless', part FROM stp2
        WHERE op IS NULL AND uw IS NULL AND part NOT LIKE '(%'
  -- AN UNKNOWN COMBINATOR, and AN UNKNOWN CLAUSE KEYWORD: R37's second and third rules. The
  -- message names the OFFENDING WORD. At BASE it named the remainder -- `FROBNICATE 'x'` refused
  -- with `cannot read 'x'`, pointing at the operand.
  --
  -- CANNOT REJECT PRINTER OUTPUT: both registries are read from the catalog, case-insensitively,
  -- so every keyword the printer can emit is known to this test and a front-end that registers a
  -- ninth combinator is accepted the day the row lands.
  --
  -- AND R42 ONCE MORE, on the WHOLE STEP TEXT: a leading word that is in neither registry is only
  -- evidence of a misspelled keyword when the step was split where the printer put a boundary. On
  -- raw-bodied text the splitters cannot know that, so the word may be an ordinary SQL token from
  -- inside a WHERE body. These two arms therefore ask the same question the three above ask.
  UNION ALL SELECT 'comb', uw FROM uwk
        WHERE NOT is_group AND body_is_clauses AND tree_treeql_no_raw_body(part)
  UNION ALL SELECT 'kw',   uw FROM uwk
        WHERE NOT is_group AND NOT body_is_clauses AND tree_treeql_no_raw_body(part)
  -- EVERYTHING ELSE, which keeps Task 4's generic message as the CATCH-ALL rather than replacing
  -- it. A fault that carries no offending word has nothing for a specialised message to name, and
  -- `cannot read <fragment>` is the honest answer: a part that is neither a clause nor a group
  -- (`42`), a clause keyword with no operand (`TYPE`), an EMPTY group, a group whose tail wraps
  -- but whose chain is unreadable, and a clause whose literal is malformed with its quotes
  -- balanced.
  --
  -- THIS ARM DOES REJECT PRINTER OUTPUT, and the sentence here said it cannot. `k08` and `k21`
  -- both show it. `k08` has been in test/sweep_treeql.py since before `53cd01b` first corrected
  -- this sentence: `tree_steps([{"where": 'a = 1, b = 2, TYPE c'}])` prints
  -- `(WHERE a = 1, b = 2, TYPE c)` and this arm refuses it `cannot read b = 2`. So the sentence
  -- was already false against the sweep's own corpus, and what was missing was reading the two
  -- together rather than a case nobody had written.
  --
  -- The second is `k21`, added by `681c2c3`. MEASURED, duckdb 1.5.5:
  --
  --     tree_steps([{type: 'a', has: [{"where": 'c = 1)'}]}, {type: 'e', comb: 'child'}])
  --       prints   (TYPE 'a', HAS ( DESCENDANT (WHERE c = 1)) ))<newline>CHILD (TYPE 'e')
  --       parses   REFUSED: cannot read ( DESCENDANT (WHERE c = 1)) ))<newline>CHILD (TYPE 'e'
  --
  -- The text is printer output by construction and this arm refuses it, so "every row here is a
  -- shape the assembly cannot build" is false for whichever row fires. `cannot read` is emitted
  -- only under `code = 'generic'`, so the ARM is identified rather than guessed; WHICH of its rows
  -- fires is NOT isolated, and this comment does not guess. The group's raw body carries an
  -- unmatched parenthesis, so the splitters cannot find the step boundary that follows the group.
  --
  -- WHAT IS STILL TRUE of the old sentence: this is the arm Task 4 shipped, and the corpus
  -- selectors do round-trip through it untouched. What was wrong was reading that as a guarantee
  -- over the printer's whole image -- A CORPUS IS NOT A QUANTIFIER. (The old sentence gave the
  -- corpus a COUNT. It is not restated here: this comment cannot check that figure, and a count of
  -- something in another file is the defect this correction exists to stop.)
  --
  -- NOT FIXED HERE. The refusal is the symptom; the cause is that the printed text does not say
  -- where a raw body ends, which is sql/06_selector.sql and frozen for this task. `k21` is a
  -- declared EXACT failure with the measurement beside it, and whether the text has a second
  -- preimage at all is recorded there as OPEN rather than answered.
  UNION ALL SELECT 'generic', part FROM cps WHERE cl IS NULL AND gkind IS NULL
  UNION ALL SELECT 'generic', part FROM cps WHERE cl IS NOT NULL AND NOT (cl).lit_ok
  UNION ALL SELECT 'generic', part FROM cps
        WHERE gkind IS NOT NULL AND tree_treeql_chain_parts(gbody) IS NULL
  UNION ALL SELECT 'generic', part FROM uwk
        WHERE is_group AND tree_treeql_wrapped(utail)
  -- R42's COUNTERWEIGHT, and the reason the stand-downs above do not silently widen what parses.
  -- Each of those faults is still a fault the assembly cannot build; R42 only says the TEXT is not
  -- trustworthy evidence of WHICH fault. Without these two rows, suppressing the arms above would
  -- turn a refusal into a clean WRONG PARSE, which the acceptance sweep counts as a break in its
  -- own right and which is the worse of the two failures.
  --
  -- THE CLAIM THAT WAS HERE UNTIL FIX ROUND 3 -- "every shape whose named arm stood down is caught
  -- here instead" -- IS FALSE, and it was the fifth comment in this task to claim a completeness
  -- the code does not have. What the rows actually cover, measured by driving each stand-down:
  --
  --   COVERED, by these two rows: the `comb` and `kw` arms, through uwk. The uwk row carries NO
  --     is_group test, so it also covers the uwk `groupparen` arm, and the cps row covers the cps
  --     `groupparen` arm. Measured: `HAS ( WHERE a = 1 TYPE 'b'` and `FROBNICATE 'x', WHERE a = 1`
  --     are both refused generically.
  --   COVERED, but by the OLDER generic rows above and not by these two: the `unterminated` arm.
  --     Measured, `(TYPE 'a, WHERE x = 1)` is refused `cannot read TYPE 'a, WHERE x = 1`, because
  --     the part reaches `cl IS NULL AND gkind IS NULL`. The round-3 brief said nothing covers
  --     this arm. The code says otherwise, and BASE 3384ede ACCEPTED that same input as a type
  --     clause whose value was `'a, WHERE x = 1`, so this row is an improvement on BASE.
  --   WAS NOT COVERED AT ALL: the two `parenless` arms below. Nothing caught their stand-down.
  --     Measured then, `(TYPE 'a', HAS ( WHERE a = 1 TYPE 'b' ))` was ACCEPTED and the WHERE body
  --     swallowed the next step, giving a where value of `a = 1 TYPE 'b'`.
  --
  -- THAT GAP IS CLOSED IN TASK 7, and it did NOT need a counterweight row: the stand-down itself
  -- was removed from those two arms, so the fault is refused by its own name rather than caught
  -- generically. The reasoning, the measurement that made it safe, and the one wording it costs
  -- are at the arms themselves below. Nothing here needs a counterweight for them any more, and
  -- the rows above still cover what they always covered.
  UNION ALL SELECT 'generic', part FROM uwk
        WHERE NOT tree_treeql_no_raw_body(part)
  UNION ALL SELECT 'generic', part FROM cps
        WHERE gkind IS NOT NULL AND NOT tree_treeql_wrapped(gtail)
          AND NOT tree_treeql_no_raw_body(part)),
-- ONE ROW PER CODE, so each arm below is one scalar read. `n` and not `frag IS NOT NULL` decides
-- whether an arm fires: a rule whose fragment went NULL would otherwise be SILENTLY SKIPPED, and
-- absence of signal is not success.
pb AS (SELECT code, count(*) AS n, min(frag) AS frag FROM prob GROUP BY code)
SELECT CASE
  -- requirement 5, and FIRST: the depth is measured on the ASSEMBLED selector with
  -- tree_selector_group_depth against tree_group_depth_limit(), which is what the printer and
  -- tree_steps_group both do, and the wording is the printer's own. It comes before every other
  -- arm so that a selector nested too deep is always refused in those words.
  WHEN tree_selector_group_depth((SELECT v FROM asm)) > tree_group_depth_limit()
    THEN tree_err('tree_parse_treeql: groups nested deeper than ' || tree_group_depth_limit()
                  || ' levels are not supported')
  -- THE ARM ORDER IS THE PRIORITY ORDER. Every concatenated piece is COALESCEd: a NULL anywhere
  -- in a refusal message makes the whole message NULL, which tree_err reports as "refusal with a
  -- NULL message" -- losing the one sentence the caller needed. This repo has shipped that twice.
  WHEN (SELECT n FROM pb WHERE code = 'nosteps') > 0
    THEN tree_err('tree_parse_treeql: selector has no steps')
  WHEN (SELECT n FROM pb WHERE code = 'unterminated') > 0
    THEN tree_err('tree_parse_treeql: unterminated quoted value')
  WHEN (SELECT n FROM pb WHERE code = 'unbalanced') > 0
    THEN tree_err('tree_parse_treeql: unbalanced parentheses')
  WHEN (SELECT n FROM pb WHERE code = 'groupparen') > 0
    THEN tree_err('tree_parse_treeql: HAS/NOT needs parentheses around its chain')
  WHEN (SELECT n FROM pb WHERE code = 'parenless') > 0
    THEN tree_err('tree_parse_treeql: a step inside HAS/NOT needs a combinator or parentheses, '
                  || 'so its clauses can be told from the next step''s')
  WHEN (SELECT n FROM pb WHERE code = 'comb') > 0
    THEN tree_err('tree_parse_treeql: unknown combinator '
                  || COALESCE((SELECT frag FROM pb WHERE code = 'comb'), '<NULL>'))
  WHEN (SELECT n FROM pb WHERE code = 'kw') > 0
    THEN tree_err('tree_parse_treeql: unknown clause keyword '
                  || COALESCE((SELECT frag FROM pb WHERE code = 'kw'), '<NULL>'))
  WHEN (SELECT n FROM pb WHERE code = 'generic') > 0
    THEN tree_err('tree_parse_treeql: cannot read '
                  || COALESCE((SELECT frag FROM pb WHERE code = 'generic'), '<NULL>'))
  ELSE (SELECT v FROM asm) END);
