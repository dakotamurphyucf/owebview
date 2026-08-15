module Wire = Owebview_protocol

type run_mode = Fast | Balanced | Deep

type run_request = {
  prompt : string;
  workspace : string;
  model : string;
  mode : run_mode;
}

type phase = Planning | Research | Execution | Review
type risk = Low | Medium | High

type usage = {
  input_tokens : int;
  output_tokens : int;
  cached_tokens : int;
  estimated_cost : float;
  elapsed : float;
}

type event =
  | Run_started of {
      title : string;
      prompt : string;
      workspace : string;
      model : string;
      mode : run_mode;
    }
  | Phase_changed of { phase : phase; detail : string }
  | Plan_updated of string list
  | Text_delta of string
  | Activity of { title : string; detail : string }
  | Tool_started of { id : string; name : string; input : string }
  | Tool_progress of { id : string; progress : int; detail : string }
  | Tool_finished of {
      id : string;
      summary : string;
      duration : float;
      success : bool;
    }
  | Approval_requested of {
      id : string;
      title : string;
      description : string;
      command : string;
      risk : risk;
    }
  | Approval_resolved of { id : string; approved : bool; actor : string }
  | Usage_updated of usage
  | Artifact_created of { name : string; kind : string; summary : string }
  | Checkpoint_saved of string
  | Instruction_received of string
  | Status of string

type command =
  | Approve of string
  | Reject of string
  | Pause
  | Resume
  | Cancel
  | Add_instruction of string

type result =
  | Completed of {
      summary : string;
      output_tokens : int;
      tools_used : int;
      elapsed : float;
    }
  | Cancelled of { reason : string; elapsed : float }

type platform_info = {
  backend : string;
  validation : string;
  capabilities : string list;
  session_directory : string;
}

type save_report_request = { suggested_name : string; content : string }

let tagged tag fields = `Assoc (("tag", `String tag) :: fields)

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field: " ^ name)

let decode_field codec name fields =
  match field name fields with
  | Error _ as error -> error
  | Ok value -> Wire.Codec.decode codec value

let decode_string name fields = decode_field Wire.Codec.string name fields
let decode_int name fields = decode_field Wire.Codec.int name fields
let decode_float name fields = decode_field Wire.Codec.float name fields
let decode_bool name fields = decode_field Wire.Codec.bool name fields

let mode_name = function
  | Fast -> "fast"
  | Balanced -> "balanced"
  | Deep -> "deep"

let mode_of_string = function
  | "fast" -> Ok Fast
  | "balanced" -> Ok Balanced
  | "deep" -> Ok Deep
  | _ -> Error "invalid agent run mode"

let mode_codec =
  Wire.Codec.make
    ~encode:(fun mode -> `String (mode_name mode))
    ~decode:(function
      | `String value -> mode_of_string value
      | _ -> Error "expected an agent run mode")

let phase_name = function
  | Planning -> "planning"
  | Research -> "research"
  | Execution -> "execution"
  | Review -> "review"

let phase_of_string = function
  | "planning" -> Ok Planning
  | "research" -> Ok Research
  | "execution" -> Ok Execution
  | "review" -> Ok Review
  | _ -> Error "invalid agent phase"

let phase_codec =
  Wire.Codec.make
    ~encode:(fun phase -> `String (phase_name phase))
    ~decode:(function
      | `String value -> phase_of_string value
      | _ -> Error "expected an agent phase")

let risk_name = function Low -> "low" | Medium -> "medium" | High -> "high"

let risk_of_string = function
  | "low" -> Ok Low
  | "medium" -> Ok Medium
  | "high" -> Ok High
  | _ -> Error "invalid approval risk"

let risk_codec =
  Wire.Codec.make
    ~encode:(fun risk -> `String (risk_name risk))
    ~decode:(function
      | `String value -> risk_of_string value
      | _ -> Error "expected an approval risk")

let run_request_codec =
  Wire.Codec.make
    ~encode:(fun request ->
      `Assoc
        [
          ("prompt", `String request.prompt);
          ("workspace", `String request.workspace);
          ("model", `String request.model);
          ("mode", Wire.Codec.encode mode_codec request.mode);
        ])
    ~decode:(function
      | `Assoc fields -> (
          match
            ( decode_string "prompt" fields,
              decode_string "workspace" fields,
              decode_string "model" fields,
              decode_field mode_codec "mode" fields )
          with
          | Ok prompt, Ok workspace, Ok model, Ok mode ->
              Ok { prompt; workspace; model; mode }
          | Error message, _, _, _
          | _, Error message, _, _
          | _, _, Error message, _
          | _, _, _, Error message ->
              Error message)
      | _ -> Error "expected an agent run request")

let usage_fields usage =
  [
    ("input_tokens", `Int usage.input_tokens);
    ("output_tokens", `Int usage.output_tokens);
    ("cached_tokens", `Int usage.cached_tokens);
    ("estimated_cost", `Float usage.estimated_cost);
    ("elapsed", `Float usage.elapsed);
  ]

let decode_usage fields =
  match
    ( decode_int "input_tokens" fields,
      decode_int "output_tokens" fields,
      decode_int "cached_tokens" fields,
      decode_float "estimated_cost" fields,
      decode_float "elapsed" fields )
  with
  | ( Ok input_tokens,
      Ok output_tokens,
      Ok cached_tokens,
      Ok estimated_cost,
      Ok elapsed ) ->
      Ok { input_tokens; output_tokens; cached_tokens; estimated_cost; elapsed }
  | Error message, _, _, _, _
  | _, Error message, _, _, _
  | _, _, Error message, _, _
  | _, _, _, Error message, _
  | _, _, _, _, Error message ->
      Error message

let event_codec =
  Wire.Codec.make
    ~encode:(function
      | Run_started { title; prompt; workspace; model; mode } ->
          tagged "run_started"
            [
              ("title", `String title);
              ("prompt", `String prompt);
              ("workspace", `String workspace);
              ("model", `String model);
              ("mode", Wire.Codec.encode mode_codec mode);
            ]
      | Phase_changed { phase; detail } ->
          tagged "phase_changed"
            [
              ("phase", Wire.Codec.encode phase_codec phase);
              ("detail", `String detail);
            ]
      | Plan_updated steps ->
          tagged "plan_updated"
            [
              ( "steps",
                Wire.Codec.encode (Wire.Codec.list Wire.Codec.string) steps );
            ]
      | Text_delta text -> tagged "text_delta" [ ("text", `String text) ]
      | Activity { title; detail } ->
          tagged "activity"
            [ ("title", `String title); ("detail", `String detail) ]
      | Tool_started { id; name; input } ->
          tagged "tool_started"
            [
              ("id", `String id);
              ("name", `String name);
              ("input", `String input);
            ]
      | Tool_progress { id; progress; detail } ->
          tagged "tool_progress"
            [
              ("id", `String id);
              ("progress", `Int progress);
              ("detail", `String detail);
            ]
      | Tool_finished { id; summary; duration; success } ->
          tagged "tool_finished"
            [
              ("id", `String id);
              ("summary", `String summary);
              ("duration", `Float duration);
              ("success", `Bool success);
            ]
      | Approval_requested { id; title; description; command; risk } ->
          tagged "approval_requested"
            [
              ("id", `String id);
              ("title", `String title);
              ("description", `String description);
              ("command", `String command);
              ("risk", Wire.Codec.encode risk_codec risk);
            ]
      | Approval_resolved { id; approved; actor } ->
          tagged "approval_resolved"
            [
              ("id", `String id);
              ("approved", `Bool approved);
              ("actor", `String actor);
            ]
      | Usage_updated usage -> tagged "usage_updated" (usage_fields usage)
      | Artifact_created { name; kind; summary } ->
          tagged "artifact_created"
            [
              ("name", `String name);
              ("kind", `String kind);
              ("summary", `String summary);
            ]
      | Checkpoint_saved checkpoint ->
          tagged "checkpoint_saved" [ ("checkpoint", `String checkpoint) ]
      | Instruction_received instruction ->
          tagged "instruction_received" [ ("instruction", `String instruction) ]
      | Status status -> tagged "status" [ ("status", `String status) ])
    ~decode:(function
      | `Assoc fields -> (
          match decode_string "tag" fields with
          | Error _ as error -> error
          | Ok "run_started" -> (
              match
                ( decode_string "title" fields,
                  decode_string "prompt" fields,
                  decode_string "workspace" fields,
                  decode_string "model" fields,
                  decode_field mode_codec "mode" fields )
              with
              | Ok title, Ok prompt, Ok workspace, Ok model, Ok mode ->
                  Ok (Run_started { title; prompt; workspace; model; mode })
              | Error message, _, _, _, _
              | _, Error message, _, _, _
              | _, _, Error message, _, _
              | _, _, _, Error message, _
              | _, _, _, _, Error message ->
                  Error message)
          | Ok "phase_changed" -> (
              match
                ( decode_field phase_codec "phase" fields,
                  decode_string "detail" fields )
              with
              | Ok phase, Ok detail -> Ok (Phase_changed { phase; detail })
              | Error message, _ | _, Error message -> Error message)
          | Ok "plan_updated" -> (
              match
                decode_field (Wire.Codec.list Wire.Codec.string) "steps" fields
              with
              | Ok steps -> Ok (Plan_updated steps)
              | Error _ as error -> error)
          | Ok "text_delta" ->
              Result.map
                (fun text -> Text_delta text)
                (decode_string "text" fields)
          | Ok "activity" -> (
              match
                (decode_string "title" fields, decode_string "detail" fields)
              with
              | Ok title, Ok detail -> Ok (Activity { title; detail })
              | Error message, _ | _, Error message -> Error message)
          | Ok "tool_started" -> (
              match
                ( decode_string "id" fields,
                  decode_string "name" fields,
                  decode_string "input" fields )
              with
              | Ok id, Ok name, Ok input ->
                  Ok (Tool_started { id; name; input })
              | Error message, _, _ | _, Error message, _ | _, _, Error message
                ->
                  Error message)
          | Ok "tool_progress" -> (
              match
                ( decode_string "id" fields,
                  decode_int "progress" fields,
                  decode_string "detail" fields )
              with
              | Ok id, Ok progress, Ok detail ->
                  Ok (Tool_progress { id; progress; detail })
              | Error message, _, _ | _, Error message, _ | _, _, Error message
                ->
                  Error message)
          | Ok "tool_finished" -> (
              match
                ( decode_string "id" fields,
                  decode_string "summary" fields,
                  decode_float "duration" fields,
                  decode_bool "success" fields )
              with
              | Ok id, Ok summary, Ok duration, Ok success ->
                  Ok (Tool_finished { id; summary; duration; success })
              | Error message, _, _, _
              | _, Error message, _, _
              | _, _, Error message, _
              | _, _, _, Error message ->
                  Error message)
          | Ok "approval_requested" -> (
              match
                ( decode_string "id" fields,
                  decode_string "title" fields,
                  decode_string "description" fields,
                  decode_string "command" fields,
                  decode_field risk_codec "risk" fields )
              with
              | Ok id, Ok title, Ok description, Ok command, Ok risk ->
                  Ok
                    (Approval_requested
                       { id; title; description; command; risk })
              | Error message, _, _, _, _
              | _, Error message, _, _, _
              | _, _, Error message, _, _
              | _, _, _, Error message, _
              | _, _, _, _, Error message ->
                  Error message)
          | Ok "approval_resolved" -> (
              match
                ( decode_string "id" fields,
                  decode_bool "approved" fields,
                  decode_string "actor" fields )
              with
              | Ok id, Ok approved, Ok actor ->
                  Ok (Approval_resolved { id; approved; actor })
              | Error message, _, _ | _, Error message, _ | _, _, Error message
                ->
                  Error message)
          | Ok "usage_updated" ->
              Result.map
                (fun usage -> Usage_updated usage)
                (decode_usage fields)
          | Ok "artifact_created" -> (
              match
                ( decode_string "name" fields,
                  decode_string "kind" fields,
                  decode_string "summary" fields )
              with
              | Ok name, Ok kind, Ok summary ->
                  Ok (Artifact_created { name; kind; summary })
              | Error message, _, _ | _, Error message, _ | _, _, Error message
                ->
                  Error message)
          | Ok "checkpoint_saved" ->
              Result.map
                (fun value -> Checkpoint_saved value)
                (decode_string "checkpoint" fields)
          | Ok "instruction_received" ->
              Result.map
                (fun value -> Instruction_received value)
                (decode_string "instruction" fields)
          | Ok "status" ->
              Result.map
                (fun value -> Status value)
                (decode_string "status" fields)
          | Ok tag -> Error ("unknown agent event: " ^ tag))
      | _ -> Error "expected an agent event")

let command_codec =
  Wire.Codec.make
    ~encode:(function
      | Approve id -> tagged "approve" [ ("id", `String id) ]
      | Reject id -> tagged "reject" [ ("id", `String id) ]
      | Pause -> tagged "pause" []
      | Resume -> tagged "resume" []
      | Cancel -> tagged "cancel" []
      | Add_instruction instruction ->
          tagged "add_instruction" [ ("instruction", `String instruction) ])
    ~decode:(function
      | `Assoc fields -> (
          match decode_string "tag" fields with
          | Ok "approve" ->
              Result.map (fun id -> Approve id) (decode_string "id" fields)
          | Ok "reject" ->
              Result.map (fun id -> Reject id) (decode_string "id" fields)
          | Ok "pause" -> Ok Pause
          | Ok "resume" -> Ok Resume
          | Ok "cancel" -> Ok Cancel
          | Ok "add_instruction" ->
              Result.map
                (fun value -> Add_instruction value)
                (decode_string "instruction" fields)
          | Ok tag -> Error ("unknown agent command: " ^ tag)
          | Error _ as error -> error)
      | _ -> Error "expected an agent command")

let result_codec =
  Wire.Codec.make
    ~encode:(function
      | Completed { summary; output_tokens; tools_used; elapsed } ->
          tagged "completed"
            [
              ("summary", `String summary);
              ("output_tokens", `Int output_tokens);
              ("tools_used", `Int tools_used);
              ("elapsed", `Float elapsed);
            ]
      | Cancelled { reason; elapsed } ->
          tagged "cancelled"
            [ ("reason", `String reason); ("elapsed", `Float elapsed) ])
    ~decode:(function
      | `Assoc fields -> (
          match decode_string "tag" fields with
          | Ok "completed" -> (
              match
                ( decode_string "summary" fields,
                  decode_int "output_tokens" fields,
                  decode_int "tools_used" fields,
                  decode_float "elapsed" fields )
              with
              | Ok summary, Ok output_tokens, Ok tools_used, Ok elapsed ->
                  Ok (Completed { summary; output_tokens; tools_used; elapsed })
              | Error message, _, _, _
              | _, Error message, _, _
              | _, _, Error message, _
              | _, _, _, Error message ->
                  Error message)
          | Ok "cancelled" -> (
              match
                (decode_string "reason" fields, decode_float "elapsed" fields)
              with
              | Ok reason, Ok elapsed -> Ok (Cancelled { reason; elapsed })
              | Error message, _ | _, Error message -> Error message)
          | Ok tag -> Error ("unknown agent result: " ^ tag)
          | Error _ as error -> error)
      | _ -> Error "expected an agent result")

let platform_info_codec =
  Wire.Codec.make
    ~encode:(fun info ->
      `Assoc
        [
          ("backend", `String info.backend);
          ("validation", `String info.validation);
          ( "capabilities",
            Wire.Codec.encode
              (Wire.Codec.list Wire.Codec.string)
              info.capabilities );
          ("session_directory", `String info.session_directory);
        ])
    ~decode:(function
      | `Assoc fields -> (
          match
            ( decode_string "backend" fields,
              decode_string "validation" fields,
              decode_field
                (Wire.Codec.list Wire.Codec.string)
                "capabilities" fields,
              decode_string "session_directory" fields )
          with
          | Ok backend, Ok validation, Ok capabilities, Ok session_directory ->
              Ok { backend; validation; capabilities; session_directory }
          | Error message, _, _, _
          | _, Error message, _, _
          | _, _, Error message, _
          | _, _, _, Error message ->
              Error message)
      | _ -> Error "expected platform information")

let save_report_codec =
  Wire.Codec.make
    ~encode:(fun request ->
      `Assoc
        [
          ("suggested_name", `String request.suggested_name);
          ("content", `String request.content);
        ])
    ~decode:(function
      | `Assoc fields -> (
          match
            ( decode_string "suggested_name" fields,
              decode_string "content" fields )
          with
          | Ok suggested_name, Ok content -> Ok { suggested_name; content }
          | Error message, _ | _, Error message -> Error message)
      | _ -> Error "expected a report save request")

let run =
  Wire.Stream_endpoint.make ~name:"agent.run" ~request:run_request_codec
    ~event:event_codec ~command:command_codec ~result:result_codec

let open_inspector =
  Wire.Endpoint.make ~name:"agent.open_inspector" ~request:Wire.Codec.string
    ~response:Wire.Codec.unit

let retry =
  Wire.Endpoint.make ~name:"agent.retry" ~request:Wire.Codec.string
    ~response:Wire.Codec.string

let platform_info =
  Wire.Endpoint.make ~name:"app.platform_info" ~request:Wire.Codec.unit
    ~response:platform_info_codec

let copy_text =
  Wire.Endpoint.make ~name:"app.copy_text" ~request:Wire.Codec.string
    ~response:Wire.Codec.unit

let save_report =
  Wire.Endpoint.make ~name:"app.save_report" ~request:save_report_codec
    ~response:(Wire.Codec.option Wire.Codec.string)
