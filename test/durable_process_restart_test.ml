module Durable = Owebview_app.Durable_session
module Protocol = Owebview_protocol

let endpoint =
  Protocol.Stream_endpoint.make ~name:"test.process-restart"
    ~request:Protocol.Codec.unit ~event:Protocol.Codec.string
    ~command:Protocol.Codec.string ~result:Protocol.Codec.string

let require condition message = if not condition then failwith message
let manifest directory = Filename.concat directory "manifest"

let write_manifest directory completed interrupted =
  let channel = open_out_bin (manifest directory) in
  Fun.protect
    (fun () ->
      output_string channel completed;
      output_char channel '\n';
      output_string channel interrupted;
      output_char channel '\n';
      flush channel;
      Unix.fsync (Unix.descr_of_out_channel channel))
    ~finally:(fun () -> close_out channel)

let read_manifest directory =
  let channel = open_in_bin (manifest directory) in
  Fun.protect
    (fun () ->
      let completed = input_line channel in
      let interrupted = input_line channel in
      (completed, interrupted))
    ~finally:(fun () -> close_in channel)

let writer directory =
  Eio_main.run @@ fun env ->
  Eio.Switch.run ~name:"durable-process-writer" @@ fun sw ->
  let registry =
    Durable.create ~sw
      ~now:(fun () -> Eio.Time.now env#clock)
      ~persistence:(Durable.Persistence.directory directory)
      ()
  in
  let completed, resolve_completed = Eio.Promise.create () in
  let completed_session =
    match
      Durable.start registry endpoint () (fun session () ->
          ignore (Durable.Session.emit session "persisted-before-exit");
          ignore (Durable.Session.finish session "complete");
          Eio.Promise.resolve resolve_completed ())
    with
    | Ok session -> session
    | Error error -> failwith error.message
  in
  Eio.Promise.await completed;
  let running, resolve_running = Eio.Promise.create () in
  let never, _ = Eio.Promise.create () in
  let interrupted_session =
    match
      Durable.start registry endpoint () (fun session () ->
          ignore
            (Durable.Session.save_checkpoint session
               (Some (`Assoc [ ("external_run_id", `String "process-17") ])));
          ignore (Durable.Session.emit session "partial-before-exit");
          Eio.Promise.resolve resolve_running ();
          Eio.Promise.await never)
    with
    | Ok session -> session
    | Error error -> failwith error.message
  in
  Eio.Promise.await running;
  write_manifest directory
    (Durable.Session.id completed_session)
    (Durable.Session.id interrupted_session);
  Durable.shutdown registry

let reader directory =
  let completed_id, interrupted_id = read_manifest directory in
  Eio_main.run @@ fun env ->
  Eio.Switch.run ~name:"durable-process-reader" @@ fun sw ->
  let registry =
    Durable.create ~sw
      ~now:(fun () -> Eio.Time.now env#clock)
      ~persistence:(Durable.Persistence.directory directory)
      ()
  in
  Durable.handle registry endpoint (fun _session () -> ());
  let summary id =
    match
      List.find_opt
        (fun (summary : Durable.summary) -> summary.id = id)
        (Durable.list registry)
    with
    | Some summary -> summary
    | None -> failwith ("missing session after process restart: " ^ id)
  in
  let completed = summary completed_id in
  require
    (completed.lifecycle = Completed)
    "completed history did not survive a new operating-system process";
  require
    (completed.latest_sequence = 1L)
    "completed events did not survive a new operating-system process";
  let interrupted = summary interrupted_id in
  require
    (interrupted.lifecycle = Interrupted)
    "running state was not reconciled in the second process";
  require
    (interrupted.latest_sequence = 1L)
    "partial events did not survive a new operating-system process";
  match Durable.snapshot registry interrupted_id with
  | Some
      {
        checkpoint = Some (`Assoc [ ("external_run_id", `String "process-17") ]);
        _;
      } ->
      ()
  | _ -> failwith "checkpoint did not survive a new operating-system process"

let run_child mode directory =
  let executable = Sys.executable_name in
  let pid =
    Unix.create_process executable
      [| executable; mode; directory |]
      Unix.stdin Unix.stdout Unix.stderr
  in
  match snd (Unix.waitpid [] pid) with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code ->
      failwith (Printf.sprintf "%s child exited with status %d" mode code)
  | Unix.WSIGNALED signal ->
      failwith (Printf.sprintf "%s child was killed by signal %d" mode signal)
  | Unix.WSTOPPED signal ->
      failwith (Printf.sprintf "%s child stopped on signal %d" mode signal)

let parent () =
  let directory = Filename.temp_file "owebview-process-restart-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    (fun () ->
      run_child "write" directory;
      run_child "read" directory)
    ~finally:(fun () ->
      Sys.readdir directory
      |> Array.iter (fun name -> Sys.remove (Filename.concat directory name));
      Unix.rmdir directory)

let () =
  match Array.to_list Sys.argv with
  | [ _ ] -> parent ()
  | [ _; "write"; directory ] -> writer directory
  | [ _; "read"; directory ] -> reader directory
  | _ -> failwith "invalid durable process restart test invocation"
