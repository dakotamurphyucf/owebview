module App = Owebview_app
module Agent = Agent_protocol.Protocol
module Protocol = Owebview_protocol

type simulation = {
  started_at : float;
  mutable paused : bool;
  mutable output_tokens : int;
  mutable tools_used : int;
  mutable instructions : string list;
}

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    (fun () -> really_input_string channel (in_channel_length channel))
    ~finally:(fun () -> close_in channel)

let rpc_error ~code message = Protocol.Rpc_error.make ~code message

let emit session event =
  match App.Durable_session.Session.emit session event with
  | Ok () -> ()
  | Error error -> failwith error.message

let finish session result =
  match App.Durable_session.Session.finish session result with
  | Ok () -> ()
  | Error error -> failwith error.message

let apply_command session command =
  match App.Durable_session.Session.mark_command_applied session command with
  | Ok () -> ()
  | Error error -> failwith error.message

let reject_command session command message =
  ignore
    (App.Durable_session.Session.mark_command_rejected session command
       (rpc_error ~code:"command_not_applicable" message))

let elapsed now state = now () -. state.started_at

let usage (state : simulation) now =
  Agent.
    {
      input_tokens = 684;
      output_tokens = state.output_tokens;
      cached_tokens = 192;
      estimated_cost = float_of_int (684 + state.output_tokens) *. 0.0000025;
      elapsed = elapsed now state;
    }

let update_usage session state now =
  emit session (Agent.Usage_updated (usage state now))

let cancel_run session state now command reason =
  apply_command session command;
  emit session (Agent.Status "Run cancelled cleanly");
  finish session (Agent.Cancelled { reason; elapsed = elapsed now state });
  raise App.Durable_session.Session_cancelled

let handle_general_command session state now command =
  match command.App.Durable_session.value with
  | Agent.Pause ->
      state.paused <- true;
      apply_command session command;
      emit session (Agent.Status "Paused — durable state is safe")
  | Agent.Resume ->
      state.paused <- false;
      apply_command session command;
      emit session (Agent.Status "Resumed")
  | Agent.Add_instruction instruction ->
      let instruction = String.trim instruction in
      if instruction = "" then
        reject_command session command "the instruction was empty"
      else (
        state.instructions <- state.instructions @ [ instruction ];
        apply_command session command;
        emit session (Agent.Instruction_received instruction);
        emit session
          (Agent.Activity
             {
               title = "Run guidance updated";
               detail =
                 "The new constraint will be reflected in the final review.";
             }))
  | Agent.Cancel -> cancel_run session state now command "Stopped by the user"
  | Agent.Approve _ | Agent.Reject _ ->
      reject_command session command "there is no matching pending approval"

let rec drain_commands session state now =
  match
    Eio.Stream.take_nonblocking (App.Durable_session.Session.commands session)
  with
  | None -> ()
  | Some command ->
      handle_general_command session state now command;
      drain_commands session state now

let rec await_resumed session state now =
  if state.paused then (
    let command =
      Eio.Stream.take (App.Durable_session.Session.commands session)
    in
    handle_general_command session state now command;
    await_resumed session state now)

let cooperative_sleep ~clock session state now duration =
  let rec loop remaining =
    drain_commands session state now;
    await_resumed session state now;
    if remaining > 0. then (
      let step = min 0.05 remaining in
      Eio.Time.sleep clock step;
      loop (remaining -. step))
  in
  loop duration

let save_checkpoint session ~phase ~progress =
  let checkpoint =
    `Assoc
      [
        ( "external_run_id",
          `String ("orbit-" ^ App.Durable_session.Session.id session) );
        ("phase", `String phase);
        ("progress", `Int progress);
      ]
  in
  match
    App.Durable_session.Session.save_checkpoint session (Some checkpoint)
  with
  | Error error -> failwith error.message
  | Ok () ->
      emit session
        (Agent.Checkpoint_saved (phase ^ " · " ^ string_of_int progress ^ "%"))

let run_tool ~clock session state now ~id ~name ~input ~steps ~summary =
  state.tools_used <- state.tools_used + 1;
  emit session (Agent.Tool_started { id; name; input });
  List.iter
    (fun (progress, detail) ->
      emit session (Agent.Tool_progress { id; progress; detail });
      cooperative_sleep ~clock session state now 0.16)
    steps;
  emit session
    (Agent.Tool_finished
       {
         id;
         summary;
         duration = 0.7 +. (float_of_int state.tools_used *. 0.18);
         success = true;
       });
  update_usage session state now

let await_approval session state now approval_id =
  let rec loop () =
    let command =
      Eio.Stream.take (App.Durable_session.Session.commands session)
    in
    match command.value with
    | Agent.Approve id when id = approval_id ->
        apply_command session command;
        emit session
          (Agent.Approval_resolved
             { id; approved = true; actor = "approved from a native window" });
        true
    | Agent.Reject id when id = approval_id ->
        apply_command session command;
        emit session
          (Agent.Approval_resolved
             { id; approved = false; actor = "rejected from a native window" });
        false
    | Agent.Approve _ | Agent.Reject _ ->
        reject_command session command "the approval identifier did not match";
        loop ()
    | _ ->
        handle_general_command session state now command;
        loop ()
  in
  loop ()

let stream_text ~clock session state now chunks =
  List.iter
    (fun chunk ->
      emit session (Agent.Text_delta chunk);
      state.output_tokens <-
        state.output_tokens + max 1 (String.length chunk / 4);
      update_usage session state now;
      cooperative_sleep ~clock session state now 0.045)
    chunks

let title_of_prompt prompt =
  let prompt = String.trim prompt in
  let limit = 52 in
  if String.length prompt <= limit then prompt
  else String.sub prompt 0 (limit - 1) ^ "…"

let run_agent ~clock ~now session (request : Agent.run_request) =
  let state =
    {
      started_at = now ();
      paused = false;
      output_tokens = 0;
      tools_used = 0;
      instructions = [];
    }
  in
  emit session
    (Agent.Run_started
       {
         title = title_of_prompt request.prompt;
         prompt = request.prompt;
         workspace = request.workspace;
         model = request.model;
         mode = request.mode;
       });
  emit session (Agent.Status "Building an execution plan");
  emit session
    (Agent.Phase_changed
       {
         phase = Planning;
         detail = "Decomposing the request into verifiable work";
       });
  emit session
    (Agent.Plan_updated
       [
         "Inspect the runtime architecture and durable session boundary";
         "Collect evidence from lifecycle, transport, and platform capabilities";
         "Prepare a proposed workspace action and request approval";
         "Synthesize findings into an implementation-ready report";
       ]);
  emit session
    (Agent.Activity
       {
         title = "Objective classified";
         detail = "Architecture and release-readiness analysis";
       });
  cooperative_sleep ~clock session state now 0.3;
  save_checkpoint session ~phase:"planning" ~progress:15;

  emit session
    (Agent.Phase_changed
       {
         phase = Research;
         detail = "Exploring the local OCaml project in parallel";
       });
  emit session (Agent.Status "Researching the local workspace");
  run_tool ~clock session state now ~id:"repo-map" ~name:"repository_search"
    ~input:"lib/app, lib/eio, lib/jsoo, validation docs"
    ~steps:
      [
        (18, "Mapping public libraries and module boundaries");
        (47, "Tracing native callback and Domain ownership");
        (76, "Reviewing durable stream persistence and replay");
        (100, "Architecture map complete");
      ]
    ~summary:
      "Mapped five public libraries, the native boundary, and durable session \
       ownership";
  emit session
    (Agent.Activity
       {
         title = "Concurrency invariant confirmed";
         detail =
           "UI work remains on the main thread; Eio owns application fibers";
       });
  run_tool ~clock session state now ~id:"test-scan" ~name:"validation_matrix"
    ~input:"OCaml 5.3 · Cocoa/WebKit · sanitizer and integration results"
    ~steps:
      [
        (22, "Reading lifecycle and multi-window coverage");
        (58, "Correlating streaming and persistence stress tests");
        (84, "Checking sanitizer exceptions and release tooling");
        (100, "Validation evidence assembled");
      ]
    ~summary:
      "Confirmed local macOS coverage and isolated machine-dependent \
       validation gaps";
  save_checkpoint session ~phase:"research" ~progress:48;

  let approval_id = "workspace-report" in
  emit session
    (Agent.Approval_requested
       {
         id = approval_id;
         title = "Create a release-readiness artifact?";
         description =
           "The simulation is ready to stage a detailed report artifact for \
            the local workspace. No remote operation will occur.";
         command = "generate ./reports/owebview-readiness.md --local-only";
         risk = Medium;
       });
  emit session (Agent.Status "Waiting for a durable approval command");
  let approved = await_approval session state now approval_id in

  emit session
    (Agent.Phase_changed
       {
         phase = Execution;
         detail = "Turning evidence into a concrete deliverable";
       });
  if approved then (
    emit session (Agent.Status "Approved — generating the local artifact");
    run_tool ~clock session state now ~id:"report-build"
      ~name:"artifact_builder" ~input:"reports/owebview-readiness.md"
      ~steps:
        [
          (20, "Structuring findings and maturity criteria");
          (54, "Adding platform and protocol recommendations");
          (82, "Cross-checking claims against validation status");
          (100, "Artifact staged in the durable run history");
        ]
      ~summary:
        "Prepared a release-readiness report without mutating the actual \
         repository";
    emit session
      (Agent.Artifact_created
         {
           name = "owebview-readiness.md";
           kind = "Markdown report";
           summary =
             "Architecture findings, maturity gates, and recommended next \
              actions";
         }))
  else (
    emit session
      (Agent.Status "Approval rejected — continuing in read-only mode");
    emit session
      (Agent.Activity
         {
           title = "Workspace mutation skipped";
           detail =
             "The final answer will remain in the streamed transcript only";
         }));
  save_checkpoint session ~phase:"execution" ~progress:76;

  emit session
    (Agent.Phase_changed
       {
         phase = Review;
         detail = "Validating conclusions and composing the response";
       });
  emit session (Agent.Status "Composing the final response");
  run_tool ~clock session state now ~id:"review" ~name:"consistency_check"
    ~input:"claims, evidence, compatibility boundary"
    ~steps:
      [
        (35, "Checking platform claims against the validation matrix");
        (72, "Checking protocol and persistence guarantees");
        (100, "Review complete — no unsupported claims detected");
      ]
    ~summary:
      "Validated the final response against local documentation and runtime \
       guarantees";

  let guidance =
    match state.instructions with
    | [] -> ""
    | instructions ->
        "\n\nI also incorporated your live guidance: "
        ^ String.concat "; " instructions
        ^ "."
  in
  let approval_note =
    if approved then
      "The approved report artifact is represented in durable history and can \
       be exported from the native window."
    else
      "The workspace action was rejected, so I preserved the run as a \
       read-only analysis."
  in
  stream_text ~clock session state now
    [
      "The project already has the right core architecture for a serious OCaml \
       desktop runtime. ";
      "Its strongest property is the ownership model: WebKit stays on the \
       operating-system main thread while Eio runs application work on a \
       dedicated Domain. ";
      "That boundary is reinforced by managed native handles, typed lifecycle \
       errors, bounded callback queues, and close-aware dispatch.\n\n";
      "For agent applications, the durable session layer is the centerpiece. ";
      "Events are sequenced and persisted before visibility, each native \
       window tracks its own acknowledgement cursor, and command identifiers \
       survive retries and process restart. ";
      "This gives the frontend realtime token delivery without coupling the \
       orchestration lifetime to one WebView document.\n\n";
      approval_note;
      "\n\n\
       The remaining maturity work is mostly validation rather than redesign: \
       OCaml 5.4/5.5 cells, Linux GTK coverage, WebView2 completion if Windows \
       is in scope, and integration with the real agent orchestrator's \
       checkpoint and side-effect reconciliation model.";
      guidance;
      "\n\n\
       Recommended next move: preserve this runtime as the narrow native \
       foundation, then build the opinionated application framework above \
       it—project scaffolding, frontend build orchestration, agent lifecycle \
       conventions, and native packaging.";
    ];
  emit session
    (Agent.Artifact_created
       {
         name = "run-transcript.json";
         kind = "Durable event log";
         summary =
           "Replayable sequence of phases, tools, approval, usage, and \
            terminal state";
       });
  save_checkpoint session ~phase:"review" ~progress:100;
  emit session (Agent.Status "Complete — durable history is ready to replay");
  let final_usage = usage state now in
  finish session
    (Agent.Completed
       {
         summary = "Architecture review and release-readiness plan completed";
         output_tokens = final_usage.output_tokens;
         tools_used = state.tools_used;
         elapsed = final_usage.elapsed;
       })

let bootstrap_script ?session_id ~role ~autoplay () =
  "globalThis.__owebviewBootstrap="
  ^ Yojson.Safe.to_string
      (`Assoc
         [
           ("role", `String role);
           ( "sessionId",
             match session_id with None -> `Null | Some id -> `String id );
           ("autoplay", `Bool autoplay);
         ])
  ^ ";"

let capability_name : App.Platform.capability -> string = function
  | Multiple_windows -> "multiple windows"
  | Navigation_policy -> "navigation policy"
  | Native_dialogs -> "native dialogs"
  | Clipboard_read -> "clipboard read"
  | Clipboard_write -> "clipboard write"
  | Theme_query -> "theme query"
  | Theme_notifications -> "theme notifications"
  | Permission_policy -> "permission policy"
  | Native_permission_delegates -> "native permission delegates"
  | Download_policy -> "download policy"
  | Native_downloads -> "native downloads"
  | Custom_scheme -> "custom scheme"
  | Development_tools -> "development tools"

let validation_name : App.Platform.validation -> string = function
  | Validated -> "validated"
  | Compiled_unvalidated -> "compiled, unvalidated"
  | Unsupported -> "unsupported"

let save_file path content =
  let channel = open_out_bin path in
  Fun.protect
    (fun () -> output_string channel content)
    ~finally:(fun () -> close_out channel)

let () =
  if Array.length Sys.argv <> 2 then
    failwith "usage: backend.exe FRONTEND.bc.js";
  let javascript = read_file Sys.argv.(1) in
  Webview_eio.run
    ~setup:(fun webview ->
      Webview.set_title webview "Orbit Agent Studio";
      Webview.set_size webview ~width:1280 ~height:820 Webview.Hint_none)
    (fun ~env ~sw app ->
      let session_directory =
        match Sys.getenv_opt "OWEBVIEW_SESSION_DIR" with
        | Some path -> path
        | None -> Filename.concat (Sys.getcwd ()) ".owebview-agent-sessions"
      in
      let autoplay = Sys.getenv_opt "OWEBVIEW_DEMO_AUTOPLAY" = Some "1" in
      let autoplay_export =
        Sys.getenv_opt "OWEBVIEW_DEMO_AUTOPLAY_EXPORT" = Some "1"
      in
      let autoplay_fullscreen =
        Sys.getenv_opt "OWEBVIEW_DEMO_AUTOPLAY_FULLSCREEN" = Some "1"
      in
      let bootstrap_session = Sys.getenv_opt "OWEBVIEW_DEMO_SESSION_ID" in
      let assets =
        App.Assets.start ~sw ~net:env#net
          (Embedded
             (App.Assets.bundle
                [
                  ("index.html", Demo_assets.index_html);
                  ("app.css", Demo_assets.stylesheet);
                  ("frontend.js", javascript);
                ]))
      in
      let navigation = App.Assets.navigation_policy assets in
      let registry =
        App.Durable_session.create ~sw ~max_sessions:128
          ~now:(fun () -> Eio.Time.now env#clock)
          ~persistence:
            (App.Durable_session.Persistence.directory session_directory)
          ()
      in
      App.Durable_session.handle registry Agent.run
        (run_agent ~clock:env#clock ~now:(fun () -> Eio.Time.now env#clock));

      let next_inspector = ref 0 in
      let authorize ~subscriber_id _action =
        subscriber_id = "conversation"
        || String.starts_with ~prefix:"inspector-" subscriber_id
      in
      let rec install_window ~window_sw ~role window =
        let transport =
          App.Transport.create ~sw:window_sw
            ~now:(fun () -> Eio.Time.now env#clock)
            ~sleep:(Eio.Time.sleep env#clock)
            ~trusted_origins:(App.Assets.trusted_origins assets)
            window
        in
        ignore
          (App.Durable_session.connect registry transport ~event_capacity:512
             ~event_byte_capacity:(2 * 1024 * 1024)
             ~flush_interval:0.008 ~max_batch_bytes:(128 * 1024) ~authorize);
        let rpc = App.Rpc.Server.create transport in
        ignore
          (App.Rpc.Server.handle rpc Agent.open_inspector (fun session_id ->
               let ready, resolve_ready = Eio.Promise.create () in
               incr next_inspector;
               let inspector_role =
                 "inspector-" ^ string_of_int !next_inspector
               in
               Eio.Fiber.fork ~sw (fun () ->
                   Eio.Switch.run ~name:"agent.inspector" @@ fun inspector_sw ->
                   let inspector =
                     Webview_eio.create_window ~sw:inspector_sw app
                       ~setup:(fun webview ->
                         Webview.set_title webview "Orbit Run Inspector";
                         Webview.set_size webview ~width:1080 ~height:760
                           Webview.Hint_none;
                         Webview.set_navigation_handler webview
                           (App.Navigation.decide navigation);
                         Webview.init webview
                           (bootstrap_script ~session_id ~role:inspector_role
                              ~autoplay:false ()))
                   in
                   install_window ~window_sw:inspector_sw ~role:inspector_role
                     inspector;
                   Webview_eio.navigate inspector (App.Assets.index_url assets);
                   Eio.Promise.resolve resolve_ready ();
                   Webview_eio.await_closed inspector);
               Eio.Promise.await ready;
               Ok ()));
        ignore
          (App.Rpc.Server.handle rpc Agent.retry (fun session_id ->
               App.Durable_session.retry registry session_id));
        ignore
          (App.Rpc.Server.handle rpc Agent.platform_info (fun () ->
               Ok
                 Agent.
                   {
                     backend =
                       App.Platform.string_of_backend (App.Platform.backend ());
                     validation = validation_name (App.Platform.validation ());
                     capabilities =
                       List.map capability_name (App.Platform.capabilities ());
                     session_directory;
                   }));
        ignore
          (App.Rpc.Server.handle rpc Agent.copy_text (fun text ->
               try
                 App.Desktop.Clipboard.write_text window text;
                 Ok ()
               with Webview.Error error ->
                 Error
                   (rpc_error ~code:"clipboard_unavailable"
                      (Format.asprintf "%a" Webview.pp_error error))));
        ignore
          (App.Rpc.Server.handle rpc Agent.save_report (fun request ->
               match
                 App.Desktop.Dialog.save_file window
                   ~title:"Export agent report"
                   ~suggested_name:request.suggested_name
               with
               | None -> Ok None
               | Some path ->
                   save_file path request.content;
                   Ok (Some path)));
        App.Console.install ~sw:window_sw ~trusted:navigation window
          (fun message ->
            Printf.eprintf "agent frontend [%s]: %s\n%!" role message.text);
        App.Desktop.Permission.install ~sw:window_sw ~trusted:navigation window
          (fun _ -> Deny);
        App.Desktop.Download.install ~sw:window_sw ~trusted:navigation window
          (fun _ -> Reject)
      in

      App.Window.configure app
        (App.Window.config ~title:"Orbit Agent Studio" ~width:1280 ~height:820
           ~min_size:{ width = 920; height = 640 }
           ~navigation assets);
      Webview_eio.init app
        (bootstrap_script ?session_id:bootstrap_session ~role:"conversation"
           ~autoplay ());
      install_window ~window_sw:sw ~role:"conversation" app;
      Webview_eio.navigate app (App.Assets.index_url assets);
      if autoplay_export then
        Eio.Fiber.fork ~sw (fun () ->
            Eio.Time.sleep env#clock 6.;
            Webview_eio.eval app
              "document.getElementById('export-report')?.click()")
      else ();
      if autoplay_fullscreen then
        Eio.Fiber.fork ~sw (fun () ->
            Eio.Time.sleep env#clock 6.;
            Webview_eio.set_fullscreen app true;
            Eio.Time.sleep env#clock 2.;
            Webview_eio.set_fullscreen app false)
      else ();
      Webview_eio.await_closed app)
