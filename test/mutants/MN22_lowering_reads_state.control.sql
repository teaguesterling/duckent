-- test/mutants/MN22_lowering_reads_state.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/09_css.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- The document-order path of one row, and of its parent. `lvl` is the row's group depth, `pos`
-- its 1-based place in its chain and `a` which of the step's parts it is: 0 the step's own row,
-- 1..n its parts in emitted order. Unlike tree_steps, which can give a clause its fixed slot
-- number because no tree_steps literal can carry two clauses of one kind, css can (`.b.a`), so
-- `a` is the part's RANK after the slot sort rather than the slot itself. Only the order matters
-- -- the numbers never leave this file.
CREATE OR REPLACE MACRO tree_css_path(lvl, i0, a0, i1, a1, pos, a) AS
  CASE lvl WHEN 0 THEN {i0: pos::INTEGER, a0: a::INTEGER, i1: 0, a1: 0, i2: 0, a2: 0}
           WHEN 1 THEN {i0: i0::INTEGER, a0: a0::INTEGER, i1: pos::INTEGER, a1: a::INTEGER, i2: 0, a2: 0}
           ELSE        {i0: i0::INTEGER, a0: a0::INTEGER, i1: i1::INTEGER, a1: a1::INTEGER, i2: pos::INTEGER, a2: a::INTEGER} END;
