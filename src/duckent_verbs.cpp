#include "duckent_sql.hpp"

#include "duckdb/function/table_function.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/main/extension/extension_loader.hpp"

namespace duckdb {

namespace {

struct VerbBindData : public TableFunctionData {
	string verb;
	string macro_name;
	vector<Value> args;
};

struct VerbGlobalState : public GlobalTableFunctionState {
	bool done = false;
};

//! Shared bind. Each verb gets a three-line wrapper below that hardcodes its own name; the
//! brief's `__macro` named parameter was dropped because nothing ever supplied it (every verb
//! would have compiled `SELECT (?, ...)`) and because a hidden named parameter that changes
//! which macro runs is worse than one wrapper per verb.
unique_ptr<FunctionData> VerbBind(const char *verb, TableFunctionBindInput &input,
                                  vector<LogicalType> &return_types, vector<string> &names) {
	auto result = make_uniq<VerbBindData>();
	result->verb = verb;
	result->macro_name = DuckentCompileMacroName(result->verb);
	for (auto &v : input.inputs) {
		result->args.push_back(v);
	}
	// Bind runs under EXPLAIN and during prepare. It records arguments and NOTHING else:
	// compiling or executing here would fire the verb for a query that never runs.
	return_types.push_back(LogicalType::BOOLEAN);
	names.emplace_back("ok");
	return std::move(result);
}

unique_ptr<GlobalTableFunctionState> VerbInit(ClientContext &, TableFunctionInitInput &) {
	return make_uniq<VerbGlobalState>();
}

//! The whole verb -- guard, compile, execute -- happens here, because a scan is the only part of
//! a table function that runs exactly when the query runs.
//!
//! Footgun inherited from the mechanism (docs/executor-mechanism.md): a scan that the optimizer
//! never calls never mutates. `CALL verb(...)`, the corpus' spelling, always runs it; so does a
//! cross join. `SELECT * FROM verb(...) LIMIT 0` does not, and so silently does nothing. Not
//! reachable from `CALL`.
void VerbScan(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &state = data_p.global_state->Cast<VerbGlobalState>();
	if (state.done) {
		output.SetCardinality(0);
		return;
	}
	auto &bind = data_p.bind_data->Cast<VerbBindData>();

	RequireAutoCommit(context, bind.verb);
	const auto statements = CompileStatements(context, bind.macro_name, bind.args);
	ExecuteCompiledStatements(context, statements);

	output.SetCardinality(1);
	output.SetValue(0, 0, Value::BOOLEAN(true));
	state.done = true;
}

// --- one bind wrapper per verb -----------------------------------------------------------
// Task 6 adds the other six on this pattern.

unique_ptr<FunctionData> BindTreeDdlCreate(ClientContext &, TableFunctionBindInput &input,
                                           vector<LogicalType> &return_types, vector<string> &names) {
	return VerbBind("tree_ddl_create", input, return_types, names);
}

unique_ptr<FunctionData> BindTreeDdlDrop(ClientContext &, TableFunctionBindInput &input,
                                         vector<LogicalType> &return_types, vector<string> &names) {
	return VerbBind("tree_ddl_drop", input, return_types, names);
}

unique_ptr<FunctionData> BindTreeDdlAlter(ClientContext &, TableFunctionBindInput &input,
                                          vector<LogicalType> &return_types, vector<string> &names) {
	return VerbBind("tree_ddl_alter", input, return_types, names);
}

unique_ptr<FunctionData> BindTreeInsert(ClientContext &, TableFunctionBindInput &input,
                                        vector<LogicalType> &return_types, vector<string> &names) {
	return VerbBind("tree_insert", input, return_types, names);
}

unique_ptr<FunctionData> BindTreeReplace(ClientContext &, TableFunctionBindInput &input,
                                         vector<LogicalType> &return_types, vector<string> &names) {
	return VerbBind("tree_replace", input, return_types, names);
}

unique_ptr<FunctionData> BindTreeDelete(ClientContext &, TableFunctionBindInput &input,
                                        vector<LogicalType> &return_types, vector<string> &names) {
	return VerbBind("tree_delete", input, return_types, names);
}

unique_ptr<FunctionData> BindTreeCheck(ClientContext &, TableFunctionBindInput &input,
                                       vector<LogicalType> &return_types, vector<string> &names) {
	return VerbBind("tree_check", input, return_types, names);
}

TableFunction MakeVerb(const string &name, const vector<LogicalType> &arg_types,
                       table_function_bind_t bind) {
	return TableFunction(name, arg_types, VerbScan, bind, VerbInit);
}

} // namespace

void RegisterDuckentVerbs(ExtensionLoader &loader) {
	// tree_ddl_create(sch, nm, spec) -- spec is a TREE_SPEC struct from tree_spec(), which the
	// compile macro re-reads field by field, so the argument type is ANY rather than a struct
	// shape spelled out here. (LogicalType::ANY is established for table-function arguments in
	// core: src/function/table/repeat_row.cpp.)
	loader.RegisterFunction(MakeVerb("tree_ddl_create",
	                                 {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::ANY},
	                                 BindTreeDdlCreate));

	// tree_ddl_drop(sch, nm) -- a bare identity; nothing else to type.
	loader.RegisterFunction(
	    MakeVerb("tree_ddl_drop", {LogicalType::VARCHAR, LogicalType::VARCHAR}, BindTreeDdlDrop));

	// tree_ddl_alter(sch, nm, semantic) -- semantic is a TREE_SEMANTIC struct from
	// tree_semantic(), read field by field the same way create reads TREE_SPEC, so ANY for the
	// same reason as create's third argument above.
	loader.RegisterFunction(MakeVerb("tree_ddl_alter",
	                                 {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::ANY},
	                                 BindTreeDdlAlter));

	// tree_insert(sch, nm, source) / tree_replace(sch, nm, source) -- source is SQL text (a
	// relation expression), spliced into the compiled statements as a string and never
	// evaluated as a value here, so VARCHAR.
	loader.RegisterFunction(MakeVerb(
	    "tree_insert", {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR}, BindTreeInsert));
	loader.RegisterFunction(MakeVerb(
	    "tree_replace", {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR}, BindTreeReplace));

	// tree_delete(sch, nm, root_predicate) -- root_predicate is SQL text too (a WHERE-clause
	// fragment over the ROOT columns), same reasoning as source above.
	loader.RegisterFunction(MakeVerb(
	    "tree_delete", {LogicalType::VARCHAR, LogicalType::VARCHAR, LogicalType::VARCHAR}, BindTreeDelete));

	// tree_check(sch, nm) -- records assertions; no extra argument to type.
	loader.RegisterFunction(
	    MakeVerb("tree_check", {LogicalType::VARCHAR, LogicalType::VARCHAR}, BindTreeCheck));
}

} // namespace duckdb
