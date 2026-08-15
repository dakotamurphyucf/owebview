type level = Debug | Info | Warning | Error

type message = {
  level : level;
  text : string;
  source : string option;
  line : int option;
  column : int option;
}

val install :
  sw:Eio.Switch.t ->
  trusted:Navigation.policy ->
  Webview_eio.t ->
  (message -> unit) ->
  unit
