-- test/mutants/MN14_cross_partition.sql
CREATE OR REPLACE MACRO tree_sql_comb(op, a, b) AS
  CASE op
    WHEN 'desc'  THEN b || '._pre BETWEEN ' || a || '._pre + 1 AND ' || a || '._pre + ' || a || '._size'
    WHEN 'child' THEN b || '._parent = ' || a || '._pre'
    WHEN 'next'  THEN b || '._parent IS NOT DISTINCT FROM ' || a || '._parent AND ' || b || '._pre = ' || a || '._pre + ' || a || '._size + 1'
    WHEN 'after' THEN b || '._parent IS NOT DISTINCT FROM ' || a || '._parent AND ' || b || '._pre > ' || a || '._pre'
    ELSE error('tree_match: unknown combinator ' || op) END;
-- and the derived size must also ignore roots for the mutant to bite in 12_dml (multi-file scripts fixture)
CREATE OR REPLACE MACRO tree_sql_size_expr() AS
  'COALESCE((SELECT min(b._pre) FROM __p b WHERE b._pre > a._pre AND b._level <= a._level), max(a._pre) OVER () + 1) - a._pre - 1';
