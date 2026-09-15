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
-- untouched -- it always compared as text. The copy is GENERATED verbatim from the source
-- macro by test/mutants/regen.py, comments included; .control.sql is the same copy with the
-- edit left out, so a diff between the two IS the mutation.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/07_match.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- Clause predicate on the step alias, which is passed in: a placeholder substituted afterwards
-- would rewrite any user text that happened to contain it. Attribute and pseudo filters are
-- NULL-definite. p is the projection relation text and elem the tree's ELEMENT flag, both only
-- for the positional built-ins. MN19 mutates the where branch.
CREATE OR REPLACE MACRO tree_sql_clause(kind, value, op, arg, alias, attr_cols, has_map, p, elem) AS
  CASE kind
    WHEN 'type'   THEN alias || '._type = ' || tree_sql_lit(value)
    WHEN 'id'     THEN alias || '._id = ' || tree_sql_lit(value)
    WHEN 'class'  THEN 'COALESCE(list_contains(' || alias || '._classes, ' || tree_sql_lit(value) || '), false)'
    -- The built-ins are compiled by tree_sql_builtin_pseudo, which returns NULL for every other
    -- name -- so this branch consults the one list rather than repeating it. A declared
    -- pseudo-class is a lookup in the projection's _pseudo map.
    WHEN 'pseudo' THEN COALESCE(tree_sql_builtin_pseudo(value, alias, p, elem),
                                'COALESCE(' || alias || '._pseudo[' || tree_sql_lit(value) || '], false)')
    -- An attribute resolves to a projected column first, then to ATTR MAP. The map is
    -- MAP(VARCHAR, VARCHAR), so a comparison against a number or a boolean has to cast the
    -- value ('3' > '10' is true as text); a quoted literal compares as text and needs none.
    -- TRY_CAST, not CAST: a row whose map holds text where a number was asked for should not
    -- match, not abort the query. MN13 mutates the cast.
    --
    -- The column lookup is CASE-INSENSITIVE, because SQL identifiers are and the projection's
    -- columns are SQL identifiers: `[Name=x]` on a tree whose column is `name` names that column.
    -- It used to be a byte comparison against the artifact, which on a MAP-less tree refused a
    -- mis-cased name outright and on a MAP tree did something worse -- fell past the column into
    -- the map, which serves every key, and answered no rows. The column is emitted with the
    -- spelling the projection STORES, so the generated SQL binds whatever the selector wrote.
    --
    -- A canonical column is not an attribute: it is the tree's own representation, and P14 says
    -- MATCH sees the projection's DECLARED attributes. Checked FIRST, before the map, for the
    -- same reason the case fold matters -- on an ATTR MAP tree `_level` would otherwise be a
    -- lookup for a key the map cannot hold, which reads as "no such row" rather than as "wrong
    -- question". WHERE is where a question about the representation belongs, so it is named.
    WHEN 'attr'   THEN CASE
        WHEN list_contains(tree_canonical_columns(), lower(COALESCE(value, '')))
          THEN tree_err('tree_match: attribute ' || value || ' is a canonical column, not an attribute; use a WHERE clause')
        WHEN len(list_filter(attr_cols, lambda c: lower((c).name) = lower(value))) > 0
          THEN 'COALESCE(' || tree_sql_attr_col_cmp(alias,
                 (list_filter(attr_cols, lambda c: lower((c).name) = lower(value))[1]).name,
                 (list_filter(attr_cols, lambda c: lower((c).name) = lower(value))[1])."type",
                 op, arg) || ', false)'
        -- the mutation: no TRY_CAST on the map value; the literal is cast to VARCHAR instead
        WHEN has_map
          THEN 'COALESCE(' || alias || '._attr_map[' || tree_sql_lit(value) || ']'
               || ' ' || op || ' ' || CASE WHEN tree_sql_literal_type(arg) IS NULL THEN arg
                                           ELSE 'CAST(' || arg || ' AS VARCHAR)' END || ', false)'
        ELSE tree_err('tree_match: attribute ' || COALESCE(value, '<NULL>') || ' is neither a projected column nor served by ATTR MAP') END
    -- One level only: recursive := true flattens _root's struct into its component columns, so
    -- _root itself stops being addressable and falls through to an enclosing step alias
    -- (ambiguous, or worse, silently the wrong row). Unqualified names resolve to this step's
    -- own row first; another step's alias is legal when qualified (spec 6.2).
    WHEN 'where'  THEN 'EXISTS (SELECT 1 FROM (SELECT unnest(' || alias || ', recursive := false)) __w WHERE ' || value || ')'
    WHEN 'pseudo_unknown' THEN 'false'
    -- COALESCE for the same reason as the combinator above: a NULL kind is an IR node nothing
    -- in this codebase builds, so its refusal is the one a hand-built selector most needs.
    ELSE tree_err('tree_match: unknown clause kind ' || COALESCE(kind, '<NULL>')) END;
