# Flezha UI — Build Plan

## Workflow

Each phase follows this loop:
1. Implement the piece
2. Compile + run tests (`mix test`)
3. Ask user to verify on http://localhost:4000
4. User commits, we move on

---

> **This file is a historical build log.** The phases below record how the app
> was first built, against a version of the controller that has since changed
> substantially. For what the app does now, read `README.md`; for what is left,
> read `TODO.md`. Vocabulary here has been brought in line with the controller,
> but the narrative is not maintained.

## Current state

- Compiles clean under `mix compile --warnings-as-errors`
- `mix test` green, including distributed tests that start real peer nodes
- `npm run e2e` (Playwright) green against the running dev stack
- The dev stack is `docker compose -f docker-compose.dev.yml up --build`, which
  brings up the controller, a Rust runner, this UI, Postgres, and Kafka

### Known issue: container recompile lag
The container has its own `_build` Docker volume (`fui_web_build`). When `.ex` files change on the host, the container won't pick them up until `docker exec fui_web mix compile` is run (or the container restarts). `.html.heex` template changes are picked up by live-reload automatically.

---

## Phase Status

### ✅ Phase 1: User Authentication — COMPLETE

**What was done:**
- `mix phx.gen.auth Accounts User users` — full auth: bcrypt passwords, magic links, CSRF, session tokens
- Added `postgres:16` to `docker-compose.dev.yml` (hostname: `flezha_ui_db`, depends_on web)
- Created `auth.html.heex` — minimal dark centered card layout for login/register pages
- Updated all auth templates to use `<Layouts.auth>` instead of `<Layouts.app>`
- Cleaned up `root.html.heex` — removed gen.auth nav bar, dark background
- Fixed: `alias FlezhaUiWeb.Layouts` in `html_helpers`, removed unsupported `variant` attr
- Router: all app routes protected by `require_authenticated_user`
- **[Phase 1 polish]** Login page simplified — magic link form removed, password-only form with orange button
- **[Phase 1 polish]** Registration page restyled — "Create account" heading, orange button
- **[Phase 1 polish]** `UserAuth.on_mount/4` added (`:mount_current_scope`, `:ensure_authenticated`) so `current_scope` is available in LiveView sockets
- **[Phase 1 polish]** Router wrapped LiveViews in `live_session :authenticated` with `on_mount` hook
- **[Phase 1 polish]** `app.html.heex` uses `assigns[:current_scope]` (not `@current_scope`) + Settings link added to top bar
- **[Phase 1 polish]** `DashboardLiveTest` written and passing
- **All 96 tests pass**

**How auth works (for reference):**
- Passwords hashed with bcrypt (min 12 chars, max 72)
- CSRF protection on all forms
- Session tokens stored server-side (not raw passwords in cookies)
- Dev emails go to http://localhost:4000/dev/mailbox
- Magic link login still works via `/users/log-in/:token` (registration confirms via magic link)
- Password login: email + password → logged in (shown on login page)

**Needs browser confirmation:**
- Register at `/users/register` → check `/dev/mailbox` → click link → see Dashboard
- Log out → log back in at `/users/log-in` with email + password (after setting password in settings)

---

### ✅ Phase 2: NodeManager + Layout + Dashboard — AGENT CONFIRMED WORKING

**What was done:**
- `NodeManager` extended with all RPC wrapper functions (list_namespaces, list_operatives, etc.)
- App layout (`app.html.heex`): dark sidebar, top bar with node status dot + user email, settings + logout links
- `DashboardLive`: polls every 5s, shows node status, namespace/operative/plugin counts, CE table, namespace quick links
- **Fixed `Node.list(:hidden)` → `Node.list()`** in `node_manager.ex` — agent is a regular node, not hidden; `Node.list(:hidden)` always returned `[]` from the UI node
- **Fixed CE process lifecycle**: added `FLEZHA_EXTERNAL_PROCESSES` to `docker-compose.dev.yml` so `PortPilot` GenServer manages the Rust CE (previously, ERPC-launched CE died immediately when handler terminated)
- **Confirmed RPC works**: `list_namespaces()` → `["default"]`, `list_runners("default")` → `{:ok, ["default_..."]}`, `start_operative` → `{:ok, ...}`

**Known gaps:**
- `extension_entries/1` helper in `OperativeLive` handles both atom and string keys — not yet verified in browser
- Top bar logout uses `<.link method="delete">` — needs JS for method override (app.js includes Phoenix.HTML.Form JS)

**Needs browser confirmation:**
- Dashboard shows green dot + node name `flezha@flezha_controller`
- Namespace count 1, CE table shows CE ID, Namespace quicklink to `/namespaces/default`
- Demo operatives `operative_a` (store_input) and `operative_b` (do_nothing) running in "default"

---

### ⚠️ Phase 3: Namespace + Operative LiveViews — IMPLEMENTED, NOT BROWSER-TESTED

**What was done:**
- `NamespaceLive.Index`: lists namespaces with operative/CE counts, auto-refreshes every 5s
- `NamespaceLive.Show`: operatives + CEs panels, Start Operative modal, Stop confirmation
- `OperativeLive`: info panel, SDK state fetch + auto-refresh toggle, bindings table, attach/detach modals, stream link

**Known gaps:**
- `get_overwatch_state` return value key format (atom vs string) handled with `||` fallback — verify against real agent
- `extension_entries/1` in OperativeLive needs testing with real binding data shapes
- Start operative modal: `init_values` JSON textarea, `snapshot_interval` optional

**Tests to write:**
- Namespace index: empty state when disconnected
- Show: start modal renders, stop confirmation renders

---

### ⚠️ Phase 4: Plugin Management — IMPLEMENTED, NOT BROWSER-TESTED

**What was done:**
- `PluginSchema` module: static schema for 4 user-facing providers (websocket, kafka, filter, stdout)
- Attach Plugin modal in `OperativeLive`: step 1 choose provider, step 2 configure fields
- `PluginLive`: global list of all active plugins, disable button

**Known gaps:**
- `enable_plugin` RPC call: the plugin_map format sent to `Flezha.Service.CliManager` needs
  to match the expected struct exactly — verify field names against real flezha source
- `get_enabled_providers()` result filtering: keys may be atoms or strings — handled but unverified

**Tests to write:**
- `PluginSchema.providers/0` returns expected map shape
- Attach modal step 1 → step 2 transition

---

### ⚠️ Phase 5: StreamBridge + Stream Viewer — IMPLEMENTED, NOT BROWSER-TESTED

**What was done:**
- `StreamBridge` GenServer: enables `monitored_io_forward` plugin via RPC, bridges to PubSub
- `StreamLive`: input/output tab, pause/resume, clear, regex filter, 200-message cap, timestamps
- `StreamRegistry` (Registry) + `StreamSupervisor` (DynamicSupervisor) added to Application

**Known gaps:**
- `MonitoredIOForward` plugin provider_id may differ from `"monitored_io_forward"` — check flezha source
- `StreamBridge.enable_plugin` sends `recv_pid: self()` inside `provider_settings` — the actual
  `MonitoredIOForward` struct field might be named differently
- `phx-hook="ScrollBottom"` referenced in stream_live.html.heex but the JS hook is not yet
  implemented in `app.js` — auto-scroll won't work until that's added
- StreamBridge `terminate/2` calls `disable_plugin` — verify this works correctly

**Tests to write:**
- StreamLive mounts and shows "waiting" state
- StreamBridge reference counting: last unsubscribe triggers cleanup

---

### ⚠️ Phase 6: EventBridge + Enhanced Dashboard — IMPLEMENTED, NOT BROWSER-TESTED

**What was done:**
- `EventBridge` GenServer: subscribes to `Flezha.Service.EventManager` via RPC, retries every 10s
- Broadcasts `:runner_connected` / `:runner_disconnected` events to PubSub `"flezha:events"`

**Known gaps:**
- `Flezha.Service.EventManager.subscribe/1` API may differ — currently logs warning and retries
- Dashboard LiveView does NOT yet subscribe to EventBridge events — the event feed panel from Phase 6
  plan is not yet implemented in DashboardLive (only the bridge exists)

**Tests to write:**
- EventBridge starts and retries gracefully when node not connected
- EventBridge broadcasts to PubSub when event received

---

## Agent Crash-Loop Investigation — STATUS AND FINDINGS

### What was fixed

#### Fix 1: `Node.list(:hidden)` → `Node.list()`
`node_manager.ex` was calling `Node.list(:hidden)` but the UI node is `--hidden`, so agent
(a regular named node) never appeared in that list. Fixed to `Node.list()`.

#### Fix 2: `FLEZHA_EXTERNAL_PROCESSES` env var
Without this, CE was launched via ERPC. The ERPC handler process owns the Port. Handler exits →
stdin closes → CE reads EOF → exits. Fixed: set env var in docker-compose.dev.yml so PortPilot
GenServer owns the Port for the lifetime of the application.

#### Fix 3: `testnet_enabled: false` + `pkill` cleanup
`testnet_enabled: true` in `flezha/config/dev.exs` starts a Node.js WebSocket server on port 4500.
On agent restart, the old node process keeps the port bound. New instance → EADDRINUSE → crash loop.
Fixed: `testnet_enabled: false` in dev.exs + `pkill node; pkill -f rust_runner` before
each iex restart in docker-compose.dev.yml command.

#### Fix 4: `PortPilot` fatal raise → backoff (KEY FIX)
`port_pilot.ex` had `raise "Port application malfunction"` when `port_down_counter > 10`.
This caused a supervisor cascade: PortPilot crashes → supervisor restarts PortPilot → if 3 crashes
in 5s, supervisor crashes → parent crashes → iex exits. Each CE restart was hitting this.

**Fix applied (compiled 2026-03-05 ~17:09):**
- Replaced `raise` with `Process.send_after(self(), {:restart_port, command}, @backoff_ms)`
- Added `handle_info({:restart_port, command})` handler to restart CE after 5s backoff
- This keeps PortPilot alive — no supervisor cascade — iex stays up

After this fix: rapid restart cycle (every few seconds) stopped. Agent now survives CE crashes.

### Remaining issue: silent periodic BEAM crashes (~6-10 min cycle)

**Symptom:** BEAM process dies silently every ~6-10 minutes. No Elixir-level log output. BEAM PID
changes, new iex session starts, web app reconnects.

**What was ruled out:**
- `runner_cleanup` in `FleetManager` — runs every 40s, uses `HubManager.get_registry`
  which returns `{:ok,...}` or `{:error,...}`, never raises. Only stops inactive CEs.
- `ControlChannel → FleetManager` call deadlock — when ControlChannel gets killed during a
  `GenServer.call(FleetManager, ...)`, Erlang handles this gracefully (reply dropped, no crash).
- Orchestrator reconnect logic — `Node.monitor(node, false)` after max attempts — safe.
- NIF thread panics — Rust panics in background threads don't crash the BEAM.
- QuicListener — confirmed NOT in the supervisor tree (`transport_children()` only has `Transport.Server`).

**What is suspected but unconfirmed:**
- `LoggerFileBackend` (old `:gen_event` style) failing silently on init — no file log in new
  sessions. All output goes to console (docker logs stdout). If logger backend crashes an OTP
  process somehow, it could cascade. Unlikely but unconfirmed.
- NIF resource cleanup race — `TransportServer::drop` sends Shutdown + joins with 50ms timeout.
  If the thread doesn't stop in 50ms, it's abandoned but still alive. Possible state corruption.
- Diagnostic remsh sessions appeared to trigger crashes — running `iex --remsh flezha@flezha_controller`
  from outside, then disconnecting, seemed to correlate with agent crashes. Mechanism unclear.
  AVOID running diagnostic remsh commands — they may destabilize the agent.

**Current status (end of last session):**
- BEAM PID 17282 had been running 9m31s without crash (as of ~17:49 on 2026-03-05)
- Web app showed "Connected to flezha@flezha_controller" at 17:40:08 with no subsequent disconnects
- Agent appeared stable but root cause of periodic crashes not yet confirmed

### Next steps to investigate periodic crash

1. **Enable file logging properly** — `LoggerFileBackend` not writing in current sessions.
   Check if it registers correctly: in agent console or remsh look for it in `:logger.get_handler_config/0`.
   Alternative: add `config :logger, backends: [...]` explicitly in dev.exs.
   Goal: get crash stacktraces to file so we can see the actual crash reason.

2. **Watch docker logs during a crash** — run `docker logs -f flezha_controller` and wait for crash.
   If nothing appears in logs at crash time, it's a native/NIF crash (SIGABRT, SIGSEGV, etc.).
   If Elixir output appears, get the stacktrace.

3. **Check for BEAM crash dump** — after a crash, check for `/flezha/erl_crash.dump`.
   `docker exec flezha_controller ls -la /flezha/erl_crash.dump`
   If it exists, `head -100 /flezha/erl_crash.dump` will show the crash reason.

4. **Test agent stability without any UI connections** — if agent crashes even without fui_web
   connected, the crash is purely internal to the agent, not triggered by UI RPC calls.

5. **If crash dump shows NIF crash** — look at `flz_nif/src/` for any unsafe Rust. The 50ms
   join timeout in `TransportServer::drop` is the most likely race condition.

### Files changed (not yet committed in flezha repo)
- `/home/moon/Code/flezha/lib/flezha/service/port_pilot.ex` — backoff fix (key fix)
- `/home/moon/Code/flezha/config/dev.exs` — `testnet_enabled: false`

### Files changed (not yet committed in flezha_ui repo)
- `docker-compose.dev.yml` — `FLEZHA_EXTERNAL_PROCESSES`, `pkill` cleanup in command
- `lib/flezha_ui/service/node_manager.ex` — `Node.list()` fix
- `PLAN.md` — this update

---

## Immediate Next Steps (start of next session)

### Step 0 — Confirm agent stability / fix periodic crash
1. Start stack: `docker compose -f docker-compose.dev.yml up -d`
2. Watch for crashes: `docker logs -f flezha_controller` — wait 15+ minutes
3. After first crash, check: `docker exec flezha_controller ls -la /flezha/erl_crash.dump`
4. If crash dump exists: `docker exec flezha_controller head -200 /flezha/erl_crash.dump`
5. Fix based on crash reason (see investigation notes above)
6. DO NOT use `iex --remsh` for diagnosis — it appears to trigger crashes

### Step 1 — User browser confirms Phase 1 auth UX (after agent stable)
1. Open http://localhost:4000/users/register — "Create account" card, orange button
2. Register → check http://localhost:4000/dev/mailbox → click magic link → Dashboard
3. Open settings → set a password
4. Log out → log back in at http://localhost:4000/users/log-in with email + password

### Step 2 — User browser confirms Phase 2 dashboard
- http://localhost:4000 → green dot, namespace count, CE table
- http://localhost:4000/namespaces → "default" namespace
- http://localhost:4000/namespaces/default → operatives, CE, start/stop modals

---

## Key Files

| File | Purpose |
|------|---------|
| `lib/flezha_ui/service/node_manager.ex` | All RPC wrappers to flezha agent |
| `lib/flezha_ui/plugin_schema.ex` | Static schema for user-facing plugin providers |
| `lib/flezha_ui/service/stream_bridge.ex` | PubSub bridge for live I/O streaming |
| `lib/flezha_ui/service/event_bridge.ex` | PubSub bridge for system events |
| `lib/flezha_ui_web/live/dashboard_live.ex` | System overview, auto-refresh every 5s |
| `lib/flezha_ui_web/live/namespace_live/index.ex` | Namespace list |
| `lib/flezha_ui_web/live/namespace_live/show.ex` | Namespace detail + start/stop operative |
| `lib/flezha_ui_web/live/operative_live.ex` | Operative detail, state, bindings, plugin attach |
| `lib/flezha_ui_web/live/plugin_live.ex` | Global plugin list |
| `lib/flezha_ui_web/live/stream_live.ex` | Real-time I/O stream viewer |
| `lib/flezha_ui_web/router.ex` | All routes, auth protection |
| `lib/flezha_ui_web/components/layouts/app.html.heex` | Dark sidebar layout (authenticated pages) |
| `lib/flezha_ui_web/components/layouts/auth.html.heex` | Minimal centered layout (login/register) |
| `docker-compose.dev.yml` | Full dev stack: agent + web + db + kafka |

---

## Route Map

```
GET  /                                     → DashboardLive           [auth required]
GET  /namespaces                           → NamespaceLive.Index      [auth required]
GET  /namespaces/:ns                       → NamespaceLive.Show       [auth required]
GET  /namespaces/:ns/operatives/:id        → OperativeLive            [auth required]
GET  /namespaces/:ns/operatives/:id/stream → StreamLive               [auth required]
GET  /plugins                              → PluginLive               [auth required]

GET    /users/register   → UserRegistrationController (public)
GET    /users/log-in     → UserSessionController (public)
DELETE /users/log-out    → UserSessionController (auth required)
GET    /users/settings   → UserSettingsController (auth required)
GET    /dev/mailbox      → Swoosh mailbox preview (dev only)
```

---

## Docker Cheatsheet

```bash
# Start full stack
docker compose -f docker-compose.dev.yml up

# Force recompile after .ex file changes
docker exec fui_web mix compile --force

# Run migrations
docker exec fui_web mix ecto.migrate

# Check logs (filter noise)
docker logs fui_web 2>&1 | grep -v "EventBridge\|NodeConnector"

# Watch agent for crashes (wait 15+ min)
docker logs -f flezha_controller

# Check for BEAM crash dump after a crash
docker exec flezha_controller ls -la /flezha/erl_crash.dump
docker exec flezha_controller head -200 /flezha/erl_crash.dump
```
