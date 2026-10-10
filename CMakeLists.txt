cmake_minimum_required(VERSION 3.5)

# Set extension name here
set(TARGET_NAME duckent)

# DuckDB's extension distribution supports vcpkg. As such, dependencies can be added in ./vcpkg.json and then
# used in cmake with find_package. Feel free to remove or replace with other dependencies.
# Note that it should also be removed from vcpkg.json to prevent needlessly installing it..
find_package(OpenSSL REQUIRED)

set(EXTENSION_NAME ${TARGET_NAME}_extension)
set(LOADABLE_EXTENSION_NAME ${TARGET_NAME}_loadable_extension)

project(${TARGET_NAME})

set(CMAKE_CXX_STANDARD "17" CACHE STRING "C++ standard to enforce")
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include_directories(src/include)

set(EXTENSION_SOURCES src/duckent_extension.cpp src/duckent_macro_loader.cpp
                      src/duckent_match.cpp src/duckent_sql.cpp
                      src/duckent_verbs.cpp)

set(DUCKENT_SQL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/src/sql_macros)
set(DUCKENT_EMBEDDED_HEADER ${CMAKE_CURRENT_BINARY_DIR}/embedded_sql_macros.hpp)

file(GLOB DUCKENT_SQL_FILES ${DUCKENT_SQL_DIR}/*.sql)

add_custom_command(
    OUTPUT ${DUCKENT_EMBEDDED_HEADER}
    COMMAND ${CMAKE_COMMAND} -E echo "Embedding duckent SQL macros"
    COMMAND python3 ${CMAKE_CURRENT_SOURCE_DIR}/scripts/embed_sql_macros.py
            --input-dir ${DUCKENT_SQL_DIR}
            --output ${DUCKENT_EMBEDDED_HEADER}
    DEPENDS ${DUCKENT_SQL_FILES} ${CMAKE_CURRENT_SOURCE_DIR}/scripts/embed_sql_macros.py
    COMMENT "Generating embedded_sql_macros.hpp"
)
add_custom_target(duckent_embed_sql DEPENDS ${DUCKENT_EMBEDDED_HEADER})
include_directories(${CMAKE_CURRENT_BINARY_DIR})

build_static_extension(${TARGET_NAME} ${EXTENSION_SOURCES})
build_loadable_extension(${TARGET_NAME} " " ${EXTENSION_SOURCES})

add_dependencies(${EXTENSION_NAME} duckent_embed_sql)
add_dependencies(${LOADABLE_EXTENSION_NAME} duckent_embed_sql)

# Link OpenSSL in both the static library as the loadable extension
target_link_libraries(${EXTENSION_NAME} OpenSSL::SSL OpenSSL::Crypto)
target_link_libraries(${LOADABLE_EXTENSION_NAME} OpenSSL::SSL OpenSSL::Crypto)

install(
  TARGETS ${EXTENSION_NAME}
  EXPORT "${DUCKDB_EXPORT_SET}"
  LIBRARY DESTINATION "${INSTALL_LIB_DIR}"
  ARCHIVE DESTINATION "${INSTALL_LIB_DIR}")
