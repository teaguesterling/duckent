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
    def test_not_negates_the_subject_row(self):
        # the general rule: one inner step, related to the subject by `self`, carrying the
        # compound's clauses -- so this asks whether the row itself has class 'method'
        self.assertEqual(css_parser.parse(".fn:not(.method)"), [
            row(0, None, "selector"),
            row(1, 0, "step"),
            row(2, 1, "class", "fn"),
            row(3, 1, "not"),
            row(4, 3, "step", op="self"),
            row(5, 4, "class", "method"),
        ])

    def test_not_has_collapses(self):
        # NOT ( SELF ( HAS ( R ) ) ) is NOT ( R anchored on the subject ): the same rows
        # tree_steps([{class: 'fn', "not": [{type: 'string'}]}]) builds, one group level
        self.assertEqual(css_parser.parse(".fn:not(:has(string))"), [
            row(0, None, "selector"),
            row(1, 0, "step"),
            row(2, 1, "class", "fn"),
            row(3, 1, "not"),
            row(4, 3, "step", op="desc"),
            row(5, 4, "type", "string"),
        ])

    def test_not_has_collapse_keeps_the_relative_combinator(self):
        self.assertEqual([r["op"] for r in css_parser.parse(".fn:not(:has(> block))") if r["kind"] == "step"],
                         [None, "child"])

    def test_has_is_still_a_descendant_test(self):
        self.assertEqual(css_parser.parse(".fn:has(string)"), [
            row(0, None, "selector"),
            row(1, 0, "step"),
            row(2, 1, "class", "fn"),
            row(3, 1, "has"),
            row(4, 3, "step", op="desc"),
            row(5, 4, "type", "string"),
        ])

    def test_nested_groups_are_the_exact_ir(self):
        # a group written inside a :not() compound: NOT ( SELF (CLASS 'fn', HAS ( ... )) ),
        # two group levels, which is the ceiling
        self.assertEqual(css_parser.parse(":not(.fn:has(string))"), [
            row(0, None, "selector"),
            row(1, 0, "step"),
            row(2, 1, "not"),
            row(3, 2, "step", op="self"),
            row(4, 3, "class", "fn"),
            row(5, 3, "has"),
            row(6, 5, "step", op="desc"),
            row(7, 6, "type", "string"),
        ])

    def test_clauses_are_emitted_in_slot_order(self):
        # tree_steps numbers a step's parts by slot (type, id, class, attr, pseudo), so the
        # parser does too and the two front-ends' row lists line up whatever the writing order
        self.assertEqual([(r["kind"], r["value"]) for r in css_parser.parse(".fn#greet")[2:]],
                         [("id", "greet"), ("class", "fn")])
        self.assertEqual([(r["kind"], r["value"]) for r in css_parser.parse("#greet.fn")[2:]],
                         [("id", "greet"), ("class", "fn")])
        # ... but two clauses of one kind, which no tree_steps literal can express, keep
        # the order they were written in
        self.assertEqual([r["value"] for r in css_parser.parse(".b.a") if r["kind"] == "class"],
                         ["b", "a"])

    def test_groups_come_after_every_clause_of_their_compound(self):
        self.assertEqual([r["kind"] for r in css_parser.parse("x:has(y).fn#i")],
                         ["selector", "step", "type", "id", "class", "has", "step", "type"])

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
            ("attr", "name", "LIKE", "'sh%' ESCAPE '\\'"),
            ("pseudo", "first-child", None, None)])
        self.assertEqual(rows[1]["alias"], "s")

    def test_attribute_values(self):
        def attr(text):
            r = [x for x in css_parser.parse(text) if x["kind"] == "attr"][0]
            return (r["value"], r["op"], r["arg"])
        self.assertEqual(attr('[name="main"]'), ("name", "=", "'main'"))
        self.assertEqual(attr("[kind=block]"), ("kind", "=", "'block'"))
        self.assertEqual(attr("[n=100]"), ("n", "=", "100"))          # unquoted: a number
        # the affix forms escape LIKE metacharacters in the value and carry the ESCAPE clause,
        # so `$="_t"` asks for a literal underscore rather than "any character then t"
        self.assertEqual(attr('[name^="sh"]'), ("name", "LIKE", "'sh%' ESCAPE '\\'"))
        self.assertEqual(attr('[name$="sh"]'), ("name", "LIKE", "'%sh' ESCAPE '\\'"))
        self.assertEqual(attr('[name*="sh"]'), ("name", "LIKE", "'%sh%' ESCAPE '\\'"))
        self.assertEqual(attr('[name$="_t"]'), ("name", "LIKE", "'%\\_t' ESCAPE '\\'"))
        self.assertEqual(attr('[name*="50%"]'), ("name", "LIKE", "'%50\\%%' ESCAPE '\\'"))
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

    def test_second_capture(self):
        self.assertIn("unexpected second capture", self.refusal(".fn@a@b"))

    def test_capture_must_be_an_identifier(self):
        # a capture becomes a SQL relation alias and an output column name; the css IDENT shape
        # allows `-`, which passed every producer and died in DuckDB's binder
        self.assertIn("alias my-cap is not an identifier", self.refusal(".fn@my-cap"))
        self.assertEqual([r for r in css_parser.parse(".fn@my_cap") if r["kind"] == "step"][0]["alias"],
                         "my_cap")

    def test_exponent_numbers_are_not_v0(self):
        # v0's number is -?\d+(\.\d+)? -- and `1e3` is where the two front-ends would otherwise
        # read the same text as two different selectors
        self.assertIn("exponent numbers are not supported in v0", self.refusal("a[n=1e3]"))
        self.assertIn("exponent numbers are not supported in v0", self.refusal("a[n=-1.5E-2]"))
        self.assertEqual([r for r in css_parser.parse("a[n=1.5]") if r["kind"] == "attr"][0]["arg"], "1.5")

    def test_unterminated_quoted_value(self):
        self.assertIn("unclosed", self.refusal('.fn[name="sh]'))
        self.assertIn("unclosed", self.refusal('"select'))

    def test_not_takes_a_compound(self):
        for text in (".fn:not(block string)", ".fn:not(> block)", ".fn:not(a > b)"):
            self.assertIn(":not() takes a compound selector in v0", self.refusal(text))

    def test_argument_taking_pseudos_other_than_has_and_not(self):
        self.assertIn(":nth-child() is not supported in v0", self.refusal(":nth-child(2)"))
        self.assertIn(":lang() is not supported in v0", self.refusal("x:lang(en)"))
        # an argument-less unknown pseudo is not a parse error: the match compiler counts it
        self.assertEqual([r["kind"] for r in css_parser.parse(".fn:nope")],
                         ["selector", "step", "class", "pseudo"])


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
