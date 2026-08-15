type t
type subscription

type frontend = {
  generation : int;
  protocol_version : int;
  frontend_build_id : string;
  application_version : string option;
  capabilities : string list;
}

val create :
  ?binding_capacity:int ->
  ?required_capabilities:string list ->
  ?trusted_origins:string list ->
  ?is_trusted_url:(string -> bool) ->
  ?on_error:(string -> unit) ->
  sw:Eio.Switch.t ->
  now:(unit -> float) ->
  sleep:(float -> unit) ->
  Webview_eio.t ->
  t
(** [trusted_origins] defaults to the non-network origins used by
    {!Webview.set_html}. Application asset windows should pass their explicit
    asset origin. [is_trusted_url], when supplied, is an additional predicate.
    The actual URL is captured by the native callback rather than trusted from
    JavaScript input. *)

val app : t -> Webview_eio.t
val sw : t -> Eio.Switch.t
val sleep : t -> float -> unit
val now : t -> float
val next_id : t -> string -> string
val ready_generation : t -> int
val frontend : t -> frontend option

val await_ready : t -> unit
(** [await_ready t] waits for a compatible frontend handshake. It raises a
    closed-handle {!Webview.Error} if the window closes first. *)

val report_exception :
  t -> context:string -> exn -> Printexc.raw_backtrace -> unit

val register :
  t ->
  kind:string ->
  ?name:string ->
  (Owebview_protocol.Envelope.t ->
  (Owebview_protocol.Envelope.t, Owebview_protocol.Rpc_error.t) result) ->
  subscription

val unsubscribe : subscription -> unit
val subscription : t -> (unit -> unit) -> subscription

val emit :
  t ->
  Owebview_protocol.Envelope.t ->
  (unit, Owebview_protocol.Rpc_error.t) result

val call_frontend :
  ?timeout:float ->
  t ->
  Owebview_protocol.Envelope.t ->
  (Owebview_protocol.Envelope.t, Owebview_protocol.Rpc_error.t) result
