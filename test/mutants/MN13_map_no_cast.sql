-- test/mutants/MN13_map_no_cast.sql
-- An ATTR MAP comparison is made without the literal-typed cast: the map value stays VARCHAR
-- and the LITERAL is coerced to text instead, so `[n>9]` compares '9' and '10' as strings and
-- answers that neither is greater than 9 -- the failure sql/07_match.sql's comment names
-- ('3' > '10' is true as text). The map is MAP(VARCHAR, VARCHAR), so the direction of the
-- cast is the whole of the semantics: cast the value to the literal's type (right) or the
-- literal to the value's (wrong, and silent -- it binds and it returns rows).
--
-- Copied from sql/07_match.sql's tree_sql_clause with one edit: the has_map branch's
-- TRY_CAST(... AS <literal type>) around the map lookup is dropped and the arg is wrapped in
-- CAST(... AS VARCHAR) instead. The quoted-literal case (tree_sql_literal_type IS NULL) is
-- untouched -- it always compared as text. Comments trimmed to the branches they explain.
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
        -- the mutation: no TRY_CAST on the map value; the literal is cast to VARCHAR instead
        WHEN has_map
          THEN 'COALESCE(' || alias || '._attr_map[' || tree_sql_lit(value) || ']'
               || ' ' || op || ' ' || CASE WHEN tree_sql_literal_type(arg) IS NULL THEN arg
                                           ELSE 'CAST(' || arg || ' AS VARCHAR)' END || ', false)'
        ELSE error('tree_match: attribute ' || value || ' is neither a projected column nor served by ATTR MAP') END
    WHEN 'where'  THEN 'EXISTS (SELECT 1 FROM (SELECT unnest(' || alias || ', recursive := false)) __w WHERE ' || value || ')'
    WHEN 'pseudo_unknown' THEN 'false'
    ELSE error('tree_match: unknown clause kind ' || kind) END;
