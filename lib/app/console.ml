type level = Debug | Info | Warning | Error

type message = {
  level : level;
  text : string;
  source : string option;
  line : int option;
  column : int option;
}

let level = function
  | "debug" -> Debug
  | "warn" -> Warning
  | "error" -> Error
  | _ -> Info

let optional_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Some value
  | _ -> None

let optional_int fields name =
  match List.assoc_opt name fields with
  | Some (`Int value) -> Some value
  | _ -> None

let decode request =
  match Yojson.Safe.from_string request with
  | `List [ `Assoc fields ] -> (
      match List.assoc_opt "text" fields with
      | Some (`String text) ->
          let raw_level =
            Option.value (optional_string fields "level") ~default:"info"
          in
          Some
            {
              level = level raw_level;
              text;
              source = optional_string fields "source";
              line = optional_int fields "line";
              column = optional_int fields "column";
            }
      | _ -> None)
  | _ -> None
  | exception Yojson.Json_error _ -> None

let script =
  {|
(function () {
  const send = payload => {
    try {
      const binding = globalThis.__owebview_console;
      if (typeof binding === "function") void binding(payload).catch(() => {});
    } catch (_) {}
  };
  const encode = value => {
    if (typeof value === "string") return value;
    if (value instanceof Error) return value.stack || value.message;
    try { return JSON.stringify(value); } catch (_) { return String(value); }
  };
  for (const level of ["debug", "info", "warn", "error"]) {
    const original = console[level].bind(console);
    console[level] = (...args) => {
      original(...args);
      send({level, text: args.map(encode).join(" ")});
    };
  }
  addEventListener("error", event => send({
    level: "error", text: event.message || "JavaScript error",
    source: event.filename || null, line: event.lineno || null,
    column: event.colno || null
  }));
  addEventListener("unhandledrejection", event => send({
    level: "error", text: "Unhandled rejection: " + encode(event.reason)
  }));
})();
|}

let install ~sw ~trusted window handler =
  Webview_eio.bind_with_url ~sw window "__owebview_console"
    (fun ~id ~request ~url ->
      if not (Navigation.is_trusted trusted url) then
        Webview_eio.respond window ~id ~error:true
          ~result:
            {|{"code":"untrusted_origin","message":"console forwarding denied"}|}
      else (
        Option.iter handler (decode request);
        Webview_eio.respond window ~id ~error:false ~result:"null"));
  Webview_eio.init window script
