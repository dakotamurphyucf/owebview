type external_urls = Reject | Open_system
type policy

val default :
  trusted_origins:string list ->
  ?external_urls:external_urls ->
  ?allow_about_blank:bool ->
  unit ->
  policy

val trusted_origins : policy -> string list
val is_trusted : policy -> string -> bool
val decide : policy -> string -> Webview.navigation_action
val install : Webview_eio.t -> policy -> unit
