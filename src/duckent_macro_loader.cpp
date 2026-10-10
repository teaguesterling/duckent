#include "duckent_macro_loader.hpp"
#include "embedded_sql_macros.hpp"
#include "duckdb/main/connection.hpp"
#include <algorithm>

namespace duckdb {

void LoadEmbeddedMacros(ExtensionLoader &loader) {
	auto files = EMBEDDED_SQL_MACROS;
	std::sort(files.begin(), files.end(),
	          [](const std::pair<std::string, std::string> &a,
	             const std::pair<std::string, std::string> &b) { return a.first < b.first; });

	Connection con(loader.GetDatabaseInstance());
	for (const auto &f : files) {
		auto result = con.Query(f.second);
		if (result->HasError()) {
			// Name the FILE. A failure here is almost always a missing statically
			// linked dependency (json, core_functions), and without the filename
			// the message is a bare SQL error with no provenance.
			throw InvalidInputException("duckent: failed to load embedded macros from %s: %s",
			                            f.first, result->GetError());
		}
	}
}

} // namespace duckdb
