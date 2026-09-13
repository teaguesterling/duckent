-- test/mutants/MN19_where_raw_relation.sql
-- The where clause is compiled against the raw fixture relation instead of the
-- step's projection row. Copied from sql/07_match.sql with the 'where' branch
-- changed to hit test/data/app.parquet directly, keyed on node_id.
CREATE OR REPLACE MACRO tree_sql_clause(kind, value, op, arg) AS
  CASE kind
    WHEN 'type'   THEN '§._type = ' || tree_sql_lit(value)
    WHEN 'id'     THEN '§._id = ' || tree_sql_lit(value)
    WHEN 'class'  THEN 'COALESCE(list_contains(§._classes, ' || tree_sql_lit(value) || '), false)'
    WHEN 'pseudo' THEN 'COALESCE(§._pseudo[' || tree_sql_lit(value) || '], false)'
    WHEN 'attr'   THEN 'COALESCE(§.' || tree_sql_ident(value) || ' ' || op || ' ' || arg || ', false)'
    WHEN 'where'  THEN 'EXISTS (SELECT 1 FROM read_parquet(''test/data/app.parquet'') __w WHERE __w.node_id = §._pre AND ' || value || ')'
    WHEN 'pseudo_unknown' THEN 'false'
    ELSE error('tree_match: unknown clause kind ' || kind) END;
