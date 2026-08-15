type backend =
  | Cocoa_webkit
  | Gtk_webkit of [ `V6_0 | `V4_1 | `V4_0 ]
  | Webview2
  | Unknown

type capability =
  | Multiple_windows
  | Navigation_policy
  | Native_dialogs
  | Clipboard_read
  | Clipboard_write
  | Theme_query
  | Theme_notifications
  | Permission_policy
  | Native_permission_delegates
  | Download_policy
  | Native_downloads
  | Custom_scheme
  | Development_tools

type validation = Validated | Compiled_unvalidated | Unsupported

val backend : unit -> backend
val validation : unit -> validation
val capabilities : unit -> capability list
val supports : capability -> bool
val string_of_backend : backend -> string
