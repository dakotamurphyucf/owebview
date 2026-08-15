let child_cancelled = Atomic.make false

let () =
  Webview_eio.run
    ~setup:(fun webview ->
      Webview.set_title webview "Owebview lifecycle test";
      Webview.set_html webview "<p>Lifecycle test</p>")
    (fun ~env:_ ~sw app ->
      let started, resolve_started = Eio.Promise.create () in
      let never, _resolve_never = Eio.Promise.create () in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Promise.resolve resolve_started ();
          Fun.protect
            (fun () -> Eio.Promise.await never)
            ~finally:(fun () -> Atomic.set child_cancelled true));
      Eio.Promise.await started;
      Webview_eio.close app;
      Webview_eio.close app;
      Webview_eio.await_closed app);
  if not (Atomic.get child_cancelled) then
    failwith "window close did not cancel a window-scoped fiber"
