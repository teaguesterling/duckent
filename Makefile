PROJ_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Configuration of extension
EXT_NAME=duckent
EXT_CONFIG=${PROJ_DIR}extension_config.cmake

# Include the Makefile from extension-ci-tools
include extension-ci-tools/makefiles/duckdb_extension.Makefile

# Override test_release_internal, test_debug_internal, and test_reldebug_internal (all three
# defined above, in the submodule's Makefile) to pass --test-config. The unittest binary's
# runtime extension list comes from TestConfiguration::ExtensionToBeLoadedOnLoad()
# (duckdb/test/helpers/test_config.cpp), which defaults to {"core_functions"} alone; the "Tests
# loaded for extensions: [duckent]" message produced by LOAD_TESTS in extension_config.cmake is a
# build-log line only (see extension/extension_build_tools.cmake) and does not populate that
# runtime list. Without this, test/sql/*.test files would need `require duckent` / `require json`
# lines to resolve duckent_version()/json_serialize_sql() — and a `require` that fails to resolve
# SKIPs the whole file silently rather than failing it, which is exactly the vacuous-green failure
# mode this project tracks. Pointing unittest at test/test_config.json makes extension-resolution
# regressions a hard failure instead of a silent skip, and keeps test files free of `require`.
#
# All three build configurations get this override, not just release: without it, a debug or
# reldebug run resolves extensions differently than release does, so a debug-only test failure
# (or pass) can be an artifact of that difference rather than of the change actually under test.
test_release_internal:
	./build/release/$(TEST_PATH) "$(TESTS_BASE_DIRECTORY)*" --test-config test/test_config.json
test_debug_internal:
	./build/debug/$(TEST_PATH) "$(TESTS_BASE_DIRECTORY)*" --test-config test/test_config.json
test_reldebug_internal:
	./build/reldebug/$(TEST_PATH) "$(TESTS_BASE_DIRECTORY)*" --test-config test/test_config.json

# Override the three format targets (also defined in the submodule's Makefile) to format `src`
# ONLY, dropping `test` from the directory list.
#
# The submodule's version runs `format.py --all --directories src test`, and `test/` here is not
# ours to format: test/sql/*.test and test/mutants/* are byte-identical copies of the plan repo's,
# and scripts/check_macro_identity.py fails the build if any of them differs by one byte.
# format.py normalizes whitespace in those .test files, so `make format-fix` with the default
# directories would silently fork the corpus from its source -- the exact failure the identity
# gate exists to prevent, introduced by the tool meant to tidy the repo. `make format-check` was
# red on main for this reason, listing all 16 copied suites among the files it wanted to rewrite.
#
# The cost is that test/check_gate.py, test/compile_differential.py and test/run_mutants.py --
# which ARE ours -- are not format-gated. format.py's --directories is per-directory, so there is
# no way to include those three while excluding their copied neighbours, and a forked corpus is
# much worse than three unformatted scripts.
format-check:
	python3 duckdb/scripts/format.py --all --check --directories src

format:
	python3 duckdb/scripts/format.py --all --fix --noconfirm --directories src

format-fix:
	python3 duckdb/scripts/format.py --all --fix --noconfirm --directories src
