-- test/mutants/MN02_parent_same_level.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/02_projection.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- Derived parent for level basis: nearest prior row at level - 1 within the root (ASOF join). MN2 mutates this.
-- It reads __rn, the stage that carries _pre: M3 §2.1 makes _pre the rank of ORDER within ROOT,
-- computed one CTE after __r, so __r itself has no _pre to join on. tree_derive_parent (sql/05)
-- names its own stage __rn for the same reason -- this fragment is spliced there verbatim.
CREATE OR REPLACE MACRO tree_sql_parent_join() AS
  '__p AS (SELECT a.*, b._pre AS _parent FROM __rn a ASOF LEFT JOIN __rn b ON a._root = b._root AND b._level = a._level - 1 AND b._pre < a._pre), ';
