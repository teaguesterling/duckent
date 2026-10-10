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
	throw InvalidInputException(
	    "duckent: %s cannot run inside an explicit transaction. A duckent verb executes its "
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

vector<string> CompileStatements(ClientContext &context, const string &macro_name,
                                 const vector<Value> &args) {
	// One placeholder per argument, except a NULL argument, which is written as the literal NULL.
	//
	// run.py splices every argument's TEXT into `SELECT {macro}({args})`, so a caller's `NULL`
	// reaches the macro as a NULL literal, which is typeless. Here it does not: DuckDB folds a
	// table function's arguments to Values, and a bare `NULL` against a LogicalType::ANY
	// parameter arrives as a NULL of type INTEGER -- SQLNULL only in the `arguments` list DuckDB
	// matched the overload on, not in the Value it hands over. Bound as a parameter, that INTEGER
	// is what the macro inlines against, and `CALL tree_ddl_alter('main', 'bare', NULL)` reports
	// "UNNEST() for correlated expressions is not supported yet" instead of the refusal
	// 11_ddl.test pins. Measured, on this build, with the compile macro called directly:
	//
	//     tree_compile_alter('main', 'bare', NULL)                           -> nothing to alter
	//     tree_compile_alter('main', 'bare', NULL::TREE_SEMANTIC)            -> nothing to alter
	//     tree_compile_alter('main', 'bare', NULL::STRUCT(abstract BOOLEAN)) -> nothing to alter
	//     tree_compile_alter('main', 'bare', NULL::INTEGER)                  -> UNNEST() ... error
	//
	// So writing `NULL` restores what the caller wrote and the reference passes on. The type of a
	// NULL is dropped rather than respelled as `NULL::<type>` because it is not the caller's: an
	// INTEGER is the one case that misbinds, and it is the one DuckDB invented.
	string placeholders;
	vector<Value> bound;
	for (idx_t i = 0; i < args.size(); i++) {
		placeholders += (i ? ", " : "");
		if (args[i].IsNull()) {
			placeholders += "NULL";
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
	auto result = prepared->Execute(bound, false);
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
