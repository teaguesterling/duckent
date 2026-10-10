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

void RequireAutoCommit(ClientContext &context, const string &verb) {
	if (context.transaction.IsAutoCommit()) {
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

vector<string> CompileStatements(ClientContext &context, const string &macro_name,
                                 const vector<Value> &args) {
	string placeholders;
	for (idx_t i = 0; i < args.size(); i++) {
		placeholders += (i ? ", ?" : "?");
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
	vector<Value> bound = args;
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
		if (!v.IsNull()) {
			out.push_back(v.ToString());
		}
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
