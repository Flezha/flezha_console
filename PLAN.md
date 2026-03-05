# Flezha UI — Build Plan

## Workflow

Each phase follows this loop:
1. Implement the piece
2. Compile + run tests (`mix test`)
3. Ask user to verify on http://localhost:4000
4. User commits, we move on

---

## Current State (as of last session)

- **Code compiles cleanly** (host: `mix compile` passes with no errors)
- **Docker stack is running** (`docker compose -f docker-compose.dev.yml up`)
- **DB is migrated** (`docker exec fui_web mix ecto.migrate` → "Migrations already up")
- **Login page loads** (200), register page loads (200), `/` redirects to login (302)
- **Registration flow tested**: register → dev mailbox email → magic link → logged in → Dashboard renders
- **Container recompile needed after `.ex` file changes**: `docker exec fui_web mix compile --force`

### Known issue: container recompile lag
The container has its own `_build` Docker volume (`fui_web_build`). When `.ex` files change on the host, the container won't pick them up until `docker exec fui_web mix compile --force` is run (or the container restarts). `.html.heex` template changes are picked up by live-reload automatically.

---

## Phase Status

### ⚠️ Phase 1: User Authentication — WORKING BUT NEEDS UX POLISH

**What was done:**
- `mix phx.gen.auth Accounts User users` — full auth: bcrypt passwords, magic links, CSRF, session tokens
- Added `postgres:16` to `docker-compose.dev.yml` (hostname: `flezha_ui_db`, depends_on web)
- Created `auth.html.heex` — minimal dark centered card layout for login/register pages
- Updated all auth templates to use `<Layouts.auth>` instead of `<Layouts.app>`
- Cleaned up `root.html.heex` — removed gen.auth nav bar, dark background
- Fixed: `alias FlezhaUiWeb.Layouts` in `html_helpers`, removed unsupported `variant` attr
- Router: all app routes protected by `require_authenticated_user`

**What still needs work (deferred):**
- The login page UX: currently shows TWO forms (magic link + password) which is confusing
  - Option A: Remove magic link form, keep password-only login (simpler)
  - Option B: Keep magic link only (passwordless), remove password form
  - Recommended: password-only for a single-user dev tool
- Registration form styling could be improved to match dark theme better
- The `auth.html.heex` layout renders inside a second `app.html.heex` wrapper for controller routes
  — this is because the controllers call `<Layouts.auth>` as a component AND Phoenix applies
  the app layout from the router. The app.html.heex checks `assigns[:inner_block]` to handle both.
  This works but needs cleanup.
- No tests written yet for auth flow

**How auth works (for reference):**
- Passwords hashed with bcrypt (min 12 chars, max 72)
- CSRF protection on all forms
- Session tokens stored server-side (not raw passwords in cookies)
- Dev emails go to http://localhost:4000/dev/mailbox
- Magic link login: enter email only → get a link emailed → click link → logged in
- Password login: email + password → logged in

**Tests to write:**
- `test/flezha_ui_web/live/dashboard_live_test.exs` — unauthenticated redirect, authenticated mount

---

### ⚠️ Phase 2: NodeManager + Layout + Dashboard — IMPLEMENTED, NOT BROWSER-TESTED

**What was done:**
- `NodeManager` extended with all RPC wrapper functions (list_namespaces, list_processors, etc.)
- App layout (`app.html.heex`): dark sidebar, top bar with node status dot + user email, logout link
- `DashboardLive`: polls every 5s, shows node status, namespace/processor/plugin counts, CE table, namespace quick links

**Known gaps:**
- Dashboard shows "Not connected" when flezha agent is not running — this is correct behaviour
- The `flat_bindings/1` helper in `ProcessorLive` handles both atom and string keys in the overwatch
  state map (RPC may return either) — needs real testing against a live agent
- Top bar logout uses `<.link method="delete">` — correct for Phoenix, but needs JS to work
  (the `app.js` must include the Phoenix.HTML.Form JS for method override)

**Tests to write:**
- Mount DashboardLive unauthenticated → redirect
- Mount DashboardLive authenticated (mocked node) → renders "Not connected"

---

### ⚠️ Phase 3: Namespace + Processor LiveViews — IMPLEMENTED, NOT BROWSER-TESTED

**What was done:**
- `NamespaceLive.Index`: lists namespaces with processor/CE counts, auto-refreshes every 5s
- `NamespaceLive.Show`: processors + CEs panels, Start Processor modal, Stop confirmation
- `ProcessorLive`: info panel, SDK state fetch + auto-refresh toggle, bindings table, attach/detach modals, stream link

**Known gaps:**
- `get_overwatch_state` return value key format (atom vs string) handled with `||` fallback — verify against real agent
- `flat_bindings/1` in ProcessorLive needs testing with real binding data shapes
- Start processor modal: `init_values` JSON textarea, `snapshot_interval` optional

**Tests to write:**
- Namespace index: empty state when disconnected
- Show: start modal renders, stop confirmation renders

---

### ⚠️ Phase 4: Plugin Management — IMPLEMENTED, NOT BROWSER-TESTED

**What was done:**
- `PluginSchema` module: static schema for 4 user-facing providers (websocket, kafka, filter, stdout)
- Attach Plugin modal in `ProcessorLive`: step 1 choose provider, step 2 configure fields
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
- Broadcasts `:compute_engine_connected` / `:compute_engine_disconnected` events to PubSub `"flezha:events"`

**Known gaps:**
- `Flezha.Service.EventManager.subscribe/1` API may differ — currently logs warning and retries
- Dashboard LiveView does NOT yet subscribe to EventBridge events — the event feed panel from Phase 6
  plan is not yet implemented in DashboardLive (only the bridge exists)

**Tests to write:**
- EventBridge starts and retries gracefully when node not connected
- EventBridge broadcasts to PubSub when event received

---

## Immediate Next Steps (start of next session)

### Step 1 — Fix auth UX (Phase 1 polish)
Make login/register actually usable and not confusing.

**Recommended approach:** simplify to email + password only (no magic link UI shown):
- `new.html.heex` (login): remove the magic link form, keep only the password form
- `new.html.heex` (register): style it properly with the dark theme
- Optionally: disable registration after first user (single-user tool)

### Step 2 — Write Phase 1 tests
```elixir
# test/flezha_ui_web/live/dashboard_live_test.exs
# - unauthenticated GET / → redirect to /users/log-in
# - authenticated GET / → 200, "Dashboard" in response
```

### Step 3 — User browser test of auth
- Login at http://localhost:4000/users/log-in
- Register, confirm via /dev/mailbox, reach Dashboard

### Step 4 — Commit Phase 1
Only after browser confirmation.

### Step 5 — Browser test Phases 2-3 (needs live flezha agent)
With flezha agent running at `flezha@fui_agent`:
- Dashboard shows green connected dot + node name
- /namespaces shows namespace list
- /namespaces/:ns shows processors + CEs

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
| `lib/flezha_ui_web/live/namespace_live/show.ex` | Namespace detail + start/stop processor |
| `lib/flezha_ui_web/live/processor_live.ex` | Processor detail, state, bindings, plugin attach |
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
GET  /namespaces/:ns/processors/:id        → ProcessorLive            [auth required]
GET  /namespaces/:ns/processors/:id/stream → StreamLive               [auth required]
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

# Restart just the web container
docker restart fui_web
```
