let fail format = Printf.ksprintf failwith format
let phase = ref "startup"

let protect_test fn =
  try fn ()
  with Webview.Error error ->
    fail "phase %s raised %s" !phase
      (Format.asprintf "%a" Webview.pp_error error)

let expect_empty = function
  | [||] -> ()
  | paths -> fail "cancelled dialog returned %d paths" (Array.length paths)

let () =
  Printexc.record_backtrace true;
  protect_test @@ fun () ->
  if Webview.platform_backend () = Webview.Cocoa_webkit then
    Webview_eio.run
      ~setup:(fun webview ->
        Webview.set_title webview "Owebview asynchronous dialog test";
        Webview.set_html webview "<p>Asynchronous dialog lifecycle test</p>")
      (fun ~env ~sw app ->
        let first_result, resolve_first =
          Eio.Promise.create ~label:"dialog.first" ()
        in
        let first_completions = Atomic.make 0 in
        Webview_eio.call_ui app (fun webview ->
            Webview.dialog_async webview Webview.Message ~title:"First dialog"
              ~detail:"This dialog is cancelled by the test." (fun outcome ->
                ignore (Atomic.fetch_and_add first_completions 1);
                ignore (Eio.Promise.try_resolve resolve_first outcome)));
        Eio.Time.sleep env#clock 0.2;

        phase := "duplicate rejection";
        (match
           Webview_eio.dialog app Webview.Message ~title:"Duplicate dialog"
             ~detail:"This request must be rejected."
         with
        | _ -> fail "a second dialog was accepted while the first was active"
        | exception Webview.Error { code = Duplicate; _ } -> ());

        phase := "explicit cancellation";
        Webview_eio.call_ui app (fun webview ->
            Webview.cancel_dialog webview;
            Webview.cancel_dialog webview);
        (match Eio.Promise.await first_result with
        | Result.Ok paths -> expect_empty paths
        | Result.Error error -> raise (Webview.Error error));
        Eio.Time.sleep env#clock 0.2;
        if Atomic.get first_completions <> 1 then
          fail "cancelled dialog completed %d times"
            (Atomic.get first_completions);

        phase := "fiber cancellation";
        let timeout_cancelled =
          Eio.Fiber.first
            (fun () ->
              ignore
                (Webview_eio.dialog app Webview.Message
                   ~title:"Fiber cancellation"
                   ~detail:"The losing fiber must dismiss this sheet.");
              false)
            (fun () ->
              Eio.Time.sleep env#clock 0.2;
              true)
        in
        if not timeout_cancelled then
          fail "dialog unexpectedly completed before cancellation";

        Eio.Time.sleep env#clock 0.4;
        phase := "repeated dialog";
        let repeated_cancelled =
          Eio.Fiber.first
            (fun () ->
              ignore
                (Webview_eio.dialog app Webview.Message ~title:"Repeated dialog"
                   ~detail:"A new dialog must work after cancellation.");
              false)
            (fun () ->
              Eio.Time.sleep env#clock 0.2;
              true)
        in
        if not repeated_cancelled then
          fail "repeated dialog unexpectedly completed before cancellation";
        Eio.Time.sleep env#clock 0.4;

        let close_result, resolve_close =
          Eio.Promise.create ~label:"dialog.close" ()
        in
        phase := "window close";
        Eio.Fiber.fork ~sw (fun () ->
            let closed =
              match
                Webview_eio.dialog app Webview.Message
                  ~title:"Window close cancellation"
                  ~detail:"Closing the parent must settle this dialog."
              with
              | _ -> false
              | exception Webview.Error { code = Closed | Closing; _ } -> true
              | exception Webview_eio.Window_closed -> true
            in
            ignore (Eio.Promise.try_resolve resolve_close closed));
        Eio.Time.sleep env#clock 0.2;
        Webview_eio.close app;
        let close_settled =
          Eio.Fiber.first
            (fun () -> Eio.Promise.await close_result)
            (fun () ->
              Eio.Time.sleep env#clock 2.0;
              false)
        in
        if not close_settled then
          fail "closing the window did not settle its active native dialog";
        Webview_eio.await_closed app)
