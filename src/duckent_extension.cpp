#define DUCKDB_EXTENSION_MAIN

#include "duckent_extension.hpp"
#include "duckent_macro_loader.hpp"
#include "duckdb/main/extension/extension_loader.hpp"
#include "duckdb/function/scalar_function.hpp"
#include "duckdb/common/vector_operations/generic_executor.hpp"

namespace duckdb {

static void VersionFunc(DataChunk &args, ExpressionState &state, Vector &result) {
	result.SetVectorType(VectorType::CONSTANT_VECTOR);
	ConstantVector::GetData<string_t>(result)[0] = StringVector::AddString(result, "mvp");
}

// NOT static: the extern "C" entry block below calls it from outside the namespace.
void LoadInternal(ExtensionLoader &loader) {
	LoadEmbeddedMacros(loader);

	ScalarFunction version("duckent_version", {}, LogicalType::VARCHAR, VersionFunc);
	loader.RegisterFunction(version);
}

void DuckentExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}
std::string DuckentExtension::Name() {
	return "duckent";
}
std::string DuckentExtension::Version() const {
	return "mvp";
}

} // namespace duckdb

extern "C" {

DUCKDB_CPP_EXTENSION_ENTRY(duckent, loader) {
	duckdb::LoadInternal(loader);
}

DUCKDB_EXTENSION_API const char *duckent_version() {
	return duckdb::DuckDB::LibraryVersion();
}
}

#ifndef DUCKDB_EXTENSION_MAIN
#error DUCKDB_EXTENSION_MAIN not defined
#endif
