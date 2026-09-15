-- sql/08_traversal.sql
-- Every traversal is SELECT b.* FROM P a, P b WHERE a is the anchor AND <fragment(a, b)>; the
-- fragment in sql/07_match.sql is the only definition of the relation, shared with the match
-- compiler. The relation text goes through query(), which in DuckDB 1.5.5 constant-folds its
-- argument and refuses text built by a macro whose body contains a SELECT or subquery -- hence
-- the projection relation is spelled out here rather than reached through the tree_project
-- table macro, and the anchor key and pre are spliced in as literals.
CREATE OR REPLACE MACRO tree_proj_sql(sch, nm) AS 'tree_catalog.' || tree_sql_object_name('proj', sch, nm) || '()';

-- Both anchors are forced through a cast before they reach the text, and both are COALESCEd to
-- the literal word NULL, because query() rejects a NULL argument outright ("Parser Error: syntax
-- error at or near NULL") and one NULL anywhere in a concatenation makes the WHOLE text NULL.
-- The literal NULL compiles to `= NULL`, which matches nothing -- the no-rows answer the M1
-- macros gave for an anchor that is not there, and the answer a caller asking about a partition
-- or a row that does not exist is owed.
--
-- root_key is quoted by tree_sql_lit, which is itself NULL for a NULL key: without the COALESCE
-- a NULL root key did not select nothing, it made query() refuse a NULL argument, in a parser
-- error from inside a macro the caller never wrote.
--
-- pre goes through DOUBLE. A bare '|| pre ||' would splice whatever the caller passed straight
-- into the WHERE clause, so tree_children(..., '6 OR true') would return the whole partition; the
-- cast makes a non-numeric anchor fail legibly instead. It was BIGINT, which ROUNDS: `5.7` became
-- 6 and the traversal answered about an anchor the caller never named, silently. DOUBLE keeps the
-- value the caller gave -- `'6'` still equals 6, `5.7` equals nothing, since a tree's _pre values
-- are integers -- and still refuses text that is not a number at all.
CREATE OR REPLACE MACRO tree_nav(sch, nm, root_key, pre, rel) AS TABLE
  FROM query('SELECT b.* FROM ' || tree_proj_sql(sch, nm) || ' a, ' || tree_proj_sql(sch, nm) || ' b WHERE a._root::VARCHAR = '
             || COALESCE(tree_sql_lit(root_key), 'NULL') || ' AND a._pre = ' || COALESCE(CAST(CAST(pre AS DOUBLE) AS VARCHAR), 'NULL') || ' AND ' || rel);

-- The element flag passed to the fragments is always true here. Deciding it properly needs a
-- catalog lookup, and a subquery in the body would make query() refuse the text; true is correct
-- either way, because _element is true on every row of a tree that declares no ELEMENT, so the
-- scanning form returns exactly what the O(1) form would. The match compiler keeps the O(1) form
-- via its own has_element flag, where the lookup happens in a CTE rather than in a macro body.
CREATE OR REPLACE MACRO tree_children(sch, nm, root_key, pre) AS TABLE
  FROM tree_nav(sch, nm, root_key, pre, tree_sql_children('a', 'b'));
CREATE OR REPLACE MACRO tree_descendants(sch, nm, root_key, pre) AS TABLE
  FROM tree_nav(sch, nm, root_key, pre, tree_sql_subtree('a', 'b'));
-- Ancestors need no recursion at all: they are exactly the rows of the partition whose
-- (_pre, _size) range contains the node, which is what "a tree is its own traversal" means.
-- The recursive form also could not be used on a projection-mode level-basis tree -- it
-- inlines the projection macro, whose derived-parent ASOF join DuckDB 1.5.5 refuses inside
-- a recursive CTE ("AsOf joins are not supported in recursive CTEs yet"), and the process
-- then aborts on teardown.
CREATE OR REPLACE MACRO tree_ancestors(sch, nm, root_key, pre) AS TABLE
  FROM tree_nav(sch, nm, root_key, pre, tree_sql_ancestors('a', 'b'));
CREATE OR REPLACE MACRO tree_parent(sch, nm, root_key, pre) AS TABLE
  FROM tree_nav(sch, nm, root_key, pre, tree_sql_parent('a', 'b'));
CREATE OR REPLACE MACRO tree_siblings(sch, nm, root_key, pre) AS TABLE
  FROM tree_nav(sch, nm, root_key, pre, tree_sql_siblings('a', 'b'));
CREATE OR REPLACE MACRO tree_next_sibling(sch, nm, root_key, pre) AS TABLE
  FROM tree_nav(sch, nm, root_key, pre, tree_sql_next_sibling('a', 'b', tree_proj_sql(sch, nm), true));
CREATE OR REPLACE MACRO tree_prev_sibling(sch, nm, root_key, pre) AS TABLE
  FROM tree_nav(sch, nm, root_key, pre, tree_sql_prev_sibling('a', 'b', tree_proj_sql(sch, nm), true));
-- The positional fragments constrain b alone; tree_sql_children anchors it under a.
CREATE OR REPLACE MACRO tree_first_child(sch, nm, root_key, pre) AS TABLE
  FROM tree_nav(sch, nm, root_key, pre, tree_sql_children('a', 'b') || ' AND ' || tree_sql_first_child('b', tree_proj_sql(sch, nm), true));
CREATE OR REPLACE MACRO tree_last_child(sch, nm, root_key, pre) AS TABLE
  FROM tree_nav(sch, nm, root_key, pre, tree_sql_children('a', 'b') || ' AND ' || tree_sql_last_child('b', tree_proj_sql(sch, nm), true));
