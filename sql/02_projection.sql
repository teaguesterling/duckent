-- sql/02_projection.sql
-- Fragment macros. Each returns SQL text. Mutants override exactly one of these.

-- ROOT struct literal: fields named after the columns when they are identifiers, r<i> otherwise; {r0: 0} when absent.
CREATE OR REPLACE MACRO tree_sql_root(root_csv, qual) AS
  CASE WHEN root_csv IS NULL THEN '{r0: 0}'
       ELSE '{' || list_aggregate(list_transform(tree_sql_list(root_csv),
              lambda x, i: (CASE WHEN tree_sql_is_ident(x) THEN x ELSE 'r' || i END) || ': ' || qual || x), 'string_agg', ', ') || '}' END;

-- MAP(VARCHAR, BOOLEAN) of expression-bodied pseudo-classes.
-- 1.5.5 note: every struct dot-access (the "sem" parameter and the lambda-bound "p")
-- must be parenthesized -- (sem).pseudo, (p).name -- when this macro is ultimately
-- inlined into a table function argument (query(tree_compile_projection(...))). Left
-- unparenthesized, DuckDB's binder in that context silently misparses "p.name" as a
-- table.column reference instead of a struct field access (it does not merely error;
-- it can produce a wrong literal), so this is not just a style preference.
CREATE OR REPLACE MACRO tree_sql_pseudo_map(sem) AS
  CASE WHEN sem IS NULL OR (sem).pseudo IS NULL OR len(list_filter((sem).pseudo, lambda p: (p).name IS NOT NULL)) = 0
       THEN 'MAP([]::VARCHAR[], []::BOOLEAN[])'
       ELSE 'MAP([' || list_aggregate(list_transform(list_filter((sem).pseudo, lambda p: (p).name IS NOT NULL), lambda p: tree_sql_lit((p).name)), 'string_agg', ', ')
            || '], [' || list_aggregate(list_transform(list_filter((sem).pseudo, lambda p: (p).name IS NOT NULL), lambda p: '(' || (p).body || ')'), 'string_agg', ', ')
            || '])::MAP(VARCHAR, BOOLEAN)' END;

-- The S columns of the projection, one definition for both bases, so the two branches of
-- tree_compile_projection cannot drift apart. ATTR MAP is cast to the canonical map type
-- (an undeclared one is a typed NULL of that type, not VARCHAR) and ELEMENT is a per-row
-- predicate defaulting to true, NULL-definite like every other filter in the language.
-- MN21 mutates the TYPE default here.
CREATE OR REPLACE MACRO tree_sql_sem_cols(sem) AS
  COALESCE((sem).type, '''node''') || ' AS _type, ' || COALESCE((sem).id, 'NULL::VARCHAR') || ' AS _id, '
  || COALESCE((sem).classes, 'NULL::VARCHAR[]') || ' AS _classes, '
  || CASE WHEN (sem).attr_map IS NULL THEN 'NULL::MAP(VARCHAR, VARCHAR)' ELSE 'CAST(' || (sem).attr_map || ' AS MAP(VARCHAR, VARCHAR))' END || ' AS _attr_map, '
  || 'COALESCE(' || COALESCE((sem).element, 'true') || ', false) AS _element, '
  || tree_sql_pseudo_map(sem) || ' AS _pseudo';

-- Derived parent for level basis: nearest prior row at level - 1 within the root (ASOF join). MN2 mutates this.
CREATE OR REPLACE MACRO tree_sql_parent_join() AS
  '__p AS (SELECT a.*, b._pre AS _parent FROM __r a ASOF LEFT JOIN __r b ON a._root = b._root AND b._level = a._level - 1 AND b._pre < a._pre), ';

-- Derived size: distance to the next row at the same or higher level within the root. Quadratic; the C++ port replaces it with a stack walk.
CREATE OR REPLACE MACRO tree_sql_size_expr() AS
  'COALESCE((SELECT min(b._pre) FROM __p b WHERE b._root = a._root AND b._pre > a._pre AND b._level <= a._level), max(a._pre) OVER (PARTITION BY a._root) + 1) - a._pre - 1';

CREATE OR REPLACE MACRO tree_sql_children_expr() AS
  '(SELECT count(*) FROM __s b WHERE b._root = a._root AND b._parent = a._pre)';

-- Encoder tiebreak after the sibling key: source order of the key. MN1 mutates this to DESC.
CREATE OR REPLACE MACRO tree_sql_encoder_tiebreak() AS 'ASC';

-- 1.5.5 notes:
-- (a) tree_compile_projection must be a pure scalar expression (no WITH/SELECT in its
--     own macro body). A macro whose body is a subquery -- even one with no FROM, over
--     constants only -- makes DuckDB reject it as a table function argument with
--     "Table function cannot contain subqueries" when called as query(tree_compile_projection(...)).
--     So the "cfg" bindings from the design (root_sql, attrs, cols, ...) are inlined as
--     repeated calls to the same pure fragment macros/expressions instead of CTE columns;
--     the compiled SQL text produced for the '*'-attr, order-declared cases is unchanged.
-- (b) row_number() OVER (PARTITION BY <root>) with no ORDER BY does not preserve scan
--     order in 1.5.5 (partitioning is not a stable sort), so the "frozen order" fallback
--     (no ORDER declared) needs an explicit sequence column (__seq) to order by. __seq
--     is dropped again within __r's own SELECT (via "* EXCLUDE (__seq)" when attr_text
--     is '*', or simply left out of an explicit column list otherwise), so it never
--     needs to appear in the final EXCLUDE list below.
-- (c) shape.parent/size/children/next name columns from the *source*, referenced at a
--     later CTE stage than the one that first projects from the source. When attr_text
--     is a closed or explicit list (not '*'), those columns are not otherwise carried
--     forward, so the later reference (e.g. __p's "a.<parent col>") fails to bind. Each
--     such column is now also carried as a hidden __*_raw alias from the first stage
--     that sees the source, and every surviving hidden helper column (__parent_raw,
--     __size_raw, __children_raw, __next_raw) is EXCLUDEd from the final SELECT.
CREATE OR REPLACE MACRO tree_compile_projection(shape, source, attr_text) AS (
  (CASE WHEN (shape).level IS NOT NULL THEN
     'WITH __src AS (' || (CASE WHEN (shape)."order" IS NULL THEN 'SELECT *, row_number() OVER () AS __seq FROM ' ELSE 'SELECT * FROM ' END) || source || '), '
     || '__r AS (SELECT '
     || (CASE WHEN attr_text = '' THEN ''
              WHEN attr_text = '*' AND (shape)."order" IS NULL THEN '* EXCLUDE (__seq), '
              WHEN attr_text = '*' THEN '*, '
              ELSE attr_text || ', ' END)
     || tree_sql_root((shape).root, '') || ' AS _root, CAST('
     || COALESCE((shape)."order", 'row_number() OVER (PARTITION BY ' || tree_sql_root((shape).root, '') || ' ORDER BY __seq) - 1')
     || ' AS BIGINT) AS _pre, CAST(' || (shape).level || ' AS BIGINT) AS _level, '
     || tree_sql_sem_cols((shape).semantic)
     || (CASE WHEN (shape).parent IS NOT NULL THEN ', ' || (shape).parent || ' AS __parent_raw' ELSE '' END)
     || (CASE WHEN (shape).size IS NOT NULL THEN ', ' || (shape).size || ' AS __size_raw' ELSE '' END)
     || (CASE WHEN (shape).children IS NOT NULL THEN ', ' || (shape).children || ' AS __children_raw' ELSE '' END)
     || (CASE WHEN (shape).next IS NOT NULL THEN ', ' || (shape).next || ' AS __next_raw' ELSE '' END)
     || ' FROM __src), '
     || CASE WHEN (shape).parent IS NOT NULL THEN '__p AS (SELECT a.*, CAST(a.__parent_raw AS BIGINT) AS _parent FROM __r a), '
             ELSE tree_sql_parent_join() END
   ELSE
     'WITH RECURSIVE __src AS (SELECT * FROM ' || source || '), '
     || '__walk USING KEY (__key) AS (SELECT ' || tree_sql_root((shape).root, '') || ' AS _root, ' || (shape).key || ' AS __key, 0 AS _level, '
     || '[row_number() OVER (PARTITION BY ' || tree_sql_root((shape).root, '') || ' ORDER BY ' || COALESCE((shape).sibling_order || ', ', '') || (shape).key || ' ' || tree_sql_encoder_tiebreak() || ')] AS __path '
     || 'FROM __src WHERE ' || (shape).parent || ' IS NULL '
     || 'UNION ALL SELECT ' || tree_sql_root((shape).root, 'c.') || ' AS _root, c.' || (shape).key || ', w._level + 1, '
     || 'w.__path || [row_number() OVER (PARTITION BY c.' || (shape).parent || ' ORDER BY '
     || COALESCE(list_aggregate(list_transform(tree_sql_list((shape).sibling_order), lambda x: 'c.' || x), 'string_agg', ', ') || ', ', '')
     || 'c.' || (shape).key || ' ' || tree_sql_encoder_tiebreak() || ')] '
     || 'FROM __src c JOIN __walk w ON c.' || (shape).parent || ' = w.__key), '
     || '__r0 AS (SELECT ' || (CASE WHEN attr_text = '' THEN '' WHEN attr_text = '*' THEN 's.*, ' ELSE attr_text || ', ' END)
     || 'w._root, CAST(row_number() OVER (PARTITION BY w._root ORDER BY w.__path) - 1 AS BIGINT) AS _pre, '
     || 'CAST(w._level AS BIGINT) AS _level, s.' || (shape).key || ' AS __key, s.' || (shape).parent || ' AS __pkey, '
     || tree_sql_sem_cols((shape).semantic)
     || (CASE WHEN (shape).size IS NOT NULL THEN ', s.' || (shape).size || ' AS __size_raw' ELSE '' END)
     || (CASE WHEN (shape).children IS NOT NULL THEN ', s.' || (shape).children || ' AS __children_raw' ELSE '' END)
     || (CASE WHEN (shape).next IS NOT NULL THEN ', s.' || (shape).next || ' AS __next_raw' ELSE '' END)
     || ' FROM __src s JOIN __walk w ON s.' || (shape).key || ' = w.__key), '
     || '__p AS (SELECT a.* EXCLUDE (__key, __pkey), b._pre AS _parent FROM __r0 a LEFT JOIN __r0 b ON b.__key = a.__pkey AND b._root = a._root), '
   END)
  || '__s AS (SELECT a.*, ' || COALESCE(CASE WHEN (shape).size IS NOT NULL THEN 'CAST(a.__size_raw AS BIGINT)' END, tree_sql_size_expr()) || ' AS _size FROM __p a), '
  || '__c AS (SELECT a.*, ' || COALESCE(CASE WHEN (shape).children IS NOT NULL THEN 'CAST(a.__children_raw AS BIGINT)' END, tree_sql_children_expr()) || ' AS _children, '
  || COALESCE(CASE WHEN (shape).next IS NOT NULL THEN 'CAST(a.__next_raw AS BIGINT)' END, 'a._pre + a._size + 1') || ' AS _next FROM __s a) '
  || (CASE WHEN COALESCE(list_aggregate(list_filter([
         CASE WHEN (shape).level IS NOT NULL AND (shape).parent IS NOT NULL THEN '__parent_raw' END,
         CASE WHEN (shape).size IS NOT NULL THEN '__size_raw' END,
         CASE WHEN (shape).children IS NOT NULL THEN '__children_raw' END,
         CASE WHEN (shape).next IS NOT NULL THEN '__next_raw' END
       ], lambda x: x IS NOT NULL), 'string_agg', ', '), '') = ''
       THEN 'SELECT * FROM __c'
       ELSE 'SELECT * EXCLUDE (' || list_aggregate(list_filter([
         CASE WHEN (shape).level IS NOT NULL AND (shape).parent IS NOT NULL THEN '__parent_raw' END,
         CASE WHEN (shape).size IS NOT NULL THEN '__size_raw' END,
         CASE WHEN (shape).children IS NOT NULL THEN '__children_raw' END,
         CASE WHEN (shape).next IS NOT NULL THEN '__next_raw' END
       ], lambda x: x IS NOT NULL), 'string_agg', ', ') || ') FROM __c' END)
);
