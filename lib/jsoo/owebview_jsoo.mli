module Promise = Js_of_ocaml.Promise

type t
type subscription

val create : ?client_identifier:string -> ?max_pending_events:int -> unit -> t
(** [client_identifier] supplies a stable per-window identity for durable
    session authorization and acknowledgement cursors. A random identifier is
    generated when omitted. *)

val install : t -> unit

val ready :
  ?protocol_version:int ->
  ?frontend_build_id:string ->
  ?application_version:string ->
  ?capabilities:string list ->
  t ->
  (unit, Owebview_protocol.Rpc_error.t) result Promise.t

val unsubscribe : subscription -> unit

module Rpc : sig
  type 'response call = {
    id : string;
    result : ('response, Owebview_protocol.Rpc_error.t) result Promise.t;
  }

  val call :
    t ->
    ('request, 'response) Owebview_protocol.Endpoint.t ->
    'request ->
    ('response, Owebview_protocol.Rpc_error.t) result Promise.t

  val call_with_id :
    t ->
    ('request, 'response) Owebview_protocol.Endpoint.t ->
    'request ->
    'response call

  val cancel :
    t -> string -> (unit, Owebview_protocol.Rpc_error.t) result Promise.t
end

module Frontend : sig
  val handle :
    t ->
    ('request, 'response) Owebview_protocol.Frontend_endpoint.t ->
    ('request -> ('response, Owebview_protocol.Rpc_error.t) result Promise.t) ->
    subscription
end

module Event : sig
  val subscribe :
    t -> 'event Owebview_protocol.Event.t -> ('event -> unit) -> subscription
end

module Durable_session : sig
  type lifecycle =
    | Running
    | Recovering
    | Interrupted
    | Completed
    | Failed
    | Cancelled

  type summary = {
    id : string;
    endpoint : string;
    lifecycle : lifecycle;
    latest_sequence : int64;
    created_at : float;
    updated_at : float;
  }

  val list : t -> (summary list, Owebview_protocol.Rpc_error.t) result Promise.t
end

module Stream : sig
  type ('event, 'command, 'result) stream

  val open_ :
    t ->
    ('request, 'event, 'command, 'result) Owebview_protocol.Stream_endpoint.t ->
    'request ->
    (('event, 'command, 'result) stream, Owebview_protocol.Rpc_error.t) result
    Promise.t

  val attach :
    t ->
    ('request, 'event, 'command, 'result) Owebview_protocol.Stream_endpoint.t ->
    stream_id:string ->
    after_sequence:int64 ->
    (('event, 'command, 'result) stream, Owebview_protocol.Rpc_error.t) result
    Promise.t

  val id : ('event, 'command, 'result) stream -> string
  val last_sequence : ('event, 'command, 'result) stream -> int64

  val on_event :
    ('event, 'command, 'result) stream -> ('event -> unit) -> subscription

  val send :
    ('event, 'command, 'result) stream ->
    'command ->
    (unit, Owebview_protocol.Rpc_error.t) result Promise.t

  val send_with_id :
    ('event, 'command, 'result) stream ->
    command_id:string ->
    'command ->
    (unit, Owebview_protocol.Rpc_error.t) result Promise.t
  (** Send a command with an application-stable identifier. Durable registries
      deduplicate retries and multi-window responses using this identifier. *)

  val finished :
    ('event, 'command, 'result) stream ->
    ('result, Owebview_protocol.Rpc_error.t) result Promise.t

  val cancel :
    ('event, 'command, 'result) stream ->
    (unit, Owebview_protocol.Rpc_error.t) result Promise.t

  val detach :
    ('event, 'command, 'result) stream ->
    (unit, Owebview_protocol.Rpc_error.t) result Promise.t

  val resume :
    ('event, 'command, 'result) stream ->
    after_sequence:int64 ->
    (unit, Owebview_protocol.Rpc_error.t) result Promise.t
end
