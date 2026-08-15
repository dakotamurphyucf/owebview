open Js_of_ocaml
module Protocol = Owebview_protocol
module Promise = Js_of_ocaml.Promise

type subscription = { mutable active : bool; cancel : unit -> unit }

type packed_frontend_handler =
  | Frontend_handler :
      ('request, 'response) Protocol.Frontend_endpoint.t
      * ('request -> ('response, Protocol.Rpc_error.t) result Promise.t)
      -> packed_frontend_handler

type packed_event_handler =
  | Event_handler :
      'event Protocol.Event.t * ('event -> unit)
      -> packed_event_handler

type packed_stream =
  | Stream_state : ('event, 'command, 'result) stream_state -> packed_stream

and ('event, 'command, 'result) stream_state = {
  owner : t;
  id : string;
  event_codec : 'event Protocol.Codec.t;
  command_codec : 'command Protocol.Codec.t;
  result_codec : 'result Protocol.Codec.t;
  mutable handlers : (int * ('event -> unit)) list;
  mutable pending_events : 'event list;
  mutable pending_event_count : int;
  mutable next_handler : int;
  mutable last_sequence : int64;
  finished_promise : ('result, Protocol.Rpc_error.t) result Promise.t;
  resolve_finished : ('result, Protocol.Rpc_error.t) result -> unit;
}

and t = {
  frontend_handlers : (string, packed_frontend_handler) Hashtbl.t;
  event_handlers : (string, (int * packed_event_handler) list) Hashtbl.t;
  streams : (string, packed_stream) Hashtbl.t;
  mutable next_identifier : int64;
  client_identifier : string;
  mutable next_subscription : int;
  max_pending_events : int;
  mutable installed : bool;
}

let rpc_error ?data ~code message = Protocol.Rpc_error.make ?data ~code message

let unsubscribe subscription =
  if subscription.active then (
    subscription.active <- false;
    subscription.cancel ())

let create ?client_identifier ?(max_pending_events = 4096) () =
  if max_pending_events <= 0 then
    invalid_arg "Owebview_jsoo.create: max_pending_events must be positive";
  let client_identifier =
    match client_identifier with
    | Some "" ->
        invalid_arg "Owebview_jsoo.create: client_identifier must not be empty"
    | Some identifier -> identifier
    | None -> (
        try
          let crypto = Js.Unsafe.get Js.Unsafe.global "crypto" in
          Js.Unsafe.meth_call crypto "randomUUID" [||] |> Js.to_string
        with _ ->
          Random.self_init ();
          String.init 32 (fun _ -> "0123456789abcdef".[Random.int 16]))
  in
  {
    frontend_handlers = Hashtbl.create 16;
    event_handlers = Hashtbl.create 16;
    streams = Hashtbl.create 16;
    next_identifier = 0L;
    client_identifier;
    next_subscription = 0;
    max_pending_events;
    installed = false;
  }

let next_id t prefix =
  t.next_identifier <- Int64.succ t.next_identifier;
  prefix ^ "-" ^ t.client_identifier ^ "-" ^ Int64.to_string t.next_identifier

let native_binding () = Js.Unsafe.get Js.Unsafe.global "__owebview_native"

let promise_error_message error =
  try
    Js.Unsafe.meth_call (Promise.error_to_any error) "toString" [||]
    |> Js.to_string
  with _ -> "JavaScript Promise rejected"

let call_native envelope =
  try
    let encoded = Protocol.Envelope.to_string envelope in
    let raw : Js.Unsafe.any =
      Js.Unsafe.fun_call (native_binding ())
        [| Js.Unsafe.inject (Js.string encoded) |]
    in
    let promise : Js.js_string Js.t Promise.t = Promise.of_any raw in
    Promise.catch
      (fun error ->
        Promise.resolve
          (Error
             (rpc_error ~code:"transport_error" (promise_error_message error))))
      (Promise.map
         (fun encoded ->
           match Protocol.Envelope.of_string (Js.to_string encoded) with
           | Ok envelope -> Ok envelope
           | Error message -> Error (rpc_error ~code:"invalid_envelope" message))
         promise)
  with exn ->
    Promise.resolve
      (Error (rpc_error ~code:"transport_unavailable" (Printexc.to_string exn)))

let decode_error envelope =
  match
    Protocol.Codec.decode Protocol.Rpc_error.codec
      envelope.Protocol.Envelope.payload
  with
  | Ok error -> error
  | Error message -> rpc_error ~code:"invalid_error" message

let expect_unit_response promise ~kind =
  Promise.map
    (function
      | Error error -> Error error
      | Ok envelope when envelope.Protocol.Envelope.kind = kind -> Ok ()
      | Ok envelope when envelope.kind = "error" ->
          Error (decode_error envelope)
      | Ok envelope when String.ends_with ~suffix:"_error" envelope.kind ->
          Error (decode_error envelope)
      | Ok envelope ->
          Error
            (rpc_error ~code:"invalid_response"
               ("unexpected response: " ^ envelope.kind)))
    promise

let send_frontend_response response = ignore (call_native response)

let handle_frontend_call t envelope =
  match
    ( envelope.Protocol.Envelope.id,
      Protocol.Json.string_member "method" envelope.payload,
      Protocol.Json.member "request" envelope.payload )
  with
  | Some id, Ok method_name, Ok encoded -> begin
      match Hashtbl.find_opt t.frontend_handlers method_name with
      | None ->
          send_frontend_response
            (Protocol.Envelope.make ~id ~kind:"frontend.response"
               (`Assoc
                  [
                    ("status", `String "error");
                    ( "error",
                      Protocol.Codec.encode Protocol.Rpc_error.codec
                        (rpc_error ~code:"method_not_found"
                           "frontend method is not registered") );
                  ]))
      | Some (Frontend_handler (endpoint, handler)) -> begin
          match
            Protocol.Codec.decode
              (Protocol.Frontend_endpoint.request endpoint)
              encoded
          with
          | Error message ->
              send_frontend_response
                (Protocol.Envelope.make ~id ~kind:"frontend.response"
                   (`Assoc
                      [
                        ("status", `String "error");
                        ( "error",
                          Protocol.Codec.encode Protocol.Rpc_error.codec
                            (rpc_error ~code:"decode_error" message) );
                      ]))
          | Ok request ->
              let handled =
                try handler request
                with exn ->
                  Promise.resolve
                    (Error
                       (rpc_error ~code:"frontend_exception"
                          (Printexc.to_string exn)))
              in
              let handled =
                Promise.catch
                  (fun error ->
                    Promise.resolve
                      (Error
                         (rpc_error ~code:"frontend_rejection"
                            (promise_error_message error))))
                  handled
              in
              ignore
                (Promise.map
                   (fun result ->
                     let payload =
                       match result with
                       | Ok response ->
                           `Assoc
                             [
                               ("status", `String "ok");
                               ( "response",
                                 Protocol.Codec.encode
                                   (Protocol.Frontend_endpoint.response endpoint)
                                   response );
                             ]
                       | Error error ->
                           `Assoc
                             [
                               ("status", `String "error");
                               ( "error",
                                 Protocol.Codec.encode Protocol.Rpc_error.codec
                                   error );
                             ]
                     in
                     send_frontend_response
                       (Protocol.Envelope.make ~id ~kind:"frontend.response"
                          payload))
                   handled)
        end
    end
  | _ -> ()

let handle_event t envelope =
  match
    ( Protocol.Json.string_member "name" envelope.Protocol.Envelope.payload,
      Protocol.Json.member "event" envelope.payload )
  with
  | Ok name, Ok encoded -> (
      match Hashtbl.find_opt t.event_handlers name with
      | None -> ()
      | Some handlers ->
          List.iter
            (fun (_, Event_handler (event, handler)) ->
              match
                Protocol.Codec.decode (Protocol.Event.event event) encoded
              with
              | Ok event -> ( try handler event with _ -> ())
              | Error _ -> ())
            handlers)
  | _ -> ()

let stream_batch t envelope =
  match
    ( Protocol.Json.string_member "stream_id" envelope.Protocol.Envelope.payload,
      Protocol.Json.member "events" envelope.payload )
  with
  | Ok stream_id, Ok (`List events) -> (
      match Hashtbl.find_opt t.streams stream_id with
      | None -> ()
      | Some (Stream_state stream) ->
          let codec = Protocol.Sequenced.codec stream.event_codec in
          List.iter
            (fun encoded ->
              match Protocol.Codec.decode codec encoded with
              | Error _ -> ()
              | Ok sequenced
                when Int64.compare sequenced.sequence stream.last_sequence <= 0
                ->
                  ()
              | Ok sequenced ->
                  stream.last_sequence <- sequenced.sequence;
                  if stream.handlers = [] then (
                    stream.pending_events <-
                      sequenced.event :: stream.pending_events;
                    stream.pending_event_count <- stream.pending_event_count + 1)
                  else
                    List.iter
                      (fun (_, handler) ->
                        try handler sequenced.event with _ -> ())
                      stream.handlers)
            events;
          if stream.pending_event_count > t.max_pending_events then (
            Hashtbl.remove t.streams stream_id;
            stream.resolve_finished
              (Error
                 (rpc_error ~code:"slow_subscriber"
                    "the frontend pending event limit was reached"));
            ignore
              (call_native
                 (Protocol.Envelope.make ~kind:"stream.detach"
                    (`Assoc [ ("stream_id", `String stream.id) ]))))
          else if Int64.compare stream.last_sequence 0L > 0 then
            ignore
              (call_native
                 (Protocol.Envelope.make ~kind:"stream.ack"
                    (`Assoc
                       [
                         ("stream_id", `String stream.id);
                         ("subscriber_id", `String t.client_identifier);
                         ( "sequence",
                           Protocol.Codec.encode Protocol.Codec.int64_string
                             stream.last_sequence );
                       ]))))
  | _ -> ()

let stream_finished t envelope =
  match
    Protocol.Json.string_member "stream_id" envelope.Protocol.Envelope.payload
  with
  | Error _ -> ()
  | Ok stream_id -> (
      match Hashtbl.find_opt t.streams stream_id with
      | None -> ()
      | Some (Stream_state stream) ->
          Hashtbl.remove t.streams stream_id;
          let result =
            if envelope.kind = "stream.finished" then
              match Protocol.Json.member "result" envelope.payload with
              | Ok encoded -> (
                  match Protocol.Codec.decode stream.result_codec encoded with
                  | Ok result -> Ok result
                  | Error message ->
                      Error (rpc_error ~code:"decode_error" message))
              | Error message ->
                  Error (rpc_error ~code:"invalid_response" message)
            else
              match Protocol.Json.member "error" envelope.payload with
              | Ok encoded -> (
                  match
                    Protocol.Codec.decode Protocol.Rpc_error.codec encoded
                  with
                  | Ok error -> Error error
                  | Error message ->
                      Error (rpc_error ~code:"invalid_response" message))
              | Error message ->
                  Error (rpc_error ~code:"invalid_response" message)
          in
          stream.resolve_finished result)

let receive t encoded =
  match Protocol.Envelope.of_string (Js.to_string encoded) with
  | Error _ -> ()
  | Ok envelope -> (
      match envelope.Protocol.Envelope.kind with
      | "frontend.call" -> handle_frontend_call t envelope
      | "event" -> handle_event t envelope
      | "stream.batch" -> stream_batch t envelope
      | "stream.finished" | "stream.failed" -> stream_finished t envelope
      | _ -> ())

let install t =
  if not t.installed then (
    t.installed <- true;
    Js.Unsafe.set Js.Unsafe.global "__owebviewReceive"
      (Js.Unsafe.callback (receive t)))

let ready ?(protocol_version = Protocol.Envelope.current_version)
    ?(frontend_build_id = "development") ?application_version
    ?(capabilities = [ "rpc"; "streams" ]) t =
  install t;
  let application_version =
    match application_version with
    | None -> `Null
    | Some version -> `String version
  in
  expect_unit_response
    (call_native
       (Protocol.Envelope.make ~kind:"ready"
          (`Assoc
             [
               ("protocol_version", `Int protocol_version);
               ("frontend_build_id", `String frontend_build_id);
               ("application_version", application_version);
               ( "capabilities",
                 `List (List.map (fun value -> `String value) capabilities) );
             ])))
    ~kind:"ready.ok"

module Rpc = struct
  type 'response call = {
    id : string;
    result : ('response, Protocol.Rpc_error.t) result Promise.t;
  }

  let call_with_id t endpoint request =
    let id = next_id t "rpc" in
    let response =
      call_native
        (Protocol.Envelope.make ~id ~kind:"rpc.call"
           (`Assoc
              [
                ("method", `String (Protocol.Endpoint.name endpoint));
                ( "request",
                  Protocol.Codec.encode
                    (Protocol.Endpoint.request endpoint)
                    request );
              ]))
    in
    let result =
      Promise.map
        (function
          | Error error -> Error error
          | Ok envelope when envelope.Protocol.Envelope.kind = "rpc.ok" -> (
              match
                Protocol.Codec.decode
                  (Protocol.Endpoint.response endpoint)
                  envelope.payload
              with
              | Ok response -> Ok response
              | Error message -> Error (rpc_error ~code:"decode_error" message))
          | Ok envelope when envelope.kind = "error" ->
              Error (decode_error envelope)
          | Ok envelope ->
              Error
                (rpc_error ~code:"invalid_response"
                   ("unexpected response: " ^ envelope.kind)))
        response
    in
    { id; result }

  let call t endpoint request = (call_with_id t endpoint request).result

  let cancel _t request_id =
    expect_unit_response
      (call_native
         (Protocol.Envelope.make ~kind:"rpc.cancel"
            (`Assoc [ ("request_id", `String request_id) ])))
      ~kind:"rpc.cancelled"
end

module Frontend = struct
  let handle t endpoint handler =
    let name = Protocol.Frontend_endpoint.name endpoint in
    if Hashtbl.mem t.frontend_handlers name then
      invalid_arg ("duplicate frontend handler: " ^ name);
    Hashtbl.add t.frontend_handlers name (Frontend_handler (endpoint, handler));
    let subscription =
      {
        active = true;
        cancel = (fun () -> Hashtbl.remove t.frontend_handlers name);
      }
    in
    subscription
end

module Event = struct
  let subscribe t event handler =
    let name = Protocol.Event.name event in
    t.next_subscription <- t.next_subscription + 1;
    let id = t.next_subscription in
    let handlers =
      Option.value (Hashtbl.find_opt t.event_handlers name) ~default:[]
    in
    Hashtbl.replace t.event_handlers name
      ((id, Event_handler (event, handler)) :: handlers);
    {
      active = true;
      cancel =
        (fun () ->
          match Hashtbl.find_opt t.event_handlers name with
          | None -> ()
          | Some handlers ->
              Hashtbl.replace t.event_handlers name
                (List.filter (fun (candidate, _) -> candidate <> id) handlers));
    }
end

module Durable_session = struct
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

  let lifecycle = function
    | "running" -> Ok Running
    | "recovering" -> Ok Recovering
    | "interrupted" -> Ok Interrupted
    | "completed" -> Ok Completed
    | "failed" -> Ok Failed
    | "cancelled" -> Ok Cancelled
    | value -> Error ("unknown durable session lifecycle: " ^ value)

  let decode = function
    | `Assoc fields -> (
        match
          ( List.assoc_opt "id" fields,
            List.assoc_opt "endpoint" fields,
            List.assoc_opt "lifecycle" fields,
            List.assoc_opt "latest_sequence" fields,
            List.assoc_opt "created_at" fields,
            List.assoc_opt "updated_at" fields )
        with
        | ( Some (`String id),
            Some (`String endpoint),
            Some (`String state),
            Some sequence,
            Some created_at,
            Some updated_at ) -> (
            let number = function
              | `Float value -> Ok value
              | `Int value -> Ok (Float.of_int value)
              | _ -> Error "expected a timestamp"
            in
            match
              ( lifecycle state,
                Protocol.Codec.decode Protocol.Codec.int64_string sequence,
                number created_at,
                number updated_at )
            with
            | Ok lifecycle, Ok latest_sequence, Ok created_at, Ok updated_at ->
                Ok
                  {
                    id;
                    endpoint;
                    lifecycle;
                    latest_sequence;
                    created_at;
                    updated_at;
                  }
            | Error message, _, _, _
            | _, Error message, _, _
            | _, _, Error message, _
            | _, _, _, Error message ->
                Error message)
        | _ -> Error "invalid durable session summary")
    | _ -> Error "invalid durable session summary"

  let rec decode_all result = function
    | [] -> Ok (List.rev result)
    | encoded :: rest -> (
        match decode encoded with
        | Ok summary -> decode_all (summary :: result) rest
        | Error _ as error -> error)

  let list t =
    Promise.map
      (function
        | Error error -> Error error
        | Ok envelope when envelope.Protocol.Envelope.kind = "session.list" -> (
            match envelope.payload with
            | `List sessions -> (
                match decode_all [] sessions with
                | Ok sessions -> Ok sessions
                | Error message ->
                    Error (rpc_error ~code:"decode_error" message))
            | _ ->
                Error
                  (rpc_error ~code:"invalid_response"
                     "session.list response is not an array"))
        | Ok envelope when envelope.kind = "error" ->
            Error (decode_error envelope)
        | Ok envelope ->
            Error
              (rpc_error ~code:"invalid_response"
                 ("unexpected response: " ^ envelope.kind)))
      (call_native
         (Protocol.Envelope.make ~kind:"session.list"
            (`Assoc [ ("subscriber_id", `String t.client_identifier) ])))
end

module Stream = struct
  type ('event, 'command, 'result) stream =
    ('event, 'command, 'result) stream_state

  let id stream = stream.id
  let last_sequence stream = stream.last_sequence

  let open_ t endpoint request =
    let request_id = next_id t "stream-open" in
    Promise.map
      (function
        | Error error -> Error error
        | Ok envelope when envelope.Protocol.Envelope.kind = "stream.opened"
          -> (
            match Protocol.Json.string_member "stream_id" envelope.payload with
            | Error message ->
                Error (rpc_error ~code:"invalid_response" message)
            | Ok stream_id ->
                let resolve_finished_ref = ref (fun _ -> ()) in
                let finished_promise =
                  Promise.make (fun ~resolve ~reject:_ ->
                      resolve_finished_ref := resolve)
                in
                let stream =
                  {
                    owner = t;
                    id = stream_id;
                    event_codec = Protocol.Stream_endpoint.event endpoint;
                    command_codec = Protocol.Stream_endpoint.command endpoint;
                    result_codec = Protocol.Stream_endpoint.result endpoint;
                    handlers = [];
                    pending_events = [];
                    pending_event_count = 0;
                    next_handler = 0;
                    last_sequence = 0L;
                    finished_promise;
                    resolve_finished = !resolve_finished_ref;
                  }
                in
                Hashtbl.replace t.streams stream_id (Stream_state stream);
                Ok stream)
        | Ok envelope when envelope.kind = "error" ->
            Error (decode_error envelope)
        | Ok envelope ->
            Error
              (rpc_error ~code:"invalid_response"
                 ("unexpected response: " ^ envelope.kind)))
      (call_native
         (Protocol.Envelope.make ~id:request_id ~kind:"stream.open"
            (`Assoc
               [
                 ("method", `String (Protocol.Stream_endpoint.name endpoint));
                 ("subscriber_id", `String t.client_identifier);
                 ( "request",
                   Protocol.Codec.encode
                     (Protocol.Stream_endpoint.request endpoint)
                     request );
               ])))

  let resume_request stream ~after_sequence =
    expect_unit_response
      (call_native
         (Protocol.Envelope.make ~kind:"stream.resume"
            (`Assoc
               [
                 ("stream_id", `String stream.id);
                 ("subscriber_id", `String stream.owner.client_identifier);
                 ( "after_sequence",
                   Protocol.Codec.encode Protocol.Codec.int64_string
                     after_sequence );
               ])))
      ~kind:"stream.resumed"

  let attach t endpoint ~stream_id ~after_sequence =
    let resolve_finished_ref = ref (fun _ -> ()) in
    let finished_promise =
      Promise.make (fun ~resolve ~reject:_ -> resolve_finished_ref := resolve)
    in
    let stream =
      {
        owner = t;
        id = stream_id;
        event_codec = Protocol.Stream_endpoint.event endpoint;
        command_codec = Protocol.Stream_endpoint.command endpoint;
        result_codec = Protocol.Stream_endpoint.result endpoint;
        handlers = [];
        pending_events = [];
        pending_event_count = 0;
        next_handler = 0;
        last_sequence = after_sequence;
        finished_promise;
        resolve_finished = !resolve_finished_ref;
      }
    in
    Hashtbl.replace t.streams stream_id (Stream_state stream);
    Promise.map
      (function
        | Ok () -> Ok stream
        | Error error ->
            Hashtbl.remove t.streams stream_id;
            Error error)
      (resume_request stream ~after_sequence)

  let on_event stream handler =
    stream.next_handler <- stream.next_handler + 1;
    let id = stream.next_handler in
    stream.handlers <- (id, handler) :: stream.handlers;
    let pending = List.rev stream.pending_events in
    stream.pending_events <- [];
    stream.pending_event_count <- 0;
    List.iter (fun event -> try handler event with _ -> ()) pending;
    {
      active = true;
      cancel =
        (fun () ->
          stream.handlers <-
            List.filter (fun (candidate, _) -> candidate <> id) stream.handlers);
    }

  let send_with_id stream ~command_id command =
    expect_unit_response
      (call_native
         (Protocol.Envelope.make ~id:command_id ~kind:"stream.command"
            (`Assoc
               [
                 ("stream_id", `String stream.id);
                 ("command", Protocol.Codec.encode stream.command_codec command);
               ])))
      ~kind:"stream.command_ack"

  let send stream command =
    send_with_id stream ~command_id:(next_id stream.owner "command") command

  let finished stream = stream.finished_promise

  let cancel stream =
    expect_unit_response
      (call_native
         (Protocol.Envelope.make ~kind:"stream.cancel"
            (`Assoc [ ("stream_id", `String stream.id) ])))
      ~kind:"stream.cancelled"

  let detach stream =
    Promise.map
      (fun result ->
        match result with
        | Ok () ->
            Hashtbl.remove stream.owner.streams stream.id;
            Ok ()
        | Error _ as error -> error)
      (expect_unit_response
         (call_native
            (Protocol.Envelope.make ~kind:"stream.detach"
               (`Assoc [ ("stream_id", `String stream.id) ])))
         ~kind:"stream.detached")

  let resume = resume_request
end
