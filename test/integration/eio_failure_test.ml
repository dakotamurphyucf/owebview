exception Expected of string

let expect_expected label f =
  match f () with
  | () -> failwith (label ^ ": expected an exception")
  | exception Expected actual when actual = label -> ()
  | exception exn ->
      failwith (label ^ ": unexpected exception: " ^ Printexc.to_string exn)

let () =
  expect_expected "setup" (fun () ->
      Webview_eio.run
        ~setup:(fun _ -> raise (Expected "setup"))
        (fun ~env:_ ~sw:_ _ -> ()));

  expect_expected "application" (fun () ->
      Webview_eio.run
        ~setup:(fun webview ->
          Webview.set_html webview "<p>application failure</p>")
        (fun ~env:_ ~sw:_ _ -> raise (Expected "application")));

  Webview_eio.run
    ~setup:(fun webview -> Webview.set_html webview "<p>UI exception</p>")
    (fun ~env:_ ~sw:_ app ->
      expect_expected "call_ui" (fun () ->
          Webview_eio.call_ui app (fun _ -> raise (Expected "call_ui")));
      Webview_eio.close app);

  Webview_eio.run
    ~setup:(fun webview -> Webview.set_html webview "<p>close race</p>")
    (fun ~env:_ ~sw:_ app ->
      Eio.Fiber.both
        (fun () -> Webview_eio.close app)
        (fun () ->
          match Webview_eio.call_ui app (fun _ -> ()) with
          | () -> ()
          | exception
              Webview.Error { code = Closed | Closing | Invalid_state; _ } ->
              ()))
