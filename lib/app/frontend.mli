val call :
  ?timeout:float ->
  Transport.t ->
  ('request, 'response) Owebview_protocol.Frontend_endpoint.t ->
  'request ->
  ('response, Owebview_protocol.Rpc_error.t) result
