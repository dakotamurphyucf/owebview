let () =
  let webview = Webview.create () in
  Webview.bind webview "done" (fun id _request ->
      Webview.return webview id ~error:false ~result:"null";
      Webview.terminate webview);
  Gc.full_major ();
  Gc.compact ();
  Webview.set_html webview
    {|
      <script>
        window.addEventListener('DOMContentLoaded', () => done());
      </script>
    |};
  Webview.run webview;
  Webview.destroy webview
