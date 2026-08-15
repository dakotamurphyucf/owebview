type mode = Production | Development
type entry = { path : string; mime : string; content : string; hash : string }
type bundle = { entries : (string, entry) Hashtbl.t }

let normalize_path path =
  let path = Uri.pct_decode path in
  let segments =
    String.split_on_char '/' path
    |> List.filter (fun segment -> segment <> "" && segment <> ".")
  in
  if
    List.exists
      (fun segment ->
        segment = ".."
        || String.contains segment '\000'
        || String.contains segment '\\')
      segments
  then Error "unsafe asset path"
  else Ok (String.concat "/" segments)

let mime path =
  match Magic_mime.lookup path with
  | "" -> "application/octet-stream"
  | value -> value

let make_entry path content =
  {
    path;
    mime = mime path;
    content;
    hash = Digest.to_hex (Digest.string content);
  }

let bundle files =
  let entries = Hashtbl.create (max 16 (List.length files)) in
  List.iter
    (fun (path, content) ->
      match normalize_path path with
      | Error message -> invalid_arg ("Assets.bundle: " ^ message)
      | Ok "" -> invalid_arg "Assets.bundle: asset path must not be empty"
      | Ok path ->
          if Hashtbl.mem entries path then
            invalid_arg ("Assets.bundle: duplicate asset: " ^ path);
          Hashtbl.add entries path (make_entry path content))
    files;
  { entries }

let entries bundle =
  Hashtbl.fold (fun _ entry result -> entry :: result) bundle.entries []

type source =
  | Directory : 'a Eio.Path.t -> source
  | Embedded of bundle
  | Development_server of Uri.t

type served = {
  token : string;
  origin : string;
  source : source;
  mode : mode;
  index : string;
  csp : string;
}

type t = Served of served | Remote of { origin : string; base : Uri.t }

let default_csp =
  "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors \
   'none'; "
  ^ "form-action 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
  ^ "img-src 'self' data:; connect-src 'self'"

let random_token mode =
  let bytes = Bytes.create 24 in
  let filled =
    try
      let channel = open_in_bin "/dev/urandom" in
      Fun.protect
        (fun () -> really_input channel bytes 0 (Bytes.length bytes))
        ~finally:(fun () -> close_in channel);
      true
    with _ -> false
  in
  (if not filled then
     match mode with
     | Production ->
         failwith "Assets.start: secure random bytes are unavailable"
     | Development ->
         Random.self_init ();
         for index = 0 to Bytes.length bytes - 1 do
           Bytes.set bytes index (Char.chr (Random.int 256))
         done);
  let buffer = Buffer.create (Bytes.length bytes * 2) in
  Bytes.iter
    (fun byte ->
      Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte)))
    bytes;
  Buffer.contents buffer

let origin_of_uri uri =
  match (Uri.scheme uri, Uri.host uri) with
  | Some scheme, Some host ->
      let port =
        match Uri.port uri with
        | None -> ""
        | Some port -> ":" ^ string_of_int port
      in
      scheme ^ "://" ^ host ^ port
  | _ ->
      invalid_arg "Assets.Development_server requires an absolute HTTP(S) URI"

let inject_reload served content =
  content
  ^ Printf.sprintf {|<script src="/%s/__owebview/reload.js"></script>|}
      served.token

let rec directory_revision path prefix digest =
  Eio.Path.read_dir path
  |> List.fold_left
       (fun digest name ->
         let child = Eio.Path.(path / name) in
         let relative = if prefix = "" then name else prefix ^ "/" ^ name in
         match Eio.Path.kind ~follow:false child with
         | `Directory -> directory_revision child relative digest
         | `Regular_file ->
             let stat = Eio.Path.stat ~follow:true child in
             Digest.string
               (Digest.to_hex digest ^ relative ^ string_of_float stat.mtime
               ^ Optint.Int63.to_string stat.size)
         | _ -> digest)
       digest

let revision = function
  | Embedded bundle ->
      entries bundle
      |> List.sort (fun left right -> String.compare left.path right.path)
      |> List.fold_left
           (fun digest entry ->
             Digest.string (Digest.to_hex digest ^ entry.path ^ entry.hash))
           (Digest.string "")
      |> Digest.to_hex
  | Directory path ->
      directory_revision path "" (Digest.string "") |> Digest.to_hex
  | Development_server _ -> "remote"

let find_entry source path =
  match source with
  | Embedded bundle -> Hashtbl.find_opt bundle.entries path
  | Directory root -> (
      let rec find current = function
        | [] -> None
        | [ name ] ->
            let child = Eio.Path.(current / name) in
            if Eio.Path.kind ~follow:false child = `Regular_file then Some child
            else None
        | name :: rest ->
            let child = Eio.Path.(current / name) in
            if Eio.Path.kind ~follow:false child = `Directory then
              find child rest
            else None
      in
      match find root (String.split_on_char '/' path) with
      | Some asset -> Some (make_entry path (Eio.Path.load asset))
      | None -> None
      | exception (Eio.Io _ | Unix.Unix_error _) -> None)
  | Development_server _ -> None

let headers served entry =
  let cache =
    match (served.mode, String.ends_with ~suffix:".html" entry.path) with
    | Development, _ | Production, true -> "no-store"
    | Production, false -> "public, max-age=31536000, immutable"
  in
  Cohttp.Header.init () |> fun headers ->
  Cohttp.Header.add headers "content-type" entry.mime |> fun headers ->
  Cohttp.Header.add headers "content-security-policy" served.csp
  |> fun headers ->
  Cohttp.Header.add headers "x-content-type-options" "nosniff" |> fun headers ->
  Cohttp.Header.add headers "cross-origin-resource-policy" "same-origin"
  |> fun headers ->
  Cohttp.Header.add headers "referrer-policy" "no-referrer" |> fun headers ->
  Cohttp.Header.add headers "cache-control" cache |> fun headers ->
  Cohttp.Header.add headers "etag" ("\"" ^ entry.hash ^ "\"")

let reload_script served =
  Printf.sprintf
    {|(function(){globalThis.__owebviewDevelopmentReload=true;let revision=null;async function poll(){try{const r=await fetch('/%s/__owebview/revision',{cache:'no-store'});const n=await r.text();if(revision===null)revision=n;else if(revision!==n)location.reload();}catch(_){ }setTimeout(poll,500);}poll();})();|}
    served.token

let response served request =
  let path = Uri.path (Cohttp.Request.uri request) in
  let prefix = "/" ^ served.token ^ "/" in
  if not (String.starts_with ~prefix path) then
    Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"not found" ()
  else
    let relative =
      String.sub path (String.length prefix)
        (String.length path - String.length prefix)
    in
    if relative = "__owebview/revision" then
      Cohttp_eio.Server.respond_string
        ~headers:(Cohttp.Header.init_with "cache-control" "no-store")
        ~status:`OK ~body:(revision served.source) ()
    else if relative = "__owebview/reload.js" && served.mode = Development then
      Cohttp_eio.Server.respond_string
        ~headers:
          (Cohttp.Header.of_list
             [
               ("content-type", "text/javascript; charset=utf-8");
               ("cache-control", "no-store");
               ("x-content-type-options", "nosniff");
             ])
        ~status:`OK ~body:(reload_script served) ()
    else
      match
        normalize_path (if relative = "" then served.index else relative)
      with
      | Error _ ->
          Cohttp_eio.Server.respond_string ~status:`Forbidden ~body:"forbidden"
            ()
      | Ok path -> (
          match find_entry served.source path with
          | None ->
              Cohttp_eio.Server.respond_string ~status:`Not_found
                ~body:"not found" ()
          | Some entry ->
              let entry =
                if served.mode = Development && entry.mime = "text/html" then
                  make_entry entry.path (inject_reload served entry.content)
                else entry
              in
              let response_headers = headers served entry in
              let etag = Cohttp.Header.get response_headers "etag" in
              if
                Option.equal String.equal etag
                  (Cohttp.Header.get
                     (Cohttp.Request.headers request)
                     "if-none-match")
              then
                Cohttp_eio.Server.respond_string ~headers:response_headers
                  ~status:`Not_modified ~body:"" ()
              else
                Cohttp_eio.Server.respond_string ~headers:response_headers
                  ~status:`OK ~body:entry.content ())

let start ~sw ~net ?(mode = Production) ?(index = "index.html")
    ?(content_security_policy = default_csp) source =
  match source with
  | Development_server base -> Remote { origin = origin_of_uri base; base }
  | (Directory _ | Embedded _) as source ->
      let token = random_token mode in
      let socket =
        Eio.Net.listen ~sw ~reuse_addr:true ~backlog:32 net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
      in
      let port =
        match Eio.Net.listening_addr socket with
        | `Tcp (_, port) -> port
        | `Unix _ -> assert false
      in
      let origin = Printf.sprintf "http://127.0.0.1:%d" port in
      let served =
        { token; origin; source; mode; index; csp = content_security_policy }
      in
      let server =
        Cohttp_eio.Server.make
          ~callback:(fun _ request _body -> response served request)
          ()
      in
      Eio.Fiber.fork ~sw (fun () ->
          Cohttp_eio.Server.run socket server ~on_error:(fun exn ->
              prerr_endline ("owebview asset server: " ^ Printexc.to_string exn)));
      Served served

let mode = function Served served -> served.mode | Remote _ -> Development

let origin = function
  | Served served -> served.origin
  | Remote remote -> remote.origin

let trusted_origins assets = [ origin assets ]

let url assets path =
  match assets with
  | Served served ->
      let path =
        match normalize_path path with
        | Ok path -> path
        | Error message -> invalid_arg message
      in
      served.origin ^ "/" ^ served.token ^ "/" ^ path
  | Remote remote ->
      Uri.resolve "" remote.base (Uri.of_string path) |> Uri.to_string

let index_url assets =
  match assets with
  | Served served -> url assets served.index
  | Remote remote -> Uri.to_string remote.base

let navigation_policy ?external_urls assets =
  Navigation.default ~trusted_origins:(trusted_origins assets) ?external_urls ()

let load window assets =
  Navigation.install window (navigation_policy assets);
  Webview_eio.navigate window (index_url assets)
