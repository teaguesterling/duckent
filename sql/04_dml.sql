-- sql/04_dml.sql (first part; the DML compilers are added in Task 7)

-- P13: within each ROOT partition, the first row is level 0 and no row descends more than one level.
-- Returns a statement that raises when violated. MN15 mutates tree_sql_p13_pred.
CREATE OR REPLACE MACRO tree_sql_p13_pred() AS 'd > 1 OR (rn = 1 AND _level <> 0)';

-- The source's (ROOT key, ORDER value) pairs with the size of each pair's group: the one relation
-- both the raising ingest check and tree_check's recorded assertion read, so the two cannot come
-- to disagree about what a tie is.
CREATE OR REPLACE MACRO tree_sql_order_dup_rel(order_expr, root_csv, source_sql) AS
  '(SELECT __k, __o, count(*) OVER (PARTITION BY __k, __o) AS __n FROM (SELECT '
  || tree_sql_root(root_csv, '') || '::VARCHAR AS __k, ' || order_expr || ' AS __o FROM ' || source_sql || '))';

-- ORDER on its own (M3 §3.2), whenever ORDER is declared, whatever else is. NULL when no ORDER
-- was declared, so the caller's list_filter drops the statement.
--
-- It runs over the SOURCE, before the projection numbers anything, for two reasons. The first is
-- that row_number() would otherwise number NULLs and ties arbitrarily and every later check --
-- P13 included -- would see a well-formed tree and report nothing, or report a level jump for
-- what is really a tie. The second is row-count correctness, which is newer and sharper: since
-- M3 §2.2 a declared PARENT is a value in ORDER space translated by a LEFT JOIN on __order, so
-- two rows of one root sharing an ORDER value make the projection return MORE rows than its
-- source (measured: 3 source rows -> 5 projected). Every ingest site therefore emits this
-- statement BEFORE any statement that evaluates the projection.
--
-- `label` lands inside a single-quoted literal of the generated statement, so its own quotes are
-- doubled, as everywhere else here. The ROOT hint rides on the tie message rather than on P13:
-- an unpartitioned ORDER column that restarts per tree shows up here, as a tie, and nowhere else.
CREATE OR REPLACE MACRO tree_compile_order_check(order_expr, root_csv, source_sql, label) AS
  CASE WHEN order_expr IS NULL THEN NULL ELSE
    'SELECT CASE'
    || ' WHEN __nulls > 0 THEN tree_err(''ORDER is NULL in tree ' || replace(label, '''', '''''') || ' at root '' || COALESCE(__null_k, ''<NULL>''))'
    || ' WHEN __mx > 1 THEN tree_err(''ORDER is not a traversal in tree ' || replace(label, '''', '''''') || ': root '' || COALESCE((__w).k, ''<NULL>'') || '' has '' || __mx || '' rows with ORDER value '' || COALESCE((__w).o, ''<NULL>'')'
    || CASE WHEN root_csv IS NULL THEN ' || ''; if the relation holds several trees whose ORDER restarts, declare ROOT''' ELSE '' END
    -- The root and the ORDER value are ONE arg_max over a struct, evaluated once and bound, not two
    -- independent arg_max calls: with two roots tying at the same group size nothing made separate
    -- calls resolve their tie to the same row, so the message could have named a root and a value
    -- that do not actually collide. Picking the pair structurally makes that unrepresentable.
    || ') END FROM (SELECT count(*) FILTER (WHERE __o IS NULL) AS __nulls, min(__k) FILTER (WHERE __o IS NULL) AS __null_k,'
    || ' max(__n) AS __mx, arg_max({k: __k, o: __o::VARCHAR}, __n) AS __w FROM '
    || tree_sql_order_dup_rel(order_expr, root_csv, source_sql) || ')'
  END;

-- The two parent-basis ingest checks (M3 §3.2's sibling: a structural basis that cannot be walked
-- is refused, never silently walked part-way). Both return NULL when there is no KEY to walk --
-- the level basis, where the caller passes NULL -- so the caller's list_filter drops them.
--
-- A NOTE ON THE ROOT CLAUSE, which both share. tree_sql_root(NULL, qual) is not NULL: it is the
-- literal '{r0: 0}', the one-partition constant the projection uses when no ROOT was declared.
-- That is deliberate and load-bearing here -- it is what makes both statements fail CLOSED on a
-- rootless tree, rather than concatenating to NULL and being filtered out of the statement list,
-- which is how an optional check disappears. But it also means a literal ' in root ' || __k
-- clause would print `in root {r0: 0}` to someone who never wrote a ROOT, naming a synthetic
-- partition as if it were theirs. So the clause is built only when ROOT was actually declared:
-- rooted, the message names the offending partition; rootless, it says nothing about partitions.
--
-- Before the walk: the KEY must identify at most one row per ROOT. A key repeated within a root
-- attaches every child to BOTH bearers, and the walk's recursive CTE -- keyed on (__key, _root),
-- which is a node's identity in a forest -- then collapses the duplicates in an order nothing
-- defines, so rows multiply or vanish depending on which copy won. Like the ORDER check, this runs
-- over the SOURCE and before any statement that evaluates the projection: afterwards the damage is
-- already numbered and reads as a well-formed tree.
--
-- The root and the key are ONE arg_max over a struct, bound once as __w and read as (__w).k and
-- (__w).v -- exactly as tree_compile_order_check picks its root and ORDER value, and for exactly
-- the same reason. With two independent arg_max calls, two roots that each repeat a DIFFERENT key
-- and tie at the same group size have nothing forcing the two calls to resolve their tie to the
-- same row, so the message could name a (root, key) pair that does not actually collide. In
-- practice both calls share one scan order and agree, which is precisely the problem: the message
-- is correct by accident rather than by construction. Picking the pair structurally makes the
-- mismatch unrepresentable. It must stay ONE binding -- writing the struct expression twice would
-- be two aggregate instances again and close nothing.
--
-- Untested by construction, and deliberately so: which of several equally-tying roots gets named
-- is nondeterministic, so a record pinning the message would be fragile. The records that do exist
-- (dupkey, dupkey2, duproot) name a single colliding pair, where both forms agree byte for byte.
CREATE OR REPLACE MACRO tree_compile_key_check(key_expr, root_csv, source_sql, label) AS
  CASE WHEN key_expr IS NULL THEN NULL ELSE
    'SELECT CASE WHEN __mx > 1 THEN tree_err(''KEY '' || COALESCE((__w).v, ''<NULL>'') || '' appears '' || __mx || '' times'
    || CASE WHEN root_csv IS NULL THEN ' in tree ' || replace(label, '''', '''''') || ''')'
            ELSE ' in root '' || COALESCE((__w).k, ''<NULL>'') || '' of tree ' || replace(label, '''', '''''') || ''')' END
    || ' END FROM (SELECT max(__n) AS __mx, arg_max({k: __k, v: __v::VARCHAR}, __n) AS __w'
    || ' FROM (SELECT __k, __v, count(*) AS __n FROM (SELECT ' || tree_sql_root(root_csv, '') || '::VARCHAR AS __k, ' || key_expr || ' AS __v FROM ' || source_sql || ') GROUP BY __k, __v))'
  END;

-- After the key check: every source row must be reached by the walk from a NULL-parent row in
-- its own root. A row that is not is an orphan or sits on a cycle; either way it is refused
-- rather than silently left out of the tree. The parent basis requires KEY to be a plain column,
-- so when ATTR is open (`*`) the projection carries that column and the refusal can name an
-- example key; when ATTR is closed it compares row counts per root and names only the count.
CREATE OR REPLACE MACRO tree_compile_reach_check(key_expr, root_csv, source_sql, rel_sql, label, attr_text) AS
  CASE WHEN key_expr IS NULL THEN NULL
       WHEN attr_text = '*' THEN
    'SELECT tree_err(count(*) || '' rows of tree ' || replace(label, '''', '''''') || ' are not reachable from a root'
    || CASE WHEN root_csv IS NULL THEN '' ELSE ' in root '' || COALESCE(min(__k), ''<NULL>'') || ''' END
    || ': orphans or a cycle, e.g. key '' || COALESCE(min(__v::VARCHAR), ''<NULL>''))'
    || ' FROM (SELECT s.__k, s.__v FROM (SELECT ' || tree_sql_root(root_csv, '') || '::VARCHAR AS __k, ' || key_expr || ' AS __v FROM ' || source_sql || ') s'
    || ' ANTI JOIN (SELECT _root::VARCHAR AS __k, ' || key_expr || ' AS __v FROM ' || rel_sql || ') r ON r.__k = s.__k AND r.__v = s.__v) HAVING count(*) > 0'
       ELSE
    'SELECT tree_err((s.__n - COALESCE(r.__n, 0)) || '' rows of tree ' || replace(label, '''', '''''') || ' are not reachable from a root'
    || CASE WHEN root_csv IS NULL THEN '' ELSE ' in root '' || s.__k || ''' END
    || ': orphans or a cycle'')'
    || ' FROM (SELECT ' || tree_sql_root(root_csv, '') || '::VARCHAR AS __k, count(*) AS __n FROM ' || source_sql || ' GROUP BY 1) s'
    || ' LEFT JOIN (SELECT _root::VARCHAR AS __k, count(*) AS __n FROM ' || rel_sql || ' GROUP BY 1) r USING (__k)'
    || ' WHERE s.__n <> COALESCE(r.__n, 0) LIMIT 1'
  END;

-- P13 plus the level checks it never had (M3 §7.3). One statement, one message per failure class,
-- the first failing class reported: a NULL level, a negative level, a partition starting above
-- level 0, then the jump/start predicate itself.
--
-- The start-offset arm is gated on there being NO real jump anywhere (`rn > 1 AND d > 1`), and
-- deliberately does not reuse tree_sql_p13_pred: lag(_level, 1, -1) makes row 1 of a 1-based
-- partition look like a descent of 2, so counting the first row's own "jump" would fire the hint
-- on relations that also have genuine jumps, and hide them. tree_sql_p13_pred stays the jump/start
-- predicate, so MN15 still has exactly one thing to mutate.
--
-- `level_expr` is the LEVEL expression AS DECLARED, quoted into the hint so the message says what
-- to write: a source whose levels are 1-based (duck_blocks' top-level blocks, §7.7) conforms with
-- one declaration. `has_root` is no longer read -- the ROOT hint moved to tree_compile_order_check,
-- where a resetting ORDER actually shows up -- and is kept for arity.
--
-- Every aggregate in the hint is filtered to the OFFENDING partitions (`rn = 1 AND _level > 0`),
-- and the arm additionally requires them all to start at the SAME level. Unfiltered, the three
-- min()s ranged over every partition's first row, so a multi-root source with one conforming root
-- reported that root's level and advised subtracting it: two roots starting at 0 and 1 said "rows
-- start at level 0 ... declare LEVEL as 'lvl - 0'", a remedy that changes nothing and leaves the
-- tree refused -- worse diagnosis than the message this replaced, on exactly the shape ROOT is for.
-- When the offending partitions disagree no single offset fixes the source, so the hint would be
-- wrong whichever level it named; that case falls through to the jump arm below.
CREATE OR REPLACE MACRO tree_compile_p13(rel_sql, label, has_root, level_expr) AS
  'SELECT CASE'
  || ' WHEN count(*) FILTER (WHERE _level IS NULL) > 0 THEN tree_err(''LEVEL is NULL in tree ' || replace(label, '''', '''''') || ' at root '' || COALESCE(min(_root::VARCHAR) FILTER (WHERE _level IS NULL), ''<NULL>''))'
  || ' WHEN count(*) FILTER (WHERE _level < 0) > 0 THEN tree_err(''LEVEL is negative in tree ' || replace(label, '''', '''''') || ' at root '' || COALESCE(min(_root::VARCHAR) FILTER (WHERE _level < 0), ''<NULL>''))'
  || ' WHEN count(*) FILTER (WHERE rn = 1 AND _level > 0) > 0 AND count(*) FILTER (WHERE rn > 1 AND d > 1) = 0'
  || '   AND min(_level) FILTER (WHERE rn = 1 AND _level > 0) = max(_level) FILTER (WHERE rn = 1 AND _level > 0)'
  || ' THEN tree_err(''P13 violated in tree ' || replace(label, '''', '''''') || ': rows start at level '' || min(_level) FILTER (WHERE rn = 1 AND _level > 0)'
  || ' || ''; if the source''''s levels are '' || min(_level) FILTER (WHERE rn = 1 AND _level > 0)'
  || ' || ''-based, declare LEVEL as ''''' || replace(COALESCE(level_expr, '0'), '''', '''''') || ' - '' || min(_level) FILTER (WHERE rn = 1 AND _level > 0) || '''''''')'
  || ' WHEN count(*) FILTER (WHERE ' || tree_sql_p13_pred() || ') > 0'
  || ' THEN tree_err(''P13 violated in tree ' || replace(label, '''', '''''') || ': '' || count(*) FILTER (WHERE ' || tree_sql_p13_pred() || ') || '' rows descend more than one level or start above level 0'')'
  || ' END FROM (SELECT _root, _level, _level - lag(_level, 1, -1) OVER (PARTITION BY _root ORDER BY _pre) AS d, row_number() OVER (PARTITION BY _root ORDER BY _pre) AS rn FROM ' || rel_sql || ')';

-- O CONFORMANCE (M3 §3.1). A declared O column is a FAST PATH over a derivation, not a second
-- opinion about the tree's shape. SIZE, CHILDREN, NEXT -- and, in the level basis, PARENT --
-- each have a derived default, and a declared one that disagrees with it is a corrupted
-- encoding. Serving it would answer subtree, child, sibling and successor questions out of
-- numbers the rest of the language contradicts, so ingest refuses it rather than trusting it.
--
-- Whether this shape declares anything to check at all. PARENT counts only beside a declared
-- LEVEL: in the parent basis PARENT is the R slot the walk is BUILT from, so there is no
-- independent derivation to compare it against. slot_rows in sql/03_ddl.sql decides the block
-- the same way round (`CASE WHEN level_basis THEN 'O' ELSE 'R' END`), so the catalog and this
-- check cannot come to disagree about what an O slot is.
CREATE OR REPLACE MACRO tree_sql_declares_o(shape) AS
  (shape).size IS NOT NULL OR (shape).children IS NOT NULL OR (shape).next IS NOT NULL
  OR ((shape).parent IS NOT NULL AND (shape).level IS NOT NULL);

-- The ORDER column the refusal may NAME A VALUE from, or NULL to name the position only.
-- The message can read an ORDER value off the relation only when ORDER is a plain column the
-- projection actually carries, which is when ATTR is open; a computed ORDER ('node_id + 1') or
-- a closed ATTR list leaves nothing to read. That is the one place this refusal says less than
-- spec §3.1 asks -- the position is always given, and it identifies the row on its own.
CREATE OR REPLACE MACRO tree_sql_o_order_col(shape, attr_text) AS
  CASE WHEN attr_text = '*' AND tree_sql_is_ident((shape)."order") THEN (shape)."order" END;

-- Built once and used by all four arms: the ORDER value as text, or the literal NULL when there
-- is no column to read it from. Spelling it in one place keeps the arms from drifting -- the
-- EXCLUDE list in sql/02_projection.sql is the standing example of what "built twice" costs.
CREATE OR REPLACE MACRO tree_sql_o_ord_expr(order_col) AS
  COALESCE('x.' || tree_sql_ident(order_col) || '::VARCHAR', 'NULL');

-- The disagreements between the declared O columns and their derived defaults, as CTE text
-- ending in `__bad(slot, k, pos, ord, declared, derived)`. ONE definition, shared by the ingest
-- check that RAISES and the tree_check assertion that RECORDS, so the two can never come to
-- disagree about what a disagreement is.
--
-- rel_sql is the PROJECTION's output: it exposes _root, _pre, _level and the declared O columns
-- under their canonical names. The derivation is recomputed from its R columns alone -- __r
-- keeps _root, _pre and _level and nothing else -- so what is compared is "what this relation
-- says" against "what its own structure implies", with the declared columns unable to influence
-- the answer they are being checked against.
--
-- Comparisons are IS DISTINCT FROM: a NULL on either side is a disagreement, not a pass.
--
-- EVERY arm carries the full alias list, not just the first one. A UNION ALL takes its column
-- NAMES from its leading branch, and which branch leads here depends on which slots the shape
-- declares -- so aliasing only the SIZE arm (the arm that happens to come first when SIZE is
-- declared) left `__bad` with columns called ''PARENT'', ''CHILDREN'' or ''NEXT'' for any shape
-- that declared one of those WITHOUT a SIZE, and the ORDER BY k, pos, slot below failed to bind.
-- 11_ddl's with_children and with_next records are the shapes that have no SIZE.
--
-- __dnext is `_pre + _size + 1` UNCONDITIONALLY, because that is what the projection computes
-- for _next (sql/02_projection.sql) -- for every row, with no bound at the end of the root.
-- Bounding it by the root's max _pre and then skipping the rows where it came out NULL would
-- leave the LAST ROW of every root unchecked, and that row is a row like any other: 11_ddl
-- carries the record where it declares a NEXT naming a real earlier row.
CREATE OR REPLACE MACRO tree_sql_o_bad_cte(shape, rel_sql, order_col) AS
  'WITH __r AS (SELECT _root, _pre, _level FROM ' || rel_sql || '), '
  || '__rn AS (SELECT * FROM __r), '
  || tree_sql_parent_join()
  || tree_sql_size_join()
  || tree_sql_children_join()
  || '__d AS (SELECT a._root, a._pre, a._parent AS __dparent, a._size AS __dsize, '
  || 'COALESCE(ch.__cn, 0) AS __dchildren, a._pre + a._size + 1 AS __dnext '
  || 'FROM __s a LEFT JOIN __ch ch ON ch._root = a._root AND ch.__cp = a._pre), '
  || '__bad AS ('
  || list_aggregate(list_filter([
       CASE WHEN (shape).size IS NOT NULL THEN
         'SELECT ''SIZE'' AS slot, x._root::VARCHAR AS k, x._pre AS pos, ' || tree_sql_o_ord_expr(order_col)
         || ' AS ord, x._size::VARCHAR AS declared, d.__dsize::VARCHAR AS derived FROM ' || rel_sql
         || ' x JOIN __d d ON d._root = x._root AND d._pre = x._pre WHERE x._size IS DISTINCT FROM d.__dsize' END,
       CASE WHEN (shape).parent IS NOT NULL AND (shape).level IS NOT NULL THEN
         'SELECT ''PARENT'' AS slot, x._root::VARCHAR AS k, x._pre AS pos, ' || tree_sql_o_ord_expr(order_col)
         || ' AS ord, x._parent::VARCHAR AS declared, d.__dparent::VARCHAR AS derived FROM ' || rel_sql
         || ' x JOIN __d d ON d._root = x._root AND d._pre = x._pre WHERE x._parent IS DISTINCT FROM d.__dparent' END,
       CASE WHEN (shape).children IS NOT NULL THEN
         'SELECT ''CHILDREN'' AS slot, x._root::VARCHAR AS k, x._pre AS pos, ' || tree_sql_o_ord_expr(order_col)
         || ' AS ord, x._children::VARCHAR AS declared, d.__dchildren::VARCHAR AS derived FROM ' || rel_sql
         || ' x JOIN __d d ON d._root = x._root AND d._pre = x._pre WHERE x._children IS DISTINCT FROM d.__dchildren' END,
       CASE WHEN (shape).next IS NOT NULL THEN
         'SELECT ''NEXT'' AS slot, x._root::VARCHAR AS k, x._pre AS pos, ' || tree_sql_o_ord_expr(order_col)
         || ' AS ord, x._next::VARCHAR AS declared, d.__dnext::VARCHAR AS derived FROM ' || rel_sql
         || ' x JOIN __d d ON d._root = x._root AND d._pre = x._pre WHERE x._next IS DISTINCT FROM d.__dnext' END
     ], lambda q: q IS NOT NULL), 'string_agg', ' UNION ALL ')
  || ') ';

-- Refuse the FIRST disagreement, in (root, position, slot) order. A conforming tree yields no
-- row, so tree_err is never evaluated and nothing is raised -- the same shape as every other
-- ingest check here. NULL when the shape declares no O override, so the caller's list_filter
-- drops it.
--
-- `slot` is in the ORDER BY, and is not decoration. Two slots can disagree at the SAME (root,
-- position) -- a source whose SIZE and CHILDREN are both wrong on one row -- and ordering by
-- (k, pos) alone leaves the tie to scan order, so the same source and shape named SIZE on one
-- run and CHILDREN on the next. Both messages were true, which is exactly the problem: the
-- content was correct by accident rather than by construction. This is the same defect class as
-- the arg_max pairings in tree_compile_order_check and tree_compile_key_check, and it is closed
-- the same way -- structurally, so the mismatch is unrepresentable rather than merely unlikely.
CREATE OR REPLACE MACRO tree_compile_o_conformance(shape, rel_sql, label, order_col) AS
  CASE WHEN NOT tree_sql_declares_o(shape) THEN NULL ELSE
    tree_sql_o_bad_cte(shape, rel_sql, order_col)
    || 'SELECT tree_err(''O conformance violated in tree ' || replace(label, '''', '''''') || ': '' || slot'
    || ' || '' disagrees with its derived default at root '' || COALESCE(k, ''<NULL>'')'
    || ' || COALESCE('', ORDER '' || ord, '''') || '' (position '' || pos || ''): declared '' || COALESCE(declared, ''NULL'')'
    || ' || '', derived '' || COALESCE(derived, ''NULL'') || '' (a corrupted encoding, not a fast path)'')'
    || ' FROM (SELECT * FROM __bad ORDER BY k, pos, slot LIMIT 1)'
  END;

-- One RECORDED O assertion -- the DELETE and the INSERT for a single slot, as a two-element list
-- the caller flattens. tree_check reports, it never refuses (M3 §3.4), so this counts the same
-- __bad rows tree_compile_o_conformance raises on and writes 'ok' or 'violated' instead.
-- `cte` is NULL when the shape declares no O slot at all, which makes both statements NULL and
-- the caller's list_filter drop them.
CREATE OR REPLACE MACRO tree_sql_o_assert_stmts(db, sch, nm, slot, cte) AS
  ['DELETE FROM tree_state.assertions WHERE database_name = ' || tree_sql_lit(db) || ' AND schema_name = ' || tree_sql_lit(sch)
   || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''assert_o_' || lower(slot) || '''',
   'INSERT INTO tree_state.assertions ' || cte
   || 'SELECT ' || tree_sql_lit(db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm)
   || ', ''assert_o_' || lower(slot) || ''', CASE WHEN count(*) = 0 THEN ''ok'' ELSE ''violated'' END, '
   || '(SELECT max(epoch) FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(db)
   || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || '), '
   || 'count(*) || '' disagreeing rows'' || COALESCE('', first at root '' || (SELECT COALESCE(k, ''<NULL>'')'
   || ' || '' position '' || pos || '': declared '' || COALESCE(declared, ''NULL'') || '', derived '' || COALESCE(derived, ''NULL'')'
   || ' FROM __bad WHERE slot = ''' || slot || ''' ORDER BY k, pos LIMIT 1), '''') '
   || 'FROM __bad WHERE slot = ''' || slot || ''''];

-- helper: the tree row and its shape, or an error
--
-- The identity is COALESCEd into every message: a NULL schema or name makes the lookup empty,
-- so the FIRST branch is the one that fires -- and without the COALESCE its message would be
-- NULL, error(NULL) evaluates to NULL in 1.5.5, the whole context struct would be NULL, every
-- statement the verb builds from it would be NULL, and list_filter would drop them. The verb
-- would then run BEGIN ... COMMIT over nothing instead of refusing. tree_err covers the case
-- where the message goes NULL for some other reason; this covers the one we know about.
CREATE OR REPLACE MACRO tree_dml_context(verb, sch, nm) AS (
  SELECT CASE WHEN count(*) = 0 THEN tree_err(COALESCE(verb, '<NULL>') || ': tree ' || COALESCE(sch, '<NULL>') || '.' || COALESCE(nm, '<NULL>') || ' not found')
              -- an abstract tree records storage = materialized but owns no table, so without
              -- this the verb fails with a raw "table t_... does not exist" catalog error
              WHEN bool_or(is_abstract) THEN tree_err(verb || ': tree ' || sch || '.' || nm || ' is SHAPE ONLY (abstract); it has no storage')
              -- tree_check is the ONE verb M3 §3.4 lets a projection-mode tree reach: assertions
              -- are exactly what a tree with no storage can still be asked for, and answering
              -- them needs no table. Every other verb writes rows, so it still refuses here.
              WHEN max(storage) <> 'materialized' AND verb <> 'tree_check'
                THEN tree_err(verb || ': tree ' || sch || '.' || nm || ' is projection-mode; DML needs storage := materialized')
              ELSE {db: current_database(), shape: tree_shape_from_catalog(current_database(), sch, nm),
                    order_source: max(order_source),
                    -- storage and source are read by tree_compile_check alone, which is the one
                    -- verb M3 §3.4 lets a projection-mode tree reach; every other verb here has
                    -- already refused that storage mode.
                    storage: max(storage), source: max(source_sql),
                    attr: (SELECT expression FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND slot = 'ATTR'),
                    has_root: bool_or(EXISTS (SELECT 1 FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND slot = 'ROOT')),
                    tbl: 'tree_catalog.' || tree_sql_object_name('t', sch, nm),
                    -- The relation to READ for a check that writes no rows: the stored table for
                    -- a materialized tree, the projection MACRO for a projection-mode one, which
                    -- owns no table. `tbl` stays the WRITE target, read by the DML verbs alone --
                    -- every one of which has already refused a projection-mode tree above -- so a
                    -- read-only check reaching for `tbl` would name a table that does not exist.
                    rel: CASE WHEN max(storage) = 'materialized'
                              THEN 'tree_catalog.' || tree_sql_object_name('t', sch, nm)
                              ELSE 'tree_catalog.' || tree_sql_object_name('proj', sch, nm) || '()' END} END
  FROM tree_catalog.trees WHERE database_name = current_database() AND schema_name = sch AND tree_name = nm);

-- `frozen` means _pre is the source's scan order; taking it while preserve_insertion_order
-- is off would freeze an arbitrary order into the tree. Create refuses this; so must ingest.
CREATE OR REPLACE MACRO tree_sql_frozen_guard(order_source, verb) AS
  CASE WHEN order_source <> 'frozen' THEN NULL ELSE
    'SELECT CASE WHEN NOT current_setting(''preserve_insertion_order'') THEN error(''' || verb || ': ORDER is required because preserve_insertion_order is off'') END' END;

CREATE OR REPLACE MACRO tree_compile_insert(sch, nm, source) AS (
  WITH c AS (SELECT tree_dml_context('tree_insert', sch, nm) AS x),
  -- NULL in the level basis, which is how both parent-basis checks below drop out of the list
  p AS (SELECT x, tree_compile_projection(x.shape, source, x.attr) AS proj,
               CASE WHEN (x.shape).level IS NOT NULL OR (x.shape).parent IS NULL THEN NULL ELSE (x.shape).key END AS key_expr FROM c)
  SELECT list_filter(['BEGIN TRANSACTION',
    tree_sql_frozen_guard(x.order_source, 'tree_insert'),
    -- before the projection is evaluated, not after: a tie would otherwise be numbered first,
    -- and under a declared PARENT it multiplies rows rather than merely reordering them
    tree_compile_order_check((x.shape)."order", (x.shape).root, source, sch || '.' || nm),
    -- The NEW source alone, never unioned with x.tbl: insert refuses a ROOT that is already
    -- present (the statement below), so the roots arriving here are disjoint from the stored
    -- ones and a key they share with a stored row is not a collision.
    tree_compile_key_check(key_expr, (x.shape).root, source, sch || '.' || nm),
    'CREATE TEMP TABLE __duckent_new AS ' || proj,
    -- and the reach check right after it, because __duckent_new IS the walk's output
    tree_compile_reach_check(key_expr, (x.shape).root, source, '__duckent_new', sch || '.' || nm, x.attr),
    tree_sql_shadow_check('__duckent_new', 'tree_insert'),
    'SELECT CASE WHEN count(*) > 0 THEN error(''tree_insert: ROOT values already present in ' || replace(sch || '.' || nm, '''', '''''') || ': '' || string_agg(DISTINCT n._root::VARCHAR, '', '')) END FROM __duckent_new n JOIN tree_state.partitions p ON p.root_key = n._root::VARCHAR AND p.database_name = ' || tree_sql_lit(x.db) || ' AND p.schema_name = ' || tree_sql_lit(sch) || ' AND p.tree_name = ' || tree_sql_lit(nm),
    tree_compile_p13('__duckent_new', sch || '.' || nm, x.has_root, (x.shape).level),
    -- O conformance over the NEW partition, and after P13 so a malformed level is reported as
    -- that rather than as a disagreeing SIZE downstream of it. Ingest needs its own copy of this
    -- check because create only ever saw the source it was GIVEN: without it the fast path is
    -- corruptible by the back door, one unexamined partition at a time.
    tree_compile_o_conformance(x.shape, '__duckent_new', sch || '.' || nm, tree_sql_o_order_col(x.shape, x.attr)),
    -- BY NAME: the projection's column order follows the source's select list, which need
    -- not match the stored table's, and a positional INSERT misfiles same-typed columns
    'INSERT INTO ' || x.tbl || ' BY NAME SELECT * FROM __duckent_new',
    'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', _root::VARCHAR, 1, count(*), true, now() FROM __duckent_new GROUP BY _root',
    'DROP TABLE __duckent_new',
    'COMMIT'], lambda s: s IS NOT NULL) FROM p);

CREATE OR REPLACE MACRO tree_compile_replace(sch, nm, source) AS (
  WITH c AS (SELECT tree_dml_context('tree_replace', sch, nm) AS x),
  p AS (SELECT x, tree_compile_projection(x.shape, source, x.attr) AS proj,
               CASE WHEN (x.shape).level IS NOT NULL OR (x.shape).parent IS NULL THEN NULL ELSE (x.shape).key END AS key_expr FROM c)
  SELECT list_filter(['BEGIN TRANSACTION',
    tree_sql_frozen_guard(x.order_source, 'tree_replace'),
    tree_compile_order_check((x.shape)."order", (x.shape).root, source, sch || '.' || nm),
    -- The NEW source alone, as for insert, and here the union would be actively wrong: replace
    -- rewrites whole partitions, so the rows it is about to delete are STILL PRESENT in x.tbl
    -- while this runs, and every key in an unchanged tree would read as appearing twice.
    tree_compile_key_check(key_expr, (x.shape).root, source, sch || '.' || nm),
    'CREATE TEMP TABLE __duckent_new AS ' || proj,
    tree_compile_reach_check(key_expr, (x.shape).root, source, '__duckent_new', sch || '.' || nm, x.attr),
    tree_sql_shadow_check('__duckent_new', 'tree_replace'),
    tree_compile_p13('__duckent_new', sch || '.' || nm, x.has_root, (x.shape).level),
    -- and the same conformance check insert runs, for the same reason: replace rewrites whole
    -- partitions from a source create never saw
    tree_compile_o_conformance(x.shape, '__duckent_new', sch || '.' || nm, tree_sql_o_order_col(x.shape, x.attr)),
    'CREATE TEMP TABLE __duckent_epochs AS SELECT root_key, epoch FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT DISTINCT _root::VARCHAR FROM __duckent_new)',
    'DELETE FROM ' || x.tbl || ' WHERE _root::VARCHAR IN (SELECT root_key FROM __duckent_epochs)',
    'DELETE FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT root_key FROM __duckent_epochs)',
    'INSERT INTO ' || x.tbl || ' BY NAME SELECT * FROM __duckent_new',
    'INSERT INTO tree_state.partitions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', n._root::VARCHAR, COALESCE(e.epoch, 0) + 1, count(*), true, now() FROM __duckent_new n LEFT JOIN __duckent_epochs e ON e.root_key = n._root::VARCHAR GROUP BY n._root, e.epoch',
    'DROP TABLE __duckent_new', 'DROP TABLE __duckent_epochs',
    'COMMIT'], lambda s: s IS NOT NULL) FROM p);

-- The predicate is evaluated over the ROOT columns only: a non-ROOT column is a binder error naming it (P21). MN17 mutates this to row surgery.
CREATE OR REPLACE MACRO tree_sql_delete_stmt(tbl, root_predicate) AS
  'DELETE FROM ' || tbl || ' WHERE _root IN (SELECT _root FROM (SELECT DISTINCT _root, _root.* FROM ' || tbl || ') WHERE ' || root_predicate || ')';

-- `CASE WHEN x IS NULL` is not dead code, and neither is its twin in tree_compile_check.
-- Every statement below is pure string concatenation over the identity, so when the identity is
-- NULL each one constant-folds to NULL *before* anything reads `x` -- and 1.5.5 then prunes the
-- column that holds tree_dml_context out of the plan, so the refusal inside it is never
-- evaluated at all. The verb returns a list of NULLs and the executor runs BEGIN, nothing,
-- COMMIT. tree_compile_insert and _replace escape this only by accident: they also call
-- tree_compile_projection(x.shape, ...), which forces the context. Reading `x` in a predicate
-- that cannot fold is what makes the refusal unconditional here.
--
-- What the arm SAYS, though, is a backstop and not the tested path. tree_dml_context refuses on
-- its own account -- tree not found, abstract, projection-mode -- and each of those messages
-- COALESCEs the identity, so it raises rather than returning NULL; that is the message 12_dml
-- pins, and it is the message a caller sees. `x IS NULL` therefore fires only if the context
-- macro ever returns NULL without raising, which nothing here can currently make it do. It says
-- "internal" because reaching it is a duckent bug, not a user error.
CREATE OR REPLACE MACRO tree_compile_delete(sch, nm, root_predicate) AS (
  WITH c AS (SELECT tree_dml_context('tree_delete', sch, nm) AS x)
  SELECT CASE WHEN x IS NULL THEN tree_err('tree_delete: internal: no DML context') ELSE
   ['BEGIN TRANSACTION',
    'CREATE TEMP TABLE __duckent_gone AS SELECT DISTINCT _root::VARCHAR AS root_key FROM (SELECT DISTINCT _root, _root.* FROM ' || x.tbl || ') WHERE ' || root_predicate,
    tree_sql_delete_stmt(x.tbl, root_predicate),
    'DELETE FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND root_key IN (SELECT root_key FROM __duckent_gone)',
    'DROP TABLE __duckent_gone',
    'COMMIT'] END FROM c);

-- Run the assertions and record them: P13, the ORDER assertion for a projection-mode tree, and
-- one per declared O slot. tree_check REPORTS and never refuses (M3 §3.4) -- that is the whole
-- difference between it and the ingest checks it shares its comparisons with -- so every
-- statement below writes a row and none of them calls tree_err.
--
-- It serves BOTH storage modes. A materialized tree is read through its table; a projection-mode
-- tree, which owns no table, is read through its projection macro (x.rel). That is also why the
-- ORDER assertion exists only for projection-mode trees: a materialized one had its ORDER checked
-- at the ingest that stored it, and its source may since have moved on, while a projection-mode
-- tree IS its source.
CREATE OR REPLACE MACRO tree_compile_check(sch, nm) AS (
  WITH c AS (SELECT tree_dml_context('tree_check', sch, nm) AS x),
  -- The comparison text, built ONCE and handed to every slot's assertion. It is the same
  -- fragment tree_compile_o_conformance raises on, so what tree_check RECORDS and what ingest
  -- REFUSES are one question asked twice rather than two questions that might disagree. NULL
  -- when the shape declares no O slot, which makes every statement built from it NULL.
  b AS (SELECT x, tree_sql_o_bad_cte(x.shape, x.rel, tree_sql_o_order_col(x.shape, x.attr)) AS cte FROM c)
  -- see tree_compile_delete on why the context is read in a predicate
  SELECT CASE WHEN x IS NULL THEN tree_err('tree_check: internal: no DML context') ELSE
   list_filter(list_concat(list_concat(['BEGIN TRANSACTION',
    -- The ORDER assertion is recorded, never raised (M3 §3.4), and only for a projection-mode
    -- tree: a materialized one had its ORDER checked at the ingest that stored it, and its source
    -- may since have moved on, while a projection-mode tree IS its source. It reads the same
    -- duplicate relation the ingest check raises on. REACHABLE as of M3 Task 7, which let a
    -- projection-mode tree past tree_dml_context's refusal for this one verb; 12_dml's
    -- scripts_pm record is what holds it reachable, and until that record existed this was dead
    -- scaffolding that no suite could run.
    CASE WHEN x.storage <> 'projection' OR (x.shape)."order" IS NULL THEN NULL ELSE
      'DELETE FROM tree_state.assertions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''assert_order''' END,
    CASE WHEN x.storage <> 'projection' OR (x.shape)."order" IS NULL THEN NULL ELSE
      'INSERT INTO tree_state.assertions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ''assert_order'', CASE WHEN count(*) FILTER (WHERE __o IS NULL OR __n > 1) = 0 THEN ''ok'' ELSE ''violated'' END, (SELECT max(epoch) FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || '), count(*) FILTER (WHERE __o IS NULL OR __n > 1) || '' violating rows'' FROM ' || tree_sql_order_dup_rel((x.shape)."order", (x.shape).root, x.source) END,
    'DELETE FROM tree_state.assertions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''assert_p13''',
    'INSERT INTO tree_state.assertions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ''assert_p13'', CASE WHEN count(*) = 0 THEN ''ok'' ELSE ''violated'' END, (SELECT max(epoch) FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || '), count(*) || '' violating rows'' FROM (SELECT _level, _level - lag(_level, 1, -1) OVER (PARTITION BY _root ORDER BY _pre) AS d, row_number() OVER (PARTITION BY _root ORDER BY _pre) AS rn FROM ' || x.rel || ') WHERE ' || tree_sql_p13_pred()],
    -- One pair of statements per DECLARED O slot. A shape declaring none contributes an empty
    -- list, so a tree with no O group records P13 (and ORDER) exactly as it always did.
    flatten(list_filter([
      CASE WHEN (x.shape).size IS NULL THEN NULL ELSE tree_sql_o_assert_stmts(x.db, sch, nm, 'SIZE', cte) END,
      CASE WHEN (x.shape).parent IS NULL OR (x.shape).level IS NULL THEN NULL ELSE tree_sql_o_assert_stmts(x.db, sch, nm, 'PARENT', cte) END,
      CASE WHEN (x.shape).children IS NULL THEN NULL ELSE tree_sql_o_assert_stmts(x.db, sch, nm, 'CHILDREN', cte) END,
      CASE WHEN (x.shape).next IS NULL THEN NULL ELSE tree_sql_o_assert_stmts(x.db, sch, nm, 'NEXT', cte) END
    ], lambda l: l IS NOT NULL))), ['COMMIT']), lambda s: s IS NOT NULL) END FROM b);
