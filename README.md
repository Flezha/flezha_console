# Flezha Console

[![CI](https://github.com/Flezha/flezha_console/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Flezha/flezha_console/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Flezha/flezha_console)](https://github.com/Flezha/flezha_console/releases/latest)
[![Docker](https://img.shields.io/docker/v/flezha/flezha_console?label=docker&sort=semver)](https://hub.docker.com/r/flezha/flezha_console)
[![License](https://img.shields.io/badge/license-MPL--2.0-blue)](LICENSE)

The Phoenix LiveView console for a [Flezha](https://github.com/Flezha/flezha) controller. It holds
no domain state of its own: every screen is a projection of a call to the
controller over its HTTPS channel, the controller's HTTP API, with a client
certificate and the operator's flezha token. The console holds no cookie and
starts no Erlang distribution toward the controllers.

![Starting a relay from the console: pick a factory, name the relay, review and start it](docs/console-start-a-relay.webp)

## Vocabulary

The console uses the controller's terms exactly. If a name here disagrees with
`flezha`, this app is the one that is wrong.

| Term | What it is |
| --- | --- |
| **Namespace** | An isolated control-plane scope. Everything below lives in one. |
| **Relay** | A running unit of work, started from a factory. How it runs — its *run*, `flow` or `steps` — is its factory's. |
| **Run** | `flow` (each input is processed as it arrives) or `steps` (a durable, journaled sequence of iterations). Announced by the factory's runners; never chosen at start. |
| **Runner** | An SDK-side process serving factories. Relays are bound to one. |
| **Factory** | What a runner registers and a relay is started from. |
| **Tasklet** | A step inside a relay. |
| **each** | How a steps factory loops: `once` (one pass over its first message), `per_input` (one pass per message, for as long as the run lives) or `chained` (each pass feeds the next, ending on an empty handoff). |
| **on_failure** | How far a failed steps run is undone: `undo_all` (every finished step) or `keep_progress` (only the pass in flight). |
| **Compensation** | A step's undo: a tasklet declaring a `compensate` hook reverses its work when its run fails or is stopped. |
| **keep_finished** | What a factory keeps of a finished run: nothing by default, or its Cells and completion record for some hours. |
| **Relay history** | The controller's durable record of every relay run: one line when it starts and one when it ends, with who started it, how it ended and how long it ran. It outlives the run's state, which a factory keeps only when it declares `keep_finished`. |
| **Source plugin** | A plugin whose provider feeds a relay, such as a websocket or a poll; it injects records on the entry channel it names, or on the relay's first. |
| **Input filter** | A plugin bound on `on_input`: it runs before a record enters the relay, and a record it skips never reaches a tasklet. |
| **Entry channel** | A named channel records enter a relay on; a plugin feeding the relay names the entry it attaches to. |
| **Output channel** | A channel that leaves a relay for its plugins; each output plugin takes the records of the channels it names. |
| **No plugin bound** | An output channel no plugin takes from: only a listener, such as a tap, sees its records. |
| **Folded run** | Four or more tasklets in a row, each reading only the one before it, drawn as one node until expanded. |
| **Backlog** | Inputs queued at a tasklet faster than it takes them, marked once its deepest Cell has held a queue for two readings. |
| **Shed** | Inputs a tasklet dropped: a full mailbox under a dropping overflow policy, or a new key at the Cell cap. |
| **Cell** | A keyed unit of state inside a tasklet; a tasklet's Cells are listed, busiest first, when it is selected on the relay's graph. |
| **Output** | Where a relay's results leave it. |
| **Task journal** | A durable steps relay's record of committed tasklets and iterations; the only rewind targets. |
| **Input log** | A durable steps relay's journaled inputs, consumed iteration by iteration. |
| **Plugin** | A provider enabled by name in a namespace and bound to a relay on one or more *hooks*. |
| **Provider** | What implements a plugin (`relay_websocket`, `relay_stdout`, …). |
| **Hook** | A point a plugin is bound on: `on_input`, `on_output`, `on_interval`, `on_message`, `on_snapshot`, `on_terminate`, `on_relay_init`. |
| **Hub** | The per-namespace supervision root, placed on one or more cluster nodes. |
| **Posture** | The controller's authorization stance: `open`, `bootstrap_pending`, or `enforced`. |
| **Principal** | The identity a call is made as. The console's comes only from a verified flezha token — never from a form field. |
| **Role** | What a principal may do in a namespace: `viewer`, `app`, `ops`, `admin`, `runner`, `spawner`, `stopper`. "Operator" in this README means the person using the console. |
| **Quota** | A per-namespace limit (`max_relays`, `max_runners`, state bytes, …) paired with a live counter. |
| **Flow in** | Records arriving at a namespace's relays each second, summed; its Out is what they forwarded to their outputs. |
| **Partition group** | A set of relays that split one keyspace between them, each owning a *key-group* range. |
| **Coverage** | Whether a partition group's members own every key group exactly once. A gap or an overlap is a fault. |
| **Suspended** | A relay stopped at a committed boundary on purpose, not by a fault. It holds no runner; the next message or its timer wakes it on a runner that serves its factory. |
| **Halted** | A relay a fault stopped that the system cannot fix by itself; Flezha retries its bind with a growing delay, but it stays stopped until a person fixes the cause. |
| **Unbound** | A relay no runner is bound to; the Convergence Loop binds it once a runner serving its factory can take it. |
| **Failed** | A relay whose runner is gone past its grace; the Convergence Loop rebinds it. |
| **Recovering** | An unbound or failed relay still inside its grace. |
| **Degraded** | A relay that runs but not as declared; the Convergence Loop repairs it in place. |
| **Dead letter** | A record a tasklet could not process, kept in the dead-letter queue to be inspected, replayed or dropped. An operator can mark one *seen*: it stays in the queue but is no longer an open problem, until it parks again under a new generation. |
| **WAL seq** | The sequence number of the last change a cell wrote to its write-ahead log. |
| **Snapshot seq** | The change a cell's newest snapshot covers; the gap to WAL seq is what a restart replays. |
| **Fsync lag** | How long a cell's changes waited before a disk sync made them durable. |
| **Lagging** | A cell whose fsync lag is above one second and still rising between the State screen's readings. |
| **Health** | How the Convergence Loop classified a relay: `healthy`, `unknown` (not observed yet), `suspended`, `degraded`, `recovering`, `unbound`, `failed` or `halted`. Suspension is a health value, not a separate flag — which is what makes it readable one call per namespace. |
| **Handled by** | Who acts next on a condition: *Nobody* (planned), *Flezha* (the system is fixing it) or *You* (an operator has to act). Only a condition Flezha or you handle is an open problem. |

## Screens

A route carrying a namespace is scoped to it; the rest are platform-global.
The scoped listings are the *same* LiveViews as their platform twins,
reading the namespace from the path instead of from a filter control, and a
scope switch moves between the two forms.

| Route | Shows |
| --- | --- |
| `/` | Redirects to the Dashboard of the namespace last worked in, then to the first reachable one, then to `/namespaces` |
| `/namespaces/:ns` | **Dashboard** — a headline sentence and the namespace's figures with the connected controllers, indicator tiles for the namespace (relays by health with a link per verdict, runners, plugins, schedules, dead letters, the namespace's summed inbound flow with its history, the two fullest limits), its open problems below them, its relays' dead letters among them (three, then a link), what happened while the screen was open, and as sections that fold: quotas, access (role bindings with when and by whom each was bound, and tokens with their issue, expiry and revoke times, filtered by status), partition groups (read while the section is open), recent runs — the namespace's ended runs from the relay history, newest first, each a sentence in its outcome's tone, grown page by page into older ones and counting in its title the shown runs that did not complete — and runners; drop a runner and readmit its process |
| `/problems` | **Open problems** in every reachable namespace, worst first, a page at a time — read from each namespace's 50 most severe relays, with one item saying how many more are not healthy that reads more of them on request — only what Flezha is fixing or you have to act on, so not a dead letter marked seen; dead letters are a warning, since their records wait safely for a replay or a drop — each card with the same rows (state, cause, impact, handled by, next step) and the action that fixes it; relays that wait only on a missing runner fold into one card for their factory |
| `/namespaces` | Declared and running namespaces as tiles, with a health strip, counts and quota breaches |
| `/namespaces/:ns/relays` | That namespace's relays: health, run, node, runner, plugins and the measured rate — messages a second, and bytes where the controller counts them — with its recent history; read a page at a time from the controller, searched by relay id or factory, filtered and sorted by id or severity there, the view in the address; grown up to 500 rows, then the foot asks to search or filter; a relay's name and its Open button go to its page, an opened partition group pages its members, a row opens in an inspector, and its menu opens, inspects or stops it |
| `/namespaces/:ns/factories` | **Factories** — every factory a runner announces in that namespace, running or not, with its description, how it runs and the runners and controllers serving it; `/factories` lists every reachable namespace's, each under its name |
| `/namespaces/:ns/factories/:id` | One factory, whether or not an instance of it runs: a sentence on how it runs — its run, what one pass is (`each`) and what a failed run undoes (`on_failure`) — the runners and controllers serving it, what it declares (durability, sleep, time limit, delivery, acknowledgement, corrections, partitioning, whether it keeps a finished run's state), whether it can undo a failed run and which tasklets compensate, with a warning when `undo_all` has nothing to undo, its graph drawn still by the relay graph with compensating tasklets marked, its entry API, and its last 10 runs from the relay history, each linking to its records and all of them to the Logs screen. Reached from the rail, the launcher's chosen factory, a relay's header, the Cluster screen's factory lookup and the command palette |
| `/namespaces/:ns/plugins` | Plugins enabled in that namespace, where each runs and ten of the relays bound to each with how many more, a page at a time, searched by name and filtered by provider or bound relay, the view in the address; enable, bind — the relay picked by typing part of its id — unbind one of the ten or, through "Unbind another relay…", any relay found by a search, update, with a typed field for each option the provider declares |
| `/namespaces/:ns/schedules` | Schedules targeting that namespace; the create form opens aimed at it |
| `/relays` | The Relays screen's **All namespaces** switch — every relay across every reachable namespace, a page per namespace merged by namespace, searchable, filterable by namespace, health, run and runner and sortable; starts one into any of them; what happened while the screen was open |
| `/namespaces/:ns/relays/:id` | **Live** — one sentence on what the relay is and how it is faring, the pipeline graph — its sources, input filters, entry channels, tasklets, output channels and the plugins and called relays they end at, in one layout drawn left to right or top to bottom and fitted to its panel, records moving in the order they pass, what each channel carries beside its name, each tasklet's input rate, backlog, shed and dead-letter badges and a table of its Cells, a payload tap opened from any channel port, and a sentence and timeline of what the relay is doing — and as sections that fold: its condition — state, cause, impact, runner, handled by, next step and, on request, the diagnosis — the calls made to it from anywhere as they happen, its API and its plugin bindings; send to it, call it, or call an entry channel from a form built from its schema — Send stays open when no runner serves its factory, saying what will happen to the message, while Call waits for a runner; a partition member's menu opens any partition of its group on the same view, here and on Listen and State; a Recent activity strip of the relay's own history records, kept live while the screen is visible, linking to its whole history; a relay that has ended opens on its last run — outcome, start and end, duration, who started it and its error — and says whether its state was kept, and until when |
| `/namespaces/:ns/relays/:id/listen` | **Listen** — the relay's live outputs or inputs |
| `/namespaces/:ns/relays/:id/state` | **State** — steps facts as sentences, the task journal a page at a time and the input log's undelivered count, SDK state, and durable cells with their sequences and lag, a page at a time and searched by key, the lag chart drawn for the cells shown, each column and row action explained beside it; point-in-time reads, a cell's outbox, replay, rotate, delete; rewind to one of the 20 newest committed iterations or, through Older, any before them; retention, the history one settable, and whether the factory keeps a finished run's state; a run that ended without its state kept says so, with a link to how it ended, instead of empty sections |
| `/plugins` | Enabled plugins per namespace, the providers on offer and the controllers lacking one, and the packages installed on each controller with why one was refused |
| `/cluster` | How many controllers are connected and on which machines, overview tiles for everything the token reaches (namespaces, controller nodes, runners, relays by health, open problems — "Urgent" or "Attention" by the worst — and controller health), cluster nodes, each namespace's relays by health and per node as the controller counts them, the relays with no live node, hub recovery per node (a notice only while a hub is recovering), runners — each with its node, connection time, last contact (late ones flagged and listed first), a link to its relays and what it serves, with a summary, a filter, a node choice, "Late only" and a sort — and which runners serve a factory; drop a runner and readmit its process |
| `/observability` | Every source the controllers report through, listed once, grouped by area and headed by its plain title, each saying what it is, whether anything failed in the last 15 minutes (failing sources first) and what else it said, with a filter, an on/off switch that applies to every controller (half-way, with "On 2 of 3 controllers", while it is on for some), the sinks in one line, and a tail that opens with the source's recent history, tells each signal as a sentence about its subject with its time and controller and its raw fields behind Details, and lists what the source can say, failures first |
| `/controller` | Readiness, authorization and durability in one sentence; every controller of the cluster with its machine, address, version, uptime and runners, the one this console reached marked; choose one (`?controller=`, this console's by default) for its durability posture, RPO breaches and the shipper with the time left to each retry, shutdown and boot state, and memory hot spots by name with their queue and initial call |
| `/schedules` | Cron schedules on every controller with their status (active, inactive or dormant), the controller holding each (filterable when there are several), creation time, last fire with its outcome and the relay it started, and the next fire the job is armed for; run one now, after a confirmation |
| `/dlq` | Dead letters on every controller, newest first a page at a time, grouped by tasklet with each tasklet's count, each with the controller holding it (filterable when there are several), when it was dead-lettered, its attempts, size and whether it waits or is replaying, and the queue's total size; inspect an entry's payload in place, replay, drop, or mark one or a whole tasklet's seen — seen ones are listed only with "Show seen" and raise no problem |
| `/logs/:kind` | **Logs** — one tab per log the controller declares (the audit log, the relay history, and any it adds later), each with the filters and columns its declaration names, carried in the address so a filtered view can be linked to; reads newest first across every controller, Read more by the answer's cursor up to 5000 records, rows with an Open label that open to the whole record, the relay history read as one sentence per record linking its relay and factory; each controller's files with the one being written first, its statistics and rotation; a live tail that starts paused, narrowed by the filters. `/logs` opens the first kind and `/audit` redirects to `/logs/audit` |

Starting a relay is a guided flow: choose a factory (each says what it is, how
it runs and how many runners serve it), give the details, then read the start
back fact by fact — factory, how it runs, namespace, relay id, the runners
serving it and the initial values — before it is made.

Every action answers where it was asked: a button shows a spinner while its
call is in flight, a result that renders elsewhere is scrolled into view and
marked, and the outcome is stated in a toast under the topbar. A `?` beside a
screen's title opens its help, and one beside a section explains it.

## Getting around

The shell models the domain it controls: some concerns are scoped to a
namespace and some are not, and it says which is which.

- **The rail is four labelled sections.** `NAMESPACE` holds Dashboard, Relays,
  Factories, Plugins and Schedules; `ATTENTION` holds Problems and Dead-letter;
  `PLATFORM` holds Namespaces, Cluster and Controller; `MONITORING` holds
  Observability and Logs. A screen is in the first only when the
  controller call behind it takes a namespace, or the rows it returns each
  carry one. With nothing in scope the first section says so.
- **The rail stands off the page and folds to its icons.** At desk width it
  runs the screen's full height and casts its edge onto the content. The «
  control in its head collapses it to a strip of icons — each named beside it
  on hover or focus, the Problems count on its icon — and » brings it back.
  The choice is kept in the browser and applied before the first paint.
- **Problems are counted on the rail.** A per-session pulse reads every
  reachable namespace every ten seconds, with the operator's own token and a
  fixed number of calls per namespace, and the Problems entry shows how many
  are open in the tone of the worst. The Cluster screen's overview tiles take
  relay health, problems and durability breaches from the same pulse. The
  pulse reads in a task, one at a time, so a slow controller delays the count
  but never a click.
- **Dashboard answers before it has read.** Dashboard's reads run off its LiveView
  process: the screen connects with its frame and a skeleton, and its figures
  arrive when the read answers. One read is in flight at a time; a tick due
  meanwhile is skipped, and an operator's action is always followed by a read
  that started after it. A read that fails keeps the last figures and says why.
- **Scope lives in the URL, never in the session.** `FlezhaConsoleWeb.Layouts`
  reads it back out of the path on every navigation, so the rail, the picker
  and the screen cannot disagree, and a pasted link opens the scope it names.
- **The topbar's namespace picker means one thing everywhere**: show me this
  namespace. From a scoped screen it re-navigates to the same screen kind under
  the new scope; from a platform screen, to that namespace's Dashboard.
- **Crumbs appear only below a rail destination** — on a relay's views — and
  sit in the page header. A rail destination carries none.
- **A relay's Live, Listen and State are tabs on the object**, and each stays
  its own route: Listen holds a live listener, State does point-in-time reads,
  Live polls overwatch.
- **The whole cluster, or what is missing.** Every screen reads every
  controller through the one it is connected to. When a controller does not
  answer, one notice says how many answered and names the ones that did not,
  and an empty listing says nothing was found on the controllers that
  answered rather than that there is nothing. A row that lives on one
  controller names its machine.
- **Objects open in place.** A relay, a runner, a plugin or a dead letter
  opens in an inspector drawer on the current screen, addressed by
  `?inspect=<kind>:<id>` so the link can be shared; Escape closes it.
- **`⌘K` / `Ctrl+K` opens a command palette** that reaches a relay or a factory by
  id, a namespace by name or any rail destination by name, and offers actions — stop
  or diagnose a relay, listen to it, run a schedule now — each landing on its
  own screen's confirmation. Its screen index is the rail's own list.
- **`?` explains the screen** — what it shows, the terms on it and the
  keyboard shortcuts — as does the topbar's help control. `g` then `d`, `r`,
  `p` or `c` goes to Dashboard, Relays, Problems or Cluster. Every flezha term on
  screen shows its definition on hover or focus, from one glossary, and a
  click pins that definition beside it until Escape or a click elsewhere.
  A definition, like a menu, is kept whole on screen: near an edge it moves
  in, and with no room above it opens below.
- **A long screen opens on what it is for** and folds the rest away, each
  folded section stating what it holds. The viewer's last choice is restored
  from `localStorage`; a breached quota opens its section regardless.
- **Every screen that refreshes says so** — its interval, when it last did, and
  a control to hold it still. Dashboard and the relay page read nothing while their
  tab is hidden, and a burst of relay or runner events costs one read.

### On a phone or tablet

The shell has three modes, by width alone:

- **Desk, 1024 px and wider:** the rail beside the page, as described above,
  expanded or collapsed to its icons.
- **Compact, 600–1023 px:** the rail is a drawer, opened from the menu control
  that leads the topbar, always whole whatever the desk choice. The topbar keeps to one row, and a search control
  opens the palette.
- **Phone, under 600 px:** the drawer too, plus a bar along the bottom edge:
  Dashboard, Relays and Problems (with its count), Search, which opens the palette
  full screen, and Menu, which opens the drawer. The topbar holds the
  namespace picker, the time of the last refresh with its pause control, and
  the account menu. The node, the principal and the theme toggle move to the
  drawer's foot, and each screen's own "?" stands in for the topbar's help.

The drawer closes on Escape, a tap beside it, or following a link, and the page
behind it takes no focus while it is open. On a phone a table reads as cards,
each value under its column's name — a table whose columns are explained keeps
their names and "?"s in one line above the cards — and a dialog rises as a
sheet whose title and actions stay in view. Every control a finger meets is at least 44 px tall.
A touch screen shows no hover tooltips; a tap on a term pins its definition.

iOS Safari ignores `interactive-widget=resizes-content`, so there the keyboard
covers the bottom of a sheet rather than pushing it up. The focused field is
still scrolled into view.

## Dev setup

The compose file brings up a cluster of two controllers, a Rust runner on each,
this console, Postgres and Kafka in one command. The console connects to the
first controller; the second joins it with storage of its own, and its runner
serves the namespace `second`, so every screen has a relay, a runner and
signals on a controller it is not connected to. It expects two sibling
checkouts alongside this one:

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
the `web` container by itself (`FLEZHA_CONSOLE_RESTART_ON_CONFIG_CHANGE` on
`fcon_web`), so the console picks up the change instead of showing Phoenix's "You
must restart your server" page. Only the VM serving the console watches: an
`iex -S mix` in the container, or a `mix phx.server` on the host, is never
stopped this way.

The controller enforces authorization by default, so the stack claims its own
bootstrap: a one-shot `bootstrap` service waits for the controller node, claims
the bootstrap, issues a `_system` token and writes it to a shared volume. The
console reads it through `FLEZHA_TOKEN_FILE` — a file rather than an env var because
the token does not exist until the controller has booted. A restart reuses the
token already written; nothing is re-claimed.

The same step enables the `http_api` plugin in `_system`, the channel the
console reaches the controllers through, over mutual TLS. A one-shot `certs`
step (`priv/dev/certs.sh channel`) makes a dev authority for it, apart from any
distribution one: a server certificate per controller and the console's client
certificate, into the `fcon_channel_tls` volume, kept across restarts. The
plugin listens only on the controllers that hold `_system`, so both controllers
answer to a shared name, `flezha_controllers`, which each server certificate
names too, and the console's `FLEZHA_CONTROLLER_URL` names it: the console pins
whichever controller answers and moves when it stops answering.

`FLEZHA_AUTHZ_ENABLED` is set to `true` on the controller deliberately. A dev
stack that switched enforcement off would leave the console's whole identity path —
token, principal, refusals — untested locally.

A signed-in user may store their own flezha token under **Settings**, which then
rides their calls so the controller's audit log names the human rather than the
app. It is encrypted at rest and never rendered back.

The `web` container migrates the database and runs `priv/repo/seeds.exs` each
time it starts, so even after a `docker compose down` — the `db` service keeps
its data in the container, so `down` discards it — the next `up` can log in at
once. Log in at http://localhost:4000 with:

- **Email:** `admin@flezha.com`
- **Password:** `admin`

The seed runs only in dev. There is no registration page: an operator makes
every other account with

```bash
docker exec -it fcon_web mix flezha_console.create_user someone@example.com
```

which asks for a password of 12 to 72 characters (or takes `--password`) and
creates the account confirmed, ready to log in.

In dev the console seeds testnet relays — flow and steps, `orders`, the runner's
relay API fixture, and `testnet_showcase`, whose graph holds every shape the
relay graph draws, with its sources, an input filter and output plugins —
websocket plugins and a `hook_webhook` controller plugin once the controller is
reachable, so Dashboard's tiles count them on arrival. A runner that does not
announce `showcase` skips that relay with one log line. See
`:dev_setup` in `config/dev.exs`. Before the controller boots, the
`plugin_packages` service builds the `flezha_http` plugin package with the
controller's toolchain and places it in the plugin root with a copy the loader
refuses, so the plugin screens show a loaded and a refused package
(`priv/dev/plugin_packages.sh`).

### Starting, stopping and restarting the stack

`priv/dev/stack.sh` runs the stack once it has been built:

```bash
priv/dev/stack.sh up                   # start every container, and wait until it is ready
priv/dev/stack.sh stop                 # drain the controllers, then stop every container
priv/dev/stack.sh status               # the containers, and how ready each controller is
priv/dev/stack.sh restart-controllers  # drain and restart each controller in turn
priv/dev/stack.sh restart-web          # restart the console and wait for it to answer
priv/dev/stack.sh update               # fetch and compile the console, restart the controllers onto ../flezha
```

A controller is drained and stopped the way `flz controller stop` stops it,
never killed, so its next boot has no files to repair. The two controllers
restart one after the other, because they compile `../flezha` into one shared
build volume. `up` restarts a controller that was already running, since it
lists the plugin packages `up` places again as pending until it restarts.
Nothing in the script runs `docker compose down`, which discards the
database's data.

### Resetting the dev controller

Controller state written by an older controller is not migrated. To start over
— this **discards all dev controller state**: relays, plugins, schedules,
dead letters, the audit log and the authorization bootstrap — stop the stack,
clear the controller's durable state, drop the console's token volume so the
bootstrap is claimed again, and bring the stack up:

```bash
docker compose -f docker-compose.dev.yml down
../flezha/_build/.target/release/flz reset --yes --include-dlq --include-schedules \
  --include-auth --include-audit --storage-root ../flezha/storage
docker volume rm flezha_console_fcon_auth_data
docker compose -f docker-compose.dev.yml up
```

A cold start then seeds cleanly in the current vocabulary.

### Services

| Container | Role |
| --- | --- |
| `fcon_plugin_packages` | One-shot: builds and places the plugin packages the controller loads at boot. Any `docker compose up`, even of one service, runs it again, and the controller lists the re-placed packages as pending until `priv/dev/stack.sh restart-controllers` (`stack.sh up` does it) |
| `flezha_controller` | The controller, built from `../flezha/deploy/docker/dev/Dockerfile.toolchain` |
| `flezha_rust_runner` | `test/apps/rust_runner`, waits for the control socket then connects |
| `fcon_certs` | One-shot: makes the channel's authority, the controllers' server certificates and the console's client certificate |
| `fcon_bootstrap` | One-shot: claims the authorization bootstrap, issues the console's token and enables `http_api` |
| `fcon_web` | This app, reaching the controllers over HTTPS; it holds no cookie |
| `fcon_tools` | The operator helpers that stand in for `flz` on a controller's host — `priv/dev/stack.sh`, CLI calls, shape recording — holding the cookie; run with `docker exec` |
| `flezha_console_db` | Postgres |

### Distribution over TLS

The controllers, the bootstrap steps and the tools service talk over Erlang
distribution; the console takes no part in it. By default that is plain TCP,
guarded only by the cookie (`ERLANG_COOKIE`, declared once at the top of
`docker-compose.dev.yml`). To run every link over TLS 1.3 instead, layer the
overlay on:

```bash
docker compose -f docker-compose.dev.yml -f docker-compose.dev-tls.yml up
```

A one-shot `fcon_dist_tls_certs` (`priv/dev/certs.sh dist`) makes a private
distribution authority, apart from the channel's, and a key, certificate and
option file per distributed host, into the `fcon_dist_tls` volume. Later runs keep them, and remake only what is missing,
expires within 30 days, or was signed by an earlier CA. The option files are
written anew on every run, so a change to their options reaches each node at
the next `up`. Each node then starts
with `ELIXIR_ERL_OPTIONS="-proto_dist inet_tls -ssl_dist_optfile
/dist_tls/<host>.conf"`.

- **Protected:** traffic between nodes is encrypted, and both sides of a link
  check the other's certificate. A node needs a certificate from the stack's CA
  *and* the cookie: a plain-TCP node, a node with another CA's certificate, and
  a node with the wrong cookie are all refused.
- **Not protected:** EPMD, which only reports node names and ports, still runs
  in clear. The cookie is still required.
- **Helper nodes:** `docker exec` inherits the container's
  `ELIXIR_ERL_OPTIONS`, so the commands above and the browser suite's helper
  nodes run over TLS unchanged. A node started any other way needs the same
  two flags and a certificate whose subject alternative name is its host
  name, because `inet_tls_dist` checks a peer against the host part of its node
  name.
- **Outside dev:** a deployment brings its own CA and certificates and keeps
  the CA key off the nodes. The controller's release takes
  `FLEZHA_DIST_TLS_OPTFILE`.

`docker compose … down` followed by `up` without the overlay goes back to plain
TCP. `docker volume rm flezha_console_fcon_dist_tls` discards the CA and the
certificates, and the next overlay `up` makes new ones.
| `fcon_kafka`, `fcon_kafka_ui` | Kafka, for the Kafka provider |

Useful commands:

```bash
docker exec fcon_web mix compile                      # after editing .ex files
docker logs fcon_web 2>&1 | grep EventFeed            # signal feed status
docker logs fcon_web 2>&1 | grep ConfigWatcher        # why the console restarted itself
docker attach flezha_controller                      # controller iex (detach: Ctrl+P Ctrl+Q)
docker exec fcon_tools sh -c 'exec elixir --sname cli1 --hidden --cookie "$ERLANG_COOKIE" "$@"' _ \
  /flezha_console/priv/dev/cli_call.exs Relay.call_channel \
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
npx playwright test --project=phone  # the console held as a phone (390×844, touch)
npm run e2e:flake-check       # the suite three times; lists any test that wavered

npm run tokens                # the design-token gate over assets/ and lib/
```

`npm run tokens` runs the stylebook's own `check-tokens.mjs` over this
repository, once for the console's colour roles and once for the relay graph's
stylebook tokens. It fails on a `var()` naming a token nobody defines, a token
defined but never referenced, and any ink/surface pairing below its WCAG AA
floor in either theme — so a colour that only looks fine in dark mode is caught
before it ships.

`npm run e2e` drives the running dev stack at `http://localhost:4000` in four
parallel workers, each logged in as its own console user, so bring the stack up
first with `docker compose -f docker-compose.dev.yml up`. When the stack is
published on another port, set `E2E_BASE_URL`, for example
`E2E_BASE_URL=http://localhost:4001 npm run e2e`. A run waits for the
controller to be ready and holds the stack while it runs, so a second run
against the same stack stops at once and names the one holding it; each worker
keeps its tokens and role bindings in a namespace of its own. A failing browser
test is investigated as `docs/testing.md` describes, and is fixed only once
`npm run e2e:flake-check` passes.

No test waits for time to pass: a test causes what it asserts and waits only for
that, and `mix test` fails on a sleep, a timer or a long timeout in either
suite. Every ExUnit test is capped at 5 s and every browser test at 20 s; the
whole of `mix test` runs in under a minute and the browser suite in about
one.

The ExUnit LiveView tests run against `test/support/fake_controller.ex`, which
answers as the published `Flezha.Service.*` modules by name, on a peer BEAM node
that carries none of this application's code. That is how states a live stack
refuses to enter — a disconnected or version-skewed controller, audit switched
off, a confirmed controller stop — get covered at all. The fake's error classes
are checked against core's catalogue, and its answers against shapes recorded
from the dev controller, which every browser run re-checks.

Every browser test also fails on a broken page, whatever it asserted, and
`mix test` fails when an event in `lib/` is driven through its markup by no test
(`test/flezha_console/coverage_ledger_test.exs`).

See [docs/testing.md](docs/testing.md) for the rules a new test follows: which
layer it belongs to, how it causes what it asserts, the state it owns, the
table-driven mechanics, the caps, and the gates that enforce them.

## How it looks

The colours, the shell and the brand come from
[`flezha_stylebook`](../flezha_stylebook), the Flezha group's design system;
the content of every screen is drawn with the console's own component kit.

- **Colour has one source.** The kit reads colour only through `--fcon-*` roles
  in `assets/css/console/tokens.css`, and each role names the stylebook token it
  takes — `--fcon-ink-1` is `--text-primary`, `--fcon-canvas` is
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
  `FlezhaConsoleWeb.CoreComponents`: buttons, fields, switches, segmented controls,
  comboboxes, chips, state badges, grids with row menus, sections with digests,
  the page header, tabs, drawers, dialogs, popovers, tooltips, toasts,
  sparklines, meters, skeletons, code blocks, steps and identifiers. A screen
  opens on its page header — the kind of object, its name, one sentence on its
  condition, its actions and its tabs — and its sections are separated by space
  and hairlines rather than nested cards. Tiles are the one raised surface on
  a page: the stylebook's `.flz-tile`, with a tone edge, a lift on
  hover and fixed rows so a row of them stands level, and figures that shrink
  to fit (`.flz-figure-fit`) rather than spill. Every listing shows 20 rows
  and grows by a page on request, its count kept by the server
  (`FlezhaConsoleWeb.Live.Sections`). In dev, `/dev/kit` shows every component in
  every state.
- **Type**: flezha.com's faces — Space Grotesk for display, Inter for the
  interface and JetBrains Mono for identifiers and figures — from the
  stylebook's `fonts.css`, served from `priv/static/fonts`.
- **Theme contract**: attribute `data-theme="light|dark"` on `<html>`, storage
  key `flezha-theme`, set before the first paint by the stylebook's inlined
  `theme-hydrate.js`. The toggle sits in the topbar and on the signed-out
  pages, with flezha.com's sun and moon.
- **The relay pipeline graph** draws nodes and wires with the stylebook's
  relay-graph recipe (`.flz-graph-*`); the console's own `topo-*` rules add
  the relay's edge, nets in six hues (`--fcon-wire-0` to `--fcon-wire-5`, both
  themes; a channel keeps its hue through its port), halos and junction dots, ports and their taps, badges, focus, the
  view controls, the Cell sheet, the flow sentence and the timeline.
  `Topology.pipeline/1` places every node on abstract ranks and orders — sources
  and input filters, entry ports, tasklets by depth, exit ports, then the
  plugins, called relays and "no plugin bound" ends — routes each channel
  leaving a point as one net with its own lane in each gap, and only then maps
  the layout to x and y; layouts are kept per shape and direction, so no tick
  moves a node. A plugin is a source when its provider's `feeds` flag says so
  (`Fleet.providers/1`), on the entry it names or the first one. The
  `FlzPipeline` hook owns the view box (Fit, zoom, ctrl/⌘ + wheel, drag to pan,
  full screen) and the viewer's direction, kept in `localStorage` and sent with
  the panel size so Auto picks the direction that fits larger. Once the viewer
  zooms or pans, opening or closing a tasklet's Cells keeps that zoom and only
  pans the tasklet beside the sheet. Each tick the server pushes how many
  records each counted node took (`pipeline_counts`): IN by entry, each
  tasklet's admitted advance from `Relay.activity/4`, each output channel's
  count from a tally listen held while the page shows a relay with two or more
  outputs, and what was skipped and dead-lettered; and what each channel carried —
  every reader takes all of it, so it is worked out from its readers' intake,
  else its tally — and each wire into a tasklet reading several channels, its
  channel's share. A channel's label shows that rate, so a tasklet that emits
  several records per input reads as a jump along the graph. The hook starts
  marks at the sources and hands them on node by node on a canvas over the SVG,
  at about 24 frames a second, only while something moves and the graph is on
  screen; a wire of twelve or more records a second flows instead. Selecting a
  tasklet opens its Cells (`Relay.activity/4` with `cells_of`, read only while
  the sheet is open). The graph is read when the page opens and again when the
  relay is bound anew, and nothing is read while the tab is hidden. Without a
  graph the relay is an empty boundary and a line says why.
- **The gate.** `npm run tokens` runs the stylebook's `check-tokens.mjs` twice:
  over the console's roles, resolved through the stylebook's palette, and over
  the stylebook tokens the graph still reads. Either fails on an undefined or
  unused token, a contrast pairing below WCAG AA in either theme, or a hex,
  `rgb()` or `hsl()` colour written outside a token file.

## How the console talks to the controller

Every remote call goes through `FlezhaConsole.Service.NodeManager`, which is the
only module that names a `Flezha.*` module, and every call is an operation on
core's **published consumer API**: a `Flezha.Service.*` function listed in
core's `docs/internal/api/consumers/published.txt`, sent over the controller's
HTTPS channel as `POST /v1/call/<Module.function>` with its arguments as a JSON
array and the operator's token as its bearer token. The controller builds the
caller context from that token and runs the call through its one door, as it
does for every surface; the console builds no context. Answers are decoded from
JSON by the recorded shapes (`FlezhaConsole.Service.ControllerShapes`,
`priv/controller_shapes.json`), so screens read the terms they always did:
atom keys, atoms the console knows, tuples and times. A name the console has no
atom for stays text, so the controller's data never grows the atom table, and
node names are always text.
The door keeps the operations core does not let the network reach — issuing,
revoking and binding, deleting a namespace, claiming the bootstrap and stopping
the controller — away from the console; `flz` makes them.
`test/flezha_console/service/published_surface_test.exs` holds the console to that
with core's own extractor and list (`FLEZHA_CORE_PATH`, default `../flezha`).

The controller is the one `FLEZHA_CONTROLLER_URL` names, and only that one.
`FlezhaConsole.Service.NodeConnector` resolves its host, pins the first address
that answers an unauthenticated `GET /v1/catalogue`, keeps it while it answers,
and broadcasts `:controller_up` and `:controller_down`. TLS checks the server's
certificate against the URL's host, also on the pinned address.
`NodeManager.connected_node/0` answers the reached controller's name, from the
`local?` row of its `Controller.controllers` answer, while the channel is up, and
`nil` otherwise.

A call answers the controller's `{:ok, value}`, or its error read from the
channel's error body — code, class, message, hint, details — or one of
the transport conditions only this node sees: not connected, API missing,
timeout, remote error. An operation the door does not publish reads as API
missing. `NodeManager.error/1` reads any of them as one map, so a
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

Identity comes *only* from `Flezha.Service.Namespace.whoami`, called with the
token: one answer gives the principal, namespace, role, granted operations and
the controller's enforcement posture. A name typed into this console is never
sent as a principal; the controller judges each call by the token it carries.
Verifications are cached briefly, and never for a transient
`authz.registry_unavailable`; a refused call evicts the entry. Without a token
the console makes no call at all, and every screen says it needs one, since the
HTTP API refuses any request without a bearer token.

A screen reads what it shows, never a whole namespace, so it costs the
controller the same with ten relays or ten thousand. A listing of relays,
plugins, dead letters, Cells, journal entries or committed iterations asks for
the page it shows (`limit`, `sort`, `filter`, as the controller's paged reads
take them), counts come from the controller's summary, one relay is read by
id, and rates are read for the relays on screen and, for Dashboard's Flow, as the
namespace's summed totals. Pickers of such a collection search the
controller as the operator types. Screens that refresh read off their
process and hold while their tab is hidden, as the shell's pulse does, and
reads of liveness counters and dead-letter seen counts are shared between an
operator's tabs through `NodeManager`'s read cache.
`FlezhaConsoleWeb.ListingView` is the one search, filter and sort view every
listing shares, written to the query string.

Behaviour shared across screens is a `use`-able module rather than a copied
block: `FlezhaConsoleWeb.Live.Refresh` (the tick, the forwarded runner events —
ignored by a screen scoped to another namespace — what a screen says about
its own currency and, for a screen declaring `background: true`, reading off
the LiveView process), `FlezhaConsoleWeb.Live.Tail` (a live
tail), `FlezhaConsoleWeb.Topology` (the pipeline graph, drawn live for a relay
and still for a factory, and the fleet summary),
`FlezhaConsoleWeb.Live.Launcher` (starting a relay, rendered by both
`/namespaces/:ns` and `/relays`), `FlezhaConsoleWeb.Live.PluginForm` (enabling,
binding and updating a plugin, from a relay's screen and the plugins screen),
`FlezhaConsoleWeb.Live.Target` (the namespace and
factory a write is aimed at, shared by the launcher and the schedule form) and
`FlezhaConsoleWeb.Live.Sections` (which of a long screen's panels are open);
`Layouts.scope_switch/1` is the one switch between a scoped listing and its
all-namespaces twin. A write
path implemented twice drifts, and the half that drifts is the one nobody is
looking at.

Live data rides `FlezhaConsole.Service.EventFeed`, and **no code of this
application runs on the controller**. A feed holds one published stream
operation — `Observability.tail/2`, `Logs.tail/2` or `Relay.listen/5` —
open on the channel's stream route, `POST /v1/stream/<Module.function>`, by a
process linked to it, which hands each server-sent event, decoded, to the feed
as `{:flezha_emit, event}`. The stream ends with the operation's answer (`end`),
with `overrun` when the console fell behind, which the feed always opens again
and tells the screen about the gap, or with a lost connection.
Runner connects and disconnects are observability signals on `:flezha_runner`,
which a supervised feed tails and broadcasts on `"flezha:events"`; relay starts,
stops and exits on `:flezha_relay` get a supervised feed of their own, on
`"flezha:relays"`, which only the relays index hears; the audit
and observability tails, the listen screen, the pipeline graph's payload tap
and the relay screen's Calls section (a `:calls` listen, held only while the
section is open) each hold a feed linked to the screen. When the feed exits its
request is closed and the controller ends the operation, so stopping the feed —
or closing the screen — releases the subscription. There
is no second mechanism. `EventFeed.stop/2` also drops what the feed already
sent under its tag, so a screen that replaces a feed never hears the old one,
and a retrying feed reports a reconnect only once its re-opened stream is held.

## Releases

### Get the release

Each GitHub release carries the console for Linux x86_64, macOS on Apple Silicon
and macOS on Intel, with its own Erlang runtime, and a `SHA256SUMS.txt` over
them. Download your platform's archive and the checksums, check, and unpack:

```bash
gh release download v0.1.0 -R Flezha/flezha_console \
  -p 'flezha_console-*-linux-x86_64.tar.gz' -p SHA256SUMS.txt
sha256sum -c --ignore-missing SHA256SUMS.txt     # macOS: shasum -a 256 -c --ignore-missing SHA256SUMS.txt
tar -xzf flezha_console-0.1.0-linux-x86_64.tar.gz
```

A macOS archive is signed ad hoc, not notarized. Fetched with `gh` or `curl` it
runs as it is; one downloaded through a browser needs
`xattr -dr com.apple.quarantine flezha_console` first.

The release takes its settings from the environment: `DATABASE_URL` (an
existing database), `SECRET_KEY_BASE` (`openssl rand -base64 48`), `PHX_HOST`,
`PHX_SERVER=true`, the admin account `FLEZHA_CONSOLE_ADMIN_EMAIL` and
`FLEZHA_CONSOLE_ADMIN_PASSWORD`, and the channel to the controllers:

- `FLEZHA_CONTROLLER_URL` — the controllers' HTTP API, `https://host:port`, where
  `host` may be one DNS name for every controller: the console pins one that
  answers. Plain `http://` is taken only for `127.0.0.1` or `[::1]`. A flezha
  token works only on the controllers that issued it, so a name must not span
  clusters.
- `FLEZHA_CONTROLLER_CA` — the authority the controllers' server certificates
  chain to; each must name the URL's host.
- `FLEZHA_CLIENT_CERT` and `FLEZHA_CLIENT_KEY` — the console's client
  certificate, from the authority the controllers' `http_api` plugin names as
  `tls_client_cacertfile`.
- A flezha token, as `FLEZHA_TOKEN` or `FLEZHA_TOKEN_FILE`, or stored per user
  in Settings: the HTTP API refuses every request without one, even on a
  controller whose authorization is open.

The controllers need a release newer than 0.1.6, with the `http_api` plugin
enabled in `_system` over TLS with `tls_client_cacertfile`. The console starts
no Erlang distribution and needs no cookie; without the URL, or with an `https`
URL and a missing or unreadable file, it refuses to start, naming the variable.
Console replicas that cluster among themselves (`DNS_CLUSTER_QUERY`) set
`RELEASE_DISTRIBUTION=name` and a `RELEASE_COOKIE` of their own, never the
controllers'. The flezha repository's console guide
(`docs/public/console/console.md`) lists every setting. Then:

```bash
flezha_console/bin/flezha_console eval FlezhaConsole.Release.migrate
flezha_console/bin/flezha_console eval FlezhaConsole.Release.ensure_admin
flezha_console/bin/flezha_console start          # or `daemon`, and `stop` to stop it
```

On another platform, build it yourself: `scripts/release-archive.sh` (below),
or the Docker image `deploy/Dockerfile` describes.

### Build and check an archive

```bash
scripts/release-archive.sh       # _build/dist/flezha_console-<version>-<platform>.tar.gz
scripts/smoke-release.sh _build/dist/flezha_console-0.1.0-linux-x86_64.tar.gz \
  ecto://postgres:postgres@localhost:5432/flezha_console_smoke
```

`release-archive.sh` needs Elixir, Node and the stylebook checkout, and builds
for the machine it runs on. `smoke-release.sh` unpacks the archive into a
temporary directory, creates the database the URL names (it must not exist
yet), migrates it, starts the release on a free port, wants 200 from
`/users/log-in` and stops it. It removes the directory and the database however
it ends, and a failure names the step that failed. No controller is needed.

### CI and cutting a release

`.github/workflows/ci.yml` runs on every push to `main` and every pull
request: `mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix test` against a Postgres service, and `mix assets.deploy`. Pushes to `dev`
and other branches start nothing, and the browser suite does not run in CI.

A release is cut by pushing a `v*` tag from `main`.
`.github/workflows/release.yml` then builds the archive on Linux and on both
macOS runners with `scripts/release-archive.sh`, smoke-tests each on the runner
that built it with `scripts/smoke-release.sh`, and only when all three passed
attaches them and `SHA256SUMS.txt` to the tag's release. A tag with a `-`
(`v0.1.0-rc.1`) makes a pre-release.

The image `flezha/flezha_console` is published by hand: `scripts/publish-image.sh`, run
once on an amd64 machine and once on an arm64 one, each with the stylebook checkout beside
this repository, pushes that machine's image and joins both under `:<version>` and
`:latest`.

Both files check out `flezha/flezha_stylebook` beside the console, and `ci.yml`
also the parts of `flezha/flezha` that
`test/flezha_console/service/published_surface_test.exs` reads. Both
repositories are public, so no token is needed.

## Manual setup (no Docker)

```bash
# Controller, from the flezha repo, then `flz plugin enable api http_api
# --namespace _system`, which listens on 127.0.0.1:8765
iex -S mix

# Console: plain HTTP is taken for a controller on loopback, with a token
FLEZHA_CONTROLLER_URL=http://127.0.0.1:8765 FLEZHA_TOKEN=<token> mix phx.server
```

A controller on another machine serves `http_api` over TLS with a client
authority, and the console is given `https://…` and its three files as above.

## License

Flezha Console is licensed under the [Mozilla Public License 2.0](LICENSE), the
same license as the Flezha controller. Use it and run it anywhere, commercially
too; if you distribute a modified copy, publish your changes to its files under
the same license. Flezha Console is provided "AS IS", without warranty of any kind
(MPL-2.0 §6-7). The license grants no trademark rights: a fork, derived work or
hosted service must not use the name "Flezha" or one confusingly similar.
