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

let backend () =
  match Webview.platform_backend () with
  | Cocoa_webkit -> Cocoa_webkit
  | Gtk_webkit_6_0 -> Gtk_webkit `V6_0
  | Gtk_webkit_4_1 -> Gtk_webkit `V4_1
  | Gtk_webkit_4_0 -> Gtk_webkit `V4_0
  | Webview2 -> Webview2
  | Unknown_backend -> Unknown

let validation () =
  match backend () with
  | Cocoa_webkit -> Validated
  | Gtk_webkit _ | Webview2 -> Compiled_unvalidated
  | Unknown -> Unsupported

let capabilities () =
  let desktop_baseline =
    [
      Multiple_windows;
      Navigation_policy;
      Native_dialogs;
      Clipboard_write;
      Theme_query;
      Theme_notifications;
      Permission_policy;
      Download_policy;
      Development_tools;
    ]
  in
  match backend () with
  | Cocoa_webkit | Gtk_webkit (`V4_1 | `V4_0) ->
      Clipboard_read :: desktop_baseline
  | Gtk_webkit `V6_0 ->
      [
        Multiple_windows;
        Navigation_policy;
        Clipboard_write;
        Theme_query;
        Theme_notifications;
        Permission_policy;
        Download_policy;
        Development_tools;
      ]
  | Webview2 -> [ Development_tools ]
  | Unknown -> []

let supports capability = List.mem capability (capabilities ())

let string_of_backend = function
  | Cocoa_webkit -> "cocoa-webkit"
  | Gtk_webkit `V6_0 -> "gtk4-webkitgtk-6.0"
  | Gtk_webkit `V4_1 -> "gtk3-webkitgtk-4.1"
  | Gtk_webkit `V4_0 -> "gtk3-webkitgtk-4.0"
  | Webview2 -> "webview2"
  | Unknown -> "unknown"
