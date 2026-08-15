# ADR 0001: OCaml 5 and Eio only

- Status: Accepted
- Date: August 12, 2026

## Decision

Require OCaml 5.3 or newer and support Eio as the sole asynchronous runtime.
Use native JavaScript Promises in the js_of_ocaml client and do not add Lwt
adapters.

## Consequences

The runtime can use Domains, effects, Eio switches, and structured concurrency
without compatibility shims. Documentation, tests, and public APIs have one
cancellation model. OCaml 4 and Lwt applications must migrate or remain on the
upstream thin binding.
