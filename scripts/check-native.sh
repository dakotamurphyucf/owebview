#!/bin/sh
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

compiler=${CXX:-c++}
object=$(mktemp "${TMPDIR:-/tmp}/owebview-native-warning.XXXXXX.o")
trap 'rm -f "$object"' EXIT HUP INT TERM

# OCaml 5.3's CAMLlocalresult macro expands to a C99 compound literal even in
# C++ mode. Keep that toolchain warning visible but non-fatal; all other
# warnings in owebview's own C++ translation unit are errors. System-header
# treatment keeps diagnostics from the unmodified vendored header separate.
"$compiler" -std=c++17 -Wall -Wextra -Wconversion -Wsign-conversion \
  -Wpedantic -Werror -Wno-error=c99-extensions \
  -isystem "$(ocamlc -where)" -isystem vendor \
  -c lib/webview_stubs.cpp -o "$object"
