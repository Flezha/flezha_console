# Flezha UI — Build Plan

## Workflow

Each phase follows this loop:
1. Implement the piece
2. Compile + run tests (`mix test`)
3. Ask user to verify on http://localhost:4000
4. User commits, we move on

---

## Phase Status

### ✅ Phase 1: User Authentication — IMPLEMENTED, NEEDS TEST & REVIEW

**What was done:**
- Ran `mix phx.gen.auth Accounts User users` — generated full auth with sessions, email tokens, password support
- Added `postgres:16` service to `docker-compose.dev.yml` (hostname: `flezha_ui_db`)
- Added `depends_on: db` to `web` service
- Fixed generated template warnings: removed unsupported `variant` attr from buttons, added `alias FlezhaUiWeb.Layouts` to `html_helpers`
- Updated `router.ex`: removed old controller routes, added `require_authenticated_user` protection on all app routes

**What needs to happen before testing:**
- Restart docker-compose to pick up the new `db` service
- Run `mix ecto.migrate` inside the container (or `docker exec fui_web mix ecto.migrate`)
- Visit http://localhost:4000 → should redirect to /users/log-in
- Register a user at /users/register
- Log in, see the dashboard

**Test files to write:**
- `test/flezha_ui_web/live/dashboard_live_test.exs` — basic auth redirect test
- Extend existing generated auth tests

---

### 🔲 Phase 2: NodeManager + Layout + Dashboard — IMPLEMENTED, NOT YET TESTED

**What was done:**
- Extended `NodeManager` with all RPC wrapper functions
- New app layout: dark sidebar (`#FD4F00` brand), top bar with node status + user email
- `DashboardLive`: polls every 5s, shows node status, namespace/processor/plugin counts, CE table

**Test focus:**
- Mount `DashboardLive` with a mocked/disconnected node → shows "Not connected"
- Sidebar nav links render correctly

---

### 🔲 Phase 3: Namespace + Processor LiveViews — IMPLEMENTED, NOT YET TESTED

**What was done:**
- `NamespaceLive.Index`: lists namespaces with processor/CE counts, auto-refreshes
- `NamespaceLive.Show`: lists processors + CEs, Start Processor modal, Stop confirmation
- `ProcessorLive`: info panel, SDK state fetch/auto-refresh, bindings table, stream link

**Test focus:**
- Namespace index renders empty state when not connected
- Start processor modal opens/closes
- Stop confirmation appears

---

### 🔲 Phase 4: Plugin Management — IMPLEMENTED, NOT YET TESTED

**What was done:**
- `PluginSchema` module with static schema for 4 user-facing providers
- Attach Plugin modal in `ProcessorLive` (2-step: choose provider → configure)
- Global `PluginLive` listing all active plugins with disable button

**Test focus:**
- PluginSchema.providers() returns correct map
- Attach modal step 1 shows provider cards
- Step 2 shows correct fields per provider

---

### 🔲 Phase 5: StreamBridge + Stream Viewer — IMPLEMENTED, NOT YET TESTED

**What was done:**
- `StreamBridge` GenServer: subscribes MonitoredIOForward plugin, broadcasts to PubSub
- `StreamLive`: input/output tab switch, pause/resume, clear, regex filter, 200-message cap
- Added `StreamRegistry` + `StreamSupervisor` to Application

**Test focus:**
- StreamBridge starts and enables plugin via RPC
- StreamLive shows "waiting" message when no messages
- Switching IO type unsubscribes old / subscribes new

---

### 🔲 Phase 6: EventBridge + Enhanced Dashboard — IMPLEMENTED, NOT YET TESTED

**What was done:**
- `EventBridge` GenServer subscribes to `Flezha.Service.EventManager` via RPC, retries on failure
- Broadcasts CE connected/disconnected events to PubSub `"flezha:events"`

**Test focus:**
- EventBridge starts in application supervision tree
- Gracefully handles missing node (retries)

---

## Next Steps (in order)

1. **Restart docker-compose** (to get Postgres running): `docker compose -f docker-compose.dev.yml up`
2. **Run migration**: `docker exec fui_web mix ecto.migrate`
3. **Write Phase 1 tests** + run `mix test`
4. **User review**: http://localhost:4000 — test register/login flow
5. **User commits Phase 1**
6. Move to Phase 2 review, etc.

---

## Key Files

| File | Purpose |
|------|---------|
| `lib/flezha_ui/service/node_manager.ex` | All RPC wrappers to flezha agent |
| `lib/flezha_ui/plugin_schema.ex` | Static schema for user-facing plugin providers |
| `lib/flezha_ui/service/stream_bridge.ex` | PubSub bridge for live I/O streaming |
| `lib/flezha_ui/service/event_bridge.ex` | PubSub bridge for system events |
| `lib/flezha_ui_web/live/dashboard_live.ex` | System overview, auto-refresh |
| `lib/flezha_ui_web/live/namespace_live/` | Namespace index + show + start/stop |
| `lib/flezha_ui_web/live/processor_live.ex` | Processor detail, state, bindings |
| `lib/flezha_ui_web/live/plugin_live.ex` | Global plugin list |
| `lib/flezha_ui_web/live/stream_live.ex` | Real-time I/O stream viewer |
| `lib/flezha_ui_web/router.ex` | All routes, auth protection |
| `docker-compose.dev.yml` | Added `db` (postgres:16) service |

---

## Route Map

```
GET  /                              → DashboardLive           [auth required]
GET  /namespaces                    → NamespaceLive.Index      [auth required]
GET  /namespaces/:ns                → NamespaceLive.Show       [auth required]
GET  /namespaces/:ns/processors/:id → ProcessorLive            [auth required]
GET  /namespaces/:ns/processors/:id/stream → StreamLive        [auth required]
GET  /plugins                       → PluginLive               [auth required]
GET  /users/register                → UserRegistrationController
GET  /users/log-in                  → UserSessionController
DELETE /users/log-out               → UserSessionController
```
