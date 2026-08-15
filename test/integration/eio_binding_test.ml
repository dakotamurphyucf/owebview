let page =
  {|
    <script>
      window.addEventListener('DOMContentLoaded', async () => {
        await eio_ready('request from the webview');
      });
    </script>
  |}

let () =
  Webview_eio.run
    ~setup:(fun webview -> Webview.set_title webview "Eio binding test")
    (fun ~env:_ ~sw app ->
      Webview_eio.bind ~sw app "eio_ready" (fun ~id ~request ->
          if request <> {|["request from the webview"]|} then
            failwith ("unexpected request: " ^ request);
          Webview_eio.respond app ~id ~error:false ~result:"null";
          Webview_eio.close app);
      Webview_eio.set_html app page;
      Webview_eio.await_closed app)
