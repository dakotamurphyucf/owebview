type size = { width : int; height : int }

type config = {
  title : string;
  width : int;
  height : int;
  min_size : size option;
  max_size : size option;
  resizable : bool;
  debug : bool;
  assets : Assets.t;
  navigation : Navigation.policy;
}

let config ?(title = "Owebview") ?(width = 960) ?(height = 640) ?min_size
    ?max_size ?(resizable = true) ?(debug = false) ?navigation assets =
  if width <= 0 || height <= 0 then
    invalid_arg "Window.config: width and height must be positive";
  let validate (bound : size option) =
    match bound with
    | None -> ()
    | Some { width; height } when width > 0 && height > 0 -> ()
    | Some _ -> invalid_arg "Window.config: size bounds must be positive"
  in
  validate min_size;
  validate max_size;
  let navigation =
    Option.value navigation ~default:(Assets.navigation_policy assets)
  in
  {
    title;
    width;
    height;
    min_size;
    max_size;
    resizable;
    debug;
    assets;
    navigation;
  }

type t = Webview_eio.t

let configure_native webview config =
  Webview.set_title webview config.title;
  Webview.set_size webview ~width:config.width ~height:config.height
    (if config.resizable then Webview.Hint_none else Webview.Hint_fixed);
  Option.iter
    (fun (size : size) ->
      Webview.set_size webview ~width:size.width ~height:size.height
        Webview.Hint_min)
    config.min_size;
  Option.iter
    (fun (size : size) ->
      Webview.set_size webview ~width:size.width ~height:size.height
        Webview.Hint_max)
    config.max_size;
  Webview.set_navigation_handler webview (Navigation.decide config.navigation)

let configure window config =
  Webview_eio.call_ui window (fun webview -> configure_native webview config)

let create ~sw ?before_load parent config =
  let window =
    Webview_eio.create_window ~debug:config.debug ~sw parent
      ~setup:(fun webview -> configure_native webview config)
  in
  Option.iter (fun setup -> setup window) before_load;
  Webview_eio.navigate window (Assets.index_url config.assets);
  window

let transport ?binding_capacity ?required_capabilities ?on_error ~sw ~now ~sleep
    config window =
  Transport.create ?binding_capacity ?required_capabilities ?on_error ~sw ~now
    ~sleep
    ~trusted_origins:(Navigation.trusted_origins config.navigation)
    window

let close = Webview_eio.close
let await_closed = Webview_eio.await_closed
let is_closed = Webview_eio.is_closed
let set_title = Webview_eio.set_title
let set_size = Webview_eio.set_size
let set_position = Webview_eio.set_position
let show = Webview_eio.show
let hide = Webview_eio.hide
let focus = Webview_eio.focus
let minimize = Webview_eio.minimize
let maximize = Webview_eio.maximize
let restore = Webview_eio.restore
let set_fullscreen = Webview_eio.set_fullscreen
let reload = Webview_eio.reload
let current_url = Webview_eio.current_url
let intercept_close = Webview_eio.set_close_handler

let on_closed ~sw window handler =
  Eio.Fiber.fork ~sw (fun () ->
      Webview_eio.await_closed window;
      handler ())
