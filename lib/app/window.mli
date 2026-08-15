type size = { width : int; height : int }
type config

val config :
  ?title:string ->
  ?width:int ->
  ?height:int ->
  ?min_size:size ->
  ?max_size:size ->
  ?resizable:bool ->
  ?debug:bool ->
  ?navigation:Navigation.policy ->
  Assets.t ->
  config

type t = Webview_eio.t

val configure : t -> config -> unit
val create : sw:Eio.Switch.t -> ?before_load:(t -> unit) -> t -> config -> t

val transport :
  ?binding_capacity:int ->
  ?required_capabilities:string list ->
  ?on_error:(string -> unit) ->
  sw:Eio.Switch.t ->
  now:(unit -> float) ->
  sleep:(float -> unit) ->
  config ->
  t ->
  Transport.t

val close : t -> unit
val await_closed : t -> unit
val is_closed : t -> bool
val set_title : t -> string -> unit
val set_size : t -> width:int -> height:int -> Webview.hint -> unit
val set_position : t -> x:int -> y:int -> unit
val show : t -> unit
val hide : t -> unit
val focus : t -> unit
val minimize : t -> unit
val maximize : t -> unit
val restore : t -> unit
val set_fullscreen : t -> bool -> unit
val reload : t -> unit
val current_url : t -> string
val intercept_close : t -> (unit -> bool) -> unit
val on_closed : sw:Eio.Switch.t -> t -> (unit -> unit) -> unit
