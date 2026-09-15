-- test/mutants/MN22_lowering_reads_state.sql
-- The css lowering consults ENGINE STATE: it reads tree_state.partitions and refuses to lower
-- any selector while some partition is not P13-clean. A language front-end turns TEXT into IR;
-- what it produces may depend on the text and on nothing else. A lowering that reads state makes
-- the same selector mean one thing and then refuse to mean anything, for a reason that is not in
-- the selector -- and the state it reads here belongs to a DIFFERENT tree than the one the
-- selector will be matched against, which no amount of squinting makes relevant.
--
-- One fragment of the lowering is overridden, not the whole of it: tree_css_path (sql/09_css.sql)
-- is the fragment stage 9 calls for every emitted row, so the state read happens exactly where
-- the lowering decides where a row goes. The original body is the ELSE arm, unchanged.
--
-- The bait is in test/sql/44_parsers.test: one setup statement inserts a partition row with
-- p13_ok = false for a tree name that does not exist, so nothing else in the file reads it.
-- Killed by 44_parsers, which is the suite that runs the SQL front-end (tree_parse_css) over
-- both corpora. 40_corpus cannot see this mutant: its `language := 'css'` selectors are parsed
-- by the RUNNER's parser (test/css_parser.py, which stands in for the extension's parse-time
-- hook), so no record there reaches tree_css_lower at all.
CREATE OR REPLACE MACRO tree_css_path(lvl, i0, a0, i1, a1, pos, a) AS
  CASE WHEN (SELECT count(*) FROM tree_state.partitions WHERE p13_ok = false) > 0
         THEN tree_css_err('css: cannot lower a selector while a partition is not P13-clean')
       ELSE CASE lvl WHEN 0 THEN {i0: pos::INTEGER, a0: a::INTEGER, i1: 0, a1: 0, i2: 0, a2: 0}
                     WHEN 1 THEN {i0: i0::INTEGER, a0: a0::INTEGER, i1: pos::INTEGER, a1: a::INTEGER, i2: 0, a2: 0}
                     ELSE        {i0: i0::INTEGER, a0: a0::INTEGER, i1: i1::INTEGER, a1: a1::INTEGER, i2: pos::INTEGER, a2: a::INTEGER} END END;
