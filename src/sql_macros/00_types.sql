-- sql/00_types.sql
CREATE TYPE TREE_SEMANTIC AS STRUCT(
  type VARCHAR, key VARCHAR, tags VARCHAR, attr VARCHAR, attr_map VARCHAR, element VARCHAR, predicate_args VARCHAR,
  predicate STRUCT(name VARCHAR, body VARCHAR, macro VARCHAR, args VARCHAR, prefix VARCHAR)[]);

CREATE TYPE TREE_SHAPE AS STRUCT(
  root VARCHAR, "order" VARCHAR, unique_key VARCHAR, level VARCHAR, parent VARCHAR, sibling_order VARCHAR,
  size VARCHAR, children VARCHAR, next VARCHAR,
  semantic TREE_SEMANTIC);

CREATE TYPE TREE_SPEC AS STRUCT(shape TREE_SHAPE, abstract BOOLEAN, "like" VARCHAR, source VARCHAR, storage VARCHAR);

CREATE TYPE TREE_SELECTOR AS STRUCT(
  node_id INTEGER, parent_id INTEGER, kind VARCHAR, value VARCHAR, op VARCHAR, arg VARCHAR, alias VARCHAR)[];

-- The fixed step shapes tree_steps casts its argument to, so that a field a step omits reads as
-- NULL. A step's has/not holds a nested step list, so there is one shape per literal nesting
-- level: an L0 step has no groups, an L1 step's groups hold L0 steps, an L2 step's groups hold
-- L1 steps. tree_steps takes L2, which is the three-literal-level ceiling
-- (step -> group -> step -> group -> step).
CREATE TYPE TREE_STEP_L0 AS STRUCT(
  comb VARCHAR, type VARCHAR, id VARCHAR, class VARCHAR, attr VARCHAR, pseudo VARCHAR, "where" VARCHAR, "as" VARCHAR);
CREATE TYPE TREE_STEP_L1 AS STRUCT(
  comb VARCHAR, type VARCHAR, id VARCHAR, class VARCHAR, attr VARCHAR, pseudo VARCHAR, "where" VARCHAR, "as" VARCHAR,
  has TREE_STEP_L0[], "not" TREE_STEP_L0[]);
CREATE TYPE TREE_STEP_L2 AS STRUCT(
  comb VARCHAR, type VARCHAR, id VARCHAR, class VARCHAR, attr VARCHAR, pseudo VARCHAR, "where" VARCHAR, "as" VARCHAR,
  has TREE_STEP_L1[], "not" TREE_STEP_L1[]);

-- Refuse with `msg`, and refuse even when building `msg` went wrong.
--
-- 1.5.5: error(NULL) does NOT raise -- it evaluates to NULL. A refusal whose message
-- concatenates a value that turns out to be NULL therefore hands its caller a NULL where an
-- exception was owed, and a NULL propagates: a NULL fragment makes the whole compiled query
-- NULL, a NULL context struct makes every statement built from it NULL and list_filter drops
-- them, so a verb that should have refused runs BEGIN ... COMMIT over nothing. sql/09_css.sql
-- met this first and answered it with tree_css_err; this is the same guard for the rest of the
-- macro files, and every refusal outside 09_css.sql goes through it. Sites whose operand can
-- actually be NULL (an identity, a hand-built IR node's kind or op) COALESCE that operand to
-- '<NULL>' as well, so the message still names what was wrong; this is the backstop for the
-- ones nobody anticipated. It deliberately does not name the caller -- it has no way to know
-- one -- which is why the text says "internal": reaching it is a duckent bug, not a user error.
CREATE OR REPLACE MACRO tree_err(msg) AS
  error(COALESCE(msg, 'duckent: internal: refusal with a NULL message; see FINDINGS on error(NULL) in 1.5.5'));

-- predicate: a list of any of {name, body} | {name, macro, args} | {prefix, args}; predicate_map: MAP of name -> macro
-- with predicate_args shared by every entry; the constructor flattens the map into the list.
CREATE OR REPLACE MACRO tree_semantic(type := NULL, key := NULL, tags := NULL, attr := NULL, attr_map := NULL, element := NULL,
                                      predicate := NULL, predicate_map := NULL, predicate_args := NULL) AS
  {type: type, key: key, tags: tags, attr: attr, attr_map: attr_map, element: element, predicate_args: predicate_args,
   predicate: CASE WHEN predicate IS NULL AND predicate_map IS NULL THEN NULL ELSE list_concat(
     COALESCE(predicate::STRUCT(name VARCHAR, body VARCHAR, macro VARCHAR, args VARCHAR, prefix VARCHAR)[], []),
     CASE WHEN predicate_map IS NULL THEN [] ELSE list_transform(map_entries(predicate_map),
       lambda e: {name: (e).key, body: NULL::VARCHAR, macro: (e).value, args: predicate_args, prefix: NULL::VARCHAR}) END) END
  }::TREE_SEMANTIC;

-- The shared predicate tier's prefix, spelled once: every reference to the literal "sel_" (and its
-- length, for stripping it off a matched function_name) goes through this macro.
CREATE OR REPLACE MACRO tree_shared_predicate_prefix() AS 'sel_';

-- Expand macro, map, prefix and shared bindings to expression bodies. Prefix entries bind every
-- catalog scalar macro whose name starts with the prefix; name = the remainder. A round-tripped
-- catalog entry (tree_shape_from_catalog, for a LIKE child) always carries a name, even when it
-- also carries a provenance-only prefix marker (see below), so the local/pass-through group is
-- "prefix IS NULL OR name IS NOT NULL" -- only a freshly declared, not-yet-expanded prefix entry
-- ({prefix, args}, no name) is routed to the scanning branch.
-- After that, the shared tier: every catalog scalar macro named sel_<rest> becomes a binding
-- {name: rest, body: 'sel_' || rest || '(predicate_args)', macro, args: predicate_args, prefix: 'sel_'},
-- unless <rest> is already bound (by name) or the macro itself already underlies a local/prefix
-- binding (by macro identity -- a prefix-bound macro like sel_ast_leaf also starts with the
-- literal "sel_" the shared tier scans for, and must not be double-bound under a second name).
-- The shared tier binds nothing when predicate_args is NULL, tree-wide (§7 of the M2 design doc:
-- "the shared tier's args default to the tree's predicate_args slot"; there is no args source for a
-- shared binding otherwise). Reads duckdb_functions(), so this is called by the DDL compilers
-- (runner-executed), never by tree_compile_projection.
CREATE OR REPLACE MACRO tree_expand_predicate(sem) AS (
WITH lp AS (
  SELECT list_concat(
    list_transform(list_filter(COALESCE((sem).predicate, []), lambda p: (p).prefix IS NULL OR (p).name IS NOT NULL),
      lambda p: {name: (p).name, body: COALESCE((p).body, (p).macro || '(' || COALESCE((p).args, '') || ')'),
                 macro: (p).macro, args: (p).args, prefix: (p).prefix}),
    COALESCE((SELECT list({name: substr(f.function_name, length((x).px.prefix) + 1),
                           body: f.function_name || '(' || COALESCE((x).px.args, '') || ')',
                           macro: f.function_name, args: (x).px.args, prefix: (x).px.prefix} ORDER BY f.function_name)
              FROM (SELECT unnest(list_filter(COALESCE((sem).predicate, []), lambda p: (p).prefix IS NOT NULL AND (p).name IS NULL)) AS px) x
              JOIN (SELECT DISTINCT function_name FROM duckdb_functions() WHERE function_type = 'macro') f
                ON starts_with(f.function_name, (x).px.prefix)), [])
  ) AS bound
),
shared AS (
  SELECT COALESCE((SELECT list({name: substr(f.function_name, length(tree_shared_predicate_prefix()) + 1),
                                body: f.function_name || '(' || COALESCE((sem).predicate_args, '') || ')',
                                macro: f.function_name, args: (sem).predicate_args, prefix: tree_shared_predicate_prefix()} ORDER BY f.function_name)
                    FROM (SELECT DISTINCT function_name FROM duckdb_functions() WHERE function_type = 'macro') f
                    WHERE (sem).predicate_args IS NOT NULL AND starts_with(f.function_name, tree_shared_predicate_prefix())
                      -- a bare sel_ macro has an empty remainder: not an error, just not a
                      -- nameable pseudo-class, so it is left unbound rather than bound as ''
                      AND substr(f.function_name, length(tree_shared_predicate_prefix()) + 1) <> ''
                      -- spec §7, amended: identity dedup. The spec's literal text excludes a
                      -- candidate only by name collision; that alone double-binds a macro
                      -- already claimed by a prefix declaration (e.g. sel_ast_leaf, which also
                      -- starts with the shared tier's own "sel_") under a second, derived name.
                      -- A prefix declaration is a namespace claim: a macro already bound under
                      -- any name -- locally or via a prefix -- is not re-bound by the shared
                      -- tier under another one.
                      AND NOT list_contains(list_transform(lp.bound, lambda y: (y).name), substr(f.function_name, length(tree_shared_predicate_prefix()) + 1))
                      AND NOT list_contains(list_transform(lp.bound, lambda y: (y).macro), f.function_name)
                   ), []) AS extra
  FROM lp
)
SELECT {type: (sem).type, key: (sem).key, tags: (sem).tags, attr: (sem).attr, attr_map: (sem).attr_map, element: (sem).element, predicate_args: (sem).predicate_args,
  predicate: CASE WHEN (sem).predicate IS NULL AND (sem).predicate_args IS NULL THEN NULL ELSE list_concat(lp.bound, shared.extra) END
}::TREE_SEMANTIC
FROM lp, shared);

-- Does this SEMANTIC group DECLARE an S slot? The one answer to that question, shared by
-- tree_compile_create, tree_compile_alter (which both store it as tree_catalog.trees.has_semantic)
-- and tree_compile_match (whose "semantic overlay is empty" refusal asks exactly the same thing of
-- an overlay). It had been hand-copied into all three, and the copies had already drifted: the
-- compiler's forgot PREDICATE_ARGS, so a `tree_semantic(predicate_args := ...)` overlay -- which DOES
-- bind the shared predicate tier -- was refused as empty.
--
-- It is a question about what the group DECLARES, one slot at a time, never about whether a group
-- was written: `tree_semantic(attr := 'x')` declares no S slot (ATTR names the projected columns;
-- it binds nothing structural) and must not mark a tree S-ful, or a TYPE step would compile
-- against TYPE's 'node' default and return zero rows -- a refusal owed and an empty result
-- delivered. Every other slot counts: ELEMENT, ATTR MAP, PREDICATE and PREDICATE_ARGS are S declarations
-- as much as TYPE is, and a slot added later must be added here.
--
-- ATTR is the one that must NOT appear: every tree stores an S/ATTR slot ('' closed, '*' open),
-- so tree_shape_from_catalog gives every LIKE child a non-NULL semantic.attr and counting it would
-- make every child S-ful. Never NULL, whatever it is handed -- every term is an IS NOT NULL
-- predicate or a length test -- so a caller may concatenate the result into generated SQL.
CREATE OR REPLACE MACRO tree_semantic_declares(sem) AS
  (sem).type IS NOT NULL OR (sem).key IS NOT NULL OR (sem).tags IS NOT NULL
    OR (sem).attr_map IS NOT NULL OR (sem).element IS NOT NULL
    OR len(COALESCE((sem).predicate, [])) > 0 OR (sem).predicate_args IS NOT NULL;

-- The type a comparison literal implies: numbers and booleans cast the map value; quoted text compares as VARCHAR.
CREATE OR REPLACE MACRO tree_sql_literal_type(arg) AS
  CASE WHEN regexp_matches(trim(arg), '^-?[0-9]+$') THEN 'BIGINT'
       WHEN regexp_matches(trim(arg), '^-?[0-9]*\.[0-9]+$') THEN 'DOUBLE'
       WHEN lower(trim(arg)) IN ('true', 'false') THEN 'BOOLEAN'
       ELSE NULL END;

CREATE OR REPLACE MACRO tree_shape(root := NULL, "order" := NULL, unique_key := NULL, level := NULL, parent := NULL, sibling_order := NULL,
                                   size := NULL, children := NULL, next := NULL, semantic := NULL) AS
  {root: root, "order": "order", unique_key: unique_key, level: level, parent: parent, sibling_order: sibling_order,
   size: size, children: children, next: next, semantic: semantic}::TREE_SHAPE;

CREATE OR REPLACE MACRO tree_spec(shape, abstract := false, "like" := NULL, source := NULL, storage := 'materialized') AS
  {shape: shape, abstract: abstract, "like": "like", source: source, storage: storage}::TREE_SPEC;

-- string helpers used by every compiler
CREATE OR REPLACE MACRO tree_sql_lit(s) AS '''' || replace(s, '''', '''''') || '''';
CREATE OR REPLACE MACRO tree_sql_ident(s) AS '"' || replace(s, '"', '""') || '"';
CREATE OR REPLACE MACRO tree_sql_list(csv) AS list_transform(string_split(csv, ','), lambda x: trim(x));
CREATE OR REPLACE MACRO tree_sql_is_ident(s) AS regexp_matches(s, '^[A-Za-z_][A-Za-z0-9_]*$');

-- A value going into a LIKE PATTERN, with LIKE's own metacharacters made literal. css's affix
-- operators (`^=`, `$=`, `*=`) say "starts with / ends with / contains THESE CHARACTERS", so the
-- value is text and only the `%` the lowering adds is a wildcard: unescaped, `[name$="_t"]`
-- asked for any character followed by `t` and `[attr^="50%"]` meant rather more than it said.
-- The backslash is doubled first, so it cannot eat the escape the other two get; the pattern this
-- builds must be emitted with `ESCAPE '\'`, which is what makes the backslash the escape at all
-- (there is no default escape character in SQL's LIKE).
CREATE OR REPLACE MACRO tree_sql_like_escape(s) AS
  replace(replace(replace(s, '\', '\\'), '%', '\%'), '_', '\_');
-- The pattern, quoted, with its ESCAPE clause: one SQL fragment, because an ATTR clause's `arg`
-- is spliced whole after the operator.
CREATE OR REPLACE MACRO tree_sql_like_arg(pattern) AS tree_sql_lit(pattern) || ' ESCAPE ''\''';

-- The one spelling of a generated object's name: kind ('proj' or 't'), schema, tree.
-- Length-prefix the schema, because no escaping of the separator alone is injective here:
-- doubling underscores still maps ('a_','c') and ('a','_c') to the same a__c. With the
-- schema's length in front, decoding reads the number, then exactly that many characters,
-- then the separator, then the rest as the name, so no two pairs can collide:
-- ('a_b','c') is proj_3_a_b_c, ('a','b_c') is proj_1_a_b_c, ('a_','c') is proj_2_a__c
-- and ('a','_c') is proj_1_a__c.
CREATE OR REPLACE MACRO tree_sql_object_name(kind, sch, nm) AS
  tree_sql_ident(kind || '_' || length(sch) || '_' || sch || '_' || nm);

-- M4 PURITY. A predicate must answer the same for the same row, or matching stops being a function
-- of the declarations (doctrine 2): the same selector would return different rows on two runs.
--
-- The functions a body references come from DuckDB's own PARSE TREE, not a text scan.
-- json_serialize_sql PARSES without binding, so a body full of column names it cannot resolve
-- still yields its calls, and `random` appearing as a column name is not mistaken for the
-- function. A malformed body comes back as an error OBJECT rather than raising, which is why
-- parse-ability is asked separately: the extractor finds no calls in unparseable text, and
-- "no calls" would otherwise read as "pure".
CREATE OR REPLACE MACRO tree_sql_expr_parses(expr) AS
  NOT COALESCE(json_serialize_sql('SELECT ' || COALESCE(expr, 'NULL')) ->> '$.error' = 'true', false);

-- A LIST EXPRESSION, not a subquery, and that is load-bearing rather than tidier. DuckDB 2.0.0
-- refuses a lateral join inside a correlated subquery, and every purity caller passes a value
-- that varies per row, so each subquery level here became one lateral level there. The old form
-- was `SELECT list(DISTINCT ...) FROM (SELECT unnest(...))`, which list_distinct + list_transform
-- compute with no relation at all. Measured equal on 9 bodies including malformed and NULL.
CREATE OR REPLACE MACRO tree_sql_expr_functions(expr) AS
  COALESCE(list_distinct(list_transform(
    regexp_extract_all(json_serialize_sql('SELECT ' || COALESCE(expr, 'NULL')),
                       '"function_name":"[^"]+"'),
    lambda m: lower(regexp_extract(m, '"function_name":"([^"]+)"', 1)))), []);

-- THE TWO CATALOG READS, TAKEN ONCE. Both are zero-argument, so neither depends on the row being
-- judged: DuckDB evaluates each once and nothing becomes a lateral. This is the whole of the
-- 2.0.0 fix. Reading duckdb_functions() per predicate -- which is what a subquery macro called
-- from a lambda or from a per-row CTE does -- is what 2.0.0 refuses, in two different ways:
-- `tree_sql_check_purity` over a correlated column raised "Nested lateral joins or lateral joins
-- in correlated subqueries are not (yet) supported", and `tree_sql_predicate_insert` over one
-- raised INTERNAL Error "Conflicting or cyclic column binding replacement". Both passed on 1.5.5.
CREATE OR REPLACE MACRO tree_sql_volatile_fns() AS (
  SELECT COALESCE(list(DISTINCT lower(function_name)), []) FROM duckdb_functions()
  WHERE stability IN ('VOLATILE', 'CONSISTENT_WITHIN_QUERY'));

-- name -> EVERY body that name has, so level 2 resolves by map lookup instead of a per-row join.
-- A LIST of bodies and not one body: the old form joined `lvl1` to duckdb_functions() on the
-- name, which fans out to every overload, so level 2 saw the calls of all of them. Taking one
-- body with min() would lose an overload -- and if that is the volatile one, a predicate the old
-- code refused as 'impure' would be recorded 'pure', which is a safety check getting quieter
-- during a port. MEASURED: this DuckDB has 4 built-in macro names whose overloads have differing
-- bodies (json_copy_strftime_if_date, json_copy_strftime_if_timestamp, pg_get_constraintdef,
-- assert_true), so the case is real and not hypothetical.
CREATE OR REPLACE MACRO tree_sql_macro_bodies() AS (
  SELECT COALESCE(map(list(fn), list(bodies)), MAP {}) FROM (
    SELECT lower(function_name) AS fn, list(DISTINCT macro_definition) AS bodies
    FROM duckdb_functions() WHERE function_type = 'macro' AND macro_definition IS NOT NULL
    GROUP BY 1));

-- The functions every level-1 macro call reaches through its own body, over all overloads.
-- Factored out because the purity arms below ask for it twice and a duplicated expression of
-- this size is where the two copies drift apart.
CREATE OR REPLACE MACRO tree_sql_expr_functions_lvl2(expr, macro_bodies) AS
  flatten(list_transform(
    list_filter(tree_sql_expr_functions(expr), lambda f: map_contains(macro_bodies, f)),
    lambda f: flatten(list_transform(macro_bodies[f], lambda b: tree_sql_expr_functions(b)))));

-- VOLATILE and CONSISTENT_WITHIN_QUERY are both impure here: the first differs within one query,
-- the second between queries, and a predicate that moves between queries is the same defect.
-- A MACRO reports stability NULL whatever it calls -- measured: a macro over random() and one over
-- a constant are indistinguishable in duckdb_functions() -- so its own body is resolved, ONE level
-- deep. Beyond that the answer is 'unknown', recorded rather than guessed: claiming 'pure' for a
-- body nothing resolved is the false-positive verdict, and refusing it would reject a predicate
-- that is very likely fine. Transitive resolution is the obvious extension and would turn some of
-- today's 'unknown' into 'impure'.

-- The purity decision as a PURE EXPRESSION over pre-bound lookups. Taking the two lists as
-- parameters is what lets a lambda call it: DuckDB refuses a subquery inside a lambda (the same
-- refusal `tree_sql_predicate_insert` works around with generate_series), so the lookups are
-- bound by the caller, once, and this stays relational-free.
CREATE OR REPLACE MACRO tree_sql_purity_expr(expr, volatile_fns, macro_bodies) AS
  CASE
    WHEN NOT tree_sql_expr_parses(expr) THEN 'malformed'
    WHEN len(list_intersect(tree_sql_expr_functions(expr), volatile_fns)) > 0 THEN 'impure'
    -- level 2: a macro reports stability NULL whatever it calls, so its own body is resolved one
    -- level deep. The old form did this with lvl2/lvl2c CTEs over duckdb_functions(); the map
    -- lookup answers the same question without a relation.
    WHEN len(list_intersect(tree_sql_expr_functions_lvl2(expr, macro_bodies), volatile_fns)) > 0
      THEN 'impure'
    -- a level-2 call that is ITSELF a macro is where resolution stops: recorded, never guessed
    WHEN len(list_filter(tree_sql_expr_functions_lvl2(expr, macro_bodies),
                         lambda g: map_contains(macro_bodies, g))) > 0 THEN 'unknown'
    ELSE 'pure' END;

-- The one-argument form, kept because it is the surface the suites and the catalog's recorded
-- purity already read. It binds the lookups itself, which is safe wherever `expr` does not vary
-- per row -- a literal, or a macro argument. A per-row caller must NOT use it: it calls
-- tree_sql_purity_expr and binds the two lookups once in its own scope, which is what
-- tree_sql_check_purity and tree_sql_predicate_insert now do.
CREATE OR REPLACE MACRO tree_sql_purity(expr) AS (
  WITH k AS (SELECT tree_sql_volatile_fns() AS vf, tree_sql_macro_bodies() AS mb)
  SELECT tree_sql_purity_expr(expr, k.vf, k.mb) FROM k);

-- Refuses the two decidable failures and lets 'unknown' through. Reads the EXPANDED list, so a
-- macro- or prefix-bound entry is checked on the body it actually compiles to.
CREATE OR REPLACE MACRO tree_sql_check_purity(sem, verb) AS (
  WITH k AS (SELECT tree_sql_volatile_fns() AS vf, tree_sql_macro_bodies() AS mb),
       b AS (SELECT list_filter(
               list_transform(COALESCE((sem).predicate, []),
                 lambda e: {nm: (e).name, pur: tree_sql_purity_expr((e).body, k.vf, k.mb)}),
               lambda x: (x).pur IN ('impure', 'malformed')) AS bad
             FROM k)
  -- list_min over the names, not `SELECT min(nm) FROM bad`: the refusal must name the same
  -- predicate the old form named, and the old form took the alphabetically first of the bad ones.
  SELECT CASE WHEN len(b.bad) = 0 THEN true
              ELSE tree_err(verb || ': PREDICATE ' || list_min(list_transform(b.bad, lambda x: (x).nm))
                   || CASE WHEN list_min(list_transform(b.bad, lambda x: (x).pur)) = 'malformed'
                           THEN ' does not parse'
                           ELSE ' is not pure: its body reads a VOLATILE or CONSISTENT_WITHIN_QUERY'
                                || ' function, so the same selector would not answer the same twice' END) END
  FROM b);

-- The alphabetically first name bound more than once in an EXPANDED predicate list, or NULL
-- when every name is unique. Exists so the S-coherence refusal can say WHICH predicate: a
-- prefix binding expands to one entry per matching macro, so "a predicate is bound twice" tells
-- a reader nothing they can act on. Deterministic by min(), not by list order, because the
-- expanded list is not name-ordered (the shared tier is, local entries are as written).
--
-- A subquery macro, so tree_sql_check_semantic now contains a subquery. That is fine at all
-- three call sites -- create's and alter's `ok` expression, and tree_match's chk ladder -- but
-- it would break if check_semantic were ever inlined INSIDE a lambda, which 1.5.5 refuses.
CREATE OR REPLACE MACRO tree_sql_dup_predicate(sem) AS (
  SELECT min(nm) FROM (
    SELECT nm FROM (SELECT unnest(list_transform(COALESCE((sem).predicate, []), lambda x: (x).name)) AS nm)
    GROUP BY nm HAVING count(*) > 1));

-- The validation ladder for the S group, shared by tree_compile_create and tree_compile_alter
-- so that altering a tree cannot bypass a check create enforces. `verb` prefixes the message.
-- Returns true when the semantic is acceptable; raises otherwise.
CREATE OR REPLACE MACRO tree_sql_check_semantic(sem, attr_text, verb) AS
  CASE
    WHEN regexp_matches(COALESCE(attr_text, ''), '(?i)\bAS\s+"?_')
      THEN tree_err(verb || ': ATTR alias collides with the canonical prefix: ' || regexp_extract(attr_text, '(?i)\bAS\s+("?_[A-Za-z0-9_]*)', 1))
    -- A NULL name, or a body with no macro to derive one from, would compile the predicate map
    -- and the predicates INSERT to NULL; both would then be dropped from the statement
    -- list instead of refusing. A macro-bound entry passes with a NULL body because the DDL
    -- compilers run tree_expand_predicate first, which fills the body in from macro(args);
    -- prefix entries are exempt entirely -- expansion is what gives them their names.
    WHEN len(list_filter(COALESCE((sem).predicate, []), lambda x: (x).prefix IS NULL AND ((x).name IS NULL OR ((x).body IS NULL AND (x).macro IS NULL)))) > 0
      THEN tree_err(verb || ': every PREDICATE needs a name and a body or macro')
    WHEN len(list_distinct(list_transform(COALESCE((sem).predicate, []), lambda x: (x).name))) <> len(COALESCE((sem).predicate, []))
      THEN tree_err(verb || ': S-coherence: PREDICATE '
                    || COALESCE(tree_sql_dup_predicate(sem), '<unnamed>') || ' is bound twice')
    ELSE true END;

-- The second half of the S validation ladder, and the one that has to read the UNEXPANDED
-- semantic: a PREDICATE prefix entry names a NAMESPACE of catalog macros, and tree_expand_predicate
-- replaces it with one binding per macro carrying that prefix. When none does, expansion replaces
-- it with NOTHING -- so by the time tree_sql_check_semantic sees the group, a prefix that bound
-- no macro is indistinguishable from one that was never written. The tree was created with an
-- empty PREDICATE block and every `:name` its author meant to mint was an unknown pseudo-class
-- compiling to false, silently: `{prefix: 'sel_ats_'}` read as "this tree has no predicates"
-- rather than as a misspelling of `sel_ast_`.
--
-- Only a freshly declared entry ({prefix, args} with no name) is a prefix declaration; a
-- round-tripped catalog row (tree_shape_from_catalog, for a LIKE child) carries a provenance-only
-- prefix marker AND a name, and is not re-resolved. Reads duckdb_functions(), so this is called by
-- the DDL compilers (runner-executed), like tree_expand_predicate itself. Returns true or raises;
-- both compilers call it alongside tree_sql_check_semantic so the two verbs cannot drift.
CREATE OR REPLACE MACRO tree_sql_check_prefixes(sem, verb) AS (
  WITH px AS (SELECT unnest(list_filter(COALESCE((sem).predicate, []),
                                        lambda p: (p).prefix IS NOT NULL AND (p).name IS NULL)) AS p),
       m AS (SELECT DISTINCT function_name FROM duckdb_functions() WHERE function_type = 'macro'),
       bad AS (SELECT min((px.p).prefix) AS pre FROM px
               WHERE NOT EXISTS (SELECT 1 FROM m WHERE starts_with(m.function_name, (px.p).prefix))),
       -- The IMPLICIT shared tier needs the same check. PREDICATE_ARGS switches on every macro under
       -- tree_shared_predicate_prefix(), so it makes exactly the claim an explicit prefix entry makes
       -- -- that there are predicates to bind -- and it was the one spelling that bypassed
       -- this. Unchecked, it bound none while tree_semantic_declares still counted it as an S
       -- group, so has_semantic went true and tree_match's S-less refusal stopped firing: a TYPE
       -- clause compiled against TYPE's 'node' default and returned zero rows where a refusal was
       -- owed, which is the failure the comment on tree_semantic_declares names.
       --
       -- The emptiness rule is tree_expand_predicate's, not a new one: its `shared` arm requires a
       -- non-empty remainder, because a BARE prefix macro is "not an error, just not a nameable
       -- pseudo-class". So a tree whose only sel_ macro is the bare one binds nothing and must be
       -- refused too -- the check agrees with the expansion rather than approximating it.
       shared_bad AS (SELECT (sem).predicate_args IS NOT NULL
                        AND NOT EXISTS (SELECT 1 FROM m
                                        WHERE starts_with(m.function_name, tree_shared_predicate_prefix())
                                          AND substr(m.function_name,
                                                     length(tree_shared_predicate_prefix()) + 1) <> '') AS unbound)
  SELECT CASE WHEN (SELECT pre FROM bad) IS NOT NULL
              THEN tree_err(verb || ': PREDICATE prefix ' || (SELECT pre FROM bad) || ' binds no macro')
              WHEN (SELECT unbound FROM shared_bad)
              THEN tree_err(verb || ': PREDICATE_ARGS binds no macro: no '
                            || tree_shared_predicate_prefix() || '* macro is in scope')
              ELSE true END);

-- Structural companion to the ATTR-alias regex above: the regex only sees an explicit
-- "AS _x", so an implicit or quoted alias still reaches the projection. DESCRIBE the
-- compiled relation instead -- DuckDB renames the displaced duplicate of a canonical
-- column to _size_1 (etc.), so its presence is the proof that an attribute shadowed one.
--
-- The alternation is BUILT from tree_canonical_columns(), not spelled out. It used to be a
-- hand-maintained list of thirteen names, and it drifted: the catalog's vocabulary renames left
-- it naming `id`, `classes` and `pseudo` after the projection had moved to `_key`, `_tags` and
-- `_predicate`, so a source column with one of those three names displaced the canonical column
-- and the check that exists to catch exactly that said nothing. FINDINGS predicted this shape --
-- "a typo in that alternative would reopen the back door F3 closed, silently" -- and a rename is
-- a typo nobody types. Derived from the one list, the check cannot disagree with the projection,
-- and the next canonical column is covered the moment it is added there.
--
-- Forward reference: tree_canonical_columns() lives in sql/07_match.sql, which loads after this
-- file. DuckDB binds a macro body at CALL time, and this macro is only ever called by the DDL
-- compilers (runner-executed, long after every file is loaded), so the order is not a problem.
CREATE OR REPLACE MACRO tree_sql_shadow_check(rel_sql, verb) AS
  'SELECT CASE WHEN count(*) > 0 THEN error(''' || verb || ': attribute column shadows a canonical column: '' || string_agg(DISTINCT regexp_replace(column_name, ''_[0-9]+$'', ''''), '', '')) END'
  || ' FROM (DESCRIBE ' || rel_sql || ')'
  || ' WHERE regexp_matches(column_name, ''^_('
  || list_aggregate(list_transform(tree_canonical_columns(), lambda c: substr(c, 2)), 'string_agg', '|')
  || ')_[0-9]+$'')';
