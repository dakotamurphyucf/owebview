#!/bin/sh
set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

system=$(uname -s)

UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1
export UBSAN_OPTIONS
dune exec --profile ubsan test/integration/sanitizer_smoke_test.exe
dune exec --profile ubsan test/integration/managed_handle_test.exe

case "$system" in
  Darwin)
    # On OCaml 5.3/macOS, ASan itself aborts while an otherwise minimal OCaml
    # Domain is torn down. Keep ASan on the single-Domain callback/lifetime
    # smoke test and use UBSan above for Domain concurrency.
    ASAN_OPTIONS=halt_on_error=1:detect_leaks=0
    export ASAN_OPTIONS
    dune exec --profile asan test/integration/sanitizer_smoke_test.exe
    ;;
  Linux)
    ASAN_OPTIONS=halt_on_error=1:detect_leaks=1
    export ASAN_OPTIONS
    dune exec --profile asan test/integration/sanitizer_smoke_test.exe
    dune exec --profile asan test/integration/managed_handle_test.exe
    ;;
  *)
    echo "ASan profile is not defined for $system; UBSan checks passed" >&2
    ;;
esac
