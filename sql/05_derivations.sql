-- Standalone lemmas. The projection compiler emits the same text; these exist for direct use and for the M1 identities.

-- The parent join is tree_sql_parent_join() verbatim (its CTE reads __rn, which is why the
-- stage is named that here): the lemma and the projection compiler must derive parent the
-- same way, and a copy of the text would let a mutation of the fragment survive here.
--
-- The WHOLE __r -> __rn chain is mirrored, not just the join. Since M3 §2.1 _pre is the RANK of
-- ORDER within ROOT, not the ORDER value, so a lemma that went on casting ORDER straight to _pre
-- would agree with the compiler only where ORDER is already dense and 0-based -- which is every
-- fixture here, and precisely the case in which the disagreement cannot be observed. "The same
-- way" is a claim about every ORDER or it is not worth making.
CREATE OR REPLACE MACRO tree_derive_parent(source, root_csv, order_col, level_col) AS TABLE
  FROM query(
    'WITH __r AS (SELECT *, ' || tree_sql_root(root_csv, '') || ' AS _root, ' || order_col || ' AS __order, CAST(' || level_col || ' AS BIGINT) AS _level FROM ' || source || '), '
    || '__rn AS (SELECT *, CAST(row_number() OVER (PARTITION BY _root ORDER BY __order) - 1 AS BIGINT) AS _pre FROM __r), '
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
    || 'c.' || key || ' ' || tree_sql_encoder_tiebreak() || ')] FROM __src c JOIN __walk w ON c.' || parent || ' = w.__key), '
    -- An orphan (a parent key nowhere in the source) or a cycle leaves rows out of __walk, and
    -- the final join is an INNER one, so those rows were simply absent from the result: measured,
    -- 4 rows in and 3 out with no error. The DML path refuses exactly this, and says why --
    -- "rather than silently left out of the tree" (tree_compile_reach_check, sql/04_dml.sql) --
    -- and the lemma has to agree, or a malformed source comes back as a SMALLER tree that passes
    -- every validity check there is. The wording and the example-key shape are kept in step with
    -- that refusal so the two paths read the same way.
    --
    -- The guard is an uncorrelated scalar subquery in WHERE, which is the shape that types: the
    -- CASE's other arm is TRUE, and DuckDB binds `CASE WHEN .. THEN error(..) ELSE TRUE END` as
    -- the boolean -- verified before writing it, since error()'s own type is not boolean.
    || '__orph AS (SELECT count(*) AS __n, min(s.' || key || '::VARCHAR) AS __v FROM __src s ANTI JOIN __walk w ON s.' || key || ' = w.__key) '
    || 'SELECT s.*, w._root, CAST(row_number() OVER (ORDER BY w.__path) - 1 AS BIGINT) AS _pre, CAST(w._level AS BIGINT) AS _level FROM __src s JOIN __walk w ON s.' || key || ' = w.__key'
    || ' WHERE (SELECT CASE WHEN __n > 0 THEN tree_err(__n || '' rows are not reachable from a root: orphans or a cycle, e.g. key '' || COALESCE(__v, ''<NULL>'')) ELSE TRUE END FROM __orph)');
