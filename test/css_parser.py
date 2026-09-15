#!/usr/bin/env python3
"""A recursive-descent parser for duckent's v0 css selector grammar, producing TREE_SELECTOR rows.

Stands in for the parser the C++ extension will own; it must agree with tree_css_lower
(sql/09_css.sql) on every corpus row, so the IR it builds is exactly the IR tree_steps builds
for the equivalent selector literal -- same kinds, same parent links, same dense depth-first
numbering.

Grammar (v0, and no more than v0 -- no `,` selector lists, no `*`, no `:nth-child`):

    complex   := compound (combinator compound)*
    combinator:= ws | '>' | '+' | '~'                  -> desc | child | next | after
    compound  := [type] simple* ['@' name]
    type      := ident | '"' ident '"'                 (the quotes let a keyword be a type)
    simple    := '.' ident | '#' ident | attribute | pseudo
    attribute := '[' ident op value ']'
    op        := '=' | '^=' | '$=' | '*='              -> '=' | LIKE 'v%' | LIKE '%v' | LIKE '%v%'
    value     := '"' text '"' | "'" text "'" | ident | number
    pseudo    := ':' ident | ':has(' [combinator] complex ')' | ':not(' complex ')'
                 | ':' ident '(' arg ')'               (the argument is kept for M-LANG)

`:has` and `:not` become `has`/`not` group nodes whose inner chain hangs beneath them. A group's
first inner step always carries a combinator ('desc' unless the relative selector opens with one),
which is the invariant the match compiler's chain rule reads. The IR has no self-relation, so a
group's chain always relates to the step it hangs off by a combinator: `:has(x)` is the descendant
test css already means, but `:not(x)` becomes "no DESCENDANT matches x" rather than css's "this row
does not match x". tree_css_lower has to make the same choice, or the two front-ends disagree.
A capture inside a group is refused
for the reason tree_steps refuses one: a step inside HAS/NOT is a test, not a row of the result.

Numbering note (deliberate, and the one place this parser's row ORDER differs from tree_steps'):
the rows come out in the order they are WRITTEN, because that is the order a recursive-descent
parser meets them, while tree_steps numbers a step's parts by fixed slot -- type, id, class, attr,
pseudo, where, then its groups. So `.fn#greet` numbers class before id where tree_steps numbers id
before class, and a group is emitted where it is written, so the clauses of `.fn:has(x).other`
that follow it are numbered after that group's whole inner chain. Everything else is identical:
the same rows, the same kinds, the same parent links, the same dense depth-first numbering down
the tree. Ordering inside one step is therefore the one thing a differential against tree_steps
cannot assume: it compares match results, and printed TREEQL for compounds whose parts happen to
be written in slot order. Against tree_css_lower (which meets a compound's parts in the same
written order) the row lists compare directly.

Every failure is a CssError whose message starts with 'css: '.

DUCKENT_MUTANT=MN08 plants mutant MN8 here: a child combinator is recorded as a descendant, so
`a > b c` is grouped the way `a b c` is. The hook lives in the parser because the mutant is a
parser mutant; nothing else reads the environment.
"""
import collections
import os
import re

__all__ = ["CssError", "parse", "to_sql"]


class CssError(Exception):
    """A selector the v0 css grammar does not accept."""


Token = collections.namedtuple("Token", "kind text pos")

IDENT = r"[A-Za-z_][A-Za-z0-9_-]*"
_SCAN = re.compile(r"""(?P<ws>\s+)
                     | (?P<punct>\^=|\$=|\*=|[>+~.\#\[\]():@=])
                     | (?P<ident>""" + IDENT + r""")
                     | (?P<num>-?\d+(?:\.\d+)?)
                     | (?P<str>"[^"]*"|'[^']*')
                     | (?P<junk>.)""", re.X | re.S)
COMBINATOR = {">": "child", "+": "next", "~": "after"}


def tokenize(text):
    """Split the selector text into (kind, text, position) tokens. An unterminated quote is left
    as junk tokens, which the caller reports as unexpected input rather than as a silent value."""
    return [Token(m.lastgroup, m.group(0), m.start()) for m in _SCAN.finditer(text)]


def sql_str(s):
    """One SQL text literal, single quotes doubled."""
    return "'" + str(s).replace("'", "''") + "'"


class Parser:
    """One selector text; one method per grammar production."""

    def __init__(self, text):
        self.text = text
        self.toks = tokenize(text)
        self.i = 0
        self.rows = []
        self.mn08 = os.environ.get("DUCKENT_MUTANT") == "MN08"

    # --- token helpers ---------------------------------------------------
    def peek(self, kind=None):
        """The current token, or None at the end; with `kind`, None unless it is of that kind."""
        t = self.toks[self.i] if self.i < len(self.toks) else None
        return t if t is not None and (kind is None or t.kind == kind) else None

    def at(self, *punct):
        t = self.peek("punct")
        return t is not None and t.text in punct

    def take(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def skip_ws(self):
        """Consume whitespace; report whether any was there, since ws is the descendant combinator."""
        saw = False
        while self.peek("ws") is not None:
            self.i += 1
            saw = True
        return saw

    def error(self, msg):
        t = self.peek()
        pos = t.pos if t is not None else len(self.text)
        raise CssError("css: %s at position %d in %r" % (msg, pos, self.text))

    def unexpected(self):
        t = self.peek()
        self.error("unexpected " + (repr(t.text) if t is not None else "end of selector"))

    def node(self, parent_id, kind, value=None, op=None, arg=None, alias=None):
        row = {"node_id": len(self.rows), "parent_id": parent_id, "kind": kind,
               "value": value, "op": op, "arg": arg, "alias": alias}
        self.rows.append(row)
        return row

    # --- productions -----------------------------------------------------
    def ident(self, what="name"):
        t = self.peek("ident")
        if t is None:
            self.error("expected a %s" % what)
        return self.take().text

    def parse(self):
        root = self.node(None, "selector")
        self.skip_ws()
        self.complex(root["node_id"], first_op=None, in_group=False)
        self.skip_ws()
        if self.peek() is not None:
            self.unexpected()
        return self.rows

    def complex(self, parent_id, first_op, in_group):
        """A chain of compounds joined by combinators. `first_op` is the op of the chain's first
        step: NULL for the selector's own chain, 'desc' for a group's, unless the group's relative
        selector opens with a combinator of its own."""
        op = first_op
        if in_group and self.at(*COMBINATOR):
            op = COMBINATOR[self.take().text]
            self.skip_ws()
        while True:
            step = self.node(parent_id, "step", op=op)
            self.compound(step, in_group)
            saw_ws = self.skip_ws()
            if self.at(*COMBINATOR):
                t = self.take().text
                self.skip_ws()
                if self.at(*COMBINATOR):
                    self.unexpected()
                op = COMBINATOR[t]
                if self.mn08 and op == "child":
                    op = "desc"          # MN8: `a > b c` grouped as `a b c`
            elif saw_ws and self.peek() is not None and not self.at(")"):
                op = "desc"
            else:
                return

    def compound(self, step, in_group):
        """One compound: an optional type, then any number of simple selectors and groups, then
        an optional capture. An empty compound is a hole in the chain, so it is refused."""
        sid = step["node_id"]
        seen = False
        t = self.peek("ident") or self.peek("str")
        if t is not None:
            if t.kind == "str" and not re.fullmatch(IDENT, t.text[1:-1]):
                self.error("expected a type name in quotes, got " + repr(t.text))
            self.take()
            self.node(sid, "type", value=t.text[1:-1] if t.kind == "str" else t.text)
            seen = True
        while True:
            if self.at("."):
                self.take()
                self.node(sid, "class", value=self.ident("class name"))
            elif self.at("#"):
                self.take()
                self.node(sid, "id", value=self.ident("id"))
            elif self.at("["):
                self.attribute(sid)
            elif self.at(":"):
                self.pseudo(sid, in_group)
            elif self.at("@"):
                self.take()
                if in_group:
                    self.error("capture inside :has/:not has no row to bind")
                step["alias"] = self.ident("capture name")
            else:
                break
            seen = True
        if not seen:
            self.unexpected()

    def attribute(self, sid):
        """`[name op value]`, lowered to the ATTR clause's (name, SQL operator, SQL literal)."""
        self.take()
        self.skip_ws()
        name = self.ident("attribute name")
        # WHERE is TREEQL's host escape into raw SQL. css has no such escape, and letting one in
        # through an attribute name would make `[WHERE ...]` mean something very different from
        # what it looks like, so it is refused by name.
        if name.upper() == "WHERE":
            self.error("css has no host escape: mint a PSEUDO, or MATCH USING TREEQL")
        self.skip_ws()
        if not self.at("=", "^=", "$=", "*="):
            self.error("expected one of = ^= $= *= after attribute " + name)
        aop = self.take().text
        self.skip_ws()
        v = self.peek()
        if v is None or v.kind not in ("ident", "num", "str"):
            self.error("expected an attribute value")
        self.take()
        raw = v.text[1:-1] if v.kind == "str" else v.text
        if aop == "=" and v.kind == "num":
            # left unquoted, so an ATTR MAP lookup is cast to the number's type before comparing;
            # a quoted number ([n="100"]) is text and compares as text, as it does in TREEQL
            op, arg = "=", raw
        elif aop == "=":
            op, arg = "=", sql_str(raw)
        else:
            op = "LIKE"
            arg = sql_str({"^=": raw + "%", "$=": "%" + raw, "*=": "%" + raw + "%"}[aop])
        self.skip_ws()
        if not self.at("]"):
            self.error("unclosed [ in attribute selector")
        self.take()
        self.node(sid, "attr", value=name, op=op, arg=arg)

    def pseudo(self, sid, in_group):
        """`:name`, `:has(...)`, `:not(...)`, or `:name(argument)`. An unknown pseudo-class is
        kept as a clause: the match compiler is what decides it is unknown and counts it."""
        self.take()
        name = self.ident("pseudo-class name")
        if name in ("has", "not"):
            if not self.at("("):
                self.error("expected ( after :" + name)
            self.take()
            self.skip_ws()
            g = self.node(sid, name)
            self.complex(g["node_id"], first_op="desc", in_group=True)
            self.skip_ws()
            if not self.at(")"):
                self.error("unclosed :" + name + "(")
            self.take()
        elif self.at("("):
            self.take()
            depth, arg = 1, []
            while depth and self.peek() is not None:
                tok = self.take()
                if tok.kind == "punct" and tok.text == "(":
                    depth += 1
                elif tok.kind == "punct" and tok.text == ")":
                    depth -= 1
                if depth:
                    arg.append(" " if tok.kind == "ws" else tok.text)
            if depth:
                self.error("unclosed :" + name + "(")
            self.node(sid, "pseudo", value=name, arg="".join(arg).strip())
        else:
            self.node(sid, "pseudo", value=name)


def parse(text):
    """The selector text as IR rows; raises CssError."""
    if text is None:
        raise CssError("css: no selector text")
    return Parser(text).parse()


def to_sql(rows):
    """The IR rows as a TREE_SELECTOR literal, ready to splice into a tree_match call."""
    def lit(v):
        return "NULL" if v is None else sql_str(v)
    parts = ["{node_id: %d, parent_id: %s, kind: %s, value: %s, op: %s, arg: %s, alias: %s}" % (
        r["node_id"], "NULL" if r["parent_id"] is None else r["parent_id"],
        lit(r["kind"]), lit(r["value"]), lit(r["op"]), lit(r["arg"]), lit(r["alias"]))
        for r in rows]
    return "[" + ", ".join(parts) + "]::TREE_SELECTOR"
