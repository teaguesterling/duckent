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
    number    := -?\d+(\.\d+)?                         (no exponent: v0 refuses `1e3`)
    pseudo    := ':' ident | ':has(' [combinator] complex ')' | ':not(' compound ')'

The three affix operators escape LIKE's metacharacters in the value and emit `ESCAPE '\'`, so
`[name$="_t"]` asks for a literal underscore. A capture name must be a SQL identifier
(`[A-Za-z_][A-Za-z0-9_]*`), which is narrower than the css IDENT the rest of the grammar uses.

An argument-less pseudo-class is kept whatever its name: deciding it is unknown is the match
compiler's job, and it counts one. Any OTHER pseudo-class written with an argument -- `:nth-child(2)`
and friends -- refuses, because dropping the argument would silently change what the selector asks.

`:has` and `:not` become `has`/`not` group nodes whose inner chain hangs beneath them, and that
chain is anchored on the step the group hangs off by the op of its first inner step:

  - `:has(R)`  -> HAS, inner chain R, first op = R's leading combinator or 'desc'. This is the
                 descendant test css already means.
  - `:not(C)`  -> NOT, ONE inner step with op 'self' carrying C's clauses and groups. css `:not`
                 negates the SUBJECT row, so the chain has to start at the row itself; `self` is
                 the relation sql/07_match.sql adds for exactly this, legal only here.
  - `:not(:has(R))`, and nothing else in the compound, collapses to NOT ( R ), because "no
                 descendant matches R" is precisely "not a row that has a descendant matching R".
                 That keeps the spec's flagship at one group level and makes the rows identical to
                 tree_steps([{..., "not": [R]}]).
  - `:not(<chain with combinators>)` refuses: there is nothing for the chain to anchor on, and
                 guessing an anchor is how `:not` came to mean a descendant test in the first place.

A capture inside a group is refused for the reason tree_steps refuses one: a step inside HAS/NOT
is a test, not a row of the result. A capture named `s<N>` is refused for the reason tree_steps
refuses one: that is the alias the match compiler generates for step N.

Row order: the rows are the rows tree_steps builds for the equivalent literal, numbered the same
way -- a compound's clauses are emitted in tree_steps' slot order (type, id, class, attr, pseudo;
`where` has no css spelling) and its groups after all of them, in written order, whatever order
they were written in. The parser therefore reads a compound in two passes: it collects the parts,
then emits them. The one thing no tree_steps literal can express is two clauses of the same kind
(`.a.b`, a second attribute); those keep the order they were written in.

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
# An alias becomes a SQL relation alias and an output column name, so it must be an identifier --
# which the css IDENT shape above is not, because it allows `-`. See `compound`.
ALIAS = r"[A-Za-z_][A-Za-z0-9_]*"
# v0's number is `-?\d+(\.\d+)?` and no more. `expnum` is matched BEFORE `num` so that `1e3` is one
# token that can be refused, rather than the number 1 followed by the name e3 -- which is exactly
# how tree-sitter-css and this parser would otherwise disagree about the same text (it reads `1e3`
# as one float_value). Both front-ends refuse it in the same words.
_SCAN = re.compile(r"""(?P<ws>\s+)
                     | (?P<punct>\^=|\$=|\*=|[>+~.\#\[\]():@=])
                     | (?P<ident>""" + IDENT + r""")
                     | (?P<expnum>-?\d+(?:\.\d+)?[eE][-+]?\d+)
                     | (?P<num>-?\d+(?:\.\d+)?)
                     | (?P<str>"[^"]*"|'[^']*')
                     | (?P<openstr>["'].*)
                     | (?P<junk>.)""", re.X | re.S)
COMBINATOR = {">": "child", "+": "next", "~": "after"}
# the order tree_steps numbers a step's clauses in, which is the order they are emitted in
CLAUSE_SLOT = {"type": 1, "id": 2, "class": 3, "attr": 4, "pseudo": 5}


def tokenize(text):
    """Split the selector text into (kind, text, position) tokens. A quote with no partner takes
    the rest of the text as one `openstr` token, so it is reported as an unclosed quote rather
    than silently becoming a bare value and some punctuation."""
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
        if t is not None and t.kind == "openstr":
            self.error("unclosed quote at " + repr(t.text))
        self.error("unexpected " + (repr(t.text) if t is not None else "end of selector"))

    def skip_balanced(self, name):
        """Step over a parenthesized argument without parsing it, leaving the position it starts
        at. A compound emits its clauses before its groups, so a group is parsed on a second pass
        over the same tokens, once every clause of its compound has been placed."""
        depth = 0
        while self.peek() is not None:
            if self.at("("): depth += 1
            elif self.at(")"): depth -= 1
            self.take()
            if depth == 0: return
        self.error("unclosed :" + name + "(")

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
        an optional capture. An empty compound is a hole in the chain, so it is refused.

        Two passes over the same tokens: the first collects the compound's clauses and the token
        position of each group, the second emits the clauses in slot order and then parses the
        groups. That is what makes the rows tree_steps' rows rather than the order they happen to
        be written in."""
        sid = step["node_id"]
        clauses, groups, seen = [], [], False
        t = self.peek("ident") or self.peek("str")
        if t is not None:
            if t.kind == "str" and not re.fullmatch(IDENT, t.text[1:-1]):
                self.error("expected a type name in quotes, got " + repr(t.text))
            self.take()
            clauses.append(("type", t.text[1:-1] if t.kind == "str" else t.text, None, None))
            seen = True
        while True:
            if self.at("."):
                self.take()
                clauses.append(("class", self.ident("class name"), None, None))
            elif self.at("#"):
                self.take()
                clauses.append(("id", self.ident("id"), None, None))
            elif self.at("["):
                clauses.append(self.attribute())
            elif self.at(":"):
                self.take()
                name = self.ident("pseudo-class name")
                if name in ("has", "not"):
                    if not self.at("("):
                        self.error("expected ( after :" + name)
                    groups.append((name, self.i))
                    self.skip_balanced(name)
                elif self.at("("):
                    self.error(":" + name + "() is not supported in v0")
                else:
                    clauses.append(("pseudo", name, None, None))
            elif self.at("@"):
                self.take()
                if in_group:
                    self.error("capture inside :has/:not has no row to bind")
                if step["alias"] is not None:
                    self.error("unexpected second capture")
                at = self.i
                name = self.ident("capture name")
                # s<N> is the alias the match compiler generates for step N, and it drops any
                # capture whose alias equals its own generated one -- so `@s1` on step 1 would
                # silently lose its output column, and `@s3` on a shorter selector would name a
                # second relation s3 and die in the binder. tree_steps has refused the shape
                # since M1 1/2; both css front-ends and the compiler refuse it now too.
                if re.fullmatch(r"s[0-9]+", name):
                    self.i = at
                    self.error("alias %s is reserved for generated step aliases" % name)
                # An alias becomes a SQL relation alias and an output column name. A css capture
                # name takes the css IDENT shape, which allows `-`, so `@my-cap` passed every
                # producer -- this parser, the lowering, the printer -- and died in DuckDB's
                # binder on `... AS my-cap`, naming nothing the user wrote.
                if not re.fullmatch(ALIAS, name):
                    self.i = at
                    self.error("alias %s is not an identifier" % name)
                step["alias"] = name
            else:
                break
            seen = True
        if not seen:
            self.unexpected()
        end = self.i
        for kind, value, op, arg in sorted(clauses, key=lambda c: CLAUSE_SLOT[c[0]]):
            self.node(sid, kind, value=value, op=op, arg=arg)
        for name, pos in groups:
            self.i = pos
            self.group(sid, name)
        self.i = end

    def group(self, sid, name):
        """`:has(R)` or `:not(C)`, parsed from the '(' the first pass stepped over. The two
        differ in what the group's chain is anchored on, which is the whole point of `self`."""
        self.take()
        self.skip_ws()
        if name == "has":
            g = self.node(sid, "has")
            self.complex(g["node_id"], first_op="desc", in_group=True)
            self.skip_ws()
            if not self.at(")"):
                self.unexpected()
            self.take()
            return
        if self.at(*COMBINATOR):
            self.error(":not() takes a compound selector in v0")
        g = self.node(sid, "not")
        step = self.node(g["node_id"], "step", op="self")
        self.compound(step, in_group=True)
        self.skip_ws()
        if not self.at(")"):
            self.error(":not() takes a compound selector in v0")
        self.take()
        # the collapse: NOT ( SELF ( HAS ( R ) ) ) and NOT ( R ) accept the same rows
        kids = [r for r in self.rows if r["parent_id"] == step["node_id"]]
        if len(kids) == 1 and kids[0]["kind"] == "has":
            self.collapse_not_has(g, step, kids[0])

    def collapse_not_has(self, g, step, has):
        """Drop the `self` step and the HAS node, hanging the HAS group's chain on the NOT node.
        Every row of the compound the group belongs to is already placed and every ancestor row
        is numbered below the two that go, so only rows after them renumber -- which is why the
        ids the caller is still holding stay valid."""
        gid, drop = g["node_id"], {step["node_id"], has["node_id"]}
        kept = [r for r in self.rows if r["node_id"] not in drop]
        remap = {r["node_id"]: i for i, r in enumerate(kept)}
        for i, r in enumerate(kept):
            if r["parent_id"] in drop:
                r["parent_id"] = gid
            if r["parent_id"] is not None:
                r["parent_id"] = remap[r["parent_id"]]
            r["node_id"] = i
        self.rows = kept

    def attribute(self):
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
        if v is not None and v.kind == "openstr":
            self.error("unclosed quote in attribute value")
        if v is not None and v.kind == "expnum":
            self.error("exponent numbers are not supported in v0")
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
            # The affix operators say "starts with / ends with / contains THESE CHARACTERS", so
            # only the `%` added here is a wildcard: LIKE's own metacharacters in the value are
            # escaped and the pattern carries its ESCAPE clause. Unescaped, `[name$="_t"]` asked
            # for any character followed by `t`, and `[attr^="50%"]` meant rather more than it
            # said. Must stay identical to tree_sql_like_escape / tree_sql_like_arg (sql/00_types.sql).
            op = "LIKE"
            esc = raw.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            arg = sql_str({"^=": esc + "%", "$=": "%" + esc, "*=": "%" + esc + "%"}[aop]) + " ESCAPE '\\'"
        self.skip_ws()
        if not self.at("]"):
            self.error("unclosed [ in attribute selector")
        self.take()
        return ("attr", name, op, arg)


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
