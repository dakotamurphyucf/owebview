let dispatch_stress () =
  let webview = Webview.create () in
  Webview.set_html webview "<p>dispatch stress</p>";
  let workers = 4 in
  let per_worker = 250 in
  let expected = workers * per_worker in
  let completed = Atomic.make 0 in
  let domains =
    List.init workers (fun _ ->
        Domain.spawn (fun () ->
            Thread.delay 0.05;
            for _ = 1 to per_worker do
              Webview.dispatch webview (fun webview ->
                  let previous = Atomic.fetch_and_add completed 1 in
                  if previous + 1 = expected then Webview.terminate webview)
            done))
  in
  Webview.run webview;
  List.iter Domain.join domains;
  if Atomic.get completed <> expected then
    failwith
      (Printf.sprintf "only %d/%d dispatch callbacks completed"
         (Atomic.get completed) expected);
  Webview.destroy webview

let lifecycle_stress () =
  for _iteration = 1 to 12 do
    let webview = Webview.create () in
    Webview.set_html webview "<p>lifecycle stress</p>";
    let closer =
      Thread.create
        (fun () ->
          Thread.delay 0.01;
          Webview.terminate webview)
        ()
    in
    Webview.run webview;
    Thread.join closer;
    Webview.destroy webview;
    Webview.destroy webview;
    Gc.full_major ()
  done

let bind_unbind_stress () =
  let webview = Webview.create () in
  let called = Atomic.make 0 in
  Webview.bind webview "once" (fun id _request ->
      ignore (Atomic.fetch_and_add called 1);
      Webview.unbind webview "once";
      Webview.return webview id ~error:false ~result:"null";
      Webview.terminate webview);
  Webview.set_html webview
    {|
      <script>
        window.addEventListener('DOMContentLoaded', () => once());
      </script>
    |};
  Webview.run webview;
  Webview.destroy webview;
  if Atomic.get called <> 1 then
    failwith "bind/unbind callback count was not one"

let () =
  dispatch_stress ();
  lifecycle_stress ();
  bind_unbind_stress ()
