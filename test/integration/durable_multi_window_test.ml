module App = Owebview_app
module Protocol = Owebview_protocol

let endpoint =
  Protocol.Stream_endpoint.make ~name:"test.shared-session"
    ~request:Protocol.Codec.unit ~event:Protocol.Codec.string
    ~command:Protocol.Codec.string ~result:Protocol.Codec.string

let encoded envelope =
  Protocol.Envelope.to_string envelope |> fun value ->
  Protocol.Json.to_string (`String value)

let ready name =
  Protocol.Envelope.make ~kind:"ready"
    (`Assoc
       [
         ("protocol_version", `Int Protocol.Envelope.current_version);
         ("frontend_build_id", `String name);
         ("application_version", `String "durable-multi-window-test");
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
  let command =
    Protocol.Envelope.make ~id:"shared-approval-command" ~kind:"stream.command"
      (`Assoc
         [ ("stream_id", `String session_id); ("command", `String "approve") ])
    |> encoded
  in
  let list_request =
    Protocol.Envelope.make ~kind:"session.list"
      (`Assoc [ ("subscriber_id", `String name) ])
    |> encoded
  in
  Printf.sprintf
    {|
<!doctype html><meta charset="utf-8"><title>%s</title>
<script>
(function () {
  const report = value => globalThis.__test_report(value);
  const subscriberId = %s;
  const streamId = %s;
  let commandSent = false;
  globalThis.__owebviewReceive = raw => {
    const envelope = JSON.parse(raw);
    if (envelope.kind === "stream.batch") {
      for (const item of envelope.payload.events) {
        const event = item.event;
        void report("event:" + event);
        const acknowledgement = JSON.stringify({
          version: 1,
          kind: "stream.ack",
          id: null,
          payload: {
            stream_id: streamId,
            subscriber_id: subscriberId,
            sequence: item.sequence
          }
        });
        void globalThis.__owebview_native(acknowledgement).then(
          () => globalThis.__owebview_native(acknowledgement));
        if (event === "one" && !commandSent) {
          commandSent = true;
          void globalThis.__owebview_native(%s).then(
            () => report("command-ack"),
            error => report("command-error:" + error));
        }
      }
    } else if (envelope.kind === "stream.finished") {
      void report("finished:" + envelope.payload.result);
    } else if (envelope.kind === "stream.failed") {
      void report("failed:" + envelope.payload.error.code);
    }
  };
  (async () => {
    await globalThis.__owebview_native(%s);
    await globalThis.__owebview_native(%s);
    await report("attached");
    const listed = await globalThis.__owebview_native(%s);
    await report("list-kind:" + JSON.parse(listed).kind);
  })().catch(error => report("setup-error:" + error));
})();
</script>
|}
    name
    (Yojson.Safe.to_string (`String name))
    (Yojson.Safe.to_string (`String session_id))
    command (ready name) resume list_request

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
    else if
      String.starts_with ~prefix:"setup-error:" message
      || String.starts_with ~prefix:"command-error:" message
      || String.starts_with ~prefix:"failed:" message
    then failwith message
    else loop ()
  in
  loop ()

let await_condition clock message condition =
  Eio.Fiber.first
    (let rec loop () =
       if condition () then ()
       else (
         Eio.Time.sleep clock 0.02;
         loop ())
     in
     loop)
    (fun () ->
      Eio.Time.sleep clock 5.;
      failwith message)

let install_reporter ~sw window =
  let reports = Eio.Stream.create 32 in
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
    ~setup:(fun webview -> Webview.set_title webview "Durable primary")
    (fun ~env ~sw primary ->
      let persisted = ref [] in
      let fail_next_acknowledgement = ref true in
      let persistence =
        App.Durable_session.Persistence.make
          ~load_all:(fun () -> !persisted)
          ~save:(fun record ->
            if
              !fail_next_acknowledgement
              && List.exists
                   (fun (ack : App.Durable_session.stored_acknowledgement) ->
                     Int64.compare ack.sequence 0L > 0)
                   record.acknowledgements
            then (
              fail_next_acknowledgement := false;
              failwith "simulated acknowledgement persistence failure");
            persisted :=
              record
              :: List.filter
                   (fun (existing : App.Durable_session.stored_session) ->
                     existing.id <> record.id)
                   !persisted)
          ~delete:(fun id ->
            persisted :=
              List.filter
                (fun (record : App.Durable_session.stored_session) ->
                  record.id <> id)
                !persisted)
      in
      let registry =
        App.Durable_session.create ~sw
          ~now:(fun () -> Eio.Time.now env#clock)
          ~persistence ()
      in
      let begin_events, release_events = Eio.Promise.create () in
      let finish_session, release_finish = Eio.Promise.create () in
      let command_count = Atomic.make 0 in
      let session =
        match
          App.Durable_session.start registry endpoint () (fun session () ->
              Eio.Promise.await begin_events;
              ignore (App.Durable_session.Session.emit session "one");
              let command =
                Eio.Stream.take (App.Durable_session.Session.commands session)
              in
              let admitted =
                List.find_opt
                  (fun (record : App.Durable_session.stored_session) ->
                    record.id = App.Durable_session.Session.id session)
                  !persisted
              in
              (match admitted with
              | Some
                  {
                    commands =
                      [
                        { id = "shared-approval-command"; status = Admitted; _ };
                      ];
                    _;
                  } ->
                  ()
              | _ ->
                  failwith
                    "command became application-visible before durable \
                     admission");
              Atomic.incr command_count;
              Eio.Time.sleep env#clock 0.1;
              if
                Eio.Stream.take_nonblocking
                  (App.Durable_session.Session.commands session)
                <> None
              then failwith "duplicate command was admitted twice";
              ignore
                (App.Durable_session.Session.emit session
                   ("command:" ^ command.value));
              ignore
                (App.Durable_session.Session.mark_command_applied session
                   command);
              Eio.Promise.await finish_session;
              ignore (App.Durable_session.Session.finish session "done"))
        with
        | Ok session -> session
        | Error error -> failwith error.message
      in
      let session_id = App.Durable_session.Session.id session in

      let primary_reports = install_reporter ~sw primary in
      let primary_transport =
        App.Transport.create ~sw
          ~on_error:(fun _ -> ())
          ~now:(fun () -> Eio.Time.now env#clock)
          ~sleep:(Eio.Time.sleep env#clock) primary
      in
      ignore (App.Durable_session.connect registry primary_transport);
      Webview_eio.set_html primary (page ~name:"primary" ~session_id);

      let child_ready, resolve_child_ready = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run ~name:"durable-child-window" @@ fun child_sw ->
          let child =
            Webview_eio.create_window ~sw:child_sw primary
              ~setup:(fun webview ->
                Webview.set_title webview "Durable inspector")
          in
          let reports = install_reporter ~sw:child_sw child in
          let transport =
            App.Transport.create ~sw:child_sw
              ~on_error:(fun _ -> ())
              ~now:(fun () -> Eio.Time.now env#clock)
              ~sleep:(Eio.Time.sleep env#clock) child
          in
          ignore
            (App.Durable_session.connect
               ~authorize:(fun ~subscriber_id action ->
                 match action with
                 | App.Durable_session.List_sessions ->
                     subscriber_id <> "inspector"
                 | _ -> true)
               registry transport);
          Webview_eio.set_html child (page ~name:"inspector" ~session_id);
          Eio.Promise.resolve resolve_child_ready (child, reports);
          Webview_eio.await_closed child);
      let child, child_reports = Eio.Promise.await child_ready in

      await_message env#clock primary_reports "attached";
      await_message env#clock child_reports "attached";
      await_message env#clock primary_reports "list-kind:session.list";
      await_message env#clock child_reports "list-kind:error";
      Eio.Promise.resolve release_events ();
      await_message env#clock primary_reports "event:one";
      await_message env#clock child_reports "event:one";
      await_message env#clock primary_reports "command-ack";
      await_message env#clock child_reports "command-ack";
      await_message env#clock primary_reports "event:command:approve";
      await_message env#clock child_reports "event:command:approve";
      if Atomic.get command_count <> 1 then
        failwith "shared command was not applied exactly once";

      Webview_eio.close child;
      Webview_eio.await_closed child;
      Eio.Promise.resolve release_finish ();
      await_message env#clock primary_reports "finished:done";
      let summary =
        match App.Durable_session.list registry with
        | [ summary ] -> summary
        | _ -> failwith "unexpected durable session registry contents"
      in
      if summary.lifecycle <> Completed then
        failwith "shared session did not complete after inspector closed";
      await_condition env#clock
        "subscriber acknowledgements did not recover after a failed durable \
         write" (fun () ->
          match
            List.find_opt
              (fun (record : App.Durable_session.stored_session) ->
                record.id = session_id)
              !persisted
          with
          | None -> false
          | Some record ->
              List.length record.acknowledgements = 2
              && List.for_all
                   (fun (ack : App.Durable_session.stored_acknowledgement) ->
                     ack.sequence = 2L)
                   record.acknowledgements);
      let stored =
        match
          List.find_opt
            (fun (record : App.Durable_session.stored_session) ->
              record.id = session_id)
            !persisted
        with
        | Some record -> record
        | None -> failwith "shared session was not persisted"
      in
      (match stored.commands with
      | [ { status = Applied; _ } ] -> ()
      | _ -> failwith "shared command did not reach one durable applied state");
      let subscriber_ids =
        List.sort_uniq String.compare
          (List.map
             (fun (ack : App.Durable_session.stored_acknowledgement) ->
               ack.subscriber_id)
             stored.acknowledgements)
      in
      if List.length subscriber_ids <> 2 then
        failwith "independent subscriber acknowledgements were not persisted";
      if
        not
          (List.for_all
             (fun (ack : App.Durable_session.stored_acknowledgement) ->
               ack.sequence = 2L)
             stored.acknowledgements)
      then
        failwith
          "an acknowledgement advanced in memory before persistence succeeded";
      Webview_eio.set_title primary "Durable session survived child close";
      Webview_eio.close primary;
      Webview_eio.await_closed primary)
