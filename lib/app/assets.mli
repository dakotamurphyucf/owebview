type mode = Production | Development
type entry = { path : string; mime : string; content : string; hash : string }
type bundle

val bundle : (string * string) list -> bundle
val entries : bundle -> entry list

type source =
  | Directory : 'a Eio.Path.t -> source
  | Embedded of bundle
  | Development_server of Uri.t

type t

val start :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?mode:mode ->
  ?index:string ->
  ?content_security_policy:string ->
  source ->
  t

val mode : t -> mode
val origin : t -> string
val trusted_origins : t -> string list
val url : t -> string -> string
val index_url : t -> string

val navigation_policy :
  ?external_urls:Navigation.external_urls -> t -> Navigation.policy

val load : Webview_eio.t -> t -> unit
