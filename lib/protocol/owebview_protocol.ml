module Json = struct
  type t = Yojson.Safe.t

  let null = `Null
  let to_string value = Yojson.Safe.to_string value

  let of_string value =
    try Ok (Yojson.Safe.from_string value)
    with Yojson.Json_error message -> Error message

  let member name = function
    | `Assoc fields -> (
        match List.assoc_opt name fields with
        | Some value -> Ok value
        | None -> Error ("missing JSON member: " ^ name))
    | _ -> Error "expected a JSON object"

  let string_member name json =
    match member name json with
    | Ok (`String value) -> Ok value
    | Ok _ -> Error ("expected string member: " ^ name)
    | Error _ as error -> error
end

module Codec = struct
  type 'a t = { encode : 'a -> Json.t; decode : Json.t -> ('a, string) result }

  let make ~encode ~decode = { encode; decode }
  let encode codec = codec.encode
  let decode codec = codec.decode

  let xmap to_ from codec =
    make
      ~encode:(fun value -> codec.encode (from value))
      ~decode:(fun json -> Result.map to_ (codec.decode json))

  let json = make ~encode:Fun.id ~decode:(fun value -> Ok value)

  let string =
    make
      ~encode:(fun value -> `String value)
      ~decode:(function
        | `String value -> Ok value | _ -> Error "expected a JSON string")

  let bool =
    make
      ~encode:(fun value -> `Bool value)
      ~decode:(function
        | `Bool value -> Ok value | _ -> Error "expected a JSON boolean")

  let int =
    make
      ~encode:(fun value -> `Int value)
      ~decode:(function
        | `Int value -> Ok value | _ -> Error "expected a JSON integer")

  let float =
    make
      ~encode:(fun value -> `Float value)
      ~decode:(function
        | `Float value -> Ok value
        | `Int value -> Ok (Float.of_int value)
        | _ -> Error "expected a JSON number")

  let int64_string =
    make
      ~encode:(fun value -> `String (Int64.to_string value))
      ~decode:(function
        | `String value -> (
            try Ok (Int64.of_string value)
            with Failure _ -> Error "expected a decimal int64 string")
        | _ -> Error "expected a decimal int64 string")

  let unit =
    make
      ~encode:(fun () -> `Null)
      ~decode:(function `Null -> Ok () | _ -> Error "expected JSON null")

  let option codec =
    make
      ~encode:(function None -> `Null | Some value -> codec.encode value)
      ~decode:(function
        | `Null -> Ok None
        | value -> Result.map Option.some (codec.decode value))

  let list codec =
    let rec decode values acc =
      match values with
      | [] -> Ok (List.rev acc)
      | value :: rest -> (
          match codec.decode value with
          | Ok decoded -> decode rest (decoded :: acc)
          | Error _ as error -> error)
    in
    make
      ~encode:(fun values -> `List (List.map codec.encode values))
      ~decode:(function
        | `List values -> decode values [] | _ -> Error "expected a JSON array")
end

module Rpc_error = struct
  type t = { code : string; message : string; data : Json.t option }

  let make ?data ~code message = { code; message; data }

  let codec =
    Codec.make
      ~encode:(fun error ->
        `Assoc
          [
            ("code", `String error.code);
            ("message", `String error.message);
            ("data", Option.value error.data ~default:`Null);
          ])
      ~decode:(function
        | `Assoc fields -> (
            match
              (List.assoc_opt "code" fields, List.assoc_opt "message" fields)
            with
            | Some (`String code), Some (`String message) ->
                let data =
                  match List.assoc_opt "data" fields with
                  | None | Some `Null -> None
                  | Some value -> Some value
                in
                Ok { code; message; data }
            | _ -> Error "invalid RPC error")
        | _ -> Error "expected an RPC error object")
end

module Endpoint = struct
  type ('request, 'response) t = {
    name : string;
    request : 'request Codec.t;
    response : 'response Codec.t;
  }

  let make ~name ~request ~response = { name; request; response }
  let name endpoint = endpoint.name
  let request endpoint = endpoint.request
  let response endpoint = endpoint.response
end

module Frontend_endpoint = Endpoint

module Event = struct
  type 'event t = { name : string; event : 'event Codec.t }

  let make ~name ~event = { name; event }
  let name event = event.name
  let event event = event.event
end

module Stream_endpoint = struct
  type ('request, 'event, 'command, 'result) t = {
    name : string;
    request : 'request Codec.t;
    event : 'event Codec.t;
    command : 'command Codec.t;
    result : 'result Codec.t;
  }

  let make ~name ~request ~event ~command ~result =
    { name; request; event; command; result }

  let name endpoint = endpoint.name
  let request endpoint = endpoint.request
  let event endpoint = endpoint.event
  let command endpoint = endpoint.command
  let result endpoint = endpoint.result
end

module Envelope = struct
  type t = {
    version : int;
    kind : string;
    id : string option;
    payload : Json.t;
  }

  let current_version = 1
  let make ?id ~kind payload = { version = current_version; kind; id; payload }

  let to_json envelope =
    `Assoc
      [
        ("version", `Int envelope.version);
        ("kind", `String envelope.kind);
        ("id", match envelope.id with None -> `Null | Some id -> `String id);
        ("payload", envelope.payload);
      ]

  let to_string envelope = Json.to_string (to_json envelope)

  let of_json = function
    | `Assoc fields -> (
        match
          ( List.assoc_opt "version" fields,
            List.assoc_opt "kind" fields,
            List.assoc_opt "id" fields,
            List.assoc_opt "payload" fields )
        with
        | Some (`Int version), Some (`String kind), id, Some payload ->
            let id = match id with Some (`String id) -> Some id | _ -> None in
            if version = current_version then Ok { version; kind; id; payload }
            else
              Error (Printf.sprintf "unsupported protocol version: %d" version)
        | _ -> Error "invalid protocol envelope")
    | _ -> Error "expected a protocol envelope object"

  let of_string encoded =
    match Json.of_string encoded with
    | Ok json -> of_json json
    | Error _ as error -> error
end

module Sequenced = struct
  type 'event t = { sequence : int64; timestamp : float; event : 'event }

  let codec event_codec =
    Codec.make
      ~encode:(fun value ->
        `Assoc
          [
            ("sequence", Codec.encode Codec.int64_string value.sequence);
            ("timestamp", `Float value.timestamp);
            ("event", Codec.encode event_codec value.event);
          ])
      ~decode:(function
        | `Assoc fields -> (
            match
              ( List.assoc_opt "sequence" fields,
                List.assoc_opt "timestamp" fields,
                List.assoc_opt "event" fields )
            with
            | Some sequence, Some timestamp, Some event -> (
                match
                  ( Codec.decode Codec.int64_string sequence,
                    Codec.decode Codec.float timestamp,
                    Codec.decode event_codec event )
                with
                | Ok sequence, Ok timestamp, Ok event ->
                    Ok { sequence; timestamp; event }
                | Error message, _, _
                | _, Error message, _
                | _, _, Error message ->
                    Error message)
            | _ -> Error "invalid sequenced event")
        | _ -> Error "expected a sequenced event object")
end
