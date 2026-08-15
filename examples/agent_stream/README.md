# Orbit Agent Studio

This example is the full-stack showcase for owebview's intended application
architecture. It is a polished native desktop agent workspace implemented with:

- an OCaml 5/Eio backend;
- a js_of_ocaml frontend using JavaScript Promises without Lwt;
- shared typed request, event, command, result, and RPC definitions;
- secure embedded assets served from a tokenized loopback origin;
- application-owned durable sessions shared by multiple native windows.

The agent is deliberately simulated, so the example is self-contained and does
not require an API key or network service. Its runtime behavior mirrors the
shape expected from a real orchestration framework.

## Run it

Build the native backend and js_of_ocaml bundle:

```sh
dune build examples/agent_stream/backend.exe \
  examples/agent_stream/frontend.bc.js
```

Launch the application:

```sh
dune exec examples/agent_stream/backend.exe -- \
  _build/default/examples/agent_stream/frontend.bc.js
```

Session snapshots are stored in `.owebview-agent-sessions` by default. Use an
isolated directory with:

```sh
OWEBVIEW_SESSION_DIR=/path/to/sessions \
  dune exec examples/agent_stream/backend.exe -- \
  _build/default/examples/agent_stream/frontend.bc.js
```

## What the demonstration exercises

### Typed agent workflow

A run has a typed request containing prompt, workspace, model, and execution
mode. The backend streams structured events for:

- run metadata and four execution phases;
- a live plan and application-safe activity descriptions;
- tool start, progress, completion, duration, and failure state;
- token, cache, elapsed-time, and estimated-cost metrics;
- a human approval request and durable resolution;
- live user instructions;
- generated artifacts and durable checkpoints;
- incremental answer text and a typed terminal summary.

The UI intentionally presents structured activity rather than private model
chain-of-thought.

### Realtime control

While the simulation is running, the frontend can:

- pause and resume the orchestration fiber;
- add a live instruction that changes the final response;
- cancel cleanly with a typed terminal result;
- approve or reject the proposed workspace action;
- open an inspector window at any point in the run.

Commands are bounded and durably admitted before the backend applies them. The
approval uses one stable command ID derived from the session and approval IDs.
If two windows make the same decision, it is admitted once; conflicting reuse
of that ID is rejected.

### Multi-window behavior

The conversation and inspector windows attach to one stable durable session.
Each receives an independent bounded delivery queue, batching fiber, replay,
and acknowledgement cursor. The inspector can open halfway through execution
and reconstruct the complete UI from persisted events before receiving live
updates.

Close the inspector and use **Open inspector** to attach another native window.
The agent continues independently of either inspector window. Subscriber IDs
are restricted to the conversation and generated inspector identities through
the registry's authorization callback.

### Desktop application features

The example also demonstrates:

- a responsive native application shell with an embedded asset bundle;
- native backend and capability reporting;
- native clipboard writing through **Copy**;
- a native save dialog through **Export**;
- trusted console forwarding;
- deny-by-default permission and download policies;
- native navigation policy and trusted-origin transport checks.

### Persistence and process restart

The session history sidebar lists retained runs. Completed runs can be reopened
and replayed after restarting the entire native process. A run that was active
when the process stopped is restored as `Interrupted`; **Retry interrupted run**
starts a new session from its persisted typed request while retaining the old
partial history.

The backend records an opaque checkpoint containing a simulated external run
ID, phase, and progress. This demonstrates where a real agent orchestrator can
store its continuation reference. It does not claim that an Eio fiber, network
response, JavaScript Promise, or arbitrary external side effect survives a
process exit.

## Deterministic showcase mode

For local visual testing, the opt-in autoplay mode starts the default prompt,
pauses, sends an instruction, resumes, opens an inspector, and approves the
workspace action:

```sh
OWEBVIEW_DEMO_AUTOPLAY=1 \
  dune exec examples/agent_stream/backend.exe -- \
  _build/default/examples/agent_stream/frontend.bc.js
```

Normal launches remain fully interactive. `OWEBVIEW_DEMO_SESSION_ID` can be set
to a retained session ID when testing direct replay after process restart.
Set `OWEBVIEW_DEMO_AUTOPLAY_EXPORT=1` alongside autoplay to invoke the Export
button after the deterministic run completes. This is useful for native dialog
regression testing and has no effect during normal launches.
`OWEBVIEW_DEMO_AUTOPLAY_FULLSCREEN=1` similarly enters and exits native
fullscreen after the run for Cocoa window-transition regression testing.

## Source layout

- `protocol.ml`: pure shared types and codecs compiled natively and to
  JavaScript.
- `backend.ml`: Eio orchestration simulation, durable registry, native windows,
  RPC handlers, security policies, clipboard, and export support.
- `frontend.ml`: Promise-based browser state machine and durable replay UI.
- `demo_assets.ml`: embedded HTML and CSS application shell.
- `protocol_test.ml`: codec roundtrip coverage for every public demo message.
