module Protocol = Owebview_protocol

let frontend_endpoint =
  Protocol.Frontend_endpoint.make ~name:"test.never_responds"
    ~request:Protocol.Codec.unit ~response:Protocol.Codec.unit

let ready_html () =
  let envelope =
    Protocol.Envelope.make ~kind:"ready"
      (`Assoc
         [
           ("protocol_version", `Int Protocol.Envelope.current_version);
           ("frontend_build_id", `String "transport-close-test");
           ("application_version", `Null);
           ("capabilities", `List [ `String "rpc"; `String "streams" ]);
         ])
  in
  let argument =
    Protocol.Json.to_string (`String (Protocol.Envelope.to_string envelope))
  in
  "<p>No frontend receiver</p><script>" ^ "(function connect(){"
  ^ "if(typeof globalThis.__owebview_native==='function'){"
  ^ "void globalThis.__owebview_native(" ^ argument ^ ");"
  ^ "}else{setTimeout(connect,1);}})();" ^ "</script>"

let () =
  let observed_close = Atomic.make false in
  Webview_eio.run
    ~setup:(fun webview -> Webview.set_html webview (ready_html ()))
    (fun ~env ~sw app ->
      let transport =
        Owebview_app.Transport.create ~sw
          ~now:(fun () -> Eio.Time.now env#clock)
          ~sleep:(Eio.Time.sleep env#clock) app
      in
      Owebview_app.Transport.await_ready transport;
      (match
         Owebview_app.Frontend.call ~timeout:0.02 transport frontend_endpoint ()
       with
      | Error error when error.code = "timeout" -> ()
      | Error error -> failwith ("unexpected frontend-call error: " ^ error.code)
      | Ok () -> failwith "frontend call unexpectedly completed");
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Cancel.protect (fun () ->
              match
                Owebview_app.Frontend.call ~timeout:30. transport
                  frontend_endpoint ()
              with
              | Error error when error.code = "window_closed" ->
                  Atomic.set observed_close true
              | Error error ->
                  failwith
                    ("unexpected close-time frontend-call error: " ^ error.code)
              | Ok () ->
                  failwith "close-time frontend call unexpectedly completed"));
      Eio.Time.sleep env#clock 0.02;
      Webview_eio.close app;
      Webview_eio.await_closed app);
  if not (Atomic.get observed_close) then
    failwith "pending frontend call did not observe window closure"
