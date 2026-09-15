-- test/mutants/MN14_cross_partition.sql
-- The containment fragments forget that a tree is partitioned by ROOT, so a descendant test
-- matches rows of another partition. One fragment per relation means there are now exactly two
-- definitions to mutate for every surface (combinators, groups and traversal alike).
CREATE OR REPLACE MACRO tree_sql_subtree(a, b) AS
  b || '._pre BETWEEN ' || a || '._pre + 1 AND ' || a || '._pre + ' || a || '._size';
CREATE OR REPLACE MACRO tree_sql_children(a, b) AS
  b || '._parent = ' || a || '._pre';
-- tree_sql_siblings carries the guard for every sibling and positional relation (after, before,
-- next, prev, first_child, last_child all build on it), so it needs mutating too: without it a
-- node's siblings include the identically-placed rows of every other partition.
CREATE OR REPLACE MACRO tree_sql_siblings(a, b) AS
  b || '._parent IS NOT DISTINCT FROM ' || a || '._parent AND ' || b || '._pre <> ' || a || '._pre';
-- The derived size ignores roots too, so the mutation is consistent on a size-less shape: without
-- this, a cross-partition _pre range would still be bounded by a correctly-partitioned _size.
-- (This was added to make the mutant bite in 12_dml on the multi-file scripts fixture; it never
-- did -- see the manifest -- but it keeps the mutant coherent, so it stays.)
CREATE OR REPLACE MACRO tree_sql_size_expr() AS
  'COALESCE((SELECT min(b._pre) FROM __p b WHERE b._pre > a._pre AND b._level <= a._level), max(a._pre) OVER () + 1) - a._pre - 1';
