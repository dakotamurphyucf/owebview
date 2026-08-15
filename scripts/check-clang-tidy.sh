#!/bin/sh
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

if ! command -v clang-tidy >/dev/null 2>&1; then
  echo "clang-tidy is required for this check but is not installed" >&2
  exit 127
fi

dune build lib/c_flags.sexp
platform_flags=$(tr -d '()"' < _build/default/lib/c_flags.sexp)

# Deliberate word splitting converts Dune's generated list of compiler flags
# into clang-tidy arguments. The discovered pkg-config paths must not contain
# shell whitespace.
# shellcheck disable=SC2086
clang-tidy lib/webview_stubs.cpp -- \
  -std=c++17 -isystem "$(ocamlc -where)" -isystem vendor $platform_flags
