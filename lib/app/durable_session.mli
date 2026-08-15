type lifecycle =
  | Running
  | Recovering
  | Interrupted
  | Completed
  | Failed
  | Cancelled

val string_of_lifecycle : lifecycle -> string

type terminal =
  | Finished of Owebview_protocol.Json.t
  | Failed_with of Owebview_protocol.Rpc_error.t
  | Cancelled_with of Owebview_protocol.Rpc_error.t

type stored_event = {
  sequence : int64;
  timestamp : float;
  encoded : Owebview_protocol.Json.t;
}

type command_status =
  | Admitted
  | Applied
  | Rejected of Owebview_protocol.Rpc_error.t

type stored_command = {
  id : string;
  encoded : Owebview_protocol.Json.t;
  status : command_status;
  created_at : float;
  updated_at : float;
}

type stored_acknowledgement = {
  subscriber_id : string;
  sequence : int64;
  updated_at : float;
}

type stored_session = {
  schema_version : int;
  id : string;
  endpoint : string;
  request : Owebview_protocol.Json.t;
  lifecycle : lifecycle;
  events : stored_event list;
  terminal : terminal option;
  commands : stored_command list;
  acknowledgements : stored_acknowledgement list;
  checkpoint : Owebview_protocol.Json.t option;
  created_at : float;
  updated_at : float;
}

module Persistence : sig
  type t

  val make :
    load_all:(unit -> stored_session list) ->
    save:(stored_session -> unit) ->
    delete:(string -> unit) ->
    t

  val memory : unit -> t
  val directory : string -> t
end

type summary = {
  id : string;
  endpoint : string;
  lifecycle : lifecycle;
  latest_sequence : int64;
  created_at : float;
  updated_at : float;
}

type authorization_action =
  | List_sessions
  | Open_endpoint of string
  | Attach_session of string
  | Command_session of string
  | Cancel_session of string

type t
type packed_session
type 'command accepted_command = { id : string; value : 'command }

exception Session_cancelled

module Session : sig
  type ('event, 'command, 'result) t

  type 'command command = 'command accepted_command = {
    id : string;
    value : 'command;
  }

  val id : ('event, 'command, 'result) t -> string
  val lifecycle : ('event, 'command, 'result) t -> lifecycle
  val commands : ('event, 'command, 'result) t -> 'command command Eio.Stream.t
  val is_cancelled : ('event, 'command, 'result) t -> bool

  val checkpoint :
    ('event, 'command, 'result) t -> Owebview_protocol.Json.t option

  val save_checkpoint :
    ('event, 'command, 'result) t ->
    Owebview_protocol.Json.t option ->
    (unit, Owebview_protocol.Rpc_error.t) result
  (** Persist application-specific orchestration state or an external-run
      reference. The library stores but does not interpret this value. *)

  val mark_command_applied :
    ('event, 'command, 'result) t ->
    'command command ->
    (unit, Owebview_protocol.Rpc_error.t) result
  (** Durably mark an admitted command as applied after the application has
      completed its effect. *)

  val mark_command_rejected :
    ('event, 'command, 'result) t ->
    'command command ->
    Owebview_protocol.Rpc_error.t ->
    (unit, Owebview_protocol.Rpc_error.t) result
  (** Durably mark an admitted command as rejected. Commands left [Admitted]
      across a crash require application-specific reconciliation. *)

  val emit :
    ('event, 'command, 'result) t ->
    'event ->
    (unit, Owebview_protocol.Rpc_error.t) result

  val finish :
    ('event, 'command, 'result) t ->
    'result ->
    (unit, Owebview_protocol.Rpc_error.t) result

  val fail :
    ('event, 'command, 'result) t ->
    Owebview_protocol.Rpc_error.t ->
    (unit, Owebview_protocol.Rpc_error.t) result
end

val create :
  ?max_sessions:int ->
  sw:Eio.Switch.t ->
  now:(unit -> float) ->
  persistence:Persistence.t ->
  unit ->
  t

val handle :
  ?command_capacity:int ->
  t ->
  ('request, 'event, 'command, 'result) Owebview_protocol.Stream_endpoint.t ->
  (('event, 'command, 'result) Session.t -> 'request -> unit) ->
  unit

val start :
  ?command_capacity:int ->
  t ->
  ('request, 'event, 'command, 'result) Owebview_protocol.Stream_endpoint.t ->
  'request ->
  (('event, 'command, 'result) Session.t -> 'request -> unit) ->
  (('event, 'command, 'result) Session.t, Owebview_protocol.Rpc_error.t) result

val retry : t -> string -> (string, Owebview_protocol.Rpc_error.t) result
(** Start a new session from the persisted request of an [Interrupted] session.
    The interrupted history remains immutable and discoverable; the returned
    identifier names the new run. *)

val connect :
  ?event_capacity:int ->
  ?event_byte_capacity:int ->
  ?flush_interval:float ->
  ?max_batch_bytes:int ->
  ?authorize:(subscriber_id:string -> authorization_action -> bool) ->
  t ->
  Transport.t ->
  Transport.subscription
(** Attach one window transport. Each session subscription receives its own
    bounded delivery queue and batching fiber. A subscriber that exceeds its
    count or byte limit is detached without blocking session producers or other
    windows. [authorize] defaults to allowing every action from the already
    trusted transport origin. *)

val list : t -> summary list
val find : t -> string -> packed_session option
val snapshot : t -> string -> stored_session option

val admitted_commands : t -> session_id:string -> stored_command list
(** Return commands still requiring application-specific crash reconciliation.
*)

val mark_command_applied :
  t ->
  session_id:string ->
  command_id:string ->
  (unit, Owebview_protocol.Rpc_error.t) result

val mark_command_rejected :
  t ->
  session_id:string ->
  command_id:string ->
  Owebview_protocol.Rpc_error.t ->
  (unit, Owebview_protocol.Rpc_error.t) result

val delete : t -> string -> (unit, Owebview_protocol.Rpc_error.t) result
(** Delete a non-running session from memory and durable storage. *)

val compact : ?max_age:float -> ?keep_latest:int -> t -> int
(** Delete non-running sessions older than [max_age] seconds, then retain at
    most [keep_latest] of the remaining non-running sessions. Returns the number
    deleted. Persistence failures are raised and do not remove the corresponding
    live record. *)

val shutdown : t -> unit
(** Stop live orchestration fibers without changing their persisted lifecycle. A
    later registry restores such records as {!Interrupted}. Application shutdown
    caused by switch cancellation does this automatically; this function is
    useful for orderly process-restart simulations. *)
