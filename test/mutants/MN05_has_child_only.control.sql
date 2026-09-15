-- test/mutants/MN05_has_child_only.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/07_match.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- One step chain as FROM text. `steps` is STRUCT(node_id, alias, op, pred)[] in chain order and
-- `anchor` is the alias of the enclosing step when the chain is a group's, NULL when it is the
-- selector's own. Produces
--   <P> a1 JOIN <P> a2 ON <comb(a1, a2)> AND (<pred2>) ... WHERE <comb(anchor, a1) AND> <pred1>
-- The first step has nothing before it to join against, so its predicate becomes the WHERE. At
-- the top level that predicate is the whole WHERE and needs no parentheses; inside a group it is
-- ANDed with the relation to the anchor, so there it is parenthesized like every joined step's.
-- 1.5.5: list_transform's two-argument lambda indexes from 1, so steps[i - 1] is the previous step.
-- The empty-step refusal is the fragment's own guard, not the compiler's: a group with no inner
-- steps contributes no row to the fold's group pass, so nothing would call this for it. That case
-- is refused in chk. This branch is what stops a direct caller emitting a FROM with no relation.
CREATE OR REPLACE MACRO tree_sql_chain(p, steps, anchor, elem) AS
  CASE WHEN steps IS NULL OR len(steps) = 0 THEN tree_err('tree_match: empty group') ELSE
    list_aggregate(list_transform(steps, lambda s, i:
        CASE WHEN i = 1 THEN p || ' ' || (s).alias
             ELSE 'JOIN ' || p || ' ' || (s).alias || ' ON ' || tree_sql_comb((s).op, (steps[i - 1]).alias, (s).alias, p, elem)
                  || ' AND (' || (s).pred || ')' END), 'string_agg', ' ')
    || ' WHERE '
    -- COALESCE, although tree_steps already defaults a group's first inner step to desc: only the
    -- first step of the OUTER chain may carry a NULL op, and there anchor is NULL and no
    -- combinator is asked for. A hand-built IR that breaks that invariant would otherwise reach
    -- tree_sql_comb with a NULL op, whose refusal message concatenates to NULL and raises nothing.
    || CASE WHEN anchor IS NULL THEN (steps[1]).pred
            ELSE tree_sql_comb(COALESCE((steps[1]).op, 'desc'), anchor, (steps[1]).alias, p, elem) || ' AND (' || (steps[1]).pred || ')' END
  END;
