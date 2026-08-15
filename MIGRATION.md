# Migration guide

## From upstream owebview to this local fork

The original project is a thin binding around webview 0.12. This fork keeps the
`owebview.webview` package and core `Webview` operations, but changes the target
to an OCaml 5/Eio desktop application runtime.

### Toolchain

- Upgrade to OCaml 5.3 or newer.
- Add Eio and `eio_main` for managed applications.
- Remove Lwt-based timer/application code. Lwt is not supported by this fork.
- For a typed frontend, add `owebview.protocol` to shared protocol code and
  `owebview.jsoo` to the js_of_ocaml executable.

### Lifecycle

Existing minimal code can continue to use `Webview.create`, `run`, and
`destroy`, but errors now raise `Webview.Error` rather than generic failures.
Calls after close fail deterministically, and most UI operations enforce the
creating thread.

New applications should use `Webview_eio.run`. The setup callback executes on
the main UI thread; the application callback executes in Eio on a dedicated
Domain. Use `Webview_eio.call_ui` or the provided Eio wrapper operations instead
of invoking UI-only low-level functions from application fibers.

Before:

```ocaml
let webview = Webview.create () in
Webview.set_html webview html;
Webview.run webview;
Webview.destroy webview
```

Recommended application shape:

```ocaml
Webview_eio.run
  ~setup:(fun webview -> Webview.set_html webview html)
  (fun ~env:_ ~sw:_ app -> Webview_eio.await_closed app)
```

### JavaScript bindings

`Webview.bind` remains low level. It invokes a UI-thread callback and requires a
manual `Webview.return`. For application work, prefer one
`Owebview_app.Transport` and typed RPC/stream endpoints. The Eio binding helper
uses a bounded queue; overload rejects the JavaScript Promise instead of
blocking the UI thread.

Do not expose the bridge to arbitrary remote pages. Serve application assets
through `Owebview_app.Assets` and use `Owebview_app.Navigation` so both native
navigation and binding-origin checks share the intended trusted origins.

### Frontend

The supported client is Promise-based and does not require Lwt:

1. Define codecs and endpoints in a pure shared library depending on
   `owebview.protocol`.
2. Compile that library into both native and js_of_ocaml executables.
3. Create and install `Owebview_jsoo` once in the frontend.
4. Complete `ready` before making calls.
5. Use stable command IDs for durable actions that may be retried.

### Realtime and restart behavior

Use `Owebview_app.Stream` for a stream owned by one transport. Use
`Owebview_app.Durable_session` when multiple windows, process-restart history,
durable command status, or application-level reconciliation are required.

Restart restoration does not continue a dead OCaml fiber. A formerly running
session restores as `Interrupted`; either retry it as a new session or use the
opaque checkpoint and admitted-command APIs to implement application-specific
continuation and external side-effect reconciliation.

## Future version migrations

Before each pre-1.0 minor or post-1.0 major release, this file will list source,
wire, persistence, and behavior changes with mechanical migration examples.
