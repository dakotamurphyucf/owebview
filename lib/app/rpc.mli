exception Request_cancelled

module Server : sig
  type t

  val create : Transport.t -> t

  val handle :
    t ->
    ('request, 'response) Owebview_protocol.Endpoint.t ->
    ('request -> ('response, Owebview_protocol.Rpc_error.t) result) ->
    Transport.subscription
end
