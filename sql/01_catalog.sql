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

CREATE TABLE IF NOT EXISTS tree_catalog.pseudo_classes(
  database_name VARCHAR, schema_name VARCHAR, tree_name VARCHAR,
  name VARCHAR, kind VARCHAR, body VARCHAR, origin VARCHAR, purity VARCHAR);

CREATE TABLE IF NOT EXISTS tree_catalog.selector_languages(
  language VARCHAR PRIMARY KEY, parser VARCHAR, printer VARCHAR, bare_safe BOOLEAN);
INSERT INTO tree_catalog.selector_languages VALUES ('treeql', NULL, 'tree_selector_to_treeql', true) ON CONFLICT DO NOTHING;

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
CREATE OR REPLACE MACRO tree_catalog_pseudo_classes() AS TABLE SELECT * FROM tree_catalog.pseudo_classes;
CREATE OR REPLACE MACRO tree_catalog_assertions() AS TABLE SELECT * FROM tree_state.assertions;
CREATE OR REPLACE MACRO tree_catalog_languages() AS TABLE SELECT * FROM tree_catalog.selector_languages;
