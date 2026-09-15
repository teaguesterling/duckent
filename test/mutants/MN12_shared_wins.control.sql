-- test/mutants/MN12_shared_wins.control.sql
-- THIS IS THE CONTROL: the same copy with NO planted edit, so applying it is a no-op
-- CREATE OR REPLACE of the macro the mutant copies. test/run_mutants.py --verify applies
-- it and requires the mutant's expect_fail suites to PASS, which is what makes the kill
-- evidence about the EDIT rather than about the copy having drifted from the source.
-- vvv GENERATED BELOW by test/mutants/regen.py from sql/00_types.sql -- do not edit by hand vvv
-- Regenerate with: python3 test/mutants/regen.py   (--check verifies, writes nothing)
-- Expand macro, map, prefix and shared bindings to expression bodies. Prefix entries bind every
-- catalog scalar macro whose name starts with the prefix; name = the remainder. A round-tripped
-- catalog entry (tree_shape_from_catalog, for a LIKE child) always carries a name, even when it
-- also carries a provenance-only prefix marker (see below), so the local/pass-through group is
-- "prefix IS NULL OR name IS NOT NULL" -- only a freshly declared, not-yet-expanded prefix entry
-- ({prefix, args}, no name) is routed to the scanning branch.
-- After that, the shared tier: every catalog scalar macro named sel_<rest> becomes a binding
-- {name: rest, body: 'sel_' || rest || '(pseudo_args)', macro, args: pseudo_args, prefix: 'sel_'},
-- unless <rest> is already bound (by name) or the macro itself already underlies a local/prefix
-- binding (by macro identity -- a prefix-bound macro like sel_ast_leaf also starts with the
-- literal "sel_" the shared tier scans for, and must not be double-bound under a second name).
-- The shared tier binds nothing when pseudo_args is NULL, tree-wide (§7 of the M2 design doc:
-- "the shared tier's args default to the tree's pseudo_args slot"; there is no args source for a
-- shared binding otherwise). Reads duckdb_functions(), so this is called by the DDL compilers
-- (runner-executed), never by tree_compile_projection.
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
                      -- a bare sel_ macro has an empty remainder: not an error, just not a
                      -- nameable pseudo-class, so it is left unbound rather than bound as ''
                      AND substr(f.function_name, length(tree_shared_pseudo_prefix()) + 1) <> ''
                      -- spec §7, amended: identity dedup. The spec's literal text excludes a
                      -- candidate only by name collision; that alone double-binds a macro
                      -- already claimed by a prefix declaration (e.g. sel_ast_leaf, which also
                      -- starts with the shared tier's own "sel_") under a second, derived name.
                      -- A prefix declaration is a namespace claim: a macro already bound under
                      -- any name -- locally or via a prefix -- is not re-bound by the shared
                      -- tier under another one.
                      AND NOT list_contains(list_transform(lp.bound, lambda y: (y).name), substr(f.function_name, length(tree_shared_pseudo_prefix()) + 1))
                      AND NOT list_contains(list_transform(lp.bound, lambda y: (y).macro), f.function_name)
                   ), []) AS extra
  FROM lp
)
SELECT {type: (sem).type, id: (sem).id, classes: (sem).classes, attr: (sem).attr, attr_map: (sem).attr_map, element: (sem).element, pseudo_args: (sem).pseudo_args,
  pseudo: CASE WHEN (sem).pseudo IS NULL AND (sem).pseudo_args IS NULL THEN NULL ELSE list_concat(lp.bound, shared.extra) END
}::TREE_SEMANTIC
FROM lp, shared);
