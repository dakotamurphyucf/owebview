exception Window_closed

type t = {
  webview : Webview.t;
  dispatcher : Webview.t;
  closed : unit Eio.Promise.t;
  resolve_closed : unit Eio.Promise.u;
  primary : bool;
  close_handler : (unit -> bool) ref;
}

let webview t = t.webview
let await_closed t = Eio.Promise.await t.closed
let is_closed t = Webview.is_closed t.webview

let make_window ~dispatcher ~primary webview =
  let closed, resolve_closed =
    Eio.Promise.create ~label:"owebview.window.closed" ()
  in
  let close_handler = ref (fun () -> true) in
  let t =
    { webview; dispatcher; closed; resolve_closed; primary; close_handler }
  in
  Webview.on_close webview (fun () ->
      ignore (Eio.Promise.try_resolve resolve_closed ()));
  Webview.set_close_handler webview (fun () ->
      let allow = !close_handler () in
      if allow && not primary then (
        Webview.defer dispatcher (fun _ -> Webview.destroy webview);
        false)
      else allow);
  t

let closed_error operation =
  Webview.Error
    { Webview.operation; code = Webview.Closed; message = "webview is closed" }

let call_ui t f =
  if Webview.is_closed t.webview then raise (closed_error "dispatch");
  let result, resolve = Eio.Promise.create () in
  Webview.dispatch t.dispatcher (fun _ ->
      let outcome =
        try
          if Webview.is_closed t.webview then raise (closed_error "dispatch");
          Ok (f t.webview)
        with exn -> Error (exn, Printexc.get_raw_backtrace ())
      in
      ignore (Eio.Promise.try_resolve resolve outcome));
  match
    Eio.Fiber.first
      (fun () -> `Result (Eio.Promise.await result))
      (fun () ->
        Eio.Promise.await t.closed;
        `Closed)
  with
  | `Closed -> raise (closed_error "dispatch")
  | `Result (Ok value) -> value
  | `Result (Error (exn, backtrace)) ->
      Printexc.raise_with_backtrace exn backtrace

let close t =
  try
    if not (Webview.is_closed t.webview) then
      Webview.dispatch t.dispatcher (fun _ ->
          if not (Webview.is_closed t.webview) then
            Webview.window_command t.webview Webview.Request_close)
  with Webview.Error { code = Closed | Closing | Invalid_state; _ } -> ()

let set_title t title =
  call_ui t (fun webview -> Webview.set_title webview title)

let set_size t ~width ~height hint =
  call_ui t (fun webview -> Webview.set_size webview ~width ~height hint)

let navigate t url = call_ui t (fun webview -> Webview.navigate webview url)
let set_html t html = call_ui t (fun webview -> Webview.set_html webview html)

let init t javascript =
  call_ui t (fun webview -> Webview.init webview javascript)

let eval t javascript =
  call_ui t (fun webview -> Webview.eval webview javascript)

let reload t = call_ui t Webview.reload
let current_url t = call_ui t Webview.current_url
let show t = call_ui t (fun webview -> Webview.window_command webview Show)
let hide t = call_ui t (fun webview -> Webview.window_command webview Hide)
let focus t = call_ui t (fun webview -> Webview.window_command webview Focus)

let minimize t =
  call_ui t (fun webview -> Webview.window_command webview Minimize)

let maximize t =
  call_ui t (fun webview -> Webview.window_command webview Maximize)

let restore t =
  call_ui t (fun webview -> Webview.window_command webview Restore)

let set_fullscreen t enabled =
  call_ui t (fun webview ->
      Webview.window_command webview
        (if enabled then Enter_fullscreen else Exit_fullscreen))

let set_navigation_handler t handler =
  call_ui t (fun webview -> Webview.set_navigation_handler webview handler)

let set_close_handler t handler =
  call_ui t (fun _ -> t.close_handler := handler)

let set_position t ~x ~y =
  call_ui t (fun webview -> Webview.set_position webview ~x ~y)

let system_theme t = call_ui t Webview.system_theme
let clipboard_read t = call_ui t Webview.clipboard_read

let clipboard_write t contents =
  call_ui t (fun webview -> Webview.clipboard_write webview contents)

let on_theme_change ~sw t handler =
  let changes = Eio.Stream.create 8 in
  call_ui t (fun webview ->
      Webview.on_theme_change webview (fun theme ->
          if Eio.Stream.length changes < 8 then Eio.Stream.add changes theme));
  Eio.Fiber.fork ~sw (fun () ->
      while true do
        handler (Eio.Stream.take changes)
      done)

let dialog t kind ~title ~detail =
  if Webview.is_closed t.webview then raise (closed_error "native_dialog");
  let start, resolve_start =
    Eio.Promise.create ~label:"owebview.dialog.start" ()
  in
  let result, resolve = Eio.Promise.create ~label:"owebview.dialog" () in
  let dispatched = Atomic.make false in
  let start_finished = Atomic.make false in
  let native_started = Atomic.make false in
  let native_finished = Atomic.make false in
  let start_on_ui _ =
    let outcome =
      try
        Webview.dialog_async t.webview kind ~title ~detail (fun outcome ->
            Atomic.set native_finished true;
            ignore (Eio.Promise.try_resolve resolve outcome));
        Atomic.set native_started true;
        Result.Ok ()
      with exn -> Result.Error (exn, Printexc.get_raw_backtrace ())
    in
    Atomic.set start_finished true;
    ignore (Eio.Promise.try_resolve resolve_start outcome)
  in
  let await_start () =
    Eio.Fiber.first
      (fun () -> `Started (Eio.Promise.await start))
      (fun () ->
        Eio.Promise.await t.closed;
        `Closed)
  in
  let cancel_if_waiting () =
    if Atomic.get dispatched && not (Atomic.get start_finished) then
      Eio.Cancel.protect (fun () -> ignore (await_start ()));
    if Atomic.get native_started && not (Atomic.get native_finished) then (
      (try
         Webview.dispatch t.dispatcher (fun _ ->
             if not (Webview.is_closed t.webview) then
               Webview.cancel_dialog t.webview)
       with Webview.Error { code = Closed | Closing | Invalid_state; _ } -> ());
      if not (Atomic.get native_finished) then
        Eio.Cancel.protect (fun () -> ignore (Eio.Promise.await result)))
  in
  Fun.protect
    (fun () ->
      Webview.dispatch t.dispatcher start_on_ui;
      Atomic.set dispatched true;
      (match await_start () with
      | `Closed -> raise (closed_error "native_dialog")
      | `Started (Result.Ok ()) -> ()
      | `Started (Result.Error (exn, backtrace)) ->
          Printexc.raise_with_backtrace exn backtrace);
      match
        Eio.Fiber.first
          (fun () -> `Result (Eio.Promise.await result))
          (fun () ->
            Eio.Promise.await t.closed;
            `Closed)
      with
      | `Closed -> raise (closed_error "native_dialog")
      | `Result (Result.Ok paths) -> paths
      | `Result (Result.Error error) -> raise (Webview.Error error))
    ~finally:cancel_if_waiting

let respond t ~id ~error ~result = Webview.return t.webview id ~error ~result

let bind ?(capacity = 1024) ?(concurrency = 64) ~sw t name handler =
  if capacity <= 0 then
    invalid_arg "Webview_eio.bind: capacity must be positive";
  if concurrency <= 0 then
    invalid_arg "Webview_eio.bind: concurrency must be positive";
  let requests = Eio.Stream.create capacity in
  call_ui t (fun webview ->
      Webview.bind webview name (fun id request ->
          if Eio.Stream.length requests >= capacity then
            Webview.return webview id ~error:true
              ~result:
                {|{"code":"queue_full","message":"native request queue is full"}|}
          else Eio.Stream.add requests (id, request)));
  for _worker = 1 to concurrency do
    Eio.Fiber.fork ~sw (fun () ->
        while true do
          let id, request = Eio.Stream.take requests in
          handler ~id ~request
        done)
  done

let bind_with_url ?(capacity = 1024) ?(concurrency = 64) ~sw t name handler =
  if capacity <= 0 then
    invalid_arg "Webview_eio.bind_with_url: capacity must be positive";
  if concurrency <= 0 then
    invalid_arg "Webview_eio.bind_with_url: concurrency must be positive";
  let requests = Eio.Stream.create capacity in
  call_ui t (fun webview ->
      Webview.bind_with_url webview name (fun id request url ->
          if Eio.Stream.length requests >= capacity then
            Webview.return webview id ~error:true
              ~result:
                {|{"code":"queue_full","message":"native request queue is full"}|}
          else Eio.Stream.add requests (id, request, url)));
  for _worker = 1 to concurrency do
    Eio.Fiber.fork ~sw (fun () ->
        while true do
          let id, request, url = Eio.Stream.take requests in
          handler ~id ~request ~url
        done)
  done

let create_window ?(debug = false) ~sw parent ~setup =
  let child =
    call_ui parent (fun _ ->
        let webview = Webview.create ~debug () in
        try
          let child =
            make_window ~dispatcher:parent.dispatcher ~primary:false webview
          in
          setup webview;
          child
        with exn ->
          Webview.defer parent.dispatcher (fun _ -> Webview.destroy webview);
          raise exn)
  in
  Eio.Switch.on_release sw (fun () -> close child);
  child

let run ?(debug = false) ~setup application =
  let webview = Webview.create ~debug () in
  let app = make_window ~dispatcher:webview ~primary:true webview in
  let worker_outcome = Atomic.make (Ok ()) in
  let setup_outcome =
    try
      setup webview;
      Ok ()
    with exn -> Error (exn, Printexc.get_raw_backtrace ())
  in
  match setup_outcome with
  | Error (exn, backtrace) ->
      Webview.destroy webview;
      Printexc.raise_with_backtrace exn backtrace
  | Ok () -> (
      let worker =
        Domain.spawn (fun () ->
            let outcome =
              try
                Eio_main.run (fun env ->
                    try
                      Eio.Switch.run ~name:"owebview.application" @@ fun sw ->
                      Eio.Fiber.fork ~sw (fun () ->
                          Fun.protect
                            (fun () -> application ~env ~sw app)
                            ~finally:(fun () -> close app));
                      Eio.Promise.await app.closed;
                      Eio.Switch.fail sw Window_closed
                    with Window_closed -> ());
                Ok ()
              with exn -> Error (exn, Printexc.get_raw_backtrace ())
            in
            Atomic.set worker_outcome outcome;
            match outcome with Error _ -> close app | Ok () -> ())
      in
      let run_outcome =
        try
          Webview.run webview;
          Ok ()
        with exn -> Error (exn, Printexc.get_raw_backtrace ())
      in
      ignore (Eio.Promise.try_resolve app.resolve_closed ());
      Domain.join worker;
      Webview.destroy webview;
      match run_outcome with
      | Error (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
      | Ok () -> (
          match Atomic.get worker_outcome with
          | Ok () -> ()
          | Error (exn, backtrace) ->
              Printexc.raise_with_backtrace exn backtrace))
