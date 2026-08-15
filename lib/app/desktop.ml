module Dialog = struct
  let message window ~title ~message =
    ignore (Webview_eio.dialog window Webview.Message ~title ~detail:message)

  let one = function [| path |] -> Some path | _ -> None

  let open_file window ~title =
    Webview_eio.dialog window Webview.Open_file ~title ~detail:"" |> one

  let open_files window ~title =
    Webview_eio.dialog window Webview.Open_files ~title ~detail:""
    |> Array.to_list

  let open_directory window ~title =
    Webview_eio.dialog window Webview.Open_directory ~title ~detail:"" |> one

  let save_file window ~title ~suggested_name =
    Webview_eio.dialog window Webview.Save_file ~title ~detail:suggested_name
    |> one
end

module Theme = struct
  type t = Webview.system_theme = Light | Dark | Unknown

  let current = Webview_eio.system_theme

  let subscribe ~sw ~clock:_ window handler =
    handler (current window);
    Webview_eio.on_theme_change ~sw window handler
end

module Clipboard = struct
  let read_text = Webview_eio.clipboard_read
  let write_text = Webview_eio.clipboard_write
end

let respond_bool window id value =
  Webview_eio.respond window ~id ~error:false
    ~result:(if value then "true" else "false")

module Permission = struct
  type t = Camera | Microphone | Location | Notifications | Clipboard_read
  type decision = Allow | Deny

  let of_string = function
    | "camera" -> Some Camera
    | "microphone" -> Some Microphone
    | "location" -> Some Location
    | "notifications" -> Some Notifications
    | "clipboard-read" -> Some Clipboard_read
    | _ -> None

  let decode request =
    match Yojson.Safe.from_string request with
    | `List [ `String permission ] -> of_string permission
    | _ -> None
    | exception Yojson.Json_error _ -> None

  let script =
    {|
(function () {
  const request = async name => {
    const binding = globalThis.__owebview_permission;
    if (typeof binding !== "function") return false;
    try { return await binding(name) === true; } catch (_) { return false; }
  };
  if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
    const original = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    navigator.mediaDevices.getUserMedia = async constraints => {
      if (constraints && constraints.video && !await request("camera"))
        throw new DOMException("Camera permission denied", "NotAllowedError");
      if (constraints && constraints.audio && !await request("microphone"))
        throw new DOMException("Microphone permission denied", "NotAllowedError");
      return original(constraints);
    };
  }
  if (navigator.geolocation) {
    const original = navigator.geolocation.getCurrentPosition.bind(navigator.geolocation);
    navigator.geolocation.getCurrentPosition = (success, error, options) => {
      request("location").then(allowed => allowed
        ? original(success, error, options)
        : error && error({code: 1, message: "Location permission denied"}));
    };
  }
  if (globalThis.Notification && Notification.requestPermission) {
    const original = Notification.requestPermission.bind(Notification);
    Notification.requestPermission = async callback => {
      const result = await request("notifications") ? await original() : "denied";
      if (callback) callback(result);
      return result;
    };
  }
  if (navigator.clipboard && navigator.clipboard.readText) {
    const original = navigator.clipboard.readText.bind(navigator.clipboard);
    navigator.clipboard.readText = async () => {
      if (!await request("clipboard-read"))
        throw new DOMException("Clipboard permission denied", "NotAllowedError");
      return original();
    };
  }
})();
|}

  let install ~sw ~trusted window decide =
    Webview_eio.bind_with_url ~sw window "__owebview_permission"
      (fun ~id ~request ~url ->
        let allowed =
          Navigation.is_trusted trusted url
          &&
          match decode request with
          | Some permission -> decide permission = Allow
          | None -> false
        in
        respond_bool window id allowed);
    Webview_eio.init window script
end

module Download = struct
  type request = { url : string; suggested_filename : string option }
  type action = Reject | Open_external | Handled

  let decode request =
    match Yojson.Safe.from_string request with
    | `List [ `Assoc fields ] -> (
        match List.assoc_opt "url" fields with
        | Some (`String url) ->
            let suggested_filename =
              match List.assoc_opt "suggestedFilename" fields with
              | Some (`String value) when value <> "" -> Some value
              | _ -> None
            in
            Some { url; suggested_filename }
        | _ -> None)
    | _ -> None
    | exception Yojson.Json_error _ -> None

  let script =
    {|
addEventListener("click", event => {
  const anchor = event.target && event.target.closest
    ? event.target.closest("a[download]") : null;
  if (!anchor) return;
  event.preventDefault();
  const binding = globalThis.__owebview_download;
  if (typeof binding === "function") void binding({
    url: anchor.href, suggestedFilename: anchor.download || null
  }).catch(() => {});
}, true);
|}

  let install ~sw ~trusted window decide =
    Webview_eio.bind_with_url ~sw window "__owebview_download"
      (fun ~id ~request ~url ->
        let handled =
          if not (Navigation.is_trusted trusted url) then false
          else
            match decode request with
            | None -> false
            | Some request -> (
                match decide request with
                | Reject -> false
                | Handled -> true
                | Open_external ->
                    Webview.open_external request.url;
                    true)
        in
        respond_bool window id handled);
    Webview_eio.init window script
end
