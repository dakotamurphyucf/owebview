module Protocol = Owebview_protocol

exception Request_cancelled

type packed_handler =
  | Handler :
      ('request, 'response) Protocol.Endpoint.t
      * ('request -> ('response, Protocol.Rpc_error.t) result)
      -> packed_handler

module Server = struct
  type t = {
    transport : Transport.t;
    handlers : (string, packed_handler) Hashtbl.t;
    pending : (string, unit -> unit) Hashtbl.t;
    cancelled : (string, unit) Hashtbl.t;
    cancelled_order : string Queue.t;
  }

  let rpc_error ?data ~code message =
    Protocol.Rpc_error.make ?data ~code message

  let create transport =
    let server =
      {
        transport;
        handlers = Hashtbl.create 32;
        pending = Hashtbl.create 32;
        cancelled = Hashtbl.create 32;
        cancelled_order = Queue.create ();
      }
    in
    ignore
      (Transport.register transport ~kind:"rpc.cancel" (fun envelope ->
           match Protocol.Json.string_member "request_id" envelope.payload with
           | Error message -> Error (rpc_error ~code:"invalid_request" message)
           | Ok request_id -> (
               match Hashtbl.find_opt server.pending request_id with
               | None ->
                   if not (Hashtbl.mem server.cancelled request_id) then (
                     Hashtbl.add server.cancelled request_id ();
                     Queue.add request_id server.cancelled_order);
                   while Queue.length server.cancelled_order > 4096 do
                     Hashtbl.remove server.cancelled
                       (Queue.take server.cancelled_order)
                   done;
                   Ok
                     (Protocol.Envelope.make ?id:envelope.id
                        ~kind:"rpc.cancelled" `Null)
               | Some cancel ->
                   cancel ();
                   Ok
                     (Protocol.Envelope.make ?id:envelope.id
                        ~kind:"rpc.cancelled" `Null))));
    ignore
      (Transport.register transport ~kind:"rpc.call" (fun envelope ->
           match
             ( envelope.id,
               Protocol.Json.string_member "method" envelope.payload,
               Protocol.Json.member "request" envelope.payload )
           with
           | None, _, _ ->
               Error (rpc_error ~code:"invalid_request" "RPC request has no id")
           | _, Error message, _ | _, _, Error message ->
               Error (rpc_error ~code:"invalid_request" message)
           | Some request_id, Ok method_name, Ok encoded -> (
               if Hashtbl.mem server.cancelled request_id then (
                 Hashtbl.remove server.cancelled request_id;
                 Error (rpc_error ~code:"cancelled" "RPC request was cancelled"))
               else
                 match Hashtbl.find_opt server.handlers method_name with
                 | None ->
                     Error
                       (rpc_error ~code:"method_not_found"
                          "RPC endpoint is not registered")
                 | Some (Handler (endpoint, handler)) -> (
                     match
                       Protocol.Codec.decode
                         (Protocol.Endpoint.request endpoint)
                         encoded
                     with
                     | Error message ->
                         Error (rpc_error ~code:"decode_error" message)
                     | Ok request -> (
                         try
                           Eio.Switch.run ~name:("rpc." ^ method_name)
                           @@ fun request_sw ->
                           Hashtbl.replace server.pending request_id (fun () ->
                               Eio.Switch.fail request_sw Request_cancelled);
                           Fun.protect
                             (fun () ->
                               match handler request with
                               | Ok response ->
                                   Ok
                                     (Protocol.Envelope.make ~id:request_id
                                        ~kind:"rpc.ok"
                                        (Protocol.Codec.encode
                                           (Protocol.Endpoint.response endpoint)
                                           response))
                               | Error error -> Error error)
                             ~finally:(fun () ->
                               Hashtbl.remove server.pending request_id)
                         with
                         | Request_cancelled ->
                             Error
                               (rpc_error ~code:"cancelled"
                                  "RPC request was cancelled")
                         | exn ->
                             let backtrace = Printexc.get_raw_backtrace () in
                             Transport.report_exception server.transport
                               ~context:("RPC handler " ^ method_name)
                               exn backtrace;
                             Error
                               (rpc_error ~code:"handler_exception"
                                  "the RPC handler raised an exception"))))));
    server

  let handle server endpoint handler =
    let name = Protocol.Endpoint.name endpoint in
    if Hashtbl.mem server.handlers name then
      invalid_arg ("duplicate RPC endpoint: " ^ name);
    Hashtbl.add server.handlers name (Handler (endpoint, handler));
    Transport.subscription server.transport (fun () ->
        Hashtbl.remove server.handlers name)
end
