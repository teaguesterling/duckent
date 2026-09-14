-- sql/00_types.sql
CREATE TYPE TREE_SEMANTIC AS STRUCT(
  type VARCHAR, id VARCHAR, classes VARCHAR, attr VARCHAR, attr_map VARCHAR,
  pseudo STRUCT(name VARCHAR, body VARCHAR, prefix VARCHAR)[]);

CREATE TYPE TREE_SHAPE AS STRUCT(
  root VARCHAR, "order" VARCHAR, key VARCHAR, level VARCHAR, parent VARCHAR, sibling_order VARCHAR,
  size VARCHAR, children VARCHAR, next VARCHAR,
  semantic TREE_SEMANTIC);

CREATE TYPE TREE_SPEC AS STRUCT(shape TREE_SHAPE, abstract BOOLEAN, "like" VARCHAR, source VARCHAR, storage VARCHAR);

CREATE TYPE TREE_SELECTOR AS STRUCT(
  node_id INTEGER, parent_id INTEGER, kind VARCHAR, value VARCHAR, op VARCHAR, arg VARCHAR, alias VARCHAR)[];

CREATE OR REPLACE MACRO tree_semantic(type := NULL, id := NULL, classes := NULL, attr := NULL, attr_map := NULL, pseudo := NULL) AS
  {type: type, id: id, classes: classes, attr: attr, attr_map: attr_map, pseudo: pseudo}::TREE_SEMANTIC;

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
-- Escape then separate: every underscore inside a part is doubled, so a lone underscore
-- occurs only as the separator and the encoding is injective -- ('a_b','c') compiles to
-- proj_a__b_c and ('a','b_c') to proj_a_b__c, which used to be the same object.
CREATE OR REPLACE MACRO tree_sql_object_name(kind, sch, nm) AS
  tree_sql_ident(kind || '_' || replace(sch, '_', '__') || '_' || replace(nm, '_', '__'));

-- The validation ladder for the S group, shared by tree_compile_create and tree_compile_alter
-- so that altering a tree cannot bypass a check create enforces. `verb` prefixes the message.
-- Returns true when the semantic is acceptable; raises otherwise.
CREATE OR REPLACE MACRO tree_sql_check_semantic(sem, attr_text, verb) AS
  CASE
    WHEN regexp_matches(COALESCE(attr_text, ''), '(?i)\bAS\s+"?_')
      THEN error(verb || ': ATTR alias collides with the canonical prefix: ' || regexp_extract(attr_text, '(?i)\bAS\s+("?_[A-Za-z0-9_]*)', 1))
    WHEN len(list_distinct(list_transform(COALESCE((sem).pseudo, []), lambda x: (x).name))) <> len(COALESCE((sem).pseudo, []))
      THEN error(verb || ': S-coherence: a pseudo-class is bound twice')
    ELSE true END;
