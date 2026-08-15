#!/bin/sh
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

ODOC_WARN_ERROR=true
export ODOC_WARN_ERROR

scripts/check-format.sh
dune build @all @runtest @doc @integration
dune build --profile release @install @runtest @doc
opam lint owebview.opam
scripts/check-package.sh
scripts/check-native.sh
if command -v clang-tidy >/dev/null 2>&1; then
  scripts/check-clang-tidy.sh
else
  echo "clang-tidy is not installed; repository check is prepared but skipped" >&2
fi
scripts/check-vendor.sh
git diff --check
