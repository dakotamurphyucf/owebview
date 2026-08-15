module Protocol = Owebview_protocol

exception Session_cancelled

type lifecycle =
  | Running
  | Recovering
  | Interrupted
  | Completed
  | Failed
  | Cancelled

let string_of_lifecycle = function
  | Running -> "running"
  | Recovering -> "recovering"
  | Interrupted -> "interrupted"
  | Completed -> "completed"
  | Failed -> "failed"
  | Cancelled -> "cancelled"

let lifecycle_of_string = function
  | "running" -> Ok Running
  | "recovering" -> Ok Recovering
  | "interrupted" -> Ok Interrupted
  | "completed" -> Ok Completed
  | "failed" -> Ok Failed
  | "cancelled" -> Ok Cancelled
  | value -> Error ("unknown session lifecycle: " ^ value)

type terminal =
  | Finished of Protocol.Json.t
  | Failed_with of Protocol.Rpc_error.t
  | Cancelled_with of Protocol.Rpc_error.t

type stored_event = {
  sequence : int64;
  timestamp : float;
  encoded : Protocol.Json.t;
}

type command_status = Admitted | Applied | Rejected of Protocol.Rpc_error.t

type stored_command = {
  id : string;
  encoded : Protocol.Json.t;
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
  request : Protocol.Json.t;
  lifecycle : lifecycle;
  events : stored_event list;
  terminal : terminal option;
  commands : stored_command list;
  acknowledgements : stored_acknowledgement list;
  checkpoint : Protocol.Json.t option;
  created_at : float;
  updated_at : float;
}

module Persistence = struct
  type t = {
    load_all : unit -> stored_session list;
    save : stored_session -> unit;
    delete : string -> unit;
  }

  let make ~load_all ~save ~delete = { load_all; save; delete }

  let memory () =
    let records = Hashtbl.create 32 in
    make
      ~load_all:(fun () ->
        Hashtbl.fold (fun _ record result -> record :: result) records [])
      ~save:(fun record -> Hashtbl.replace records record.id record)
      ~delete:(fun id -> Hashtbl.remove records id)

  let terminal_to_json = function
    | Finished result ->
        `Assoc [ ("kind", `String "finished"); ("result", result) ]
    | Failed_with error ->
        `Assoc
          [
            ("kind", `String "failed");
            ("error", Protocol.Codec.encode Protocol.Rpc_error.codec error);
          ]
    | Cancelled_with error ->
        `Assoc
          [
            ("kind", `String "cancelled");
            ("error", Protocol.Codec.encode Protocol.Rpc_error.codec error);
          ]

  let terminal_of_json = function
    | `Assoc fields -> (
        match List.assoc_opt "kind" fields with
        | Some (`String "finished") -> (
            match List.assoc_opt "result" fields with
            | Some result -> Ok (Finished result)
            | None -> Error "finished terminal has no result")
        | Some (`String (("failed" | "cancelled") as kind)) -> (
            match List.assoc_opt "error" fields with
            | Some encoded ->
                Result.map
                  (fun error ->
                    if kind = "failed" then Failed_with error
                    else Cancelled_with error)
                  (Protocol.Codec.decode Protocol.Rpc_error.codec encoded)
            | None -> Error (kind ^ " terminal has no error"))
        | _ -> Error "invalid terminal kind")
    | _ -> Error "invalid terminal record"

  let event_to_json (event : stored_event) =
    `Assoc
      [
        ( "sequence",
          Protocol.Codec.encode Protocol.Codec.int64_string event.sequence );
        ("timestamp", `Float event.timestamp);
        ("encoded", event.encoded);
      ]

  let event_of_json = function
    | `Assoc fields -> (
        match
          ( List.assoc_opt "sequence" fields,
            List.assoc_opt "timestamp" fields,
            List.assoc_opt "encoded" fields )
        with
        | Some sequence, Some timestamp, Some encoded -> (
            let timestamp =
              match timestamp with
              | `Float value -> Ok value
              | `Int value -> Ok (Float.of_int value)
              | _ -> Error "invalid event timestamp"
            in
            match
              ( Protocol.Codec.decode Protocol.Codec.int64_string sequence,
                timestamp )
            with
            | Ok sequence, Ok timestamp -> Ok { sequence; timestamp; encoded }
            | Error message, _ | _, Error message -> Error message)
        | _ -> Error "invalid stored event")
    | _ -> Error "invalid stored event"

  let command_status_to_json = function
    | Admitted -> `Assoc [ ("kind", `String "admitted") ]
    | Applied -> `Assoc [ ("kind", `String "applied") ]
    | Rejected error ->
        `Assoc
          [
            ("kind", `String "rejected");
            ("error", Protocol.Codec.encode Protocol.Rpc_error.codec error);
          ]

  let command_status_of_json = function
    | `Assoc fields -> (
        match List.assoc_opt "kind" fields with
        | Some (`String "admitted") -> Ok Admitted
        | Some (`String "applied") -> Ok Applied
        | Some (`String "rejected") -> (
            match List.assoc_opt "error" fields with
            | Some encoded ->
                Result.map
                  (fun error -> Rejected error)
                  (Protocol.Codec.decode Protocol.Rpc_error.codec encoded)
            | None -> Error "rejected command has no error")
        | _ -> Error "invalid command status")
    | _ -> Error "invalid command status"

  let command_to_json (command : stored_command) =
    `Assoc
      [
        ("id", `String command.id);
        ("encoded", command.encoded);
        ("status", command_status_to_json command.status);
        ("created_at", `Float command.created_at);
        ("updated_at", `Float command.updated_at);
      ]

  let acknowledgement_to_json (acknowledgement : stored_acknowledgement) =
    `Assoc
      [
        ("subscriber_id", `String acknowledgement.subscriber_id);
        ( "sequence",
          Protocol.Codec.encode Protocol.Codec.int64_string
            acknowledgement.sequence );
        ("updated_at", `Float acknowledgement.updated_at);
      ]

  let to_json record =
    `Assoc
      [
        ("schema_version", `Int record.schema_version);
        ("id", `String record.id);
        ("endpoint", `String record.endpoint);
        ("request", record.request);
        ("lifecycle", `String (string_of_lifecycle record.lifecycle));
        ("events", `List (List.map event_to_json record.events));
        ( "terminal",
          match record.terminal with
          | None -> `Null
          | Some terminal -> terminal_to_json terminal );
        ("commands", `List (List.map command_to_json record.commands));
        ( "acknowledgements",
          `List (List.map acknowledgement_to_json record.acknowledgements) );
        ("checkpoint", Option.value record.checkpoint ~default:`Null);
        ("created_at", `Float record.created_at);
        ("updated_at", `Float record.updated_at);
      ]

  let number = function
    | `Float value -> Ok value
    | `Int value -> Ok (Float.of_int value)
    | _ -> Error "expected timestamp"

  let command_of_json = function
    | `Assoc fields -> (
        match
          ( List.assoc_opt "id" fields,
            List.assoc_opt "encoded" fields,
            List.assoc_opt "status" fields,
            List.assoc_opt "created_at" fields,
            List.assoc_opt "updated_at" fields )
        with
        | ( Some (`String id),
            Some encoded,
            Some status,
            Some created_at,
            Some updated_at ) -> (
            match
              ( command_status_of_json status,
                number created_at,
                number updated_at )
            with
            | Ok status, Ok created_at, Ok updated_at ->
                Ok { id; encoded; status; created_at; updated_at }
            | Error message, _, _ | _, Error message, _ | _, _, Error message ->
                Error message)
        | _ -> Error "invalid stored command")
    | _ -> Error "invalid stored command"

  let acknowledgement_of_json = function
    | `Assoc fields -> (
        match
          ( List.assoc_opt "subscriber_id" fields,
            List.assoc_opt "sequence" fields,
            List.assoc_opt "updated_at" fields )
        with
        | Some (`String subscriber_id), Some sequence, Some updated_at -> (
            match
              ( Protocol.Codec.decode Protocol.Codec.int64_string sequence,
                number updated_at )
            with
            | Ok sequence, Ok updated_at ->
                Ok { subscriber_id; sequence; updated_at }
            | Error message, _ | _, Error message -> Error message)
        | _ -> Error "invalid stored acknowledgement")
    | _ -> Error "invalid stored acknowledgement"

  let decode_list decode values =
    List.fold_right
      (fun encoded result ->
        match (decode encoded, result) with
        | Ok value, Ok values -> Ok (value :: values)
        | Error message, _ | _, Error message -> Error message)
      values (Ok [])

  let legacy_commands ~created_at ~updated_at = function
    | Some (`List command_ids) ->
        decode_list
          (function
            | `String id ->
                Ok
                  {
                    id;
                    encoded = `Null;
                    status = Admitted;
                    created_at;
                    updated_at;
                  }
            | _ -> Error "invalid command identifier")
          command_ids
    | None -> Ok []
    | Some _ -> Error "invalid legacy command identifiers"

  let of_json = function
    | `Assoc fields -> (
        match
          ( List.assoc_opt "schema_version" fields,
            List.assoc_opt "id" fields,
            List.assoc_opt "endpoint" fields,
            List.assoc_opt "request" fields,
            List.assoc_opt "lifecycle" fields,
            List.assoc_opt "events" fields,
            List.assoc_opt "terminal" fields,
            List.assoc_opt "created_at" fields,
            List.assoc_opt "updated_at" fields )
        with
        | ( Some (`Int schema_version),
            Some (`String id),
            Some (`String endpoint),
            Some request,
            Some (`String lifecycle),
            Some (`List events),
            terminal,
            Some encoded_created_at,
            Some encoded_updated_at ) -> (
            match (number encoded_created_at, number encoded_updated_at) with
            | Error message, _ | _, Error message -> Error message
            | Ok created_at, Ok updated_at -> (
                let commands =
                  match List.assoc_opt "commands" fields with
                  | Some (`List commands) ->
                      decode_list command_of_json commands
                  | Some _ -> Error "invalid stored commands"
                  | None ->
                      legacy_commands ~created_at ~updated_at
                        (List.assoc_opt "command_ids" fields)
                in
                let acknowledgements =
                  match List.assoc_opt "acknowledgements" fields with
                  | Some (`List acknowledgements) ->
                      decode_list acknowledgement_of_json acknowledgements
                  | None -> Ok []
                  | Some _ -> Error "invalid stored acknowledgements"
                in
                let terminal =
                  match terminal with
                  | None | Some `Null -> Ok None
                  | Some encoded ->
                      Result.map Option.some (terminal_of_json encoded)
                in
                match
                  ( lifecycle_of_string lifecycle,
                    decode_list event_of_json events,
                    terminal,
                    commands,
                    acknowledgements )
                with
                | ( Ok lifecycle,
                    Ok events,
                    Ok terminal,
                    Ok commands,
                    Ok acknowledgements ) ->
                    Ok
                      {
                        schema_version;
                        id;
                        endpoint;
                        request;
                        lifecycle;
                        events;
                        terminal;
                        commands;
                        acknowledgements;
                        checkpoint =
                          (match List.assoc_opt "checkpoint" fields with
                          | None | Some `Null -> None
                          | Some checkpoint -> Some checkpoint);
                        created_at;
                        updated_at;
                      }
                | Error message, _, _, _, _
                | _, Error message, _, _, _
                | _, _, Error message, _, _
                | _, _, _, Error message, _
                | _, _, _, _, Error message ->
                    Error message))
        | _ -> Error "invalid stored session")
    | _ -> Error "invalid stored session"

  let directory path =
    if not (Sys.file_exists path) then Unix.mkdir path 0o700;
    if not (Sys.is_directory path) then
      invalid_arg
        "Durable_session.Persistence.directory: path is not a directory";
    let file id = Filename.concat path (id ^ ".json") in
    let load_file filename =
      let channel = open_in_bin filename in
      Fun.protect
        (fun () ->
          let encoded =
            really_input_string channel (in_channel_length channel)
          in
          match Protocol.Json.of_string encoded with
          | Error message -> failwith (filename ^ ": " ^ message)
          | Ok json -> (
              match of_json json with
              | Ok record -> record
              | Error message -> failwith (filename ^ ": " ^ message)))
        ~finally:(fun () -> close_in channel)
    in
    make
      ~load_all:(fun () ->
        Sys.readdir path |> Array.to_list
        |> List.filter (String.ends_with ~suffix:".json")
        |> List.map (fun name -> load_file (Filename.concat path name)))
      ~save:(fun record ->
        let target = file record.id in
        let temporary = target ^ ".tmp" in
        try
          let channel = open_out_bin temporary in
          Fun.protect
            (fun () ->
              output_string channel (Protocol.Json.to_string (to_json record));
              flush channel;
              Unix.fsync (Unix.descr_of_out_channel channel))
            ~finally:(fun () -> close_out channel);
          Unix.rename temporary target;
          try
            let directory = Unix.openfile path [ Unix.O_RDONLY ] 0 in
            Fun.protect
              (fun () -> Unix.fsync directory)
              ~finally:(fun () -> Unix.close directory)
          with Unix.Unix_error _ -> ()
        with exn ->
          if Sys.file_exists temporary then Sys.remove temporary;
          raise exn)
      ~delete:(fun id ->
        let target = file id in
        if Sys.file_exists target then Sys.remove target)
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

type delivery =
  | Deliver_event of stored_event * int
  | Deliver_terminal of terminal
  | Stop_delivery

type subscriber = {
  connection_id : string;
  subscriber_id : string;
  transport : Transport.t;
  deliveries : delivery Eio.Stream.t;
  event_capacity : int;
  event_byte_capacity : int;
  flush_interval : float;
  max_batch_bytes : int;
  mutable queued_events : int;
  mutable queued_bytes : int;
  mutable acknowledged : int64;
  mutable attached : bool;
}

type 'command accepted_command = { id : string; value : 'command }

type registry = {
  sw : Eio.Switch.t;
  now : unit -> float;
  persistence : Persistence.t;
  stored : (string, stored_session) Hashtbl.t;
  sessions : (string, packed_session) Hashtbl.t;
  handlers : (string, packed_handler) Hashtbl.t;
  connections : (string, Transport.t) Hashtbl.t;
  max_sessions : int;
}

and ('event, 'command, 'result) session = {
  registry : registry;
  id : string;
  endpoint : string;
  request : Protocol.Json.t;
  event_codec : 'event Protocol.Codec.t;
  command_codec : 'command Protocol.Codec.t;
  result_codec : 'result Protocol.Codec.t;
  commands : 'command accepted_command Eio.Stream.t;
  command_capacity : int;
  events : stored_event Queue.t;
  subscribers : (string, subscriber) Hashtbl.t;
  stored_commands : (string, stored_command) Hashtbl.t;
  acknowledgements : (string, stored_acknowledgement) Hashtbl.t;
  created_at : float;
  mutable updated_at : float;
  mutable sequence : int64;
  mutable lifecycle : lifecycle;
  mutable terminal : terminal option;
  mutable checkpoint : Protocol.Json.t option;
  mutable cancel_handler : unit -> unit;
}

and packed_session =
  | Session : ('event, 'command, 'result) session -> packed_session

and packed_handler =
  | Handler :
      ('request, 'event, 'command, 'result) Protocol.Stream_endpoint.t
      * (('event, 'command, 'result) session -> 'request -> unit)
      * int
      -> packed_handler

type t = registry

let rpc_error ?data ~code message = Protocol.Rpc_error.make ?data ~code message

let random_id prefix =
  let bytes = Bytes.create 16 in
  (try
     let channel = open_in_bin "/dev/urandom" in
     Fun.protect
       (fun () -> really_input channel bytes 0 (Bytes.length bytes))
       ~finally:(fun () -> close_in channel)
   with Sys_error _ ->
     Random.self_init ();
     for index = 0 to Bytes.length bytes - 1 do
       Bytes.set bytes index (Char.chr (Random.int 256))
     done);
  let encoded = Buffer.create 32 in
  Bytes.iter
    (fun byte ->
      Buffer.add_string encoded (Printf.sprintf "%02x" (Char.code byte)))
    bytes;
  prefix ^ "-" ^ Buffer.contents encoded

let summary (Session session) =
  {
    id = session.id;
    endpoint = session.endpoint;
    lifecycle = session.lifecycle;
    latest_sequence = session.sequence;
    created_at = session.created_at;
    updated_at = session.updated_at;
  }

let stored_of_session session =
  {
    schema_version = 2;
    id = session.id;
    endpoint = session.endpoint;
    request = session.request;
    lifecycle = session.lifecycle;
    events =
      Queue.fold (fun events event -> event :: events) [] session.events
      |> List.rev;
    terminal = session.terminal;
    commands =
      Hashtbl.fold
        (fun _ command commands -> command :: commands)
        session.stored_commands [];
    acknowledgements =
      Hashtbl.fold
        (fun _ acknowledgement acknowledgements ->
          acknowledgement :: acknowledgements)
        session.acknowledgements [];
    checkpoint = session.checkpoint;
    created_at = session.created_at;
    updated_at = session.updated_at;
  }

let persist session =
  let record = stored_of_session session in
  session.registry.persistence.save record;
  Hashtbl.replace session.registry.stored record.id record

let save_record session record =
  session.registry.persistence.save record;
  Hashtbl.replace session.registry.stored record.id record

let event_bytes (event : stored_event) =
  String.length (Protocol.Json.to_string event.encoded)

let stop_subscriber subscriber =
  if subscriber.attached then (
    subscriber.attached <- false;
    Eio.Stream.add subscriber.deliveries Stop_delivery)

let emit_batch subscriber session (events : stored_event list) =
  if not subscriber.attached then false
  else
    match
      Transport.emit subscriber.transport
        (Protocol.Envelope.make ~kind:"stream.batch"
           (`Assoc
              [
                ("stream_id", `String session.id);
                ( "events",
                  `List
                    (List.map
                       (fun (event : stored_event) -> event.encoded)
                       events) );
              ]))
    with
    | Ok () -> true
    | Error _ ->
        stop_subscriber subscriber;
        false

let emit_terminal subscriber session = function
  | Finished result when subscriber.attached ->
      Transport.emit subscriber.transport
        (Protocol.Envelope.make ~kind:"stream.finished"
           (`Assoc [ ("stream_id", `String session.id); ("result", result) ]))
      |> Result.is_ok
  | (Failed_with error | Cancelled_with error) when subscriber.attached ->
      Transport.emit subscriber.transport
        (Protocol.Envelope.make ~kind:"stream.failed"
           (`Assoc
              [
                ("stream_id", `String session.id);
                ("error", Protocol.Codec.encode Protocol.Rpc_error.codec error);
              ]))
      |> Result.is_ok
  | _ -> false

let take_delivery subscriber =
  let delivery = Eio.Stream.take subscriber.deliveries in
  (match delivery with
  | Deliver_event (_, bytes) ->
      subscriber.queued_events <- subscriber.queued_events - 1;
      subscriber.queued_bytes <- subscriber.queued_bytes - bytes
  | Deliver_terminal _ | Stop_delivery -> ());
  delivery

let take_delivery_nonblocking subscriber =
  match Eio.Stream.take_nonblocking subscriber.deliveries with
  | None -> None
  | Some delivery ->
      (match delivery with
      | Deliver_event (_, bytes) ->
          subscriber.queued_events <- subscriber.queued_events - 1;
          subscriber.queued_bytes <- subscriber.queued_bytes - bytes
      | Deliver_terminal _ | Stop_delivery -> ());
      Some delivery

let enqueue_event subscriber (event : stored_event) =
  let bytes = event_bytes event in
  if not subscriber.attached then false
  else if
    bytes > subscriber.max_batch_bytes
    || subscriber.queued_events >= subscriber.event_capacity
    || subscriber.queued_bytes + bytes > subscriber.event_byte_capacity
  then (
    stop_subscriber subscriber;
    false)
  else (
    subscriber.queued_events <- subscriber.queued_events + 1;
    subscriber.queued_bytes <- subscriber.queued_bytes + bytes;
    Eio.Stream.add subscriber.deliveries (Deliver_event (event, bytes));
    true)

let enqueue_terminal subscriber terminal =
  if subscriber.attached then
    Eio.Stream.add subscriber.deliveries (Deliver_terminal terminal)

let start_subscriber session subscriber ~replay ~terminal =
  let rec emit_replay events =
    if not subscriber.attached then false
    else
      match events with
      | [] -> true
      | first :: rest ->
          let first_bytes = event_bytes first in
          if first_bytes > subscriber.max_batch_bytes then (
            stop_subscriber subscriber;
            false)
          else
            let rec batch size batched remaining =
              match remaining with
              | next :: tail
                when size + event_bytes next <= subscriber.max_batch_bytes ->
                  batch (size + event_bytes next) (next :: batched) tail
              | remaining -> (List.rev batched, remaining)
            in
            let batched, remaining = batch first_bytes [ first ] rest in
            emit_batch subscriber session batched && emit_replay remaining
  in
  let rec delivery_loop carry =
    let delivery =
      match carry with
      | Some delivery -> delivery
      | None -> take_delivery subscriber
    in
    match delivery with
    | Stop_delivery -> ()
    | Deliver_terminal terminal ->
        if not (emit_terminal subscriber session terminal) then
          stop_subscriber subscriber
    | Deliver_event (first, first_bytes) ->
        if subscriber.flush_interval > 0. then
          Transport.sleep subscriber.transport subscriber.flush_interval;
        let rec drain size events =
          match take_delivery_nonblocking subscriber with
          | Some (Deliver_event (event, bytes))
            when size + bytes <= subscriber.max_batch_bytes ->
              drain (size + bytes) (event :: events)
          | Some delivery -> (List.rev events, Some delivery)
          | None -> (List.rev events, None)
        in
        let events, carry = drain first_bytes [ first ] in
        if emit_batch subscriber session events then delivery_loop carry
  in
  Eio.Fiber.fork ~sw:session.registry.sw (fun () ->
      try
        if emit_replay replay then
          match terminal with
          | Some terminal ->
              if not (emit_terminal subscriber session terminal) then
                stop_subscriber subscriber
          | None -> delivery_loop None
      with
      | Eio.Cancel.Cancelled _ -> ()
      | exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          subscriber.attached <- false;
          Transport.report_exception subscriber.transport
            ~context:"durable subscriber delivery" exn backtrace)

module Session = struct
  type ('event, 'command, 'result) t = ('event, 'command, 'result) session

  type 'command command = 'command accepted_command = {
    id : string;
    value : 'command;
  }

  let id (session : (_, _, _) session) = session.id
  let lifecycle (session : (_, _, _) session) = session.lifecycle
  let commands (session : (_, _, _) session) = session.commands
  let is_cancelled (session : (_, _, _) session) = session.lifecycle = Cancelled
  let checkpoint (session : (_, _, _) session) = session.checkpoint

  let save_checkpoint session checkpoint =
    let updated_at = session.registry.now () in
    let record = { (stored_of_session session) with checkpoint; updated_at } in
    save_record session record;
    session.checkpoint <- checkpoint;
    session.updated_at <- updated_at;
    Ok ()

  let set_command_status session command status =
    match Hashtbl.find_opt session.stored_commands command.id with
    | None ->
        Error
          (rpc_error ~code:"command_not_found"
             "the command was not admitted by this durable session")
    | Some stored when stored.status = status -> Ok ()
    | Some { status = Applied | Rejected _; _ } ->
        Error
          (rpc_error ~code:"command_already_final"
             "the durable command already has a final status")
    | Some stored ->
        let updated_at = session.registry.now () in
        let updated = { stored with status; updated_at } in
        let record =
          {
            (stored_of_session session) with
            commands =
              updated
              :: Hashtbl.fold
                   (fun id command commands ->
                     if id = updated.id then commands else command :: commands)
                   session.stored_commands [];
            updated_at;
          }
        in
        save_record session record;
        Hashtbl.replace session.stored_commands updated.id updated;
        session.updated_at <- updated_at;
        Ok ()

  let mark_command_applied session command =
    set_command_status session command Applied

  let mark_command_rejected session command error =
    set_command_status session command (Rejected error)

  let emit session event =
    if session.lifecycle <> Running then
      Error
        (rpc_error ~code:"session_not_running"
           "the durable session is not running")
    else
      let sequence = Int64.succ session.sequence in
      let timestamp = session.registry.now () in
      let encoded =
        Protocol.Codec.encode
          (Protocol.Sequenced.codec session.event_codec)
          { Protocol.Sequenced.sequence; timestamp; event }
      in
      let stored = { sequence; timestamp; encoded } in
      let record =
        {
          (stored_of_session session) with
          events =
            ( Queue.fold (fun events event -> event :: events) [] session.events
            |> List.rev
            |> fun events -> events @ [ stored ] );
          updated_at = timestamp;
        }
      in
      save_record session record;
      session.sequence <- sequence;
      session.updated_at <- timestamp;
      Queue.add stored session.events;
      Hashtbl.iter
        (fun _ subscriber -> ignore (enqueue_event subscriber stored))
        session.subscribers;
      Ok ()

  let set_terminal session lifecycle terminal =
    if session.terminal <> None then
      Error
        (rpc_error ~code:"session_finished"
           "the durable session is already terminal")
    else
      let updated_at = session.registry.now () in
      let record =
        {
          (stored_of_session session) with
          lifecycle;
          terminal = Some terminal;
          updated_at;
        }
      in
      save_record session record;
      session.lifecycle <- lifecycle;
      session.terminal <- Some terminal;
      session.updated_at <- updated_at;
      Hashtbl.iter
        (fun _ subscriber -> enqueue_terminal subscriber terminal)
        session.subscribers;
      Ok ()

  let finish session result =
    set_terminal session Completed
      (Finished (Protocol.Codec.encode session.result_codec result))

  let fail session error = set_terminal session Failed (Failed_with error)
end

let create ?(max_sessions = 1024) ~sw ~now ~persistence () =
  if max_sessions <= 0 then
    invalid_arg "Durable_session.create: max_sessions must be positive";
  let stored = Hashtbl.create 64 in
  List.iter
    (fun (record : stored_session) -> Hashtbl.replace stored record.id record)
    (persistence.Persistence.load_all ());
  {
    sw;
    now;
    persistence;
    stored;
    sessions = Hashtbl.create 64;
    handlers = Hashtbl.create 16;
    connections = Hashtbl.create 8;
    max_sessions;
  }

let list registry =
  Hashtbl.fold
    (fun _ session result -> summary session :: result)
    registry.sessions []
  |> List.sort (fun (left : summary) (right : summary) ->
      Float.compare right.updated_at left.updated_at)

let find registry id = Hashtbl.find_opt registry.sessions id

let snapshot registry id =
  match Hashtbl.find_opt registry.sessions id with
  | Some (Session session) -> Some (stored_of_session session)
  | None -> Hashtbl.find_opt registry.stored id

let admitted_commands registry ~session_id =
  match snapshot registry session_id with
  | None -> []
  | Some record ->
      List.filter
        (fun (command : stored_command) -> command.status = Admitted)
        record.commands

let set_registry_command_status registry ~session_id ~command_id status =
  let update commands updated_at =
    let rec loop result = function
      | [] ->
          Error
            (rpc_error ~code:"command_not_found"
               "the durable command was not found")
      | (command : stored_command) :: rest when command.id = command_id ->
          if command.status = status then
            Ok (List.rev_append result (command :: rest))
          else begin
            match command.status with
            | Applied | Rejected _ ->
                Error
                  (rpc_error ~code:"command_already_final"
                     "the durable command already has a final status")
            | Admitted ->
                let command = { command with status; updated_at } in
                Ok (List.rev_append result (command :: rest))
          end
      | command :: rest -> loop (command :: result) rest
    in
    loop [] commands
  in
  match snapshot registry session_id with
  | None ->
      Error
        (rpc_error ~code:"session_not_found" "the durable session was not found")
  | Some record ->
      let updated_at = registry.now () in
      begin match update record.commands updated_at with
      | Error _ as error -> error
      | Ok commands ->
          let record = { record with commands; updated_at } in
          registry.persistence.save record;
          Hashtbl.replace registry.stored session_id record;
          (match Hashtbl.find_opt registry.sessions session_id with
          | None -> ()
          | Some (Session session) ->
              List.iter
                (fun (command : stored_command) ->
                  Hashtbl.replace session.stored_commands command.id command)
                commands;
              session.updated_at <- updated_at);
          Ok ()
      end

let mark_command_applied registry ~session_id ~command_id =
  set_registry_command_status registry ~session_id ~command_id Applied

let mark_command_rejected registry ~session_id ~command_id error =
  set_registry_command_status registry ~session_id ~command_id (Rejected error)

let delete registry id =
  match snapshot registry id with
  | None ->
      Error
        (rpc_error ~code:"session_not_found" "the durable session was not found")
  | Some { lifecycle = Running | Recovering; _ } ->
      Error
        (rpc_error ~code:"session_running"
           "a running durable session cannot be deleted")
  | Some _ ->
      registry.persistence.delete id;
      (match Hashtbl.find_opt registry.sessions id with
      | None -> ()
      | Some (Session session) ->
          Hashtbl.iter
            (fun _ subscriber -> stop_subscriber subscriber)
            session.subscribers);
      Hashtbl.remove registry.sessions id;
      Hashtbl.remove registry.stored id;
      Ok ()

let compact ?max_age ?keep_latest registry =
  Option.iter
    (fun max_age ->
      if max_age < 0. then
        invalid_arg "Durable_session.compact: max_age must not be negative")
    max_age;
  Option.iter
    (fun keep_latest ->
      if keep_latest < 0 then
        invalid_arg "Durable_session.compact: keep_latest must not be negative")
    keep_latest;
  let candidates =
    Hashtbl.fold
      (fun _ (record : stored_session) records ->
        match record.lifecycle with
        | Running | Recovering -> records
        | Interrupted | Completed | Failed | Cancelled -> record :: records)
      registry.stored []
  in
  let expired, retained =
    match max_age with
    | None -> ([], candidates)
    | Some max_age ->
        let cutoff = registry.now () -. max_age in
        List.partition
          (fun (record : stored_session) -> record.updated_at < cutoff)
          candidates
  in
  let overflow =
    match keep_latest with
    | None -> []
    | Some keep_latest ->
        let retained =
          List.sort
            (fun (left : stored_session) (right : stored_session) ->
              Float.compare right.updated_at left.updated_at)
            retained
        in
        let rec drop index = function
          | [] -> []
          | _ :: rest when index < keep_latest -> drop (index + 1) rest
          | records -> records
        in
        drop 0 retained
  in
  let ids =
    List.sort_uniq String.compare
      (List.map
         (fun (record : stored_session) -> record.id)
         (expired @ overflow))
  in
  List.fold_left
    (fun deleted id ->
      match delete registry id with Ok () -> deleted + 1 | Error _ -> deleted)
    0 ids

let shutdown registry =
  Hashtbl.iter
    (fun _ (Session session) ->
      if session.lifecycle = Running || session.lifecycle = Recovering then
        session.cancel_handler ())
    registry.sessions

let persist_acknowledgement session subscriber_id sequence =
  let updated_at = session.registry.now () in
  let acknowledgement = { subscriber_id; sequence; updated_at } in
  let record =
    {
      (stored_of_session session) with
      acknowledgements =
        acknowledgement
        :: Hashtbl.fold
             (fun id acknowledgement acknowledgements ->
               if id = subscriber_id then acknowledgements
               else acknowledgement :: acknowledgements)
             session.acknowledgements [];
      updated_at;
    }
  in
  save_record session record;
  Hashtbl.replace session.acknowledgements subscriber_id acknowledgement;
  session.updated_at <- updated_at

let attach_subscriber ~event_capacity ~event_byte_capacity ~flush_interval
    ~max_batch_bytes connection_id subscriber_id transport session
    after_sequence =
  if
    Int64.compare after_sequence 0L < 0
    || Int64.compare after_sequence session.sequence > 0
  then
    Error
      (rpc_error ~code:"invalid_sequence"
         "the requested sequence is outside the session range")
  else (
    persist_acknowledgement session subscriber_id after_sequence;
    Option.iter stop_subscriber
      (Hashtbl.find_opt session.subscribers connection_id);
    let subscriber =
      {
        connection_id;
        subscriber_id;
        transport;
        deliveries = Eio.Stream.create (event_capacity + 2);
        event_capacity;
        event_byte_capacity;
        flush_interval;
        max_batch_bytes;
        queued_events = 0;
        queued_bytes = 0;
        acknowledged = after_sequence;
        attached = true;
      }
    in
    Hashtbl.replace session.subscribers connection_id subscriber;
    let replay =
      Queue.fold
        (fun events (event : stored_event) ->
          if Int64.compare event.sequence after_sequence > 0 then
            event :: events
          else events)
        [] session.events
      |> List.rev
    in
    start_subscriber session subscriber ~replay ~terminal:session.terminal;
    Ok subscriber)

let make_session registry endpoint request event_codec command_codec
    result_codec command_capacity =
  if Hashtbl.length registry.sessions >= registry.max_sessions then
    Error
      (rpc_error ~code:"session_limit_reached"
         "the durable session limit was reached")
  else
    let now = registry.now () in
    let session =
      {
        registry;
        id = random_id "session";
        endpoint;
        request;
        event_codec;
        command_codec;
        result_codec;
        commands = Eio.Stream.create command_capacity;
        command_capacity;
        events = Queue.create ();
        subscribers = Hashtbl.create 4;
        stored_commands = Hashtbl.create 32;
        acknowledgements = Hashtbl.create 8;
        created_at = now;
        updated_at = now;
        sequence = 0L;
        lifecycle = Running;
        terminal = None;
        checkpoint = None;
        cancel_handler = (fun () -> ());
      }
    in
    let record = stored_of_session session in
    registry.persistence.save record;
    Hashtbl.replace registry.stored record.id record;
    Hashtbl.add registry.sessions session.id (Session session);
    Ok session

let run_handler registry method_name handler session request =
  Eio.Fiber.fork ~sw:registry.sw (fun () ->
      try
        Eio.Switch.run ~name:("durable-session." ^ method_name)
        @@ fun session_sw ->
        session.cancel_handler <-
          (fun () -> Eio.Switch.fail session_sw Session_cancelled);
        handler session request;
        if session.lifecycle = Running then
          ignore
            (Session.fail session
               (rpc_error ~code:"session_incomplete"
                  "the durable session handler returned without finishing"))
      with
      | Session_cancelled -> ()
      | Eio.Cancel.Cancelled _ -> ()
      | exn ->
          let backtrace = Printexc.get_raw_backtrace () in
          prerr_endline
            (Printf.sprintf "durable session %s: %s\n%s" session.id
               (Printexc.to_string exn)
               (Printexc.raw_backtrace_to_string backtrace));
          ignore
            (Session.fail session
               (rpc_error ~code:"handler_exception"
                  "the durable session handler raised an exception")))

let restore_for_handler registry endpoint request_codec event_codec
    command_codec result_codec command_capacity =
  let records =
    Hashtbl.fold
      (fun id record records -> (id, record) :: records)
      registry.stored []
  in
  List.iter
    (fun (id, (record : stored_session)) ->
      if record.schema_version <> 1 && record.schema_version <> 2 then
        failwith
          (Printf.sprintf "unsupported durable session schema %d for %s"
             record.schema_version id);
      if record.endpoint = endpoint && not (Hashtbl.mem registry.sessions id)
      then
        match Protocol.Codec.decode request_codec record.request with
        | Error message ->
            failwith
              (Printf.sprintf "could not restore durable session %s: %s" id
                 message)
        | Ok _request ->
            let lifecycle =
              match record.lifecycle with
              | Running | Recovering -> Interrupted
              | state -> state
            in
            let session =
              {
                registry;
                id;
                endpoint;
                request = record.request;
                event_codec;
                command_codec;
                result_codec;
                commands = Eio.Stream.create command_capacity;
                command_capacity;
                events = Queue.create ();
                subscribers = Hashtbl.create 4;
                stored_commands = Hashtbl.create 32;
                acknowledgements = Hashtbl.create 8;
                created_at = record.created_at;
                updated_at = registry.now ();
                sequence = 0L;
                lifecycle;
                terminal = record.terminal;
                checkpoint = record.checkpoint;
                cancel_handler = (fun () -> ());
              }
            in
            List.iter
              (fun event ->
                Queue.add event session.events;
                session.sequence <- event.sequence)
              record.events;
            List.iter
              (fun (command : stored_command) ->
                Hashtbl.replace session.stored_commands command.id command)
              record.commands;
            List.iter
              (fun (acknowledgement : stored_acknowledgement) ->
                Hashtbl.replace session.acknowledgements
                  acknowledgement.subscriber_id acknowledgement)
              record.acknowledgements;
            Hashtbl.add registry.sessions id (Session session);
            if lifecycle <> record.lifecycle then persist session)
    records

let handle ?(command_capacity = 128) registry endpoint handler =
  if command_capacity <= 0 then
    invalid_arg "Durable_session.handle: command_capacity must be positive";
  let name = Protocol.Stream_endpoint.name endpoint in
  if Hashtbl.mem registry.handlers name then
    invalid_arg ("duplicate durable session endpoint: " ^ name);
  Hashtbl.add registry.handlers name
    (Handler (endpoint, handler, command_capacity));
  restore_for_handler registry name
    (Protocol.Stream_endpoint.request endpoint)
    (Protocol.Stream_endpoint.event endpoint)
    (Protocol.Stream_endpoint.command endpoint)
    (Protocol.Stream_endpoint.result endpoint)
    command_capacity

let start ?(command_capacity = 128) registry endpoint request handler =
  if command_capacity <= 0 then
    invalid_arg "Durable_session.start: command_capacity must be positive";
  let name = Protocol.Stream_endpoint.name endpoint in
  match
    make_session registry name
      (Protocol.Codec.encode
         (Protocol.Stream_endpoint.request endpoint)
         request)
      (Protocol.Stream_endpoint.event endpoint)
      (Protocol.Stream_endpoint.command endpoint)
      (Protocol.Stream_endpoint.result endpoint)
      command_capacity
  with
  | Error _ as error -> error
  | Ok session ->
      run_handler registry name handler session request;
      Ok session

let retry registry id =
  match Hashtbl.find_opt registry.sessions id with
  | None ->
      Error
        (rpc_error ~code:"session_not_found" "the durable session was not found")
  | Some (Session previous) when previous.lifecycle <> Interrupted ->
      Error
        (rpc_error ~code:"session_not_interrupted"
           "only an interrupted durable session can be retried")
  | Some (Session previous) -> (
      match Hashtbl.find_opt registry.handlers previous.endpoint with
      | None ->
          Error
            (rpc_error ~code:"method_not_found"
               "the durable session endpoint is not registered")
      | Some (Handler (endpoint, handler, command_capacity)) -> (
          match
            Protocol.Codec.decode
              (Protocol.Stream_endpoint.request endpoint)
              previous.request
          with
          | Error message -> Error (rpc_error ~code:"decode_error" message)
          | Ok request -> (
              match
                make_session registry previous.endpoint previous.request
                  (Protocol.Stream_endpoint.event endpoint)
                  (Protocol.Stream_endpoint.command endpoint)
                  (Protocol.Stream_endpoint.result endpoint)
                  command_capacity
              with
              | Error _ as error -> error
              | Ok session ->
                  run_handler registry previous.endpoint handler session request;
                  Ok session.id)))

let connect ?(event_capacity = 1024) ?(event_byte_capacity = 4 * 1024 * 1024)
    ?(flush_interval = 0.005) ?(max_batch_bytes = 256 * 1024)
    ?(authorize = fun ~subscriber_id:_ _ -> true) registry transport =
  if event_capacity <= 0 then
    invalid_arg "Durable_session.connect: event_capacity must be positive";
  if event_byte_capacity <= 0 then
    invalid_arg "Durable_session.connect: event_byte_capacity must be positive";
  if flush_interval < 0. then
    invalid_arg "Durable_session.connect: flush_interval must not be negative";
  if max_batch_bytes <= 0 then
    invalid_arg "Durable_session.connect: max_batch_bytes must be positive";
  let connection_id = random_id "window" in
  Hashtbl.add registry.connections connection_id transport;
  let unauthorized () =
    Error
      (rpc_error ~code:"unauthorized"
         "this window is not authorized for the durable session action")
  in
  let subscriber_id (envelope : Protocol.Envelope.t) =
    match envelope.payload with
    | `Assoc fields -> (
        match List.assoc_opt "subscriber_id" fields with
        | None -> Ok connection_id
        | Some (`String id) when id <> "" -> Ok id
        | Some _ ->
            Error
              (rpc_error ~code:"invalid_subscriber_id"
                 "subscriber_id must be a non-empty string"))
    | _ -> Ok connection_id
  in
  let find_session (envelope : Protocol.Envelope.t) =
    match
      Protocol.Json.string_member "stream_id" envelope.Protocol.Envelope.payload
    with
    | Error message -> Error (rpc_error ~code:"invalid_request" message)
    | Ok id -> (
        match Hashtbl.find_opt registry.sessions id with
        | Some session -> Ok session
        | None ->
            Error
              (rpc_error ~code:"stream_not_found"
                 "durable session was not found"))
  in
  let handle_open (envelope : Protocol.Envelope.t) =
    match
      ( Protocol.Json.string_member "method" envelope.Protocol.Envelope.payload,
        Protocol.Json.member "request" envelope.payload,
        subscriber_id envelope )
    with
    | Error message, _, _ | _, Error message, _ ->
        Error (rpc_error ~code:"invalid_request" message)
    | _, _, Error error -> Error error
    | Ok method_name, Ok encoded, Ok subscriber_id ->
        if not (authorize ~subscriber_id (Open_endpoint method_name)) then
          unauthorized ()
        else begin
          match Hashtbl.find_opt registry.handlers method_name with
          | None ->
              Error
                (rpc_error ~code:"method_not_found"
                   "durable session endpoint is not registered")
          | Some (Handler (endpoint, handler, command_capacity)) -> begin
              match
                Protocol.Codec.decode
                  (Protocol.Stream_endpoint.request endpoint)
                  encoded
              with
              | Error message -> Error (rpc_error ~code:"decode_error" message)
              | Ok request -> begin
                  match
                    make_session registry method_name encoded
                      (Protocol.Stream_endpoint.event endpoint)
                      (Protocol.Stream_endpoint.command endpoint)
                      (Protocol.Stream_endpoint.result endpoint)
                      command_capacity
                  with
                  | Error _ as error -> error
                  | Ok session ->
                      ignore
                        (attach_subscriber ~event_capacity ~event_byte_capacity
                           ~flush_interval ~max_batch_bytes connection_id
                           subscriber_id transport session 0L);
                      run_handler registry method_name handler session request;
                      Ok
                        (Protocol.Envelope.make ?id:envelope.id
                           ~kind:"stream.opened"
                           (`Assoc [ ("stream_id", `String session.id) ]))
                end
            end
        end
  in
  let handle_resume (envelope : Protocol.Envelope.t) =
    match (find_session envelope, subscriber_id envelope) with
    | (Error _ as error), _ -> error
    | _, Error error -> Error error
    | Ok (Session session), Ok subscriber_id ->
        if not (authorize ~subscriber_id (Attach_session session.id)) then
          unauthorized ()
        else begin
          match Protocol.Json.member "after_sequence" envelope.payload with
          | Error message -> Error (rpc_error ~code:"invalid_request" message)
          | Ok encoded -> begin
              match
                Protocol.Codec.decode Protocol.Codec.int64_string encoded
              with
              | Error message -> Error (rpc_error ~code:"decode_error" message)
              | Ok after_sequence -> begin
                  match
                    attach_subscriber ~event_capacity ~event_byte_capacity
                      ~flush_interval ~max_batch_bytes connection_id
                      subscriber_id transport session after_sequence
                  with
                  | Error _ as error -> error
                  | Ok _ ->
                      Ok
                        (Protocol.Envelope.make ?id:envelope.id
                           ~kind:"stream.resumed"
                           (`Assoc
                              [
                                ( "latest_sequence",
                                  Protocol.Codec.encode
                                    Protocol.Codec.int64_string session.sequence
                                );
                              ]))
                end
            end
        end
  in
  let handle_ack (envelope : Protocol.Envelope.t) =
    match find_session envelope with
    | Error _ as error -> error
    | Ok (Session session) -> begin
        match
          ( Hashtbl.find_opt session.subscribers connection_id,
            Protocol.Json.member "sequence" envelope.payload )
        with
        | None, _ ->
            Error (rpc_error ~code:"not_attached" "this window is not attached")
        | _, Error message -> Error (rpc_error ~code:"invalid_request" message)
        | Some { attached = false; _ }, _ ->
            Error (rpc_error ~code:"not_attached" "this window was detached")
        | Some subscriber, Ok encoded -> begin
            match Protocol.Codec.decode Protocol.Codec.int64_string encoded with
            | Error message -> Error (rpc_error ~code:"decode_error" message)
            | Ok sequence
              when Int64.compare sequence 0L < 0
                   || Int64.compare sequence session.sequence > 0 ->
                Error
                  (rpc_error ~code:"invalid_sequence"
                     "acknowledgement is outside the session range")
            | Ok sequence
              when Int64.compare sequence subscriber.acknowledged <= 0 ->
                Ok
                  (Protocol.Envelope.make ?id:envelope.id ~kind:"stream.acked"
                     `Null)
            | Ok sequence ->
                persist_acknowledgement session subscriber.subscriber_id
                  sequence;
                subscriber.acknowledged <- sequence;
                Ok
                  (Protocol.Envelope.make ?id:envelope.id ~kind:"stream.acked"
                     `Null)
          end
      end
  in
  let handle_detach (envelope : Protocol.Envelope.t) =
    match find_session envelope with
    | Error _ as error -> error
    | Ok (Session session) ->
        Option.iter stop_subscriber
          (Hashtbl.find_opt session.subscribers connection_id);
        Hashtbl.remove session.subscribers connection_id;
        Ok
          (Protocol.Envelope.make ?id:envelope.id ~kind:"stream.detached" `Null)
  in
  let handle_command (envelope : Protocol.Envelope.t) =
    match (envelope.id, find_session envelope) with
    | None, _ ->
        Error
          (rpc_error ~code:"invalid_command_id"
             "durable commands require an identifier")
    | _, (Error _ as error) -> error
    | Some command_id, Ok (Session session) -> begin
        match Hashtbl.find_opt session.subscribers connection_id with
        | None | Some { attached = false; _ } ->
            Error
              (rpc_error ~code:"not_attached"
                 "this window is not attached to the durable session")
        | Some subscriber
          when not
                 (authorize ~subscriber_id:subscriber.subscriber_id
                    (Command_session session.id)) ->
            unauthorized ()
        | Some _ -> begin
            match Protocol.Json.member "command" envelope.payload with
            | Error message -> Error (rpc_error ~code:"invalid_request" message)
            | Ok encoded -> begin
                match Hashtbl.find_opt session.stored_commands command_id with
                | Some stored
                  when stored.encoded = `Null || stored.encoded = encoded ->
                    Ok
                      (Protocol.Envelope.make ~id:command_id
                         ~kind:"stream.command_ack" `Null)
                | Some _ ->
                    Error
                      (rpc_error ~code:"command_id_conflict"
                         "the command identifier was already used for a \
                          different payload")
                | None -> begin
                    match
                      Protocol.Codec.decode session.command_codec encoded
                    with
                    | Error message ->
                        Error (rpc_error ~code:"decode_error" message)
                    | Ok _command
                      when Eio.Stream.length session.commands
                           >= session.command_capacity ->
                        Error
                          (rpc_error ~code:"command_queue_full"
                             "durable command queue is full")
                    | Ok command ->
                        let updated_at = registry.now () in
                        let stored =
                          {
                            id = command_id;
                            encoded;
                            status = Admitted;
                            created_at = updated_at;
                            updated_at;
                          }
                        in
                        let record =
                          {
                            (stored_of_session session) with
                            commands =
                              stored
                              :: Hashtbl.fold
                                   (fun _ command commands ->
                                     command :: commands)
                                   session.stored_commands [];
                            updated_at;
                          }
                        in
                        save_record session record;
                        Hashtbl.add session.stored_commands command_id stored;
                        session.updated_at <- updated_at;
                        Eio.Stream.add session.commands
                          { id = command_id; value = command };
                        Ok
                          (Protocol.Envelope.make ~id:command_id
                             ~kind:"stream.command_ack" `Null)
                  end
              end
          end
      end
  in
  let handle_cancel (envelope : Protocol.Envelope.t) =
    match find_session envelope with
    | Error _ as error -> error
    | Ok (Session session) -> begin
        match Hashtbl.find_opt session.subscribers connection_id with
        | None | Some { attached = false; _ } ->
            Error
              (rpc_error ~code:"not_attached"
                 "this window is not attached to the durable session")
        | Some subscriber
          when not
                 (authorize ~subscriber_id:subscriber.subscriber_id
                    (Cancel_session session.id)) ->
            unauthorized ()
        | Some _ ->
            if session.terminal = None then (
              let error =
                rpc_error ~code:"cancelled" "the durable session was cancelled"
              in
              let updated_at = registry.now () in
              let terminal = Cancelled_with error in
              let record =
                {
                  (stored_of_session session) with
                  lifecycle = Cancelled;
                  terminal = Some terminal;
                  updated_at;
                }
              in
              save_record session record;
              session.lifecycle <- Cancelled;
              session.terminal <- Some terminal;
              session.updated_at <- updated_at;
              session.cancel_handler ();
              Hashtbl.iter
                (fun _ subscriber -> enqueue_terminal subscriber terminal)
                session.subscribers);
            Ok
              (Protocol.Envelope.make ?id:envelope.id ~kind:"stream.cancelled"
                 `Null)
      end
  in
  let handle_list (envelope : Protocol.Envelope.t) =
    let encoded_summary (summary : summary) =
      `Assoc
        [
          ("id", `String summary.id);
          ("endpoint", `String summary.endpoint);
          ("lifecycle", `String (string_of_lifecycle summary.lifecycle));
          ( "latest_sequence",
            Protocol.Codec.encode Protocol.Codec.int64_string
              summary.latest_sequence );
          ("created_at", `Float summary.created_at);
          ("updated_at", `Float summary.updated_at);
        ]
    in
    match subscriber_id envelope with
    | Error error -> Error error
    | Ok subscriber_id when not (authorize ~subscriber_id List_sessions) ->
        unauthorized ()
    | Ok _ ->
        Ok
          (Protocol.Envelope.make ?id:envelope.id ~kind:"session.list"
             (`List (List.map encoded_summary (list registry))))
  in
  ignore (Transport.register transport ~kind:"stream.open" handle_open);
  ignore (Transport.register transport ~kind:"stream.resume" handle_resume);
  ignore (Transport.register transport ~kind:"stream.ack" handle_ack);
  ignore (Transport.register transport ~kind:"stream.detach" handle_detach);
  ignore (Transport.register transport ~kind:"stream.command" handle_command);
  ignore (Transport.register transport ~kind:"stream.cancel" handle_cancel);
  ignore (Transport.register transport ~kind:"session.list" handle_list);
  Transport.subscription transport (fun () ->
      Hashtbl.remove registry.connections connection_id;
      Hashtbl.iter
        (fun _ (Session session) ->
          Option.iter stop_subscriber
            (Hashtbl.find_opt session.subscribers connection_id);
          Hashtbl.remove session.subscribers connection_id)
        registry.sessions)
