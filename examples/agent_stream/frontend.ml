open Js_of_ocaml
module Client = Owebview_jsoo
module Agent = Agent_protocol.Protocol

type tool_view = {
  card : Dom_html.element Js.t;
  state : Dom_html.element Js.t;
  detail : Dom_html.element Js.t;
  progress : Dom_html.element Js.t;
}

let element id : Dom_html.element Js.t =
  Js.Unsafe.meth_call Dom_html.document "getElementById"
    [| Js.Unsafe.inject (Js.string id) |]

let set_text target value = Js.Unsafe.set target "textContent" (Js.string value)
let set_value target value = Js.Unsafe.set target "value" (Js.string value)

let value target =
  let value : Js.js_string Js.t = Js.Unsafe.get target "value" in
  Js.to_string value

let set_class target value = Js.Unsafe.set target "className" (Js.string value)
let set_hidden target hidden = Js.Unsafe.set target "hidden" (Js.bool hidden)

let set_disabled target disabled =
  Js.Unsafe.set target "disabled" (Js.bool disabled)

let clear target = Js.Unsafe.set target "textContent" (Js.string "")

let append parent child =
  Dom.appendChild (Js.Unsafe.coerce parent) (Js.Unsafe.coerce child)

let create tag class_name =
  let node : Dom_html.element Js.t =
    Js.Unsafe.meth_call Dom_html.document "createElement"
      [| Js.Unsafe.inject (Js.string tag) |]
  in
  set_class node class_name;
  node

let create_text tag class_name text =
  let node = create tag class_name in
  set_text node text;
  node

let error_message (error : Owebview_protocol.Rpc_error.t) = error.message

let bootstrap () =
  let value : Js.Unsafe.any =
    Js.Unsafe.get Js.Unsafe.global "__owebviewBootstrap"
  in
  let role : Js.js_string Js.t = Js.Unsafe.get value "role" in
  let session_id : Js.js_string Js.t Js.opt = Js.Unsafe.get value "sessionId" in
  let autoplay : bool = Js.to_bool (Js.Unsafe.get value "autoplay") in
  ( Js.to_string role,
    Js.Opt.to_option session_id |> Option.map Js.to_string,
    autoplay )

let lifecycle_name : Client.Durable_session.lifecycle -> string = function
  | Running -> "running"
  | Recovering -> "recovering"
  | Interrupted -> "interrupted"
  | Completed -> "completed"
  | Failed -> "failed"
  | Cancelled -> "cancelled"

let lifecycle_label lifecycle =
  match lifecycle_name lifecycle with
  | "running" -> "Running"
  | "recovering" -> "Recovering"
  | "interrupted" -> "Interrupted"
  | "completed" -> "Completed"
  | "failed" -> "Failed"
  | "cancelled" -> "Cancelled"
  | _ -> "Ready"

let ui_mode_of_string = function
  | "fast" -> Agent.Fast
  | "deep" -> Agent.Deep
  | _ -> Agent.Balanced

let mode_name = function
  | Agent.Fast -> "Fast"
  | Agent.Balanced -> "Balanced"
  | Agent.Deep -> "Deep"

let phase_index = function
  | Agent.Planning -> 0
  | Agent.Research -> 1
  | Agent.Execution -> 2
  | Agent.Review -> 3

let phase_id = function
  | Agent.Planning -> "phase-planning"
  | Agent.Research -> "phase-research"
  | Agent.Execution -> "phase-execution"
  | Agent.Review -> "phase-review"

let phase_all =
  [ Agent.Planning; Agent.Research; Agent.Execution; Agent.Review ]

let short_id id =
  if String.length id <= 14 then id
  else String.sub id (String.length id - 12) 12

let word_count text =
  String.split_on_char ' ' text
  |> List.filter (fun value -> String.trim value <> "")
  |> List.length

let () =
  let role, bootstrap_session, autoplay = bootstrap () in
  let inspector = String.starts_with ~prefix:"inspector" role in
  let body : Dom_html.bodyElement Js.t =
    Js.Unsafe.get Dom_html.document "body"
  in
  if inspector then set_class body "inspector";

  let history = element "history" in
  let session_count = element "session-count" in
  let welcome = element "welcome" in
  let run_view = element "run-view" in
  let run_title = element "run-title" in
  let lifecycle_badge = element "lifecycle-badge" in
  let window_role = element "window-role" in
  let workspace_name = element "workspace-name" in
  let prompt_display = element "prompt-display" in
  let prompt_input = element "prompt-input" in
  let mode_select = element "mode-select" in
  let model_select = element "model-select" in
  let send_prompt = element "send-prompt" in
  let new_run = element "new-run" in
  let output = element "output" in
  let answer_card = element "answer-card" in
  let answer_word_count = element "answer-word-count" in
  let cursor = element "cursor" in
  let status = element "status" in
  let run_controls = element "run-controls" in
  let pause_run = element "pause-run" in
  let resume_run = element "resume-run" in
  let cancel_run = element "cancel-run" in
  let plan_card = element "plan-card" in
  let plan_list = element "plan-list" in
  let phase_detail = element "phase-detail" in
  let activity_card = element "activity-card" in
  let activity_list = element "activity-list" in
  let tool_list = element "tool-list" in
  let approval_card = element "approval-card" in
  let approval_risk = element "approval-risk" in
  let approval_title = element "approval-title" in
  let approval_description = element "approval-description" in
  let approval_command = element "approval-command" in
  let approval_approve = element "approval-approve" in
  let approval_reject = element "approval-reject" in
  let artifact_section = element "artifact-section" in
  let artifact_list = element "artifact-list" in
  let terminal_card = element "terminal-card" in
  let terminal_title = element "terminal-title" in
  let terminal_detail = element "terminal-detail" in
  let streaming_indicator = element "streaming-indicator" in
  let model_label = element "model-label" in
  let open_inspector = element "open-inspector" in
  let copy_output = element "copy-output" in
  let export_report = element "export-report" in
  let instruction_input = element "instruction-input" in
  let send_instruction = element "send-instruction" in
  let session_short = element "session-short" in
  let sequence_value = element "sequence-value" in
  let checkpoint_value = element "checkpoint-value" in
  let client_value = element "client-value" in
  let metric_input = element "metric-input" in
  let metric_output = element "metric-output" in
  let metric_cached = element "metric-cached" in
  let metric_cost = element "metric-cost" in
  let metric_time = element "metric-time" in
  let token_bar_fill = element "token-bar-fill" in
  let platform_backend = element "platform-backend" in
  let capability_list = element "capability-list" in
  let backend_label = element "backend-label" in
  let connection_dot = element "connection-dot" in
  let connection_label = element "connection-label" in
  let scroll_region = element "scroll-region" in
  let jump_latest = element "jump-latest" in
  let toast = element "toast" in

  set_text window_role (if inspector then "Run inspector" else "Conversation");
  set_text client_value role;
  set_value prompt_input
    "Analyze this OCaml desktop runtime and propose a production readiness \
     plan.";

  let client =
    Client.create ~client_identifier:role ~max_pending_events:4096 ()
  in
  Client.install client;

  let active_stream = ref None in
  let active_subscription = ref None in
  let active_session = ref None in
  let active_approval = ref None in
  let transcript = Buffer.create 4096 in
  let current_prompt = ref "" in
  let current_title = ref "Agent workspace" in
  let current_status = ref "Ready" in
  let current_lifecycle = ref "idle" in
  let artifact_names = ref [] in
  let tool_views : (string, tool_view) Hashtbl.t = Hashtbl.create 8 in
  let toast_generation = ref 0 in
  let history_cache = ref [] in
  let follow_latest = ref true in

  let show_toast message =
    incr toast_generation;
    let generation = !toast_generation in
    set_text toast message;
    set_hidden toast false;
    Js.Unsafe.meth_call Dom_html.window "setTimeout"
      [|
        Js.Unsafe.inject
          (Js.wrap_callback (fun () ->
               if generation = !toast_generation then set_hidden toast true));
        Js.Unsafe.inject 2200;
      |]
    |> ignore
  in

  let scroll_bottom () =
    if !follow_latest then
      Js.Unsafe.set scroll_region "scrollTop"
        (Js.Unsafe.get scroll_region "scrollHeight")
  in

  let jump_to_latest () =
    follow_latest := true;
    set_hidden jump_latest true;
    Js.Unsafe.set scroll_region "scrollTop"
      (Js.Unsafe.get scroll_region "scrollHeight")
  in

  let update_sequence () =
    match !active_stream with
    | None -> set_text sequence_value "0"
    | Some stream ->
        set_text sequence_value
          (Int64.to_string (Client.Stream.last_sequence stream))
  in

  let set_lifecycle state label =
    current_lifecycle := state;
    set_class lifecycle_badge ("pill pill-" ^ state);
    let dot = create "span" "" in
    clear lifecycle_badge;
    append lifecycle_badge dot;
    append lifecycle_badge (create_text "span" "" label)
  in

  let set_connection connected label =
    set_class connection_dot (if connected then "connected" else "");
    set_text connection_label label
  in

  let set_phase phase detail =
    let active_index = phase_index phase in
    List.iter
      (fun candidate ->
        let index = phase_index candidate in
        let class_name =
          if index < active_index then "phase complete"
          else if index = active_index then "phase active"
          else "phase"
        in
        set_class (element (phase_id candidate)) class_name)
      phase_all;
    set_text phase_detail detail
  in

  let append_activity title detail =
    set_hidden activity_card false;
    let item = create "div" "activity-item" in
    append item (create "span" "");
    let copy = create "div" "" in
    append copy (create_text "b" "" title);
    append copy (create_text "small" "" detail);
    append item copy;
    append activity_list item;
    while
      let child_nodes : Js.Unsafe.any =
        Js.Unsafe.get activity_list "childNodes"
      in
      let length : int = Js.Unsafe.get child_nodes "length" in
      length > 8
    do
      let child : Dom.node Js.t = Js.Unsafe.get activity_list "firstChild" in
      Dom.removeChild (Js.Unsafe.coerce activity_list) child
    done
  in

  let create_tool id name input =
    let card = create "div" "tool-card" in
    let top = create "div" "tool-top" in
    let identity = create "div" "tool-name" in
    append identity (create_text "span" "tool-glyph" "⌘");
    append identity (create_text "b" "" name);
    let state = create_text "span" "tool-state" "Running" in
    append top identity;
    append top state;
    append card top;
    append card (create_text "div" "tool-input" input);
    let track = create "div" "progress-track" in
    let progress = create "span" "" in
    append track progress;
    append card track;
    let detail = create_text "div" "tool-detail" "Starting tool…" in
    append card detail;
    append tool_list card;
    let view = { card; state; detail; progress } in
    Hashtbl.replace tool_views id view;
    view
  in

  let update_tool id progress detail =
    match Hashtbl.find_opt tool_views id with
    | None -> ()
    | Some view ->
        Js.Unsafe.set view.progress "style"
          (Js.string
             ("width:" ^ string_of_int (max 0 (min 100 progress)) ^ "%"));
        set_text view.detail detail;
        set_text view.state (string_of_int progress ^ "%")
  in

  let finish_tool id summary success =
    match Hashtbl.find_opt tool_views id with
    | None -> ()
    | Some view ->
        set_class view.card
          (if success then "tool-card success" else "tool-card failed");
        set_text view.state (if success then "Complete" else "Failed");
        set_text view.detail summary;
        Js.Unsafe.set view.progress "style" (Js.string "width:100%")
  in

  let add_artifact name kind summary =
    if not (List.mem name !artifact_names) then (
      artifact_names := name :: !artifact_names;
      set_hidden artifact_section false;
      let card = create "div" "artifact" in
      append card
        (create_text "div" "artifact-icon"
           (if String.ends_with ~suffix:".json" name then "{}" else "≡"));
      let copy = create "div" "" in
      append copy (create_text "b" "" name);
      append copy (create_text "small" "" (kind ^ " · " ^ summary));
      append card copy;
      append artifact_list card)
  in

  let update_usage (usage : Agent.usage) =
    set_text metric_input (string_of_int usage.input_tokens);
    set_text metric_output (string_of_int usage.output_tokens);
    set_text metric_cached (string_of_int usage.cached_tokens);
    set_text metric_cost (Printf.sprintf "$%.4f" usage.estimated_cost);
    set_text metric_time (Printf.sprintf "%.1fs" usage.elapsed);
    let percentage = min 100 (usage.output_tokens * 100 / 1200) in
    Js.Unsafe.set token_bar_fill "style"
      (Js.string ("width:" ^ string_of_int percentage ^ "%"))
  in

  let report_content () =
    let artifacts =
      match List.rev !artifact_names with
      | [] -> "- None\n"
      | names ->
          String.concat "" (List.map (fun name -> "- " ^ name ^ "\n") names)
    in
    "# Orbit Agent Studio run\n\n" ^ "- Session: "
    ^ Option.value !active_session ~default:"none"
    ^ "\n" ^ "- Lifecycle: " ^ !current_lifecycle ^ "\n" ^ "- Status: "
    ^ !current_status ^ "\n\n" ^ "## Request\n\n" ^ !current_prompt ^ "\n\n"
    ^ "## Response\n\n" ^ Buffer.contents transcript ^ "\n\n"
    ^ "## Artifacts\n\n" ^ artifacts
  in

  let reset_run_view () =
    follow_latest := true;
    set_hidden jump_latest true;
    Buffer.clear transcript;
    current_prompt := "";
    current_title := "Agent workspace";
    current_status := "Ready";
    artifact_names := [];
    active_approval := None;
    Hashtbl.clear tool_views;
    clear output;
    clear plan_list;
    clear activity_list;
    clear tool_list;
    clear artifact_list;
    set_hidden plan_card true;
    set_hidden activity_card true;
    set_hidden answer_card true;
    set_hidden approval_card true;
    set_hidden artifact_section true;
    set_hidden terminal_card true;
    set_hidden run_controls false;
    set_hidden pause_run false;
    set_hidden resume_run true;
    set_hidden cursor false;
    set_class terminal_card "terminal-card";
    set_class streaming_indicator "streaming-indicator";
    set_text answer_word_count "0 words";
    set_text checkpoint_value "—";
    set_text sequence_value "0";
    List.iter
      (fun phase -> set_class (element (phase_id phase)) "phase")
      phase_all
  in

  let show_new_run () =
    Option.iter Client.unsubscribe !active_subscription;
    active_subscription := None;
    active_stream := None;
    active_session := None;
    reset_run_view ();
    set_hidden welcome false;
    set_hidden run_view true;
    set_hidden run_controls true;
    set_lifecycle "idle" "Ready";
    set_text run_title "Agent workspace";
    set_text session_short "No active session";
    set_disabled open_inspector true;
    set_disabled copy_output true;
    set_disabled export_report true;
    set_disabled send_instruction true;
    Js.Unsafe.meth_call prompt_input "focus" [||] |> ignore
  in

  let command_error context = function
    | Ok () -> ()
    | Error error -> show_toast (context ^ ": " ^ error_message error)
  in

  let send_command command =
    match !active_stream with
    | None -> show_toast "No active run"
    | Some stream ->
        ignore
          (Promise.map
             (command_error "Command rejected")
             (Client.Stream.send stream command))
  in

  let render_event event =
    (match event with
    | Agent.Run_started { title; prompt; workspace; model; mode } ->
        current_title := title;
        current_prompt := prompt;
        set_text run_title title;
        set_text prompt_display prompt;
        set_text workspace_name workspace;
        set_text model_label (model ^ " · " ^ mode_name mode);
        set_hidden welcome true;
        set_hidden run_view false;
        set_hidden run_controls false;
        set_lifecycle "running" "Running";
        set_disabled open_inspector inspector;
        set_disabled send_instruction false;
        if autoplay then (
          Js.Unsafe.meth_call Dom_html.window "setTimeout"
            [|
              Js.Unsafe.inject
                (Js.wrap_callback (fun () ->
                     Js.Unsafe.meth_call pause_run "click" [||] |> ignore));
              Js.Unsafe.inject 450;
            |]
          |> ignore;
          Js.Unsafe.meth_call Dom_html.window "setTimeout"
            [|
              Js.Unsafe.inject
                (Js.wrap_callback (fun () ->
                     set_value instruction_input
                       "Prioritize the durable session and multi-window story.";
                     Js.Unsafe.meth_call send_instruction "click" [||] |> ignore));
              Js.Unsafe.inject 700;
            |]
          |> ignore;
          Js.Unsafe.meth_call Dom_html.window "setTimeout"
            [|
              Js.Unsafe.inject
                (Js.wrap_callback (fun () ->
                     Js.Unsafe.meth_call resume_run "click" [||] |> ignore));
              Js.Unsafe.inject 1050;
            |]
          |> ignore)
    | Agent.Phase_changed { phase; detail } ->
        set_phase phase detail;
        set_hidden plan_card false
    | Agent.Plan_updated steps ->
        clear plan_list;
        List.iter
          (fun step -> append plan_list (create_text "li" "" step))
          steps;
        set_hidden plan_card false
    | Agent.Text_delta delta ->
        Buffer.add_string transcript delta;
        set_text output (Buffer.contents transcript);
        set_text answer_word_count
          (string_of_int (word_count (Buffer.contents transcript)) ^ " words");
        set_hidden answer_card false;
        set_disabled copy_output false;
        set_disabled export_report false
    | Agent.Activity { title; detail } -> append_activity title detail
    | Agent.Tool_started { id; name; input } ->
        ignore (create_tool id name input)
    | Agent.Tool_progress { id; progress; detail } ->
        update_tool id progress detail
    | Agent.Tool_finished { id; summary; success; _ } ->
        finish_tool id summary success
    | Agent.Approval_requested { id; title; description; command; risk } ->
        active_approval := Some id;
        set_text approval_title title;
        set_text approval_description description;
        set_text approval_command command;
        set_text approval_risk
          ((match risk with
             | Low -> "Low risk"
             | Medium -> "Medium risk"
             | High -> "High risk")
          ^ " · approval required");
        set_class approval_risk
          ("risk-badge "
          ^ match risk with Low -> "low" | Medium -> "" | High -> "high");
        set_disabled approval_approve false;
        set_disabled approval_reject false;
        set_hidden approval_card false;
        current_status := "Waiting for approval";
        set_text status !current_status;
        if autoplay then
          Js.Unsafe.meth_call Dom_html.window "setTimeout"
            [|
              Js.Unsafe.inject
                (Js.wrap_callback (fun () ->
                     Js.Unsafe.meth_call approval_approve "click" [||] |> ignore));
              Js.Unsafe.inject 350;
            |]
          |> ignore
    | Agent.Approval_resolved { approved; actor; _ } ->
        active_approval := None;
        set_hidden approval_card true;
        show_toast
          ((if approved then "Action approved" else "Action rejected")
          ^ " · " ^ actor)
    | Agent.Usage_updated usage -> update_usage usage
    | Agent.Artifact_created { name; kind; summary } ->
        add_artifact name kind summary
    | Agent.Checkpoint_saved checkpoint -> set_text checkpoint_value checkpoint
    | Agent.Instruction_received instruction ->
        append_activity "Instruction accepted" instruction;
        show_toast "The active run incorporated your instruction"
    | Agent.Status message ->
        current_status := message;
        set_text status message);
    update_sequence ();
    scroll_bottom ()
  in

  let render_terminal = function
    | Ok (Agent.Completed { summary; output_tokens; tools_used; elapsed }) ->
        set_lifecycle "completed" "Completed";
        set_class streaming_indicator "streaming-indicator done";
        set_text streaming_indicator "✓ Complete";
        set_text terminal_title "Run completed successfully";
        set_text terminal_detail
          (Printf.sprintf "%s · %d output tokens · %d tools · %.1fs" summary
             output_tokens tools_used elapsed);
        set_hidden terminal_card false;
        set_hidden cursor true;
        set_hidden run_controls true;
        set_disabled send_instruction true;
        current_status := "Completed";
        set_disabled copy_output false;
        set_disabled export_report false
    | Ok (Agent.Cancelled { reason; elapsed }) ->
        set_lifecycle "cancelled" "Cancelled";
        set_class streaming_indicator "streaming-indicator done";
        set_text streaming_indicator "Stopped";
        set_class terminal_card "terminal-card cancelled";
        set_text terminal_title "Run stopped";
        set_text terminal_detail (Printf.sprintf "%s · %.1fs" reason elapsed);
        set_hidden terminal_card false;
        set_hidden cursor true;
        set_hidden run_controls true;
        set_disabled send_instruction true;
        current_status := "Cancelled"
    | Error (error : Owebview_protocol.Rpc_error.t) ->
        let state =
          if error.code = "cancelled" then "cancelled" else "failed"
        in
        set_lifecycle state
          (if state = "cancelled" then "Cancelled" else "Failed");
        set_class terminal_card "terminal-card cancelled";
        set_text terminal_title
          (if state = "cancelled" then "Run cancelled" else "Run failed");
        set_text terminal_detail (error_message error);
        set_hidden terminal_card false;
        set_hidden cursor true;
        set_hidden run_controls true;
        set_disabled send_instruction true;
        current_status := error_message error
  in

  let rec refresh_history () =
    ignore
      (Promise.map
         (function
           | Error error ->
               clear history;
               append history
                 (create_text "div" "history-empty"
                    ("History unavailable: " ^ error_message error))
           | Ok sessions ->
               let sessions =
                 List.sort
                   (fun (left : Client.Durable_session.summary) right ->
                     Float.compare right.updated_at left.updated_at)
                   sessions
               in
               history_cache := sessions;
               clear history;
               set_text session_count (string_of_int (List.length sessions));
               if sessions = [] then
                 append history
                   (create_text "div" "history-empty"
                      "Runs will remain here across reloads and process \
                       restarts.")
               else List.iter render_history_row sessions)
         (Client.Durable_session.list client))
  and render_history_row (summary : Client.Durable_session.summary) =
    let active = Some summary.id = !active_session in
    let row = create "div" ("history-row" ^ if active then " active" else "") in
    let title =
      if summary.endpoint = "agent.run" then
        "Agent run · " ^ short_id summary.id
      else summary.endpoint
    in
    append row (create_text "div" "history-title" title);
    let meta = create "div" "history-meta" in
    append meta
      (create "span" ("history-state " ^ lifecycle_name summary.lifecycle));
    append meta
      (create_text "span" ""
         (lifecycle_label summary.lifecycle
         ^ " · "
         ^ Int64.to_string summary.latest_sequence
         ^ " events"));
    append row meta;
    Js.Unsafe.set row "onclick"
      (Dom_html.handler (fun _ ->
           attach_session summary.id;
           Js._false));
    if summary.lifecycle = Interrupted then (
      let retry = create_text "button" "retry-mini" "↻ Retry interrupted run" in
      Js.Unsafe.set retry "onclick"
        (Dom_html.handler (fun event ->
             Js.Unsafe.meth_call event "stopPropagation" [||] |> ignore;
             retry_session summary.id;
             Js._false));
      append row retry);
    append history row
  and render_stream stream =
    Option.iter Client.unsubscribe !active_subscription;
    active_stream := Some stream;
    active_session := Some (Client.Stream.id stream);
    reset_run_view ();
    set_hidden welcome true;
    set_hidden run_view false;
    set_text session_short (short_id (Client.Stream.id stream));
    set_disabled open_inspector inspector;
    let subscription = Client.Stream.on_event stream render_event in
    active_subscription := Some subscription;
    ignore
      (Promise.map
         (fun result ->
           render_terminal result;
           refresh_history ();
           scroll_bottom ())
         (Client.Stream.finished stream));
    refresh_history ()
  and detach_active continuation =
    Option.iter Client.unsubscribe !active_subscription;
    active_subscription := None;
    match !active_stream with
    | None -> continuation ()
    | Some stream ->
        active_stream := None;
        ignore
          (Promise.map (fun _ -> continuation ()) (Client.Stream.detach stream))
  and attach_session session_id =
    if Some session_id = !active_session then ()
    else
      detach_active (fun () ->
          set_text status "Replaying durable history…";
          ignore
            (Promise.map
               (function
                 | Ok stream -> render_stream stream
                 | Error error ->
                     show_toast ("Could not attach: " ^ error_message error))
               (Client.Stream.attach client Agent.run ~stream_id:session_id
                  ~after_sequence:0L)))
  and retry_session session_id =
    set_text status "Starting a new run from the interrupted request…";
    ignore
      (Promise.map
         (function
           | Error error -> show_toast ("Retry failed: " ^ error_message error)
           | Ok new_session_id ->
               refresh_history ();
               attach_session new_session_id)
         (Client.Rpc.call client Agent.retry session_id))
  in

  let start_run () =
    let prompt = String.trim (value prompt_input) in
    if prompt = "" then show_toast "Enter a request for the agent"
    else
      let request =
        Agent.
          {
            prompt;
            workspace = "owebview";
            model = value model_select;
            mode = ui_mode_of_string (value mode_select);
          }
      in
      set_disabled send_prompt true;
      detach_active (fun () ->
          reset_run_view ();
          set_hidden welcome true;
          set_hidden run_view false;
          set_text prompt_display prompt;
          set_text run_title
            (if String.length prompt > 52 then String.sub prompt 0 51 ^ "…"
             else prompt);
          set_lifecycle "running" "Starting";
          set_text status "Opening a durable agent session…";
          ignore
            (Promise.map
               (function
                 | Error error ->
                     set_disabled send_prompt false;
                     show_toast ("Could not start run: " ^ error_message error)
                 | Ok stream ->
                     set_disabled send_prompt false;
                     render_stream stream;
                     if autoplay then
                       Js.Unsafe.meth_call Dom_html.window "setTimeout"
                         [|
                           Js.Unsafe.inject
                             (Js.wrap_callback (fun () ->
                                  Js.Unsafe.meth_call open_inspector "click" [||]
                                  |> ignore));
                           Js.Unsafe.inject 1400;
                         |]
                       |> ignore)
               (Client.Stream.open_ client Agent.run request)))
  in

  let inspect_active () =
    match !active_session with
    | None -> show_toast "Open or start a run first"
    | Some session_id ->
        set_disabled open_inspector true;
        ignore
          (Promise.map
             (function
               | Ok () ->
                   set_disabled open_inspector inspector;
                   show_toast "Inspector window attached"
               | Error error ->
                   set_disabled open_inspector false;
                   show_toast
                     ("Could not open inspector: " ^ error_message error))
             (Client.Rpc.call client Agent.open_inspector session_id))
  in

  let send_approval approved =
    match (!active_stream, !active_approval) with
    | Some stream, Some approval_id ->
        set_disabled approval_approve true;
        set_disabled approval_reject true;
        let command =
          if approved then Agent.Approve approval_id
          else Agent.Reject approval_id
        in
        let command_id =
          "approval-" ^ Client.Stream.id stream ^ "-" ^ approval_id
        in
        ignore
          (Promise.map
             (function
               | Ok () -> set_text status "Approval command admitted durably"
               | Error error ->
                   set_disabled approval_approve false;
                   set_disabled approval_reject false;
                   show_toast ("Approval failed: " ^ error_message error))
             (Client.Stream.send_with_id stream ~command_id command))
    | _ -> show_toast "There is no pending approval"
  in

  let send_live_instruction () =
    let instruction = String.trim (value instruction_input) in
    if instruction = "" then show_toast "Enter guidance for the active run"
    else (
      set_value instruction_input "";
      send_command (Agent.Add_instruction instruction))
  in

  let copy_transcript () =
    let content = Buffer.contents transcript in
    if content = "" then show_toast "There is no response to copy yet"
    else
      ignore
        (Promise.map
           (function
             | Ok () ->
                 show_toast "Transcript copied with the native clipboard API"
             | Error error -> show_toast ("Copy failed: " ^ error_message error))
           (Client.Rpc.call client Agent.copy_text content))
  in

  let export_current_report () =
    let suggested_name =
      "orbit-run-"
      ^ (match !active_session with None -> "report" | Some id -> short_id id)
      ^ ".md"
    in
    ignore
      (Promise.map
         (function
           | Ok None -> show_toast "Export cancelled"
           | Ok (Some path) -> show_toast ("Report saved to " ^ path)
           | Error error -> show_toast ("Export failed: " ^ error_message error))
         (Client.Rpc.call client Agent.save_report
            Agent.{ suggested_name; content = report_content () }))
  in

  Js.Unsafe.set send_prompt "onclick"
    (Dom_html.handler (fun _ ->
         start_run ();
         Js._false));
  Js.Unsafe.set prompt_input "onkeydown"
    (Dom_html.handler (fun event ->
         let key : Js.js_string Js.t = Js.Unsafe.get event "key" in
         let shift : bool = Js.to_bool (Js.Unsafe.get event "shiftKey") in
         if Js.to_string key = "Enter" && not shift then (
           Js.Unsafe.meth_call event "preventDefault" [||] |> ignore;
           start_run ());
         Js._true));
  Js.Unsafe.set new_run "onclick"
    (Dom_html.handler (fun _ ->
         detach_active show_new_run;
         Js._false));
  Js.Unsafe.set open_inspector "onclick"
    (Dom_html.handler (fun _ ->
         inspect_active ();
         Js._false));
  Js.Unsafe.set approval_approve "onclick"
    (Dom_html.handler (fun _ ->
         send_approval true;
         Js._false));
  Js.Unsafe.set approval_reject "onclick"
    (Dom_html.handler (fun _ ->
         send_approval false;
         Js._false));
  Js.Unsafe.set pause_run "onclick"
    (Dom_html.handler (fun _ ->
         send_command Agent.Pause;
         set_hidden pause_run true;
         set_hidden resume_run false;
         Js._false));
  Js.Unsafe.set resume_run "onclick"
    (Dom_html.handler (fun _ ->
         send_command Agent.Resume;
         set_hidden pause_run false;
         set_hidden resume_run true;
         Js._false));
  Js.Unsafe.set cancel_run "onclick"
    (Dom_html.handler (fun _ ->
         send_command Agent.Cancel;
         set_text status "Stopping the active run…";
         Js._false));
  Js.Unsafe.set send_instruction "onclick"
    (Dom_html.handler (fun _ ->
         send_live_instruction ();
         Js._false));
  Js.Unsafe.set copy_output "onclick"
    (Dom_html.handler (fun _ ->
         copy_transcript ();
         Js._false));
  Js.Unsafe.set export_report "onclick"
    (Dom_html.handler (fun _ ->
         export_current_report ();
         Js._false));
  Js.Unsafe.set scroll_region "onscroll"
    (Dom_html.handler (fun _ ->
         let scroll_top : float = Js.Unsafe.get scroll_region "scrollTop" in
         let client_height : float =
           Js.Unsafe.get scroll_region "clientHeight"
         in
         let scroll_height : float =
           Js.Unsafe.get scroll_region "scrollHeight"
         in
         follow_latest := scroll_top +. client_height >= scroll_height -. 72.;
         set_hidden jump_latest !follow_latest;
         Js._true));
  Js.Unsafe.set jump_latest "onclick"
    (Dom_html.handler (fun _ ->
         jump_to_latest ();
         Js._false));

  let presets : Js.Unsafe.any =
    Js.Unsafe.meth_call Dom_html.document "querySelectorAll"
      [| Js.Unsafe.inject (Js.string ".preset") |]
  in
  let preset_count : int = Js.Unsafe.get presets "length" in
  for index = 0 to preset_count - 1 do
    let preset : Dom_html.element Js.t =
      Js.Unsafe.meth_call presets "item" [| Js.Unsafe.inject index |]
    in
    Js.Unsafe.set preset "onclick"
      (Dom_html.handler (fun _ ->
           let prompt : Js.js_string Js.t =
             Js.Unsafe.meth_call preset "getAttribute"
               [| Js.Unsafe.inject (Js.string "data-prompt") |]
           in
           set_value prompt_input (Js.to_string prompt);
           start_run ();
           Js._false))
  done;

  let ready =
    Promise.bind
      (function
        | Error error ->
            set_connection false "Handshake failed";
            set_text status ("Handshake failed: " ^ error_message error);
            Promise.resolve ()
        | Ok () ->
            set_connection true "Connected";
            let platform =
              Promise.map
                (function
                  | Error error ->
                      set_text platform_backend
                        ("Unavailable: " ^ error_message error)
                  | Ok (info : Agent.platform_info) ->
                      set_text platform_backend
                        (info.backend ^ " · " ^ info.validation);
                      set_text backend_label info.backend;
                      clear capability_list;
                      List.iter
                        (fun capability ->
                          append capability_list
                            (create_text "span" "capability" capability))
                        info.capabilities)
                (Client.Rpc.call client Agent.platform_info ())
            in
            ignore platform;
            Promise.map
              (function
                | Error error ->
                    set_text status ("History failed: " ^ error_message error)
                | Ok sessions -> (
                    history_cache := sessions;
                    refresh_history ();
                    match bootstrap_session with
                    | Some session_id -> attach_session session_id
                    | None -> (
                        match
                          List.sort
                            (fun (left : Client.Durable_session.summary) right
                               ->
                              Float.compare right.updated_at left.updated_at)
                            sessions
                          |> List.find_opt
                               (fun
                                 (summary : Client.Durable_session.summary) ->
                                 summary.lifecycle = Running
                                 || summary.lifecycle = Recovering)
                        with
                        | Some summary -> attach_session summary.id
                        | None ->
                            show_new_run ();
                            if autoplay then start_run ())))
              (Client.Durable_session.list client))
      (Client.ready ~frontend_build_id:"orbit-agent-studio-2"
         ~application_version:"0.1.0-demo"
         ~capabilities:[ "rpc"; "streams"; "durable-sessions"; "multi-window" ]
         client)
  in
  ignore ready
