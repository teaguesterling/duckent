# This file is included by DuckDB's build system. It specifies which extension to load

# Load order is load-bearing. duckent's embedded macros call core_functions
# operators and 27 json functions. Autoload is NOT sufficient: in a from-source
# build the version stamp is a git-describe string, no installed-extension
# directory matches it, and TryAutoLoadAvailableExtension silently no-ops
# (sitting_duck issue #82). Static linking is the only guarantee.
duckdb_extension_load(core_functions)
duckdb_extension_load(json)

duckdb_extension_load(duckent
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
    LOAD_TESTS
)
