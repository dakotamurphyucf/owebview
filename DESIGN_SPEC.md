# Owebview: OCaml 5 Desktop Application Runtime

Status: Draft design specification  
Date: August 12, 2026  
Target milestone: first production-oriented OCaml 5 release  

Implementation status as of August 12, 2026:

- Phase 1 is implemented and validated on macOS, subject to the documented
  OCaml Domain/AddressSanitizer limitation.
- Phase 2 is implemented and validated on macOS. Linux lifecycle validation is
  deliberately deferred until a Linux test machine is available.
- Phase 3 is implemented and closed on macOS with a shared protocol library,
  native Eio RPC, Promise-based js_of_ocaml RPC, compatibility-enforced
  readiness generations, frontend calls, events, structured errors,
  cancellation, reload rejection, and close-aware pending requests.
- Phase 4 is implemented and closed on macOS with multiplexed streams,
  count- and byte-bounded queues, active-session limits, batching, typed
  coalescing, immediate critical-event flushing, sequence numbers,
  acknowledgements, command admission replies, cancellation, replay,
  retained terminal results, reload-style resume, and slow-subscriber handling.
- Phase 5 is implemented and validated on macOS with tokenized loopback
  application origins, embedded and directory asset sources, development
  reload, MIME/CSP/cache headers, native navigation policy, and trusted-origin
  enforcement at privileged bindings.
- Phase 6 is implemented and validated on macOS for the scoped desktop
  baseline: managed multiple windows, close interception, lifecycle events,
  window controls, native dialogs, theme observation, console forwarding, and
  explicit download and permission policy hooks.
- Phase 7 is implemented for the locally achievable platform-modernization
  scope: explicit OS target detection, GTK4/WebKitGTK 6.0 preference with
  GTK3 fallbacks, Windows target recognition, runtime backend/capability
  reporting, native clipboard access, and platform packaging guidance. Cocoa
  is validated; Linux and Windows remain compiled-but-unvalidated targets.
- Phase 8 is implemented and validated on macOS with an application-owned
  durable session registry, stable session and command IDs, per-window replay
  and durable acknowledgement cursors, command payload/status persistence,
  independent bounded subscriber delivery, command deduplication, attachment
  authorization, opaque orchestration checkpoints, retention/compaction,
  application-supplied persistence, completed-history recovery across separate
  operating-system processes, interrupted-run classification, admitted-command
  reconciliation, and explicit retry-as-a-new-run behavior.
- The repository remains local-only; none of this status authorizes remote
  publication.

This document defines the intended direction of `owebview`. It consolidates the
runtime, API, frontend, streaming, security, platform, testing, and release
requirements for evolving the current binding skeleton into a mature foundation
for native desktop applications written in OCaml.

The APIs in this document are provisional. The architectural constraints,
ownership rules, and protocol semantics are intended to be normative even where
exact module or function names change during implementation.

## 1. Executive summary

`owebview` will be an opinionated OCaml 5 desktop application runtime built on
the system WebView:

- OCaml owns application state, business logic, filesystem access, networking,
  persistence, agent orchestration, and native integration.
- An HTML/CSS frontend renders inside the platform WebView.
- The preferred frontend is OCaml compiled to JavaScript with js_of_ocaml.
- Eio is the only supported native concurrency runtime.
- The native and frontend halves share pure OCaml protocol definitions.
- Typed request/response RPC and bidirectional realtime streams are first-class
  features.
- The default security model assumes packaged application content, not general
  web browsing.
- A future higher-level application framework will build on this library, but
  UI components, routing, state-management conventions, and project scaffolding
  are outside the initial binding library.

The project is not intended to expose every method in WebKit, WebKitGTK, and
WebView2 behind one flattened API. It will provide:

1. A safe cross-platform application API.
2. A typed OCaml/JavaScript transport.
3. A focused set of desktop-oriented browser and window features.
4. Explicit platform escape hatches for advanced native capabilities.

## 2. Goals

### 2.1 Primary goals

- Be safe and predictable under OCaml 5 Domains.
- Provide deterministic native resource ownership.
- Keep the UI event loop responsive.
- Integrate cleanly with Eio structured concurrency and cancellation.
- Make js_of_ocaml the preferred frontend toolchain.
- Share types and endpoint definitions between native and frontend OCaml.
- Support typed RPC in both directions.
- Support long-lived, bidirectional, realtime streaming sessions.
- Support agent and LLM workloads, including incremental text, tool calls,
  approvals, commands, cancellation, replay, and reconnect.
- Provide secure application asset loading and navigation defaults.
- Support multiple windows and long-lived application-scoped services.
- Provide useful diagnostics, logging, testing, and release tooling.
- Support macOS and Linux initially, with Windows/WebView2 as a planned target.

### 2.2 Product goal

The desired application model is:

```text
Native executable
  |
  +-- OCaml 5 + Eio
  |     +-- application state
  |     +-- database and filesystem
  |     +-- networking
  |     +-- background jobs
  |     +-- agent orchestration
  |     +-- typed RPC and streams
  |
  +-- platform WebView
        +-- HTML and CSS
        +-- js_of_ocaml application
        +-- DOM and frontend state
        +-- typed client transport
```

The WebView is an application renderer and interaction surface. It is not the
owner of application logic.

## 3. Non-goals

The initial project will not attempt to provide:

- Lwt support or a Lwt compatibility package.
- A complete direct binding to every native WebKit API.
- A browser intended for arbitrary, untrusted web navigation.
- A UI component library or virtual DOM.
- A router or frontend state-management framework.
- A JavaScript or TypeScript bundler.
- CSS processing.
- Database conventions.
- Application auto-update infrastructure.
- A framework CLI or project generator.
- Transparent migration of arbitrary browser applications into desktop apps.

These may be supplied by a future framework or separate packages.

## 4. Design principles

### 4.1 Safety before feature count

No browser feature should be added at the cost of unresolved lifetime, callback,
or Domain-safety problems. Runtime hardening is the first milestone.

### 4.2 Structured ownership

Every window, binding, stream, subscription, request, and background operation
must have an explicit owner and cleanup path. Eio switches should own high-level
resources. Native reference counting and lifecycle state should protect the C++
boundary.

### 4.3 One native UI owner

Platform UI objects are owned by the UI thread. Other Domains communicate with
that thread through explicit queues and dispatch operations.

### 4.4 Typed at the application boundary

JSON is a wire format, not the application API. Native and frontend code should
normally exchange typed OCaml values through shared endpoint definitions.

### 4.5 Transport independence

Application protocols must not depend directly on a WebView. The same protocol
should be usable with:

- The embedded native WebView transport.
- A WebSocket development transport.
- In-process test transports.
- Potential future remote clients.

### 4.6 Secure application defaults

Bindings should be available only to trusted application content by default.
Remote navigation, new windows, permissions, downloads, and external URL access
must be explicit policy decisions.

### 4.7 Backend capability honesty

When a platform cannot provide a feature, return `Unsupported`; do not silently
do nothing.

## 5. Package and module architecture

The repository should ultimately produce three principal libraries.

### 5.1 `owebview-protocol`

A pure OCaml library compiled both natively and with js_of_ocaml.

It contains:

- Codec interfaces.
- Protocol envelopes.
- Typed RPC endpoints.
- Typed stream endpoints.
- Shared error types.
- Version negotiation types.
- No Eio dependency.
- No js_of_ocaml dependency.
- No Unix or native FFI dependency.

### 5.2 `owebview`

The native OCaml 5 and Eio application runtime.

It contains:

- Application lifecycle.
- Window lifecycle.
- Eio integration.
- Native bindings.
- RPC server implementation.
- Stream server implementation.
- Asset serving.
- Navigation and security policy.
- Native dialogs and desktop-oriented platform features.

Eio is a normal dependency, not an optional adapter.

### 5.3 `owebview-jsoo`

The js_of_ocaml frontend client.

It contains:

- Promise-based RPC clients.
- Promise-based streaming clients.
- Event subscriptions.
- Frontend readiness and handshake support.
- Cancellation support.
- A wrapper around the injected JavaScript transport.
- No Lwt dependency.

### 5.4 Raw and platform APIs

The native package may additionally expose:

```text
Owebview.Raw
Owebview.Platform
Owebview.Unsafe
```

`Raw` closely mirrors the upstream C API. `Platform` exposes typed backend
capabilities. `Unsafe` contains raw native handles. These modules are not the
recommended application API and may have weaker compatibility guarantees.

## 6. Proposed repository layout

```text
lib/
  protocol/
    codec.ml
    error.ml
    envelope.ml
    endpoint.ml
    stream_endpoint.ml

  native/
    app.ml
    window.ml
    request.ml
    binding.ml
    subscription.ml
    rpc.ml
    stream.ml
    assets.ml
    navigation.ml
    platform.ml

  jsoo/
    app.ml
    rpc.ml
    stream.ml
    events.ml
    transport.ml

native/
  runtime/
    handle.hpp
    callback.hpp
    queue.hpp
    error.hpp

  core/
    webview_stubs.cpp

  macos/
    webkit_stubs.cpp

  linux/
    webkitgtk_stubs.cpp

  windows/
    webview2_stubs.cpp

test/
  unit/
  domains/
  protocol/
  integration/

examples/
  minimal/
  jsoo_rpc/
  agent_streaming/
  multiple_windows/
```

The existing `Webview.Utils.web_dir` helper should move out of the core API. Its
purpose will be replaced by a general asset abstraction.

## 7. OCaml version policy

The recommended minimum compiler version is OCaml 5.3.

Reasons:

- The project is intentionally designed around OCaml 5.
- `caml_result` provides a safer callback exception interface.
- Supporting OCaml 4 would complicate runtime and CI requirements without
  serving the project goal.

The initial CI matrix should cover OCaml 5.3, 5.4, and 5.5. A compatibility shim
for OCaml 5.0 through 5.2 may be considered only if there is demonstrated user
demand and it does not weaken the runtime design.

## 8. Native runtime architecture

### 8.1 Thread and Domain model

On macOS, the Cocoa/WebKit event loop must remain on the process main thread.
The intended high-level architecture is therefore:

```text
Process main OS thread
  +-- Cocoa/GTK/WebView event loop
  +-- native UI task queue
  +-- minimal OCaml callbacks that enqueue work

Eio application Domain
  +-- Eio_main runtime
  +-- application fibers
  +-- RPC handlers
  +-- stream handlers
  +-- networking and filesystem
  +-- agent orchestration
```

The feasibility and shutdown behavior of running the Eio runtime on a dedicated
Domain must be validated early on macOS and Linux.

### 8.2 No Eio effects in native callbacks

Callbacks entered from WebKit do not execute under the Eio effect handler. They
must not directly run application fibers or perform Eio operations that may
suspend.

A UI callback must:

1. Acquire the correct OCaml runtime state.
2. Copy native request data into owned memory.
3. Enqueue a plain message into a thread-safe bridge queue.
4. Wake the Eio Domain.
5. Return immediately to the UI event loop.

The bridge should use a native multi-producer queue or a mutex-protected queue
with a cross-platform wakeup mechanism. The callback must never block waiting
for application work.

### 8.3 UI command path

Calls originating from Eio application fibers use the reverse path:

```text
Eio fiber
  -> enqueue UI command
  -> schedule native UI dispatch
  -> UI thread executes command
  -> result is placed on response queue
  -> Eio fiber resumes
```

Operations documented as thread-safe by the underlying WebView, such as
termination and binding responses, may use a shorter path but must still validate
the managed handle state.

### 8.4 Managed native handle

`Webview.t` must no longer be only a boxed `nativeint`. It should reference a
native state structure similar to:

```cpp
enum class lifecycle {
  created,
  running,
  stopped,
  closing,
  closed
};

struct ocaml_webview {
  webview_t native;
  std::thread::id owner_thread;
  std::mutex mutex;
  lifecycle state;
  binding_registry bindings;
  dispatch_registry dispatches;
  request_registry requests;
};
```

Required properties:

- `close` and `destroy` are idempotent.
- Every operation rejects a closed handle.
- UI-only operations check thread ownership.
- Pending callbacks keep native state alive.
- Destruction waits for or safely cancels pending native work.
- Raw native pointers are never the sole ownership record.
- The OCaml finalizer does not directly destroy UI objects from an arbitrary
  Domain.

### 8.5 Lifecycle states

The public lifecycle is:

```text
Created -> Running -> Stopped -> Closing -> Closed
```

Rules:

- A window may run at most once unless the native backend explicitly supports a
  safe restart.
- Closing from a worker Domain schedules close on the UI thread.
- Calls submitted during `Closing` fail with `Closed` or `Closing`.
- All pending frontend requests are rejected during close.
- Window-scoped fibers are cancelled during close.
- Application-scoped services may survive a window closing.

### 8.6 Callback safety requirements

All native-to-OCaml callbacks must:

- Acquire the OCaml runtime before touching OCaml values.
- Register foreign-created native threads when required.
- Establish local roots while the runtime lock is held.
- Use `caml_result` callback functions.
- Convert callback exceptions into structured errors or logging events.
- Drop local roots before releasing the runtime.
- Never allow OCaml exceptions to jump through C++ frames.
- Never retain an unrooted OCaml value in native memory.

Every exported `extern "C"` function must catch C++ exceptions and convert them
to typed OCaml errors.

### 8.7 Per-instance callback bookkeeping

The current process-global binding map must be replaced by per-instance state.
Binding and dispatch records must be reference-counted or otherwise protected
until no queued native callback can reference them.

Unbinding should:

1. Mark the binding inactive.
2. Remove it from the JavaScript-visible method table.
3. Prevent new requests.
4. Reject or cancel pending requests according to policy.
5. Defer native record reclamation until queued callbacks are drained.
6. Remove the OCaml global root exactly once.

## 9. Error model

Generic `Failure` exceptions are insufficient. The native API should expose a
typed error:

```ocaml
module Error : sig
  type code =
    | Missing_dependency
    | Canceled
    | Invalid_state
    | Invalid_argument
    | Duplicate
    | Not_found
    | Closed
    | Closing
    | Wrong_thread
    | Unsupported
    | Protocol_error
    | Transport_error
    | Native_error of int

  type t = {
    operation : string;
    code : code;
    message : string;
  }

  exception E of t
end
```

Expected failures should use `result`. An `Exn` compatibility module may provide
raising wrappers.

Native errors must include:

- The failed operation.
- The upstream error code.
- A readable message.
- Platform/backend context when useful.

## 10. Application and window API

### 10.1 Application entry point

A provisional application API is:

```ocaml
val App.run :
  initial_window:Window.config ->
  (env:Eio.Stdenv.t -> App.t -> Window.t -> unit) ->
  unit
```

The runtime should:

- Create the initial native window on the main thread.
- Start the Eio application Domain.
- Run the platform event loop on the main thread.
- Coordinate normal shutdown and exceptional shutdown.
- Wait for application cleanup before final native destruction.

The first stable version may require an initial window. Dynamic creation of
additional windows can be added once the main-thread dispatch architecture is
proven.

### 10.2 Window configuration

```ocaml
type Window.config = {
  title : string;
  width : int;
  height : int;
  min_size : size option;
  max_size : size option;
  resizable : bool;
  debug : bool;
  background : color option;
  assets : Assets.source;
  navigation : Navigation.policy;
}
```

### 10.3 Window ownership

```ocaml
val Window.create :
  sw:Eio.Switch.t ->
  App.t ->
  Window.config ->
  (Window.t, Error.t) result

val Window.close : Window.t -> (unit, Error.t) result
val Window.await_closed : Window.t -> unit
val Window.is_closed : Window.t -> bool
```

`Window.create ~sw` ties the high-level window resource to an Eio switch.
Closing the switch requests orderly window shutdown. Closing the window cancels
its window-scoped fibers.

### 10.4 Thread-safe versus UI-only operations

The public documentation must classify every operation.

Thread-safe examples:

- Request close or termination.
- Respond to a frontend request.
- Emit a frontend event.
- Enqueue a UI command.

UI-owned examples:

- Direct native handle access.
- Mutating native WebKit objects.
- Creating or destroying native views.

Application code should normally use Eio-aware wrappers that marshal UI-owned
operations automatically.

## 11. Desktop application features

The initial common feature set should prioritize native application use cases:

- Window title, size, position, visibility, and focus.
- Minimize, maximize, restore, fullscreen, and close.
- Application/window icon.
- Close interception for unsaved state.
- Background color and transparency where supported.
- Frontend load and ready lifecycle.
- Development reload.
- Developer tools in debug mode.
- Console and JavaScript error forwarding.
- File open/save and directory dialogs.
- Clipboard integration.
- Drag and drop.
- Download policy and progress.
- System theme notification.
- Multiple windows.
- External URL opening policy.
- Navigation policy.
- Permission requests.

Traditional browser capabilities such as detailed arbitrary history inspection
are lower priority unless required by application use cases.

## 12. Asset system

Asset handling is in scope because the library targets packaged applications.

```ocaml
type Assets.source =
  | Directory of Eio.Path.t
  | Embedded of Assets.bundle
  | Development_server of Uri.t
```

### 12.1 Production assets

The implemented portable backend loads production content from a
cryptographically tokenized HTTP origin bound only to an ephemeral IPv4
loopback port. The token is generated independently for each application run,
and application navigation is restricted to the resulting origin. This gives
the WebView normal HTTP origin semantics without granting `file://` privileges
or exposing the server on an external interface.

A future platform layer may replace this with an `app://` origin backed by a
platform custom-scheme implementation:

- macOS: `WKURLSchemeHandler`.
- Linux: WebKitGTK URI scheme registration.
- Windows: WebView2 resource interception and generated responses.

The asset layer should provide:

- Correct MIME types.
- Content hashes.
- Optional compression metadata.
- Content Security Policy headers.
- Cache behavior.
- An index document.
- A generated manifest.
- A safe not-found response.

The current implementation also rejects path traversal and symlink traversal,
uses content-derived ETags, sends `nosniff`, same-origin resource policy, and a
no-referrer policy, and requires secure random token generation in production.
The loopback backend is intentional while upstream WebView 0.12 does not offer
a portable construction-time hook for installing platform scheme handlers.

### 12.2 Development assets

Development mode may load from:

- Dune build output.
- A watched directory.
- A local frontend development server.

The backend should support automatic reload when frontend output changes.

The implemented development mode polls a revision endpoint through a separate
same-origin script, so the reload helper remains compatible with the default
`script-src 'self'` Content Security Policy. `Development_server` can instead
point the window at an existing absolute HTTP(S) frontend server.

### 12.3 Asset build modes

```text
Development
  - source maps enabled
  - developer tools enabled
  - assets read from build output
  - automatic reload
  - verbose frontend and RPC errors

Release
  - optimized js_of_ocaml output
  - content-hashed assets
  - embedded or packaged bundle
  - developer tools disabled
  - sanitized frontend errors
```

## 13. js_of_ocaml frontend architecture

### 13.1 No frontend Lwt requirement

The frontend should use JavaScript Promises through js_of_ocaml. It should not
depend on `js_of_ocaml-lwt`.

The frontend library should expose Promise-based APIs and synchronous event
subscriptions.

### 13.2 Shared protocol package

An application should be structured as:

```text
app_protocol
  +-- data types
  +-- codecs
  +-- RPC endpoints
  +-- stream endpoints
  +-- event definitions

backend
  +-- native compilation
  +-- Eio handlers

frontend
  +-- js_of_ocaml compilation
  +-- Promise clients
  +-- DOM rendering
```

Shared protocol code must avoid assumptions that differ between native and
JavaScript runtimes. In particular:

- Do not use `Marshal` across the boundary.
- Do not use plain `int` for identifiers that may exceed 31 bits.
- Encode `int64` values explicitly, normally as decimal strings in JSON.
- Avoid Unix, threads, Eio, and js_of_ocaml APIs in shared modules.
- Use explicit, stable tagged encodings for variants.

### 13.3 Frontend build

A frontend executable should be buildable with conventional Dune configuration:

```lisp
(executable
 (name main)
 (modes js)
 (libraries
  js_of_ocaml
  owebview-jsoo
  app_protocol)
 (preprocess
  (pps js_of_ocaml-ppx)))
```

The framework may later generate these stanzas, but `owebview` should work with
normal Dune projects.

### 13.4 Frontend readiness

Document load completion is not equivalent to application readiness.

```ocaml
type frontend_state =
  | Loading
  | Document_loaded
  | Runtime_loaded
  | Ready
  | Disconnected
  | Failed of frontend_error
```

The js_of_ocaml entry point should call:

```ocaml
Owebview_jsoo.App.ready ()
```

after DOM initialization and event-handler registration.

The native side should provide:

```ocaml
val Window.await_frontend_ready : Window.t -> unit
```

### 13.5 Frontend handshake

The frontend sends:

- Protocol version.
- Frontend build identifier.
- Optional application version.
- Supported transport capabilities.

The native runtime validates compatibility before accepting normal RPC or stream
traffic. A mismatch should display a useful diagnostic rather than fail silently.

## 14. Protocol and transport

### 14.1 Transport envelope

All messages use a versioned envelope:

```ocaml
type envelope = {
  version : int;
  kind : string;
  id : string option;
  payload : Json.t;
}
```

JSON is the initial wire format. The codec abstraction must permit a future
binary format without changing application endpoint definitions.

### 14.2 JavaScript transport object

The native runtime injects a single private JavaScript transport object:

```javascript
window.__owebview = {
  call(method, payload) { /* Promise */ },
  openStream(method, payload) { /* Promise */ },
  sendCommand(streamId, command) { /* Promise */ },
  cancelStream(streamId) { /* Promise */ },
  deliverBatch(encodedBatch) { /* native -> frontend */ },
  ready(protocolVersion, frontendBuildId, capabilities) {}
};
```

Application code should not use this object directly. `owebview-jsoo` provides
the typed wrapper.

### 14.3 Transport interface

Application protocol code must support alternate transports:

```ocaml
module type TRANSPORT = sig
  type t

  val send : t -> Envelope.t -> unit
  val set_receiver : t -> (Envelope.t -> unit) -> unit
  val close : t -> unit
end
```

Planned implementations:

- Embedded WebView transport.
- In-memory test transport.
- WebSocket development transport.

A WebSocket development transport allows the js_of_ocaml frontend to run in a
normal browser while talking to the same Eio backend and protocol.

## 15. Typed RPC

### 15.1 Endpoint definition

```ocaml
type ('request, 'response) Endpoint.t = {
  name : string;
  request : 'request Codec.t;
  response : 'response Codec.t;
}
```

Example:

```ocaml
let get_user : (user_id, user) Endpoint.t =
  Endpoint.make
    ~name:"user.get"
    ~request:user_id_codec
    ~response:user_codec
```

### 15.2 Native server

```ocaml
val Rpc.handle :
  sw:Eio.Switch.t ->
  Window.t ->
  ('request, 'response) Endpoint.t ->
  ('request -> ('response, Rpc_error.t) result) ->
  Subscription.t
```

Handlers run as Eio fibers, not on the UI thread.

### 15.3 Frontend client

```ocaml
val Owebview_jsoo.Rpc.call :
  ('request, 'response) Endpoint.t ->
  'request ->
  ('response, Rpc_error.t) result Js_of_ocaml.Promise.t
```

### 15.4 Request lifecycle

Every request has:

- A unique request ID.
- An endpoint name.
- A creation timestamp.
- An owning window and application.
- A one-shot response capability.
- Optional timeout and cancellation state.

The application API must not expose raw upstream request IDs. Responding twice
returns an error. Closing a window rejects unresolved window-scoped requests.

### 15.5 RPC errors

```ocaml
type Rpc_error.t = {
  code : string;
  message : string;
  data : Json.t option;
}
```

Backend exceptions are logged with full native backtraces but converted into
sanitized structured errors for release frontends.

### 15.6 Backend-initiated frontend calls

The native application may need to request a typed value or action from the
frontend, for example reading current form state, asking the frontend to prepare
for navigation, or invoking a frontend-owned dialog.

Define frontend endpoints separately so direction remains explicit:

```ocaml
type ('request, 'response) Frontend_endpoint.t

val Frontend.call :
  Window.t ->
  ('request, 'response) Frontend_endpoint.t ->
  'request ->
  ('response, Rpc_error.t) result
```

`Frontend.call` is an Eio operation that suspends the calling fiber until the
js_of_ocaml frontend responds, the request times out, or the window closes.

The frontend registers a typed handler:

```ocaml
val Owebview_jsoo.Frontend.handle :
  ('request, 'response) Frontend_endpoint.t ->
  ('request -> ('response, Rpc_error.t) result Js_of_ocaml.Promise.t) ->
  Subscription.t
```

### 15.7 Typed one-way events

Not every notification requires a request/response lifecycle. The protocol
should support typed one-way events:

```ocaml
type 'event Event.t

val Event.emit :
  Window.t ->
  'event Event.t ->
  'event ->
  (unit, Error.t) result

val Owebview_jsoo.Event.subscribe :
  'event Event.t ->
  ('event -> unit) ->
  Subscription.t
```

Events are appropriate for state invalidation, theme changes, notifications,
and application broadcasts. Long-lived ordered operations with commands and a
terminal result should use streams instead.

### 15.8 JavaScript evaluation with results

Raw fire-and-forget `eval` should remain available under `Owebview.Raw`, but the
safe API should provide asynchronous, result-bearing evaluation:

```ocaml
val Frontend.eval :
  Window.t ->
  string ->
  (Json.t, Javascript_error.t) result
```

This is an Eio operation. It should use the native platform's asynchronous
JavaScript evaluation API where practical and preserve JavaScript exception
information. It is an escape hatch; typed frontend endpoints are preferred for
normal application communication.

## 16. Realtime bidirectional streams

Realtime streaming is a core requirement, especially for agent orchestration and
LLM applications.

### 16.1 Stream endpoint

```ocaml
type ('request, 'event, 'command, 'result) Stream_endpoint.t = {
  name : string;
  request : 'request Codec.t;
  event : 'event Codec.t;
  command : 'command Codec.t;
  result : 'result Codec.t;
}
```

This supports:

- A typed request that starts or attaches to a stream.
- Typed backend-to-frontend events.
- Typed frontend-to-backend commands.
- A typed terminal result.

### 16.2 Agent protocol example

```ocaml
type run_agent = {
  conversation_id : string;
  prompt : string;
}

type agent_event =
  | Run_started of { run_id : string }
  | Assistant_message_started of { message_id : string }
  | Text_delta of { message_id : string; text : string }
  | Tool_started of {
      call_id : string;
      tool : string;
      arguments : Json.t;
    }
  | Tool_output of { call_id : string; output : string }
  | Approval_requested of {
      request_id : string;
      description : string;
    }
  | Usage_updated of {
      input_tokens : int;
      output_tokens : int;
    }
  | Status_changed of agent_status

type agent_command =
  | Send_message of string
  | Cancel_run
  | Pause_run
  | Resume_run
  | Approve_tool of string
  | Reject_tool of {
      request_id : string;
      reason : string option;
    }

type run_result =
  | Completed
  | Cancelled
  | Failed of Rpc_error.t
```

Events must be structured. The frontend must not need to parse textual log lines
to distinguish model output, tool execution, approval requests, status, and
completion.

### 16.3 Native stream API

```ocaml
module Stream_session : sig
  type ('event, 'command, 'result) t

  val emit :
    ('event, _, _) t ->
    'event ->
    (unit, Error.t) result

  val commands :
    (_, 'command, _) t ->
    'command Eio.Stream.t

  val finish :
    (_, _, 'result) t ->
    'result ->
    (unit, Error.t) result

  val cancel_context : (_, _, _) t -> Eio.Cancel.t
end

val Stream.handle :
  sw:Eio.Switch.t ->
  App.t ->
  ('request, 'event, 'command, 'result) Stream_endpoint.t ->
  (('event, 'command, 'result) Stream_session.t ->
   'request ->
   unit) ->
  Subscription.t
```

The exact cancellation accessor may change based on Eio API constraints. The
semantic requirement is that frontend cancellation cancels the handler's Eio
fiber tree.

### 16.4 Frontend stream API

```ocaml
module Owebview_jsoo.Stream : sig
  type ('event, 'command, 'result) t

  val open_ :
    ('request, 'event, 'command, 'result) Stream_endpoint.t ->
    'request ->
    ('event, 'command, 'result) t Js_of_ocaml.Promise.t

  val on_event :
    ('event, _, _) t ->
    ('event -> unit) ->
    Subscription.t

  val send :
    (_, 'command, _) t ->
    'command ->
    (unit, Rpc_error.t) result Js_of_ocaml.Promise.t

  val finished :
    (_, _, 'result) t ->
    ('result, Rpc_error.t) result Js_of_ocaml.Promise.t

  val cancel :
    (_, _, _) t ->
    unit Js_of_ocaml.Promise.t
end
```

### 16.5 Stream wire messages

Required message kinds:

```text
stream.open
stream.opened
stream.event
stream.batch
stream.command
stream.command_ack
stream.command_error
stream.finished
stream.failed
stream.cancel
stream.ack
stream.resume
stream.detached
```

All streams are multiplexed over one transport by `streamId`. The implementation
must not create a native WebView binding per stream.

### 16.6 Ordering

Every event has a monotonically increasing sequence number:

```ocaml
type 'event sequenced = {
  sequence : int64;
  timestamp : float;
  event : 'event;
}
```

Sequence numbers provide:

- Deterministic ordering.
- Duplicate detection.
- Acknowledgement.
- Lag measurement.
- Replay.
- Reconnection after frontend reload.

### 16.7 Replay and resume

The frontend periodically acknowledges the highest processed sequence number.
After reload or reconnect, it may request:

```text
stream.resume(stream_id, after_sequence)
```

The backend retains a configurable replay buffer. If the requested sequence is
no longer available, the stream may:

- Send a current state snapshot.
- Return a `Replay_unavailable` error.
- Require the frontend to create a new subscription.

The chosen behavior is endpoint policy.

### 16.8 Application scope versus window scope

Long-running agent sessions should normally be application-scoped, while UI
subscriptions are window-scoped:

```text
Application switch
  +-- agent session
      +-- orchestration fibers
      +-- model stream
      +-- tool processes
      +-- retained event buffer

Window switch
  +-- subscription to agent session
```

This permits:

- Frontend reload without cancelling the agent.
- Closing one window without terminating a shared session.
- Multiple windows observing the same session.
- Explicit cancellation through a command.
- Application exit cancelling all sessions.

Endpoint configuration should decide whether a session is application-scoped or
window-scoped.

### 16.9 Backpressure and batching

The implementation must not invoke JavaScript evaluation once per model token.

The native flow is:

```text
Agent fibers
  -> bounded outgoing queue
  -> batching/coalescing fiber
  -> native UI dispatch
  -> one JavaScript delivery call with N events
```

Initial configurable defaults:

- Flush interval: approximately 16 to 30 milliseconds.
- Maximum encoded batch: approximately 32 to 64 KiB.
- Immediate flush for approval requests, errors, and terminal events.
- Bounded pending event count and byte count per subscriber.
- Bounded retained replay buffer per session.
- Bounded active stream count per application and window.

### 16.10 Coalescing policy

Never drop:

- Approval requests.
- Commands and command acknowledgements.
- Tool results.
- State transitions.
- Errors.
- Terminal results.
- User messages.

May coalesce:

- Adjacent text deltas for the same message.
- Progress percentages.
- Token usage updates.
- Repeated status updates.
- Debug telemetry.

Coalescing must preserve semantic order.

### 16.11 Slow subscribers

If a frontend cannot keep up, the endpoint may choose among:

- Apply producer backpressure.
- Coalesce low-priority events.
- Drop superseded telemetry.
- Send a state snapshot.
- Detach the slow subscriber with a structured error.

Agent execution must not deadlock solely because a window stopped rendering.
An intermediary transport fiber should isolate critical orchestration work from
slow UI delivery.

### 16.12 Command acknowledgement

Every frontend command receives a unique command ID and an acknowledgement or
structured error. The frontend must not assume that an approval, cancellation,
or state mutation succeeded until acknowledged.

## 17. Frontend rendering guidance

The transport may deliver many events, but the UI should render at most once per
browser animation frame where practical.

Recommended frontend flow:

```text
Native event batch
  -> decode typed events
  -> update frontend model
  -> schedule requestAnimationFrame
  -> render current state once
```

Transport semantics preserve events; rendering may coalesce visual updates.

The binding library should expose enough hooks for this behavior without
mandating a specific UI library.

## 18. Security model

### 18.1 Trusted origin

RPC and stream bindings are enabled only for the trusted application origin by
default.

Remote pages must not gain access to native application methods merely because
the window navigated to them.

The current transport validates the native browser's top-level URL for every
privileged call, and the default navigation policy prevents an untrusted page
from loading in the privileged window at all. Applications that deliberately
allow additional in-WebView origins must decide separately whether those
origins are included in the transport trust set.

### 18.2 Default navigation policy

The default policy should:

- Allow the application origin.
- Reject or open external HTTP(S) URLs in the system browser.
- Reject unexpected custom schemes.
- Reject new windows unless handled.
- Prevent remote pages from inheriting privileged bindings.

### 18.3 Content policy

Production assets should receive a restrictive Content Security Policy.
Applications can explicitly extend it for required APIs.

### 18.4 Protocol validation

The transport must validate:

- Protocol version.
- Message kind.
- Endpoint existence.
- Stream ownership.
- Request and command identifiers.
- Payload size.
- Pending request count.
- Codec success.
- One-shot response rules.
- Permission to issue commands for the target session.

### 18.5 Native permissions

Camera, microphone, location, notifications, downloads, external URLs, and file
access require explicit application policies and frontend-visible errors.

## 19. Platform architecture

### 19.1 Upstream WebView

The vendored upstream WebView should remain unmodified when possible. It supplies
the minimal common window and JavaScript binding transport.

Vendor updates must record:

- Upstream tag.
- Upstream commit.
- Generated header checksum.
- Regeneration instructions.
- Local compatibility notes.

### 19.2 Platform modules

Common desktop features not exposed by upstream should be implemented behind a
small internal platform interface, not by permanently forking upstream.

```text
macOS
  - WKWebView
  - Cocoa/AppKit

Linux
  - WebKitGTK
  - GTK

Windows
  - WebView2
  - Win32
```

### 19.3 Linux detection

Preferred detection order:

1. GTK 4 with WebKitGTK 6.0.
2. GTK 3 with WebKitGTK 4.1.
3. Optional legacy GTK 3 with WebKitGTK 4.0.

The selected backend should be queryable at runtime.

### 19.4 Windows

Windows support requires:

- Explicit build-system detection.
- WebView2 SDK and runtime diagnostics.
- MSVC and/or MinGW support.
- Unicode paths and titles.
- Application manifest support.
- Correct COM initialization.
- Windows CI.

The current behavior of treating all non-macOS systems as Linux must be removed.

### 19.5 Capability reporting

```ocaml
type Platform.backend =
  | Cocoa_webkit
  | Gtk_webkit of [ `V6_0 | `V4_1 | `V4_0 ]
  | Webview2

val Platform.backend : unit -> Platform.backend
val Platform.capabilities : unit -> Platform.capability list
```

### 19.6 Advanced native engine features

The common application API should grow according to application demand. Native
platform modules may expose additional capabilities in these areas:

- Navigation lifecycle, policy decisions, redirects, and failures.
- Back/forward history, reload, cache-bypassing reload, and stop.
- Current URL, title, favicon, and load progress.
- Zoom, user agent, background, rendering, and developer settings.
- Persistent and private profiles.
- Cookies, cache, local storage, and website-data clearing.
- Downloads, request interception, and custom schemes.
- TLS, authentication, and certificate decisions.
- File chooser, context-menu, printing, and new-window hooks.
- Camera, microphone, location, notification, and fullscreen permissions.
- Web-process crash, media playback, and inspector events.

The project should expose commonly portable features through `Owebview` and
backend-specific features through `Owebview.Platform`. It should not claim that
all backend features behave identically.

## 20. Developer experience

### 20.1 Development browser mode

The future framework should be able to run the frontend in Safari, Chrome, or
Firefox using a WebSocket transport to the same Eio backend.

Benefits:

- Familiar browser developer tools.
- Faster frontend iteration.
- Easy network and DOM inspection.
- The same typed protocol as the embedded app.

### 20.2 Embedded development mode

The native WebView mode should support:

- Developer tools.
- Source maps.
- Automatic reload.
- Native logs for JavaScript console output.
- Protocol message tracing.
- Stream queue and lag metrics.

### 20.3 Build integration

The project should offer Dune rules or helper libraries that collect frontend
output into an asset manifest without requiring a separate JavaScript bundler.

The future framework may add code generation and project scaffolding.

## 21. Observability

The runtime should support a configurable logger for:

- Native errors.
- Callback exceptions.
- JavaScript console messages.
- JavaScript uncaught exceptions.
- RPC start, completion, duration, cancellation, and failure.
- Stream open, close, event count, byte count, and lag.
- Dropped or coalesced events.
- Queue depth and backpressure.
- Frontend handshake and reconnect.
- Navigation and permission decisions.

Debug tracing must be possible without exposing sensitive payloads by default.
Applications should be able to provide redaction rules.

## 22. Testing strategy

### 22.1 Unit tests

- Error-code conversion.
- Lifecycle state transitions.
- Double close and calls after close.
- Wrong-thread checks.
- Binding registration and removal.
- One-shot responses.
- Protocol codecs.
- Endpoint registration.
- Stream sequencing.
- Command acknowledgements.
- Batching and coalescing.
- Replay buffer behavior.
- Security policy decisions.

### 22.2 Runtime stress tests

- Repeated create/run/close cycles.
- Major and minor GC during callbacks.
- Bind/unbind while messages are queued.
- Window close with pending RPC responses.
- Window close with active streams.
- Concurrent Domain dispatches.
- Concurrent stream commands.
- Callback exceptions.
- Frontend reload during an active agent session.
- Slow or disconnected subscribers.
- Multiple simultaneous windows and streams.

### 22.3 Integration tests

- macOS native WebKit smoke tests.
- Linux WebKitGTK tests under a virtual display where necessary.
- Windows WebView2 tests when supported.
- js_of_ocaml frontend handshake.
- Typed RPC round trip.
- Bidirectional stream round trip.
- Cancellation propagation.
- Asset loading and MIME behavior.
- Navigation policy enforcement.
- Production trusted-origin rejection in a real WebKit page.
- CSP-compatible development reload injection.
- Secondary-window close interception and managed teardown.
- Continued primary-window operation after repeated child-window teardown.

### 22.4 Native tooling

- AddressSanitizer.
- LeakSanitizer.
- ThreadSanitizer where supported.
- `clang-tidy`.
- Strict compiler warnings.
- `ocamlformat`.
- `odoc` warnings as errors.
- `opam lint`.

### 22.5 Fake transport and backend

State machines, RPC, streams, and most lifecycle behavior should be testable
without opening a graphical window. Provide:

- An in-memory transport.
- A fake UI dispatcher.
- A fake window backend.
- Deterministic clock hooks for batching and timeout tests.

## 23. Continuous integration

The initial CI matrix should include:

- OCaml 5.3, 5.4, and 5.5.
- macOS arm64 where available.
- Linux GTK 3/WebKitGTK 4.1.
- Linux GTK 4/WebKitGTK 6.0.
- Windows when WebView2 support lands.

Required checks:

```text
dune build @all
dune runtest
dune build @doc
opam lint
format checks
C++ warning build
sanitizer jobs
package installation test
```

During the local-only development phase, these checks run locally. CI
configuration may be authored and tested in the repository, but it must not be
enabled on or pushed to a hosted service until the publication gate described
below is explicitly opened.

## 24. Release and packaging

Add:

- Versioned release tags.
- `CHANGES.md`.
- `CONTRIBUTING.md`.
- Architecture decision records for major runtime choices.
- A platform support table.
- Threading and Domains documentation.
- Security documentation.
- A protocol compatibility policy.
- A migration guide.
- Reproducible vendor-update tooling.
- A prepared, but not submitted, central opam package.

Native application packaging guidance should eventually cover:

- macOS `.app` bundles, `Info.plist`, assets, and code signing.
- Linux `.desktop` files, icons, and application IDs.
- Windows executables, manifests, icons, and WebView2 runtime requirements.

Remote releases, package submission, and public distribution are prohibited
during the local-only development phase. Release tooling may be prepared and
tested entirely locally.

## 25. API compatibility policy

Suggested stability levels:

```text
Owebview
  Stable application API after 1.0.

Owebview_protocol
  Stable wire and endpoint definitions after 1.0.

Owebview_jsoo
  Stable frontend client after 1.0.

Owebview.Platform
  Platform-dependent but versioned API.

Owebview.Raw / Owebview.Unsafe
  Lower compatibility guarantee.
```

Protocol changes require explicit version negotiation. Additive event variants
should be designed so older frontends can report unsupported messages cleanly.

## 26. Migration from the current API

The existing low-level operations can initially remain available under
`Owebview.Raw`:

```ocaml
create
destroy
run
terminate
dispatch
set_title
set_size
navigate
set_html
init
eval
bind
unbind
return
get_native_handle
```

The new safe API should be introduced alongside them, then become the documented
default. Migration goals:

- Replace raw request IDs with request capabilities.
- Replace raw JSON strings with typed endpoints.
- Replace explicit `destroy` with switch-owned lifecycle and idempotent close.
- Replace manual worker threads with Eio fibers.
- Replace direct `eval` event delivery with a batched transport.
- Move native handles into `Unsafe`.
- Remove Lwt examples and documentation.
- Replace asset-directory heuristics with the asset system.

## 27. Phased implementation plan

### Phase 1: OCaml 5 runtime hardening

Branch: `feature/ocaml5-runtime-hardening`

- Fix local-root cleanup ordering.
- Use `caml_result` callbacks.
- Catch C++ exceptions at FFI boundaries.
- Introduce typed native errors.
- Introduce managed handle state.
- Add lifecycle and thread-affinity checks.
- Replace global binding state with per-instance state.
- Make binding and dispatch reclamation safe.
- Make close idempotent.
- Add initial unit and stress tests.

Exit criteria:

- No known use-after-free path during close.
- Callback exceptions cannot escape through C++.
- Calls after close fail deterministically.
- Domain-concurrency tests pass.
- Sanitizer smoke tests pass.

### Phase 2: Eio application runtime

Branch: `feature/eio-runtime`

- Implement main-thread UI and Eio-Domain architecture.
- Implement bidirectional native queues and wakeups.
- Add Eio-aware window lifecycle.
- Tie windows to switches.
- Implement clean application shutdown.
- Replace Lwt examples with an Eio lifecycle example.

Exit criteria:

- UI remains responsive during long Eio operations.
- Closing a window cancels window-scoped fibers.
- Application exit cleans up all native resources.
- macOS and Linux lifecycle tests pass.

### Phase 3: Shared protocol and typed RPC

Branch: `feature/app-rpc`

- Create `owebview-protocol`.
- Create `owebview-jsoo`.
- Add endpoint definitions and codecs.
- Add frontend handshake.
- Add Promise-based js_of_ocaml RPC.
- Add native Eio handlers.
- Add structured errors and cancellation.

Exit criteria:

- A shared endpoint compiles natively and to JavaScript.
- Typed request/response round trips work.
- Frontend reload performs a fresh handshake.
- Pending requests reject cleanly on close.

Status: complete and validated on macOS as of August 12, 2026. Linux validation
remains part of the separately deferred platform validation work.

### Phase 4: Realtime streams

Branch: `feature/realtime-streams`

- Add typed stream endpoints.
- Add Eio stream sessions and commands.
- Add Promise-based frontend stream clients.
- Add event batching and coalescing.
- Add acknowledgements and sequence numbers.
- Add cancellation, replay, and resume.
- Add application-scoped agent sessions.
- Add slow-subscriber policy.

Exit criteria:

- Multiple simultaneous streams are multiplexed correctly.
- LLM-style text streams remain responsive.
- Tool approval commands are acknowledged.
- Reloaded frontends can resume a running session.
- Slow subscribers do not deadlock agent execution.

Status: complete and validated on macOS as of August 12, 2026. Multi-window
subscriber ownership and process-restart persistence are intentionally assigned
to Phase 8 rather than being Phase 4 completion requirements.

### Phase 5: Application assets and security

Branch: `feature/app-assets`

- Add asset source abstraction.
- Add custom application origin.
- Add MIME and CSP support.
- Add navigation policy.
- Restrict privileged bindings to trusted content.
- Add development reload.
- Add packaged/embedded asset mode.

Exit criteria:

- Production content loads without `file://` privileges.
- Remote pages cannot call native bindings by default.
- Development and release modes are documented and tested.

Status: complete and validated on macOS as of August 12, 2026. The production
backend uses a private tokenized loopback origin rather than `file://`. A true
platform `app://` scheme remains an optional Phase 7 backend improvement, not a
Phase 5 security requirement.

### Phase 6: Desktop window features

Branch: `feature/desktop-window`

- Add application-oriented window controls.
- Add native dialogs.
- Add theme and lifecycle events.
- Add console/error forwarding.
- Add downloads and permissions.
- Add native multiple-window creation and lifecycle support.

Exit criteria:

- UI controls and native dialogs are callable from Eio without violating UI
  thread ownership.
- Close interception can veto a request and later permit it.
- Secondary windows close and destroy independently without terminating the
  primary application loop or corrupting upstream window accounting.
- JavaScript console/error forwarding is restricted to trusted content.
- Permission and download decisions are explicit application policies.
- Theme and lifecycle changes can be observed from application fibers.

Status: complete and validated on macOS as of August 13, 2026 for this scoped
baseline. Cocoa dialogs use asynchronous window-attached sheets: only the
requesting Eio fiber waits, cancellation is propagated to AppKit, concurrent
dialogs on one window are rejected, and window closure settles the pending
operation before closing the parent. Cocoa secondary-window destruction also
avoids upstream's nested main-queue drain, which could self-deadlock when
teardown ran from a main-thread callback while the primary window remained
active. Queued Cocoa callbacks use a shared lifetime guard so skipping that
drain does not permit callbacks to access a destroyed engine. Download support
currently provides trusted-link interception and an application policy hook;
engine-native transfer progress, response metadata, and cookie-aware download
management remain future platform work.
Permission hooks gate frontend API requests before WebKit and the operating
system apply their own permission behavior. Multi-window attachment to shared
agent sessions is implemented by the Phase 8 durable registry.

### Phase 7: Platform modernization

Branch: `feature/platform-support`

- Add GTK4/WebKitGTK 6.0 detection.
- Preserve GTK3/WebKitGTK 4.1 support.
- Add Windows/WebView2.
- Add capability reporting.
- Add platform packaging documentation.

Exit criteria:

- Build discovery distinguishes macOS, Linux, Windows, and unsupported targets.
- Linux discovery prefers GTK4/WebKitGTK 6.0 and preserves explicit GTK3
  fallbacks.
- The selected backend and implemented capabilities are queryable at runtime.
- Unsupported backend features are omitted from capability reporting or return
  a typed unsupported error.
- Windows/WebView2 is represented as a distinct target rather than falling
  through Linux configuration.
- Packaging requirements and validation status are documented per platform.

Status: complete as of August 12, 2026 for implementation that can be performed
locally. Cocoa/WKWebView is validated on macOS. Linux and Windows detection and
backend-selection code is implemented but cannot honestly be marked validated
without those machines. Windows desktop extensions remain capability-gated;
the target recognition and upstream WebView2 build path do not imply a tested
Windows release. Operations not implemented by a selected backend are omitted
from `Platform.capabilities` or raise the typed `Missing_dependency` error
rather than silently succeeding.

### Phase 8: Shared application sessions and restart recovery

Branch: `feature/durable-app-sessions`

This phase turns realtime streams from resources owned by one native window
into application-level services that may be observed by multiple windows and
recovered after the OCaml process restarts. Phase 6 supplies the native ability
to create and manage windows; this phase defines how those windows share
long-lived application state.

The target ownership model is:

```text
Application switch
  +-- session registry
      +-- agent session
          +-- orchestration fibers
          +-- model and tool activity
          +-- command state
          +-- retained event log
          +-- persistence checkpoint

Window A switch
  +-- transport A
      +-- subscription A
          +-- acknowledgement and replay cursor A

Window B switch
  +-- transport B
      +-- subscription B
          +-- acknowledgement and replay cursor B
```

Closing or reloading a window removes only that window's transport and
subscriptions. It must not cancel an application-scoped agent session. An
explicit session cancellation, application shutdown, or configured
last-window policy may cancel the underlying work.

#### Phase 8.1 Application session registry

- Move application-scoped stream sessions above individual `Window` and
  `Transport` ownership.
- Add stable, globally unique session and command identifiers. Process-local
  identifiers such as `stream-4` are not sufficient for restart recovery.
- Give every session an explicit lifecycle such as `Running`, `Recovering`,
  `Interrupted`, `Completed`, `Failed`, or `Cancelled`.
- Separate the application switch, session switch, window switch, and
  subscription switch.
- Define whether closing the final window leaves the application running,
  cancels sessions, or asks the application policy to decide.

#### Phase 8.2 Multi-window attachment

- Allow any authorized window transport to attach to an existing session by
  stable session ID.
- Maintain independent acknowledgement, replay, batching, and backpressure
  state for every subscriber.
- Replay missed events to one subscriber without disturbing other subscribers.
- Detach a slow or closed subscriber without blocking agent execution or
  terminating the shared session.
- Broadcast terminal state, command results, and approval resolution to all
  attached subscribers.
- Deduplicate commands and approvals so the same action cannot be applied twice
  when more than one window responds.
- Provide application APIs for listing active and historical sessions so a new
  window can discover and attach to them.

A representative application should be able to express:

```ocaml
Owebview_app.run @@ fun app ->
let session = Agent_session.start app agent_request in

let conversation =
  Window.create app ~title:"Conversation"
in
Stream.attach conversation session;

let inspector =
  Window.create app ~title:"Agent Inspector"
in
Stream.attach inspector session
```

The exact public API may differ, but the ownership represented by the example
is required: `session` belongs to `app`, while each `Stream.attach` creates a
window-scoped subscription.

#### Phase 8.3 Durable session storage

Define an application-supplied persistence interface rather than coupling the
binding library to one database. A default SQLite implementation may be
provided by the future application framework. The interface must support:

- Creating and updating session metadata.
- Appending sequenced events.
- Recording terminal results and errors.
- Recording commands, approvals, acknowledgements, and their final status.
- Loading sessions and replay ranges after process restart.
- Saving application-specific orchestration checkpoints or references to
  external jobs.
- Schema versioning, migrations, retention, and compaction.

Events must be assigned stable sequence numbers and durably recorded according
to a documented ordering policy. Delivery should use at-least-once semantics;
frontends deduplicate replayed events by session ID and sequence number. The
project must not claim exactly-once execution for commands or external tool
side effects.

Command IDs and state transitions must be durable enough to distinguish a new
command from a retry after a crash. Sensitive prompts, tool output, credentials,
and approval data require an explicit storage and encryption policy in the
application layer.

#### Phase 8.4 Restart reconciliation

On process startup, reconstruct the application session registry from durable
records and reconcile every non-terminal session with the agent orchestrator.
Recovery may produce one of three supported levels:

1. **Durable history:** completed sessions and their output can be reopened.
2. **Interrupted-run recovery:** partial output is retained, the run is marked
   interrupted, and the user may retry or continue through an application
   command.
3. **True continuation:** execution resumes from a durable workflow checkpoint
   or reconnects to an externally running job.

The first implementation must provide durable history and interrupted-run
recovery. True continuation is optional until the agent orchestration framework
provides durable checkpoints, idempotent tool execution, external run IDs, and
safe reconciliation of partially completed side effects. An Eio fiber, child
process, or live model HTTP stream cannot itself survive process termination.

Frontend Promises from the old process are not recoverable. After restart, a
new frontend handshake must list or attach to the durable session using its
stable ID and request events after its last processed sequence number.

#### Phase 8.5 Demonstration

Extend the agent demonstration to use two native windows:

1. Start an agent session from a conversation window.
2. Attach an inspector window to the same running session.
3. Stream text, tool activity, and state transitions to both windows.
4. Close and reopen the inspector without interrupting the agent.
5. Resolve a tool approval in one window and reflect the result in both.
6. Restart the native application during a run.
7. Restore prior events, classify the run as interrupted or recovering, and
   expose an explicit retry or continuation action.
8. Reopen a completed session from durable history.

Exit criteria:

- Sessions are owned independently of any individual window transport.
- Two or more windows can observe the same session with independent replay and
  acknowledgement positions.
- Closing or reloading one window does not terminate a shared session.
- Duplicate commands or approvals from multiple windows are applied at most
  once at the application level.
- Completed session history survives a full native process restart.
- Interrupted sessions restart in a deterministic, documented state.
- A reconnected frontend can resume durable event replay by stable session ID
  and sequence number.
- Persistence and recovery tests cover crashes between event creation,
  durable append, delivery, acknowledgement, and command application.

Status: complete and validated on macOS as of August 12, 2026 for the required
durable-history and interrupted-run recovery levels. Sessions are owned by an
application registry rather than a window transport. Multiple WebKit windows
attach with independent acknowledgement cursors, bounded count/byte delivery
queues, batching fibers, and authorization decisions. A slow subscriber is
detached without blocking producers or other windows. Durable command IDs are
deduplicated before application admission. Commands retain their encoded
payload and `Admitted`, `Applied`, or `Rejected` status; conflicting reuse of
an ID is rejected, and startup reconciliation APIs expose commands whose
external effect may have happened before final status was persisted. Events,
commands, acknowledgements, checkpoints, and terminal transitions are
persisted before their corresponding live state becomes visible.

Directory-backed snapshots survive an actual second operating-system process,
completed histories reopen, and non-terminal runs restore as `Interrupted`.
Non-running histories can be explicitly deleted or compacted by age and latest
count, so retained history does not permanently exhaust the session limit.
`Durable_session.retry` starts a new session from the old persisted request and
preserves the interrupted run as immutable history.

True continuation remains conditional by design: applications may build it on
the persistence interface when their orchestration framework supplies durable
checkpoints, external run IDs, idempotent tool behavior, and reconciliation of
partially completed side effects. The library does not claim that an Eio fiber,
HTTP stream, frontend Promise, or arbitrary side effect survives process exit.
The `examples/agent_stream` demonstration now uses a js_of_ocaml conversation
window and inspector windows attached to one durable session. Its typed
protocol covers run phases, plans, structured activity, tool progress, usage
telemetry, approvals, live instructions, artifacts, checkpoints, incremental
text, commands, and terminal summaries. The application demonstrates stable
approval command IDs, pause/resume/cancel, subscriber authorization, bounded
per-window replay, native clipboard and export RPC, secure embedded assets,
platform capability reporting, directory persistence, historical-session
discovery, inspector reopen, and interrupted-run retry. It intentionally
demonstrates retry rather than claiming transparent continuation of a dead
OCaml fiber.

### Phase 9: Release maturity

- Complete local validation matrix: implemented. macOS arm64/OCaml 5.3 is the
  locally validated cell; OCaml 5.4/5.5, Linux, and Windows cells are prepared
  and explicitly remain unvalidated until matching machines exist.
- Complete documentation: implemented for architecture, compatibility,
  migration, security, platform support, vendoring, contribution, release, and
  architecture decisions.
- Add release tooling and changelog: implemented as local-only scripts and
  `CHANGES.md`.
- Prepare an initial opam release without submitting it: implemented as a
  generated local source archive and opam-repository overlay. No submission or
  publication is performed.
- Define the 1.0 compatibility boundary: implemented in `COMPATIBILITY.md`.

Publication is a separate, explicitly authorized milestone after the local
maturity gate. It is not an automatic consequence of completing Phase 9.

## 28. First complete demonstration

The first full-stack demonstration should be an agent-style application built
entirely in OCaml:

1. The frontend is compiled with js_of_ocaml.
2. The frontend sends a prompt through a typed stream endpoint.
3. The backend starts an Eio-managed agent run.
4. The backend streams structured text deltas.
5. The backend emits a simulated tool call.
6. The frontend displays an approval request.
7. The frontend sends an approval or rejection command.
8. The backend continues streaming.
9. The frontend can pause, resume, or cancel.
10. Reloading the frontend reconnects to the active session.
11. Closing the application cancels all remaining work safely.

This example validates the core architecture needed by the future framework.

Status: implemented. The polished Orbit Agent Studio demonstration exercises
all eleven behaviors above plus usage telemetry, generated artifacts, native
clipboard/export integration, platform capability reporting, durable
checkpoints, subscriber authorization, and deterministic autoplay for local
end-to-end verification.

## 29. Future framework boundary

The future framework can build the following on top of `owebview`:

- Project scaffolding.
- Typed endpoint code generation.
- Frontend asset pipelines.
- Hot reload orchestration.
- Application routing.
- State synchronization.
- Component conventions.
- Application packaging commands.
- Plugin systems.
- Auto-update support.

To enable that framework, this library must provide stable primitives for:

```text
Application lifecycle
Window lifecycle
Eio integration
Typed RPC
Realtime streams
OCaml-to-frontend events
Secure assets
Navigation and permission policy
Native dialogs and desktop events
Platform capabilities
Packaging hooks
```

## 30. Open design decisions

These decisions require prototypes or benchmarks:

1. Exact Eio-main-thread/worker-Domain bootstrap sequence on each platform.
2. Cross-platform wakeup mechanism for the native-to-Eio queue.
3. Whether the initial stable API requires one initial window.
4. Default JSON codec implementation.
5. Replay buffer ownership and optional persistence.
6. Default batching interval and byte limits.
7. Whether application-scoped sessions survive closing the last window.
8. Whether Phase 7 should replace the portable tokenized loopback asset origin
   with platform-specific `app://` scheme handlers.
9. WebSocket development transport package boundaries.
10. Objective-C runtime calls versus a typed Objective-C++ platform shim.
11. Windows compiler and package support policy.
12. Stable public names for `App`, `Window`, `Rpc`, and `Stream` modules.

These should be documented through architecture decision records as they are
resolved.

## 31. Local fork and repository policy

### 31.1 Fork status

This project is being developed as a local fork of the existing `owebview`
repository. The upstream repository is the source lineage and may be consulted
or fetched for reference, but this fork is not currently intended to be
published or synchronized to a writable remote.

The current development model is deliberately local-first:

- Source changes remain in the local Git repository.
- Feature branches remain local.
- Commits remain local.
- Tags remain local.
- Test artifacts and release candidates remain local.
- No pull requests are opened.
- No branches or tags are pushed.
- No hosted package is published.
- No opam-repository submission is made.
- No automated job may upload source, artifacts, logs, coverage, or releases.

This policy applies until the project is considered mature and the owner makes
an explicit decision to publish it.

### 31.2 Remote usage

Any Git remote associated with the original project is treated as read-only
upstream metadata. It may be used for intentional read operations such as:

- Inspecting upstream history.
- Fetching upstream tags or fixes.
- Comparing the local fork with upstream.
- Importing selected upstream changes.

It must not be used for push operations. The local workflow must not assume that
a GitHub fork, writable origin, pull request, or hosted CI service exists.

As an optional local safety measure, the upstream remote may later be renamed to
`upstream` and configured with a disabled push URL. That repository
configuration change requires an explicit owner decision; it is not required by
this specification.

### 31.3 Local branch strategy

Development should use ordinary local branches so work remains reviewable and
reversible:

```text
main
  +-- feature/ocaml5-runtime-hardening
  +-- feature/eio-runtime
  +-- feature/app-rpc
  +-- feature/realtime-streams
  +-- feature/app-assets
  +-- feature/desktop-window
  +-- feature/platform-support
  +-- feature/durable-app-sessions
```

`main` is the local integration branch. Feature branches are merged locally
only after their tests and phase exit criteria pass. No branch name implies a
remote counterpart.

Commits should remain focused and reviewable even though they are not public.
Local development should preserve attribution, upstream history, and all
applicable licenses.

### 31.4 Local verification

Before a feature branch is merged into the local `main`, run the relevant local
checks:

```text
dune build @all
dune runtest
dune build @doc
opam lint
format checks
C++ warning checks
sanitizer checks where applicable
integration examples where applicable
```

Hosted CI is not required to enforce quality. Scripts and Dune aliases should
make the complete verification suite reproducible on local machines.

### 31.5 Local backups

Because there is intentionally no remote copy, the repository should have a
local backup procedure. Suitable options include:

- Periodic Git bundle files stored on separate local media.
- Encrypted machine backups.
- Filesystem snapshots.
- A second private machine or storage device that is not a public Git remote.

Backup creation must not upload the repository to an external service unless
the owner explicitly changes this policy.

The backup procedure should preserve:

- All local branches.
- All local tags.
- Full Git history.
- Important untracked design or test artifacts until committed.

### 31.6 Maturity gate

Remote publication may be considered only after a deliberate maturity review.
At minimum, that review should confirm:

- OCaml 5 runtime invariants are implemented and documented.
- No known callback, lifetime, shutdown, or Domain-safety defects remain.
- The Eio runtime model is validated on supported platforms.
- Typed RPC and realtime streaming have stress and integration tests.
- Security defaults and trusted-origin behavior are implemented.
- The js_of_ocaml agent-streaming demonstration is complete.
- Documentation covers threading, cancellation, assets, security, and platform
  behavior.
- Local build, test, documentation, lint, and sanitizer checks pass.
- Vendored upstream provenance and licenses are correct.
- The public API and compatibility policy have been reviewed.
- Any planned release artifacts can be reproduced locally.
- The owner explicitly authorizes creating or using a writable remote.

Meeting technical criteria does not itself authorize publication. Publication
always requires a separate explicit owner decision.

### 31.7 Actions after the gate

If publication is eventually authorized, it should be handled as its own phase:

1. Decide the public project and package names.
2. Decide whether to preserve or rewrite local development history.
3. Create or select a writable remote.
4. Review every branch, tag, artifact, and document intended for publication.
5. Audit the repository for secrets, private paths, logs, and local-only data.
6. Enable hosted CI only after its configuration is reviewed.
7. Publish a release candidate before a stable release.
8. Submit to opam only after the release candidate is validated.

Until that phase is explicitly authorized, all roadmap work remains local.

## 32. Immediate next steps

1. Validate Phases 1 through 8 on Linux when a suitable machine is available.
2. Validate the WebView2 target and implement its missing desktop capability
   shims when a Windows machine and OCaml 5 toolchain are available.
3. Integrate the application-specific agent orchestrator with
   `Durable_session.Persistence`, including checkpoint and external-run
   reconciliation needed for true continuation.
4. Continue stress testing realistic agent orchestration workloads and
   persistence failure points.
5. Run the prepared Phase 9 matrix cells on OCaml 5.4/5.5, Linux, and Windows
   when suitable machines exist, without publishing anything.
6. Keep all branches, commits, artifacts, and verification local until the
   maturity gate is explicitly opened.
