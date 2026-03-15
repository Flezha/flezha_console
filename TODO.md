# TODO

## Add standalone Processors page

### Current state
- Processors are only accessible through the namespace detail page: `/namespaces/:ns` → click processor → `/namespaces/:ns/processors/:id`
- No way to see all processors across all namespaces in one view
- Sidebar has: Dashboard, Namespaces, Plugins — no Processors entry

### What to build

#### 1. Processors list page (`/processors`)
**Route:** `live "/processors", ProcessorListLive`
**File:** `lib/flezha_ui_web/live/processor_list_live.ex` + `.html.heex`

Shows a table of all processors across all namespaces:
- **Columns:** Processor ID, Namespace, Factory ID, Compute Engine, Plugin Count
- Processor ID links to the existing detail page (`/namespaces/:ns/processors/:id`)
- Data: iterate `list_namespaces()` → `list_processors(ns)` → `get_overwatch_state(ns, proc_id)` for each
- Auto-refresh every 5s (same pattern as other pages)

#### 2. Add sidebar nav entry
**File:** `lib/flezha_ui_web/components/layouts/app.html.heex`

Add a "Processors" link between "Namespaces" and "Plugins" in the sidebar nav:
- Icon: `hero-cpu-chip`
- href: `/processors`

#### 3. Improve processor detail page
**Existing file:** `lib/flezha_ui_web/live/processor_live.ex` + `.html.heex`
**Route:** `/namespaces/:ns/processors/:id` (already exists)

The processor detail page already shows:
- Info panel: namespace, factory_id, compute_engine_id, default_input_type
- SDK state viewer with fetch + auto-refresh
- Plugins/Bindings table with trigger, provider, position
- Attach plugin modal (choose provider → configure)
- Detach plugin with confirmation
- Link to stream page

Review and ensure:
- Bindings table shows all plugin info correctly (trigger, provider, position)
- Attach plugin flow works end-to-end (currently sends plain map to `Flezha.enable_plugin` which expects a struct — same bug we fixed in DevSetup by using `CliManager.enable_plugin`)
- Stream link works

### Existing pages for reference
| Page | Route | File |
|------|-------|------|
| Dashboard | `/` | `dashboard_live.ex` |
| Namespaces list | `/namespaces` | `namespace_live/index.ex` |
| Namespace detail | `/namespaces/:ns` | `namespace_live/show.ex` |
| Processor detail | `/namespaces/:ns/processors/:id` | `processor_live.ex` |
| Stream | `/namespaces/:ns/processors/:id/stream` | `stream_live.ex` |
| Plugins | `/plugins` | `plugin_live.ex` |

### Data sources (NodeManager)
- `list_namespaces()` → list of namespace strings
- `list_processors(ns)` → `{:ok, [processor_id_string, ...]}`
- `get_overwatch_state(ns, proc_id)` → `{:ok, %{factory_id, compute_engine_id, bindings, ...}}`
- `get_plugins()` → `%{plugin_id => {module, {namespace, processor_id}}}`
