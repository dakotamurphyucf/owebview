# owebview

`owebview` is an opinionated OCaml 5 desktop application runtime built on the
platform WebView. OCaml and Eio own application state and native work; a
js_of_ocaml application owns the HTML frontend.

Implemented locally:

- Managed OCaml 5 native handles, typed errors, lifecycle checks, and safe
  callbacks.
- A main-thread WebView loop with Eio application fibers on a dedicated Domain.
- Bounded JavaScript binding queues and bounded handler concurrency.
- Pure shared protocol definitions, JSON codecs, and a compatibility-enforced
  frontend handshake.
- Promise-based js_of_ocaml RPC without Lwt.
- Backend-to-frontend RPC and typed one-way events.
- Multiplexed realtime streams with typed commands and terminal results.
- Sequence numbers, acknowledgements, retained terminal results, replay,
  reload-style resume, batching, coalescing, cancellation, and count- and
  byte-bounded slow-subscriber behavior.
- Embedded, directory, and development-server assets served without
  `file://`, with a tokenized loopback origin, MIME/CSP/cache headers, and
  development reload.
- Trusted-origin transport enforcement and native navigation policy.
- Managed multiple windows, close interception, window controls, native
  dialogs, theme observation, console/error forwarding, and explicit download
  and permission policy hooks.
- Explicit Cocoa, GTK4/GTK3, and WebView2 target selection with conservative
  runtime capability reporting.
- Application-owned durable sessions with multi-window replay, persisted
  acknowledgement cursors, bounded per-window delivery, authorization, durable
  command reconciliation, retention, interrupted-run retry, and
  completed-history recovery.

The full product direction is in [`DESIGN_SPEC.md`](DESIGN_SPEC.md).

Release and maintenance documentation:

- [`COMPATIBILITY.md`](COMPATIBILITY.md): pre-1.0 and intended 1.0 API, wire,
  persistence, and deprecation policy.
- [`SECURITY.md`](SECURITY.md): browser/native trust boundary and application
  responsibilities.
- [`MIGRATION.md`](MIGRATION.md): migration from the upstream thin binding.
- [`VALIDATION_MATRIX.md`](VALIDATION_MATRIX.md): prepared and actually
  validated platform/compiler cells.
- [`RELEASING.md`](RELEASING.md): local-only release candidate procedure.
- [`CHANGES.md`](CHANGES.md): local fork changelog.
- [`CONTRIBUTING.md`](CONTRIBUTING.md): project scope and local workflow.

## Libraries

| Library | Purpose |
| --- | --- |
| `owebview.webview` | Managed low-level native binding |
| `owebview.eio` | Main-thread UI and Eio lifecycle |
| `owebview.protocol` | Runtime-neutral codecs, endpoints, envelopes, and errors |
| `owebview.app` | Native Eio transport, RPC server, events, and streams |
| `owebview.jsoo` | Promise-based js_of_ocaml client |

Runtime backend and feature support is documented in
[`PLATFORM_SUPPORT.md`](PLATFORM_SUPPORT.md).

## Requirements

- OCaml 5.3 or newer.
- Dune 3.0 or newer.
- Eio 1.3 or newer.
- Cohttp-eio 6.0 or newer.
- Uri 4.4 or newer.
- Magic-mime 1.3 or newer.
- Yojson 3.0 or newer.
- js_of_ocaml 6.4 or newer. Version 6.4 supplies the non-Lwt, type-safe Promise
  API used by `owebview.jsoo`.
- macOS: Cocoa and WebKit system frameworks.
- Linux: GTK4/WebKitGTK 6.0, or GTK3/WebKitGTK 4.1/4.0 development packages.

macOS is the currently validated development platform. Linux support remains in
the build configuration but lifecycle validation is deferred until a Linux test
machine is available. Windows/WebView2 is recognized as a distinct build target,
but its owebview-specific desktop extensions are not yet implemented or
validated.

## Build and test

```sh
dune build @all @runtest @doc @integration
opam lint owebview.opam
```

Or run the local verification script:

```sh
scripts/check-local.sh
```

Sanitizers and the current machine's complete matrix cell are explicit:

```sh
scripts/check-sanitizers.sh
scripts/check-matrix.sh current
```

`scripts/check-matrix.sh list` shows prepared cells without claiming that an
unavailable machine or compiler has been validated.

The integration alias opens short-lived graphical WebViews. It exercises the
native lifecycle, Domains, Eio cancellation, overload handling, handshake
compatibility, typed RPC, an actual js_of_ocaml bundle, simultaneous streams,
coalescing, terminal recovery, and resume.
It also exercises production/development assets, trusted-origin rejection, and
secondary-window close and teardown behavior, native theme notification,
durable multi-window attachment, command deduplication, persisted subscriber
acknowledgements, slow-subscriber isolation, authorization, and restart
recovery across separate operating-system processes.

## Eio application runtime

The native UI loop stays on the process main thread. Eio runs on a dedicated
Domain, and UI operations marshal through `Webview_eio.call_ui`:

```ocaml
let () =
  Webview_eio.run
    ~setup:(fun webview ->
      Webview.set_title webview "My application";
      Webview.set_html webview "<main id='app'></main>")
    (fun ~env:_ ~sw app ->
      Webview_eio.bind ~sw app "ping" (fun ~id ~request:_ ->
          Webview_eio.respond app ~id ~error:false ~result:{|"pong"|});
      Webview_eio.await_closed app)
```

Bindings use a bounded queue and worker pool. Additional calls are rejected
without blocking the UI thread when the configured queue is full.

## Shared typed protocol

Endpoint definitions contain no Eio, Unix, or js_of_ocaml dependencies and can
therefore be compiled into both halves of an application:

```ocaml
module P = Owebview_protocol

let echo =
  P.Endpoint.make ~name:"app.echo" ~request:P.Codec.string
    ~response:P.Codec.string

let tokens =
  P.Stream_endpoint.make ~name:"agent.run" ~request:P.Codec.string
    ~event:P.Codec.string ~command:P.Codec.string
    ~result:P.Codec.string
```

The native side creates one multiplexed transport and registers handlers:

```ocaml
let transport =
  Owebview_app.Transport.create ~sw
    ~now:(fun () -> Eio.Time.now env#clock)
    ~sleep:(Eio.Time.sleep env#clock) app

let rpc = Owebview_app.Rpc.Server.create transport

let _subscription =
  Owebview_app.Rpc.Server.handle rpc Protocol.echo (fun request ->
      Ok ("echo:" ^ request))
```

The js_of_ocaml side uses JavaScript Promises and does not depend on Lwt:

```ocaml
let client = Owebview_jsoo.create ()
let () = Owebview_jsoo.install client

let ready = Owebview_jsoo.ready ~frontend_build_id:"my-app" client
```

The native transport rejects RPC and stream traffic until a compatible
handshake succeeds. Applications normally begin their Promise workflow with
`ready`, then issue typed calls such as
`Owebview_jsoo.Rpc.call client Protocol.echo "hello"`.

## Realtime streams

Streams are multiplexed over the same private binding. Each session has:

- A typed opening request.
- Ordered, `int64`-sequenced events.
- Count- and byte-bounded outgoing queues and replay buffers.
- Typed commands with queue-admission acknowledgements.
- A typed terminal result.
- Cancellation, true detach, and reload-style attach/resume.
- Configurable session limits, terminal retention, flush interval, encoded
  batch limit, critical-event flushing, and typed coalescing.

See [`examples/agent_stream`](examples/agent_stream) for a js_of_ocaml frontend
presented as a polished native agent workspace. It streams phases, plans,
structured activity, tool progress, usage telemetry, approvals, artifacts, and
answer text into independently replayable conversation and inspector windows.
It also demonstrates pause/resume/cancel, live instructions, stable approval
commands, native clipboard/export actions, platform capability reporting, and
completed-history replay after process restart.

## Assets and desktop windows

`Owebview_app.Assets` serves packaged content from a random, process-local
loopback origin. Production mode fails if secure random bytes are unavailable;
it never falls back to `file://`. `Owebview_app.Navigation` allows only trusted
application origins by default and delegates or rejects external HTTP(S) URLs.

`Owebview_app.Window` adds Eio-owned secondary windows and application-oriented
controls. Secondary close requests are converted into one managed native
destruction step, so closing a child does not stop the primary event loop.
See [`examples/desktop_app`](examples/desktop_app) for embedded assets, multiple
windows, native dialogs, theme queries, and trusted console forwarding.

## Durable shared sessions

`Owebview_app.Durable_session` owns long-lived streams above individual window
transports. Multiple windows can attach to the same stable session ID with
independent replay and acknowledgement positions. Command IDs, payloads, and
`Admitted`/`Applied`/`Rejected` status are durable and deduplicated across
windows. Reusing an ID for a different payload is rejected. Each window has an
independent bounded delivery queue and batching fiber, so a slow window is
detached without blocking the session or other windows.

Persistence is application-supplied. The library includes in-memory and atomic
directory-backed stores; a future framework can provide SQLite or another
database using the same interface. On restart, completed history is restored
and sessions persisted as running are deterministically classified as
`Interrupted`. `Durable_session.retry` starts a new run from an interrupted
session's persisted request while preserving the original history. True
continuation still requires orchestration-specific durable checkpoints and
side-effect reconciliation.

Registry-level reconciliation APIs expose commands left `Admitted` across a
crash. Authorization hooks can gate listing, opening, attachment, commands, and
cancellation. Non-running histories can be deleted or compacted by age and
retained count.

## Low-level API

`Webview.t` is a managed custom block rather than a raw pointer. `destroy` is
idempotent, and calls after destruction raise `Webview.Error` with code
`Closed`. UI operations enforce owner-thread affinity. The documented
cross-thread operations are `dispatch`, `return`, and `terminate`.

## Local fork policy

This repository is a local fork under active development. Branches, commits,
tags, tests, and release candidates remain local. Nothing is pushed, submitted,
or published until the owner explicitly opens the maturity gate in
`DESIGN_SPEC.md`.

The existing upstream remote is reference-only and must not be used for pushes.

Local release candidates are created beneath ignored `_build/local-release`
with `scripts/make-local-release.sh VERSION`. This tooling never tags, pushes,
uploads, publishes, or submits to opam. Because the repository intentionally has
no writable remote, `scripts/backup-local.sh` can create a Git bundle plus an
archive of important untracked files on separate local storage.

## License and lineage

The project retains the upstream history and MIT license. The vendored
`webview.h` is from upstream `webview` 0.12. Provenance and the vendor update
policy are documented in [`VENDORING.md`](VENDORING.md).
