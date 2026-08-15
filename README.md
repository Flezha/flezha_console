# FlezhaUi

A Phoenix LiveView control panel for a [flezha](../flezha) controller. It holds
no domain state of its own — every screen is a projection of a remote call over
Erlang distribution.

## Vocabulary

The UI uses the controller's terms exactly. If a name here disagrees with
`flezha`, this app is the one that is wrong.

| Term | What it is |
| --- | --- |
| **Namespace** | An isolated control-plane scope. Everything below lives in one. |
| **Operative** | A running compute unit. Has a *kind* (`:stream`, `:workflow`) fixed at start. |
| **Runner** | An SDK-side process serving factories. Operatives are bound to one. |
| **Factory** | A compute-unit class a runner registers and can instantiate. |
| **Entity** | A keyed unit of state inside an operative, grouped by *Procedure*. |
| **Plugin** | A provider subscribed to one or more *extension points* on an operative. |
| **Provider** | The module implementing a plugin's behaviour (websocket, Kafka, stdout, …). |
| **Extension** | A hook a plugin subscribes to: `on_input`, `on_output`, `on_interval`, `on_message`, `on_snapshot`, `on_terminate`, `on_operative_init`. |
| **Hub** | The per-namespace supervision root, placed on one or more cluster nodes. |

## Screens

| Route | Shows |
| --- | --- |
| `/` | Connected controller, counts, runners, namespace links |
| `/namespaces` | Namespaces with operative and runner counts |
| `/namespaces/:ns` | A namespace's operatives, runners, factories; start and stop operatives |
| `/namespaces/:ns/operatives/:id` | Kind, runner, factory, uptime, entity state, attached plugins |
| `/namespaces/:ns/operatives/:id/stream` | Live input/output stream |
| `/plugins` | Enabled plugins with provider, extensions, and target |
| `/cluster` | Cluster nodes, hub placement, runner fleet, factory placement |
| `/schedules` | Cron schedules with live job status and next fire |
| `/dlq` | Parked dead-letter entries; inspect, replay, drop |
| `/audit` | Audit file catalog, filtered reads, live tail |

## Dev setup

The compose file brings up the controller, a Rust runner, this UI, Postgres,
and Kafka in one command. It expects the `flezha` repo checked out alongside
this one at `../flezha`.

```bash
docker compose -f docker-compose.dev.yml up --build
```

First run only — create the database and the dev user:

```bash
docker exec fui_web mix ecto.migrate
docker exec fui_web mix run priv/repo/seeds.exs
```

Then log in at http://localhost:4000 with:

- **Email:** `dev@flezha.local`
- **Password:** `dev_password_123`

In dev the UI seeds testnet operatives and websocket plugins once the
controller is reachable, so the dashboard is populated on arrival. See
`:dev_setup` in `config/dev.exs`.

### Services

| Container | Role |
| --- | --- |
| `flezha_controller` | The controller, built from `../flezha/docker/dev/Dockerfile.toolchain` |
| `flezha_rust_runner` | `test/apps/rust_runner`, waits for the control socket then connects |
| `fui_web` | This app |
| `flezha_ui_db` | Postgres |
| `fui_kafka`, `fui_zookeeper`, `fui_kafka_ui` | Kafka, for the Kafka provider |

Useful commands:

```bash
docker exec fui_web mix compile                      # after editing .ex files
docker logs fui_web 2>&1 | grep EventBridge          # relay status
docker attach flezha_controller                      # controller iex (detach: Ctrl+P Ctrl+Q)
```

## Tests

Two layers, and an assertion lives at the layer that can produce the state it
asserts.

```bash
mix test                      # ExUnit: units, LiveViews, distributed integration
mix test --exclude distributed  # the fast loop — no peer nodes booted

npx playwright install chromium  # one-time
npm run e2e                   # browser suite, needs the dev stack running
npm run e2e:ui                # same, in Playwright's UI mode
```

`npm run e2e` drives the running dev stack at `http://localhost:4000`, so bring
it up first with `docker compose -f docker-compose.dev.yml up`. A failing test
means the stack is not in the shape the suite requires — the specs assert
unconditionally rather than skipping, so a green run means the assertions ran.

The ExUnit LiveView tests boot a peer BEAM node with this app's own `ebin`
excluded from its code path, standing in for a controller that carries none of
this application's code. `test/support/fake_controller.ex` answers as the
controller modules by name, which is how states a live stack refuses to enter —
a populated dead-letter queue, audit switched off, a disconnected or
version-skewed controller — get covered at all.

See [docs/e2e-tests.md](docs/e2e-tests.md) for the browser suite's layout and
the rule for deciding which layer a new assertion belongs to.

## How the UI talks to the controller

Every remote call goes through `FlezhaUi.Service.NodeManager`, which is the
only module that names a `Flezha.*` module. It normalises failures into four
shapes — not connected, API missing, timeout, remote error — so a controller
that has moved on shows a banner naming the missing function instead of
crashing a LiveView.

Subscriptions are different. The controller's event bus and audit tail both
register the *calling* process, and an `:erpc` call runs in a process that dies
when the call returns. So `FlezhaUi.Service.EventBridge` ships
`FlezhaUi.Service.EventRelay`'s **source** to the controller, compiles it
there, and spawns it — a relay that lives on the controller and forwards back.
Source rather than a compiled beam, because the two nodes need not run the same
Erlang/OTP release.

## Manual setup (no Docker)

```bash
# UI
iex --name flezha_ui@flezha_ui_web.flezha_network --cookie flezha_cluster_cookie --hidden -S mix phx.server

# Controller, from the flezha repo
iex --name flezha@flezha_controller.flezha_network --cookie flezha_cluster_cookie -S mix
```

Connect them from either side:

```elixir
Node.connect(:"flezha@flezha_controller.flezha_network")
```
