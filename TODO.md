# TODO

## Add a standalone Operatives page

### Current state

- Operatives are reachable only through a namespace: `/namespaces/:ns` → click an
  operative → `/namespaces/:ns/operatives/:id`
- There is no view of every operative across every namespace
- The sidebar has Dashboard, Namespaces, Plugins, Cluster, Schedules,
  Dead-letter, Audit log — no Operatives entry

### What to build

#### 1. Operatives list page (`/operatives`)

**Route:** `live "/operatives", OperativeListLive`
**Files:** `lib/flezha_ui_web/live/operative_list_live.ex` + `.html.heex`

A table of every operative across every namespace:

- **Columns:** Operative ID, Namespace, Factory ID, Kind, Runner, Plugin count
- Operative ID links to `/namespaces/:ns/operatives/:id`
- Data: `list_namespaces()` → `list_operatives(ns)` → `get_overwatch_state(ns, id)`
- Auto-refresh on the 5s timer the other screens use, and subscribe to
  `EventBridge.topic()` so runner changes land immediately

Note the cost: one overwatch call per operative. `ClusterLive.describe_namespace/1`
shows the shape to follow — do the per-namespace lookups once and invert them,
rather than asking per row.

#### 2. Sidebar entry

**File:** `lib/flezha_ui_web/components/layouts/app.html.heex`

Add "Operatives" between "Namespaces" and "Plugins", icon `hero-cpu-chip`.

### Existing pages for reference

| Page | Route | File |
|------|-------|------|
| Dashboard | `/` | `dashboard_live.ex` |
| Namespaces list | `/namespaces` | `namespace_live/index.ex` |
| Namespace detail | `/namespaces/:ns` | `namespace_live/show.ex` |
| Operative detail | `/namespaces/:ns/operatives/:id` | `operative_live.ex` |
| Stream | `/namespaces/:ns/operatives/:id/stream` | `stream_live.ex` |
| Plugins | `/plugins` | `plugin_live.ex` |
| Cluster | `/cluster` | `cluster_live.ex` |
| Schedules | `/schedules` | `schedule_live.ex` |
| Dead-letter | `/dlq` | `dlq_live.ex` |
| Audit log | `/audit` | `audit_live.ex` |

### Data sources (NodeManager)

- `list_namespaces()` → list of namespace strings
- `list_operatives(ns)` → `{:ok, [operative_id, ...]}`
- `get_overwatch_state(ns, id)` → `{:ok, %{factory_id, runner_id, kind, extensions, ...}}`
- `extension_entries(state)` → one row per `{extension, plugin}` pair
- `get_plugins()` → `%{plugin_id => {namespace, operative_id}}`

## Later

- Upgrade to the latest Phoenix and LiveView
- The visual redesign in `REDESIGN_OPTIONS.md`
- AuthZ: bind a principal so the controller's `authn_authz` can be switched on
  (`NodeManager.caller_context/1` already carries the field)
