module Agent = Agent_protocol.Protocol
module Wire = Owebview_protocol

let roundtrip name codec value =
  let encoded = Wire.Codec.encode codec value in
  match Wire.Codec.decode codec encoded with
  | Ok decoded when decoded = value -> ()
  | Ok _ -> failwith (name ^ " changed during codec roundtrip")
  | Error message -> failwith (name ^ " failed to decode: " ^ message)

let () =
  roundtrip "run request" Agent.run_request_codec
    Agent.
      {
        prompt = "Review the runtime";
        workspace = "owebview";
        model = "orbit-sim-pro";
        mode = Deep;
      };
  List.iter
    (roundtrip "event" Agent.event_codec)
    Agent.
      [
        Run_started
          {
            title = "Review";
            prompt = "Review the runtime";
            workspace = "owebview";
            model = "orbit-sim-1";
            mode = Balanced;
          };
        Phase_changed { phase = Research; detail = "Inspecting" };
        Plan_updated [ "Map modules"; "Validate claims" ];
        Text_delta "Streaming text";
        Activity { title = "Mapped"; detail = "Five libraries" };
        Tool_started { id = "tool-1"; name = "search"; input = "lib/" };
        Tool_progress { id = "tool-1"; progress = 50; detail = "Halfway" };
        Tool_finished
          { id = "tool-1"; summary = "Done"; duration = 0.5; success = true };
        Approval_requested
          {
            id = "approval-1";
            title = "Create report";
            description = "Stage a local artifact";
            command = "generate report";
            risk = Medium;
          };
        Approval_resolved
          { id = "approval-1"; approved = true; actor = "conversation" };
        Usage_updated
          {
            input_tokens = 100;
            output_tokens = 42;
            cached_tokens = 12;
            estimated_cost = 0.001;
            elapsed = 1.2;
          };
        Artifact_created
          { name = "report.md"; kind = "Markdown"; summary = "Findings" };
        Checkpoint_saved "review · 100%";
        Instruction_received "Prioritize durability";
        Status "Complete";
      ];
  List.iter
    (roundtrip "command" Agent.command_codec)
    Agent.
      [
        Approve "approval-1";
        Reject "approval-2";
        Pause;
        Resume;
        Cancel;
        Add_instruction "Focus on multi-window behavior";
      ];
  List.iter
    (roundtrip "result" Agent.result_codec)
    Agent.
      [
        Completed
          {
            summary = "Complete";
            output_tokens = 220;
            tools_used = 3;
            elapsed = 4.2;
          };
        Cancelled { reason = "Stopped"; elapsed = 1.8 };
      ];
  roundtrip "platform info" Agent.platform_info_codec
    Agent.
      {
        backend = "cocoa-webkit";
        validation = "validated";
        capabilities = [ "multiple windows"; "native dialogs" ];
        session_directory = "/tmp/sessions";
      };
  roundtrip "save report" Agent.save_report_codec
    Agent.{ suggested_name = "report.md"; content = "# Report" }
