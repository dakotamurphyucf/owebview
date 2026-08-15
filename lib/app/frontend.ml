module Protocol = Owebview_protocol

let rpc_error ~code message = Protocol.Rpc_error.make ~code message

let call ?timeout transport endpoint request =
  let id = Transport.next_id transport "frontend" in
  let envelope =
    Protocol.Envelope.make ~id ~kind:"frontend.call"
      (`Assoc
         [
           ("method", `String (Protocol.Frontend_endpoint.name endpoint));
           ( "request",
             Protocol.Codec.encode
               (Protocol.Frontend_endpoint.request endpoint)
               request );
         ])
  in
  match Transport.call_frontend ?timeout transport envelope with
  | Error _ as error -> error
  | Ok response when response.kind = "frontend.response" -> (
      match Protocol.Json.string_member "status" response.payload with
      | Ok "ok" -> (
          match Protocol.Json.member "response" response.payload with
          | Error message -> Error (rpc_error ~code:"invalid_response" message)
          | Ok encoded -> (
              match
                Protocol.Codec.decode
                  (Protocol.Frontend_endpoint.response endpoint)
                  encoded
              with
              | Ok response -> Ok response
              | Error message -> Error (rpc_error ~code:"decode_error" message))
          )
      | Ok "error" -> (
          match Protocol.Json.member "error" response.payload with
          | Error message -> Error (rpc_error ~code:"invalid_response" message)
          | Ok encoded -> (
              match Protocol.Codec.decode Protocol.Rpc_error.codec encoded with
              | Ok error -> Error error
              | Error message ->
                  Error (rpc_error ~code:"invalid_response" message)))
      | Ok status ->
          Error
            (rpc_error ~code:"invalid_response"
               ("unexpected status: " ^ status))
      | Error message -> Error (rpc_error ~code:"invalid_response" message))
  | Ok response ->
      Error
        (rpc_error ~code:"invalid_response"
           ("unexpected response: " ^ response.kind))
