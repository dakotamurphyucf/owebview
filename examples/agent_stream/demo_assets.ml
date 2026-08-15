let index_html =
  {|
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="color-scheme" content="dark light">
  <title>Orbit Agent Studio</title>
  <link rel="stylesheet" href="app.css">
</head>
<body>
  <div class="ambient ambient-a"></div>
  <div class="ambient ambient-b"></div>
  <div id="app" class="app-shell">
    <aside class="sidebar">
      <div class="brand-row">
        <div class="brand-mark"><span></span><span></span><span></span></div>
        <div><strong>Orbit</strong><small>agent studio</small></div>
      </div>

      <button id="new-run" class="new-run-button">
        <span class="button-icon">+</span>
        <span>New agent run</span>
        <kbd>⌘N</kbd>
      </button>

      <div class="sidebar-label"><span>Durable sessions</span><span id="session-count">0</span></div>
      <div id="history" class="history-list" aria-live="polite" tabindex="0" aria-label="Durable session history"></div>

      <div class="sidebar-footer">
        <div class="native-badge"><span class="native-dot"></span><span id="backend-label">Native runtime</span></div>
        <div class="footer-copy">OCaml 5 · Eio · WebKit</div>
      </div>
    </aside>

    <main class="workspace">
      <header class="topbar">
        <div class="title-stack">
          <div class="eyebrow"><span id="window-role">Conversation</span><span>/</span><span id="workspace-name">owebview</span></div>
          <div class="run-title-row">
            <h1 id="run-title">Agent workspace</h1>
            <span id="lifecycle-badge" class="pill pill-idle"><span></span>Ready</span>
          </div>
        </div>
        <div class="top-actions">
          <div class="connection"><span id="connection-dot"></span><span id="connection-label">Connecting</span></div>
          <button id="copy-output" class="icon-button" title="Copy transcript" disabled>Copy</button>
          <button id="export-report" class="icon-button" title="Export report" disabled>Export</button>
          <button id="open-inspector" class="primary-button" disabled><span>Open inspector</span><span>↗</span></button>
        </div>
      </header>

      <div class="workspace-grid">
        <section class="conversation-pane">
          <div id="scroll-region" class="scroll-region" tabindex="0" aria-label="Agent conversation and activity">
            <section id="welcome" class="welcome-card">
              <div class="welcome-orbit"><span></span><span></span><span></span><i>O</i></div>
              <div class="welcome-kicker">LOCAL-FIRST AGENT RUNTIME</div>
              <h2>Watch an OCaml agent think in systems.</h2>
              <p>Durable streaming, typed commands, native windows, secure assets, replay, and process-restart recovery—all in one live demonstration.</p>
              <div class="feature-chips">
                <span>Typed RPC</span><span>Realtime streams</span><span>Multi-window</span><span>Durable replay</span>
              </div>
              <div class="preset-grid">
                <button class="preset" data-prompt="Analyze this OCaml desktop runtime and propose a production readiness plan."><b>Architecture review</b><span>Inspect the runtime and build a release plan</span></button>
                <button class="preset" data-prompt="Investigate a simulated production latency regression and prepare a safe remediation plan."><b>Incident response</b><span>Trace signals, test hypotheses, request approval</span></button>
                <button class="preset" data-prompt="Design a polished native agent application architecture with durable multi-window streaming."><b>Product design</b><span>Plan a sophisticated OCaml-native experience</span></button>
              </div>
            </section>

            <section id="run-view" class="run-view" hidden>
              <article class="message user-message">
                <div class="message-avatar user-avatar">DM</div>
                <div class="message-body"><div class="message-meta"><strong>You</strong><span>just now</span></div><p id="prompt-display"></p></div>
              </article>

              <article class="message agent-message">
                <div class="message-avatar agent-avatar"><span></span><i>O</i></div>
                <div class="message-body agent-body">
                  <div class="message-meta agent-meta">
                    <div><strong>Orbit Agent</strong><span id="model-label">Local simulator</span></div>
                    <div class="streaming-indicator" id="streaming-indicator"><i></i><span>Streaming</span></div>
                  </div>

                  <div class="phase-strip" aria-label="Run phases">
                    <div id="phase-planning" class="phase"><span>1</span><div><b>Plan</b><small>Understand</small></div></div>
                    <div id="phase-research" class="phase"><span>2</span><div><b>Research</b><small>Explore</small></div></div>
                    <div id="phase-execution" class="phase"><span>3</span><div><b>Execute</b><small>Act</small></div></div>
                    <div id="phase-review" class="phase"><span>4</span><div><b>Review</b><small>Validate</small></div></div>
                  </div>

                  <section id="plan-card" class="detail-card plan-card" hidden>
                    <div class="card-heading"><span class="card-icon">⌁</span><div><b>Execution plan</b><small id="phase-detail">Preparing a plan</small></div></div>
                    <ol id="plan-list"></ol>
                  </section>

                  <section id="activity-card" class="detail-card activity-card" hidden>
                    <div class="card-heading"><span class="card-icon pulse-icon">✦</span><div><b>Live activity</b><small>Structured progress, not hidden chain-of-thought</small></div></div>
                    <div id="activity-list" class="activity-list"></div>
                  </section>

                  <div id="tool-list" class="tool-list"></div>

                  <section id="approval-card" class="approval-card" hidden>
                    <div class="approval-topline"><span id="approval-risk" class="risk-badge">Approval required</span><span>Human in the loop</span></div>
                    <h3 id="approval-title">Approve action</h3>
                    <p id="approval-description"></p>
                    <code id="approval-command"></code>
                    <div class="approval-actions">
                      <button id="approval-reject" class="secondary-button">Reject</button>
                      <button id="approval-approve" class="approve-button"><span>Approve action</span><span>✓</span></button>
                    </div>
                  </section>

                  <section id="answer-card" class="answer-card" hidden>
                    <div class="answer-heading"><span>Response</span><span id="answer-word-count">0 words</span></div>
                    <div id="output" class="answer-output"></div><span id="cursor" class="cursor"></span>
                  </section>

                  <section id="artifact-section" class="artifact-section" hidden>
                    <div class="section-label">Generated artifacts</div>
                    <div id="artifact-list" class="artifact-list"></div>
                  </section>

                  <section id="terminal-card" class="terminal-card" hidden>
                    <div class="terminal-icon">✓</div><div><b id="terminal-title">Run complete</b><p id="terminal-detail"></p></div>
                  </section>
                </div>
              </article>
            </section>
          </div>

          <button id="jump-latest" class="jump-latest" hidden><span>↓</span> Jump to latest</button>

          <div class="composer-wrap">
            <div id="run-controls" class="run-controls" hidden>
              <button id="pause-run" class="control-button">Ⅱ <span>Pause</span></button>
              <button id="resume-run" class="control-button" hidden>▶ <span>Resume</span></button>
              <button id="cancel-run" class="control-button danger">■ <span>Stop</span></button>
              <div class="control-spacer"></div>
              <span id="status">Ready for a new run</span>
            </div>
            <div class="composer">
              <textarea id="prompt-input" rows="2" placeholder="Ask Orbit to investigate, design, or plan…"></textarea>
              <div class="composer-bottom">
                <div class="composer-options">
                  <select id="mode-select" aria-label="Run depth"><option value="fast">Fast</option><option value="balanced" selected>Balanced</option><option value="deep">Deep</option></select>
                  <select id="model-select" aria-label="Model"><option value="orbit-sim-1">Orbit Sim 1</option><option value="orbit-sim-pro">Orbit Sim Pro</option></select>
                  <span class="local-pill">● Local simulation</span>
                </div>
                <button id="send-prompt" class="send-button" title="Start run"><span>Run agent</span><b>↑</b></button>
              </div>
            </div>
            <div class="composer-note">Enter to run · Shift+Enter for a new line · all state remains local</div>
          </div>
        </section>

        <aside class="telemetry-pane" tabindex="0" aria-label="Run telemetry">
          <div class="telemetry-header"><div><span class="live-dot"></span><b>Live run telemetry</b></div><small id="session-short">No active session</small></div>

          <section class="telemetry-card usage-card">
            <div class="section-label">Usage</div>
            <div class="metric-grid">
              <div><strong id="metric-input">0</strong><span>Input</span></div>
              <div><strong id="metric-output">0</strong><span>Output</span></div>
              <div><strong id="metric-cost">$0.000</strong><span>Est. cost</span></div>
              <div><strong id="metric-time">0.0s</strong><span>Elapsed</span></div>
            </div>
            <div class="token-bar"><span id="token-bar-fill"></span></div>
            <small><span id="metric-cached">0</span> cached tokens</small>
          </section>

          <section class="telemetry-card">
            <div class="section-label">Durability</div>
            <dl class="data-list">
              <div><dt>Sequence</dt><dd id="sequence-value">0</dd></div>
              <div><dt>Checkpoint</dt><dd id="checkpoint-value">—</dd></div>
              <div><dt>Persistence</dt><dd><span class="good-dot"></span>Atomic</dd></div>
              <div><dt>Window client</dt><dd id="client-value">—</dd></div>
            </dl>
          </section>

          <section class="telemetry-card">
            <div class="section-label">Native platform</div>
            <div id="platform-backend" class="platform-name">Detecting…</div>
            <div id="capability-list" class="capability-list"></div>
          </section>

          <section class="telemetry-card instruction-card">
            <div class="section-label">Guide the active run</div>
            <textarea id="instruction-input" rows="3" placeholder="Add a constraint or follow-up…"></textarea>
            <button id="send-instruction" class="secondary-button" disabled>Send instruction</button>
          </section>

          <div class="telemetry-footnote"><span>◆</span><p>Events are typed, sequenced, persisted, replayable, and independently acknowledged by every window.</p></div>
        </aside>
      </div>
    </main>
  </div>
  <div id="toast" class="toast" hidden></div>
  <script src="frontend.js"></script>
</body>
</html>
|}

let stylesheet =
  {|
:root {
  color-scheme: dark;
  --bg: #080b12;
  --panel: rgba(14, 18, 29, .88);
  --panel-solid: #101521;
  --panel-raised: #151b29;
  --line: rgba(255,255,255,.075);
  --line-strong: rgba(255,255,255,.13);
  --text: #eef2ff;
  --muted: #8992a8;
  --faint: #5e6679;
  --cyan: #68e1d0;
  --cyan-strong: #35cdb8;
  --violet: #8f7cff;
  --orange: #ffb45b;
  --red: #ff6d78;
  --green: #6ee7a8;
  --shadow: 0 24px 80px rgba(0,0,0,.42);
  font-family: Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  font-synthesis: none;
}

* { box-sizing: border-box; }
html { width: 100%; height: 100%; margin: 0; overflow: hidden; }
body { width: 100%; height: 100%; min-height: 100%; margin: 0; overflow: auto; overscroll-behavior: none; background: var(--bg); color: var(--text); letter-spacing: -.01em; }
button, textarea, select { font: inherit; }
button { color: inherit; }
button:focus-visible, textarea:focus-visible, select:focus-visible { outline: 2px solid rgba(104,225,208,.7); outline-offset: 2px; }
button:disabled { opacity: .42; cursor: not-allowed; }
[hidden] { display: none !important; }

.ambient { position: fixed; width: 680px; height: 680px; border-radius: 50%; filter: blur(120px); opacity: .10; pointer-events: none; }
.ambient-a { background: #4ed9c6; left: 25%; top: -420px; }
.ambient-b { background: #7968ff; right: -420px; bottom: -420px; }

.app-shell { position: relative; display: grid; grid-template-columns: 260px minmax(0,1fr); height: 100dvh; min-height: 640px; background: linear-gradient(150deg, rgba(255,255,255,.015), transparent 40%); }
.sidebar { min-width: 0; min-height: 0; display: flex; flex-direction: column; padding: 22px 16px 16px; border-right: 1px solid var(--line); background: rgba(8,11,18,.72); backdrop-filter: blur(30px); }
.brand-row { display: flex; align-items: center; gap: 11px; padding: 0 8px 22px; }
.brand-row strong { display: block; font-size: 17px; letter-spacing: .01em; }
.brand-row small { display: block; color: var(--muted); font-size: 11px; margin-top: 1px; letter-spacing: .08em; text-transform: uppercase; }
.brand-mark { width: 34px; height: 34px; position: relative; border-radius: 10px; background: radial-gradient(circle at 35% 30%, #9ffff0, #38cdb9 38%, #6557da 85%); box-shadow: 0 0 28px rgba(74,220,199,.2); }
.brand-mark span { position: absolute; border: 1px solid rgba(8,11,18,.72); border-radius: 50%; }
.brand-mark span:nth-child(1) { inset: 7px; }
.brand-mark span:nth-child(2) { inset: 11px 5px; transform: rotate(55deg); }
.brand-mark span:nth-child(3) { inset: 5px 11px; transform: rotate(-55deg); }

.new-run-button { border: 1px solid rgba(104,225,208,.2); background: linear-gradient(135deg, rgba(104,225,208,.11), rgba(143,124,255,.09)); border-radius: 11px; min-height: 43px; display: flex; align-items: center; gap: 9px; padding: 0 11px; cursor: pointer; transition: .18s ease; }
.new-run-button:hover { transform: translateY(-1px); border-color: rgba(104,225,208,.42); background: linear-gradient(135deg, rgba(104,225,208,.17), rgba(143,124,255,.14)); }
.button-icon { width: 22px; height: 22px; display: grid; place-items: center; border-radius: 7px; background: rgba(104,225,208,.15); color: var(--cyan); font-size: 17px; }
.new-run-button > span:nth-child(2) { font-weight: 650; font-size: 13px; }
kbd { margin-left: auto; color: var(--faint); border: 1px solid var(--line); background: rgba(255,255,255,.025); border-radius: 5px; font: 10px ui-monospace, monospace; padding: 3px 5px; }
.sidebar-label { display: flex; justify-content: space-between; align-items: center; color: var(--faint); font-size: 10px; font-weight: 750; letter-spacing: .11em; text-transform: uppercase; padding: 25px 8px 10px; }
.sidebar-label span:last-child { border: 1px solid var(--line); border-radius: 20px; padding: 2px 6px; }
.history-list { flex: 1; overflow-y: auto; display: flex; flex-direction: column; gap: 5px; min-height: 0; overscroll-behavior: contain; -webkit-overflow-scrolling: touch; scrollbar-gutter: stable; scrollbar-width: thin; scrollbar-color: #354155 transparent; }
.history-empty { color: var(--faint); font-size: 12px; line-height: 1.55; padding: 16px 9px; }
.history-row { position: relative; border: 1px solid transparent; background: transparent; border-radius: 10px; padding: 10px 9px 10px 12px; cursor: pointer; transition: .16s ease; text-align: left; }
.history-row:hover { background: rgba(255,255,255,.035); border-color: var(--line); }
.history-row.active { background: rgba(104,225,208,.07); border-color: rgba(104,225,208,.15); }
.history-row.active:before { content: ""; position: absolute; left: -1px; top: 12px; bottom: 12px; width: 2px; border-radius: 2px; background: var(--cyan); }
.history-title { font-size: 12px; font-weight: 620; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; padding-right: 6px; }
.history-meta { display: flex; align-items: center; gap: 6px; color: var(--faint); font-size: 10px; margin-top: 5px; }
.history-state { width: 6px; height: 6px; border-radius: 50%; background: var(--faint); }
.history-state.running, .history-state.recovering { background: var(--cyan); box-shadow: 0 0 8px rgba(104,225,208,.55); }
.history-state.completed { background: var(--green); }
.history-state.interrupted { background: var(--orange); }
.history-state.failed, .history-state.cancelled { background: var(--red); }
.retry-mini { margin-top: 7px; border: 0; padding: 0; color: var(--orange); background: transparent; font-size: 10px; cursor: pointer; }
.sidebar-footer { margin-top: auto; border-top: 1px solid var(--line); padding: 14px 8px 2px; }
.native-badge { display: flex; align-items: center; gap: 7px; font-size: 11px; color: var(--muted); }
.native-dot, .good-dot { display: inline-block; width: 7px; height: 7px; border-radius: 50%; background: var(--green); box-shadow: 0 0 9px rgba(110,231,168,.5); }
.footer-copy { color: var(--faint); font-size: 10px; margin-top: 6px; }

.workspace { min-width: 0; min-height: 0; height: 100%; display: flex; flex-direction: column; }
.topbar { height: 76px; flex: 0 0 76px; display: flex; align-items: center; justify-content: space-between; gap: 18px; padding: 0 24px 0 28px; border-bottom: 1px solid var(--line); background: rgba(10,13,21,.56); backdrop-filter: blur(25px); }
.title-stack { min-width: 0; }
.eyebrow { display: flex; gap: 7px; color: var(--faint); font-size: 10px; letter-spacing: .08em; text-transform: uppercase; }
.eyebrow span:first-child { color: var(--cyan); }
.run-title-row { display: flex; align-items: center; gap: 10px; margin-top: 4px; }
.run-title-row h1 { margin: 0; font-size: 17px; font-weight: 650; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.pill { display: inline-flex; align-items: center; gap: 6px; border: 1px solid var(--line); border-radius: 99px; padding: 4px 8px; color: var(--muted); font-size: 9px; letter-spacing: .06em; text-transform: uppercase; }
.pill > span { width: 5px; height: 5px; border-radius: 50%; background: var(--faint); }
.pill-running, .pill-recovering { color: var(--cyan); border-color: rgba(104,225,208,.18); background: rgba(104,225,208,.055); }
.pill-running > span, .pill-recovering > span { background: var(--cyan); animation: pulse 1.4s infinite; }
.pill-completed { color: var(--green); border-color: rgba(110,231,168,.18); }
.pill-completed > span { background: var(--green); }
.pill-interrupted { color: var(--orange); border-color: rgba(255,180,91,.2); }
.pill-interrupted > span { background: var(--orange); }
.pill-failed, .pill-cancelled { color: var(--red); border-color: rgba(255,109,120,.2); }
.pill-failed > span, .pill-cancelled > span { background: var(--red); }
.top-actions { display: flex; align-items: center; gap: 8px; }
.connection { display: flex; align-items: center; gap: 7px; color: var(--muted); font-size: 10px; padding-right: 7px; }
#connection-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--orange); }
#connection-dot.connected { background: var(--green); box-shadow: 0 0 8px rgba(110,231,168,.5); }
.icon-button, .primary-button, .secondary-button, .approve-button, .control-button, .send-button { border-radius: 9px; border: 1px solid var(--line-strong); cursor: pointer; transition: .16s ease; }
.icon-button { background: rgba(255,255,255,.035); color: var(--muted); padding: 8px 10px; font-size: 11px; }
.icon-button:hover:not(:disabled) { color: var(--text); background: rgba(255,255,255,.07); }
.primary-button { display: flex; align-items: center; gap: 8px; background: var(--text); color: #0b0e16; border-color: transparent; padding: 8px 11px; font-size: 11px; font-weight: 700; }
.primary-button:hover:not(:disabled) { transform: translateY(-1px); box-shadow: 0 8px 24px rgba(238,242,255,.1); }

.workspace-grid { display: grid; grid-template-columns: minmax(0,1fr) 292px; flex: 1; min-height: 0; }
.conversation-pane { position: relative; min-width: 0; min-height: 0; display: flex; flex-direction: column; }
.scroll-region { flex: 1 1 0; min-height: 0; overflow-x: hidden; overflow-y: auto; overscroll-behavior-y: contain; touch-action: pan-y; -webkit-overflow-scrolling: touch; scrollbar-gutter: stable; scrollbar-width: thin; scrollbar-color: #354155 transparent; }
.scroll-region:focus-visible, .history-list:focus-visible, .telemetry-pane:focus-visible { outline: 1px solid rgba(104,225,208,.22); outline-offset: -1px; }
.scroll-region::-webkit-scrollbar, .history-list::-webkit-scrollbar, .activity-list::-webkit-scrollbar, .telemetry-pane::-webkit-scrollbar, body::-webkit-scrollbar { width: 10px; height: 10px; }
.scroll-region::-webkit-scrollbar-track, .history-list::-webkit-scrollbar-track, .activity-list::-webkit-scrollbar-track, .telemetry-pane::-webkit-scrollbar-track, body::-webkit-scrollbar-track { background: transparent; }
.scroll-region::-webkit-scrollbar-thumb, .history-list::-webkit-scrollbar-thumb, .activity-list::-webkit-scrollbar-thumb, .telemetry-pane::-webkit-scrollbar-thumb, body::-webkit-scrollbar-thumb { min-height: 34px; border: 3px solid transparent; border-radius: 10px; background: rgba(105,119,145,.46); background-clip: padding-box; }
.scroll-region::-webkit-scrollbar-thumb:hover, .history-list::-webkit-scrollbar-thumb:hover, .activity-list::-webkit-scrollbar-thumb:hover, .telemetry-pane::-webkit-scrollbar-thumb:hover, body::-webkit-scrollbar-thumb:hover { background: rgba(104,225,208,.55); background-clip: padding-box; }
.welcome-card { width: min(780px, calc(100% - 48px)); margin: max(34px, 8vh) auto 28px; text-align: center; }
.welcome-orbit { position: relative; width: 74px; height: 74px; margin: 0 auto 20px; display: grid; place-items: center; }
.welcome-orbit:before { content: ""; position: absolute; inset: 12px; border-radius: 17px; background: radial-gradient(circle at 35% 30%, #a9fff2, #45d4c1 42%, #6c5be4 100%); box-shadow: 0 0 50px rgba(74,220,199,.22); transform: rotate(8deg); }
.welcome-orbit span { position: absolute; inset: 4px; border: 1px solid rgba(104,225,208,.18); border-radius: 50%; animation: orbit 9s linear infinite; }
.welcome-orbit span:nth-child(2) { inset: 0 15px; transform: rotate(60deg); animation-duration: 12s; }
.welcome-orbit span:nth-child(3) { inset: 15px 0; transform: rotate(-60deg); animation-duration: 15s; }
.welcome-orbit i { position: relative; z-index: 2; font-style: normal; font-weight: 850; color: #07100f; }
.welcome-kicker { color: var(--cyan); font-size: 10px; font-weight: 800; letter-spacing: .18em; }
.welcome-card h2 { font-size: clamp(28px, 4vw, 48px); line-height: 1.04; letter-spacing: -.045em; margin: 13px auto 14px; max-width: 720px; background: linear-gradient(110deg, #fff, #c9cfdd 55%, #7d879c); -webkit-background-clip: text; color: transparent; }
.welcome-card > p { color: var(--muted); font-size: 14px; line-height: 1.65; max-width: 660px; margin: 0 auto; }
.feature-chips { display: flex; justify-content: center; flex-wrap: wrap; gap: 6px; margin: 18px 0 28px; }
.feature-chips span { color: #a9b3c8; background: rgba(255,255,255,.035); border: 1px solid var(--line); border-radius: 99px; padding: 6px 9px; font-size: 10px; }
.preset-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; text-align: left; }
.preset { min-width: 0; border: 1px solid var(--line); background: linear-gradient(145deg, rgba(255,255,255,.045), rgba(255,255,255,.018)); border-radius: 13px; padding: 14px; color: var(--text); cursor: pointer; transition: .18s ease; }
.preset:hover { transform: translateY(-2px); border-color: rgba(104,225,208,.24); background: linear-gradient(145deg, rgba(104,225,208,.08), rgba(143,124,255,.045)); box-shadow: 0 16px 34px rgba(0,0,0,.18); }
.preset b { display: block; font-size: 12px; margin-bottom: 5px; }
.preset span { display: block; color: var(--muted); font-size: 10px; line-height: 1.45; }

.run-view { width: min(850px, calc(100% - 48px)); margin: 25px auto 40px; }
.message { display: grid; grid-template-columns: 34px minmax(0,1fr); gap: 12px; }
.message + .message { margin-top: 26px; }
.message-avatar { width: 32px; height: 32px; border-radius: 10px; display: grid; place-items: center; font-size: 10px; font-weight: 800; }
.user-avatar { background: linear-gradient(140deg, #2c3447, #1b2231); border: 1px solid var(--line-strong); color: #b9c2d5; }
.agent-avatar { position: relative; overflow: hidden; color: #07100f; background: radial-gradient(circle at 30% 25%, #b2fff4, #47d8c4 45%, #6b5be1 100%); box-shadow: 0 0 20px rgba(71,216,196,.14); }
.agent-avatar span { position: absolute; inset: 7px 4px; border: 1px solid rgba(6,28,25,.35); border-radius: 50%; transform: rotate(55deg); }
.agent-avatar i { position: relative; font-style: normal; }
.message-meta { display: flex; align-items: center; gap: 8px; height: 32px; font-size: 11px; }
.message-meta > span, .agent-meta span { color: var(--faint); font-size: 9px; }
.message-body > p { margin: 7px 0 0; color: #d9deea; line-height: 1.55; font-size: 13px; }
.agent-body { min-width: 0; }
.agent-meta { justify-content: space-between; }
.agent-meta > div { display: flex; align-items: center; gap: 8px; }
.streaming-indicator { display: flex; align-items: center; gap: 6px; color: var(--cyan); font-size: 9px; }
.streaming-indicator i { width: 5px; height: 5px; border-radius: 50%; background: var(--cyan); animation: pulse 1.4s infinite; }
.streaming-indicator.done { color: var(--muted); }
.streaming-indicator.done i { background: var(--green); animation: none; }
.phase-strip { display: grid; grid-template-columns: repeat(4,1fr); gap: 6px; margin: 12px 0; }
.phase { position: relative; display: flex; align-items: center; gap: 8px; border: 1px solid var(--line); background: rgba(255,255,255,.022); padding: 9px; border-radius: 10px; color: var(--faint); transition: .2s ease; }
.phase:after { content: ""; position: absolute; left: 10px; right: 10px; bottom: -1px; height: 1px; background: transparent; }
.phase > span { width: 20px; height: 20px; display: grid; place-items: center; border-radius: 7px; border: 1px solid var(--line-strong); font-size: 9px; }
.phase b, .phase small { display: block; }
.phase b { font-size: 10px; }
.phase small { font-size: 8px; color: var(--faint); margin-top: 2px; }
.phase.active { color: var(--text); border-color: rgba(104,225,208,.23); background: rgba(104,225,208,.055); }
.phase.active > span { color: #07100f; border-color: transparent; background: var(--cyan); }
.phase.active:after { background: var(--cyan); box-shadow: 0 0 12px var(--cyan); }
.phase.complete { color: #a9b4c8; }
.phase.complete > span { color: var(--green); border-color: rgba(110,231,168,.25); }

.detail-card, .answer-card, .terminal-card { border: 1px solid var(--line); background: rgba(255,255,255,.024); border-radius: 13px; margin-top: 10px; overflow: hidden; }
.card-heading { display: flex; align-items: center; gap: 9px; padding: 12px 13px; border-bottom: 1px solid var(--line); }
.card-heading b, .card-heading small { display: block; }
.card-heading b { font-size: 11px; }
.card-heading small { color: var(--muted); font-size: 9px; margin-top: 2px; }
.card-icon { width: 26px; height: 26px; display: grid; place-items: center; color: var(--cyan); background: rgba(104,225,208,.08); border: 1px solid rgba(104,225,208,.12); border-radius: 8px; }
.pulse-icon { animation: softPulse 2s infinite; }
.plan-card ol { list-style: none; counter-reset: plan; margin: 0; padding: 6px 13px 10px; }
.plan-card li { counter-increment: plan; display: flex; align-items: center; gap: 9px; color: #aeb7ca; font-size: 10px; padding: 7px 0; border-bottom: 1px solid rgba(255,255,255,.035); }
.plan-card li:last-child { border: 0; }
.plan-card li:before { content: counter(plan); width: 17px; height: 17px; flex: 0 0 17px; display: grid; place-items: center; border-radius: 50%; background: rgba(143,124,255,.1); color: #b7abff; font-size: 8px; }
.activity-list { padding: 5px 13px 9px; max-height: 160px; overflow-y: auto; overscroll-behavior: contain; -webkit-overflow-scrolling: touch; scrollbar-gutter: stable; }
.activity-item { display: grid; grid-template-columns: 7px minmax(0,1fr); gap: 9px; padding: 7px 0; }
.activity-item > span { width: 6px; height: 6px; margin-top: 4px; border-radius: 50%; background: var(--violet); box-shadow: 0 0 8px rgba(143,124,255,.36); }
.activity-item b { display: block; font-size: 10px; font-weight: 620; }
.activity-item small { display: block; color: var(--muted); font-size: 9px; margin-top: 2px; line-height: 1.4; }
.tool-list { display: grid; gap: 8px; margin-top: 10px; }
.tool-card { border: 1px solid var(--line); background: linear-gradient(135deg, rgba(143,124,255,.045), rgba(255,255,255,.02)); border-radius: 12px; padding: 11px 12px; }
.tool-top { display: flex; justify-content: space-between; align-items: center; gap: 10px; }
.tool-name { display: flex; align-items: center; gap: 8px; min-width: 0; }
.tool-glyph { width: 24px; height: 24px; display: grid; place-items: center; border-radius: 7px; background: rgba(143,124,255,.11); color: #b7abff; font-size: 10px; }
.tool-name b { font: 10px ui-monospace, SFMono-Regular, monospace; }
.tool-state { color: var(--cyan); font-size: 9px; }
.tool-input { color: var(--muted); font: 9px ui-monospace, SFMono-Regular, monospace; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin: 7px 0; }
.progress-track { height: 3px; border-radius: 4px; background: rgba(255,255,255,.055); overflow: hidden; }
.progress-track span { display: block; width: 0; height: 100%; border-radius: inherit; background: linear-gradient(90deg, var(--violet), var(--cyan)); transition: width .25s ease; }
.tool-detail { color: var(--faint); font-size: 9px; margin-top: 6px; }
.tool-card.success .tool-state { color: var(--green); }
.tool-card.failed .tool-state { color: var(--red); }

.approval-card { margin-top: 11px; border: 1px solid rgba(255,180,91,.27); background: linear-gradient(140deg, rgba(255,180,91,.09), rgba(255,255,255,.018)); border-radius: 14px; padding: 14px; box-shadow: 0 18px 50px rgba(0,0,0,.16); }
.approval-topline { display: flex; justify-content: space-between; align-items: center; color: var(--faint); font-size: 9px; text-transform: uppercase; letter-spacing: .08em; }
.risk-badge { color: var(--orange); border: 1px solid rgba(255,180,91,.25); background: rgba(255,180,91,.08); border-radius: 99px; padding: 4px 7px; }
.risk-badge.high { color: var(--red); border-color: rgba(255,109,120,.28); background: rgba(255,109,120,.08); }
.risk-badge.low { color: var(--green); border-color: rgba(110,231,168,.23); background: rgba(110,231,168,.07); }
.approval-card h3 { font-size: 13px; margin: 13px 0 5px; }
.approval-card p { color: #afb8ca; font-size: 10px; line-height: 1.5; margin: 0; }
.approval-card code { display: block; margin-top: 10px; border: 1px solid var(--line); background: rgba(0,0,0,.2); color: #cfd5e2; border-radius: 8px; padding: 9px; font-size: 9px; white-space: pre-wrap; }
.approval-actions { display: flex; justify-content: flex-end; gap: 7px; margin-top: 12px; }
.secondary-button { background: rgba(255,255,255,.04); border-color: var(--line-strong); padding: 8px 11px; font-size: 10px; }
.secondary-button:hover:not(:disabled) { background: rgba(255,255,255,.08); }
.approve-button { display: flex; align-items: center; gap: 8px; color: #07100f; background: var(--cyan); border-color: transparent; padding: 8px 11px; font-size: 10px; font-weight: 750; }
.approve-button:hover:not(:disabled) { background: #83eddd; transform: translateY(-1px); }
.answer-card { padding: 13px 14px 15px; }
.answer-heading { display: flex; justify-content: space-between; color: var(--faint); font-size: 9px; text-transform: uppercase; letter-spacing: .09em; margin-bottom: 10px; }
.answer-output { display: inline; color: #dce1ec; font-size: 12px; line-height: 1.68; white-space: pre-wrap; }
.cursor { display: inline-block; width: 6px; height: 14px; vertical-align: -2px; margin-left: 2px; border-radius: 1px; background: var(--cyan); animation: blink 1s step-end infinite; }
.section-label { color: var(--faint); font-size: 9px; font-weight: 750; letter-spacing: .1em; text-transform: uppercase; }
.artifact-section { margin-top: 13px; }
.artifact-list { display: grid; grid-template-columns: repeat(2,minmax(0,1fr)); gap: 8px; margin-top: 8px; }
.artifact { display: grid; grid-template-columns: 29px minmax(0,1fr); gap: 9px; border: 1px solid var(--line); background: rgba(255,255,255,.024); border-radius: 10px; padding: 10px; }
.artifact-icon { width: 28px; height: 28px; display: grid; place-items: center; border-radius: 8px; color: var(--cyan); background: rgba(104,225,208,.07); font-size: 11px; }
.artifact b { display: block; font-size: 10px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.artifact small { display: block; color: var(--muted); font-size: 8px; line-height: 1.4; margin-top: 3px; }
.terminal-card { display: flex; align-items: center; gap: 10px; padding: 12px; border-color: rgba(110,231,168,.14); background: rgba(110,231,168,.035); }
.terminal-card.cancelled { border-color: rgba(255,109,120,.15); background: rgba(255,109,120,.035); }
.terminal-icon { width: 29px; height: 29px; display: grid; place-items: center; border-radius: 50%; color: var(--green); background: rgba(110,231,168,.1); }
.terminal-card.cancelled .terminal-icon { color: var(--red); background: rgba(255,109,120,.1); }
.terminal-card b { font-size: 10px; }
.terminal-card p { color: var(--muted); font-size: 9px; margin: 3px 0 0; }
.jump-latest { position: absolute; z-index: 5; right: 22px; bottom: 130px; display: flex; align-items: center; gap: 7px; border: 1px solid rgba(104,225,208,.22); border-radius: 99px; padding: 7px 11px; color: #c9fff7; background: rgba(18,28,36,.94); box-shadow: 0 12px 32px rgba(0,0,0,.34); backdrop-filter: blur(16px); cursor: pointer; font-size: 9px; animation: toastIn .18s ease; }
.jump-latest:hover { border-color: rgba(104,225,208,.48); background: rgba(30,49,54,.96); transform: translateY(-1px); }
.jump-latest span { color: var(--cyan); font-size: 12px; }

.composer-wrap { flex: 0 0 auto; padding: 8px 24px 14px; background: linear-gradient(transparent, rgba(8,11,18,.94) 22%); }
.run-controls { width: min(850px,100%); margin: 0 auto 7px; display: flex; align-items: center; gap: 6px; }
.control-button { border-color: var(--line); background: rgba(255,255,255,.035); color: var(--muted); padding: 6px 8px; font-size: 9px; }
.control-button:hover { color: var(--text); background: rgba(255,255,255,.07); }
.control-button.danger:hover { color: var(--red); border-color: rgba(255,109,120,.2); }
.control-spacer { flex: 1; }
#status { color: var(--muted); font-size: 9px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.composer { width: min(850px,100%); margin: 0 auto; border: 1px solid var(--line-strong); background: rgba(17,22,34,.94); border-radius: 14px; padding: 10px 10px 8px; box-shadow: var(--shadow); transition: border-color .18s ease; }
.composer:focus-within { border-color: rgba(104,225,208,.27); }
.composer textarea { display: block; width: 100%; resize: none; border: 0; outline: 0; background: transparent; color: var(--text); padding: 2px 3px 8px; font-size: 12px; line-height: 1.45; }
.composer textarea::placeholder { color: var(--faint); }
.composer-bottom { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.composer-options { display: flex; align-items: center; gap: 6px; min-width: 0; }
.composer select { appearance: none; border: 1px solid var(--line); background: rgba(255,255,255,.035); color: #aeb7c9; border-radius: 7px; padding: 5px 21px 5px 7px; font-size: 9px; background-image: linear-gradient(45deg,transparent 50%,#657087 50%),linear-gradient(135deg,#657087 50%,transparent 50%); background-position: calc(100% - 10px) 9px,calc(100% - 7px) 9px; background-size: 3px 3px; background-repeat: no-repeat; }
.local-pill { color: var(--faint); font-size: 8px; }
.local-pill::first-letter { color: var(--green); }
.send-button { display: flex; align-items: center; gap: 9px; color: #07100f; background: var(--cyan); border-color: transparent; padding: 6px 7px 6px 10px; font-size: 9px; font-weight: 760; }
.send-button b { width: 20px; height: 20px; display: grid; place-items: center; border-radius: 6px; background: rgba(4,24,21,.13); font-size: 13px; }
.send-button:hover:not(:disabled) { background: #84eddd; transform: translateY(-1px); }
.composer-note { width: min(850px,100%); margin: 6px auto 0; color: #4f5769; text-align: center; font-size: 8px; }

.telemetry-pane { min-width: 0; min-height: 0; overflow-y: auto; overscroll-behavior: contain; -webkit-overflow-scrolling: touch; scrollbar-gutter: stable; border-left: 1px solid var(--line); background: rgba(9,12,19,.58); padding: 18px 16px; scrollbar-width: thin; scrollbar-color: #354155 transparent; }
.telemetry-header { display: flex; justify-content: space-between; align-items: center; padding: 1px 2px 12px; }
.telemetry-header > div { display: flex; align-items: center; gap: 7px; font-size: 10px; }
.telemetry-header small { color: var(--faint); font-size: 8px; }
.live-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--cyan); box-shadow: 0 0 8px rgba(104,225,208,.45); animation: pulse 1.4s infinite; }
.telemetry-card { border: 1px solid var(--line); background: rgba(255,255,255,.025); border-radius: 12px; padding: 12px; margin-bottom: 9px; }
.metric-grid { display: grid; grid-template-columns: repeat(2,1fr); gap: 12px 8px; margin: 13px 0 11px; }
.metric-grid strong, .metric-grid span { display: block; }
.metric-grid strong { font-size: 15px; font-variant-numeric: tabular-nums; }
.metric-grid span { color: var(--faint); font-size: 8px; margin-top: 2px; }
.token-bar { height: 3px; border-radius: 3px; background: rgba(255,255,255,.05); overflow: hidden; }
.token-bar span { display: block; width: 0; height: 100%; background: linear-gradient(90deg,var(--cyan),var(--violet)); transition: width .3s ease; }
.usage-card > small { display: block; color: var(--faint); font-size: 8px; margin-top: 6px; }
.data-list { margin: 9px 0 0; }
.data-list > div { display: flex; justify-content: space-between; align-items: center; gap: 8px; padding: 7px 0; border-bottom: 1px solid rgba(255,255,255,.04); }
.data-list > div:last-child { border: 0; }
.data-list dt { color: var(--muted); font-size: 9px; }
.data-list dd { margin: 0; color: #c9d0de; font: 8px ui-monospace, SFMono-Regular, monospace; max-width: 145px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.good-dot { width: 5px; height: 5px; margin-right: 5px; }
.platform-name { margin: 9px 0; font: 10px ui-monospace, SFMono-Regular, monospace; color: #cbd3e2; }
.capability-list { display: flex; flex-wrap: wrap; gap: 5px; }
.capability { color: #8995ac; border: 1px solid var(--line); background: rgba(255,255,255,.025); border-radius: 6px; padding: 4px 6px; font-size: 7px; }
.instruction-card textarea { width: 100%; resize: none; border: 1px solid var(--line); outline: 0; background: rgba(0,0,0,.15); color: var(--text); border-radius: 8px; padding: 8px; margin: 9px 0 7px; font-size: 9px; line-height: 1.4; }
.instruction-card .secondary-button { width: 100%; }
.telemetry-footnote { display: grid; grid-template-columns: 18px minmax(0,1fr); gap: 7px; color: var(--faint); padding: 7px 4px; }
.telemetry-footnote span { color: var(--violet); font-size: 9px; }
.telemetry-footnote p { font-size: 8px; line-height: 1.5; margin: 0; }
.toast { position: fixed; left: 50%; bottom: 20px; transform: translateX(-50%); z-index: 20; color: #dfe5f0; background: rgba(20,25,37,.96); border: 1px solid var(--line-strong); box-shadow: var(--shadow); border-radius: 9px; padding: 9px 12px; font-size: 10px; animation: toastIn .2s ease; }

body.inspector .sidebar { display: none; }
body.inspector .app-shell { grid-template-columns: 1fr; }
body.inspector .composer-wrap { padding-bottom: 10px; }
body.inspector .welcome-card, body.inspector #new-run, body.inspector #open-inspector { display: none !important; }
body.inspector .workspace-grid { grid-template-columns: minmax(0,1fr) 330px; }

@keyframes pulse { 0%,100% { opacity: .45; transform: scale(.85); } 50% { opacity: 1; transform: scale(1.15); } }
@keyframes softPulse { 0%,100% { box-shadow: 0 0 0 rgba(104,225,208,0); } 50% { box-shadow: 0 0 18px rgba(104,225,208,.09); } }
@keyframes blink { 0%,45% { opacity: 1; } 46%,100% { opacity: 0; } }
@keyframes orbit { to { transform: rotate(360deg); } }
@keyframes toastIn { from { opacity: 0; transform: translate(-50%,8px); } }

@media (max-width: 1040px) {
  .app-shell { grid-template-columns: 220px minmax(0,1fr); }
  .workspace-grid { grid-template-columns: minmax(0,1fr) 260px; }
  .topbar { padding-left: 20px; }
  .connection { display: none; }
}
@media (max-width: 820px) {
  .app-shell { grid-template-columns: 190px minmax(0,1fr); }
  .telemetry-pane { display: none; }
  .workspace-grid { grid-template-columns: 1fr; }
  .preset-grid { grid-template-columns: 1fr; }
  .preset:nth-child(n+3) { display: none; }
  .phase small { display: none; }
  .top-actions .icon-button { display: none; }
}
|}
