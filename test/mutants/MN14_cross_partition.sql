-- test/mutants/MN14_cross_partition.sql
-- The containment fragments forget that a tree is partitioned by ROOT, so a descendant test
-- matches rows of another partition. One fragment per relation means there are now exactly two
-- definitions to mutate for every surface (combinators, groups and traversal alike).
CREATE OR REPLACE MACRO tree_sql_subtree(a, b) AS
  b || '._pre BETWEEN ' || a || '._pre + 1 AND ' || a || '._pre + ' || a || '._size';
CREATE OR REPLACE MACRO tree_sql_children(a, b) AS
  b || '._parent = ' || a || '._pre';
-- and the derived size must also ignore roots for the mutant to bite in 12_dml (multi-file scripts fixture)
CREATE OR REPLACE MACRO tree_sql_size_expr() AS
  'COALESCE((SELECT min(b._pre) FROM __p b WHERE b._pre > a._pre AND b._level <= a._level), max(a._pre) OVER () + 1) - a._pre - 1';
