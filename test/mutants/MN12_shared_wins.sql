-- test/mutants/MN12_shared_wins.sql
-- The shared pseudo tier shadows the tree's own bindings instead of the other way round: every
-- catalog macro named sel_<name> is bound first and a local or prefix declaration of the same
-- name is dropped as a duplicate. A tree that declares `:leaf` -- by name or through a PREFIX
-- namespace claim -- then silently answers some other schema's sel_leaf.
--
-- Copied from sql/00_types.sql's tree_expand_pseudo with two edits, both in service of one
-- claim (spec S7: the shared tier is a fallback, not an override):
--   (1) the two dedup filters in `shared` -- NOT list_contains(... name) and NOT
--       list_contains(... macro) -- are removed, so a shared candidate is kept even when the
--       tree already binds that name or that macro;
--   (2) the concatenation is list_concat(shared.extra, lp.bound) instead of
--       list_concat(lp.bound, shared.extra), and the result is deduped keeping the FIRST
--       occurrence of each name -- which is now the shared one. The dedup is needed because
--       tree_sql_pseudo_map builds a MAP, and a MAP with a repeated key raises.
CREATE OR REPLACE MACRO tree_expand_pseudo(sem) AS (
WITH lp AS (
  SELECT list_concat(
    list_transform(list_filter(COALESCE((sem).pseudo, []), lambda p: (p).prefix IS NULL OR (p).name IS NOT NULL),
      lambda p: {name: (p).name, body: COALESCE((p).body, (p).macro || '(' || COALESCE((p).args, '') || ')'),
                 macro: (p).macro, args: (p).args, prefix: (p).prefix}),
    COALESCE((SELECT list({name: substr(f.function_name, length((x).px.prefix) + 1),
                           body: f.function_name || '(' || COALESCE((x).px.args, '') || ')',
                           macro: f.function_name, args: (x).px.args, prefix: (x).px.prefix} ORDER BY f.function_name)
              FROM (SELECT unnest(list_filter(COALESCE((sem).pseudo, []), lambda p: (p).prefix IS NOT NULL AND (p).name IS NULL)) AS px) x
              JOIN (SELECT DISTINCT function_name FROM duckdb_functions() WHERE function_type = 'macro') f
                ON starts_with(f.function_name, (x).px.prefix)), [])
  ) AS bound
),
shared AS (
  SELECT COALESCE((SELECT list({name: substr(f.function_name, length(tree_shared_pseudo_prefix()) + 1),
                                body: f.function_name || '(' || COALESCE((sem).pseudo_args, '') || ')',
                                macro: f.function_name, args: (sem).pseudo_args, prefix: tree_shared_pseudo_prefix()} ORDER BY f.function_name)
                    FROM (SELECT DISTINCT function_name FROM duckdb_functions() WHERE function_type = 'macro') f
                    WHERE (sem).pseudo_args IS NOT NULL AND starts_with(f.function_name, tree_shared_pseudo_prefix())
                      AND substr(f.function_name, length(tree_shared_pseudo_prefix()) + 1) <> ''
                      -- edit (1): the name and macro dedup filters are gone
                   ), []) AS extra
  FROM lp
),
-- edit (2): shared first, local/prefix second, first occurrence of a name wins
allb AS (SELECT list_concat(shared.extra, lp.bound) AS v FROM lp, shared),
ded AS (SELECT list_filter(v, lambda x, i:
                 list_position(list_transform(v, lambda y: (y).name), (x).name) = i) AS v FROM allb)
SELECT {type: (sem).type, id: (sem).id, classes: (sem).classes, attr: (sem).attr, attr_map: (sem).attr_map, element: (sem).element, pseudo_args: (sem).pseudo_args,
  pseudo: CASE WHEN (sem).pseudo IS NULL AND (sem).pseudo_args IS NULL THEN NULL ELSE ded.v END
}::TREE_SEMANTIC
FROM ded);
