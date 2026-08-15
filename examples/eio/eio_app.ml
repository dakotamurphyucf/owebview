let html =
  {|
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <style>
      body { font-family: system-ui; padding: 2rem; }
      button { margin-right: .5rem; padding: .6rem 1rem; }
      #output { margin-top: 1rem; }
    </style>
  </head>
  <body>
    <h1>Owebview + Eio</h1>
    <button id="ping">Call OCaml</button>
    <button id="close">Close</button>
    <div id="output"></div>
    <script>
      const output = document.querySelector('#output');
      document.querySelector('#ping').onclick = async () => {
        output.textContent = await ocaml_ping('hello from js_of_ocaml-ready UI');
      };
      document.querySelector('#close').onclick = () => ocaml_close();
    </script>
  </body>
</html>
|}

let setup webview =
  Webview.set_title webview "Owebview Eio application";
  Webview.set_size webview ~width:640 ~height:420 Webview.Hint_none;
  Webview.set_html webview html

let application ~env:_ ~sw app =
  Webview_eio.bind ~sw app "ocaml_ping" (fun ~id ~request:_ ->
      Webview_eio.respond app ~id ~error:false
        ~result:{|"pong from an Eio fiber"|});
  Webview_eio.bind ~sw app "ocaml_close" (fun ~id ~request:_ ->
      Webview_eio.respond app ~id ~error:false ~result:"null";
      Webview_eio.close app);
  Webview_eio.await_closed app

let () = Webview_eio.run ~debug:true ~setup application
