# Validation matrix

Status as of August 12, 2026. A prepared cell has reproducible commands and
known dependencies; a validated cell has actually passed on that target.

| Cell | Backend | Status | Required checks |
| --- | --- | --- | --- |
| macOS arm64 / OCaml 5.3 | Cocoa/WKWebView | Validated locally | full build, unit, graphical integration, docs, release build/install, warnings, UBSan; single-Domain ASan smoke |
| macOS arm64 / OCaml 5.4 | Cocoa/WKWebView | Prepared, not run | same as 5.3; re-evaluate ASan Domain behavior |
| macOS arm64 / OCaml 5.5 | Cocoa/WKWebView | Prepared, not run | same as 5.3; re-evaluate ASan Domain behavior |
| Linux / OCaml 5.3 | GTK4/WebKitGTK 6.0 | Prepared, machine pending | full suite under a graphical session or virtual display, ASan, UBSan, package install |
| Linux / OCaml 5.4 | GTK4/WebKitGTK 6.0 | Prepared, machine pending | same |
| Linux / OCaml 5.5 | GTK4/WebKitGTK 6.0 | Prepared, machine pending | same |
| Linux / OCaml 5.3 | GTK3/WebKitGTK 4.1 | Prepared, machine pending | full suite and GTK3-specific dialogs/clipboard |
| Linux / OCaml 5.4 | GTK3/WebKitGTK 4.1 | Prepared, machine pending | same |
| Linux / OCaml 5.5 | GTK3/WebKitGTK 4.1 | Prepared, machine pending | same |
| Windows / OCaml 5.x | WebView2 | Target only | blocked on capability-complete native extensions and a supported test machine |

GTK3/WebKitGTK 4.0 remains an optional compatibility fallback, not a primary
release cell. It should receive a build and lifecycle smoke test before any
release claims it as supported.

## Check tiers

Every supported release cell runs:

1. Formatter and whitespace checks.
2. `dune build @all @runtest @doc`.
3. Graphical `@integration` tests.
4. `dune build --profile release @install @runtest @doc`.
5. `opam lint`.
6. A staged `dune install` into a temporary destination.
7. Strict C++ warnings.
8. `clang-tidy` when installed on the validation machine; the current macOS
   machine has the check prepared but does not yet have the tool installed.
9. Applicable ASan and UBSan jobs.
10. Local release archive creation and fresh-extraction verification.

The matrix is intentionally local. It does not define hosted-CI files or upload
results. Run `scripts/check-matrix.sh list` for machine-readable cell names and
`scripts/check-matrix.sh current` on each machine/switch. Results are written
under ignored `_build/validation/` and should be summarized in this document
before a maturity review.

## Current sanitizer exception

On macOS arm64 with OCaml 5.3, a minimal program that only spawns and joins an
OCaml Domain aborts inside AddressSanitizer's memory-unmap handling. Therefore:

- UBSan covers the Domain-concurrency tests on this toolchain.
- ASan covers `sanitizer_smoke_test`, which exercises native callback roots and
  destruction without spawning an additional Domain.
- This is not evidence that OCaml 5 Domains are unsupported by owebview.
- The limitation must be retested on OCaml 5.4, 5.5, and Linux rather than
  copied forward as an assumption.
