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
-- (A fourth override, a root-blind copy of the old derived-size fragment macro, stood here until
-- M3 Task 6 replaced that derivation with a level-expanded ASOF join. It never bit -- see the
-- manifest -- and was kept only for coherence, so it was dropped rather than re-expressed against
-- the new stages. The three mutations above are the live ones.)
