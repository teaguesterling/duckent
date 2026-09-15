-- test/mutants/MN05_has_child_only.sql
-- A HAS/NOT group's first inner step is always joined to the step the group hangs off with
-- tree_sql_children, whatever op the IR gives it: `:has(x)` becomes "has a direct CHILD x"
-- instead of "has a descendant x". The classic css reading of :has() as a child test.
--
-- Copied from sql/07_match.sql's tree_sql_chain with one edit: the anchored branch of the
-- final CASE calls tree_sql_children(anchor, first alias) where the original calls
-- tree_sql_comb(COALESCE((steps[1]).op, 'desc'), anchor, ...). The outer chain (anchor IS NULL)
-- is untouched, so only groups are affected -- which is the point: a child-only :has() is
-- invisible to every selector whose group happens to test a direct child.
CREATE OR REPLACE MACRO tree_sql_chain(p, steps, anchor, elem) AS
  CASE WHEN steps IS NULL OR len(steps) = 0 THEN error('tree_match: empty group') ELSE
    list_aggregate(list_transform(steps, lambda s, i:
        CASE WHEN i = 1 THEN p || ' ' || (s).alias
             ELSE 'JOIN ' || p || ' ' || (s).alias || ' ON ' || tree_sql_comb((s).op, (steps[i - 1]).alias, (s).alias, p, elem)
                  || ' AND (' || (s).pred || ')' END), 'string_agg', ' ')
    || ' WHERE '
    || CASE WHEN anchor IS NULL THEN (steps[1]).pred
            ELSE tree_sql_children(anchor, (steps[1]).alias) || ' AND (' || (steps[1]).pred || ')' END
  END;
