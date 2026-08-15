let fail format = Printf.ksprintf failwith format

let () =
  let version = Webview.version () in
  if version.major <> 0 || version.minor <> 12 then
    fail "unexpected vendored webview version: %s" version.version_number;
  if Webview.string_of_error_code Webview.Closed <> "closed" then
    fail "closed error code has an unstable textual representation";
  let error : Webview.error =
    {
      operation = "test";
      code = Webview.Wrong_thread;
      message = "wrong thread";
    }
  in
  let rendered = Format.asprintf "%a" Webview.pp_error error in
  if rendered <> "test: wrong_thread: wrong thread" then
    fail "unexpected rendered error: %S" rendered;
  let module Protocol = Owebview_protocol in
  let envelope =
    Protocol.Envelope.make ~id:"request-1" ~kind:"rpc.call"
      (`Assoc [ ("method", `String "test") ])
  in
  match Protocol.Envelope.of_string (Protocol.Envelope.to_string envelope) with
  | Error message -> fail "protocol envelope did not round-trip: %s" message
  | Ok decoded when decoded <> envelope ->
      fail "protocol envelope changed during round-trip"
  | Ok _ -> ()
