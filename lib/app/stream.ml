module Protocol = Owebview_protocol

exception Stream_cancelled

type event_item = { encoded : Protocol.Json.t; bytes : int; immediate : bool }
type replay_entry = { sequence : int64; encoded : Protocol.Json.t; bytes : int }

type outbound =
  | Event of event_item
  | Finished of Protocol.Json.t
  | Failed of Protocol.Rpc_error.t

type ('event, 'command, 'result) session = {
  id : string;
  transport : Transport.t;
  event_codec : 'event Protocol.Codec.t;
  command_codec : 'command Protocol.Codec.t;
  result_codec : 'result Protocol.Codec.t;
  outgoing : outbound Eio.Stream.t;
  event_capacity : int;
  event_byte_capacity : int;
  mutable outgoing_bytes : int;
  commands : 'command Eio.Stream.t;
  command_capacity : int;
  replay : replay_entry Queue.t;
  replay_capacity : int;
  replay_byte_capacity : int;
  mutable replay_bytes : int;
  flush_interval : float;
  max_batch_bytes : int;
  flush_immediately : 'event -> bool;
  coalesce_encoded :
    (Protocol.Json.t -> Protocol.Json.t -> Protocol.Json.t option) option;
  mutable sequence : int64;
  mutable active : bool;
  mutable terminal_queued : bool;
  mutable terminal : outbound option;
  mutable attached : bool;
  mutable cancelled : bool;
  mutable cancel_handler : unit -> unit;
}

type packed_session =
  | Session : ('event, 'command, 'result) session -> packed_session

type packed_handler =
  | Handler :
      ('request, 'event, 'command, 'result) Protocol.Stream_endpoint.t
      * (('event, 'command, 'result) session -> 'request -> unit)
      * int
      * int
      * int
      * int
      * int
      * float
      * int
      * ('event -> bool)
      * ('event -> 'event -> 'event option) option
      -> packed_handler

let rpc_error ?data ~code message = Protocol.Rpc_error.make ?data ~code message

module Session = struct
  type ('event, 'command, 'result) t = ('event, 'command, 'result) session

  let id session = session.id
  let commands session = session.commands
  let is_cancelled session = session.cancelled

  let enqueue_terminal session terminal =
    if session.terminal_queued then
      Error
        (rpc_error ~code:"stream_finished"
           "the stream already has a terminal result")
    else (
      session.terminal_queued <- true;
      session.active <- false;
      Eio.Stream.add session.outgoing terminal;
      Ok ())

  let emit session event =
    if not session.active then
      Error (rpc_error ~code:"stream_finished" "the stream is closed")
    else
      let sequence = Int64.succ session.sequence in
      let sequenced : _ Protocol.Sequenced.t =
        { sequence; timestamp = Transport.now session.transport; event }
      in
      let encoded =
        Protocol.Codec.encode
          (Protocol.Sequenced.codec session.event_codec)
          sequenced
      in
      let bytes = String.length (Protocol.Json.to_string encoded) in
      if bytes > session.max_batch_bytes then
        Error
          (rpc_error ~code:"event_too_large"
             "the encoded event exceeds the maximum batch size")
      else if Eio.Stream.length session.outgoing >= session.event_capacity then
        Error
          (rpc_error ~code:"slow_subscriber" "the frontend event queue is full")
      else if session.outgoing_bytes + bytes > session.event_byte_capacity then
        Error
          (rpc_error ~code:"slow_subscriber"
             "the frontend event queue byte limit was reached")
      else
        let immediate =
          try session.flush_immediately event
          with exn ->
            let backtrace = Printexc.get_raw_backtrace () in
            Transport.report_exception session.transport
              ~context:"stream immediate-flush policy" exn backtrace;
            false
        in
        session.sequence <- sequence;
        Queue.add { sequence; encoded; bytes } session.replay;
        session.replay_bytes <- session.replay_bytes + bytes;
        while
          Queue.length session.replay > session.replay_capacity
          || session.replay_bytes > session.replay_byte_capacity
        do
          let removed = Queue.take session.replay in
          session.replay_bytes <- session.replay_bytes - removed.bytes
        done;
        session.outgoing_bytes <- session.outgoing_bytes + bytes;
        Eio.Stream.add session.outgoing (Event { encoded; bytes; immediate });
        Ok ()

  let finish session result =
    enqueue_terminal session
      (Finished (Protocol.Codec.encode session.result_codec result))

  let fail session error = enqueue_terminal session (Failed error)
end

module Server = struct
  type t = {
    transport : Transport.t;
    handlers : (string, packed_handler) Hashtbl.t;
    sessions : (string, packed_session) Hashtbl.t;
    max_sessions : int;
    terminal_retention : float;
  }

  let send_batch server session events =
    if session.attached && events <> [] then
      ignore
        (Transport.emit server.transport
           (Protocol.Envelope.make ~kind:"stream.batch"
              (`Assoc
                 [ ("stream_id", `String session.id); ("events", `List events) ])))

  let send_terminal server session = function
    | Finished result when session.attached ->
        ignore
          (Transport.emit server.transport
             (Protocol.Envelope.make ~kind:"stream.finished"
                (`Assoc
                   [ ("stream_id", `String session.id); ("result", result) ])))
    | Failed error when session.attached ->
        ignore
          (Transport.emit server.transport
             (Protocol.Envelope.make ~kind:"stream.failed"
                (`Assoc
                   [
                     ("stream_id", `String session.id);
                     ( "error",
                       Protocol.Codec.encode Protocol.Rpc_error.codec error );
                   ])))
    | Finished _ | Failed _ -> ()
    | Event _ -> assert false

  let take_outgoing session =
    let item = Eio.Stream.take session.outgoing in
    (match item with
    | Event event ->
        session.outgoing_bytes <- session.outgoing_bytes - event.bytes
    | Finished _ | Failed _ -> ());
    item

  let take_outgoing_nonblocking session =
    match Eio.Stream.take_nonblocking session.outgoing with
    | None -> None
    | Some item ->
        (match item with
        | Event event ->
            session.outgoing_bytes <- session.outgoing_bytes - event.bytes
        | Finished _ | Failed _ -> ());
        Some item

  let retain_terminal server session terminal =
    session.terminal <- Some terminal;
    send_terminal server session terminal;
    if server.terminal_retention = 0. then
      Hashtbl.remove server.sessions session.id
    else
      Eio.Fiber.fork ~sw:(Transport.sw server.transport) (fun () ->
          Transport.sleep server.transport server.terminal_retention;
          Hashtbl.remove server.sessions session.id)

  let batcher server session =
    let encoded_size event = String.length (Protocol.Json.to_string event) in
    let add_event events size event =
      match (events, session.coalesce_encoded) with
      | previous :: rest, Some coalesce -> (
          match coalesce previous event with
          | Some merged ->
              let merged_size =
                size - encoded_size previous + encoded_size merged
              in
              if merged_size <= session.max_batch_bytes then
                `Added (merged :: rest, merged_size)
              else `Deferred
          | None ->
              let next_size = size + encoded_size event in
              if next_size <= session.max_batch_bytes then
                `Added (event :: events, next_size)
              else `Deferred)
      | _ ->
          let next_size = size + encoded_size event in
          if next_size <= session.max_batch_bytes then
            `Added (event :: events, next_size)
          else `Deferred
    in
    let rec loop carry =
      let next =
        match carry with Some item -> item | None -> take_outgoing session
      in
      match next with
      | (Finished _ | Failed _) as terminal ->
          retain_terminal server session terminal
      | Event first ->
          if not first.immediate then
            Transport.sleep server.transport session.flush_interval;
          let rec drain events size =
            match take_outgoing_nonblocking session with
            | None -> (List.rev events, None)
            | Some (Event event) when event.immediate ->
                (List.rev events, Some (Event event))
            | Some (Event event) -> (
                match add_event events size event.encoded with
                | `Added (events, size) -> drain events size
                | `Deferred -> (List.rev events, Some (Event event)))
            | Some ((Finished _ | Failed _) as terminal) ->
                (List.rev events, Some terminal)
          in
          let events, carry =
            if first.immediate then ([ first.encoded ], None)
            else drain [ first.encoded ] (encoded_size first.encoded)
          in
          send_batch server session events;
          loop carry
    in
    loop None

  let find_session server envelope =
    match
      Protocol.Json.string_member "stream_id" envelope.Protocol.Envelope.payload
    with
    | Error message -> Error (rpc_error ~code:"invalid_request" message)
    | Ok stream_id -> (
        match Hashtbl.find_opt server.sessions stream_id with
        | Some session -> Ok session
        | None ->
            Error (rpc_error ~code:"stream_not_found" "stream is not active"))

  let create ?(max_sessions = 256) ?(terminal_retention = 30.) transport =
    if max_sessions <= 0 then
      invalid_arg "Stream.Server.create: max_sessions must be positive";
    if terminal_retention < 0. then
      invalid_arg
        "Stream.Server.create: terminal_retention must not be negative";
    let server =
      {
        transport;
        handlers = Hashtbl.create 16;
        sessions = Hashtbl.create 32;
        max_sessions;
        terminal_retention;
      }
    in
    ignore
      (Transport.register transport ~kind:"stream.open" (fun envelope ->
           match
             ( Protocol.Json.string_member "method" envelope.payload,
               Protocol.Json.member "request" envelope.payload )
           with
           | Error message, _ | _, Error message ->
               Error (rpc_error ~code:"invalid_request" message)
           | Ok method_name, Ok encoded -> (
               match Hashtbl.find_opt server.handlers method_name with
               | None ->
                   Error
                     (rpc_error ~code:"method_not_found"
                        "stream endpoint is not registered")
               | Some
                   (Handler
                      ( endpoint,
                        handler,
                        event_capacity,
                        command_capacity,
                        replay_capacity,
                        event_byte_capacity,
                        replay_byte_capacity,
                        flush_interval,
                        max_batch_bytes,
                        flush_immediately,
                        coalesce )) -> (
                   match
                     Protocol.Codec.decode
                       (Protocol.Stream_endpoint.request endpoint)
                       encoded
                   with
                   | Error message ->
                       Error (rpc_error ~code:"decode_error" message)
                   | Ok _
                     when Hashtbl.length server.sessions >= server.max_sessions
                     ->
                       Error
                         (rpc_error ~code:"stream_limit_reached"
                            "the application stream session limit was reached")
                   | Ok request ->
                       let stream_id = Transport.next_id transport "stream" in
                       let session =
                         {
                           id = stream_id;
                           transport;
                           event_codec = Protocol.Stream_endpoint.event endpoint;
                           command_codec =
                             Protocol.Stream_endpoint.command endpoint;
                           result_codec =
                             Protocol.Stream_endpoint.result endpoint;
                           outgoing = Eio.Stream.create (event_capacity + 1);
                           event_capacity;
                           event_byte_capacity;
                           outgoing_bytes = 0;
                           commands = Eio.Stream.create command_capacity;
                           command_capacity;
                           replay = Queue.create ();
                           replay_capacity;
                           replay_byte_capacity;
                           replay_bytes = 0;
                           flush_interval;
                           max_batch_bytes;
                           flush_immediately;
                           coalesce_encoded =
                             Option.map
                               (fun coalesce left right ->
                                 let codec =
                                   Protocol.Sequenced.codec
                                     (Protocol.Stream_endpoint.event endpoint)
                                 in
                                 match
                                   ( Protocol.Codec.decode codec left,
                                     Protocol.Codec.decode codec right )
                                 with
                                 | Ok previous, Ok latest -> (
                                     match
                                       try coalesce previous.event latest.event
                                       with exn ->
                                         let backtrace =
                                           Printexc.get_raw_backtrace ()
                                         in
                                         Transport.report_exception transport
                                           ~context:
                                             ("stream coalescer " ^ method_name)
                                           exn backtrace;
                                         None
                                     with
                                     | None -> None
                                     | Some event ->
                                         Some
                                           (Protocol.Codec.encode codec
                                              {
                                                Protocol.Sequenced.sequence =
                                                  latest.sequence;
                                                timestamp = latest.timestamp;
                                                event;
                                              }))
                                 | _ -> None)
                               coalesce;
                           sequence = 0L;
                           active = true;
                           terminal_queued = false;
                           terminal = None;
                           attached = true;
                           cancelled = false;
                           cancel_handler = (fun () -> ());
                         }
                       in
                       Hashtbl.add server.sessions stream_id (Session session);
                       Eio.Fiber.fork ~sw:(Transport.sw transport) (fun () ->
                           batcher server session);
                       Eio.Fiber.fork ~sw:(Transport.sw transport) (fun () ->
                           try
                             Eio.Switch.run ~name:("stream." ^ method_name)
                             @@ fun session_sw ->
                             session.cancel_handler <-
                               (fun () ->
                                 Eio.Switch.fail session_sw Stream_cancelled);
                             if session.cancelled then raise Stream_cancelled;
                             handler session request;
                             if session.active then
                               ignore
                                 (Session.fail session
                                    (rpc_error ~code:"stream_incomplete"
                                       "stream handler returned without \
                                        finishing"))
                           with
                           | Stream_cancelled ->
                               ignore
                                 (Session.fail session
                                    (rpc_error ~code:"cancelled"
                                       "stream was cancelled"))
                           | exn ->
                               let backtrace = Printexc.get_raw_backtrace () in
                               Transport.report_exception transport
                                 ~context:("stream handler " ^ method_name)
                                 exn backtrace;
                               ignore
                                 (Session.fail session
                                    (rpc_error ~code:"handler_exception"
                                       "the stream handler raised an exception")));
                       Ok
                         (Protocol.Envelope.make ?id:envelope.id
                            ~kind:"stream.opened"
                            (`Assoc [ ("stream_id", `String stream_id) ]))))));
    let handle_command envelope =
      let outcome =
        match find_session server envelope with
        | Error _ as error -> error
        | Ok (Session session) -> (
            match Protocol.Json.member "command" envelope.payload with
            | Error message -> Error (rpc_error ~code:"invalid_request" message)
            | Ok encoded -> (
                match Protocol.Codec.decode session.command_codec encoded with
                | Error message ->
                    Error (rpc_error ~code:"decode_error" message)
                | Ok command ->
                    if not session.active then
                      Error
                        (rpc_error ~code:"stream_finished" "stream is closed")
                    else if
                      Eio.Stream.length session.commands
                      >= session.command_capacity
                    then
                      Error
                        (rpc_error ~code:"command_queue_full"
                           "stream command queue is full")
                    else (
                      Eio.Stream.add session.commands command;
                      Ok
                        (Protocol.Envelope.make ?id:envelope.id
                           ~kind:"stream.command_ack" `Null))))
      in
      match outcome with
      | Ok _ as response -> response
      | Error error ->
          Ok
            (Protocol.Envelope.make ?id:envelope.id ~kind:"stream.command_error"
               (Protocol.Codec.encode Protocol.Rpc_error.codec error))
    in
    ignore (Transport.register transport ~kind:"stream.command" handle_command);
    ignore
      (Transport.register transport ~kind:"stream.cancel" (fun envelope ->
           match find_session server envelope with
           | Error _ as error -> error
           | Ok (Session session) ->
               if not session.cancelled then (
                 session.cancelled <- true;
                 session.cancel_handler ());
               Ok
                 (Protocol.Envelope.make ?id:envelope.id
                    ~kind:"stream.cancelled" `Null)));
    ignore
      (Transport.register transport ~kind:"stream.detach" (fun envelope ->
           match find_session server envelope with
           | Error _ as error -> error
           | Ok (Session session) ->
               session.attached <- false;
               Ok
                 (Protocol.Envelope.make ?id:envelope.id ~kind:"stream.detached"
                    `Null)));
    ignore
      (Transport.register transport ~kind:"stream.ack" (fun envelope ->
           match find_session server envelope with
           | Error _ as error -> error
           | Ok (Session session) -> (
               match Protocol.Json.member "sequence" envelope.payload with
               | Error message ->
                   Error (rpc_error ~code:"invalid_request" message)
               | Ok encoded -> (
                   match
                     Protocol.Codec.decode Protocol.Codec.int64_string encoded
                   with
                   | Error message ->
                       Error (rpc_error ~code:"decode_error" message)
                   | Ok acknowledged ->
                       if
                         Int64.compare acknowledged 0L < 0
                         || Int64.compare acknowledged session.sequence > 0
                       then
                         Error
                           (rpc_error ~code:"invalid_sequence"
                              "the acknowledgement sequence is outside the \
                               stream range")
                       else (
                         while
                           (not (Queue.is_empty session.replay))
                           && Int64.compare (Queue.peek session.replay).sequence
                                acknowledged
                              <= 0
                         do
                           let removed = Queue.take session.replay in
                           session.replay_bytes <-
                             session.replay_bytes - removed.bytes
                         done;
                         Ok
                           (Protocol.Envelope.make ?id:envelope.id
                              ~kind:"stream.acked" `Null))))));
    let handle_resume envelope =
      match find_session server envelope with
      | Error _ as error -> error
      | Ok (Session session) -> (
          match Protocol.Json.member "after_sequence" envelope.payload with
          | Error message -> Error (rpc_error ~code:"invalid_request" message)
          | Ok encoded -> (
              match
                Protocol.Codec.decode Protocol.Codec.int64_string encoded
              with
              | Error message -> Error (rpc_error ~code:"decode_error" message)
              | Ok after_sequence ->
                  if
                    Int64.compare after_sequence 0L < 0
                    || Int64.compare after_sequence session.sequence > 0
                  then
                    Error
                      (rpc_error ~code:"invalid_sequence"
                         "the resume sequence is outside the stream range")
                  else
                    let replay =
                      Queue.fold
                        (fun events (entry : replay_entry) ->
                          if Int64.compare entry.sequence after_sequence > 0
                          then entry.encoded :: events
                          else events)
                        [] session.replay
                      |> List.rev
                    in
                    let unavailable =
                      match Queue.peek_opt session.replay with
                      | Some oldest ->
                          Int64.compare after_sequence
                            (Int64.pred oldest.sequence)
                          < 0
                      | None ->
                          Int64.compare after_sequence session.sequence < 0
                    in
                    if unavailable then
                      Error
                        (rpc_error ~code:"replay_unavailable"
                           "the requested sequence is no longer retained")
                    else (
                      session.attached <- true;
                      send_batch server session replay;
                      Option.iter
                        (send_terminal server session)
                        session.terminal;
                      Ok
                        (Protocol.Envelope.make ?id:envelope.id
                           ~kind:"stream.resumed"
                           (`Assoc
                              [
                                ( "latest_sequence",
                                  Protocol.Codec.encode
                                    Protocol.Codec.int64_string session.sequence
                                );
                              ])))))
    in
    ignore (Transport.register transport ~kind:"stream.resume" handle_resume);
    server

  let handle ?(event_capacity = 2048) ?(event_byte_capacity = 4 * 1024 * 1024)
      ?(command_capacity = 128) ?(replay_capacity = 4096)
      ?(replay_byte_capacity = 8 * 1024 * 1024) ?(flush_interval = 0.02)
      ?(max_batch_bytes = 65536) ?(flush_immediately = fun _ -> false) ?coalesce
      server endpoint handler =
    if event_capacity <= 0 || command_capacity <= 0 || replay_capacity <= 0 then
      invalid_arg "Stream.Server.handle: capacities must be positive";
    if event_byte_capacity <= 0 || replay_byte_capacity <= 0 then
      invalid_arg "Stream.Server.handle: byte capacities must be positive";
    if flush_interval < 0. then
      invalid_arg "Stream.Server.handle: flush_interval must not be negative";
    if max_batch_bytes <= 0 then
      invalid_arg "Stream.Server.handle: max_batch_bytes must be positive";
    let name = Protocol.Stream_endpoint.name endpoint in
    if Hashtbl.mem server.handlers name then
      invalid_arg ("duplicate stream endpoint: " ^ name);
    Hashtbl.add server.handlers name
      (Handler
         ( endpoint,
           handler,
           event_capacity,
           command_capacity,
           replay_capacity,
           event_byte_capacity,
           replay_byte_capacity,
           flush_interval,
           max_batch_bytes,
           flush_immediately,
           coalesce ));
    Transport.subscription server.transport (fun () ->
        Hashtbl.remove server.handlers name)
end
