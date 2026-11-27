#include "duckent_sql.hpp"

#include "duckdb/common/error_data.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/main/connection.hpp"
#include "duckdb/transaction/transaction_context.hpp"

namespace duckdb {

string DuckentCompileMacroName(const string &verb) {
	for (const string prefix : {"tree_ddl_", "tree_"}) {
		if (verb.rfind(prefix, 0) == 0) {
			return "tree_compile_" + verb.substr(prefix.size());
		}
	}
	return "tree_compile_" + verb;
}

//! The one test both guards below are made of. Written once so that the two refusals cannot come
//! to disagree about WHEN they fire while differing about WHY, which is the whole point of there
//! being two of them.
static bool InsideExplicitTransaction(ClientContext &context) {
	return !context.transaction.IsAutoCommit();
}

void RequireAutoCommit(ClientContext &context, const string &verb) {
	if (!InsideExplicitTransaction(context)) {
		return;
	}
	// A verb executes its compiled statement list on its OWN connection, in its own transaction
	// (docs/executor-mechanism.md, mechanism A-prime). Inside a caller's explicit BEGIN that has
	// two measured consequences, both silent and both wrong:
	//
	//   1. the verb's work is committed by its own COMMIT, so the caller's ROLLBACK does not
	//      undo it; and
	//   2. the compile step reads only committed state, so the verb compiles against the
	//      database as of the transaction's start -- it cannot see what this transaction has
	//      already done, e.g. a tree created by an earlier verb in the same BEGIN.
	//
	// Both arise only inside an explicit transaction, so one refusal covers both. A legible
	// refusal beats a silent wrong answer.
	throw InvalidInputException("duckent: %s cannot run inside an explicit transaction. A duckent verb executes its "
	                            "compiled statement list in a transaction of its own, so its work would survive your "
	                            "ROLLBACK, and it would compile against the database as of this transaction's start "
	                            "rather than against what this transaction has done so far. COMMIT or ROLLBACK first, "
	                            "then call %s outside the transaction.",
	                            verb, verb);
}

void RequireAutoCommitForRead(ClientContext &context, const string &reader) {
	if (!InsideExplicitTransaction(context)) {
		return;
	}
	// Same test as RequireAutoCommit, different consequence, so a different message.
	//
	// A reader has no work to survive a ROLLBACK -- it writes nothing. What it has instead is an
	// ANSWER, and the answer is the thing the transaction invalidates: both the compile step and
	// the execution of the compiled query run on side connections of their own, which see only
	// committed data (docs/executor-mechanism.md). Measured against the relation the match reads,
	// before this guard existed:
	//
	//     baseline_match        2
	//     BEGIN; DELETE FROM src;
	//     SELECT count(*) FROM src WHERE ...   -> 0   what the caller's transaction sees
	//     tree_match(...)                      -> 2   what tree_match said, silently
	//
	// A read disagreeing with its own reader is worse than the verb case, because a read is what
	// a user is most likely to interleave with uncommitted DML. Executing on the CALLER's
	// connection would fix it and cannot be done: that is mechanism B, which deadlocks. So this
	// refuses, for the same reason the verbs do -- a legible refusal beats a silent wrong answer.
	throw InvalidInputException(
	    "duckent: %s cannot run inside an explicit transaction. It compiles the selector and runs "
	    "the compiled query on connections of its own, which see only committed data, so its "
	    "answer would describe the database as of this transaction's start rather than what this "
	    "transaction has done so far -- rows this transaction has inserted, deleted or altered "
	    "would be missing from, or still present in, the result. COMMIT or ROLLBACK first, then "
	    "call %s outside the transaction.",
	    reader, reader);
}

vector<string> CompileStatements(ClientContext &context, const string &macro_name, const vector<Value> &args) {
	// One placeholder per argument, except a NULL argument, which is written as a NULL literal:
	// `NULL` for a NULL of type INTEGER, `NULL::<type>` for every other type.
	//
	// run.py splices every argument's TEXT into `SELECT {macro}({args})`, so a caller's NULL
	// reaches the macro with exactly the type the caller wrote. Here DuckDB folds a table
	// function's arguments to Values first, and a bare `NULL` against a LogicalType::ANY parameter
	// arrives as a NULL of type INTEGER -- SQLNULL only in the `arguments` list DuckDB matched the
	// overload on, not in the Value it hands over. Bound as a parameter, that INTEGER is what the
	// macro inlines against, and `CALL tree_ddl_alter('main', 'bare', NULL)` misbinds instead of
	// giving the refusal 11_ddl.test pins (on DuckDB 1.5.5: "UNNEST() for correlated expressions
	// is not supported yet"). So an INTEGER NULL is written as the bare literal `NULL`.
	//
	// Every other type is the caller's, and the macro binds against it, so it is kept. Measured on
	// DuckDB v2.0.1, with the compile macro called directly:
	//
	//     tree_compile_alter('main', 'bare', NULL)                           -> nothing to alter
	//     tree_compile_alter('main', 'bare', NULL::TREE_SEMANTIC)            -> nothing to alter
	//     tree_compile_alter('main', 'bare', NULL::STRUCT(abstract BOOLEAN)) -> Binder Error:
	//         Could not find key "predicate" in struct
	//     tree_compile_alter('main', 'bare', NULL::INTEGER)                  -> Binder Error:
	//         Cannot extract field 'predicate' from expression "CAST(NULL AS INTEGER)"
	//
	// An earlier version dropped the type of EVERY NULL. That turned the STRUCT case's type error
	// into "nothing to alter", a refusal for an argument that was never a semantic, and the
	// compile differential caught it (12_verb_executor.test pins it now). On DuckDB 1.5.5 the
	// STRUCT case also gave "nothing to alter", so the difference did not show there.
	//
	// The one known cost: a caller who writes NULL::INTEGER explicitly gets the bare-NULL
	// behaviour, because the Value cannot tell that INTEGER from the one DuckDB invents. Measured
	// on v2.0.1: `CALL tree_ddl_alter('main', 'bare', NULL::INTEGER)` gives "nothing to alter",
	// where the macro called directly gives the Binder Error above.
	string placeholders;
	vector<Value> bound;
	for (idx_t i = 0; i < args.size(); i++) {
		placeholders += (i ? ", " : "");
		if (args[i].IsNull()) {
			const auto &type = args[i].type();
			if (type.id() == LogicalTypeId::INTEGER || type.id() == LogicalTypeId::SQLNULL) {
				placeholders += "NULL";
			} else {
				placeholders += "NULL::" + type.ToString();
			}
			continue;
		}
		placeholders += "?";
		bound.push_back(args[i]);
	}
	const string sql = "SELECT " + macro_name + "(" + placeholders + ")";

	Connection con(*context.db);
	auto prepared = con.Prepare(sql);
	if (prepared->HasError()) {
		// Macros are inlined at bind time, so a refusal the macro raises while binding is
		// indistinguishable here from a prepare-time bug of our own -- and refusal text is
		// contract. Pass it through untouched; the corpus matches on what the error SAYS.
		prepared->GetErrorObject().Throw();
	}
	auto result = prepared->Execute(bound);
	if (result->HasError()) {
		// The macro's refusal is the product. Unwrapped, verbatim.
		result->GetErrorObject().Throw();
	}
	auto chunk = result->Fetch();
	if (!chunk || chunk->size() == 0) {
		throw InvalidInputException("duckent: %s produced no statement list", macro_name);
	}
	const Value list = chunk->GetValue(0, 0);
	if (list.IsNull()) {
		// A compile macro returning NULL is the "required statement compiled to NULL" case the
		// macros themselves refuse; reaching here means a path that does not.
		throw InvalidInputException("duckent: %s compiled to NULL", macro_name);
	}
	vector<string> out;
	for (const auto &v : ListValue::GetChildren(list)) {
		if (v.IsNull()) {
			// Refused, not skipped, and refused HERE -- during the conversion, before
			// ExecuteCompiledStatements has run anything, so there is no partial work to undo.
			//
			// Dropping the NULL instead would make this executor disagree with the reference
			// one: run.py's Session.execute iterates the list unfiltered, so a NULL element
			// raises there. The port's premise is that the semantics live in the macros and the
			// executor only reproduces them, so a case where the two executors differ must not
			// exist even where no macro can reach it -- and the difference here is the worst
			// kind, a verb reporting success having silently skipped a statement.
			//
			// Unreachable from the shipped macros, which all list_filter(..., x IS NOT NULL)
			// before returning. This is a guard against a future compile macro that does not,
			// which is why it names the macro: that name is the only thing a reader can act on.
			throw InvalidInputException("duckent: %s produced a NULL statement", macro_name);
		}
		out.push_back(v.ToString());
	}
	return out;
}

void ExecuteCompiledStatements(ClientContext &context, const vector<string> &statements) {
	// A fresh Connection is not inside a query, so BEGIN TRANSACTION is legal on it -- the
	// prohibition that forced transaction control out of the compile macros applies to the
	// calling context, not to a side connection. This transaction is the ONLY thing that makes
	// the statement list atomic; measured in docs/executor-mechanism.md (mechanism A, the same
	// code without it, left the first statement committed when a later one raised).
	Connection con(*context.db);

	auto begin = con.Query("BEGIN TRANSACTION");
	if (begin->HasError()) {
		begin->GetErrorObject().Throw();
	}
	for (const auto &stmt : statements) {
		auto r = con.Query(stmt);
		if (r->HasError()) {
			// Copy before the result dies, roll back, then rethrow the ORIGINAL error so the
			// message the corpus matches on survives the rollback unchanged. This fires on
			// parse-, bind- and runtime errors alike, since all three arrive as an errored
			// result.
			ErrorData error = r->GetErrorObject();
			con.Query("ROLLBACK");
			error.Throw();
		}
	}
	auto commit = con.Query("COMMIT");
	if (commit->HasError()) {
		ErrorData error = commit->GetErrorObject();
		con.Query("ROLLBACK");
		error.Throw();
	}
}

} // namespace duckdb
