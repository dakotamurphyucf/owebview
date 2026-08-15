# Platform support

Status as of August 12, 2026. This repository remains local-only.

The compiler/backend test cells and exact meaning of validated versus prepared
are documented in [`VALIDATION_MATRIX.md`](VALIDATION_MATRIX.md).

| Backend | Build detection | Local validation | Notes |
| --- | --- | --- | --- |
| macOS Cocoa/WKWebView | Implemented | Validated | Primary development backend |
| GTK4/WebKitGTK 6.0 | Preferred on Linux | Pending Linux machine | Native dialogs, clipboard read, and absolute positioning are not claimed |
| GTK3/WebKitGTK 4.1 | Linux fallback | Pending Linux machine | Existing Linux backend |
| GTK3/WebKitGTK 4.0 | Optional legacy fallback | Pending Linux machine | Supported only when newer packages are unavailable |
| Windows/WebView2 | Target recognized | Unvalidated | Build/link path is configured; high-level lifecycle and desktop extensions are not yet capability-complete |

`Owebview_app.Platform.backend` reports the selected backend and
`Owebview_app.Platform.capabilities` reports only features implemented by that
selection. `validation` distinguishes the locally validated Cocoa backend from
compiled-but-unvalidated Linux and Windows targets.

Capability reporting is intentionally stricter than target recognition. A
backend may be selectable while still omitting high-level features. Calls to
desktop operations that have no implementation return the typed
`Webview.Missing_dependency` error rather than acting as no-ops.

Current platform-specific limitations include:

- GTK4 does not expose the synchronous GTK3 dialog implementation or clipboard
  read path, and compositors generally do not permit absolute window position.
- WebView2 target selection does not yet include owebview's native close,
  navigation-policy, window-command, dialog, or theme-notification shims.
- Native download transfer management, native permission delegates, and a
  platform `app://` resource scheme remain future extensions on all backends.

## Native dependencies

Linux detection tries these pkg-config pairs in order:

1. `gtk4` and `webkitgtk-6.0`
2. `gtk+-3.0` and `webkit2gtk-4.1`
3. `gtk+-3.0` and `webkit2gtk-4.0`

Windows uses the vendored upstream WebView2 loader implementation and links the
required Windows system libraries. A supported Windows OCaml 5 toolchain and a
WebView2 runtime are still required. Windows behavior is not considered
validated until native build and lifecycle tests run on Windows.

## Packaging direction

macOS applications should eventually be packaged as `.app` bundles with an
`Info.plist`, application identifier, icons, usage-description strings for any
requested protected resources, code signing, and notarization as appropriate.

Linux applications should eventually install a versioned executable,
`.desktop` entry, icons, application ID, and packaged frontend assets. Runtime
packages must match the backend selected at build time.

Windows applications should eventually include an application manifest, icon,
WebView2 runtime policy, and installer/bootstrap diagnostics. None of this
packaging work authorizes publication or upload from the local fork.
