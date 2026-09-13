-- sql/06_selector.sql

-- Normalize any list of step structs to one fixed shape so missing fields read as NULL.
CREATE OR REPLACE MACRO tree_steps(steps) AS (
  WITH st AS (
    SELECT generate_subscripts(steps, 1) AS i,
           unnest(steps::STRUCT(comb VARCHAR, type VARCHAR, id VARCHAR, class VARCHAR, attr VARCHAR, pseudo VARCHAR, "where" VARCHAR, "as" VARCHAR)[]) AS s),
  nodes AS (
    SELECT 0 AS i, 0 AS sub, 'selector' AS kind, NULL::VARCHAR AS value, NULL::VARCHAR AS op, NULL::VARCHAR AS arg, NULL::VARCHAR AS alias
    UNION ALL SELECT i, 0, 'step', NULL, CASE WHEN i = 1 THEN NULL ELSE COALESCE(s.comb, 'desc') END, NULL, s."as" FROM st
    UNION ALL SELECT i, 1, 'type', s.type, NULL, NULL, NULL FROM st WHERE s.type IS NOT NULL
    UNION ALL SELECT i, 2, 'id', s.id, NULL, NULL, NULL FROM st WHERE s.id IS NOT NULL
    UNION ALL SELECT i, 3, 'class', s.class, NULL, NULL, NULL FROM st WHERE s.class IS NOT NULL
    UNION ALL SELECT i, 4, 'attr',
        regexp_extract(s.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 1),
        regexp_extract(s.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 2),
        regexp_extract(s.attr, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE|ILIKE|NOT LIKE)\s*(.+?)\s*$', 3), NULL FROM st WHERE s.attr IS NOT NULL
    UNION ALL SELECT i, 5, 'pseudo', s.pseudo, NULL, NULL, NULL FROM st WHERE s.pseudo IS NOT NULL
    UNION ALL SELECT i, 6, 'where', s."where", NULL, NULL, NULL FROM st WHERE s."where" IS NOT NULL),
  numbered AS (SELECT CAST(row_number() OVER (ORDER BY i, sub) - 1 AS INTEGER) AS node_id, * FROM nodes),
  parented AS (
    SELECT n.node_id,
           CASE n.kind WHEN 'selector' THEN NULL WHEN 'step' THEN 0 ELSE (SELECT p.node_id FROM numbered p WHERE p.kind = 'step' AND p.i = n.i) END AS parent_id,
           n.kind, n.value, n.op, n.arg, n.alias
    FROM numbered n)
  SELECT list({node_id: node_id, parent_id: parent_id, kind: kind, value: value, op: op, arg: arg, alias: alias} ORDER BY node_id)::TREE_SELECTOR FROM parented);

CREATE OR REPLACE MACRO tree_treeql_comb(op) AS
  CASE op WHEN 'desc' THEN 'DESCENDANT' WHEN 'child' THEN 'CHILD' WHEN 'next' THEN 'SIBLING' WHEN 'after' THEN 'FOLLOWING' ELSE NULL END;

CREATE OR REPLACE MACRO tree_treeql_clause(kind, value, op, arg) AS
  CASE kind WHEN 'type' THEN 'TYPE ' || tree_sql_lit(value)
            WHEN 'id' THEN 'ID ' || tree_sql_lit(value)
            WHEN 'class' THEN 'CLASS ' || tree_sql_lit(value)
            WHEN 'attr' THEN 'ATTR ' || value || ' ' || op || ' ' || arg
            WHEN 'pseudo' THEN 'PSEUDO ' || tree_sql_lit(value)
            WHEN 'where' THEN 'WHERE ' || value END;

-- Linear printer: one line per step. Nested HAS/NOT groups are M2.
CREATE OR REPLACE MACRO tree_selector_to_treeql(sel) AS (
  WITH n AS (SELECT unnest(sel, recursive := true)),
  steps AS (
    SELECT s.node_id, s.op, s.alias,
           (SELECT string_agg(tree_treeql_clause(c.kind, c.value, c.op, c.arg), ', ' ORDER BY c.node_id) FROM n c WHERE c.parent_id = s.node_id) AS clauses
    FROM n s WHERE s.kind = 'step')
  SELECT string_agg(
           rtrim(COALESCE(tree_treeql_comb(op) || ' ', '') || COALESCE('(' || clauses || ')', '') || COALESCE(' AS ' || alias, '')),
           chr(10) ORDER BY node_id)
  FROM steps);
