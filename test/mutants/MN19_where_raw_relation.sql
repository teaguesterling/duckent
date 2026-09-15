-- test/mutants/MN19_where_raw_relation.sql
-- The where clause is compiled against the raw fixture relation instead of the
-- step's projection row. Copied from sql/07_match.sql with the 'where' branch
-- changed to hit test/data/app.parquet directly, keyed on node_id.
CREATE OR REPLACE MACRO tree_sql_clause(kind, value, op, arg, alias, attr_cols, has_map, p, elem) AS
  CASE kind
    WHEN 'type'   THEN alias || '._type = ' || tree_sql_lit(value)
    WHEN 'id'     THEN alias || '._id = ' || tree_sql_lit(value)
    WHEN 'class'  THEN 'COALESCE(list_contains(' || alias || '._classes, ' || tree_sql_lit(value) || '), false)'
    WHEN 'pseudo' THEN CASE value
                         WHEN 'first-child' THEN tree_sql_first_child(alias, p, elem)
                         WHEN 'last-child'  THEN tree_sql_last_child(alias, p, elem)
                         ELSE 'COALESCE(' || alias || '._pseudo[' || tree_sql_lit(value) || '], false)' END
    WHEN 'attr'   THEN CASE
        WHEN list_contains(attr_cols, value)
          THEN 'COALESCE(' || alias || '.' || tree_sql_ident(value) || ' ' || op || ' ' || arg || ', false)'
        WHEN has_map
          THEN 'COALESCE(' || CASE WHEN tree_sql_literal_type(arg) IS NULL
                                   THEN alias || '._attr_map[' || tree_sql_lit(value) || ']'
                                   ELSE 'TRY_CAST(' || alias || '._attr_map[' || tree_sql_lit(value) || '] AS ' || tree_sql_literal_type(arg) || ')' END
               || ' ' || op || ' ' || arg || ', false)'
        ELSE error('tree_match: attribute ' || value || ' is neither a projected column nor served by ATTR MAP') END
    WHEN 'where'  THEN 'EXISTS (SELECT 1 FROM read_parquet(''test/data/app.parquet'') __w WHERE __w.node_id = ' || alias || '._pre AND ' || value || ')'
    WHEN 'pseudo_unknown' THEN 'false'
    ELSE error('tree_match: unknown clause kind ' || kind) END;
