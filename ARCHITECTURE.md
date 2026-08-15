# Owebview architecture

This document describes the implemented Phase 1 through Phase 9 architecture.
The longer-term product requirements are in [`DESIGN_SPEC.md`](DESIGN_SPEC.md).

## Layers

```text
Shared application protocol
  +-- owebview.protocol (native and JavaScript)

Native OCaml 5 + Eio                 js_of_ocaml frontend
  +-- owebview.app                     +-- owebview.jsoo
  +-- owebview.eio                      +-- JavaScript Promise API
  +-- owebview.webview                  +-- DOM application
           |                                      |
           +------- one versioned transport ------+
                              |
                         WebView 0.12
                              |
                WKWebView / WebKitWebView
```

## Managed native handle

`Webview.t` is an OCaml custom block containing a pointer to per-instance
`managed_webview` state. It records the native handle, lifecycle, UI owner,
active calls, bindings, dispatch callbacks, mutex, and close condition.

```text
created -> running -> stopped -> closing -> closed
```

The small closed state record remains alive until the OCaml custom block is
collected. Other Domains therefore receive a typed `Closed` error instead of
dereferencing freed memory. Native UI destruction is explicit; a finalizer never
destroys a live WebKit object from an arbitrary Domain.

Every exported C primitive passes through a C++ exception barrier. If an
exception bypasses an implementation's `CAMLreturn`, the barrier restores the
caller's OCaml local-root chain and raises a typed native error. Calls performed
with the OCaml runtime lock released reacquire it before an exception is
converted.

## Runtime lock and callbacks

`webview_run` and native destruction release the OCaml runtime lock. Native
callbacks reacquire it before touching OCaml values and drop local roots before
releasing it.

Callbacks use OCaml 5's `caml_result` API:

- Binding exceptions are contained and reject the JavaScript Promise.
- Dispatch exceptions are contained and logged.
- C++ exceptions cannot unwind through an OCaml or C callback boundary.
- Long-lived closures use generational global roots.
- Unbound native records remain allocated until destruction so queued WebKit
  callbacks cannot reference reclaimed user data.

## Thread ownership and Eio

The process main thread creates, runs, and destroys the native WebView. The Eio
application runs on a dedicated Domain.

```text
Main OS thread                         Eio Domain
  +-- WebView event loop                 +-- application switch
  +-- UI dispatch callbacks              +-- RPC and stream handlers
                                          +-- I/O and background fibers
```

`Webview_eio.call_ui` dispatches work and races its result against window close,
so a dispatch accepted during shutdown cannot leave a fiber suspended forever.
Closing the native loop resolves the close promise and cancels window-scoped
fibers. Setup, application, and UI callback exceptions preserve their original
backtraces.

Raw JavaScript bindings enqueue copied requests into a bounded, thread-safe
`Eio.Stream`. A fixed worker pool bounds active handlers. Queue overflow rejects
the JavaScript call on the UI thread without blocking it.

## Shared protocol

`owebview.protocol` depends only on portable OCaml and Yojson. It provides:

- Runtime-neutral codecs.
- Typed RPC and frontend endpoint descriptors.
- Typed event and stream descriptors.
- Versioned JSON envelopes.
- Structured RPC errors.
- Decimal-string `int64` identifiers and sequence numbers.

The same protocol module is compiled natively and by js_of_ocaml in the
integration suite. No `Marshal`, Eio, Unix, threads, or Lwt values cross the
frontend boundary.

## Multiplexed transport and RPC

The native runtime installs one private WebView binding. Envelopes are routed by
`kind` and endpoint name; individual RPC calls and streams do not create native
bindings.

The readiness handshake validates the protocol version and required transport
capabilities before normal traffic is accepted. It records the frontend build
and optional application version, then increments a frontend generation.
Reinstalling the js_of_ocaml receiver and handshaking again models frontend
reload without restarting the Eio application. A successful replacement
handshake rejects backend-to-frontend calls still pending against the previous
frontend generation.

Native RPC handlers run in Eio fibers. Requests have stable string IDs,
structured responses, and cancellation switches. Cancellation is recorded even
if it races ahead of handler registration. Backend-to-frontend requests are
close-aware and have a default timeout. Handler exceptions are logged with
native backtraces while release-facing protocol responses remain sanitized.
Typed one-way events use the same transport.

## Realtime streams

`Owebview_app.Stream.Server` owns application-runtime stream sessions. A session
contains typed codecs, count- and byte-bounded command/event/replay queues, a
monotonically increasing `int64` sequence, attachment state, and a retained
terminal state. The server also bounds total retained sessions.

```text
Agent fibers
  -> bounded session queue
  -> batching/coalescing fiber
  -> one UI dispatch per encoded batch
  -> js_of_ocaml stream model
```

Properties:

- Multiple sessions are multiplexed by stream ID.
- Commands receive acceptance acknowledgements or structured queue errors;
  application completion is reported as a typed event.
- Event order and duplicate suppression use sequence numbers.
- Frontends acknowledge the highest processed sequence.
- A replacement frontend can attach and resume after its last sequence.
- Replay outside the retained range returns `replay_unavailable`.
- Invalid future or negative acknowledgement/resume positions are rejected.
- Completed stream results remain attachable for a configurable grace period.
- Encoded batches have a configurable byte ceiling.
- Outgoing and replay storage have independent byte ceilings.
- Endpoint-specific typed coalescers can merge adjacent low-priority events.
- Endpoint-specific critical events can bypass the batching delay.
- Queue saturation returns `slow_subscriber` rather than blocking agent work.
- Detaching suppresses live delivery while preserving bounded replay state.
- Approval events, commands, and terminal results can remain uncoalesced by the
  endpoint's policy.

`Owebview_app.Durable_session` lifts streams above individual transports when
an application needs multi-window ownership or process-restart history. The
original bounded `Stream.Server` remains useful for transport-local streams.

## Application assets and security

`Owebview_app.Assets` has three source forms: an Eio directory, an embedded
bundle, or an existing development-server URI. Directory and embedded sources
are served by Cohttp-eio on an ephemeral IPv4 loopback port beneath a random
per-process token path.

```text
WebView
  -> http://127.0.0.1:<ephemeral>/<random-token>/index.html
       +-- restrictive CSP
       +-- exact MIME type
       +-- content ETag
       +-- no-sniff / no-referrer / same-origin resource policy
       +-- traversal-safe directory or embedded bundle
```

Production mode requires operating-system secure random bytes and never uses
`file://`. Development mode can inject a same-origin external reload script or
navigate to an existing frontend development server. The external script is
used instead of inline JavaScript so automatic reload works under the default
Content Security Policy.

Native navigation policy allows only configured application origins and
`about:blank` bootstrap by default. HTTP(S) navigation outside the trust set is
rejected or opened by the operating system. The private RPC binding captures
the browser's native top-level URL and independently checks its origin before
routing a request. Navigation and binding checks are intentionally separate.

The portable loopback origin is the current application-origin backend. A true
`app://` handler still requires platform-specific WebKit/WebView2 construction
hooks and remains an optional future platform extension.

## Desktop windows

`Webview_eio.t` represents either the primary window or a secondary window that
shares the primary native event loop and dispatcher. Secondary windows are
created on the UI thread and tied to an Eio switch.

Closing a secondary window is deliberately different from closing the primary:

```text
close request
  -> application close policy
     -> reject: keep window open
     -> allow: veto raw native close
        -> defer to a fresh native run-loop turn
        -> destroy managed WebView once
        -> emit close event and release window fibers
```

This avoids destroying an already-native-closed child, which would decrement
upstream's global window count twice. A separate UI-only `Webview.defer`
primitive provides the required fresh run-loop turn. The local Cocoa vendor
patch also skips upstream's destructor-time nested queue drain: that drain
dispatches a sentinel to the serial main queue and then waits for it from a
main-thread callback, so it can deadlock while another window keeps
`NSApplication` running. Cocoa dispatch callbacks carry a shared lifetime guard,
so callbacks still queued after destruction are discarded without touching the
freed engine. `NSWindow.close` is left to complete on the existing outer
application loop instead.

The desktop layer additionally provides visibility/focus/minimize/maximize/
fullscreen controls, position and size controls, native file and message
dialogs, native system-theme subscriptions, trusted console/error forwarding,
clipboard access where supported, and explicit permission and download policy
hooks. Download transfer progress and platform-native permission delegates
remain future platform extensions.

On Cocoa, dialogs are fully asynchronous sheets attached to the WebView's
owning `NSWindow`. Starting a dialog schedules presentation onto a fresh native
main-queue turn and returns immediately; only the requesting Eio fiber waits on
the completion promise. No `runModal` call, polling loop, or nested
`CFRunLoopRunInMode` is used. One dialog may be active per window. Completion,
user cancellation, fiber cancellation, and window closure are exactly-once
terminal paths with rooted OCaml callbacks and retained Cocoa presenters.
Closing a window with an attached sheet first settles and dismisses the dialog,
then retries the close on a clean main-queue turn.

## Platform selection and capabilities

Build discovery no longer treats every non-macOS target as Linux. It recognizes
macOS, Linux, and Windows explicitly. Linux probes GTK4/WebKitGTK 6.0 first,
then GTK3/WebKitGTK 4.1, then optional 4.0. The selected backend is compiled
into the native binding and exposed through `Owebview_app.Platform` together
with an explicit capability set and validation status.

The capability set is intentionally conservative. For example, GTK4 does not
claim the synchronous GTK3 dialog API, and Windows does not claim owebview's
desktop extensions until they are implemented and tested there.

## Durable application sessions

`Owebview_app.Durable_session` introduces ownership above a window transport:

```text
Application switch
  +-- durable registry
      +-- stable session ID
          +-- encoded event history
          +-- lifecycle and terminal state
          +-- durable command payloads and status
          +-- durable subscriber acknowledgement cursors
          +-- orchestration fiber
          +-- subscriber A: bounded queue + batching fiber + transport
          +-- subscriber B: bounded queue + batching fiber + transport
```

Events are persisted before their sequence becomes visible or they are
broadcast. Command IDs, encoded payloads, and initial `Admitted` status are
persisted before admission to the orchestration queue. Applications then mark
commands `Applied` or `Rejected`; an `Admitted` command found after a crash is
an explicit reconciliation case. Acknowledgement cursors are persisted before
their live cursor advances. Delivery is at least once; the frontend
deduplicates events by stable session ID and sequence, while the registry
deduplicates commands by stable command ID and rejects payload conflicts.

Live delivery is isolated per subscriber. Session producers only append to a
subscriber's bounded count/byte queue; a subscriber-specific fiber batches and
dispatches those events. Queue overflow or transport failure detaches that
subscriber without delaying another window or terminating the session.
Application authorization callbacks gate listing, opening, attachment,
commands, and cancellation.

Directory persistence writes a complete versioned JSON snapshot to a temporary
file, flushes it, calls `fsync`, atomically renames it into place, and syncs the
containing directory. The interface remains application-supplied so a
framework can replace snapshots with SQLite or an external service.

At restart, terminal sessions retain their history and terminal result.
Persisted `Running` or `Recovering` sessions become `Interrupted`. Live OCaml
fibers and frontend Promises are never claimed to survive process termination;
`retry` creates a new run from the persisted request while preserving the
interrupted history. Each session also has an opaque JSON checkpoint slot for
an orchestrator checkpoint or external run ID. True continuation still
requires application-specific reconciliation around that data.

Commands restored in `Admitted` state are exposed through registry-level
reconciliation APIs because an external effect may have completed immediately
before the process died. Non-running sessions can be deleted explicitly or
compacted by age and retained-history count.

The `examples/agent_stream` application exercises this architecture as a
complete desktop experience. Its shared protocol models run metadata, phases,
plans, safe activity summaries, tools, progress, usage, approvals, live
instructions, artifacts, checkpoints, incremental text, commands, and typed
terminal results. A secure embedded js_of_ocaml application renders the same
durable event stream in a conversation window and inspector windows. It adds
native clipboard/export RPC, platform capability reporting, explicit
permission/download denial, subscriber authorization, and a deterministic
autoplay mode used for local end-to-end verification.

## Libraries

- `lib/dune`: `owebview.webview` and C++ stubs.
- `lib/eio`: `owebview.eio`.
- `lib/protocol`: `owebview.protocol`.
- `lib/app`: `owebview.app`.
- `lib/jsoo`: `owebview.jsoo`.
- `vendor/webview.h`: upstream amalgamated native implementation.

## Verification

`dune build @integration` covers:

- Wrong-Domain rejection and cross-thread termination.
- Idempotent close and deterministic closed-handle errors.
- Major GC and compaction while callbacks remain rooted.
- Binding and dispatch exception containment.
- 1,000 cross-Domain dispatch callbacks.
- Repeated create/run/destroy cycles and bind/unbind reclamation.
- Setup, application, and UI-dispatch failure propagation.
- Close/dispatch races and Eio switch cancellation.
- UI heartbeat responsiveness during long Eio work.
- Bounded request queue overload.
- A real js_of_ocaml bundle sharing endpoint definitions with native OCaml.
- Handshake compatibility and traffic gating, generations, typed RPC
  cancellation, frontend RPC, reload rejection, close rejection, and events.
- Simultaneous streams, batching, coalescing, command acknowledgement,
  count/byte limit handling, terminal retention, replay exhaustion, sequence
  validation, slow-subscriber handling, and reload-style resume.
- Embedded production asset loading, native trusted-origin rejection, and
  CSP-compatible development reload execution in a real WebKit page.
- Secondary-window close veto and acceptance, switch-owned teardown, repeated
  child creation/destruction, and continued primary-window dispatch.
- Durable recovery across two operating-system processes, interrupted-run
  classification, checkpoints, admitted-command reconciliation, retention,
  compaction, and persistence-before-visibility ordering.
- Two real WebKit windows attached to one session with independent replay,
  authorization, command deduplication, and continued execution after one
  window closes.
- Per-window bounded delivery queues that detach a deliberately slow subscriber
  without delaying a fast subscriber or closing either native window.

On the current macOS OCaml 5.3 toolchain, the single-Domain callback smoke test
passes with AddressSanitizer and UndefinedBehaviorSanitizer. The full
Domain-concurrency test passes with UndefinedBehaviorSanitizer. AddressSanitizer
cannot run Domain teardown because a minimal OCaml program that only spawns and
joins a Domain aborts in AddressSanitizer's memory-unmap logic. Linux lifecycle
and full Domain ASan validation are explicitly deferred until a Linux test
machine is available.

On Cocoa, modal panels and AppKit's standard titlebar button tracking can install
Objective-C exception handlers while the native event loop is still nested
under an OCaml stack frame. On the supported OCaml 5/macOS toolchain, libunwind
can fault while constructing that handler. Dialogs therefore use asynchronous
window-attached sheets without a nested event loop. Immediately before
the native event loop starts, the final system-drawn fullscreen button instance
receives a small per-instance subclass whose `mouseDown:` defers the window
action onto a clean main-queue turn. The traffic-light appearance remains
AppKit-owned, but a physical fullscreen click no longer enters
`NSControlTrackMouse` through the OCaml-owned event-loop stack.

Phase 9 adds reproducible local formatter, warning, sanitizer, package-install,
matrix, backup, and release-candidate scripts. Compatibility, migration,
security, platform, vendor, contribution, and release policies are versioned in
the repository. These artifacts do not create hosted CI or authorize remote
publication.
