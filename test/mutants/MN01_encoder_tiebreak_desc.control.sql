-- test/mutants/MN01_encoder_tiebreak_desc.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/02_projection.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- Encoder tiebreak after the sibling key: source order of the key. MN1 mutates this to DESC.
CREATE OR REPLACE MACRO tree_sql_encoder_tiebreak() AS 'ASC';
