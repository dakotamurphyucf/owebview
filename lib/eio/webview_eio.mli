(** Eio-native application runtime for owebview.

    The platform WebView event loop runs on the process main thread. The Eio
    application runs on a dedicated Domain and communicates with the UI through
    thread-safe dispatch and promise operations. *)

type t
(** A running Eio application window. *)

exception Window_closed
(** Used internally to cancel window-scoped fibers after the native window
    closes. It may be observed by code that catches all cancellation causes. *)

val run :
  ?debug:bool ->
  setup:(Webview.t -> unit) ->
  (env:Eio_unix.Stdenv.base -> sw:Eio.Switch.t -> t -> unit) ->
  unit
(** [run ~setup application] creates the WebView on the process main thread,
    calls [setup] there before the event loop starts, and runs [application] in
    an Eio event loop on a dedicated Domain.

    Returning from [application] requests termination. Closing the native window
    cancels the application's switch. Native resources are destroyed on the main
    thread after the Eio Domain has stopped. *)

val webview : t -> Webview.t
(** The managed low-level handle. Prefer the Eio-aware operations below. *)

val await_closed : t -> unit
(** Suspend the current fiber until the native window closes. *)

val is_closed : t -> bool

val call_ui : t -> (Webview.t -> 'a) -> 'a
(** Run a function on the UI thread and suspend the current fiber until it
    completes. Exceptions are returned to and raised in the calling fiber. *)

val close : t -> unit
(** Request event-loop termination. Safe from the Eio Domain and idempotent. *)

val set_title : t -> string -> unit
val set_size : t -> width:int -> height:int -> Webview.hint -> unit
val navigate : t -> string -> unit
val set_html : t -> string -> unit
val init : t -> string -> unit
val eval : t -> string -> unit
val reload : t -> unit
val current_url : t -> string
val show : t -> unit
val hide : t -> unit
val focus : t -> unit
val minimize : t -> unit
val maximize : t -> unit
val restore : t -> unit
val set_fullscreen : t -> bool -> unit
val set_navigation_handler : t -> (string -> Webview.navigation_action) -> unit

val set_close_handler : t -> (unit -> bool) -> unit
(** Replace the close policy. Returning [false] vetoes the request. Secondary
    windows that are allowed to close are destroyed in one managed native
    lifecycle step, avoiding duplicate upstream window accounting. *)

val set_position : t -> x:int -> y:int -> unit
val system_theme : t -> Webview.system_theme

val on_theme_change :
  sw:Eio.Switch.t -> t -> (Webview.system_theme -> unit) -> unit

val clipboard_read : t -> string option
val clipboard_write : t -> string -> unit

val dialog :
  t -> Webview.dialog_kind -> title:string -> detail:string -> string array
(** Present a native window-attached dialog and suspend only the calling fiber.
    Cocoa's main event loop remains unnested and responsive. Cancelling the
    fiber dismisses the dialog; closing the window raises a typed closed error.
    Only one dialog may be active per window. *)

val respond : t -> id:string -> error:bool -> result:string -> unit
(** Resolve or reject a JavaScript binding request from the Eio Domain. *)

val bind :
  ?capacity:int ->
  ?concurrency:int ->
  sw:Eio.Switch.t ->
  t ->
  string ->
  (id:string -> request:string -> unit) ->
  unit
(** Install a JavaScript binding whose handler runs in a bounded Eio worker
    pool. The native UI callback only enqueues the copied request and returns.
    At most [capacity] requests are queued (default [1024]); additional
    JavaScript calls are rejected without blocking the UI thread. At most
    [concurrency] handlers run at once (default [64]). The binding remains
    registered until the window is destroyed. *)

val bind_with_url :
  ?capacity:int ->
  ?concurrency:int ->
  sw:Eio.Switch.t ->
  t ->
  string ->
  (id:string -> request:string -> url:string -> unit) ->
  unit
(** URL-aware form of {!bind}. The native callback captures the actual current
    top-level URL for trusted-origin enforcement. *)

val create_window :
  ?debug:bool -> sw:Eio.Switch.t -> t -> setup:(Webview.t -> unit) -> t
(** Create an additional native window on the main UI thread. The existing
    application event loop owns it; callers must not call {!Webview.run} on the
    returned window. Closing [sw] requests native window closure, and native
    closure releases the window-scoped switch. *)
