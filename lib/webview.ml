type t
(* Runtime representation is a custom block containing managed native state. *)

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

type native_error = {
  native_operation : string;
  native_code : int;
  native_message : string;
}

exception Native_error of native_error

let () =
  Callback.register_exception "owebview.native_error"
    (Native_error
       { native_operation = ""; native_code = 0; native_message = "" })

let error_code = function
  | -5 -> Missing_dependency
  | -4 -> Canceled
  | -3 -> Invalid_state
  | -2 -> Invalid_argument
  | -1 -> Native_error (-1)
  | 1 -> Duplicate
  | 2 -> Not_found
  | -1000 -> Closed
  | -1001 -> Closing
  | -1002 -> Wrong_thread
  | -1003 -> Invalid_lifecycle
  | -1005 -> Out_of_memory
  | code -> Native_error code

let string_of_error_code = function
  | Missing_dependency -> "missing_dependency"
  | Canceled -> "canceled"
  | Invalid_state -> "invalid_state"
  | Invalid_argument -> "invalid_argument"
  | Duplicate -> "duplicate"
  | Not_found -> "not_found"
  | Closed -> "closed"
  | Closing -> "closing"
  | Wrong_thread -> "wrong_thread"
  | Invalid_lifecycle -> "invalid_lifecycle"
  | Out_of_memory -> "out_of_memory"
  | Native_error code -> Printf.sprintf "native_error(%d)" code

let pp_error formatter error =
  Format.fprintf formatter "%s: %s: %s" error.operation
    (string_of_error_code error.code)
    error.message

let protect f =
  try f ()
  with
  | Native_error
      {
        native_operation = operation;
        native_code = code;
        native_message = message;
      }
  ->
    raise (Error { operation; code = error_code code; message })

type hint = Hint_none | Hint_min | Hint_max | Hint_fixed

(** This function is not required, as the enum representation is an int, but
    will ensure safety in case of reodering *)
let int_of_hint = function
  | Hint_none -> 0
  | Hint_min -> 1
  | Hint_max -> 2
  | Hint_fixed -> 3

(* The constant constructors above map to 0,1,2,3 at runtime, which matches
   WEBVIEW_HINT_NONE/MIN/MAX/FIXED, so they can be passed straight to C. *)

type native_handle_kind = Ui_window | Ui_widget | Browser_controller
type navigation_action = Allow | Reject | Open_external

let int_of_navigation_action = function
  | Allow -> 0
  | Reject -> 1
  | Open_external -> 2

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

type system_theme = Light | Dark | Unknown

type dialog_kind =
  | Message
  | Open_file
  | Open_files
  | Open_directory
  | Save_file

type platform_backend =
  | Cocoa_webkit
  | Gtk_webkit_6_0
  | Gtk_webkit_4_1
  | Gtk_webkit_4_0
  | Webview2
  | Unknown_backend

let int_of_window_command = function
  | Show -> 0
  | Hide -> 1
  | Focus -> 2
  | Minimize -> 3
  | Maximize -> 4
  | Restore -> 5
  | Enter_fullscreen -> 6
  | Exit_fullscreen -> 7
  | Request_close -> 8

(* Like [int_of_hint]: explicit mapping so reordering the variant stays safe.
   Matches WEBVIEW_NATIVE_HANDLE_KIND_UI_WINDOW/UI_WIDGET/BROWSER_CONTROLLER. *)
let int_of_native_handle_kind = function
  | Ui_window -> 0
  | Ui_widget -> 1
  | Browser_controller -> 2

(* Field order must match the record block built by the C stub
   (ocaml_webview_version). *)
type version_info = {
  major : int;
  minor : int;
  patch : int;
  version_number : string;
  pre_release : string;
  build_metadata : string;
}

external _create : bool -> t = "ocaml_webview_create"
external _destroy : t -> unit = "ocaml_webview_destroy"
external _is_closed : t -> bool = "ocaml_webview_is_closed"
external _run : t -> unit = "ocaml_webview_run"
external _terminate : t -> unit = "ocaml_webview_terminate"
external _set_title : t -> string -> unit = "ocaml_webview_set_title"
external _set_size : t -> int -> int -> int -> unit = "ocaml_webview_set_size"
external _navigate : t -> string -> unit = "ocaml_webview_navigate"
external _set_html : t -> string -> unit = "ocaml_webview_set_html"
external _init : t -> string -> unit = "ocaml_webview_init"
external _eval : t -> string -> unit = "ocaml_webview_eval"

external _bind : t -> string -> (string -> string -> unit) -> unit
  = "ocaml_webview_bind"

external _bind_with_url :
  t -> string -> (string -> string -> string -> unit) -> unit
  = "ocaml_webview_bind_with_url"

external _unbind : t -> string -> unit = "ocaml_webview_unbind"
external _dispatch : t -> (t -> unit) -> unit = "ocaml_webview_dispatch"
external _defer : t -> (t -> unit) -> unit = "ocaml_webview_defer"
external _return : t -> string -> int -> string -> unit = "ocaml_webview_return"
external _version : unit -> version_info = "ocaml_webview_version"
external _get_window : t -> nativeint = "ocaml_webview_get_window"

external _get_native_handle : t -> int -> nativeint
  = "ocaml_webview_get_native_handle"

external _set_app_icon : t -> string -> unit = "ocaml_webview_set_app_icon"
external _current_url : t -> string = "ocaml_webview_current_url"
external _reload : t -> unit = "ocaml_webview_reload"
external _on_close : t -> (unit -> unit) -> unit = "ocaml_webview_on_close"

external _set_close_handler : t -> (unit -> bool) -> unit
  = "ocaml_webview_set_close_handler"

external _set_navigation_handler : t -> (string -> int) -> unit
  = "ocaml_webview_set_navigation_handler"

external _open_external : string -> unit = "ocaml_webview_open_external"
external _window_command : t -> int -> unit = "ocaml_webview_window_command"
external _set_position : t -> int -> int -> unit = "ocaml_webview_set_position"
external _system_theme : t -> int = "ocaml_webview_system_theme"

external _on_theme_change : t -> (int -> unit) -> unit
  = "ocaml_webview_on_theme_change"

external _dialog_async :
  t -> int * string * string -> (int * string * string array -> unit) -> unit
  = "ocaml_webview_dialog_async"

external _cancel_dialog : t -> unit = "ocaml_webview_cancel_dialog"
external _platform_backend : unit -> int = "ocaml_webview_platform_backend"
external _clipboard_read : t -> string option = "ocaml_webview_clipboard_read"

external _clipboard_write : t -> string -> unit
  = "ocaml_webview_clipboard_write"

let create ?(debug = false) () = protect (fun () -> _create debug)
let destroy w = protect (fun () -> _destroy w)
let is_closed w = _is_closed w
let run w = protect (fun () -> _run w)
let terminate w = protect (fun () -> _terminate w)
let set_title w title = protect (fun () -> _set_title w title)

let set_size w ~width ~height hint =
  protect (fun () -> _set_size w width height (int_of_hint hint))

let navigate w url = protect (fun () -> _navigate w url)
let set_html w html = protect (fun () -> _set_html w html)
let init w js = protect (fun () -> _init w js)
let eval w js = protect (fun () -> _eval w js)
let bind w name f = protect (fun () -> _bind w name f)
let bind_with_url w name f = protect (fun () -> _bind_with_url w name f)
let unbind w name = protect (fun () -> _unbind w name)
let dispatch w f = protect (fun () -> _dispatch w f)
let defer w f = protect (fun () -> _defer w f)

let return w id ~error ~result =
  protect (fun () -> _return w id (if error then 1 else 0) result)

let version () = protect (fun () -> _version ())
let get_window w = protect (fun () -> _get_window w)

let get_native_handle w kind =
  protect (fun () -> _get_native_handle w (int_of_native_handle_kind kind))

let set_app_icon w path = protect (fun () -> _set_app_icon w path)
let current_url w = protect (fun () -> _current_url w)
let reload w = protect (fun () -> _reload w)
let on_close w f = protect (fun () -> _on_close w f)
let set_close_handler w f = protect (fun () -> _set_close_handler w f)

let set_navigation_handler w f =
  protect (fun () ->
      _set_navigation_handler w (fun url -> int_of_navigation_action (f url)))

let open_external url = protect (fun () -> _open_external url)

let window_command w command =
  protect (fun () -> _window_command w (int_of_window_command command))

let set_position w ~x ~y = protect (fun () -> _set_position w x y)

let system_theme w =
  protect (fun () ->
      match _system_theme w with 0 -> Light | 1 -> Dark | _ -> Unknown)

let on_theme_change w handler =
  protect (fun () ->
      _on_theme_change w (fun value ->
          handler (match value with 0 -> Light | 1 -> Dark | _ -> Unknown)))

let int_of_dialog_kind = function
  | Message -> 0
  | Open_file -> 1
  | Open_files -> 2
  | Open_directory -> 3
  | Save_file -> 4

let dialog_async w kind ~title ~detail completion =
  protect (fun () ->
      _dialog_async w
        (int_of_dialog_kind kind, title, detail)
        (fun (code, message, paths) ->
          if code = 0 then completion (Result.Ok paths)
          else
            completion
              (Result.Error
                 {
                   operation = "native_dialog";
                   code = error_code code;
                   message;
                 })))

let cancel_dialog w = protect (fun () -> _cancel_dialog w)

let platform_backend () =
  match _platform_backend () with
  | 0 -> Cocoa_webkit
  | 1 -> Gtk_webkit_6_0
  | 2 -> Gtk_webkit_4_1
  | 3 -> Gtk_webkit_4_0
  | 4 -> Webview2
  | _ -> Unknown_backend

let clipboard_read w = protect (fun () -> _clipboard_read w)
let clipboard_write w text = protect (fun () -> _clipboard_write w text)

(* Re-export the filesystem helpers as [Webview.Utils]. *)
module Utils = Utils
