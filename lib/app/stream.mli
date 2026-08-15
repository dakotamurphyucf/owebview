exception Stream_cancelled

module Session : sig
  type ('event, 'command, 'result) t

  val id : ('event, 'command, 'result) t -> string

  val emit :
    ('event, 'command, 'result) t ->
    'event ->
    (unit, Owebview_protocol.Rpc_error.t) result

  val commands : ('event, 'command, 'result) t -> 'command Eio.Stream.t
  (** Commands in this queue have been accepted by the bounded native queue. The
      wire acknowledgement means accepted, not application processing completed.
      Application-level command results should be represented by typed stream
      events. *)

  val finish :
    ('event, 'command, 'result) t ->
    'result ->
    (unit, Owebview_protocol.Rpc_error.t) result

  val fail :
    ('event, 'command, 'result) t ->
    Owebview_protocol.Rpc_error.t ->
    (unit, Owebview_protocol.Rpc_error.t) result

  val is_cancelled : ('event, 'command, 'result) t -> bool
end

module Server : sig
  type t

  val create :
    ?max_sessions:int -> ?terminal_retention:float -> Transport.t -> t
  (** [max_sessions] bounds active and grace-period terminal sessions.
      [terminal_retention] is the number of seconds a terminal result remains
      attachable for reload recovery. *)

  val handle :
    ?event_capacity:int ->
    ?event_byte_capacity:int ->
    ?command_capacity:int ->
    ?replay_capacity:int ->
    ?replay_byte_capacity:int ->
    ?flush_interval:float ->
    ?max_batch_bytes:int ->
    ?flush_immediately:('event -> bool) ->
    ?coalesce:('event -> 'event -> 'event option) ->
    t ->
    ('request, 'event, 'command, 'result) Owebview_protocol.Stream_endpoint.t ->
    (('event, 'command, 'result) Session.t -> 'request -> unit) ->
    Transport.subscription
  (** Event and replay storage are bounded independently by count and encoded
      byte size. [flush_immediately] identifies critical events that bypass the
      normal batching delay. *)
end
