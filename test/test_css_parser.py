#!/usr/bin/env python3
"""Unit checks for test/css_parser.py: the IR rows themselves, which the sqllogictest suite
only sees through match results and printed TREEQL. Standard library only; run it with

    python3 test/test_css_parser.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import css_parser


def row(node_id, parent_id, kind, value=None, op=None, arg=None, alias=None):
    return {"node_id": node_id, "parent_id": parent_id, "kind": kind,
            "value": value, "op": op, "arg": arg, "alias": alias}


def ops(rows):
    return [r["op"] for r in rows if r["kind"] == "step"]


class TestRows(unittest.TestCase):
    def test_nested_groups_are_the_exact_ir(self):
        # the group node sits under its step, its inner chain under the group, and the inner
        # chain's first step always carries a combinator -- 'desc' when none was written
        self.assertEqual(css_parser.parse(".fn:not(:has(string))"), [
            row(0, None, "selector"),
            row(1, 0, "step"),
            row(2, 1, "class", "fn"),
            row(3, 1, "not"),
            row(4, 3, "step", op="desc"),
            row(5, 4, "has"),
            row(6, 5, "step", op="desc"),
            row(7, 6, "type", "string"),
        ])

    def test_chain_numbering_is_dense_and_in_document_order(self):
        self.assertEqual(css_parser.parse("a > b c"), [
            row(0, None, "selector"),
            row(1, 0, "step"),
            row(2, 1, "type", "a"),
            row(3, 0, "step", op="child"),
            row(4, 3, "type", "b"),
            row(5, 0, "step", op="desc"),
            row(6, 5, "type", "c"),
        ])

    def test_compound_parts(self):
        rows = css_parser.parse('"select"#main.fn[name^="sh"]:first-child@s')
        self.assertEqual([(r["kind"], r["value"], r["op"], r["arg"]) for r in rows[2:]], [
            ("type", "select", None, None),
            ("id", "main", None, None),
            ("class", "fn", None, None),
            ("attr", "name", "LIKE", "'sh%'"),
            ("pseudo", "first-child", None, None)])
        self.assertEqual(rows[1]["alias"], "s")

    def test_attribute_values(self):
        def attr(text):
            r = [x for x in css_parser.parse(text) if x["kind"] == "attr"][0]
            return (r["value"], r["op"], r["arg"])
        self.assertEqual(attr('[name="main"]'), ("name", "=", "'main'"))
        self.assertEqual(attr("[kind=block]"), ("kind", "=", "'block'"))
        self.assertEqual(attr("[n=100]"), ("n", "=", "100"))          # unquoted: a number
        self.assertEqual(attr('[name^="sh"]'), ("name", "LIKE", "'sh%'"))
        self.assertEqual(attr('[name$="sh"]'), ("name", "LIKE", "'%sh'"))
        self.assertEqual(attr('[name*="sh"]'), ("name", "LIKE", "'%sh%'"))
        self.assertEqual(attr("""[name="it's"]"""), ("name", "=", "'it''s'"))  # doubled

    def test_to_sql_is_a_selector_literal(self):
        sql = css_parser.to_sql(css_parser.parse(".fn"))
        self.assertTrue(sql.endswith("]::TREE_SELECTOR"))
        self.assertIn("{node_id: 0, parent_id: NULL, kind: 'selector', value: NULL", sql)


class TestRefusals(unittest.TestCase):
    def refusal(self, text):
        with self.assertRaises(css_parser.CssError) as cm:
            css_parser.parse(text)
        self.assertTrue(str(cm.exception).startswith("css: "), str(cm.exception))
        return str(cm.exception)

    def test_where_has_no_host_escape(self):
        self.assertIn("css has no host escape: mint a PSEUDO, or MATCH USING TREEQL",
                      self.refusal(".fn[WHERE x > 2]"))

    def test_unclosed(self):
        self.assertIn("unclosed", self.refusal('.fn[name="main"'))
        self.assertIn("unclosed", self.refusal(".fn:has(block"))

    def test_unexpected(self):
        self.assertIn("unexpected", self.refusal(".fn >> .call"))
        self.assertIn("unexpected", self.refusal(".fn#main extra junk!!"))
        self.assertIn("unexpected", self.refusal(""))

    def test_capture_inside_a_group(self):
        self.assertIn("capture inside", self.refusal(".fn:has(block@b)"))


class TestMutant(unittest.TestCase):
    """MN8 lives behind DUCKENT_MUTANT=MN08, so the mutant harness can plant it without
    editing the parser. It regroups `a > b c`, which is what the corpus differential sees."""

    def setUp(self):
        self.saved = os.environ.get("DUCKENT_MUTANT")

    def tearDown(self):
        if self.saved is None: os.environ.pop("DUCKENT_MUTANT", None)
        else: os.environ["DUCKENT_MUTANT"] = self.saved

    def test_mn08_flips_the_grouping(self):
        os.environ.pop("DUCKENT_MUTANT", None)
        self.assertEqual(ops(css_parser.parse("a > b c")), [None, "child", "desc"])
        os.environ["DUCKENT_MUTANT"] = "MN08"
        self.assertEqual(ops(css_parser.parse("a > b c")), [None, "desc", "desc"])
        os.environ["DUCKENT_MUTANT"] = "MN07"
        self.assertEqual(ops(css_parser.parse("a > b c")), [None, "child", "desc"])


if __name__ == "__main__":
    unittest.main()
