-- test/mutants/MN07_unknown_pseudo_raises.sql
-- An unknown pseudo-class is a hard error instead of a clause that selects nothing. The
-- language's contract is the other way round (spec D-N7): a name no tree binds is NOT a
-- syntax error -- the selector still compiles, the clause matches no row, and the count
-- comes back on _match_unknown_pseudos so the caller can see it was asked for. A front-end
-- that raises makes a selector carrying one unusable even inside a :not(), where the whole
-- point is that the test fails.
--
-- Copied from sql/07_match.sql's tree_sql_clause with one edit: the 'pseudo_unknown' branch
-- returns error(...) where the original returns the text 'false'. Comments trimmed to the
-- branches they explain.
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
    WHEN 'where'  THEN 'EXISTS (SELECT 1 FROM (SELECT unnest(' || alias || ', recursive := false)) __w WHERE ' || value || ')'
    -- the mutation
    WHEN 'pseudo_unknown' THEN error('tree_match: unknown pseudo-class ' || value)
    ELSE error('tree_match: unknown clause kind ' || kind) END;
