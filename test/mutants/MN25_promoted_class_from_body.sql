-- test/mutants/MN25_promoted_class_from_body.sql
-- A CLASS clause falls back to the pseudo-class of the same name when the row's CLASSES list
-- is empty: the promoted class is recomputed from the PSEUDO body at match time instead of
-- being read from the column the tree actually declared. It looks like a convenience -- P23
-- says a predicate promoted from a PSEUDO body to a CLASSES list must select the same rows,
-- so why not answer either from whichever is bound? -- and it is a semantics change: a tree
-- that declares `def` only as a pseudo-class then answers `.def` too, so a class nothing
-- declares is silently served, and the projection's CLASSES stops being the only source of
-- truth for what a row's classes are.
--
-- Copied from sql/07_match.sql's tree_sql_clause with one edit: the 'class' branch emits a
-- CASE that reads _pseudo[value] when _classes is NULL or empty. Comments trimmed to the
-- branches they explain.
CREATE OR REPLACE MACRO tree_sql_clause(kind, value, op, arg, alias, attr_cols, has_map, p, elem) AS
  CASE kind
    WHEN 'type'   THEN alias || '._type = ' || tree_sql_lit(value)
    WHEN 'id'     THEN alias || '._id = ' || tree_sql_lit(value)
    -- the mutation
    WHEN 'class'  THEN 'CASE WHEN COALESCE(len(' || alias || '._classes), 0) = 0'
                       || ' THEN COALESCE(' || alias || '._pseudo[' || tree_sql_lit(value) || '], false)'
                       || ' ELSE COALESCE(list_contains(' || alias || '._classes, ' || tree_sql_lit(value) || '), false) END'
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
    WHEN 'pseudo_unknown' THEN 'false'
    ELSE error('tree_match: unknown clause kind ' || kind) END;
