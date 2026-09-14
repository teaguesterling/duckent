-- Standalone lemmas. The projection compiler emits the same text; these exist for direct use and for the M1 identities.

-- The parent join is tree_sql_parent_join() verbatim (its CTE reads __r, which is why the
-- stage is named that here): the lemma and the projection compiler must derive parent the
-- same way, and a copy of the text would let a mutation of the fragment survive here.
CREATE OR REPLACE MACRO tree_derive_parent(source, root_csv, order_col, level_col) AS TABLE
  FROM query(
    'WITH __r AS (SELECT *, ' || tree_sql_root(root_csv, '') || ' AS _root, CAST(' || order_col || ' AS BIGINT) AS _pre, CAST(' || level_col || ' AS BIGINT) AS _level FROM ' || source || '), '
    || tree_sql_parent_join() || '__out AS (SELECT * FROM __p) SELECT * FROM __out');

CREATE OR REPLACE MACRO tree_encode(source, key, parent, sibling_order) AS TABLE
  FROM query(
    'WITH RECURSIVE __src AS (SELECT * FROM ' || source || '), '
    || '__walk USING KEY (__key) AS (SELECT {r0: 0} AS _root, ' || key || ' AS __key, 0 AS _level, '
    || '[row_number() OVER (ORDER BY ' || COALESCE(sibling_order || ', ', '') || key || ' ' || tree_sql_encoder_tiebreak() || ')] AS __path FROM __src WHERE ' || parent || ' IS NULL '
    -- every sibling_order column is qualified, not just the first: 'c.' || 'a, b' left b
    -- bare, where it binds to the walk relation if that has a column of the same name
    || 'UNION ALL SELECT {r0: 0}, c.' || key || ', w._level + 1, w.__path || [row_number() OVER (PARTITION BY c.' || parent || ' ORDER BY '
    || COALESCE(list_aggregate(list_transform(tree_sql_list(sibling_order), lambda x: 'c.' || x), 'string_agg', ', ') || ', ', '')
    || 'c.' || key || ' ' || tree_sql_encoder_tiebreak() || ')] FROM __src c JOIN __walk w ON c.' || parent || ' = w.__key) '
    || 'SELECT s.*, w._root, CAST(row_number() OVER (ORDER BY w.__path) - 1 AS BIGINT) AS _pre, CAST(w._level AS BIGINT) AS _level FROM __src s JOIN __walk w ON s.' || key || ' = w.__key');
