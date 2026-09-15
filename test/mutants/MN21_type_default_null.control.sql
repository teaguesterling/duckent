-- test/mutants/MN21_type_default_null.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/02_projection.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- The S columns of the projection, one definition for both bases, so the two branches of
-- tree_compile_projection cannot drift apart. ATTR MAP is cast to the canonical map type
-- (an undeclared one is a typed NULL of that type, not VARCHAR) and ELEMENT is a per-row
-- predicate defaulting to true, NULL-definite like every other filter in the language.
-- MN21 mutates the TYPE default here.
CREATE OR REPLACE MACRO tree_sql_sem_cols(sem) AS
  COALESCE((sem).type, '''node''') || ' AS _type, ' || COALESCE((sem).id, 'NULL::VARCHAR') || ' AS _id, '
  || COALESCE((sem).classes, 'NULL::VARCHAR[]') || ' AS _classes, '
  || CASE WHEN (sem).attr_map IS NULL THEN 'NULL::MAP(VARCHAR, VARCHAR)' ELSE 'CAST(' || (sem).attr_map || ' AS MAP(VARCHAR, VARCHAR))' END || ' AS _attr_map, '
  || 'COALESCE(' || COALESCE((sem).element, 'true') || ', false) AS _element, '
  || tree_sql_pseudo_map(sem) || ' AS _pseudo';
