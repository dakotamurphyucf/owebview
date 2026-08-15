# ADR 0002: Keep the native UI on the process main thread

- Status: Accepted
- Date: August 12, 2026

## Decision

Create, run, and destroy native WebViews on the process main thread. Run Eio on
a dedicated Domain and marshal UI operations through a close-aware dispatcher.

## Consequences

The design follows Cocoa and GTK ownership requirements while allowing OCaml
application fibers to remain responsive. UI-only low-level operations reject
the wrong Domain/thread. Shutdown must join the Eio Domain before destroying
native state, and accepted dispatches must resolve or fail when a window closes.
