let heartbeat_page =
  {|
    <script>
      window.addEventListener('DOMContentLoaded', async () => {
        const calls = [];
        for (let i = 0; i < 50; i++) calls.push(heartbeat(i));
        await Promise.all(calls);
        await heartbeat_done();
      });
    </script>
  |}

let overflow_page =
  {|
    <script>
      window.addEventListener('DOMContentLoaded', () => {
        for (let i = 0; i < 100; i++) blocked(i).catch(() => overflow_seen());
      });
    </script>
  |}

let () =
  let heartbeats = Atomic.make 0 in
  let long_operation_completed = Atomic.make false in
  Webview_eio.run
    ~setup:(fun webview -> Webview.set_html webview heartbeat_page)
    (fun ~env ~sw app ->
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Time.sleep env#clock 5.;
          Atomic.set long_operation_completed true);
      Webview_eio.bind ~capacity:64 ~concurrency:8 ~sw app "heartbeat"
        (fun ~id ~request:_ ->
          ignore (Atomic.fetch_and_add heartbeats 1);
          Webview_eio.respond app ~id ~error:false ~result:"null");
      Webview_eio.bind ~sw app "heartbeat_done" (fun ~id ~request:_ ->
          Webview_eio.respond app ~id ~error:false ~result:"null";
          if Atomic.get long_operation_completed then
            failwith "long operation completed before heartbeat traffic";
          Webview_eio.close app);
      Webview_eio.await_closed app);
  if Atomic.get heartbeats <> 50 then
    failwith
      (Printf.sprintf "received only %d/50 heartbeats" (Atomic.get heartbeats));

  let overflow_observed = Atomic.make false in
  Webview_eio.run
    ~setup:(fun webview -> Webview.set_html webview overflow_page)
    (fun ~env:_ ~sw app ->
      let never, _resolve_never = Eio.Promise.create () in
      Webview_eio.bind ~capacity:2 ~concurrency:1 ~sw app "blocked"
        (fun ~id:_ ~request:_ -> Eio.Promise.await never);
      Webview_eio.bind ~sw app "overflow_seen" (fun ~id ~request:_ ->
          Atomic.set overflow_observed true;
          Webview_eio.respond app ~id ~error:false ~result:"null";
          Webview_eio.close app);
      Webview_eio.await_closed app);
  if not (Atomic.get overflow_observed) then
    failwith "bounded request queue did not reject frontend overload"
