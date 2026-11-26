-- test/mutants/MN28_malformed_reads_pure.sql
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/00_types.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- The purity decision as a PURE EXPRESSION over pre-bound lookups. Taking the two lists as
-- parameters is what lets a lambda call it: DuckDB refuses a subquery inside a lambda (the same
-- refusal `tree_sql_predicate_insert` works around with generate_series), so the lookups are
-- bound by the caller, once, and this stays relational-free.
CREATE OR REPLACE MACRO tree_sql_purity_expr(expr, volatile_fns, macro_bodies) AS
  CASE
    -- the mutation: parse-ability is never asked, and a malformed body contains no
    -- resolvable function calls -- so 'no calls' reads exactly like purity and the
    -- body is recorded 'pure' instead of refused
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
