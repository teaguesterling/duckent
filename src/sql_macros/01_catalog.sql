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
