-- test/mutants/MN14_cross_partition.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/07_match.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- One fragment per relation, each the single definition shared by combinators, groups and traversal.
-- a and b are step aliases; p is the projection relation text (needed where a third row is scanned);
-- elem says whether the tree declares ELEMENT, in which case the sibling and positional relations
-- must scan for the nearest *element* neighbour instead of using the O(1) pre/size arithmetic.
-- Every fragment is a pure expression with no SELECT of its own: sql/08_traversal.sql splices the
-- text into query(), which in DuckDB 1.5.5 only accepts text from macros whose body has no
-- SELECT or subquery.
CREATE OR REPLACE MACRO tree_sql_subtree(a, b) AS
  b || '._root = ' || a || '._root AND ' || b || '._pre BETWEEN ' || a || '._pre + 1 AND ' || a || '._pre + ' || a || '._size';

CREATE OR REPLACE MACRO tree_sql_children(a, b) AS
  b || '._root = ' || a || '._root AND ' || b || '._parent = ' || a || '._pre';

-- IS NOT DISTINCT FROM, not =: the level-0 rows of a partition all have a NULL parent
-- and are siblings of each other, which = would silently deny.
CREATE OR REPLACE MACRO tree_sql_siblings(a, b) AS
  b || '._root = ' || a || '._root AND ' || b || '._parent IS NOT DISTINCT FROM ' || a || '._parent AND ' || b || '._pre <> ' || a || '._pre';
