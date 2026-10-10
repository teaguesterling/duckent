-- test/mutants/MN27_shared_tier_unchecked.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/00_types.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- The second half of the S validation ladder, and the one that has to read the UNEXPANDED
-- semantic: a PREDICATE prefix entry names a NAMESPACE of catalog macros, and tree_expand_predicate
-- replaces it with one binding per macro carrying that prefix. When none does, expansion replaces
-- it with NOTHING -- so by the time tree_sql_check_semantic sees the group, a prefix that bound
-- no macro is indistinguishable from one that was never written. The tree was created with an
-- empty PREDICATE block and every `:name` its author meant to mint was an unknown pseudo-class
-- compiling to false, silently: `{prefix: 'sel_ats_'}` read as "this tree has no predicates"
-- rather than as a misspelling of `sel_ast_`.
--
-- Only a freshly declared entry ({prefix, args} with no name) is a prefix declaration; a
-- round-tripped catalog row (tree_shape_from_catalog, for a LIKE child) carries a provenance-only
-- prefix marker AND a name, and is not re-resolved. Reads duckdb_functions(), so this is called by
-- the DDL compilers (runner-executed), like tree_expand_predicate itself. Returns true or raises;
-- both compilers call it alongside tree_sql_check_semantic so the two verbs cannot drift.
CREATE OR REPLACE MACRO tree_sql_check_prefixes(sem, verb) AS (
  WITH px AS (SELECT unnest(list_filter(COALESCE((sem).predicate, []),
                                        lambda p: (p).prefix IS NOT NULL AND (p).name IS NULL)) AS p),
       m AS (SELECT DISTINCT function_name FROM duckdb_functions() WHERE function_type = 'macro'),
       bad AS (SELECT min((px.p).prefix) AS pre FROM px
               WHERE NOT EXISTS (SELECT 1 FROM m WHERE starts_with(m.function_name, (px.p).prefix))),
       -- The IMPLICIT shared tier needs the same check. PREDICATE_ARGS switches on every macro under
       -- tree_shared_predicate_prefix(), so it makes exactly the claim an explicit prefix entry makes
       -- -- that there are predicates to bind -- and it was the one spelling that bypassed
       -- this. Unchecked, it bound none while tree_semantic_declares still counted it as an S
       -- group, so has_semantic went true and tree_match's S-less refusal stopped firing: a TYPE
       -- clause compiled against TYPE's 'node' default and returned zero rows where a refusal was
       -- owed, which is the failure the comment on tree_semantic_declares names.
       --
       -- The emptiness rule is tree_expand_predicate's, not a new one: its `shared` arm requires a
       -- non-empty remainder, because a BARE prefix macro is "not an error, just not a nameable
       -- pseudo-class". So a tree whose only sel_ macro is the bare one binds nothing and must be
       -- refused too -- the check agrees with the expansion rather than approximating it.
       shared_bad AS (SELECT (sem).predicate_args IS NOT NULL
                        AND NOT EXISTS (SELECT 1 FROM m
                                        WHERE starts_with(m.function_name, tree_shared_predicate_prefix())
                                          AND substr(m.function_name,
                                                     length(tree_shared_predicate_prefix()) + 1) <> '') AS unbound)
  SELECT CASE WHEN (SELECT pre FROM bad) IS NOT NULL
              THEN tree_err(verb || ': PREDICATE prefix ' || (SELECT pre FROM bad) || ' binds no macro')
              WHEN (SELECT unbound FROM shared_bad)
              THEN tree_err(verb || ': PREDICATE_ARGS binds no macro: no '
                            || tree_shared_predicate_prefix() || '* macro is in scope')
              ELSE true END);
