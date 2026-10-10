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
vector<string> CompileStatements(ClientContext &context, const string &macro_name, const vector<Value> &args);

//! Execute a compiled statement list atomically on a fresh connection: BEGIN TRANSACTION, the
//! statements, COMMIT; on any errored result ROLLBACK and rethrow the original error verbatim.
//! This is run.py's Session.execute transliterated -- see docs/executor-mechanism.md, mechanism
//! A-prime.
void ExecuteCompiledStatements(ClientContext &context, const vector<string> &statements);

//! Refuse when the caller is inside an explicit transaction. See the long comment at the
//! definition: this is the guard that makes mechanism A-prime safe.
void RequireAutoCommit(ClientContext &context, const string &verb);

//! The same refusal for a READER -- `tree_match` -- which compiles and executes on side
//! connections too and so cannot see the caller's uncommitted work either.
//!
//! Deliberately a sibling rather than a flag on RequireAutoCommit: the test is identical but the
//! consequence is not. A verb's WORK would survive the caller's ROLLBACK; a reader's ANSWER would
//! not reflect the caller's transaction. Telling a user of `tree_match` that its work might
//! survive their ROLLBACK would be false, and `tree_match` writes nothing.
void RequireAutoCommitForRead(ClientContext &context, const string &reader);

void RegisterDuckentVerbs(ExtensionLoader &loader);

//! `tree_match(sch, nm, sel, semantic := ..., language := ...)`: compiles the selector to a SQL
//! query and returns that query's rows. Unlike a verb it is a READ, so the compile happens at
//! bind time, where it determines the schema and nothing else.
//!
//! Both halves run on connections of their own, not the caller's: bind compiles on a side
//! connection, and the compiled query is EXECUTED on a second one. That second connection is the
//! fact that made the missing transaction guard invisible -- "the compile is at bind time" reads
//! as though only the schema could be stale, when in truth every row comes from a connection that
//! cannot see the caller's uncommitted work. Hence RequireAutoCommitForRead at both sites.
//!
//! Registers a table MACRO over a table function rather than a table function alone, because a
//! table function's arguments cannot contain a subquery and `tree_steps` is a subquery-bodied
//! macro. The long comment at the top of src/duckent_match.cpp has the measurements.
void RegisterDuckentMatch(ExtensionLoader &loader);

} // namespace duckdb
