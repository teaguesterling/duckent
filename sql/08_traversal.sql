CREATE OR REPLACE MACRO tree_children(sch, nm, root_key, pre) AS TABLE
  SELECT * FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _parent = pre;

CREATE OR REPLACE MACRO tree_descendants(sch, nm, root_key, pre) AS TABLE
  WITH a AS (SELECT _pre, _size FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _pre = pre)
  SELECT p.* FROM tree_project(sch, nm) p, a WHERE p._root::VARCHAR = root_key AND p._pre BETWEEN a._pre + 1 AND a._pre + a._size;

-- Ancestors need no recursion at all: they are exactly the rows of the partition whose
-- (_pre, _size) range contains the node, which is what "a tree is its own traversal" means.
-- The recursive form also could not be used on a projection-mode level-basis tree -- it
-- inlines the projection macro, whose derived-parent ASOF join DuckDB 1.5.5 refuses inside
-- a recursive CTE ("AsOf joins are not supported in recursive CTEs yet"), and the process
-- then aborts on teardown.
CREATE OR REPLACE MACRO tree_ancestors(sch, nm, root_key, pre) AS TABLE
  SELECT a.* FROM tree_project(sch, nm) a,
    (SELECT _pre FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _pre = pre) n
  WHERE a._root::VARCHAR = root_key AND a._pre < n._pre AND n._pre <= a._pre + a._size;

CREATE OR REPLACE MACRO tree_next_sibling(sch, nm, root_key, pre) AS TABLE
  WITH a AS (SELECT _next, _parent FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _pre = pre)
  SELECT p.* FROM tree_project(sch, nm) p, a WHERE p._root::VARCHAR = root_key AND p._pre = a._next AND p._parent IS NOT DISTINCT FROM a._parent;

CREATE OR REPLACE MACRO tree_first_child(sch, nm, root_key, pre) AS TABLE
  SELECT * FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _parent = pre AND _pre = pre + 1;
