-- test/mutants/MN26_pre_is_order_value.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/02_projection.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
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
--     can no longer be dropped inside __r: since M3 §2.1 the ORDER expression is carried
--     forward as __order, and __seq IS that expression when no ORDER was declared, so __r
--     must still be able to read it from __src. It is excluded in the FINAL SELECT instead,
--     alongside __order -- and only when it actually reached the output, which is when
--     attr_text is '*'; a closed or explicit attribute list never carries it past __r.
-- (b2) _pre is the rank of ORDER within ROOT (M3 §2.1), not the ORDER value itself, so that
--     every O(1) form the language compiles -- _parent + 1, _pre = 0, _pre + _size + 1 --
--     holds whatever values ORDER takes. It is computed in its own stage, __rn, because a
--     window function cannot be referenced by the ASOF join in the same SELECT. A declared
--     PARENT or NEXT is a value in ORDER space, so it is TRANSLATED to a position by
--     joining on __order (§2.2), never cast: casting was only ever right for a source whose
--     ORDER was already dense and 0-based per root.
-- (c) shape.parent/size/children/next name columns from the *source*, referenced at a
--     later CTE stage than the one that first projects from the source. When attr_text
--     is a closed or explicit list (not '*'), those columns are not otherwise carried
--     forward, so the later reference (e.g. __p's "a.<parent col>") fails to bind. Each
--     such column is now also carried as a hidden __*_raw alias from the first stage
--     that sees the source, and every surviving hidden helper column (__parent_raw,
--     __size_raw, __children_raw, __next_raw) is EXCLUDEd from the final SELECT.
-- (d) The parent basis walks WITHIN a root. A forest whose KEY repeats per ROOT -- the same
--     categories table loaded under two forest names, say -- is a perfectly good forest, and
--     both halves of the walk have to say so. The joins are the obvious half: a child joins
--     its parent on the key AND on the root, so a row in one root can never be attached under
--     an identically-keyed parent in another. The recursive CTE's KEY is the half that is easy
--     to miss: USING KEY (__key) makes the key the walk's identity, so two roots sharing a key
--     COLLAPSE INTO ONE ROW -- measured, with the joins already root-aware: a 10-row two-root
--     forest walked to 5 rows, and the rows that survived were then refused by P13 for starting
--     above level 0. The identity of a node in a forest is (key, root), so that is the key.
CREATE OR REPLACE MACRO tree_compile_projection(shape, source, attr_text) AS (
  -- The level basis is taken when LEVEL is declared AND when neither LEVEL nor PARENT is:
  -- R2 defaults to LEVEL 0 (M3 §2.6), so a shape that declares no structure at all is a
  -- forest of one-node trees -- a plain SQL table -- rather than a refusal.
  (CASE WHEN (shape).level IS NOT NULL OR (shape).parent IS NULL THEN
     'WITH __src AS (' || (CASE WHEN (shape)."order" IS NULL THEN 'SELECT *, row_number() OVER () AS __seq FROM ' ELSE 'SELECT * FROM ' END) || source || '), '
     || '__r AS (SELECT '
     || (CASE WHEN attr_text = '' THEN ''
              WHEN attr_text = '*' THEN '*, '
              ELSE attr_text || ', ' END)
     || tree_sql_root((shape).root, '') || ' AS _root, '
     || COALESCE((shape)."order", '__seq') || ' AS __order, '
     || 'CAST(' || COALESCE((shape).level, '0') || ' AS BIGINT) AS _level, '
     || tree_sql_sem_cols((shape).semantic)
     || (CASE WHEN (shape).parent IS NOT NULL THEN ', ' || (shape).parent || ' AS __parent_raw' ELSE '' END)
     || (CASE WHEN (shape).size IS NOT NULL THEN ', ' || (shape).size || ' AS __size_raw' ELSE '' END)
     || (CASE WHEN (shape).children IS NOT NULL THEN ', ' || (shape).children || ' AS __children_raw' ELSE '' END)
     || (CASE WHEN (shape).next IS NOT NULL THEN ', ' || (shape).next || ' AS __next_raw' ELSE '' END)
     || ' FROM __src), '
     -- R1 made canonical within R0: the rank of ORDER in its root, 0-based and gap-free, so every
     -- O(1) form (parent + 1, pre = 0, pre + size + 1) holds whatever values ORDER takes.
     || '__rn AS (SELECT *, CAST(row_number() OVER (PARTITION BY _root ORDER BY __order) - 1 AS BIGINT) AS _pre FROM __r), '
     || CASE WHEN (shape).parent IS NOT NULL
             -- a declared PARENT is a value in ORDER space: translate it to a position
             THEN '__p AS (SELECT a.*, par._pre AS _parent FROM __rn a LEFT JOIN __rn par ON par._root = a._root AND par.__order = a.__parent_raw), '
             ELSE tree_sql_parent_join() END
   ELSE
     'WITH RECURSIVE __src AS (SELECT * FROM ' || source || '), '
     || '__walk USING KEY (__key, _root) AS (SELECT ' || tree_sql_root((shape).root, '') || ' AS _root, ' || (shape).key || ' AS __key, 0 AS _level, '
     || '[row_number() OVER (PARTITION BY ' || tree_sql_root((shape).root, '') || ' ORDER BY ' || COALESCE((shape).sibling_order || ', ', '') || (shape).key || ' ' || tree_sql_encoder_tiebreak() || ')] AS __path '
     || 'FROM __src WHERE ' || (shape).parent || ' IS NULL '
     || 'UNION ALL SELECT ' || tree_sql_root((shape).root, 'c.') || ' AS _root, c.' || (shape).key || ', w._level + 1, '
     || 'w.__path || [row_number() OVER (PARTITION BY c.' || (shape).parent || ' ORDER BY '
     || COALESCE(list_aggregate(list_transform(tree_sql_list((shape).sibling_order), lambda x: 'c.' || x), 'string_agg', ', ') || ', ', '')
     || 'c.' || (shape).key || ' ' || tree_sql_encoder_tiebreak() || ')] '
     || 'FROM __src c JOIN __walk w ON c.' || (shape).parent || ' = w.__key AND ' || tree_sql_root((shape).root, 'c.') || ' = w._root), '
     || '__r0 AS (SELECT ' || (CASE WHEN attr_text = '' THEN '' WHEN attr_text = '*' THEN 's.*, ' ELSE attr_text || ', ' END)
     || 'w._root, CAST(row_number() OVER (PARTITION BY w._root ORDER BY w.__path) - 1 AS BIGINT) AS _pre, '
     || 'CAST(w._level AS BIGINT) AS _level, s.' || (shape).key || ' AS __key, s.' || (shape).parent || ' AS __pkey, '
     || tree_sql_sem_cols((shape).semantic)
     || (CASE WHEN (shape).size IS NOT NULL THEN ', s.' || (shape).size || ' AS __size_raw' ELSE '' END)
     || (CASE WHEN (shape).children IS NOT NULL THEN ', s.' || (shape).children || ' AS __children_raw' ELSE '' END)
     || (CASE WHEN (shape).next IS NOT NULL THEN ', s.' || (shape).next || ' AS __next_raw' ELSE '' END)
     || ' FROM __src s JOIN __walk w ON s.' || (shape).key || ' = w.__key AND ' || tree_sql_root((shape).root, 's.') || ' = w._root), '
     -- __key SURVIVES this stage (only __pkey is dropped): a declared NEXT in this basis is a
     -- value in KEY space, and __c translates it by joining __s on the key. It is EXCLUDEd from
     -- the FINAL select instead, where __order is excluded in the level basis.
     || '__p AS (SELECT a.* EXCLUDE (__pkey), b._pre AS _parent FROM __r0 a LEFT JOIN __r0 b ON b.__key = a.__pkey AND b._root = a._root), '
   END)
  -- A declared SIZE is the column; a derived one is the ASOF join above, which brings its own
  -- __mx/__cand/__end stages with it. A declared CHILDREN is the column; a derived one is the
  -- grouped count, joined here.
  || CASE WHEN (shape).size IS NOT NULL THEN '__s AS (SELECT a.*, CAST(a.__size_raw AS BIGINT) AS _size FROM __p a), ' ELSE tree_sql_size_join() END
  || CASE WHEN (shape).children IS NOT NULL THEN '' ELSE tree_sql_children_join() END
  || '__c AS (SELECT a.*, '
  || CASE WHEN (shape).children IS NOT NULL THEN 'CAST(a.__children_raw AS BIGINT)' ELSE 'COALESCE(ch.__cn, 0)' END || ' AS _children, '
  -- A declared NEXT is a value in ORDER space (level basis) or KEY space (parent basis), TRANSLATED
  -- to a position by joining __s, never cast (§2.2). One that names no row keeps the structural
  -- successor.
  --
  -- That COALESCE is INFORMATION-DESTROYING, and O conformance (sql/04_dml.sql) is structurally
  -- blind past it: a declared NEXT naming no row leaves _next EQUAL to the derived default --
  -- which is exactly what a CONFORMING NEXT leaves -- so no comparison over this relation's
  -- OUTPUT can tell the two apart. (An earlier version of this comment claimed §3.1 counts it as
  -- a disagreement. It cannot, and never could.) The raw value does not survive: __next_raw is
  -- EXCLUDEd below, and ingest is handed the projection alone, so closing the hole would mean
  -- either publishing a new column on every tree or dropping this fallback -- a §2.2 semantic
  -- change that 10_projection pins in three records. Left open deliberately: a NEXT naming no
  -- row yields the CORRECT structural successor, so unlike a wrong SIZE, PARENT or CHILDREN it
  -- cannot produce a wrong answer -- it is a declaration typo, not a corrupted encoding. FINDINGS
  -- carries the reasoning and what it would cost to close.
  || CASE WHEN (shape).next IS NULL THEN 'a._pre + a._size + 1'
          ELSE 'COALESCE(nx._pre, a._pre + a._size + 1)' END || ' AS _next FROM __s a'
  || CASE WHEN (shape).children IS NOT NULL THEN '' ELSE ' LEFT JOIN __ch ch ON ch._root = a._root AND ch.__cp = a._pre' END
  || CASE WHEN (shape).next IS NULL THEN ''
          WHEN (shape).level IS NOT NULL OR (shape).parent IS NULL
          THEN ' LEFT JOIN __s nx ON nx._root = a._root AND nx.__order = a.__next_raw'
          ELSE ' LEFT JOIN __s nx ON nx._root = a._root AND nx.__key = a.__next_raw' END
  || ') '
  -- The EXCLUDE list is built TWICE -- once as the gate that decides whether an EXCLUDE clause is
  -- emitted at all, once as the clause itself -- so every hidden helper must be added to BOTH.
  -- Emitter-only suppresses the clause and leaks the name; gate-only promises a name the list
  -- does not contain.
  || (CASE WHEN COALESCE(list_aggregate(list_filter([
         CASE WHEN (shape).level IS NOT NULL OR (shape).parent IS NULL THEN '__order' END,
         CASE WHEN NOT ((shape).level IS NOT NULL OR (shape).parent IS NULL) THEN '__key' END,
         CASE WHEN ((shape).level IS NOT NULL OR (shape).parent IS NULL) AND (shape)."order" IS NULL AND attr_text = '*' THEN '__seq' END,
         CASE WHEN (shape).level IS NOT NULL AND (shape).parent IS NOT NULL THEN '__parent_raw' END,
         CASE WHEN (shape).size IS NOT NULL THEN '__size_raw' END,
         CASE WHEN (shape).children IS NOT NULL THEN '__children_raw' END,
         CASE WHEN (shape).next IS NOT NULL THEN '__next_raw' END
       ], lambda x: x IS NOT NULL), 'string_agg', ', '), '') = ''
       THEN 'SELECT * FROM __c'
       ELSE 'SELECT * EXCLUDE (' || list_aggregate(list_filter([
         CASE WHEN (shape).level IS NOT NULL OR (shape).parent IS NULL THEN '__order' END,
         CASE WHEN NOT ((shape).level IS NOT NULL OR (shape).parent IS NULL) THEN '__key' END,
         CASE WHEN ((shape).level IS NOT NULL OR (shape).parent IS NULL) AND (shape)."order" IS NULL AND attr_text = '*' THEN '__seq' END,
         CASE WHEN (shape).level IS NOT NULL AND (shape).parent IS NOT NULL THEN '__parent_raw' END,
         CASE WHEN (shape).size IS NOT NULL THEN '__size_raw' END,
         CASE WHEN (shape).children IS NOT NULL THEN '__children_raw' END,
         CASE WHEN (shape).next IS NOT NULL THEN '__next_raw' END
       ], lambda x: x IS NOT NULL), 'string_agg', ', ') || ') FROM __c' END)
);
