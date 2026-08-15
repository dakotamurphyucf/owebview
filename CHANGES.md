# Changes

This changelog records the local fork. No version listed here has been
published, pushed, or submitted to opam.

## Unreleased

### Runtime and native binding

- Require OCaml 5.3 or newer and make native handles safe to inspect after
  explicit destruction.
- Add typed native errors, lifecycle and owner-thread checks, idempotent
  destruction, callback exception barriers, generational roots, and documented
  cross-Domain operations.
- Keep the platform WebView loop on the process main thread while Eio runs on a
  dedicated Domain.
- Add bounded JavaScript binding queues and bounded Eio handler concurrency.

### Application protocol

- Add runtime-neutral typed codecs, RPC, events, stream endpoints, versioned
  envelopes, structured errors, and a compatibility-enforced handshake.
- Add a Promise-based js_of_ocaml client with no Lwt dependency.
- Add native-to-frontend RPC and cancellation-aware request handling.

### Realtime applications

- Add multiplexed, bounded realtime streams with batching, coalescing,
  sequence numbers, acknowledgement, replay, resume, terminal retention,
  commands, cancellation, and slow-subscriber isolation.
- Add durable application sessions with atomic directory persistence,
  multi-window attachment, persisted cursors, durable command IDs and status,
  authorization, crash reconciliation, retention, compaction, and
  interrupted-run retry.

### Desktop application support

- Add tokenized loopback application assets, production and development modes,
  MIME/CSP/cache security headers, and trusted-origin transport enforcement.
- Add managed secondary windows, close interception, dialogs, window controls,
  theme observation, clipboard operations, console forwarding, download and
  permission policy hooks, and conservative capability reporting.
- Present Cocoa dialogs as fully asynchronous window-attached sheets. Eio
  fibers await exactly-once completion without `runModal`, polling, or a nested
  run loop; cancellation and parent-window closure dismiss pending sheets
  deterministically.
- Route physical Cocoa fullscreen-button clicks through a per-instance button
  subclass and a clean main-queue turn, avoiding AppKit
  mouse-tracking/libunwind crashes beneath the OCaml-owned event loop.
- Remove Cocoa's destructor-time nested queue drain from the vendored webview
  implementation. Secondary-window teardown now returns to the existing
  `NSApplication` loop instead of waiting for a main-queue sentinel that cannot
  execute from inside the current callback; a shared lifetime guard discards
  callbacks that remain queued after engine destruction.
- Add explicit Cocoa, GTK4/WebKitGTK 6.0, GTK3/WebKitGTK 4.1/4.0, and WebView2
  target selection.

### Examples and verification

- Add Eio, desktop application, shared protocol/RPC, and durable agent-streaming
  examples, including a js_of_ocaml frontend and actual process-restart test.
- Expand the agent-streaming example into Orbit Agent Studio, a polished native
  showcase with typed phases, plans, tools, telemetry, approvals, live
  instructions, pause/resume/cancel, artifacts, checkpoints, multi-window
  replay, native clipboard/export actions, platform capabilities, durable
  history, restart replay, and deterministic end-to-end showcase mode.
- Add unit, integration, stress, lifecycle, security, multi-window,
  persistence, formatter, warning, sanitizer, package-install, and local
  release-candidate checks.

## Upstream history

The local fork begins from `korkorran/owebview` at commit `e0c14ce`. Earlier
changes remain available in the preserved Git history. The vendored native
implementation remains webview 0.12; see `VENDORING.md`.
