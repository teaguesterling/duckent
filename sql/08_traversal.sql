CREATE OR REPLACE MACRO tree_children(sch, nm, root_key, pre) AS TABLE
  SELECT * FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _parent = pre;

CREATE OR REPLACE MACRO tree_descendants(sch, nm, root_key, pre) AS TABLE
  WITH a AS (SELECT _pre, _size FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _pre = pre)
  SELECT p.* FROM tree_project(sch, nm) p, a WHERE p._root::VARCHAR = root_key AND p._pre BETWEEN a._pre + 1 AND a._pre + a._size;

-- Ancestors follow _parent upward. The C++ port replaces the recursion with a stack walk.
CREATE OR REPLACE MACRO tree_ancestors(sch, nm, root_key, pre) AS TABLE
  WITH RECURSIVE up USING KEY (_pre) AS (
    SELECT p.* FROM tree_project(sch, nm) p WHERE p._root::VARCHAR = root_key AND p._pre = (SELECT _parent FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _pre = pre)
    UNION ALL
    SELECT p.* FROM tree_project(sch, nm) p JOIN up ON p._root::VARCHAR = root_key AND p._pre = up._parent)
  SELECT * FROM up;

CREATE OR REPLACE MACRO tree_next_sibling(sch, nm, root_key, pre) AS TABLE
  WITH a AS (SELECT _next, _parent FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _pre = pre)
  SELECT p.* FROM tree_project(sch, nm) p, a WHERE p._root::VARCHAR = root_key AND p._pre = a._next AND p._parent IS NOT DISTINCT FROM a._parent;

CREATE OR REPLACE MACRO tree_first_child(sch, nm, root_key, pre) AS TABLE
  SELECT * FROM tree_project(sch, nm) WHERE _root::VARCHAR = root_key AND _parent = pre AND _pre = pre + 1;
