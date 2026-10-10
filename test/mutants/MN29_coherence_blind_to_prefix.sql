-- test/mutants/MN29_coherence_blind_to_prefix.sql
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/00_types.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- The validation ladder for the S group, shared by tree_compile_create and tree_compile_alter
-- so that altering a tree cannot bypass a check create enforces. `verb` prefixes the message.
-- Returns true when the semantic is acceptable; raises otherwise.
CREATE OR REPLACE MACRO tree_sql_check_semantic(sem, attr_text, verb) AS
  CASE
    WHEN regexp_matches(COALESCE(attr_text, ''), '(?i)\bAS\s+"?_')
      THEN tree_err(verb || ': ATTR alias collides with the canonical prefix: ' || regexp_extract(attr_text, '(?i)\bAS\s+("?_[A-Za-z0-9_]*)', 1))
    -- A NULL name, or a body with no macro to derive one from, would compile the predicate map
    -- and the predicates INSERT to NULL; both would then be dropped from the statement
    -- list instead of refusing. A macro-bound entry passes with a NULL body because the DDL
    -- compilers run tree_expand_predicate first, which fills the body in from macro(args);
    -- prefix entries are exempt entirely -- expansion is what gives them their names.
    WHEN len(list_filter(COALESCE((sem).predicate, []), lambda x: (x).prefix IS NULL AND ((x).name IS NULL OR ((x).body IS NULL AND (x).macro IS NULL)))) > 0
      THEN tree_err(verb || ': every PREDICATE needs a name and a body or macro')
    -- the mutation: only locally-named entries are compared, so a collision that exists
    -- ONLY after expansion is invisible here. The duplicate is still refused -- by
    -- DuckDB's own `Map keys must be unique.` when the predicate map is built -- so the
    -- kill has to be on the MESSAGE, not on whether it refuses.
    WHEN len(list_distinct(list_transform(list_filter(COALESCE((sem).predicate, []), lambda x: (x).prefix IS NULL), lambda x: (x).name))) <> len(list_filter(COALESCE((sem).predicate, []), lambda x: (x).prefix IS NULL))
      THEN tree_err(verb || ': S-coherence: PREDICATE '
                    || COALESCE(tree_sql_dup_predicate(sem), '<unnamed>') || ' is bound twice')
    ELSE true END;
