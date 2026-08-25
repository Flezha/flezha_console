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
| **Posture** | The controller's authorization stance: `open`, `bootstrap_pending`, or `enforced`. |
| **Principal** | The identity a call is made as. The UI's comes only from a verified flezha token — never from a form field. |
| **Quota** | A per-namespace limit (operatives, runners, state bytes, …) paired with a live counter. |
| **Partition group** | A set of operatives that split one keyspace between them, each owning a *key-group* range. |
| **Coverage** | Whether a partition group's members own every key group exactly once. A gap or an overlap is a fault. |
| **Health** | How the Convergence Loop classified an operative: `healthy`, `suspended`, `degraded`, `unbound`, `failed`, or `unknown` when it has not been observed yet. Suspension is a health value, not a separate flag — which is what makes it readable one call per namespace. |

## Screens

A route carrying a namespace is scoped to it; the rest are platform-global.
The three scoped listings are the *same* LiveViews as their platform twins,
reading the namespace from the path instead of from a filter control.

| Route | Shows |
| --- | --- |
| `/` | Connected controller, counts with a health breakdown, runners, namespace links |
| `/namespaces` | Declared and running namespaces, their counts, and quota breaches |
| `/namespaces/:ns` | Operatives with health; quotas, role bindings, partition groups, finished instances and runners as sections that fold |
| `/namespaces/:ns/operatives` | That namespace's operatives, its scope fixed rather than filterable |
| `/namespaces/:ns/plugins` | Plugins bound to an operative in that namespace |
| `/namespaces/:ns/schedules` | Schedules targeting that namespace; the create form opens aimed at it |
| `/operatives` | **Fleet** — every operative across every reachable namespace, filterable by namespace, health and kind; starts one into any of them |
| `/namespaces/:ns/operatives/:id` | Kind, runner, factory, uptime, health, node, workflow profile; journal, inbox, entity state and plugins as sections that fold |
| `/namespaces/:ns/operatives/:id/state` | Durable entities with their WAL/snapshot sequences and durability lag; point-in-time reads |
| `/namespaces/:ns/operatives/:id/stream` | Live input/output stream |
| `/plugins` | Enabled plugins, and the catalog installed on the controller |
| `/cluster` | Cluster nodes, per-node health rollup, hub recovery, runner fleet |
| `/observability` | Observability sources and sinks, their enabled state, and a live signal tail |
| `/controller` | Durability posture and RPO breaches, shutdown and boot state, authorization posture, memory hot spots |
| `/schedules` | Cron schedules with live job status and next fire |
| `/dlq` | Parked dead-letter entries grouped by procedure; inspect, replay, drop |
| `/audit` | Audit file catalog, filtered reads, live tail |

## Getting around

The shell models the domain it controls: some concerns are scoped to a
namespace and some are not, and it says which is which.

- **The rail is two labelled sections.** `NAMESPACE` holds Overview,
  Operatives, Plugins and Schedules; `PLATFORM` holds Dashboard, Fleet,
  Namespaces, Cluster, Controller, Observability, Dead-letter and Audit. A
  screen is in the first only when the controller call behind it takes a
  namespace, or the rows it returns each carry one — which is why Dead-letter
  (keyed by operative class) and Observability (namespace-less) stay in the
  second. With nothing in scope the first section says so instead of offering
  destinations it has no scope to point at.
- **Scope lives in the URL, never in the session.** `FlezhaUiWeb.Layouts`
  reads it back out of the path on every navigation, so the rail, the picker
  and the screen cannot disagree, and a pasted link opens the scope it names.
- **The namespace picker means one thing in both places**: show me this
  namespace. From a scoped screen it re-navigates to the same screen kind under
  the new scope; from a platform screen, to that namespace's overview.
- **Breadcrumbs are derived from the route, once**, in the same `on_mount` hook
  that marks the current destination — not assembled per screen. There is no
  back arrow.
- **An operative's Detail, Stream and State are a tab strip on the object**,
  and each stays its own route: Stream holds a live subscription, State does
  point-in-time reads, Detail polls overwatch. They are three processes with
  three lifecycles, and collapsing them would leave a stream attached while the
  operator reads something else.
- **`⌘K` / `Ctrl+K` opens a command palette** that reaches an operative by id, a
  namespace by name, or any screen by name. Its screen index is the rail's own
  list, so it can offer nothing the rail does not. The operative index is read
  on first open — never on mount — and dropped again on the same lifecycle
  events the screens refresh on.
- **A long screen opens on what it is for** and folds the rest away. Which
  sections start open is the screen's own declaration; the viewer's last choice
  is restored over it from `localStorage`, and a browser that refuses to store
  anything leaves the declared defaults standing. A breached quota outranks
  both and opens its section regardless.
- **Every screen that refreshes says so** — its interval, when it last did, and
  a control to hold it still. Pausing is the operator's; a screen that already
  suspends its tick for an open modal still does, independently.

## Dev setup

The compose file brings up the controller, a Rust runner, this UI, Postgres,
and Kafka in one command. It expects two sibling checkouts alongside this one:

| Path | Why |
| --- | --- |
| `../flezha` | The controller, built and bind-mounted into its container |
| `../flezha-stylebook` | The design system. Its tokens, component recipes, fonts and brand lockups are what this console is skinned with. |

The stylebook is an npm `file:` dependency, so install the asset dependencies
once on the host — the `web` container has no Node, and the relative symlink
`npm install` writes travels into it through the repository bind mount:

```bash
mix assets.setup                 # npm install + copy fonts, lockups, favicons
docker compose -f docker-compose.dev.yml up --build
```

Without the stylebook, `mix assets.stylebook` stops with a message naming it
and where it is expected, rather than producing an unstyled build.

The controller enforces authorization by default, so the stack claims its own
bootstrap: a one-shot `bootstrap` service waits for the controller node, claims
the bootstrap, issues a `_system` token and writes it to a shared volume. The
UI reads it through `FLEZHA_TOKEN_FILE` — a file rather than an env var because
the token does not exist until the controller has booted. A restart reuses the
token already written; nothing is re-claimed.

`FLEZHA_AUTHZ_ENABLED` is set to `true` on the controller deliberately. A dev
stack that switched enforcement off would leave the UI's whole identity path —
token, principal, refusals — untested locally.

A signed-in user may store their own flezha token under **Settings**, which then
rides their calls so the controller's audit log names the human rather than the
app. It is encrypted at rest and never rendered back.

After every `docker compose down` — create the database and the dev user:

```bash
docker exec fui_web mix ecto.migrate
docker exec fui_web mix run priv/repo/seeds.exs
```

The `db` service keeps its data in the container rather than a named volume, so
`down` discards it and the next `up` starts on an empty database. A stack that
was only stopped and started again keeps everything, and these two commands are
then no-ops.

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
| `fui_bootstrap` | One-shot: claims the authorization bootstrap and issues the UI's token |
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

npm run tokens                # the design-token gate over assets/ and lib/
```

`npm run tokens` runs the stylebook's own `check-tokens.mjs` over this
repository. It fails on a `var()` naming a token nobody defines, a token
defined but never referenced, and any ink/surface pairing below its WCAG AA
floor in either theme — so a colour that only looks fine in dark mode is caught
before it ships.

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

## How it looks

Everything visual comes from [`flezha-stylebook`](../flezha-stylebook), the
Flezha group's design system. This repository defines **no colours of its own**
— `npm run tokens` enforces that.

- **Three CSS layers**, imported in order from `assets/css/app.css`:
  `tokens.css`, `base.css`, `components.css`. They land after Tailwind's base
  layer and before its utilities, so the stylebook's reset and form baseline
  win over preflight while a utility still wins over a component recipe.
  Tailwind keeps doing layout and spacing; the stylebook owns colour, type and
  component skins.
- **The alias layer** in `assets/tailwind.config.js` maps every colour, font
  and shadow utility onto a stylebook token, so existing utility classes
  inherit the palette rather than being rewritten one by one.
- **Theme contract**: attribute `data-theme="light|dark"` on `<html>`, storage
  key `flezha-theme`, dark by default, no `prefers-color-scheme` fallback. The
  stylebook's `theme-hydrate.js` is inlined in `<head>` at compile time, so the
  attribute is set before the first paint and there is no flash of the wrong
  theme. The control is `<button data-flz-theme-toggle>` inside the account
  menu, bound by the stylebook's own `bindThemeToggles()`.
- **Chrome is theme-invariant.** The sidebar and topbar stay deep plum in both
  themes with gold marking hover and the current destination; only the content
  canvas flips.
- **Fonts and brand assets** are copied out of the stylebook into
  `priv/static/` by `mix assets.stylebook` (wired into `assets.setup`,
  `assets.build` and `assets.deploy`) and committed, so the Node-less container
  serves them with no extra step.
- **Controls come from one vocabulary.** Text inputs, selects, textareas,
  checkboxes and the dropdown trigger are all skinned by the stylebook's
  `base.css`, so they are the same box; labels, hints and errors are
  `.flz-field-*`. A picker whose menu needs styling — a filter — is a
  `<.dropdown>` (a menu button, since the OS draws a `select`'s menu and it
  cannot be themed); a `select` stays the control inside a dialog. A panel of
  *actions* rather than values — the account controls, the namespace to scope
  to — is a `<.menu>`, which shares the same panel and the same open/close hook.
  An exclusive pair or triple is `.flz-segmented`.
- **Every labelled control is `<.input>`**, the one field component in
  `FlezhaUiWeb.CoreComponents`. It renders the label, the control, the hint and
  the errors, and it is where a control class string lives — no template
  carries one. A field whose values the controller can enumerate is
  `<.enumerated_field>`, which offers them and falls back to free text only
  when the listing was refused. A dialog names its *role* — `confirm`, `form`,
  `wide` — and `<.dialog>` maps it to a width, so "how wide is a form modal" has
  one answer.
- **Status colour states an outcome, and is never a brand colour.** Green
  (`--positive`), amber (`--warning`) and red (`--negative`) say healthy,
  degraded and failed. Gold (`--accent-solid`) marks interaction and magenta
  (`--brand-solid`) is the brand fill; neither is a status. Every solid fill
  uses its matched foreground token — never white on amber.
- **A component another Flezha surface could reuse goes upstream**, into the
  stylebook's `components.css` — not into a local stylesheet. The topology
  graph's `topo-*` rules stay here because nothing else would use them; they
  consume stylebook tokens like everything else.

## How the UI talks to the controller

Every remote call goes through `FlezhaUi.Service.NodeManager`, which is the
only module that names a `Flezha.*` module. It normalises failures into five
shapes — not connected, API missing, timeout, **forbidden**, remote error — so
a controller that has moved on shows a banner naming the missing function
instead of crashing a LiveView, and a refusal reads as a refusal with a remedy
rather than an empty table.

Identity works the way the controller's own CLI does it: a principal comes
*only* from `Flezha.AuthZ.TokenStore.verify/1`. A name typed into this UI is
never placed in a caller context, because that context is what the controller's
audit log records. Verifications are cached briefly — never past the token's
own expiry — and a refused call evicts the entry, so a revoked token stops
working within one call rather than one cache lifetime.

Behaviour shared across screens is a `use`-able module rather than a copied
block: `FlezhaUiWeb.Live.Refresh` (the tick, the relayed events, and what a
screen says about its own currency), `FlezhaUiWeb.Live.Tail` (a
controller-resident tail), `FlezhaUiWeb.Topology` (the pipeline graph and fleet
summary), `FlezhaUiWeb.Live.Launcher` (starting an operative, rendered by both
`/namespaces/:ns` and `/operatives`), `FlezhaUiWeb.Live.Target` (the namespace
and factory a write is aimed at, shared by the launcher and the schedule form)
and `FlezhaUiWeb.Live.Sections` (which of a long screen's panels are open). A
write path implemented twice drifts, and the half that drifts is the one nobody
is looking at.

Subscriptions are different. The controller's event bus, audit tail and
observability tail all register the *calling* process, and an `:erpc` call runs
in a process that dies when the call returns. So `FlezhaUi.Service.EventBridge`
ships `FlezhaUi.Service.EventRelay`'s **source** to the controller, compiles it
there, and spawns it — a relay that lives on the controller and forwards back.
Source rather than a compiled beam, because the two nodes need not run the same
Erlang/OTP release. All three subscription kinds ride that one relay; there is
no second mechanism.

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
