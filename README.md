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
| **Relay** | A running unit of work, started from a factory. How it runs — its *run*, `flow` or `steps` — is its factory's. |
| **Run** | `flow` (each input is processed as it arrives) or `steps` (a durable, journaled sequence of iterations). Announced by the factory's runners; never chosen at start. |
| **Runner** | An SDK-side process serving factories. Relays are bound to one. |
| **Factory** | What a runner registers and a relay is started from. |
| **Tasklet** | A step inside a relay. |
| **Cell** | A keyed unit of state inside a tasklet. |
| **Output** | Where a relay's results leave it. |
| **Task journal** | A durable steps relay's record of committed tasklets and iterations; the only rewind targets. |
| **Input log** | A durable steps relay's journaled inputs, consumed iteration by iteration. |
| **Plugin** | A provider enabled by name in a namespace and bound to a relay on one or more *hooks*. |
| **Provider** | What implements a plugin (`relay_websocket`, `relay_stdout`, …). |
| **Hook** | A point a plugin is bound on: `on_input`, `on_output`, `on_interval`, `on_message`, `on_snapshot`, `on_terminate`, `on_relay_init`. |
| **Hub** | The per-namespace supervision root, placed on one or more cluster nodes. |
| **Posture** | The controller's authorization stance: `open`, `bootstrap_pending`, or `enforced`. |
| **Principal** | The identity a call is made as. The UI's comes only from a verified flezha token — never from a form field. |
| **Role** | What a principal may do in a namespace: `viewer`, `app`, `ops`, `admin`, `runner`, `spawner`, `stopper`. "Operator" in this README means the person using the console. |
| **Quota** | A per-namespace limit (`max_relays`, `max_runners`, state bytes, …) paired with a live counter. |
| **Partition group** | A set of relays that split one keyspace between them, each owning a *key-group* range. |
| **Coverage** | Whether a partition group's members own every key group exactly once. A gap or an overlap is a fault. |
| **Health** | How the Convergence Loop classified a relay: `healthy`, `unknown` (not observed yet), `suspended`, `degraded`, `recovering`, `unbound`, `failed` or `parked`. Suspension is a health value, not a separate flag — which is what makes it readable one call per namespace. |

## Screens

A route carrying a namespace is scoped to it; the rest are platform-global.
The three scoped listings are the *same* LiveViews as their platform twins,
reading the namespace from the path instead of from a filter control, and a
scope switch moves between the two forms.

| Route | Shows |
| --- | --- |
| `/` | Redirects to the Home of the namespace last worked in, then to the first reachable one, then to `/namespaces` |
| `/namespaces/:ns` | **Home** — a headline sentence and the namespace's figures, its open problems (three, then a link), a live map of its sources, runner bands with their relays as lanes, outputs and the dead-letter drain, what happened while the screen was open, and as sections that fold: quotas, access (role bindings and tokens), partition groups, finished relays and runners; drop a runner and readmit its process |
| `/problems` | **Open problems** in every reachable namespace, worst first, each saying what is wrong, why, and offering the action that fixes it |
| `/namespaces` | Declared and running namespaces as tiles, with a health strip, counts and quota breaches |
| `/namespaces/:ns/relays` | That namespace's relays: health, run, node, runner, plugins and the measured rate with its recent history; each opens in an inspector, and its menu opens, inspects or stops it |
| `/namespaces/:ns/plugins` | Plugins enabled in that namespace, where each runs and the relays bound to each; enable, bind, unbind, update, with a typed field for each option the provider declares |
| `/namespaces/:ns/schedules` | Schedules targeting that namespace; the create form opens aimed at it |
| `/relays` | **Fleet** — every relay across every reachable namespace, filterable by namespace, health, run and runner; starts one into any of them; what happened while the screen was open |
| `/namespaces/:ns/relays/:id` | **Live** — one sentence on what the relay is and how it is faring, the pipeline graph — records drawn as they pass, a payload tap opened from its IN and OUT ports, and a sentence and timeline of what the relay is doing — and as sections that fold: diagnosis, the calls made to it from anywhere as they happen, its API and its plugin bindings; send to it, call it, or call an entry channel from a form built from its schema |
| `/namespaces/:ns/relays/:id/listen` | **Listen** — the relay's live outputs or inputs |
| `/namespaces/:ns/relays/:id/state` | **State** — steps facts as sentences, the task journal and input log, SDK state, and durable cells with their sequences and lag; point-in-time reads, a cell's outbox, replay, rotate, delete; retention, the history one settable |
| `/plugins` | Enabled plugins per namespace, the providers on offer, and the packages installed on the controller with why one was refused |
| `/cluster` | Cluster nodes, per-node health rollup, hub recovery per node, runners with what they serve, and which runners serve a factory; drop a runner and readmit its process |
| `/observability` | Observability sources grouped by area with a name filter and an on/off switch each, sinks, and a live signal tail |
| `/controller` | Readiness, authorization and durability in one sentence; durability posture, RPO breaches and the shipper, shutdown and boot state, memory hot spots; drain and stop the controller, watching each phase |
| `/schedules` | Cron schedules with their status and next fire; run one now, after a confirmation |
| `/dlq` | Parked dead-letter entries grouped by tasklet; inspect an entry's payload in place, replay, drop |
| `/audit` | Audit file catalog, filtered reads, live tail, rotation |

Starting a relay is a guided flow: choose a factory (each says what it is, how
it runs and how many runners serve it), give the details, then read the start
back as one sentence before it is made.

## Getting around

The shell models the domain it controls: some concerns are scoped to a
namespace and some are not, and it says which is which.

- **The rail is two labelled sections.** `NAMESPACE` holds Home, Relays,
  Plugins and Schedules; `PLATFORM` holds Problems, Fleet, Namespaces,
  Cluster, Controller, Observability, Dead-letter and Audit. A screen is in the
  first only when the controller call behind it takes a namespace, or the rows
  it returns each carry one. With nothing in scope the first section says so.
- **Problems are counted on the rail.** A per-session pulse reads every
  reachable namespace every ten seconds, with the operator's own token and a
  fixed number of calls per namespace, and the Problems entry shows how many
  are open in the tone of the worst.
- **Scope lives in the URL, never in the session.** `FlezhaUiWeb.Layouts`
  reads it back out of the path on every navigation, so the rail, the picker
  and the screen cannot disagree, and a pasted link opens the scope it names.
- **The topbar's namespace picker means one thing everywhere**: show me this
  namespace. From a scoped screen it re-navigates to the same screen kind under
  the new scope; from a platform screen, to that namespace's Home.
- **Crumbs appear only below a rail destination** — on a relay's views — and
  sit in the page header. A rail destination carries none.
- **A relay's Live, Listen and State are tabs on the object**, and each stays
  its own route: Listen holds a live listener, State does point-in-time reads,
  Live polls overwatch.
- **Objects open in place.** A relay, a runner, a plugin or a parked entry
  opens in an inspector drawer on the current screen, addressed by
  `?inspect=<kind>:<id>` so the link can be shared; Escape closes it.
- **`⌘K` / `Ctrl+K` opens a command palette** that reaches a relay by id, a
  namespace by name or any rail destination by name, and offers actions — stop
  or diagnose a relay, listen to it, run a schedule now — each landing on its
  own screen's confirmation. Its screen index is the rail's own list.
- **`?` explains the screen** — what it shows, the terms on it and the
  keyboard shortcuts — as does the topbar's help control. `g` then `h`, `r`,
  `p` or `c` goes to Home, Relays, Problems or Cluster. Every flezha term on
  screen shows its definition on hover or focus, from one glossary.
- **A long screen opens on what it is for** and folds the rest away, each
  folded section stating what it holds. The viewer's last choice is restored
  from `localStorage`; a breached quota opens its section regardless.
- **Every screen that refreshes says so** — its interval, when it last did, and
  a control to hold it still.

## Dev setup

The compose file brings up the controller, a Rust runner, this UI, Postgres,
and Kafka in one command. It expects two sibling checkouts alongside this one:

| Path | Why |
| --- | --- |
| `../flezha` | The controller, built and bind-mounted into its container |
| `../flezha_stylebook` | The design system. Its tokens, component recipes, fonts and brand lockups are what this console is skinned with. |

The stylebook is an npm `file:` dependency, so install the asset dependencies
once on the host — the `web` container has no Node, and the relative symlink
`npm install` writes travels into it through the repository bind mount:

```bash
mix assets.setup                 # npm install + copy fonts, lockups, favicons
docker compose -f docker-compose.dev.yml up --build
```

Without the stylebook, `mix assets.stylebook` stops with a message naming it
and where it is expected, rather than producing an unstyled build.

Saving `config/config.exs`, `config/dev.exs`, `mix.exs` or `mix.lock` restarts
the `web` container by itself (`FLEZHA_UI_RESTART_ON_CONFIG_CHANGE` on
`fui_web`), so the console picks up the change instead of showing Phoenix's "You
must restart your server" page. Only the VM serving the console watches: an
`iex -S mix` in the container, or a `mix phx.server` on the host, is never
stopped this way.

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

In dev the UI seeds testnet relays — flow and steps, and `orders`, the runner's
relay API fixture — websocket plugins and a `hook_webhook` controller plugin
once the controller is reachable, so Home's map is populated on arrival. See
`:dev_setup` in `config/dev.exs`. Before the controller boots, the
`plugin_packages` service builds the `flezha_http` plugin package with the
controller's toolchain and places it in the plugin root with a copy the loader
refuses, so the plugin screens show a loaded and a refused package
(`priv/dev/plugin_packages.sh`).

### Resetting the dev controller

Controller state written by an older controller is not migrated. To start over
— this **discards all dev controller state**: relays, plugins, schedules,
dead letters, the audit log and the authorization bootstrap — stop the stack,
clear the controller's durable state, drop the UI's token volume so the
bootstrap is claimed again, and bring the stack up:

```bash
docker compose -f docker-compose.dev.yml down
../flezha/target/release/flz reset --yes --include-dlq --include-schedules \
  --include-auth --include-audit --app-data-root ../flezha/app_data
docker volume rm flezha_ui_fui_auth_data
docker compose -f docker-compose.dev.yml up
```

A cold start then seeds cleanly in the current vocabulary.

### Services

| Container | Role |
| --- | --- |
| `fui_plugin_packages` | One-shot: builds and places the plugin packages the controller loads at boot. Any `docker compose up`, even of one service, runs it again, and the controller lists the re-placed packages as pending until `docker restart flezha_controller` |
| `flezha_controller` | The controller, built from `../flezha/docker/dev/Dockerfile.toolchain` |
| `flezha_rust_runner` | `test/apps/rust_runner`, waits for the control socket then connects |
| `fui_bootstrap` | One-shot: claims the authorization bootstrap and issues the UI's token |
| `fui_web` | This app |
| `flezha_ui_db` | Postgres |
| `fui_kafka`, `fui_zookeeper`, `fui_kafka_ui` | Kafka, for the Kafka provider |

Useful commands:

```bash
docker exec fui_web mix compile                      # after editing .ex files
docker logs fui_web 2>&1 | grep EventFeed            # signal feed status
docker logs fui_web 2>&1 | grep ConfigWatcher        # why the console restarted itself
docker attach flezha_controller                      # controller iex (detach: Ctrl+P Ctrl+Q)
docker exec fui_web elixir --sname cli1 --cookie flezha_dev_cookie \
  /flezha_ui/priv/dev/cli_call.exs Relay.call_channel \
  '["default","orders","place",{"pair":"BTC-EUR","amount":1},{}]'   # call as flz does
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
repository, once for the console's colour roles and once for the relay graph's
stylebook tokens. It fails on a `var()` naming a token nobody defines, a token
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
published `Flezha.Service.*` modules by name, in their real return shapes and
with `%Flezha.Error{}` failures, which is how states a live stack refuses to
enter —
a populated dead-letter queue, audit switched off, a disconnected or
version-skewed controller — get covered at all.

Every browser test also fails on a broken page, whatever it asserted: a script
or console error, a LiveView that crashed, or a request answered 400 or above.
A figure the controller feeds is asserted to move, not merely to be there. And
`mix test` fails when a test id or event in `lib/` is driven by no test at all
(`test/flezha_ui/coverage_ledger_test.exs`).

See [docs/e2e-tests.md](docs/e2e-tests.md) for the browser suite's layout, the
guards and their exemptions, the coverage ledger, and the rule for deciding
which layer a new assertion belongs to.

## How it looks

The colours, the shell and the brand come from
[`flezha_stylebook`](../flezha_stylebook), the Flezha group's design system;
the content of every screen is drawn with the console's own component kit.

- **Colour has one source.** The kit reads colour only through `--fui-*` roles
  in `assets/css/console/tokens.css`, and each role names the stylebook token it
  takes — `--fui-ink-1` is `--text-primary`, `--fui-canvas` is
  `--surface-sheet` — so the palette and both themes are the stylebook's. The
  console adds only a signal colour for live data, and the overlay scrim and
  shadow.
- **Status colour states an outcome.** The positive, warning and negative roles
  say healthy, degraded and failed, and every state is also said in words and
  by a shape. The accent marks interaction; the signal marks live data — flow,
  rates, change marks — and never a status.
- **The shell is the stylebook's**: the rail and topbar in the chrome, which is
  pale in light and deep plum in dark, and the content on a square-cornered sheet set
  into the chrome, the only part that scrolls.
- **The content kit** is `assets/css/console/` (`tokens.css`, `base.css`,
  `components.css`) with one function component per element in
  `FlezhaUiWeb.CoreComponents`: buttons, fields, switches, segmented controls,
  comboboxes, chips, state badges, grids with row menus, sections with digests,
  the page header, tabs, drawers, dialogs, popovers, tooltips, toasts,
  sparklines, meters, skeletons, code blocks, steps and identifiers. A screen
  opens on its page header — the kind of object, its name, one sentence on its
  condition, its actions and its tabs — and its sections are separated by space
  and hairlines rather than nested cards. In dev, `/dev/kit` shows every
  component in every state.
- **Type**: flezha.com's faces — Space Grotesk for display, Inter for the
  interface and JetBrains Mono for identifiers and figures — from the
  stylebook's `fonts.css`, served from `priv/static/fonts`.
- **Theme contract**: attribute `data-theme="light|dark"` on `<html>`, storage
  key `flezha-theme`, set before the first paint by the stylebook's inlined
  `theme-hydrate.js`. The toggle sits in the topbar and on the signed-out
  pages, with flezha.com's sun and moon.
- **The relay pipeline graph** draws nodes, wires and dots with the
  stylebook's relay-graph recipe (`.flz-graph-*`). What is the console's own
  stays here as `topo-*` rules: lanes, ports and their listener counts,
  stream bands, the light a passing record leaves, path tracing, the stall
  ring, the flow sentence and the timeline. Its motion is the `FlzPipeline`
  hook: each tick the server pushes how far the relay's counters advanced
  (`pipeline_counts`), replayed as hollow dots over the next tick, and an open
  tap pushes what it heard every 250 ms at most (`pipeline_records`), drawn
  filled with the start of each payload.
- **The gate.** `npm run tokens` runs the stylebook's `check-tokens.mjs` twice:
  over the console's roles, resolved through the stylebook's palette, and over
  the stylebook tokens the graph still reads. Either fails on an undefined or
  unused token, a contrast pairing below WCAG AA in either theme, or a hex,
  `rgb()` or `hsl()` colour written outside a token file.

## How the UI talks to the controller

Every remote call goes through `FlezhaUi.Service.NodeManager`, which is the
only module that names a `Flezha.*` module, and every call is a function on
core's **published consumer API**: a `Flezha.Service.*` function listed in
core's `docs/api/consumers/published.txt`, called with the caller context last.
Only two reads go without a context, because a context is built from them:
`Flezha.AuthZ.TokenStore.verify/1` and `Flezha.AuthZ.enforcement_posture/0`.
`test/flezha_ui/service/published_surface_test.exs` holds the console to that
with core's own extractor and list (`FLEZHA_CORE_PATH`, default `../flezha`).

A call answers the published function's own value, or its
`{:error, %Flezha.Error{}}` — code, class, message, hint — untouched, or one of
the transport conditions only this node sees: not connected, API missing,
timeout, remote error. `NodeManager.error/1` reads any of them as one map, so a
screen decides how to present an error from its class and code, never from its
text, and a refusal reads as a refusal with the controller's own message rather
than as an empty table. `CoreComponents.runtime_error/1` renders every one of
them, and a diagnosis finding, with its code, its hint and a link to the code's
family in core's errors reference (`:core_docs_url`, default
`https://docs.flezha.com`).

Controls follow the bound role. The operations a token's role grants are read
once with its verification, from the `operations` that
`Flezha.Service.Namespace.whoami/1` answers, and `NodeManager.granted?/2` decides
whether a control renders. A controller that answers no list, or one whose
posture is `:open`, renders every control; either way the controller still
judges each call.

Identity works the way the controller's own CLI does it: a principal comes
*only* from `Flezha.AuthZ.TokenStore.verify/1`. A name typed into this UI is
never placed in a caller context, because that context is what the controller's
audit log records. Verifications are cached briefly — never past the token's
own expiry, and never for a transient `authz.registry_unavailable`. A refused
call evicts the entry. The controller sees only the principal, never the token,
so a revoked token stops working when its cached verification expires. A
verification the token store cannot answer is reported as that failure; the
call is never made unbound.

Behaviour shared across screens is a `use`-able module rather than a copied
block: `FlezhaUiWeb.Live.Refresh` (the tick, the forwarded runner events —
ignored by a screen scoped to another namespace — and what a screen says
about its own currency), `FlezhaUiWeb.Live.Tail` (a live
tail), `FlezhaUiWeb.Topology` (the pipeline graph and fleet summary),
`FlezhaUiWeb.Live.Launcher` (starting a relay, rendered by both
`/namespaces/:ns` and `/relays`), `FlezhaUiWeb.Live.PluginForm` (enabling,
binding and updating a plugin, from a relay's screen and the plugins screen),
`FlezhaUiWeb.Live.Target` (the namespace and
factory a write is aimed at, shared by the launcher and the schedule form) and
`FlezhaUiWeb.Live.Sections` (which of a long screen's panels are open). A write
path implemented twice drifts, and the half that drifts is the one nobody is
looking at.

Live data rides `FlezhaUi.Service.EventFeed`, and **no code of this
application runs on the controller**. A feed holds one published stream
operation — `Observability.tail/2`, `AuditLog.tail/2` or `Relay.listen/5` —
open with `:erpc.send_request/4`, passing its own pid as the caller context's
`:emit`; the controller hands each event to it as `{:flezha_emit, event}`.
Runner connects and disconnects are observability signals on `:flezha_runner`,
which a supervised feed tails and broadcasts on `"flezha:events"`; relay starts,
stops and exits on `:flezha_relay` get a supervised feed of their own, on
`"flezha:relays"`, which only the relays index hears; the audit
and observability tails, the listen screen, the pipeline graph's payload tap
and the relay screen's Calls section (a `:calls` listen, held only while the
section is open) each hold a feed linked to the screen. The controller watches the feed's pid,
so stopping the feed — or closing the screen — releases the subscription. There
is no second mechanism. `EventFeed.stop/2` also drops what the feed already
sent under its tag, so a screen that replaces a feed never hears the old one,
and a retrying feed reports a reconnect only once its re-opened stream is held.

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
