# FlezhaUI — Namespace Debug Context

**Problem:** `http://0.0.0.0:4000/` always shows an empty namespace list.

---

## System Architecture

Two services communicate over Erlang distribution (ERPC):

```
[fui_web container]                    [fui_agent container]
  flezha_ui Phoenix app                  flezha iex node
  NodeConnector (GenServer)  ---ERPC---> Flezha.list_namespaces/0
  NodeManager.erpc_call/3                Flezha.list_processors/1
                                         Flezha.list_compute_engines/1
```

### Data Flow for Homepage

1. `GET /` → `PageController.home/2`
2. Calls `NodeManager.erpc_call(Flezha, :list_namespaces, [])`
3. `NodeManager.connected_node/0` → `Node.list(:hidden) |> List.first()`
4. If node found: `:erpc.call(node, Flezha, :list_namespaces, [])`
5. On success assigns namespaces list; on any error assigns `[]`
6. Template renders `@namespaces` (empty → no cards shown)

---

## Key Files

| File | Role |
|------|------|
| `lib/flezha_ui/service/node_connector.ex` | GenServer — connects to agent node, monitors, retries every 3s |
| `lib/flezha_ui/service/node_manager.ex` | `connected_node/0` + `erpc_call/3` |
| `lib/flezha_ui_web/controllers/page_controller.ex` | Calls erpc, assigns `@namespaces` |
| `lib/flezha_ui_web/templates/page_html/home.html.heex` | Iterates `@namespaces` |
| `Dockerfile` | Starts Phoenix with `--sname` + `--hidden` |
| `docker-compose.dev.yml` | Dev all-in-one: agent + web + kafka |
| `docker-compose.yml` | Web-only, expects external `flezha_network` |

---

## Current State of Key Files

### `node_manager.ex` (current)
```elixir
defmodule FlezhaUi.Service.NodeManager do
  def connected_node do
    Node.list(:hidden) |> List.first()
  end

  def erpc_call(module, function, args) do
    node = connected_node()
    if is_atom(node) and not is_nil(node) do
      try do
        {:ok, :erpc.call(node, module, function, args)}
      catch
        :error, reason -> {:error, reason}
      end
    else
      {:error, :node_not_connected}
    end
  end
end
```

### `Dockerfile` CMD (current)
```dockerfile
CMD ["sh", "-c", "elixir --sname flezha_ui@flezha_ui_web --hidden --cookie ${ERLANG_COOKIE:-flezha_dev_cookie} -S mix phx.server"]
```

### `node_connector.ex` — target node resolution
```elixir
defp target_node do
  case System.get_env("FLEZHA_NODE") do
    nil -> Application.get_env(:flezha_ui, :flezha_node, :"flezha@flezha_agent_dev")
    val -> String.to_atom(val)
  end
end
```

### Agent startup command (`docker-compose.dev.yml`)
```sh
iex --sname flezha --cookie flezha_dev_cookie -S mix
```
Container hostname: `fui_agent` → node name becomes `flezha@fui_agent`

### Web service env (`docker-compose.dev.yml`)
```yaml
container_name: fui_web
hostname: fui_web
environment:
  FLEZHA_NODE: flezha@fui_agent
  ERLANG_COOKIE: flezha_dev_cookie
```

### Web service env (`docker-compose.yml`)
```yaml
container_name: flezha_ui_web
hostname: flezha_ui_web
environment:
  FLEZHA_NODE: flezha@flezha_agent_dev
  ERLANG_COOKIE: flezha_dev_cookie
networks:
  - flezha_network  # external network — must pre-exist
```

---

## Hypotheses (in order of likelihood)

### Hypothesis 1: `Node.list(:hidden)` is wrong from the UI node's perspective ← MOST LIKELY

`Node.list(:hidden)` returns **other hidden nodes** that the current node is connected to.
- The UI node is hidden (`--hidden`)
- The agent node is a **regular** (visible) node
- From the UI's perspective: `Node.list()` → `[flezha@fui_agent]`, `Node.list(:hidden)` → `[]`

`Node.list(:hidden)` will always return `[]` on the UI node unless there are other hidden nodes in the system. The agent only shows in `Node.list()`.

**Fix:** Change `Node.list(:hidden)` back to `Node.list()` in `node_manager.ex`.

The `--hidden` flag is still correct on the UI node (keeps UI invisible to cluster gossip), but the UI must use `Node.list()` to see the regular agent node.

---

### Hypothesis 2: `--sname flezha_ui@flezha_ui_web` is wrong when hostname is `fui_web`

With `--sname`, Erlang takes the short name and appends the machine's actual hostname. Passing `flezha_ui@flezha_ui_web` to `--sname` is unusual — Erlang may:
- (a) Use `flezha_ui@flezha_ui_web` literally as the node name (ignoring actual hostname)
- (b) Treat the `@flezha_ui_web` part as an error or strip it and use `flezha_ui@fui_web`

In `docker-compose.dev.yml`, the container hostname is `fui_web`, not `flezha_ui_web`. If Erlang uses the actual hostname, the UI node becomes `flezha_ui@fui_web`, not `flezha_ui@flezha_ui_web`. This would not break the outbound connection (since FLEZHA_NODE points to the agent, not back to itself), but it could cause confusing log output.

In `docker-compose.yml`, hostname is `flezha_ui_web`, which matches the `--sname` argument — so this compose file is self-consistent.

---

### Hypothesis 3: The Erlang connection is never established

NodeConnector logs either:
- `[NodeConnector] Connected to flezha@fui_agent` (success)
- `[NodeConnector] Could not connect to flezha@fui_agent, retrying...` (network/name failure)
- `[NodeConnector] Distribution not started` (`:ignored` — `--sname` not working)

If the connection is not established, `Node.list()` AND `Node.list(:hidden)` both return `[]`.

---

### Hypothesis 4: Wrong FLEZHA_NODE value

- `docker-compose.dev.yml` sets `FLEZHA_NODE: flezha@fui_agent` (agent hostname = `fui_agent`) ✓
- `docker-compose.yml` sets `FLEZHA_NODE: flezha@flezha_agent_dev` (for external network setup)

If using `docker-compose.dev.yml` but the agent container's hostname differs from `fui_agent`, the connection target is wrong.

---

### Hypothesis 5: `Flezha.list_namespaces/0` doesn't exist or returns wrong format

Even if ERPC connects, the call `Flezha.list_namespaces([])` could:
- Return `{:error, :undef}` if the function doesn't exist on the agent
- Return a non-list that the template can't iterate
- Raise an exception caught by `try/catch` returning `{:error, reason}`

The controller silently returns `[]` on any `{:error, _}`.

---

## Debugging Steps (Not Yet Done)

### Step 1 — Check NodeConnector logs
```sh
docker logs fui_web 2>&1 | grep NodeConnector
```
Expected success: `[NodeConnector] Connected to flezha@fui_agent`
If missing or showing retries → connection is the problem (Hypotheses 2/3/4).

### Step 2 — Check Node.list from inside the web container
```sh
docker exec -it fui_web iex --sname debug --cookie flezha_dev_cookie --remsh flezha_ui@fui_web
```
Then in iex:
```elixir
Node.list()          # should show [:"flezha@fui_agent"]
Node.list(:hidden)   # likely []
```

### Step 3 — Test the ERPC call directly
```elixir
:erpc.call(:"flezha@fui_agent", Flezha, :list_namespaces, [])
```

### Step 4 — Check from the agent side
```sh
docker attach fui_agent   # detach: Ctrl+P Ctrl+Q
```
In iex:
```elixir
Node.list()          # should NOT show UI (it's hidden)
Node.list(:hidden)   # should show [:"flezha_ui@fui_web"]
```

---

## Change History

| # | Change | File | Result |
|---|--------|------|--------|
| 1 | Initial code | — | `Node.list(:hidden)` — empty namespaces |
| 2 | Changed to `Node.list()` | `node_manager.ex` | Attempted fix, then reverted |
| 3 | Added `try/catch` to `erpc_call` | `node_manager.ex` | Fixed 500 crash, kept |
| 4 | Added nil guard `not is_nil(node)` | `node_manager.ex` | Safety fix, kept |
| 5 | Reverted to `Node.list(:hidden)` | `node_manager.ex` | Current state — likely wrong |
| 6 | Added `--hidden` flag | `Dockerfile` | Current state |

---

## Most Likely Fix

Two changes together:

1. **`node_manager.ex:5`** — use `Node.list()` not `Node.list(:hidden)`, because from the UI node's perspective the agent is a regular visible node:
   ```elixir
   Node.list() |> List.first()
   ```

2. **`Dockerfile:50`** — keep `--hidden` (correct — UI should be hidden from cluster gossip)

3. **Verify first** by checking `docker logs fui_web | grep NodeConnector` to confirm the connection is actually established before changing anything else.
