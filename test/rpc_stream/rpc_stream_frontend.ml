open Js_of_ocaml
module Client = Owebview_jsoo
module Protocol = Rpc_stream_protocol.Protocol_defs

exception Test_failure of string

let ( let* ) promise continuation = Promise.bind continuation promise
let error_message (error : Owebview_protocol.Rpc_error.t) = error.message
let error_code (error : Owebview_protocol.Rpc_error.t) = error.code

let unwrap label = function
  | Ok value -> value
  | Error error -> raise (Test_failure (label ^ ": " ^ error_message error))

let require condition message =
  if not condition then raise (Test_failure message)

let install_frontend_handlers client frontend_calls notices =
  ignore
    (Client.Frontend.handle client Protocol.frontend_echo (fun request ->
         incr frontend_calls;
         Promise.resolve (Ok ("frontend:" ^ request))));
  ignore
    (Client.Frontend.handle client Protocol.frontend_never (fun () ->
         Promise.make (fun ~resolve:_ ~reject:_ -> ())));
  ignore
    (Client.Event.subscribe client Protocol.notice (fun notice ->
         notices := notice :: !notices))

let report_failure client message =
  ignore (Client.Rpc.call client Protocol.report_failure message)

let () =
  let client = Client.create () in
  let frontend_calls = ref 0 in
  let notices = ref [] in
  Client.install client;
  install_frontend_handlers client frontend_calls notices;
  let workflow =
    let* pre_handshake = Client.Rpc.call client Protocol.echo "too-early" in
    let () =
      match pre_handshake with
      | Error error when error_code error = "frontend_not_ready" -> ()
      | Error error ->
          raise
            (Test_failure
               ("pre-handshake RPC returned the wrong error: "
              ^ error_message error))
      | Ok _ -> raise (Test_failure "pre-handshake RPC unexpectedly succeeded")
    in
    let* mismatched =
      Client.ready ~protocol_version:999 ~frontend_build_id:"incompatible"
        client
    in
    let () =
      match mismatched with
      | Error error when error_code error = "protocol_mismatch" -> ()
      | Error error ->
          raise
            (Test_failure
               ("protocol mismatch returned the wrong error: "
              ^ error_message error))
      | Ok () ->
          raise (Test_failure "incompatible handshake unexpectedly succeeded")
    in
    let* missing_capability =
      Client.ready ~frontend_build_id:"missing-streams" ~capabilities:[ "rpc" ]
        client
    in
    let () =
      match missing_capability with
      | Error error when error_code error = "missing_capability" -> ()
      | Error error ->
          raise
            (Test_failure
               ("missing capability returned the wrong error: "
              ^ error_message error))
      | Ok () ->
          raise (Test_failure "incomplete handshake unexpectedly succeeded")
    in
    let* ready =
      Client.ready ~frontend_build_id:"integration-test-1"
        ~application_version:"test-app-1" client
    in
    let () = ignore (unwrap "first ready" ready) in
    let* ready =
      Client.ready ~frontend_build_id:"integration-test-2"
        ~application_version:"test-app-1" client
    in
    let () = ignore (unwrap "second ready" ready) in
    let* echo = Client.Rpc.call client Protocol.echo "hello" in
    let echo = unwrap "echo" echo in
    let () = require (echo = "echo:hello") ("unexpected echo: " ^ echo) in

    let* opened = Client.Stream.open_ client Protocol.coalesced_stream 3 in
    let coalesced_stream = unwrap "coalesced stream" opened in
    let coalesced_events = ref [] in
    ignore
      (Client.Stream.on_event coalesced_stream (fun event ->
           coalesced_events := event :: !coalesced_events));
    let* coalesced_result = Client.Stream.finished coalesced_stream in
    let coalesced_result = unwrap "coalesced result" coalesced_result in
    let () =
      require (coalesced_result = "coalesced") "coalesced stream failed"
    in
    let () =
      require
        (List.rev !coalesced_events = [ "part-1+part-2+part-3" ])
        "adjacent stream events were not coalesced"
    in
    let* command_after_finish =
      Client.Stream.send coalesced_stream Protocol.Finish
    in
    let () =
      match command_after_finish with
      | Error error when error_code error = "stream_finished" -> ()
      | Error error ->
          raise
            (Test_failure
               ("post-finish command returned the wrong error: "
              ^ error_message error))
      | Ok () ->
          raise (Test_failure "post-finish command unexpectedly succeeded")
    in
    let* terminal_attach =
      Client.Stream.attach client Protocol.coalesced_stream
        ~stream_id:(Client.Stream.id coalesced_stream)
        ~after_sequence:(Client.Stream.last_sequence coalesced_stream)
    in
    let terminal_stream = unwrap "terminal stream attach" terminal_attach in
    let* terminal_result = Client.Stream.finished terminal_stream in
    let terminal_result = unwrap "retained terminal result" terminal_result in
    let () =
      require
        (terminal_result = "coalesced")
        "retained terminal stream returned the wrong result"
    in
    let* invalid_sequence =
      Client.Stream.attach client Protocol.coalesced_stream
        ~stream_id:(Client.Stream.id coalesced_stream)
        ~after_sequence:
          (Int64.succ (Client.Stream.last_sequence coalesced_stream))
    in
    let () =
      match invalid_sequence with
      | Error error when error_code error = "invalid_sequence" -> ()
      | Error error ->
          raise
            (Test_failure
               ("out-of-range resume returned the wrong error: "
              ^ error_message error))
      | Ok _ ->
          raise (Test_failure "out-of-range resume unexpectedly succeeded")
    in
    let* opened = Client.Stream.open_ client Protocol.oversized_stream () in
    let oversized = unwrap "oversized stream" opened in
    let* oversized_result = Client.Stream.finished oversized in
    let oversized_result = unwrap "oversized stream result" oversized_result in
    let () =
      require
        (oversized_result = "event_too_large")
        ("unexpected oversized event result: " ^ oversized_result)
    in
    let* opened = Client.Stream.open_ client Protocol.byte_limited_stream () in
    let byte_limited = unwrap "byte-limited stream" opened in
    let* byte_limited_result = Client.Stream.finished byte_limited in
    let byte_limited_result =
      unwrap "byte-limited stream result" byte_limited_result
    in
    let () =
      require
        (byte_limited_result = "slow_subscriber")
        ("unexpected byte-limit result: " ^ byte_limited_result)
    in
    let* opened =
      Client.Stream.open_ client Protocol.command_limited_stream ()
    in
    let command_limited = unwrap "command-limited stream" opened in
    let* first_command =
      Client.Stream.send command_limited Protocol.Emit_more
    in
    let () = ignore (unwrap "first bounded command" first_command) in
    let* second_command =
      Client.Stream.send command_limited Protocol.Emit_more
    in
    let () =
      match second_command with
      | Error error when error_code error = "command_queue_full" -> ()
      | Error error ->
          raise
            (Test_failure
               ("command overflow returned the wrong error: "
              ^ error_message error))
      | Ok () ->
          raise (Test_failure "command queue overflow unexpectedly succeeded")
    in
    let* command_result = Client.Stream.finished command_limited in
    let command_result = unwrap "command-limited result" command_result in
    let () =
      require
        (command_result = "command-test-complete")
        "command-limited stream returned the wrong result"
    in

    let* opened = Client.Stream.open_ client Protocol.stream 1 in
    let cancelled_stream = unwrap "cancelled stream" opened in
    let* cancelled = Client.Stream.cancel cancelled_stream in
    let () = ignore (unwrap "stream cancel" cancelled) in
    let* cancelled_result = Client.Stream.finished cancelled_stream in
    let () =
      match cancelled_result with
      | Error error when error_code error = "cancelled" -> ()
      | Error error ->
          raise
            (Test_failure
               ("cancelled stream returned the wrong error: "
              ^ error_message error))
      | Ok _ ->
          raise (Test_failure "cancelled stream unexpectedly finished normally")
    in

    let slow_call = Client.Rpc.call_with_id client Protocol.slow () in
    let* cancelled = Client.Rpc.cancel client slow_call.id in
    let () = ignore (unwrap "cancel" cancelled) in
    let* slow_result = slow_call.result in
    let () =
      match slow_result with
      | Error error when error_code error = "cancelled" -> ()
      | Error error ->
          raise
            (Test_failure
               ("slow RPC returned wrong error: " ^ error_message error))
      | Ok () -> raise (Test_failure "slow RPC unexpectedly completed")
    in

    let* opened = Client.Stream.open_ client Protocol.stream 3 in
    let normal_stream = unwrap "normal stream" opened in
    let events = ref [] in
    let events_ready_resolver = ref (fun _ -> ()) in
    let events_ready =
      Promise.make (fun ~resolve ~reject:_ -> events_ready_resolver := resolve)
    in
    ignore
      (Client.Stream.on_event normal_stream (fun event ->
           events := event :: !events;
           if List.length !events = 3 then !events_ready_resolver ()));

    let* opened = Client.Stream.open_ client Protocol.stream 100 in
    let overflow_stream = unwrap "overflow stream" opened in
    let* overflow_result = Client.Stream.finished overflow_stream in
    let overflow_result = unwrap "overflow result" overflow_result in
    let () =
      require
        (overflow_result = "slow-subscriber")
        ("unexpected overflow result: " ^ overflow_result)
    in
    let* opened = Client.Stream.open_ client Protocol.stream 0 in
    let replay_limited = unwrap "replay-limited stream" opened in
    let replay_limited_id = Client.Stream.id replay_limited in
    let* detached = Client.Stream.detach replay_limited in
    let () = ignore (unwrap "replay-limited detach" detached) in
    let* emitted = Client.Stream.send replay_limited Protocol.Emit_more in
    let () = ignore (unwrap "first replay-limited command" emitted) in
    let* emitted = Client.Stream.send replay_limited Protocol.Emit_more in
    let () = ignore (unwrap "second replay-limited command" emitted) in
    let* emitted = Client.Stream.send replay_limited Protocol.Emit_more in
    let () = ignore (unwrap "third replay-limited command" emitted) in
    let* delayed = Client.Rpc.call client Protocol.delay () in
    let () = ignore (unwrap "replay overflow delay" delayed) in
    let* unavailable =
      Client.Stream.attach client Protocol.stream ~stream_id:replay_limited_id
        ~after_sequence:0L
    in
    let () =
      match unavailable with
      | Error error when error_code error = "replay_unavailable" -> ()
      | Error error ->
          raise
            (Test_failure
               ("replay overflow returned the wrong error: "
              ^ error_message error))
      | Ok _ -> raise (Test_failure "unavailable replay unexpectedly succeeded")
    in
    let* cancelled = Client.Stream.cancel replay_limited in
    let () = ignore (unwrap "replay-limited cancel" cancelled) in
    let* () = events_ready in
    let sequence = Client.Stream.last_sequence normal_stream in
    let* detached = Client.Stream.detach normal_stream in
    let () = ignore (unwrap "stream detach" detached) in
    let* emitted = Client.Stream.send normal_stream Protocol.Emit_more in
    let () = ignore (unwrap "detached command" emitted) in
    let* delayed = Client.Rpc.call client Protocol.delay () in
    let () = ignore (unwrap "replay delay" delayed) in

    let reloaded = Client.create () in
    Client.install reloaded;
    install_frontend_handlers reloaded frontend_calls notices;
    let* ready = Client.ready ~frontend_build_id:"reload-test" reloaded in
    let () = ignore (unwrap "reload ready" ready) in
    let* delayed = Client.Rpc.call reloaded Protocol.delay () in
    let () = ignore (unwrap "frontend reload delay" delayed) in
    let* reload_status = Client.Rpc.call reloaded Protocol.reload_status () in
    let reload_status = unwrap "frontend reload status" reload_status in
    let () =
      require reload_status
        "frontend reload did not reject the old pending frontend call"
    in
    let* attached =
      Client.Stream.attach reloaded Protocol.stream
        ~stream_id:(Client.Stream.id normal_stream)
        ~after_sequence:sequence
    in
    let stream = unwrap "stream resume" attached in
    let replayed = ref [] in
    ignore
      (Client.Stream.on_event stream (fun event ->
           replayed := event :: !replayed));
    let* sent = Client.Stream.send stream Protocol.Finish in
    let () = ignore (unwrap "finish command" sent) in
    let* finished = Client.Stream.finished stream in
    let result = unwrap "normal result" finished in
    let () =
      require (result = "stream-complete") ("unexpected result: " ^ result)
    in
    let () =
      require
        (List.rev !events = [ "event-1"; "event-2"; "event-3" ])
        "stream events were lost or reordered"
    in
    let () =
      require
        (List.rev !replayed = [ "event-4" ])
        "detached stream event was not replayed after attach"
    in
    let () =
      require (!frontend_calls = 1)
        "backend-to-frontend RPC did not run exactly once"
    in
    let () =
      require
        (List.rev !notices = [ "backend-event" ])
        "typed event was not delivered"
    in
    let* shutdown = Client.Rpc.call reloaded Protocol.shutdown () in
    ignore (unwrap "shutdown" shutdown);
    Promise.resolve ()
  in
  ignore
    (Promise.catch
       (fun error ->
         let message =
           Js.Unsafe.meth_call (Promise.error_to_any error) "toString" [||]
           |> Js.to_string
         in
         report_failure client message;
         Promise.resolve ())
       workflow)
