-- sql/00_types.sql
CREATE TYPE TREE_SEMANTIC AS STRUCT(
  type VARCHAR, id VARCHAR, classes VARCHAR, attr VARCHAR, attr_map VARCHAR, element VARCHAR, pseudo_args VARCHAR,
  pseudo STRUCT(name VARCHAR, body VARCHAR, macro VARCHAR, args VARCHAR, prefix VARCHAR)[]);

CREATE TYPE TREE_SHAPE AS STRUCT(
  root VARCHAR, "order" VARCHAR, key VARCHAR, level VARCHAR, parent VARCHAR, sibling_order VARCHAR,
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

-- pseudo: a list of any of {name, body} | {name, macro, args} | {prefix, args}; pseudo_map: MAP of name -> macro
-- with pseudo_args shared by every entry; the constructor flattens the map into the list.
CREATE OR REPLACE MACRO tree_semantic(type := NULL, id := NULL, classes := NULL, attr := NULL, attr_map := NULL, element := NULL,
                                      pseudo := NULL, pseudo_map := NULL, pseudo_args := NULL) AS
  {type: type, id: id, classes: classes, attr: attr, attr_map: attr_map, element: element, pseudo_args: pseudo_args,
   pseudo: CASE WHEN pseudo IS NULL AND pseudo_map IS NULL THEN NULL ELSE list_concat(
     COALESCE(pseudo::STRUCT(name VARCHAR, body VARCHAR, macro VARCHAR, args VARCHAR, prefix VARCHAR)[], []),
     CASE WHEN pseudo_map IS NULL THEN [] ELSE list_transform(map_entries(pseudo_map),
       lambda e: {name: (e).key, body: NULL::VARCHAR, macro: (e).value, args: pseudo_args, prefix: NULL::VARCHAR}) END) END
  }::TREE_SEMANTIC;

-- Expand macro, map, prefix and shared bindings to expression bodies. Prefix entries bind every
-- catalog scalar macro whose name starts with the prefix; name = the remainder. A round-tripped
-- catalog entry (tree_shape_from_catalog, for a LIKE child) always carries a name, even when it
-- also carries a provenance-only prefix marker (see below), so the local/pass-through group is
-- "prefix IS NULL OR name IS NOT NULL" -- only a freshly declared, not-yet-expanded prefix entry
-- ({prefix, args}, no name) is routed to the scanning branch.
-- After that, the shared tier: every catalog scalar macro named sel_<rest> becomes a binding
-- {name: rest, body: 'sel_' || rest || '(pseudo_args)', macro, args: pseudo_args, prefix: 'sel_'},
-- unless <rest> is already bound (by name) or the macro itself already underlies a local/prefix
-- binding (by macro identity -- a prefix-bound macro like sel_ast_leaf also starts with the
-- literal "sel_" the shared tier scans for, and must not be double-bound under a second name).
-- The shared tier binds nothing when pseudo_args is NULL, tree-wide (§7 of the M2 design doc:
-- "the shared tier's args default to the tree's pseudo_args slot"; there is no args source for a
-- shared binding otherwise). Reads duckdb_functions(), so this is called by the DDL compilers
-- (runner-executed), never by tree_compile_projection.
CREATE OR REPLACE MACRO tree_expand_pseudo(sem) AS (
WITH lp AS (
  SELECT list_concat(
    list_transform(list_filter(COALESCE((sem).pseudo, []), lambda p: (p).prefix IS NULL OR (p).name IS NOT NULL),
      lambda p: {name: (p).name, body: COALESCE((p).body, (p).macro || '(' || COALESCE((p).args, '') || ')'),
                 macro: (p).macro, args: (p).args, prefix: (p).prefix}),
    COALESCE((SELECT list({name: substr(f.function_name, length((x).px.prefix) + 1),
                           body: f.function_name || '(' || COALESCE((x).px.args, '') || ')',
                           macro: f.function_name, args: (x).px.args, prefix: (x).px.prefix} ORDER BY f.function_name)
              FROM (SELECT unnest(list_filter(COALESCE((sem).pseudo, []), lambda p: (p).prefix IS NOT NULL AND (p).name IS NULL)) AS px) x
              JOIN (SELECT DISTINCT function_name FROM duckdb_functions() WHERE function_type = 'macro') f
                ON starts_with(f.function_name, (x).px.prefix)), [])
  ) AS bound
),
shared AS (
  SELECT COALESCE((SELECT list({name: substr(f.function_name, 5),
                                body: f.function_name || '(' || COALESCE((sem).pseudo_args, '') || ')',
                                macro: f.function_name, args: (sem).pseudo_args, prefix: 'sel_'} ORDER BY f.function_name)
                    FROM (SELECT DISTINCT function_name FROM duckdb_functions() WHERE function_type = 'macro') f
                    WHERE (sem).pseudo_args IS NOT NULL AND starts_with(f.function_name, 'sel_')
                      AND NOT list_contains(list_transform(lp.bound, lambda y: (y).name), substr(f.function_name, 5))
                      AND NOT list_contains(list_transform(lp.bound, lambda y: (y).macro), f.function_name)
                   ), []) AS extra
  FROM lp
)
SELECT {type: (sem).type, id: (sem).id, classes: (sem).classes, attr: (sem).attr, attr_map: (sem).attr_map, element: (sem).element, pseudo_args: (sem).pseudo_args,
  pseudo: CASE WHEN (sem).pseudo IS NULL AND (sem).pseudo_args IS NULL THEN NULL ELSE list_concat(lp.bound, shared.extra) END
}::TREE_SEMANTIC
FROM lp, shared);

-- The type a comparison literal implies: numbers and booleans cast the map value; quoted text compares as VARCHAR.
CREATE OR REPLACE MACRO tree_sql_literal_type(arg) AS
  CASE WHEN regexp_matches(trim(arg), '^-?[0-9]+$') THEN 'BIGINT'
       WHEN regexp_matches(trim(arg), '^-?[0-9]*\.[0-9]+$') THEN 'DOUBLE'
       WHEN lower(trim(arg)) IN ('true', 'false') THEN 'BOOLEAN'
       ELSE NULL END;

CREATE OR REPLACE MACRO tree_shape(root := NULL, "order" := NULL, key := NULL, level := NULL, parent := NULL, sibling_order := NULL,
                                   size := NULL, children := NULL, next := NULL, semantic := NULL) AS
  {root: root, "order": "order", key: key, level: level, parent: parent, sibling_order: sibling_order,
   size: size, children: children, next: next, semantic: semantic}::TREE_SHAPE;

CREATE OR REPLACE MACRO tree_spec(shape, abstract := false, "like" := NULL, source := NULL, storage := 'materialized') AS
  {shape: shape, abstract: abstract, "like": "like", source: source, storage: storage}::TREE_SPEC;

-- string helpers used by every compiler
CREATE OR REPLACE MACRO tree_sql_lit(s) AS '''' || replace(s, '''', '''''') || '''';
CREATE OR REPLACE MACRO tree_sql_ident(s) AS '"' || replace(s, '"', '""') || '"';
CREATE OR REPLACE MACRO tree_sql_list(csv) AS list_transform(string_split(csv, ','), lambda x: trim(x));
CREATE OR REPLACE MACRO tree_sql_is_ident(s) AS regexp_matches(s, '^[A-Za-z_][A-Za-z0-9_]*$');

-- The one spelling of a generated object's name: kind ('proj' or 't'), schema, tree.
-- Length-prefix the schema, because no escaping of the separator alone is injective here:
-- doubling underscores still maps ('a_','c') and ('a','_c') to the same a__c. With the
-- schema's length in front, decoding reads the number, then exactly that many characters,
-- then the separator, then the rest as the name, so no two pairs can collide:
-- ('a_b','c') is proj_3_a_b_c, ('a','b_c') is proj_1_a_b_c, ('a_','c') is proj_2_a__c
-- and ('a','_c') is proj_1_a__c.
CREATE OR REPLACE MACRO tree_sql_object_name(kind, sch, nm) AS
  tree_sql_ident(kind || '_' || length(sch) || '_' || sch || '_' || nm);

-- The validation ladder for the S group, shared by tree_compile_create and tree_compile_alter
-- so that altering a tree cannot bypass a check create enforces. `verb` prefixes the message.
-- Returns true when the semantic is acceptable; raises otherwise.
CREATE OR REPLACE MACRO tree_sql_check_semantic(sem, attr_text, verb) AS
  CASE
    WHEN regexp_matches(COALESCE(attr_text, ''), '(?i)\bAS\s+"?_')
      THEN error(verb || ': ATTR alias collides with the canonical prefix: ' || regexp_extract(attr_text, '(?i)\bAS\s+("?_[A-Za-z0-9_]*)', 1))
    -- A NULL name, or a body with no macro to derive one from, would compile the pseudo map
    -- and the pseudo_classes INSERT to NULL; both would then be dropped from the statement
    -- list instead of refusing. A macro-bound entry passes with a NULL body because the DDL
    -- compilers run tree_expand_pseudo first, which fills the body in from macro(args);
    -- prefix entries are exempt entirely -- expansion is what gives them their names.
    WHEN len(list_filter(COALESCE((sem).pseudo, []), lambda x: (x).prefix IS NULL AND ((x).name IS NULL OR ((x).body IS NULL AND (x).macro IS NULL)))) > 0
      THEN error(verb || ': every PSEUDO needs a name and a body or macro')
    WHEN len(list_distinct(list_transform(COALESCE((sem).pseudo, []), lambda x: (x).name))) <> len(COALESCE((sem).pseudo, []))
      THEN error(verb || ': S-coherence: a pseudo-class is bound twice')
    ELSE true END;

-- Structural companion to the ATTR-alias regex above: the regex only sees an explicit
-- "AS _x", so an implicit or quoted alias still reaches the projection. DESCRIBE the
-- compiled relation instead -- DuckDB renames the displaced duplicate of a canonical
-- column to _size_1 (etc.), so its presence is the proof that an attribute shadowed one.
CREATE OR REPLACE MACRO tree_sql_shadow_check(rel_sql, verb) AS
  'SELECT CASE WHEN count(*) > 0 THEN error(''' || verb || ': attribute column shadows a canonical column: '' || string_agg(DISTINCT regexp_replace(column_name, ''_[0-9]+$'', ''''), '', '')) END'
  || ' FROM (DESCRIBE ' || rel_sql || ')'
  || ' WHERE regexp_matches(column_name, ''^_(root|pre|level|parent|size|children|next|type|id|classes|attr_map|element|pseudo)_[0-9]+$'')';
