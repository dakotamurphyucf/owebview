# Vendored native dependency

`vendor/webview.h` is the upstream webview 0.12 amalgamated header. Its embedded
MIT notice credits Serge Zaitsev and Steffen André Langnes. The repository's
top-level MIT license covers the OCaml project; both notices must remain in
source and release archives.

## Update policy

Vendor updates are deliberate compatibility changes, not opportunistic file
replacements. Before replacing the header:

1. Record the exact upstream tag and commit.
2. Download or export the upstream release from a reviewed source.
3. Verify the upstream checksum independently.
4. Compare licenses and retain all required notices.
5. Review the complete header diff, especially callback ownership, event-loop,
   native-handle, window-counting, and backend-selection changes.
6. Reapply only necessary local integration definitions outside the vendored
   file where possible.
7. Run the full current platform cell, warning build, and sanitizers.
8. Update `CHANGES.md`, this file, and `PLATFORM_SUPPORT.md`.

`scripts/check-vendor.sh` verifies the expected webview version markers and
license notices. A future network-fetching update helper may be added only when
it requires an explicit source URL and expected checksum; it must never update
the dependency implicitly during a normal build or test.

## Current provenance

- Dependency: webview
- Version: 0.12
- Form: single amalgamated header
- Local path: `vendor/webview.h`
- Imported by the preserved upstream owebview history before this local fork
- License: MIT, included at the beginning of the header

The exact upstream commit was not recorded by the inherited repository. That
missing historical detail must be resolved before public distribution, either
by identifying a byte-identical upstream artifact or by performing a reviewed
vendor refresh from a known tag and commit.
