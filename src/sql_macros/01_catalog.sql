-- sql/01_catalog.sql
CREATE SCHEMA IF NOT EXISTS tree_catalog;
CREATE SCHEMA IF NOT EXISTS tree_state;

CREATE TABLE IF NOT EXISTS tree_catalog.trees(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  is_abstract BOOLEAN, like_tree VARCHAR, source_sql VARCHAR,
  basis VARCHAR, profile VARCHAR, storage VARCHAR, order_source VARCHAR,
  has_semantic BOOLEAN, description VARCHAR,
  PRIMARY KEY (database_name, schema_name, tree_name));

CREATE TABLE IF NOT EXISTS tree_catalog.slots(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  block VARCHAR, slot VARCHAR, expression VARCHAR);

CREATE TABLE IF NOT EXISTS tree_catalog.predicates(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  name VARCHAR, kind VARCHAR, body VARCHAR, origin VARCHAR, purity VARCHAR);

CREATE TABLE IF NOT EXISTS tree_catalog.selector_languages(
  language VARCHAR PRIMARY KEY, parser VARCHAR, printer VARCHAR, bare_safe BOOLEAN);
-- The registry is the FRONT-END SEAM, and core registers only the language it can serve
-- without one: treeql, whose parser is NULL because IR needs no parsing. Every other language
-- is registered by whatever provides it -- css by the css front-end in 09_css.sql, which is the
-- file a core-only build (the C++ extension's MVP) does not embed. A front-end shipped as its
-- own extension registers the same way, by inserting its row and naming its own parser, so the
-- registration API is SQL rather than C++.
--
-- Keeping this row here and the css row there is what lets every embedded file be byte-identical
-- to the plan repo's: the extension's difference is WHICH FILES it embeds, not what they say.
INSERT INTO tree_catalog.selector_languages VALUES ('treeql', NULL, 'tree_selector_to_treeql', true) ON CONFLICT DO NOTHING;

-- THE CLAUSE-KIND VOCABULARY, declared once. Every clause kind is a predicate over exactly one
-- declared S-block slot, plus `where` as the host door -- so this table is the engine's answer to
-- "what may a step say about a row". It is CLOSED: the S block is fixed by the ROWS contract, so a
-- seventh kind is extensibility nothing has asked for, and `tree_sql_clause` keeps its CASE
-- because the `attr` arm (projected column vs ATTR MAP, TRY_CAST by literal type, the negation
-- prefix) is not expressible as a template.
--
-- What this table replaces is the SET being written out by hand: it was named at THIRTEEN sites
-- across four files -- eight that can read a declaration and five that cannot (see the agreement
-- gate below). One of the eight generates docs/cheatsheet.md, so a drifted copy there did not
-- fail, it published a false claim; and one, 07_match.sql:584, wrote the set with `where` left
-- out, so a search for the full set did not even find it.
--
-- step_field is the TREE_STEP_* field that builds the kind, and it exists for the agreement gate:
-- TREE_STEP_L0/L1/L2 are DuckDB STRUCT types whose field lists are fixed at definition and cannot
-- be generated from this table, so the duplication cannot be removed and is verified instead --
-- at ALL THREE levels, in both directions, by test/sql/46_slot_registry.test. That qualification
-- was missing and the claim was overstated: both agreement queries read TREE_STEP_L0 alone, so a
-- field added to L1 or L2 and nowhere else passed every gate in the repo. It no longer does.
CREATE TABLE IF NOT EXISTS tree_catalog.clause_kinds(
  kind VARCHAR PRIMARY KEY, keyword VARCHAR, slot VARCHAR, needs_semantic BOOLEAN, step_field VARCHAR);
INSERT INTO tree_catalog.clause_kinds VALUES
  ('type',   'TYPE',   '_type',       true,  'type'),
  ('id',     'ID',     '_key',        true,  'id'),
  ('class',  'CLASS',  '_tags',       true,  'class'),
  ('attr',   'ATTR',   '_attr',       true,  'attr'),
  ('pseudo', 'PSEUDO', '_predicate',  true,  'pseudo'),
  -- the host door reads no S slot, so it is available on a tree with no SEMANTIC group
  ('where',  'WHERE',  NULL,          false, 'where')
ON CONFLICT DO NOTHING;

-- THE COMBINATOR VOCABULARY. Unlike clause kinds this is OPEN: a front-end registers a row from
-- its own .sql file exactly as 09_css.sql registers its selector language, because the
-- registration API is SQL and not C++.
--
-- template carries the join condition with {a} and {b} standing for the two step aliases, and the
-- rows are DERIVED by calling the relation macro with those placeholders rather than transcribed
-- -- so the logic and the reasoning recorded around it (the root COALESCE, the IS NOT DISTINCT
-- FROM that makes level-0 rows siblings of each other) stay in sql/07_match.sql and there is no
-- second copy to drift. The rows are inserted THERE, because load order is numeric and those
-- macros do not exist yet at this point in the file.
--
-- requires_sibling_order is a CAPABILITY, and it is the reason this table is correctness rather
-- than tidiness. The sibling-free refusal used to hardcode `op IN ('next','after')`; a relation
-- registered without being added to that list compiled against a _pre no SIBLING_ORDER governs
-- and answered with whatever rows happened to land there.
CREATE TABLE IF NOT EXISTS tree_catalog.combinators(
  op VARCHAR PRIMARY KEY, keyword VARCHAR, template VARCHAR, template_elem VARCHAR,
  requires_sibling_order BOOLEAN);

CREATE TABLE IF NOT EXISTS tree_catalog.settings(name VARCHAR PRIMARY KEY, value VARCHAR);
-- This row governs ONE thing: how a front-end parses a selector handed over as TEXT -- today
-- the runner's rewrite, later the binder. It is not read by the compiler: _match_language is
-- COALESCE(language, 'treeql'), because a selector handed over as IR was never parsed and its
-- provenance is TREEQL whatever the default says.
--
-- Core defaults to the language core registers. M2 flipped it to 'css' (core design section 1:
-- "treeql initially, flipped to css by setting once CSS lands") and 09_css.sql now performs that
-- flip, next to the row it depends on -- so a build without a css front-end cannot default to a
-- language nothing has registered. TREEQL TEXT still has no parser (that is M-LANG), so with
-- core alone a bare text selector is refused rather than mis-parsed.
INSERT INTO tree_catalog.settings VALUES ('tree_default_selector_language', 'treeql') ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS tree_catalog.attachments(child_tree VARCHAR, parent_tree VARCHAR, join_sql VARCHAR);

CREATE TABLE IF NOT EXISTS tree_catalog.compiled(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  artifact VARCHAR, object_name VARCHAR, sql_text VARCHAR);

CREATE TABLE IF NOT EXISTS tree_state.partitions(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  root_key VARCHAR, epoch INTEGER, row_count BIGINT, p13_ok BOOLEAN, loaded_at TIMESTAMP);

CREATE TABLE IF NOT EXISTS tree_state.assertions(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  artifact VARCHAR, status VARCHAR, checked_epoch INTEGER, detail VARCHAR);

CREATE OR REPLACE MACRO tree_catalog_trees() AS TABLE SELECT * FROM tree_catalog.trees;
CREATE OR REPLACE MACRO tree_catalog_slots() AS TABLE SELECT * FROM tree_catalog.slots ORDER BY schema_name, tree_name, block, slot;
CREATE OR REPLACE MACRO tree_catalog_predicates() AS TABLE SELECT * FROM tree_catalog.predicates;
CREATE OR REPLACE MACRO tree_catalog_assertions() AS TABLE SELECT * FROM tree_state.assertions;
CREATE OR REPLACE MACRO tree_catalog_languages() AS TABLE SELECT * FROM tree_catalog.selector_languages;
CREATE OR REPLACE MACRO tree_catalog_clause_kinds() AS TABLE SELECT * FROM tree_catalog.clause_kinds;
CREATE OR REPLACE MACRO tree_catalog_combinators() AS TABLE SELECT * FROM tree_catalog.combinators;

-- Every node kind the IR allows: the four STRUCTURAL kinds, which are the IR's own shape and not a
-- vocabulary anything extends, plus every registered clause kind. Read by the constructor, the
-- printer and the compiler, so the set is stated here once instead of at six sites.
CREATE OR REPLACE MACRO tree_ir_kinds() AS
  ['selector', 'step', 'has', 'not'] || (SELECT list(kind) FROM tree_catalog.clause_kinds);
CREATE OR REPLACE MACRO tree_clause_kinds() AS (SELECT list(kind) FROM tree_catalog.clause_kinds);
