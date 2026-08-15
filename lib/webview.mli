(** Managed OCaml 5 bindings for the classic webview C API.

    For an Eio-owned application lifecycle, use the companion [owebview.eio]
    library. *)

type t
(** A managed, opaque handle to a webview instance. *)

type error_code =
  | Missing_dependency
  | Canceled
  | Invalid_state
  | Invalid_argument
  | Duplicate
  | Not_found
  | Closed
  | Closing
  | Wrong_thread
  | Invalid_lifecycle
  | Out_of_memory
  | Native_error of int

type error = { operation : string; code : error_code; message : string }

exception Error of error
(** A typed error raised by the native binding. *)

val string_of_error_code : error_code -> string
val pp_error : Format.formatter -> error -> unit

(** Window sizing behaviour, mirrors [WEBVIEW_HINT_*]. *)
type hint =
  | Hint_none  (** width/height are the initial size *)
  | Hint_min  (** width/height are the minimum bounds *)
  | Hint_max  (** width/height are the maximum bounds *)
  | Hint_fixed  (** window is not resizable *)

val create : ?debug:bool -> unit -> t
(** [create ?debug ()] creates a new webview. When [debug] is true the developer
    tools are enabled (default [false]). *)

val destroy : t -> unit
(** Destroy the webview and free associated resources. This is idempotent. It
    must run on the owning UI thread after {!run} has returned. *)

val is_closed : t -> bool
(** Whether destruction has started or completed. *)

val run : t -> unit
(** Run the main loop. {b Blocks} the calling thread until the window is closed
    and {b must be called on the main thread}. The OCaml runtime lock is
    released for the duration so other threads keep running. *)

val terminate : t -> unit
(** Stop the main loop started by {!run}. Safe to call from any thread. *)

val set_title : t -> string -> unit
val set_size : t -> width:int -> height:int -> hint -> unit

val navigate : t -> string -> unit
(** Navigate to a URL (supports [http://], [https://], [file://], [data:]). *)

val set_html : t -> string -> unit
(** Load the given HTML string as the document. *)

val init : t -> string -> unit
(** Inject JS to be run on every page load, before page scripts. *)

val eval : t -> string -> unit
(** Evaluate JS in the current page. *)

val bind : t -> string -> (string -> string -> unit) -> unit
(** [bind w name f] exposes a JS function [window.name(...)] that calls back
    into [f id req], where [req] is a JSON array string of the JS arguments. The
    callback must eventually answer with {!return} (using [id]).

    The closure is kept alive as a GC root until the webview is destroyed.
    Unbound closure records are retained until destruction so native callbacks
    already queued by WebKit cannot reference freed memory. Raises {!Error} if a
    binding with the same [name] already exists. *)

val bind_with_url : t -> string -> (string -> string -> string -> unit) -> unit
(** Like {!bind}, but the callback also receives the browser's actual current
    URL captured by the native UI callback. This is intended for enforcing a
    trusted-origin boundary; the URL is not supplied by page JavaScript. *)

val unbind : t -> string -> unit
(** [unbind w name] removes the binding [name] created with {!bind}. Native
    bookkeeping is reclaimed safely when the webview is destroyed. *)

val dispatch : t -> (t -> unit) -> unit
(** [dispatch w f] schedules [f] to run once on the UI thread (the thread
    running {!run}), passing it the webview handle. This is the thread-safe way
    to drive the webview from another thread: call e.g. {!eval} or {!set_title}
    from inside [f]. Any exception raised by [f] is contained at the native
    boundary and logged. *)

val defer : t -> (t -> unit) -> unit
(** Schedule [f] for a later native run-loop turn. Unlike {!dispatch}, this must
    be called on the UI thread. It is primarily useful for lifecycle work that
    cannot safely run from inside the platform's serial dispatch queue. *)

val return : t -> string -> error:bool -> result:string -> unit
(** [return w id ~error ~result] resolves (or rejects, if [error]) the JS
    promise associated with the call [id]. [result] must be a JSON value. *)

type version_info = {
  major : int;
  minor : int;
  patch : int;
  version_number : string;  (** SemVer ["MAJOR.MINOR.PATCH"] string *)
  pre_release : string;  (** SemVer pre-release labels, or [""] *)
  build_metadata : string;  (** SemVer build metadata, or [""] *)
}
(** The library's version information, as returned by {!version}. *)

val version : unit -> version_info
(** The webview library's version information. *)

(** The kind of native handle to retrieve with {!get_native_handle}, mirrors
    [WEBVIEW_NATIVE_HANDLE_KIND_*]. *)
type native_handle_kind =
  | Ui_window  (** top-level window: [NSWindow]/[GtkWindow]/[HWND] *)
  | Ui_widget  (** browser widget: [NSView]/[GtkWidget]/[HWND] *)
  | Browser_controller
      (** [WKWebView]/[WebKitWebView]/[ICoreWebView2Controller] *)

val get_window : t -> nativeint
(** [get_window w] returns the native top-level window handle as a pointer ([0n]
    if unavailable). Interpret it with platform-specific FFI. *)

val get_native_handle : t -> native_handle_kind -> nativeint
(** [get_native_handle w kind] returns the requested native handle as a pointer
    ([0n] if unavailable). *)

val set_app_icon : t -> string -> unit
(** [set_app_icon w path] sets the application/window icon from an image file,
    so a plain executable shows a custom icon instead of the generic one:

    - {b macOS}: the Dock icon (application-global; [w] is ignored).
    - {b Linux/GTK}: the window's icon (taskbar/switcher).
    - {b Windows}: the window's icon via [WM_SETICON] — Win32 loads [.ico]
      files, so a [.png] will not decode there.

    Raises {!Error} if the image cannot be loaded; a no-op on other backends.

    On macOS the process only becomes a regular (Dock-visible) app once {!run}
    has started, so call this {b once the app is active} — e.g. from a
    {!dispatch} callback — otherwise the Dock ignores it. *)

val current_url : t -> string
(** Return the current top-level browser URL, or the empty string before the
    first navigation. UI-thread-only. *)

val reload : t -> unit
(** Reload the current document. UI-thread-only. *)

val on_close : t -> (unit -> unit) -> unit
(** Install the one per-window callback invoked when the native window closes.
    The callback is rooted until {!destroy}. UI-thread-only. *)

val set_close_handler : t -> (unit -> bool) -> unit
(** Install close interception. Returning [false] keeps the window open, which
    is useful for unsaved-state confirmation. The handler must return quickly.
*)

type navigation_action = Allow | Reject | Open_external

val set_navigation_handler : t -> (string -> navigation_action) -> unit
(** Install a native top-level navigation policy. [Open_external] cancels the
    WebView navigation and opens the URL using the operating system. The
    callback runs synchronously on the UI thread and must return quickly. *)

val open_external : string -> unit
(** Open a URL using the operating system's default application. *)

type window_command =
  | Show
  | Hide
  | Focus
  | Minimize
  | Maximize
  | Restore
  | Enter_fullscreen
  | Exit_fullscreen
  | Request_close

val window_command : t -> window_command -> unit
(** Perform a portable desktop-window command. UI-thread-only. *)

val set_position : t -> x:int -> y:int -> unit

type system_theme = Light | Dark | Unknown

val system_theme : t -> system_theme
(** Query the current operating-system/window theme. UI-thread-only. *)

val on_theme_change : t -> (system_theme -> unit) -> unit
(** Install the one native system-theme notification callback supported by the
    backend. Raises [Missing_dependency] when native notifications are not
    implemented. UI-thread-only. *)

type dialog_kind =
  | Message
  | Open_file
  | Open_files
  | Open_directory
  | Save_file

val dialog_async :
  t ->
  dialog_kind ->
  title:string ->
  detail:string ->
  ((string array, error) result -> unit) ->
  unit
(** Start a native window-attached dialog using a callback result. On Cocoa,
    presentation is fully asynchronous and this function returns immediately.
    The completion callback receives selected paths; cancellation and message
    dialogs produce an empty array. Only one dialog may be active per window.
    Starting the dialog is UI-thread-only; its completion is delivered on the UI
    thread and is contained at the native callback boundary. The legacy GTK3
    backend currently invokes the callback only after its synchronous native
    dialog returns. *)

val cancel_dialog : t -> unit
(** Request cancellation of the active native dialog, if any. The dialog's
    completion callback still runs exactly once. UI-thread-only. *)

type platform_backend =
  | Cocoa_webkit
  | Gtk_webkit_6_0
  | Gtk_webkit_4_1
  | Gtk_webkit_4_0
  | Webview2
  | Unknown_backend

val platform_backend : unit -> platform_backend
(** Return the backend selected at build time. *)

val clipboard_read : t -> string option
val clipboard_write : t -> string -> unit

(** Filesystem helpers for locating on-disk assets (HTML/CSS/JS) relative to the
    running executable, independently of the current working directory. *)
module Utils : sig
  val exe_dir : unit -> string
  (** Absolute path to the directory containing the running executable. *)

  val asset_dir : unit -> string
  (** Directory to resolve on-disk assets against. When launched via
      [dune exec], the executable lives under [_build/<context>/], where the
      source assets are not copied; this maps such a path back to the matching
      source directory. From an installed location the executable directory is
      used as-is. *)

  val web_dir : unit -> string
  (** Directory to resolve web assets against. This is [asset_dir]/web. *)
end
