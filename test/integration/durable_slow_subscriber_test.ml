module App = Owebview_app
module Protocol = Owebview_protocol

let endpoint =
  Protocol.Stream_endpoint.make ~name:"test.slow-durable-subscriber"
    ~request:Protocol.Codec.unit ~event:Protocol.Codec.int
    ~command:Protocol.Codec.unit ~result:Protocol.Codec.string

let encoded envelope =
  Protocol.Envelope.to_string envelope |> fun value ->
  Protocol.Json.to_string (`String value)

let ready name =
  Protocol.Envelope.make ~kind:"ready"
    (`Assoc
       [
         ("protocol_version", `Int Protocol.Envelope.current_version);
         ("frontend_build_id", `String name);
         ("application_version", `String "durable-slow-subscriber-test");
         ("capabilities", `List [ `String "rpc"; `String "streams" ]);
       ])
  |> encoded

let page ~name ~session_id =
  let resume =
    Protocol.Envelope.make ~kind:"stream.resume"
      (`Assoc
         [
           ("stream_id", `String session_id);
           ("subscriber_id", `String name);
           ( "after_sequence",
             Protocol.Codec.encode Protocol.Codec.int64_string 0L );
         ])
    |> encoded
  in
  Printf.sprintf
    {|
<!doctype html><meta charset="utf-8"><title>%s</title>
<script>
(function () {
  const report = value => globalThis.__test_report(value);
  let events = 0;
  globalThis.__owebviewReceive = raw => {
    const envelope = JSON.parse(raw);
    if (envelope.kind === "stream.batch") {
      events += envelope.payload.events.length;
      void report("events:" + events);
    } else if (envelope.kind === "stream.finished") {
      void report("finished:" + envelope.payload.result);
    }
  };
  (async () => {
    await globalThis.__owebview_native(%s);
    await globalThis.__owebview_native(%s);
    await report("attached");
  })().catch(error => report("setup-error:" + error));
})();
</script>
|}
    name (ready name) resume

let await_message clock reports expected =
  let rec loop () =
    let message =
      Eio.Fiber.first
        (fun () -> Eio.Stream.take reports)
        (fun () ->
          Eio.Time.sleep clock 5.;
          failwith ("timed out waiting for " ^ expected))
    in
    if message = expected then ()
    else if String.starts_with ~prefix:"setup-error:" message then
      failwith message
    else loop ()
  in
  loop ()

let install_reporter ~sw window =
  let reports = Eio.Stream.create 64 in
  Webview_eio.bind ~sw window "__test_report" (fun ~id ~request ->
      let message =
        match Yojson.Safe.from_string request with
        | `List [ `String message ] -> message
        | _ -> "invalid-report"
      in
      Webview_eio.respond window ~id ~error:false ~result:"null";
      Eio.Stream.add reports message);
  reports

let () =
  Webview_eio.run
    ~setup:(fun webview -> Webview.set_title webview "Durable fast subscriber")
    (fun ~env ~sw primary ->
      let registry =
        App.Durable_session.create ~sw
          ~now:(fun () -> Eio.Time.now env#clock)
          ~persistence:(App.Durable_session.Persistence.memory ())
          ()
      in
      let begin_events, release_events = Eio.Promise.create () in
      let session =
        match
          App.Durable_session.start registry endpoint () (fun session () ->
              Eio.Promise.await begin_events;
              for event = 1 to 20 do
                match App.Durable_session.Session.emit session event with
                | Ok () -> ()
                | Error error -> failwith error.message
              done;
              ignore (App.Durable_session.Session.finish session "done"))
        with
        | Ok session -> session
        | Error error -> failwith error.message
      in
      let session_id = App.Durable_session.Session.id session in
      let primary_reports = install_reporter ~sw primary in
      let primary_transport =
        App.Transport.create ~sw
          ~now:(fun () -> Eio.Time.now env#clock)
          ~sleep:(Eio.Time.sleep env#clock) primary
      in
      ignore
        (App.Durable_session.connect ~event_capacity:64 registry
           primary_transport);
      Webview_eio.set_html primary (page ~name:"primary" ~session_id);

      let child_ready, resolve_child_ready = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run ~name:"slow-subscriber-window" @@ fun child_sw ->
          let child =
            Webview_eio.create_window ~sw:child_sw primary
              ~setup:(fun webview ->
                Webview.set_title webview "Durable slow subscriber")
          in
          let reports = install_reporter ~sw:child_sw child in
          let transport =
            App.Transport.create ~sw:child_sw
              ~now:(fun () -> Eio.Time.now env#clock)
              ~sleep:(Eio.Time.sleep env#clock) child
          in
          ignore
            (App.Durable_session.connect ~event_capacity:1
               ~event_byte_capacity:1024 ~flush_interval:1. registry transport);
          Webview_eio.set_html child (page ~name:"slow" ~session_id);
          Eio.Promise.resolve resolve_child_ready (child, reports);
          Webview_eio.await_closed child);
      let child, child_reports = Eio.Promise.await child_ready in
      await_message env#clock primary_reports "attached";
      await_message env#clock child_reports "attached";
      let started_at = Eio.Time.now env#clock in
      Eio.Promise.resolve release_events ();
      await_message env#clock primary_reports "events:20";
      await_message env#clock primary_reports "finished:done";
      let elapsed = Eio.Time.now env#clock -. started_at in
      if elapsed >= 0.8 then
        failwith
          "a slow durable subscriber delayed the independent primary delivery";
      if Webview_eio.is_closed child then
        failwith "detaching a slow subscriber closed its native window";
      Webview_eio.close child;
      Webview_eio.await_closed child;
      Webview_eio.close primary;
      Webview_eio.await_closed primary)
