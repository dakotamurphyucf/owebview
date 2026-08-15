module Protocol = Owebview_protocol

type subscription = { mutable active : bool; cancel : unit -> unit }

type frontend = {
  generation : int;
  protocol_version : int;
  frontend_build_id : string;
  application_version : string option;
  capabilities : string list;
}

type t = {
  app : Webview_eio.t;
  sw : Eio.Switch.t;
  now_fn : unit -> float;
  sleep_fn : float -> unit;
  handlers :
    ( string,
      Protocol.Envelope.t -> (Protocol.Envelope.t, Protocol.Rpc_error.t) result
    )
    Hashtbl.t;
  frontend_pending : (string, Protocol.Envelope.t Eio.Promise.u) Hashtbl.t;
  required_capabilities : string list;
  trusted_origins : string list;
  is_trusted_url : string -> bool;
  on_error : string -> unit;
  mutable ready_generation : int;
  mutable frontend : frontend option;
  mutable ready_waiters : unit Eio.Promise.u list;
  mutable next_identifier : int64;
}

let app t = t.app
let sw t = t.sw
let now t = t.now_fn ()
let sleep t = t.sleep_fn
let ready_generation t = t.ready_generation
let frontend t = t.frontend

let report_exception t ~context exn backtrace =
  let message =
    Printf.sprintf "%s: %s\n%s" context (Printexc.to_string exn)
      (Printexc.raw_backtrace_to_string backtrace)
  in
  try t.on_error message with _ -> ()

let frontend_error_response id error =
  Protocol.Envelope.make ~id ~kind:"frontend.response"
    (`Assoc
       [
         ("status", `String "error");
         ("error", Protocol.Codec.encode Protocol.Rpc_error.codec error);
       ])

let reject_pending_frontend_calls t error =
  Hashtbl.iter
    (fun id resolve ->
      ignore
        (Eio.Promise.try_resolve resolve (frontend_error_response id error)))
    t.frontend_pending;
  Hashtbl.clear t.frontend_pending

let rpc_error ?data ~code message = Protocol.Rpc_error.make ?data ~code message

let handler_key ~kind ~name =
  match name with None -> kind | Some name -> kind ^ ":" ^ name

let method_name envelope =
  match
    Protocol.Json.string_member "method" envelope.Protocol.Envelope.payload
  with
  | Ok name -> Some name
  | Error _ -> None

let response_error envelope error =
  Protocol.Envelope.make ?id:envelope.Protocol.Envelope.id ~kind:"error"
    (Protocol.Codec.encode Protocol.Rpc_error.codec error)

let encode_binding_response envelope =
  Protocol.Json.to_string (`String (Protocol.Envelope.to_string envelope))

let decode_binding_request request =
  match Protocol.Json.of_string request with
  | Ok (`List [ `String encoded ]) -> Protocol.Envelope.of_string encoded
  | Ok _ -> Error "native transport expects one encoded envelope argument"
  | Error _ as error -> error

let respond_if_open app ~id ~error ~result =
  try Webview_eio.respond app ~id ~error ~result
  with Webview.Error { code = Webview.Closed | Webview.Closing; _ } -> ()

let optional_string_member name = function
  | `Assoc fields -> (
      match List.assoc_opt name fields with
      | None | Some `Null -> Ok None
      | Some (`String value) -> Ok (Some value)
      | Some _ -> Error ("expected string member: " ^ name))
  | _ -> Error "expected a JSON object"

let origin_of_url url =
  if url = "" then ""
  else
    try
      let uri = Uri.of_string url in
      match (Uri.scheme uri, Uri.host uri) with
      | Some scheme, Some host ->
          let port =
            match Uri.port uri with
            | Some port -> ":" ^ string_of_int port
            | None -> ""
          in
          String.lowercase_ascii scheme
          ^ "://"
          ^ String.lowercase_ascii host
          ^ port
      | Some "about", _ -> "about:blank"
      | Some scheme, _ -> String.lowercase_ascii scheme ^ ":"
      | None, _ -> ""
    with _ -> ""

let trusted_url t url =
  let origin = origin_of_url url in
  List.mem origin t.trusted_origins || t.is_trusted_url url

let validate_ready t envelope =
  let payload = envelope.Protocol.Envelope.payload in
  match
    ( Protocol.Json.member "protocol_version" payload,
      Protocol.Json.string_member "frontend_build_id" payload,
      optional_string_member "application_version" payload,
      Protocol.Json.member "capabilities" payload )
  with
  | Error message, _, _, _
  | _, Error message, _, _
  | _, _, Error message, _
  | _, _, _, Error message ->
      Error (rpc_error ~code:"invalid_handshake" message)
  | ( Ok encoded_version,
      Ok frontend_build_id,
      Ok application_version,
      Ok encoded_capabilities ) -> (
      match
        ( Protocol.Codec.decode Protocol.Codec.int encoded_version,
          Protocol.Codec.decode
            (Protocol.Codec.list Protocol.Codec.string)
            encoded_capabilities )
      with
      | Error message, _ | _, Error message ->
          Error (rpc_error ~code:"invalid_handshake" message)
      | Ok protocol_version, Ok capabilities -> (
          if protocol_version <> Protocol.Envelope.current_version then
            Error
              (rpc_error ~code:"protocol_mismatch"
                 (Printf.sprintf
                    "frontend protocol version %d is incompatible with native \
                     version %d"
                    protocol_version Protocol.Envelope.current_version))
          else if frontend_build_id = "" then
            Error
              (rpc_error ~code:"invalid_handshake"
                 "frontend_build_id must not be empty")
          else
            match
              List.find_opt
                (fun capability -> not (List.mem capability capabilities))
                t.required_capabilities
            with
            | Some capability ->
                Error
                  (rpc_error ~code:"missing_capability"
                     ("frontend does not support required capability: "
                    ^ capability))
            | None ->
                let generation = t.ready_generation + 1 in
                Ok
                  {
                    generation;
                    protocol_version;
                    frontend_build_id;
                    application_version;
                    capabilities;
                  }))

let emit t envelope =
  if t.frontend = None then
    Error
      (rpc_error ~code:"frontend_not_ready"
         "the frontend handshake has not completed")
  else if Webview.is_closed (Webview_eio.webview t.app) then
    Error (rpc_error ~code:"window_closed" "the frontend window is closed")
  else
    let encoded = Protocol.Envelope.to_string envelope in
    let argument = Protocol.Json.to_string (`String encoded) in
    let script =
      "if (typeof globalThis.__owebviewReceive === 'function') "
      ^ "globalThis.__owebviewReceive(" ^ argument ^ ");"
    in
    try
      Webview_eio.eval t.app script;
      Ok ()
    with Webview.Error error ->
      Error
        (rpc_error ~code:"transport_error"
           (Format.asprintf "%a" Webview.pp_error error))

let route t envelope =
  match envelope.Protocol.Envelope.kind with
  | "ready" -> (
      match validate_ready t envelope with
      | Error _ as error -> error
      | Ok frontend ->
          reject_pending_frontend_calls t
            (rpc_error ~code:"frontend_reloaded"
               "the frontend reloaded before responding");
          t.ready_generation <- frontend.generation;
          t.frontend <- Some frontend;
          List.iter
            (fun resolve -> ignore (Eio.Promise.try_resolve resolve ()))
            t.ready_waiters;
          t.ready_waiters <- [];
          Ok
            (Protocol.Envelope.make ?id:envelope.id ~kind:"ready.ok"
               (`Assoc
                  [
                    ("generation", `Int t.ready_generation);
                    ("protocol_version", `Int Protocol.Envelope.current_version);
                  ])))
  | _ when t.frontend = None ->
      Error
        (rpc_error ~code:"frontend_not_ready"
           "the frontend handshake must complete before normal traffic")
  | "frontend.response" -> (
      match envelope.id with
      | Some id -> (
          match Hashtbl.find_opt t.frontend_pending id with
          | Some resolve ->
              Hashtbl.remove t.frontend_pending id;
              ignore (Eio.Promise.try_resolve resolve envelope);
              Ok (Protocol.Envelope.make ~id ~kind:"ack" `Null)
          | None ->
              Error
                (rpc_error ~code:"request_not_found"
                   "frontend request is no longer pending"))
      | None ->
          Error
            (rpc_error ~code:"invalid_envelope" "frontend response has no id"))
  | kind -> (
      let named_key = handler_key ~kind ~name:(method_name envelope) in
      let handler =
        match Hashtbl.find_opt t.handlers named_key with
        | Some handler -> Some handler
        | None -> Hashtbl.find_opt t.handlers kind
      in
      match handler with
      | Some handler -> handler envelope
      | None ->
          Error
            (rpc_error ~code:"method_not_found" ("no handler for " ^ named_key))
      )

let create ?(binding_capacity = 1024)
    ?(required_capabilities = [ "rpc"; "streams" ])
    ?(trusted_origins = [ ""; "about:blank" ])
    ?(is_trusted_url = fun _ -> false) ?(on_error = prerr_endline) ~sw ~now
    ~sleep app =
  let t =
    {
      app;
      sw;
      now_fn = now;
      sleep_fn = sleep;
      handlers = Hashtbl.create 32;
      frontend_pending = Hashtbl.create 16;
      required_capabilities;
      trusted_origins = List.map String.lowercase_ascii trusted_origins;
      is_trusted_url;
      on_error;
      ready_generation = 0;
      frontend = None;
      ready_waiters = [];
      next_identifier = 0L;
    }
  in
  Webview_eio.bind_with_url ~capacity:binding_capacity ~sw app
    "__owebview_native" (fun ~id ~request ~url ->
      if not (trusted_url t url) then
        respond_if_open app ~id ~error:true
          ~result:
            {|{"code":"untrusted_origin","message":"native transport is unavailable for this page"}|}
      else
        let response =
          match decode_binding_request request with
          | Error message ->
              Protocol.Envelope.make ~kind:"error"
                (Protocol.Codec.encode Protocol.Rpc_error.codec
                   (rpc_error ~code:"invalid_envelope" message))
          | Ok envelope -> (
              try
                match route t envelope with
                | Ok response -> response
                | Error error -> response_error envelope error
              with exn ->
                let backtrace = Printexc.get_raw_backtrace () in
                report_exception t ~context:"transport handler" exn backtrace;
                response_error envelope
                  (rpc_error ~code:"backend_exception"
                     "the native transport handler raised an exception"))
        in
        respond_if_open app ~id ~error:false
          ~result:(encode_binding_response response));
  Eio.Switch.on_release sw (fun () ->
      Hashtbl.clear t.handlers;
      Hashtbl.clear t.frontend_pending;
      t.frontend <- None;
      t.ready_waiters <- []);
  t

let next_id t prefix =
  t.next_identifier <- Int64.succ t.next_identifier;
  prefix ^ "-" ^ Int64.to_string t.next_identifier

let await_ready t =
  if t.ready_generation > 0 then ()
  else
    let promise, resolve = Eio.Promise.create () in
    t.ready_waiters <- resolve :: t.ready_waiters;
    match
      Eio.Fiber.first
        (fun () ->
          Eio.Promise.await promise;
          `Ready)
        (fun () ->
          Webview_eio.await_closed t.app;
          `Closed)
    with
    | `Ready -> ()
    | `Closed ->
        raise
          (Webview.Error
             {
               operation = "await_frontend_ready";
               code = Webview.Closed;
               message = "the frontend window closed before becoming ready";
             })

let register t ~kind ?name handler =
  let key = handler_key ~kind ~name in
  if Hashtbl.mem t.handlers key then
    invalid_arg ("duplicate transport handler: " ^ key);
  Hashtbl.add t.handlers key handler;
  let subscription =
    { active = true; cancel = (fun () -> Hashtbl.remove t.handlers key) }
  in
  Eio.Switch.on_release t.sw (fun () ->
      if subscription.active then (
        subscription.active <- false;
        subscription.cancel ()));
  subscription

let unsubscribe subscription =
  if subscription.active then (
    subscription.active <- false;
    subscription.cancel ())

let subscription t cancel =
  let subscription = { active = true; cancel } in
  Eio.Switch.on_release t.sw (fun () ->
      if subscription.active then (
        subscription.active <- false;
        subscription.cancel ()));
  subscription

let call_frontend ?(timeout = 30.) t envelope =
  match envelope.Protocol.Envelope.id with
  | None ->
      Error (rpc_error ~code:"invalid_envelope" "frontend call requires an id")
  | Some id -> (
      let response, resolve = Eio.Promise.create () in
      Hashtbl.replace t.frontend_pending id resolve;
      match emit t envelope with
      | Error error ->
          Hashtbl.remove t.frontend_pending id;
          Error error
      | Ok () ->
          Fun.protect
            (fun () ->
              Eio.Fiber.first
                (fun () ->
                  Eio.Fiber.first
                    (fun () -> Ok (Eio.Promise.await response))
                    (fun () ->
                      Webview_eio.await_closed t.app;
                      Error
                        (rpc_error ~code:"window_closed"
                           "the frontend window closed before responding")))
                (fun () ->
                  t.sleep_fn timeout;
                  Error
                    (rpc_error ~code:"timeout"
                       "the frontend did not respond before the timeout")))
            ~finally:(fun () -> Hashtbl.remove t.frontend_pending id))
