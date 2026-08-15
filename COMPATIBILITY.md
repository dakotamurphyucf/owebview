# Compatibility policy

This document defines the intended 1.0 boundary. The repository is currently
an unpublished pre-1.0 local fork, so incompatible changes are still allowed
when they are recorded in `CHANGES.md` and `MIGRATION.md`.

## Supported runtime model

- OCaml 5.3 or newer.
- Eio is the only supported asynchronous runtime.
- The native UI loop runs on the process main thread.
- Application fibers run in Eio on a dedicated Domain.
- The supported browser frontend is compiled with js_of_ocaml and uses native
  JavaScript Promises. Lwt compatibility is intentionally out of scope.

The tested platform and compiler combinations are listed in
`VALIDATION_MATRIX.md`. A backend being detectable does not mean it is locally
validated.

## Public API boundary after 1.0

The following installed libraries are the compatibility boundary:

| Library | Stability after 1.0 |
| --- | --- |
| `owebview.webview` | Managed low-level OCaml API; additions are compatible, removals or type changes require a major release |
| `owebview.eio` | Eio lifecycle and UI-dispatch API; stable |
| `owebview.protocol` | Codec, endpoint, envelope, and error definitions; stable together with the wire policy below |
| `owebview.app` | Desktop, transport, RPC, stream, asset, and durable-session API; stable except explicitly experimental members |
| `owebview.jsoo` | Promise-based browser client; stable |

Public declarations in installed `.mli` files are covered unless their
documentation labels them `Experimental`, `Unsafe`, or platform-specific.
Implementation modules, C primitive names, C++ structs, generated JavaScript,
JSON snapshot layout internals, Dune internals, test helpers, and examples are
not public compatibility surfaces.

`Webview.get_window` and `Webview.get_native_handle` return borrowed native
handles. Their OCaml signatures are stable, but the pointed-to platform API and
lifetime rules are platform-specific. The handles must never outlive their
managed `Webview.t` and are not safe for cross-Domain use without a separate
platform binding that obeys UI-thread ownership.

## Semantic versioning

After 1.0 this fork will use semantic versioning:

- Patch: bug fixes with no intended public API or wire incompatibility.
- Minor: additive APIs, endpoints, capabilities, event forms, or optional
  fields that older peers can safely ignore or reject as unsupported.
- Major: removal, renaming, changed meaning, changed required behavior, or a
  wire/persistence change that cannot be negotiated or migrated.

Before 1.0, the minor version acts as the compatibility boundary. Applications
should pin an exact minor series and review `MIGRATION.md` before upgrading.

## Wire protocol policy

`Owebview_protocol.Envelope.current_version` is the transport protocol version.
The native and frontend handshake must agree on it before application traffic
is accepted.

- Existing envelope fields and message meanings are not changed within a
  compatible release line.
- New optional object fields may be added. Decoders must ignore unknown optional
  fields unless an endpoint explicitly declares a closed schema.
- New capabilities are advertised in the readiness handshake. A required
  capability must be negotiated before its messages are sent.
- New endpoint names, event variants, and structured error codes are additive
  only when an older peer can report them as unsupported without corrupting
  state.
- Integers that must retain full OCaml `int64` precision across JavaScript are
  encoded as decimal strings.
- A breaking envelope or message-semantics change increments the transport
  version and requires explicit dual-version support or a coordinated upgrade.

Application endpoint payloads belong to the application. Applications should
version their own payload schemas or endpoint names independently of the
transport version.

## Durable persistence policy

Directory-backed durable sessions write a versioned snapshot. Released code
must continue to read snapshots written by the previous stable minor release,
or provide a documented offline migration before dropping that reader.
Migration must be copy-on-write or backed up before replacement. A reader must
reject an unknown newer schema instead of silently rewriting it.

Persistence guarantees durable protocol history, acknowledgement positions,
command admission/status, terminal state, and opaque checkpoints. It does not
guarantee that an Eio fiber, HTTP response body, JavaScript Promise, or external
side effect survives process termination.

## Platform behavior

Portable API availability is represented by `Owebview_app.Platform` capability
reporting. Unsupported operations return a typed error; they do not silently
claim success. Platform-specific behavior may vary where operating systems do
not expose equivalent semantics, but such differences must be documented in
`PLATFORM_SUPPORT.md`.

## Deprecation

After 1.0, a public API should be deprecated for at least one minor release
before removal in the next major release. Security defects or unsound runtime
behavior may require faster removal; those cases require a prominent changelog
entry and migration instructions.
