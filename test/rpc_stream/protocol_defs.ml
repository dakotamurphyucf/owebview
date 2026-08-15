module Protocol = Owebview_protocol

let echo =
  Protocol.Endpoint.make ~name:"test.echo" ~request:Protocol.Codec.string
    ~response:Protocol.Codec.string

let shutdown =
  Protocol.Endpoint.make ~name:"test.shutdown" ~request:Protocol.Codec.unit
    ~response:Protocol.Codec.unit

let slow =
  Protocol.Endpoint.make ~name:"test.slow" ~request:Protocol.Codec.unit
    ~response:Protocol.Codec.unit

let delay =
  Protocol.Endpoint.make ~name:"test.delay" ~request:Protocol.Codec.unit
    ~response:Protocol.Codec.unit

let report_failure =
  Protocol.Endpoint.make ~name:"test.report_failure"
    ~request:Protocol.Codec.string ~response:Protocol.Codec.unit

let reload_status =
  Protocol.Endpoint.make ~name:"test.reload_status" ~request:Protocol.Codec.unit
    ~response:Protocol.Codec.bool

let frontend_echo =
  Protocol.Frontend_endpoint.make ~name:"test.frontend_echo"
    ~request:Protocol.Codec.string ~response:Protocol.Codec.string

let frontend_never =
  Protocol.Frontend_endpoint.make ~name:"test.frontend_never"
    ~request:Protocol.Codec.unit ~response:Protocol.Codec.unit

let notice =
  Protocol.Event.make ~name:"test.notice" ~event:Protocol.Codec.string

type command = Emit_more | Finish

let command_codec =
  Protocol.Codec.make
    ~encode:(function
      | Emit_more -> `String "emit_more" | Finish -> `String "finish")
    ~decode:(function
      | `String "emit_more" -> Ok Emit_more
      | `String "finish" -> Ok Finish
      | _ -> Error "expected the finish command")

let stream =
  Protocol.Stream_endpoint.make ~name:"test.stream" ~request:Protocol.Codec.int
    ~event:Protocol.Codec.string ~command:command_codec
    ~result:Protocol.Codec.string

let coalesced_stream =
  Protocol.Stream_endpoint.make ~name:"test.coalesced_stream"
    ~request:Protocol.Codec.int ~event:Protocol.Codec.string
    ~command:command_codec ~result:Protocol.Codec.string

let oversized_stream =
  Protocol.Stream_endpoint.make ~name:"test.oversized_stream"
    ~request:Protocol.Codec.unit ~event:Protocol.Codec.string
    ~command:command_codec ~result:Protocol.Codec.string

let byte_limited_stream =
  Protocol.Stream_endpoint.make ~name:"test.byte_limited_stream"
    ~request:Protocol.Codec.unit ~event:Protocol.Codec.string
    ~command:command_codec ~result:Protocol.Codec.string

let command_limited_stream =
  Protocol.Stream_endpoint.make ~name:"test.command_limited_stream"
    ~request:Protocol.Codec.unit ~event:Protocol.Codec.string
    ~command:command_codec ~result:Protocol.Codec.string
