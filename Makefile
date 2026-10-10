PROJ_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Configuration of extension
EXT_NAME=duckent
EXT_CONFIG=${PROJ_DIR}extension_config.cmake

# Include the Makefile from extension-ci-tools
include extension-ci-tools/makefiles/duckdb_extension.Makefile

# Override test_release_internal (defined above, in the submodule's Makefile) to pass
# --test-config. The unittest binary's runtime extension list comes from
# TestConfiguration::ExtensionToBeLoadedOnLoad() (duckdb/test/helpers/test_config.cpp), which
# defaults to {"core_functions"} alone; the "Tests loaded for extensions: [duckent]" message
# produced by LOAD_TESTS in extension_config.cmake is a build-log line only (see
# extension/extension_build_tools.cmake) and does not populate that runtime list. Without this,
# test/sql/*.test files would need `require duckent` / `require json` lines to resolve
# duckent_version()/json_serialize_sql() — and a `require` that fails to resolve SKIPs the whole
# file silently rather than failing it, which is exactly the vacuous-green failure mode this
# project tracks. Pointing unittest at test/test_config.json makes extension-resolution
# regressions a hard failure instead of a silent skip, and keeps test files free of `require`.
test_release_internal:
	./build/release/$(TEST_PATH) "$(TESTS_BASE_DIRECTORY)*" --test-config test/test_config.json
