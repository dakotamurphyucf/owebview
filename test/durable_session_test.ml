module Durable = Owebview_app.Durable_session
module Protocol = Owebview_protocol

let endpoint =
  Protocol.Stream_endpoint.make ~name:"test.durable"
    ~request:Protocol.Codec.unit ~event:Protocol.Codec.string
    ~command:Protocol.Codec.string ~result:Protocol.Codec.string

let require condition message = if not condition then failwith message

let find_summary id summaries =
  match
    List.find_opt (fun (summary : Durable.summary) -> summary.id = id) summaries
  with
  | Some summary -> summary
  | None -> failwith ("missing durable session: " ^ id)

let () =
  let directory = Filename.temp_file "owebview-durable-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  Fun.protect
    (fun () ->
      Eio_main.run @@ fun env ->
      let persistence = Durable.Persistence.directory directory in
      let completed_id, interrupted_id =
        Eio.Switch.run ~name:"durable-session-first-process" @@ fun sw ->
        let registry =
          Durable.create ~sw
            ~now:(fun () -> Eio.Time.now env#clock)
            ~persistence ()
        in
        let completed, resolve_completed = Eio.Promise.create () in
        let completed_session =
          match
            Durable.start registry endpoint () (fun session () ->
                ignore (Durable.Session.emit session "one");
                ignore (Durable.Session.emit session "two");
                ignore (Durable.Session.finish session "complete");
                Eio.Promise.resolve resolve_completed ())
          with
          | Ok session -> session
          | Error error -> failwith error.message
        in
        Eio.Promise.await completed;
        let started, resolve_started = Eio.Promise.create () in
        let never, _ = Eio.Promise.create () in
        let interrupted_session =
          match
            Durable.start registry endpoint () (fun session () ->
                ignore
                  (Durable.Session.save_checkpoint session
                     (Some (`Assoc [ ("external_run_id", `String "run-1") ])));
                ignore (Durable.Session.emit session "partial");
                Eio.Promise.resolve resolve_started ();
                Eio.Promise.await never)
          with
          | Ok session -> session
          | Error error -> failwith error.message
        in
        Eio.Promise.await started;
        let ids =
          ( Durable.Session.id completed_session,
            Durable.Session.id interrupted_session )
        in
        Durable.shutdown registry;
        ids
      in
      Eio.Switch.run ~name:"durable-session-second-process" @@ fun sw ->
      let registry =
        Durable.create ~sw
          ~now:(fun () -> Eio.Time.now env#clock)
          ~persistence:(Durable.Persistence.directory directory)
          ()
      in
      let retried, resolve_retried = Eio.Promise.create () in
      Durable.handle registry endpoint (fun session () ->
          ignore (Durable.Session.emit session "retried");
          ignore (Durable.Session.finish session "retry-complete");
          Eio.Promise.resolve resolve_retried (Durable.Session.id session));
      let summaries = Durable.list registry in
      let completed = find_summary completed_id summaries in
      require
        (completed.lifecycle = Completed)
        "completed durable session did not survive restart";
      require
        (completed.latest_sequence = 2L)
        "completed durable event history was not restored";
      let interrupted = find_summary interrupted_id summaries in
      require
        (interrupted.lifecycle = Interrupted)
        "running durable session was not classified as interrupted";
      require
        (interrupted.latest_sequence = 1L)
        "interrupted durable event history was not restored";
      (match Durable.snapshot registry interrupted_id with
      | Some
          {
            checkpoint = Some (`Assoc [ ("external_run_id", `String "run-1") ]);
            _;
          } ->
          ()
      | _ -> failwith "orchestration checkpoint did not survive restart");
      let retried_id =
        match Durable.retry registry interrupted_id with
        | Ok id -> id
        | Error error -> failwith error.message
      in
      require
        (retried_id <> interrupted_id)
        "retry reused an interrupted session identifier";
      require
        (Eio.Promise.await retried = retried_id)
        "retry handler did not run for the new durable session";
      let retried_summary = find_summary retried_id (Durable.list registry) in
      require
        (retried_summary.lifecycle = Completed)
        "retried durable session did not complete";
      require
        ((find_summary interrupted_id (Durable.list registry)).lifecycle
       = Interrupted)
        "retry mutated the interrupted historical session";

      let records = ref [] in
      let fail_next = ref false in
      let persistence =
        Durable.Persistence.make
          ~load_all:(fun () -> !records)
          ~save:(fun record ->
            if !fail_next then (
              fail_next := false;
              failwith "simulated persistence failure")
            else
              records :=
                record
                :: List.filter
                     (fun (existing : Durable.stored_session) ->
                       existing.id <> record.id)
                     !records)
          ~delete:(fun _ -> ())
      in
      Eio.Switch.run ~name:"durable-write-ordering" @@ fun ordering_sw ->
      let ordering =
        Durable.create ~sw:ordering_sw
          ~now:(fun () -> Eio.Time.now env#clock)
          ~persistence ()
      in
      let checked, resolve_checked = Eio.Promise.create () in
      ignore
        (Durable.start ordering endpoint () (fun session () ->
             fail_next := true;
             (match Durable.Session.emit session "must-not-commit" with
             | exception Failure message
               when message = "simulated persistence failure" ->
                 ()
             | exception exn -> raise exn
             | Ok () | Error _ ->
                 failwith "failed persistence unexpectedly admitted an event");
             let summary =
               find_summary (Durable.Session.id session) (Durable.list ordering)
             in
             require
               (summary.latest_sequence = 0L)
               "event sequence advanced before durable persistence succeeded";
             ignore (Durable.Session.finish session "write-ordering-complete");
             Eio.Promise.resolve resolve_checked ()));
      Eio.Promise.await checked;

      let admitted_record : Durable.stored_session =
        {
          schema_version = 2;
          id = "interrupted-command";
          endpoint = Protocol.Stream_endpoint.name endpoint;
          request = Protocol.Codec.encode Protocol.Codec.unit ();
          lifecycle = Interrupted;
          events = [];
          terminal = None;
          commands =
            [
              {
                id = "effect-may-have-run";
                encoded = `String "approve";
                status = Admitted;
                created_at = 1.;
                updated_at = 1.;
              };
            ];
          acknowledgements = [];
          checkpoint =
            Some (`Assoc [ ("external_run_id", `String "external-42") ]);
          created_at = 1.;
          updated_at = 1.;
        }
      in
      let reconciliation_records = ref [ admitted_record ] in
      let reconciliation_persistence =
        Durable.Persistence.make
          ~load_all:(fun () -> !reconciliation_records)
          ~save:(fun record ->
            reconciliation_records :=
              record
              :: List.filter
                   (fun (existing : Durable.stored_session) ->
                     existing.id <> record.id)
                   !reconciliation_records)
          ~delete:(fun id ->
            reconciliation_records :=
              List.filter
                (fun (record : Durable.stored_session) -> record.id <> id)
                !reconciliation_records)
      in
      Eio.Switch.run ~name:"durable-command-reconciliation"
      @@ fun reconcile_sw ->
      let reconciliation =
        Durable.create ~sw:reconcile_sw
          ~now:(fun () -> 2.)
          ~persistence:reconciliation_persistence ()
      in
      Durable.handle reconciliation endpoint (fun _session () -> ());
      (match
         Durable.admitted_commands reconciliation ~session_id:admitted_record.id
       with
      | [ { id = "effect-may-have-run"; status = Admitted; _ } ] -> ()
      | _ ->
          failwith
            "an admitted command was not exposed for restart reconciliation");
      (match
         Durable.mark_command_applied reconciliation
           ~session_id:admitted_record.id ~command_id:"effect-may-have-run"
       with
      | Ok () -> ()
      | Error error -> failwith error.message);
      require
        (Durable.admitted_commands reconciliation ~session_id:admitted_record.id
        = [])
        "an applied command remained in the reconciliation set";
      (match
         Durable.mark_command_rejected reconciliation
           ~session_id:admitted_record.id ~command_id:"effect-may-have-run"
           (Protocol.Rpc_error.make ~code:"too_late" "already applied")
       with
      | Error { code = "command_already_final"; _ } -> ()
      | Error error -> failwith error.message
      | Ok () -> failwith "a final command status was overwritten");

      Eio.Switch.run ~name:"durable-retention" @@ fun retention_sw ->
      let now = ref 0. in
      let retention =
        Durable.create ~max_sessions:3 ~sw:retention_sw
          ~now:(fun () -> !now)
          ~persistence:(Durable.Persistence.memory ())
          ()
      in
      let complete label =
        let finished, resolve_finished = Eio.Promise.create () in
        let session =
          match
            Durable.start retention endpoint () (fun session () ->
                ignore (Durable.Session.finish session label);
                Eio.Promise.resolve resolve_finished ())
          with
          | Ok session -> session
          | Error error -> failwith error.message
        in
        Eio.Promise.await finished;
        Durable.Session.id session
      in
      let first = complete "first" in
      now := 10.;
      ignore (complete "second");
      now := 20.;
      ignore (complete "third");
      require
        (Durable.compact ~keep_latest:1 retention = 2)
        "retention compaction did not remove older terminal sessions";
      require
        (List.length (Durable.list retention) = 1)
        "retention compaction left the wrong number of sessions";
      (match Durable.delete retention first with
      | Error { code = "session_not_found"; _ } -> ()
      | Error error -> failwith error.message
      | Ok () -> failwith "a compacted session was still deletable");
      let started, resolve_started = Eio.Promise.create () in
      let never, _ = Eio.Promise.create () in
      let running =
        match
          Durable.start retention endpoint () (fun _session () ->
              Eio.Promise.resolve resolve_started ();
              Eio.Promise.await never)
        with
        | Ok session -> session
        | Error error -> failwith error.message
      in
      Eio.Promise.await started;
      (match Durable.delete retention (Durable.Session.id running) with
      | Error { code = "session_running"; _ } -> ()
      | Error error -> failwith error.message
      | Ok () -> failwith "a running durable session was deleted");
      Durable.shutdown retention)
    ~finally:(fun () ->
      Sys.readdir directory
      |> Array.iter (fun name -> Sys.remove (Filename.concat directory name));
      Unix.rmdir directory)
