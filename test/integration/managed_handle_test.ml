let expect_code expected f =
  match f () with
  | () -> failwith "expected Webview.Error"
  | exception Webview.Error error when error.code = expected -> ()
  | exception Webview.Error error ->
      failwith
        (Format.asprintf "expected another error, received %a" Webview.pp_error
           error)

let () =
  let webview = Webview.create () in
  Domain.join
    (Domain.spawn (fun () ->
         expect_code Webview.Wrong_thread (fun () ->
             Webview.set_title webview "wrong Domain")));
  ignore
    (Thread.create
       (fun () ->
         Thread.delay 0.05;
         Webview.terminate webview)
       ());
  Webview.run webview;
  Webview.destroy webview;
  Webview.destroy webview;
  if not (Webview.is_closed webview) then
    failwith "destroyed handle is not closed";
  expect_code Webview.Closed (fun () ->
      Webview.set_title webview "closed handle");

  let callback_test = Webview.create () in
  Webview.bind callback_test "done" (fun id _request ->
      Webview.return callback_test id ~error:false ~result:"null";
      Webview.terminate callback_test);
  Webview.bind callback_test "boom" (fun _id _request -> raise Exit);
  Gc.full_major ();
  Gc.compact ();
  Webview.set_html callback_test
    {|
      <script>
        window.addEventListener('DOMContentLoaded', () => {
          boom().catch(() => done());
        });
      </script>
    |};
  Webview.run callback_test;
  Webview.destroy callback_test
