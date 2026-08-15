module App = Owebview_app
module Protocol = Rpc_stream_protocol.Protocol_defs

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    (fun () -> really_input_string channel (in_channel_length channel))
    ~finally:(fun () -> close_in channel)

let html javascript =
  "<!doctype html><meta charset=\"utf-8\"><div \
   id=\"status\">testing</div><script>" ^ javascript ^ "</script>"

let () =
  if Array.length Sys.argv <> 2 then
    failwith "expected the frontend JavaScript path";
  let javascript = read_file Sys.argv.(1) in
  let frontend_failure = ref None in
  let reload_rejected_pending_call = ref false in
  Webview_eio.run
    ~setup:(fun webview ->
      Webview.set_title webview "Typed RPC and stream integration test";
      Webview.set_html webview (html javascript))
    (fun ~env ~sw app ->
      let transport =
        App.Transport.create ~sw
          ~now:(fun () -> Eio.Time.now env#clock)
          ~sleep:(Eio.Time.sleep env#clock) app
      in
      let rpc = App.Rpc.Server.create transport in
      ignore
        (App.Rpc.Server.handle rpc Protocol.echo (fun request ->
             Ok ("echo:" ^ request)));
      ignore
        (App.Rpc.Server.handle rpc Protocol.shutdown (fun () ->
             Eio.Fiber.fork ~sw (fun () ->
                 Eio.Time.sleep env#clock 0.05;
                 Webview_eio.close app);
             Ok ()));
      let never, _resolve_never = Eio.Promise.create () in
      ignore
        (App.Rpc.Server.handle rpc Protocol.slow (fun () ->
             Eio.Promise.await never;
             Ok ()));
      ignore
        (App.Rpc.Server.handle rpc Protocol.delay (fun () ->
             Eio.Time.sleep env#clock 0.03;
             Ok ()));
      ignore
        (App.Rpc.Server.handle rpc Protocol.report_failure (fun message ->
             frontend_failure := Some message;
             Eio.Fiber.fork ~sw (fun () ->
                 Eio.Time.sleep env#clock 0.05;
                 Webview_eio.close app);
             Ok ()));
      ignore
        (App.Rpc.Server.handle rpc Protocol.reload_status (fun () ->
             Ok !reload_rejected_pending_call));
      let streams = App.Stream.Server.create transport in
      ignore
        (App.Stream.Server.handle ~event_capacity:8 ~replay_capacity:2
           ~flush_interval:0.005 streams Protocol.stream (fun session count ->
             let rec emit_events index =
               if index > count then
                 let rec handle_commands () =
                   match
                     Eio.Stream.take (App.Stream.Session.commands session)
                   with
                   | Protocol.Emit_more ->
                       (match App.Stream.Session.emit session "event-4" with
                       | Ok () -> ()
                       | Error error -> failwith error.message);
                       handle_commands ()
                   | Protocol.Finish ->
                       ignore
                         (App.Stream.Session.finish session "stream-complete")
                 in
                 handle_commands ()
               else
                 match
                   App.Stream.Session.emit session
                     (Printf.sprintf "event-%d" index)
                 with
                 | Ok () -> emit_events (index + 1)
                 | Error _ ->
                     ignore
                       (App.Stream.Session.finish session "slow-subscriber")
             in
             emit_events 1));
      ignore
        (App.Stream.Server.handle ~flush_interval:0.005
           ~coalesce:(fun previous next -> Some (previous ^ "+" ^ next))
           streams Protocol.coalesced_stream
           (fun session count ->
             for index = 1 to count do
               ignore
                 (App.Stream.Session.emit session
                    (Printf.sprintf "part-%d" index))
             done;
             ignore (App.Stream.Session.finish session "coalesced")));
      ignore
        (App.Stream.Server.handle ~max_batch_bytes:128 streams
           Protocol.oversized_stream (fun session () ->
             let result =
               match App.Stream.Session.emit session (String.make 512 'x') with
               | Ok () -> "unexpected_success"
               | Error error -> error.code
             in
             ignore (App.Stream.Session.finish session result)));
      ignore
        (App.Stream.Server.handle ~event_byte_capacity:256 ~max_batch_bytes:1024
           ~flush_interval:1. streams Protocol.byte_limited_stream
           (fun session () ->
             let first =
               App.Stream.Session.emit session (String.make 128 'a')
             in
             let second =
               App.Stream.Session.emit session (String.make 128 'b')
             in
             let result =
               match (first, second) with
               | Ok (), Error error -> error.code
               | Error error, _ -> "first:" ^ error.code
               | Ok (), Ok () -> "unexpected_success"
             in
             ignore (App.Stream.Session.finish session result)));
      ignore
        (App.Stream.Server.handle ~command_capacity:1 streams
           Protocol.command_limited_stream (fun session () ->
             Eio.Time.sleep env#clock 0.05;
             ignore (App.Stream.Session.finish session "command-test-complete")));
      App.Transport.await_ready transport;
      while App.Transport.ready_generation transport < 2 do
        Eio.Time.sleep env#clock 0.001
      done;
      (match App.Transport.frontend transport with
      | Some
          {
            frontend_build_id = "integration-test-2";
            application_version = Some "test-app-1";
            capabilities;
            _;
          }
        when List.mem "rpc" capabilities && List.mem "streams" capabilities ->
          ()
      | _ -> failwith "validated frontend handshake metadata was not retained");
      (match
         App.Frontend.call transport Protocol.frontend_echo "from-backend"
       with
      | Ok "frontend:from-backend" -> ()
      | Ok response -> failwith ("unexpected frontend response: " ^ response)
      | Error error -> failwith ("frontend call failed: " ^ error.message));
      Eio.Fiber.fork ~sw (fun () ->
          match
            App.Frontend.call ~timeout:30. transport Protocol.frontend_never ()
          with
          | Error error when error.code = "frontend_reloaded" ->
              reload_rejected_pending_call := true
          | Error error ->
              failwith
                ("pending frontend call returned the wrong reload error: "
               ^ error.code)
          | Ok () -> failwith "pending frontend call unexpectedly completed");
      (match App.Event.emit transport Protocol.notice "backend-event" with
      | Ok () -> ()
      | Error error -> failwith ("event emit failed: " ^ error.message));
      Webview_eio.await_closed app);
  match !frontend_failure with
  | None -> ()
  | Some message -> failwith ("frontend integration failure: " ^ message)
