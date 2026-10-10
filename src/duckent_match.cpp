#include "duckent_sql.hpp"

#include "duckdb/common/error_data.hpp"
#include "duckdb/function/table_function.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/main/connection.hpp"
#include "duckdb/main/extension/extension_loader.hpp"
#include "duckdb/main/materialized_query_result.hpp"
#include "duckdb/parser/common_table_expression_info.hpp"
#include "duckdb/parser/expression/function_expression.hpp"
#include "duckdb/parser/expression/subquery_expression.hpp"
#include "duckdb/parser/keyword_helper.hpp"
#include "duckdb/parser/query_node.hpp"
#include "duckdb/parser/statement/select_statement.hpp"
#include "duckdb/parser/tableref/table_function_ref.hpp"

namespace duckdb {

// ---------------------------------------------------------------------------------------------
// WHY tree_match IS A TABLE MACRO OVER A TABLE FUNCTION, AND NOT A TABLE FUNCTION
//
// The obvious shape -- `tree_match` as a table function whose bind compiles the selector -- does
// not bind at all, and the reason is a hard rule in DuckDB rather than anything about duckent.
// Table-function ARGUMENTS are bound by TableFunctionBinder, which refuses any subquery outright
// (duckdb/src/planner/expression_binder/table_function_binder.cpp, ExpressionClass::SUBQUERY ->
// "Table function cannot contain subqueries"). A scalar MACRO whose body is a subquery expands
// into one while binding, so it is refused too:
//
//     CREATE MACRO m() AS (SELECT 3); FROM range(m());
//     -- Binder Error: Table function cannot contain subqueries
//
// This is settled upstream and is NOT waiting on a fix, so the shape below is permanent rather
// than a stopgap. duckdb/duckdb#10228 reports exactly this, was labelled `reproduced`, and was
// closed in January 2024 with a maintainer's verdict: "Macros only substitute their expression
// wherever they are used, as such, the error is expected and seems relatively reasonable." The
// subquery here is uncorrelated and constant-foldable, so folding it would make the obvious
// shape work -- but that argument has been made and declined. Verified against v1.5.5
// (d8cdaa33fd) with the two controls that isolate the variable: `FROM range(3)` and
// `CREATE MACRO n() AS 3; FROM range(n())` both work, so it is the subquery body alone that is
// refused.
//
// `tree_steps` is exactly such a macro -- its body is `(WITH lvl0 AS (...) SELECT ...)` -- and
// the corpus writes nearly every selector as `tree_steps([...])`. Hand-written IR
// (`[{node_id: 0, ...}]`) is a plain list literal and binds fine, which is why a bare table
// function passes the literal-IR tests and fails every tree_steps-shaped one. `tree_semantic`
// and `tree_spec` are subquery-free, which is why `semantic :=` can stay an ordinary argument
// and why the Task 5/6 verbs can take their structs positionally at all.
//
// The schema cannot be dodged either: the compiled query's columns are the tree's projection
// plus one struct column per capture alias in the selector, so they depend on the selector's
// VALUE and must be known at bind time. DuckDB gives a table function a bind-time value only by
// constant-folding the argument -- which is the path that refuses the subquery.
//
// Three facts, each checked against this DuckDB (d8cdaa33fda), open the only door:
//
//   1. A TABLE MACRO's body is bound by an ORDINARY binder (Binder::BindTableMacro), so the
//      macro's arguments -- tree_steps and all -- bind without complaint, and the argument
//      EXPRESSIONS are substituted into the body's parse tree.
//   2. An argument that is syntactically a subquery takes a different path in
//      Binder::BindTableFunctionParameters: given a LogicalType::TABLE parameter it is bound as
//      a relation by an ordinary binder instead of by TableFunctionBinder.
//   3. An UNREFERENCED CTE is never bound (`WITH u AS (SELECT no_such_function()) SELECT 1`
//      succeeds), while macro parameter substitution DOES descend into one
//      (ParsedExpressionIterator::EnumerateQueryNodeChildren walks node.cte_map).
//
// So `tree_match` is a table macro that hands the selector to `duckent_match` twice inside one
// subquery: once in the projection, where binding it yields its TYPE for the IR-or-text decision,
// and once in an unreferenced CTE, where it stays unbound and so can still be deparsed. Fact 3 is
// what the second copy is for: binding REPLACES a parsed expression with an emptied
// BoundExpression in place, so by the time bind runs, every bound copy raises
// "ToString(): BoundExpression does not have a child". Deparsing is not a trick played on the
// reference implementation but the same move it makes: test/run.py's `rewrite_match` also works
// from the selector's TEXT, splicing the call's argument text into
// `SELECT tree_compile_match({args})`. The runner can read that text before SQL sees the call;
// the unbound CTE copy is the earliest place here with the same information.
//
// The selector argument is therefore evaluated twice: once by the relation DuckDB plans for the
// TABLE parameter (whose rows this scan ignores -- only its type was wanted) and once inside the
// compile call. Building the IR is a constant-size fold over a literal written in the query, so
// it is not in any loop.
// ---------------------------------------------------------------------------------------------

namespace {

//! Position of the selector relation in `duckent_match`'s argument list.
constexpr idx_t MATCH_SELECTOR_ARG = 2;
//! Name of the CTE in the table macro below that keeps the selector expression unbound. Lower
//! case because the parser folds unquoted identifiers, and prefixed because it shares a namespace
//! with nothing but itself.
constexpr const char *MATCH_SELECTOR_CTE = "__duckent_selector";

struct MatchBindData : public TableFunctionData {
	string compiled_sql;
	vector<LogicalType> types;
	vector<string> names;
};

struct MatchGlobalState : public GlobalTableFunctionState {
	//! The connection is kept because it owns the ClientContext the result was produced on, and
	//! the result outlives the call that made it.
	unique_ptr<Connection> con;
	unique_ptr<MaterializedQueryResult> result;
	//! The output chunk is handed a REFERENCE to this one, so it has to stay alive until the next
	//! call replaces it rather than dying with the call that fetched it.
	unique_ptr<DataChunk> chunk;
	bool exhausted = false;

	//! Declared, not assumed. MatchInOut mutates this state -- it calls result->Fetch() and
	//! replaces `chunk` -- and there is no local state to mutate instead, so two threads in the
	//! operator would race on both. For tree_match the input relation is a one-row scalar
	//! subquery, so there is one chunk and one caller anyway; this override says so to DuckDB
	//! rather than relying on PhysicalTableInOutFunction happening not to parallelize.
	idx_t MaxThreads() const override {
		return 1;
	}
};

//! One scalar out of a one-column query, or NULL when it returned no rows. Used for the settings
//! read the text-selector path makes; a macro's own refusals never come through here.
Value ScalarOf(Connection &con, const string &sql) {
	auto result = con.Query(sql);
	if (result->HasError()) {
		result->GetErrorObject().Throw();
	}
	if (result->RowCount() == 0) {
		return Value();
	}
	return result->GetValue(0, 0);
}

//! The language a selector argument is written in: the `language :=` named argument when the call
//! carries one, else `tree_catalog.settings`' default.
//!
//! This is run.py's `selector_language` / `written_language` / `default_language` trio. The
//! runner has to recognise its literal SYNTACTICALLY (`string_literal`, because its lookup
//! happens before SQL sees the call) while here the named argument has already been
//! constant-folded to a Value, so "carries one" and "carries a readable one" collapse into the
//! single IsNull() test.
//!
//! Nothing is written back. run.py stopped appending `language := <default>` once the front-end
//! began stamping provenance on the IR's root row, and `_match_language` is
//! COALESCE(language, tree_selector_language(sel)): IR handed over directly stamps nothing and so
//! reads as treeql, whatever the default says. Passing the resolved default through to the
//! compile macro would therefore change the answer, and is not done -- this value feeds the
//! refusal below and nothing else.
string ResolveSelectorLanguage(Connection &con, TableFunctionBindInput &input) {
	auto named = input.named_parameters.find("language");
	if (named != input.named_parameters.end() && !named->second.IsNull()) {
		return named->second.ToString();
	}
	const Value fallback =
	    ScalarOf(con, "SELECT value FROM tree_catalog.settings WHERE name = 'tree_default_selector_language'");
	if (fallback.IsNull()) {
		throw InvalidInputException("duckent: tree_catalog.settings has no tree_default_selector_language row, so the "
		                            "language of a selector given as text cannot be determined");
	}
	return fallback.ToString();
}

//! Every registered selector language and whether it has a parser, as
//! `treeql (no parser), css (parser tree_css_lower)`. The refusal below quotes this because the
//! registry is the FRONT-END SEAM (sql/01_catalog.sql): what a build can parse is whatever has
//! registered itself, so the refusal reports the registry's contents rather than a list written
//! here, which would go stale the moment a front-end extension is loaded.
string RegisteredLanguages(Connection &con) {
	auto result = con.Query("SELECT language, parser FROM tree_catalog.selector_languages ORDER BY language");
	if (result->HasError()) {
		result->GetErrorObject().Throw();
	}
	string out;
	for (idx_t i = 0; i < result->RowCount(); i++) {
		const Value parser = result->GetValue(1, i);
		out += (out.empty() ? "" : ", ") + result->GetValue(0, i).ToString() +
		       (parser.IsNull() ? " (no parser)" : " (parser " + parser.ToString() + ")");
	}
	return out.empty() ? "none" : out;
}

//! A selector handed over as TEXT needs a front-end to parse it, and this build has none.
//!
//! run.py's counterpart is the second half of `rewrite_selectors`: resolve the language, then
//! `if lang != "css": raise(... pass tree_steps(...))`, else hand the text to css_parser. The
//! runner can take that else branch because its css front-end is a Python module it imports; a
//! core-only extension embeds no front-end at all (sql/09_css.sql is deliberately not embedded),
//! so BOTH branches refuse here and a registry lookup is what says so. That is what
//! sql/01_catalog.sql asks for in as many words: "a text selector is then refused by a lookup
//! that finds no parser instead of by a hardcoded branch".
void RefuseTextSelector(Connection &con, const string &language) {
	auto row = con.Query("SELECT parser FROM tree_catalog.selector_languages WHERE language = " +
	                     KeywordHelper::WriteQuoted(language, '\'') + " LIMIT 1");
	if (row->HasError()) {
		row->GetErrorObject().Throw();
	}
	const string registered = RegisteredLanguages(con);
	if (row->RowCount() == 0) {
		// Not the same thing as a row with no parser, and worth saying so: a language nothing has
		// registered is a missing EXTENSION, while a language registered without one is a
		// front-end that has not got a parser to offer. `language := 'css'` on a core-only build
		// is the first; treeql, which core registers because IR needs no parsing, is the second.
		throw InvalidInputException(
		    "tree_match: selector language '%s' is not registered in "
		    "tree_catalog.selector_languages, so a selector given as text cannot be parsed in this "
		    "build; pass tree_steps(...) to hand over IR, or load the front-end extension that "
		    "registers it. Registered: %s",
		    language, registered);
	}
	const Value parser = row->GetValue(0, 0);
	if (!parser.IsNull()) {
		// Unreachable in a core-only build: the only row with a parser is css's, and the file
		// that inserts it is the file this extension does not embed. Kept, and kept distinct from
		// the refusal below, because a front-end extension registering its parser is the whole
		// point of the registry, and the day one does the refusal has to name what is missing --
		// the DISPATCH -- rather than claim nothing is registered.
		throw NotImplementedException("tree_match: selector language '%s' registers the parser %s in "
		                              "tree_catalog.selector_languages, but this build has no front-end dispatch for a "
		                              "selector given as text; pass tree_steps(...) to hand over IR. Registered: %s",
		                              language, parser.ToString(), registered);
	}
	throw InvalidInputException(
	    "tree_match: selector language '%s' has no parser in tree_catalog.selector_languages, so a "
	    "selector given as text cannot be parsed in this build; pass tree_steps(...) to hand over "
	    "IR, or load a front-end extension that registers a parser. Registered: %s",
	    language, registered);
}

//! What a hand-written `duckent_match` call gets, from every direction it can arrive from.
//!
//! One message for all of them because they are one condition to the user: they called duckent
//! internals, and the fix is the same. It names `tree_match` because that is the function they
//! meant.
//!
//! A BinderException, and specifically NOT the InternalException this used to raise: INTERNAL
//! renders as "This error signals an assertion failure within DuckDB" over a 35-frame stack
//! trace, which tells a caller who merely used the wrong function name that they have found a
//! DuckDB bug. BINDER because every OTHER way of misusing duckent_match is already a Binder Error
//! -- DuckDB's overload matcher answers `duckent_match('main','a','abc')` with "No function
//! matches duckent_match(VARCHAR, VARCHAR, VARCHAR)" -- so a caller who got the argument's SHAPE
//! wrong rather than its TYPE should not be told something categorically different.
//!
//! BINDER is also one of the six types Exception::InvalidatesTransaction exempts
//! (duckdb/src/common/exception.cpp), unlike INVALID_INPUT and INTERNAL. That is a latent
//! property rather than an observable one: RequireAutoCommitForRead runs first, so inside a
//! transaction this refusal is never the one raised. Noted so that the exemption is not read as
//! the reason for the choice.
[[noreturn]] void RefuseInternalsCall() {
	throw BinderException("duckent_match is duckent internals: its selector argument has to be the relation the "
	                      "tree_match macro builds. Call tree_match(sch, nm, sel) instead.");
}

//! The selector argument as written, deparsed from the unbound copy the table macro parks in a
//! CTE, and returned as a scalar subquery ready to splice into the compile call. See the
//! mechanism note at the top of this file for why it has to come from there.
string SelectorText(TableFunctionBindInput &input) {
	if (!input.ref.function) {
		// DuckDB treats ref.function as nullable and checks it itself (GetAlias in
		// bind_table_function.cpp): Binder::BindTableFunction(TableFunction &, vector<Value>)
		// builds a default TableFunctionRef with a null `function`. That path is reached only from
		// Binder::Bind(ExtensionStatement), i.e. a parser extension, so nothing in this build can
		// reach it -- but a null here would be a segfault rather than a message, and a call with
		// no readable argument text is a call that cannot have come from the macro.
		RefuseInternalsCall();
	}
	auto &call = input.ref.function->Cast<FunctionExpression>();
	if (call.children.size() <= MATCH_SELECTOR_ARG ||
	    call.children[MATCH_SELECTOR_ARG]->GetExpressionClass() != ExpressionClass::SUBQUERY) {
		// UNREACHABLE in this build, and kept anyway. DuckDB's overload matcher rejects a
		// non-subquery third argument before bind runs at all -- `duckent_match('main','a','abc')`,
		// `(..., t)` and `(..., 1)` all give "No function matches duckent_match(...)" -- because a
		// subquery is the only thing admitted against a LogicalType::TABLE parameter. So this
		// branch is a guard on the shape SelectorText needs, not a path a user can take; the
		// condition a user CAN take is the missing-CTE one below.
		RefuseInternalsCall();
	}
	auto &subquery = call.children[MATCH_SELECTOR_ARG]->Cast<SubqueryExpression>();
	for (auto &cte : subquery.subquery->node->cte_map.map) {
		if (!StringUtil::CIEquals(cte.first, MATCH_SELECTOR_CTE) || !cte.second || !cte.second->query) {
			continue;
		}
		try {
			return "(" + cte.second->query->node->ToString() + ")";
		} catch (const std::exception &ex) {
			// The deparse is the one place the whole mechanism's assumption is load-bearing, so it
			// is the one place worth labelling. An unreferenced CTE is never BOUND on this DuckDB,
			// which is why its text is still there to read (fact 3 in the note at the top of this
			// file). On a DuckDB that binds it, binding replaces the parsed expression in place
			// with a BoundExpression whose ToString() unconditionally throws -- so the failure is
			// loud and the answer is never wrong, but the message is DuckDB's internal one and
			// reads as a DuckDB bug. It is not: it is duckent's assumption no longer holding.
			throw InvalidInputException(
			    "duckent: tree_match could not deparse its selector, which means this DuckDB binds "
			    "unreferenced CTEs. tree_match reads the selector's text out of an unreferenced CTE "
			    "*because* such a CTE is never bound; once it is bound there is no text left to "
			    "read. This is a duckent incompatibility with this DuckDB version, not a DuckDB "
			    "bug: the mechanism needs rework, see the note at the top of src/duckent_match.cpp. "
			    "Underlying error: %s",
			    // RawMessage(), not what(): a DuckDB exception's what() is the JSON envelope,
			    // stack-trace pointers and all, and the diagnosis worth keeping is the one line
			    // inside it ("ToString(): BoundExpression does not have a child").
			    ErrorData(ex).RawMessage());
		}
	}
	// REACHABLE: a hand-written `duckent_match('main','app',(SELECT 1))` lands here, because a
	// subquery passes the shape check above and carries no __duckent_selector CTE. Before this was
	// a refusal it was an InternalException, which told the user they had hit a DuckDB assertion
	// failure and invalidated their transaction on the way out.
	RefuseInternalsCall();
}

//! Compile the selector into a SQL query and take the result schema from it.
//!
//! Compiling in bind is right for THIS function and wrong for the verbs, and the difference is
//! not one of style: a verb's compiled statements are executed for their effects, so compiling at
//! bind time would fire them for a query that never runs, while tree_match is a read whose only
//! bind-time product is the schema -- which is what bind is for. It is also what lifts query()'s
//! literal-only restriction on the selector: the query text is COMPUTED here, not read out of a
//! constant.
unique_ptr<FunctionData> MatchBind(ClientContext &context, TableFunctionBindInput &input,
                                   vector<LogicalType> &return_types, vector<string> &names) {
	// Guarded HERE as well as in MatchInit, because the side connection opened on the next line is
	// its own hazard: this is where the selector is compiled, and a compile against the
	// pre-transaction snapshot is a stale SCHEMA and a stale query, which EXPLAIN would print and
	// an init-time check alone would never see (EXPLAIN binds and never inits). A refusal is not a
	// side effect, so it does not violate "no side effects in bind" -- it is the opposite of one.
	RequireAutoCommitForRead(context, "tree_match");

	auto result = make_uniq<MatchBindData>();
	Connection con(*context.db);
	const string selector = SelectorText(input);

	// The IR-or-text decision, in ONE place. run.py reads the argument's syntax; the selector
	// arrives here as a one-column relation, so that column's type answers the same question:
	// VARCHAR is text and needs a front-end, anything else -- the list of structs tree_steps()
	// builds, hand-written IR, and the plain integer 00_smoke.test's stub macro concatenates --
	// was never parsed and goes through untouched, with the treeql provenance the compiler's
	// COALESCE gives it.
	if (!input.input_table_types.empty() && input.input_table_types[0].id() == LogicalTypeId::VARCHAR) {
		RefuseTextSelector(con, ResolveSelectorLanguage(con, input));
	}

	// `SELECT tree_compile_match(?, ?, <selector>[, semantic := ?][, language := ?])`, with the
	// bound values in the same textual order the placeholders appear in.
	//
	// A named argument is written only when it has a value. Writing both unconditionally would
	// read the same to the shipped macro, whose defaults are NULL -- but not to a macro that
	// declares fewer parameters, and 00_smoke.test replaces tree_compile_match with a stub that
	// declares no `language`. DuckDB refuses a named argument the macro does not have, so passing
	// one nobody asked for would make this executor reject a call the runner accepts. NULL and
	// absent are the same question for both parameters (`_match_language` is
	// COALESCE(language, ...) and semantic defaults to NULL), so testing the value is enough.
	string call = "?, ?, " + selector;
	vector<Value> bound {input.inputs[0], input.inputs[1]};
	for (const char *name : {"semantic", "language"}) {
		auto named = input.named_parameters.find(name);
		if (named != input.named_parameters.end() && !named->second.IsNull()) {
			call += string(", ") + name + " := ?";
			bound.push_back(named->second);
		}
	}

	auto prepared = con.Prepare("SELECT tree_compile_match(" + call + ")");
	if (prepared->HasError()) {
		// Macros inline at bind time, so a refusal raised while binding surfaces here. Verbatim,
		// for the reason CompileStatements gives: refusal text is contract.
		prepared->GetErrorObject().Throw();
	}
	auto compiled = prepared->Execute(bound, false);
	if (compiled->HasError()) {
		compiled->GetErrorObject().Throw();
	}
	auto chunk = compiled->Fetch();
	if (!chunk || chunk->size() == 0) {
		throw InvalidInputException("duckent: tree_compile_match produced no query");
	}
	const Value compiled_sql = chunk->GetValue(0, 0);
	if (compiled_sql.IsNull()) {
		// The match compiler refuses rather than returning NULL, so this is a guard, not a path: a
		// NULL here would otherwise reach the parser as an empty query and report something about
		// SQL syntax instead of about the selector.
		throw InvalidInputException("duckent: tree_compile_match compiled to NULL");
	}
	result->compiled_sql = compiled_sql.ToString();

	auto shape = con.Prepare(result->compiled_sql);
	if (shape->HasError()) {
		// Also verbatim, and for the same reason: the compiled query is where a clause over a
		// column the projection does not carry fails, and the corpus pins those messages too.
		shape->GetErrorObject().Throw();
	}
	result->types = shape->GetTypes();
	result->names = shape->GetNames();
	return_types = result->types;
	names = result->names;
	return std::move(result);
}

unique_ptr<GlobalTableFunctionState> MatchInit(ClientContext &context, TableFunctionInitInput &input) {
	// And guarded HERE as well as in MatchBind, because this is a SECOND side connection, and it
	// is the one the rows actually come from. A bind-time check alone misses a statement bound
	// outside a transaction and executed inside one: PREPARE in autocommit, then BEGIN; EXECUTE
	// re-uses the plan without re-binding, so bind never runs again and only this check is left.
	RequireAutoCommitForRead(context, "tree_match");

	auto &bind = input.bind_data->Cast<MatchBindData>();
	auto state = make_uniq<MatchGlobalState>();
	state->con = make_uniq<Connection>(*context.db);
	state->result = state->con->Query(bind.compiled_sql);
	if (state->result->HasError()) {
		state->result->GetErrorObject().Throw();
	}
	return std::move(state);
}

//! The compiled query's rows. The input chunk is the selector relation DuckDB planned for the
//! TABLE parameter; bind took the selector's type from its schema and its text from the macro's
//! CTE, so the rows themselves are not read -- see the mechanism note at the top of this file.
OperatorResultType MatchInOut(ExecutionContext &, TableFunctionInput &data_p, DataChunk &, DataChunk &output) {
	auto &state = data_p.global_state->Cast<MatchGlobalState>();
	if (state.exhausted) {
		output.SetCardinality(0);
		return OperatorResultType::NEED_MORE_INPUT;
	}
	state.chunk = state.result->Fetch();
	if (!state.chunk || state.chunk->size() == 0) {
		state.exhausted = true;
		output.SetCardinality(0);
		return OperatorResultType::NEED_MORE_INPUT;
	}
	output.Reference(*state.chunk);
	return OperatorResultType::HAVE_MORE_OUTPUT;
}

} // namespace

void RegisterDuckentMatch(ExtensionLoader &loader) {
	// duckent_match(sch, nm, <selector relation>, semantic := ..., language := ...). The third
	// argument is LogicalType::TABLE so that the table macro below can hand the selector over as
	// a subquery and have it bound by an ordinary binder; sch, nm, semantic and language stay
	// ordinary arguments, so they arrive as VALUES rather than as text.
	TableFunction tf("duckent_match", {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::TABLE}, nullptr,
	                 MatchBind, MatchInit);
	tf.in_out_function = MatchInOut;
	tf.named_parameters["semantic"] = LogicalType::ANY;
	tf.named_parameters["language"] = LogicalType::VARCHAR;
	loader.RegisterFunction(tf);

	// tree_match(sch, nm, sel, semantic := ..., language := ...) mirrors
	// tree_compile_match(sch, nm, sel, semantic := NULL, language := NULL) argument for argument,
	// because every one of them is forwarded to it unexamined but the selector.
	//
	// This macro is GLUE, not semantics: it adds no refusal, no default and no rewrite, and the
	// only thing it does to an argument is give the selector the two shapes bind needs -- a
	// relation whose type it can read, and an unbound copy it can deparse. The semantics stay in
	// the embedded SQL where tree_compile_match is, and this text stays out of sql/ so that every
	// embedded file remains byte-identical to the plan repo's.
	//
	// 1.5.5 resolves a table function's NAME at CREATE MACRO time (the constraint sql/09_css.sql
	// records for parse_ast_list_table), so duckent_match is registered above, first.
	Connection con(loader.GetDatabaseInstance());
	auto created =
	    con.Query(string("CREATE OR REPLACE MACRO tree_match(sch, nm, sel, semantic := NULL, language := NULL) "
	                     "AS TABLE SELECT * FROM duckent_match(sch, nm, (WITH ") +
	              MATCH_SELECTOR_CTE + " AS (SELECT sel AS s) SELECT sel AS s), " +
	              "semantic := semantic, language := language)");
	if (created->HasError()) {
		throw InvalidInputException("duckent: failed to create the tree_match macro: %s", created->GetError());
	}
}

} // namespace duckdb
