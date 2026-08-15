module App = Owebview_app

let index =
  {|
<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Owebview desktop</title>
    <link rel="stylesheet" href="app.css">
    <script src="app.js" defer></script>
  </head>
  <body>
    <main>
      <h1>OCaml desktop window</h1>
      <p id="status">The frontend is served from embedded application assets.</p>
      <div class="actions">
        <button data-action="new-window">New window</button>
        <button data-action="theme">System theme</button>
        <button data-action="message">Native dialog</button>
        <button data-action="close">Close window</button>
      </div>
    </main>
  </body>
</html>
|}

let css =
  {|
:root { color-scheme: light dark; font-family: system-ui, sans-serif; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
main { max-width: 42rem; padding: 2rem; }
.actions { display: flex; flex-wrap: wrap; gap: .75rem; }
button { font: inherit; padding: .6rem .9rem; }
|}

let javascript =
  {|
const status = document.querySelector("#status");
document.addEventListener("click", async event => {
  const action = event.target?.dataset?.action;
  if (!action) return;
  try {
    const result = await globalThis.desktop_action(action);
    if (typeof result === "string") status.textContent = result;
  } catch (error) {
    console.error(error);
    status.textContent = "Native action failed";
  }
});
console.info("desktop frontend ready", location.href);
|}

let decode_action request =
  match Yojson.Safe.from_string request with
  | `List [ `String action ] -> Some action
  | _ -> None
  | exception Yojson.Json_error _ -> None

let json_string value = Yojson.Safe.to_string (`String value)

let () =
  Webview_eio.run
    ~setup:(fun _ -> ())
    (fun ~env ~sw primary ->
      let assets =
        App.Assets.start ~sw ~net:env#net
          (Embedded
             (App.Assets.bundle
                [
                  ("index.html", index); ("app.css", css); ("app.js", javascript);
                ]))
      in
      let config =
        App.Window.config ~title:"Owebview desktop" ~width:760 ~height:500
          assets
      in
      let rec prepare window =
        App.Console.install ~sw ~trusted:(App.Assets.navigation_policy assets)
          window (fun message ->
            Printf.eprintf "frontend: %s\n%!" message.App.Console.text);
        Webview_eio.bind ~sw window "desktop_action" (fun ~id ~request ->
            match decode_action request with
            | Some "new-window" ->
                ignore
                  (App.Window.create ~sw ~before_load:prepare window config);
                Webview_eio.respond window ~id ~error:false
                  ~result:(json_string "Created another native window")
            | Some "theme" ->
                let theme =
                  match App.Desktop.Theme.current window with
                  | Light -> "System theme: light"
                  | Dark -> "System theme: dark"
                  | Unknown -> "System theme is unavailable"
                in
                Webview_eio.respond window ~id ~error:false
                  ~result:(json_string theme)
            | Some "message" ->
                App.Desktop.Dialog.message window ~title:"Native dialog"
                  ~message:"This dialog was opened by OCaml.";
                Webview_eio.respond window ~id ~error:false ~result:"null"
            | Some "close" ->
                Webview_eio.respond window ~id ~error:false ~result:"null";
                App.Window.close window
            | _ ->
                Webview_eio.respond window ~id ~error:true
                  ~result:
                    {|{"code":"unknown_action","message":"unknown desktop action"}|})
      in
      App.Window.configure primary config;
      prepare primary;
      Webview_eio.navigate primary (App.Assets.index_url assets);
      Webview_eio.await_closed primary)
