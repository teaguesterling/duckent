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
CREATE OR REPLACE MACRO tree_compile_key_check(key_expr, root_csv, source_sql, label) AS
  CASE WHEN key_expr IS NULL THEN NULL ELSE
    'SELECT CASE WHEN max(__n) > 1 THEN tree_err(''KEY '' || COALESCE(arg_max(__v::VARCHAR, __n), ''<NULL>'') || '' appears '' || max(__n) || '' times'
    || CASE WHEN root_csv IS NULL THEN ' in tree ' || replace(label, '''', '''''') || ''')'
            ELSE ' in root '' || COALESCE(arg_max(__k, __n), ''<NULL>'') || '' of tree ' || replace(label, '''', '''''') || ''')' END
    || ' END FROM (SELECT __k, __v, count(*) AS __n FROM (SELECT ' || tree_sql_root(root_csv, '') || '::VARCHAR AS __k, ' || key_expr || ' AS __v FROM ' || source_sql || ') GROUP BY __k, __v)'
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
              WHEN max(storage) <> 'materialized' THEN tree_err(verb || ': tree ' || sch || '.' || nm || ' is projection-mode; '
                                                             || CASE WHEN verb = 'tree_check' THEN 'assertions need' ELSE 'DML needs' END || ' storage := materialized')
              ELSE {db: current_database(), shape: tree_shape_from_catalog(current_database(), sch, nm),
                    order_source: max(order_source),
                    -- storage and source are read by tree_compile_check alone, which is the one
                    -- verb M3 §3.4 lets a projection-mode tree reach (Task 7 lifts the refusal
                    -- above for it); every other verb here has already refused that storage mode.
                    storage: max(storage), source: max(source_sql),
                    attr: (SELECT expression FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND slot = 'ATTR'),
                    has_root: bool_or(EXISTS (SELECT 1 FROM tree_catalog.slots s WHERE s.database_name = current_database() AND s.schema_name = sch AND s.tree_name = nm AND slot = 'ROOT')),
                    tbl: 'tree_catalog.' || tree_sql_object_name('t', sch, nm)} END
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

-- Run the assertions and record them. P13 only for now; O assertions arrive in M3.
CREATE OR REPLACE MACRO tree_compile_check(sch, nm) AS (
  WITH c AS (SELECT tree_dml_context('tree_check', sch, nm) AS x)
  -- see tree_compile_delete on why the context is read in a predicate
  SELECT CASE WHEN x IS NULL THEN tree_err('tree_check: internal: no DML context') ELSE
   list_filter(['BEGIN TRANSACTION',
    -- The ORDER assertion is recorded, never raised (M3 §3.4), and only for a projection-mode
    -- tree: a materialized one had its ORDER checked at the ingest that stored it, and its source
    -- may since have moved on, while a projection-mode tree IS its source. It reads the same
    -- duplicate relation the ingest check raises on. Unreachable until Task 7 lets a
    -- projection-mode tree past tree_dml_context's refusal, which is the only thing standing
    -- between this statement and the caller.
    CASE WHEN x.storage <> 'projection' OR (x.shape)."order" IS NULL THEN NULL ELSE
      'DELETE FROM tree_state.assertions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''assert_order''' END,
    CASE WHEN x.storage <> 'projection' OR (x.shape)."order" IS NULL THEN NULL ELSE
      'INSERT INTO tree_state.assertions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ''assert_order'', CASE WHEN count(*) FILTER (WHERE __o IS NULL OR __n > 1) = 0 THEN ''ok'' ELSE ''violated'' END, (SELECT max(epoch) FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || '), count(*) FILTER (WHERE __o IS NULL OR __n > 1) || '' violating rows'' FROM ' || tree_sql_order_dup_rel((x.shape)."order", (x.shape).root, x.source) END,
    'DELETE FROM tree_state.assertions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || ' AND artifact = ''assert_p13''',
    'INSERT INTO tree_state.assertions SELECT ' || tree_sql_lit(x.db) || ', ' || tree_sql_lit(sch) || ', ' || tree_sql_lit(nm) || ', ''assert_p13'', CASE WHEN count(*) = 0 THEN ''ok'' ELSE ''violated'' END, (SELECT max(epoch) FROM tree_state.partitions WHERE database_name = ' || tree_sql_lit(x.db) || ' AND schema_name = ' || tree_sql_lit(sch) || ' AND tree_name = ' || tree_sql_lit(nm) || '), count(*) || '' violating rows'' FROM (SELECT _level, _level - lag(_level, 1, -1) OVER (PARTITION BY _root ORDER BY _pre) AS d, row_number() OVER (PARTITION BY _root ORDER BY _pre) AS rn FROM ' || x.tbl || ') WHERE ' || tree_sql_p13_pred(),
    'COMMIT'], lambda s: s IS NOT NULL) END FROM c);
