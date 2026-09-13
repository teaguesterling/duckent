-- test/mutants/MN21_type_default_null.sql
-- TYPE no longer defaults to 'node'. Copied from sql/02_projection.sql with both
-- occurrences of COALESCE((shape).semantic.type, '''node''') changed to
-- COALESCE((shape).semantic.type, 'NULL::VARCHAR').
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
     || COALESCE((shape).semantic.type, 'NULL::VARCHAR') || ' AS _type, ' || COALESCE((shape).semantic.id, 'NULL::VARCHAR') || ' AS _id, '
     || COALESCE((shape).semantic.classes, 'NULL::VARCHAR[]') || ' AS _classes, ' || COALESCE((shape).semantic.attr_map, 'NULL') || ' AS _attr_map, '
     || tree_sql_pseudo_map((shape).semantic) || ' AS _pseudo'
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
     || COALESCE((shape).semantic.type, 'NULL::VARCHAR') || ' AS _type, ' || COALESCE((shape).semantic.id, 'NULL::VARCHAR') || ' AS _id, '
     || COALESCE((shape).semantic.classes, 'NULL::VARCHAR[]') || ' AS _classes, ' || COALESCE((shape).semantic.attr_map, 'NULL') || ' AS _attr_map, '
     || tree_sql_pseudo_map((shape).semantic) || ' AS _pseudo'
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
