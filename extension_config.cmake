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

# DuckDB v2.0 stopped linking an extension into the duckdb targets because it is loaded here:
# duckdb/extension/extension_build_tools.cmake, "DONT_LINK was removed, extensions are only linked
# when listed with duckdb_extension_statically_link() or STATICALLY_LINK_EXTENSIONS". Without this
# line the from-source CLI has no duckent, and test/compile_differential.py, which drives that CLI
# with no LOAD, cannot see tree_ddl_create. On v1.5 the CLI had it implicitly.
# core_functions and json need the same line, for the reason the load-order note above gives:
# with duckent linked alone, the CLI's first macro load tried to autoload core_functions and
# failed on the extension signature (measured on v2.0.1).
duckdb_extension_statically_link(core_functions)
duckdb_extension_statically_link(json)
duckdb_extension_statically_link(duckent)
