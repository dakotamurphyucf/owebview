module App = Owebview_app
module Protocol = Owebview_protocol

let ready_envelope build_id =
  Protocol.Envelope.make ~kind:"ready"
    (`Assoc
       [
         ("protocol_version", `Int Protocol.Envelope.current_version);
         ("frontend_build_id", `String build_id);
         ("application_version", `Null);
         ("capabilities", `List [ `String "rpc"; `String "streams" ]);
       ])
  |> Protocol.Envelope.to_string
  |> fun encoded -> Protocol.Json.to_string (`String encoded)

let page =
  "<!doctype html><meta charset=utf-8><title>Security test</title>"
  ^ "<script src=app.js defer></script>"

let trusted_script =
  "void globalThis.__owebview_native("
  ^ ready_envelope "trusted-assets"
  ^ ").catch(() => {});"

let untrusted_script =
  "(async()=>{let result='accepted';try{await globalThis.__owebview_native("
  ^ ready_envelope "untrusted-assets"
  ^ ");}catch(_){result='rejected';}await \
     globalThis.__test_report(result);})();"

let development_script =
  "setTimeout(()=>globalThis.__test_report("
  ^ "globalThis.__owebviewDevelopmentReload?'development-ready':'development-missing'"
  ^ "),50);"

let await_with_timeout clock seconds promise message =
  Eio.Fiber.first
    (fun () -> Eio.Promise.await promise)
    (fun () ->
      Eio.Time.sleep clock seconds;
      failwith message)

let () =
  Webview_eio.run
    ~setup:(fun webview ->
      Webview.set_title webview "Owebview asset security test")
    (fun ~env ~sw window ->
      let trusted_assets =
        App.Assets.start ~sw ~net:env#net
          (App.Assets.Embedded
             (App.Assets.bundle
                [ ("index.html", page); ("app.js", trusted_script) ]))
      in
      let untrusted_assets =
        App.Assets.start ~sw ~net:env#net
          (App.Assets.Embedded
             (App.Assets.bundle
                [ ("index.html", page); ("app.js", untrusted_script) ]))
      in
      let development_assets =
        App.Assets.start ~sw ~net:env#net ~mode:Development
          (App.Assets.Embedded
             (App.Assets.bundle
                [ ("index.html", page); ("app.js", development_script) ]))
      in
      let navigation =
        App.Navigation.default
          ~trusted_origins:
            [
              App.Assets.origin trusted_assets;
              App.Assets.origin untrusted_assets;
              App.Assets.origin development_assets;
            ]
          ~external_urls:Reject ()
      in
      App.Navigation.install window navigation;
      let reports = Eio.Stream.create 4 in
      Webview_eio.bind_with_url ~sw window "__test_report"
        (fun ~id ~request ~url:_ ->
          let outcome =
            match Yojson.Safe.from_string request with
            | `List [ `String value ] -> value
            | _ -> "invalid"
          in
          Webview_eio.respond window ~id ~error:false ~result:"null";
          Eio.Stream.add reports outcome);
      let transport =
        App.Transport.create ~sw
          ~trusted_origins:(App.Assets.trusted_origins trusted_assets)
          ~now:(fun () -> Eio.Time.now env#clock)
          ~sleep:(Eio.Time.sleep env#clock) window
      in
      Webview_eio.navigate window (App.Assets.index_url trusted_assets);
      await_with_timeout env#clock 5.0
        (let ready, resolve = Eio.Promise.create () in
         Eio.Fiber.fork ~sw (fun () ->
             App.Transport.await_ready transport;
             Eio.Promise.resolve resolve ());
         ready)
        "trusted embedded frontend did not become ready";
      Webview_eio.navigate window (App.Assets.index_url untrusted_assets);
      let outcome =
        await_with_timeout env#clock 5.0
          (let report, resolve = Eio.Promise.create () in
           Eio.Fiber.fork ~sw (fun () ->
               Eio.Promise.resolve resolve (Eio.Stream.take reports));
           report)
          "untrusted frontend did not report its transport result"
      in
      if outcome <> "rejected" then
        failwith ("untrusted frontend reached native transport: " ^ outcome);
      Webview_eio.navigate window (App.Assets.index_url development_assets);
      let development =
        await_with_timeout env#clock 5.0
          (let report, resolve = Eio.Promise.create () in
           Eio.Fiber.fork ~sw (fun () ->
               Eio.Promise.resolve resolve (Eio.Stream.take reports));
           report)
          "development reload helper did not execute"
      in
      if development <> "development-ready" then
        failwith ("development asset mode failed: " ^ development);
      Webview_eio.close window;
      Webview_eio.await_closed window)
