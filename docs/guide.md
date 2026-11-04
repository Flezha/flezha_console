# Using the console

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
