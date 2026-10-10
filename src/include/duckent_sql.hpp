#pragma once

#include "duckdb.hpp"

namespace duckdb {

class ExtensionLoader;

//! The compile macro that carries a verb's semantics: `tree_ddl_create` -> `tree_compile_create`,
//! `tree_insert` -> `tree_compile_insert`. This is `compile_macro_name()` in the plan repo's
//! test/run.py, and it is written once here for the same reason it is written once there: the two
//! executors must not be able to disagree about which macro a verb means.
string DuckentCompileMacroName(const string &verb);

//! Run `SELECT <macro_name>(?, ?, ...)` with args bound in order; return the VARCHAR[] it
//! produces. The compile macros are the semantics: this helper marshals arguments and nothing
//! else, so any divergence between its output and run.py's for the same call is a marshalling
//! bug.
//!
//! A macro's refusal is the product, so its error is rethrown VERBATIM via ErrorData::Throw() --
//! the corpus pins these messages by substring and a prefix of our own is a contract change.
vector<string> CompileStatements(ClientContext &context, const string &macro_name,
                                 const vector<Value> &args);

//! Execute a compiled statement list atomically on a fresh connection: BEGIN TRANSACTION, the
//! statements, COMMIT; on any errored result ROLLBACK and rethrow the original error verbatim.
//! This is run.py's Session.execute transliterated -- see docs/executor-mechanism.md, mechanism
//! A-prime.
void ExecuteCompiledStatements(ClientContext &context, const vector<string> &statements);

//! Refuse when the caller is inside an explicit transaction. See the long comment at the
//! definition: this is the guard that makes mechanism A-prime safe.
void RequireAutoCommit(ClientContext &context, const string &verb);

void RegisterDuckentVerbs(ExtensionLoader &loader);

} // namespace duckdb
