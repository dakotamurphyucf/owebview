val emit :
  Transport.t ->
  'event Owebview_protocol.Event.t ->
  'event ->
  (unit, Owebview_protocol.Rpc_error.t) result
