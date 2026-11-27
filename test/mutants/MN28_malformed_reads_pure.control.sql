-- test/mutants/MN28_malformed_reads_pure.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/00_types.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- The purity decision as a PURE EXPRESSION over pre-bound lookups. Taking the two lists as
-- parameters is what lets a lambda call it: DuckDB refuses a subquery inside a lambda (the same
-- refusal `tree_sql_predicate_insert` works around with generate_series), so the lookups are
-- bound by the caller, once, and this stays relational-free.
CREATE OR REPLACE MACRO tree_sql_purity_expr(expr, volatile_fns, macro_bodies) AS
  CASE
    WHEN NOT tree_sql_expr_parses(expr) THEN 'malformed'
    WHEN len(list_intersect(tree_sql_expr_functions(expr), volatile_fns)) > 0 THEN 'impure'
    -- level 2: a macro reports stability NULL whatever it calls, so its own body is resolved one
    -- level deep. The old form did this with lvl2/lvl2c CTEs over duckdb_functions(); the map
    -- lookup answers the same question without a relation.
    WHEN len(list_intersect(tree_sql_expr_functions_lvl2(expr, macro_bodies), volatile_fns)) > 0
      THEN 'impure'
    -- a level-2 call that is ITSELF a macro is where resolution stops: recorded, never guessed
    WHEN len(list_filter(tree_sql_expr_functions_lvl2(expr, macro_bodies),
                         lambda g: map_contains(macro_bodies, g))) > 0 THEN 'unknown'
    ELSE 'pure' END;
