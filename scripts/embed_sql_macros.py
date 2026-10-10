#!/usr/bin/env python3
"""
Generate a C++ header file with embedded SQL macros.
This script reads SQL files and creates a header with raw string literals.
Handles MSVC's 16KB string literal limit by splitting large files.

Usage:
    embed_sql_macros.py --input-dir <dir> --output <file>

Adapted from sitting_duck's scripts/embed_sql_macros.py: this version takes
--input-dir/--output flags and globs *.sql from the input directory instead
of a hardcoded filename list, so any set of macro files can be embedded
without editing the script. The chunking logic (MSVC 16KB string literal
limit) is unchanged. Embedding order does not matter here: callers that need
dependency order (e.g. duckent's loader) sort EMBEDDED_SQL_MACROS by filename
themselves at load time.
"""

import argparse
from pathlib import Path

# MSVC has a 16380 byte limit per string literal - use 14000 to be safe
MAX_CHUNK_SIZE = 14000


def escape_raw_string_delimiter(content):
    """Ensure the content doesn't contain )SQLMACRO" which would break our delimiter."""
    if ')SQLMACRO"' in content:
        raise ValueError("SQL content contains raw string delimiter - please use a different delimiter")
    return content


def split_content(content, max_size=MAX_CHUNK_SIZE):
    """Split content into chunks, breaking at newlines."""
    if len(content) <= max_size:
        return [content]

    chunks = []
    current_chunk = ""

    for line in content.split('\n'):
        line_with_newline = line + '\n'
        if len(current_chunk) + len(line_with_newline) > max_size and current_chunk:
            chunks.append(current_chunk)
            current_chunk = line_with_newline
        else:
            current_chunk += line_with_newline

    if current_chunk:
        # Remove trailing newline from last chunk
        chunks.append(current_chunk.rstrip('\n'))

    return chunks


def generate_header(sql_dir, output_file):
    """Generate C++ header with embedded SQL macros."""

    sql_dir = Path(sql_dir)
    sql_files = sorted(p.name for p in sql_dir.glob('*.sql'))

    header_content = """// Auto-generated file - DO NOT EDIT
// Generated from SQL macro files in src/sql_macros/
// Run: python scripts/embed_sql_macros.py --input-dir <dir> --output <file>
// Note: Large files are split into chunks to handle MSVC's 16KB string literal limit

#pragma once

#include <string>
#include <vector>
#include <utility>

namespace duckdb {

// SQL macro definitions embedded at compile time
static const std::vector<std::pair<std::string, std::string>> EMBEDDED_SQL_MACROS = {
"""

    chunk_report = []

    for sql_file in sql_files:
        filepath = sql_dir / sql_file
        with open(filepath, 'r') as f:
            content = f.read()

        # Verify content doesn't break our delimiter
        escape_raw_string_delimiter(content)

        # Split into chunks for MSVC compatibility
        chunks = split_content(content)
        if len(chunks) > 1:
            chunk_report.append((sql_file, len(content), len(chunks)))

        if len(chunks) == 1:
            # Small file - use simple format
            header_content += f'''    {{"{sql_file}", R"SQLMACRO(
{content}
)SQLMACRO"}},
'''
        else:
            # Large file - concatenate chunks
            header_content += f'    {{"{sql_file}", '
            for i, chunk in enumerate(chunks):
                if i > 0:
                    header_content += '\n        '
                header_content += f'R"SQLMACRO(\n{chunk}\n)SQLMACRO"'
            header_content += '},\n'

    header_content += """};

} // namespace duckdb
"""

    output_file = Path(output_file)
    output_file.parent.mkdir(parents=True, exist_ok=True)
    with open(output_file, 'w') as f:
        f.write(header_content)

    print(f"Generated {output_file}")

    for sql_file, size, nchunks in chunk_report:
        print(f"  {sql_file}: {size} bytes -> {nchunks} chunks")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-dir', required=True, help='Directory containing .sql files to embed')
    parser.add_argument('--output', required=True, help='Path to the generated header file')
    args = parser.parse_args()

    generate_header(args.input_dir, args.output)


if __name__ == "__main__":
    main()
