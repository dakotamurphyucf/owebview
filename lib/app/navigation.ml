type external_urls = Reject | Open_system

type policy = {
  trusted_origins : string list;
  external_urls : external_urls;
  allow_about_blank : bool;
}

let normalize_origin origin =
  let uri = Uri.of_string origin in
  match (Uri.scheme uri, Uri.host uri) with
  | Some scheme, Some host ->
      let port =
        match Uri.port uri with
        | None -> ""
        | Some port -> ":" ^ string_of_int port
      in
      String.lowercase_ascii scheme ^ "://" ^ String.lowercase_ascii host ^ port
  | Some "about", _ -> "about:blank"
  | Some scheme, _ -> String.lowercase_ascii scheme ^ ":"
  | None, _ -> ""

let default ~trusted_origins ?(external_urls = Open_system)
    ?(allow_about_blank = true) () =
  {
    trusted_origins = List.map normalize_origin trusted_origins;
    external_urls;
    allow_about_blank;
  }

let trusted_origins policy = policy.trusted_origins
let origin url = try normalize_origin url with _ -> ""

let is_trusted policy url =
  let origin = origin url in
  List.mem origin policy.trusted_origins
  || (policy.allow_about_blank && (origin = "" || origin = "about:blank"))

let decide policy url =
  if is_trusted policy url then Webview.Allow
  else
    match Uri.scheme (Uri.of_string url) with
    | Some ("http" | "https") -> (
        match policy.external_urls with
        | Reject -> Webview.Reject
        | Open_system -> Webview.Open_external)
    | _ -> Webview.Reject

let install window policy =
  Webview_eio.set_navigation_handler window (decide policy)
