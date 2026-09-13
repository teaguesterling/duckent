-- Standalone lemmas. The projection compiler emits the same text; these exist for direct use and for the M1 identities.

CREATE OR REPLACE MACRO tree_derive_parent(source, root_csv, order_col, level_col) AS TABLE
  FROM query(
    'WITH __r AS (SELECT *, ' || tree_sql_root(root_csv, '') || ' AS _root, CAST(' || order_col || ' AS BIGINT) AS _pre, CAST(' || level_col || ' AS BIGINT) AS _level FROM ' || source || ') '
    || 'SELECT a.*, b._pre AS _parent FROM __r a ASOF LEFT JOIN __r b ON a._root = b._root AND b._level = a._level - 1 AND b._pre < a._pre');

CREATE OR REPLACE MACRO tree_encode(source, key, parent, sibling_order) AS TABLE
  FROM query(
    'WITH RECURSIVE __src AS (SELECT * FROM ' || source || '), '
    || '__walk USING KEY (__key) AS (SELECT {r0: 0} AS _root, ' || key || ' AS __key, 0 AS _level, '
    || '[row_number() OVER (ORDER BY ' || COALESCE(sibling_order || ', ', '') || key || ' ' || tree_sql_encoder_tiebreak() || ')] AS __path FROM __src WHERE ' || parent || ' IS NULL '
    || 'UNION ALL SELECT {r0: 0}, c.' || key || ', w._level + 1, w.__path || [row_number() OVER (PARTITION BY c.' || parent || ' ORDER BY '
    || COALESCE('c.' || sibling_order || ', ', '') || 'c.' || key || ' ' || tree_sql_encoder_tiebreak() || ')] FROM __src c JOIN __walk w ON c.' || parent || ' = w.__key) '
    || 'SELECT s.*, w._root, CAST(row_number() OVER (ORDER BY w.__path) - 1 AS BIGINT) AS _pre, CAST(w._level AS BIGINT) AS _level FROM __src s JOIN __walk w ON s.' || key || ' = w.__key');
