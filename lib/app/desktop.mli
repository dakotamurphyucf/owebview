module Dialog : sig
  val message : Webview_eio.t -> title:string -> message:string -> unit
  val open_file : Webview_eio.t -> title:string -> string option
  val open_files : Webview_eio.t -> title:string -> string list
  val open_directory : Webview_eio.t -> title:string -> string option

  val save_file :
    Webview_eio.t -> title:string -> suggested_name:string -> string option
end

module Theme : sig
  type t = Webview.system_theme = Light | Dark | Unknown

  val current : Webview_eio.t -> t

  val subscribe :
    sw:Eio.Switch.t ->
    clock:_ Eio.Time.clock ->
    Webview_eio.t ->
    (t -> unit) ->
    unit
end

module Clipboard : sig
  val read_text : Webview_eio.t -> string option
  val write_text : Webview_eio.t -> string -> unit
end

module Permission : sig
  type t = Camera | Microphone | Location | Notifications | Clipboard_read
  type decision = Allow | Deny

  val install :
    sw:Eio.Switch.t ->
    trusted:Navigation.policy ->
    Webview_eio.t ->
    (t -> decision) ->
    unit
end

module Download : sig
  type request = { url : string; suggested_filename : string option }
  type action = Reject | Open_external | Handled

  val install :
    sw:Eio.Switch.t ->
    trusted:Navigation.policy ->
    Webview_eio.t ->
    (request -> action) ->
    unit
end
