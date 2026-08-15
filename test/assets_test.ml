module Assets = Owebview_app.Assets
module Navigation = Owebview_app.Navigation

let fail format = Printf.ksprintf failwith format

let expect_invalid_arg f =
  match f () with
  | exception Invalid_argument _ -> ()
  | exception exn ->
      fail "expected Invalid_argument, got %s" (Printexc.to_string exn)
  | _ -> fail "expected Invalid_argument"

let () =
  let backend = Owebview_app.Platform.backend () in
  if Owebview_app.Platform.string_of_backend backend = "" then
    fail "platform backend has no stable name";
  (match backend with
  | Cocoa_webkit ->
      if Owebview_app.Platform.validation () <> Validated then
        fail "the local Cocoa backend should be marked validated"
  | _ -> ());
  let bundle =
    Assets.bundle
      [
        ("index.html", "<!doctype html><title>Owebview</title>");
        ("assets/app.js", "console.log('ready')");
      ]
  in
  let entries = Assets.entries bundle in
  if List.length entries <> 2 then fail "expected two embedded assets";
  let index =
    List.find (fun entry -> entry.Assets.path = "index.html") entries
  in
  if index.mime <> "text/html" then
    fail "unexpected HTML MIME type: %s" index.mime;
  if index.hash <> Digest.to_hex (Digest.string index.content) then
    fail "embedded asset hash is not content-derived";
  expect_invalid_arg (fun () -> Assets.bundle [ ("../secret", "no") ]);
  expect_invalid_arg (fun () -> Assets.bundle [ ("%2e%2e/secret", "no") ]);
  expect_invalid_arg (fun () ->
      Assets.bundle [ ("app.js", "one"); ("./app.js", "two") ]);

  let reject_external =
    Navigation.default
      ~trusted_origins:[ "http://127.0.0.1:8123" ]
      ~external_urls:Reject ()
  in
  if
    Navigation.decide reject_external "http://127.0.0.1:8123/index.html"
    <> Webview.Allow
  then fail "trusted application navigation was rejected";
  if Navigation.decide reject_external "https://example.com" <> Webview.Reject
  then fail "external navigation was not rejected";
  if Navigation.decide reject_external "javascript:alert(1)" <> Webview.Reject
  then fail "unsafe URL scheme was not rejected";
  if Navigation.decide reject_external "about:blank" <> Webview.Allow then
    fail "about:blank should be allowed during bootstrap";

  let open_external =
    Navigation.default ~trusted_origins:[] ~external_urls:Open_system ()
  in
  if
    Navigation.decide open_external "https://example.com"
    <> Webview.Open_external
  then fail "external HTTP navigation was not delegated to the system"
