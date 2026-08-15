let await_with_timeout clock seconds window message =
  Eio.Fiber.first
    (fun () -> Webview_eio.await_closed window)
    (fun () ->
      Eio.Time.sleep clock seconds;
      failwith message)

let create_child ~sw parent title =
  Webview_eio.create_window ~sw parent ~setup:(fun webview ->
      Webview.set_title webview title;
      Webview.set_size webview ~width:360 ~height:240 Webview.Hint_none;
      Webview.set_html webview ("<title>" ^ title ^ "</title><p>secondary</p>"))

let () =
  Webview_eio.run
    ~setup:(fun webview ->
      Webview.set_title webview "Owebview multi-window test";
      Webview.set_html webview "<title>Primary</title><p>primary</p>")
    (fun ~env ~sw primary ->
      let allow_close = Atomic.make false in
      let child = create_child ~sw primary "Intercepted child" in
      let observed_theme = Atomic.make false in
      Owebview_app.Desktop.Theme.subscribe ~sw ~clock:env#clock child (fun _ ->
          Atomic.set observed_theme true);
      if not (Atomic.get observed_theme) then
        failwith "native theme subscription did not publish its initial value";
      Webview_eio.set_close_handler child (fun () -> Atomic.get allow_close);
      Webview_eio.close child;
      Eio.Time.sleep env#clock 0.1;
      if Webview_eio.is_closed child then
        failwith "secondary window ignored close interception";
      Atomic.set allow_close true;
      Webview_eio.close child;
      await_with_timeout env#clock 5.0 child
        "secondary window did not close after interception allowed it";
      if Webview_eio.is_closed primary then
        failwith "closing a secondary window closed the primary window";

      let child =
        Eio.Switch.run ~name:"owebview.secondary-window" @@ fun child_sw ->
        let child = create_child ~sw:child_sw primary "Switch-owned child" in
        Webview_eio.hide child;
        Webview_eio.show child;
        Webview_eio.focus child;
        ignore (Webview_eio.system_theme child);
        ignore (Webview_eio.current_url child);
        child
      in
      await_with_timeout env#clock 5.0 child
        "switch-owned secondary window did not close on switch release";
      if Webview_eio.is_closed primary then
        failwith "releasing a child switch closed the primary window";
      Webview_eio.set_title primary "Primary survived secondary teardown";
      Webview_eio.close primary;
      Webview_eio.await_closed primary)
