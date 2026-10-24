# runtime-events Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Runner lifecycle events reach LiveViews

Runner connect, disconnect, drop and readmit events SHALL reach the UI as the runner session signals core publishes on an observability source, SHALL be forwarded by `EventFeed`, and SHALL be broadcast on the UI's PubSub topic `"flezha:events"` as runner-connected, runner-disconnected, runner-dropped and runner-readmitted messages, so subscribed LiveViews update without a page reload. Drop refusals SHALL NOT be broadcast to LiveViews.

#### Scenario: A runner connects

- **WHEN** a runner connects and the controller publishes its runner-connected signal
- **THEN** `EventFeed` forwards it and the bridge broadcasts a runner-connected message
- **AND** subscribed LiveViews update their runner list

#### Scenario: A runner disconnects

- **WHEN** a runner disconnects and the controller publishes its runner-disconnected signal
- **THEN** subscribed LiveViews reflect the runner's departure

#### Scenario: A runner is dropped or readmitted

- **WHEN** the controller publishes a runner-dropped or runner-readmitted signal
- **THEN** `EventFeed` broadcasts the matching message and subscribed LiveViews reload their runners and drop marks

#### Scenario: A dropped process is refused

- **WHEN** the controller publishes a runner-drop-refused signal
- **THEN** no runner message is broadcast for it

#### Scenario: A runner of another namespace

- **WHEN** a runner signal names a namespace other than the one a screen is scoped to
- **THEN** that screen does not reload for it

#### Scenario: Other signals on the same source are ignored

- **WHEN** the tailed source carries a signal that is not a runner session signal
- **THEN** no runner message is broadcast for it

#### Scenario: Retired event names stay gone

- **WHEN** the naming gate runs over the tracked tree
- **THEN** it fails on any occurrence of `compute_engine`, so `compute_engine_connected` and `compute_engine_disconnected` cannot return

### Requirement: Observability sources and sinks are listed

The UI SHALL list the controller's observability sources, from
`Flezha.Service.Observability.list_sources/1`, each with its enabled state, its
title, its technical name, its description and its recent activity. Sources SHALL
be grouped by the area the controller declares for them:

- relays;
- storage;
- plugins;
- controller;
- machine.

A source with no declared area SHALL be listed under "Other". The UI SHALL NOT
derive a source's area from its name. A source with no declared title SHALL be
headed by its technical name.

Each row SHALL show, each in its own size and ink:

- the title as the row's heading;
- the technical name, small and in the monospace face;
- the description, as a quieter line;
- the activity line.

Each group SHALL state how many of its sources are enabled. Within a group, sources
SHALL be listed in this order:

1. those with a failure signal in the controller's history window;
2. those that emitted anything in the window;
3. the rest.

Each of these bands SHALL be ordered by title. A filter SHALL narrow the sources
to those whose title, technical name or description contains the typed text.

A source's activity line SHALL be built from the `recent` field the controller
answers and the outcome of each signal. It SHALL be:

- when a failure signal emitted in the window: a warning mark with how many
  failures, and how long ago the newest arrived;
- when the source declares failure signals and none emitted in the window: a
  positive mark stating there were no failures in the window, naming its length;
- the normal signals that emitted, told by their labels with their counts, and
  how long ago the newest arrived;
- when nothing emitted and the source declares no failure signal: a statement
  that nothing was emitted in the window, naming its length;
- nothing, when the controller answers no `recent` field.

The sinks, from `list_sinks/1`, SHALL be summarised in one line naming each sink
and what it is for. Any sink that is not running SHALL be marked as such in that
line.

#### Scenario: Sources and sinks exist

- **WHEN** an operator opens the observability screen
- **THEN** every source is listed with whether it is enabled, its title, its technical name, its description and its activity line
- **AND** sources are grouped by their declared area, each group stating how many are enabled
- **AND** one line names every sink and marks any that is not running

#### Scenario: A source's failures stand out

- **WHEN** the controller answers `flezha_file_sink` with `recent` holding `failed` 3 times, the newest 7 minutes ago, and `failed` declared with outcome `:failure`
- **THEN** its row shows a warning mark reading 3 failures in the last 15 minutes, the latest 7 minutes ago
- **AND** it is listed first in its group

#### Scenario: A quiet source with failure signals reassures

- **WHEN** the controller answers a source declaring a `:failure` signal with `recent: %{window_ms: 900_000, signals: %{}}`
- **THEN** its row shows a positive mark stating there were no failures in the last 15 minutes

#### Scenario: Normal activity is told by labels

- **WHEN** the controller answers `flezha_file_sink` with `flushed` labelled "Saved", 142 times, the newest 2 seconds ago
- **THEN** its row reads that 142 were saved, the last 2 seconds ago

#### Scenario: Filtering sources

- **WHEN** an operator types `file` into the source filter
- **THEN** only sources whose title, technical name or description contains `file` are shown, still in their groups

#### Scenario: A controller that does not describe its sources

- **WHEN** the controller answers sources without `title`, `description`, `area`, `signals` or `recent`
- **THEN** each source is listed under "Other" headed by its technical name, with its switch and Tail
- **AND** no activity line and no description are shown, and the screen raises no error

#### Scenario: Observability is disabled on the controller

- **WHEN** the calls answer `{:error, %Flezha.Error{code: "observability.disabled"}}`
- **THEN** the screen states that observability is switched off on this controller

#### Scenario: The calls are refused

- **WHEN** the calls answer `{:error, %Flezha.Error{class: :denied}}`
- **THEN** the screen states the refusal and gives the error's code and message

### Requirement: Sources are toggled from the UI

An operator SHALL be able to enable and disable an observability source with the
console kit's switch component, through `Flezha.Service.Observability.enable_source/2`
and `disable_source/2`. The change SHALL be reflected in the listing without a
page reload. The switch SHALL be labelled with the source's name and SHALL report
its state to assistive technology.

#### Scenario: Enabling a source

- **WHEN** an operator switches a disabled source on
- **THEN** `enable_source/2` is called with the UI's caller context
- **AND** the source is listed as enabled

#### Scenario: Disabling a source

- **WHEN** an operator switches an enabled source off
- **THEN** `disable_source/2` is called and the source is listed as disabled

#### Scenario: The toggle is refused

- **WHEN** the controller refuses the toggle
- **THEN** the refusal is shown and the switch returns to the source's unchanged state

### Requirement: Controller subscriptions are taken through the published tail operations

Every live controller subscription the console holds — runner session events, an observability source's signals, the audit log's records — SHALL be taken through a published stream operation of the consumer API (`Flezha.Service.Observability.tail/2` or `Flezha.Service.AuditLog.tail/2`) with the console's caller context, and SHALL be held by `FlezhaConsole.Service.EventFeed`, which receives the signals on the console node and forwards each one to the console process that asked for it. The console SHALL NOT call `Flezha.Service.EventManager` or any other unpublished controller module to subscribe.

#### Scenario: Establishing the runner event subscription

- **WHEN** the event bridge connects to the controller
- **THEN** it asks `EventFeed` to tail the observability source on which core publishes runner session signals
- **AND** the tail is established through `Flezha.Service.Observability.tail/2` with the console's caller context
- **AND** the subscription stays in place for as long as the `EventFeed` process holding it lives

#### Scenario: No unpublished subscription call remains

- **WHEN** `lib/` is searched for `Flezha.Service.EventManager`, `add_handler` or `rem_handler`
- **THEN** no occurrence exists

### Requirement: Event feed recovery

The bridge SHALL monitor the controller connection and the feed's subscription and SHALL re-establish the subscription when the subscription ends or the controller node reconnects. A subscription SHALL be released by stopping the `EventFeed` process that holds it; the controller watches that process and removes the subscription when it exits. Before taking a replacement subscription the bridge SHALL stop the process holding the prior one, so at most one subscription per tail exists at any time.

#### Scenario: The controller node restarts

- **WHEN** the controller goes down and comes back
- **THEN** the bridge takes a new subscription
- **AND** events flow again without restarting the UI

#### Scenario: Reconnect does not duplicate subscribers

- **WHEN** the bridge reconnects several times
- **THEN** exactly one subscription for the runner session source is held for the UI
- **AND** each event is broadcast to the UI exactly once

#### Scenario: The subscription cannot be established

- **WHEN** the tail call fails or is refused
- **THEN** the bridge retries on its backoff interval
- **AND** affected screens fall back to periodic refresh so data still updates

#### Scenario: Observability is switched off on the controller

- **WHEN** the tail call answers `{:error, %Flezha.Error{code: "observability.disabled"}}` or `{:error, %Flezha.Error{code: "observability.pubsub_disabled"}}`
- **THEN** the bridge logs that runner events are unavailable and keeps retrying on its backoff interval
- **AND** screens that list runners still update on their refresh tick

### Requirement: Every tail rides the event feed

A live tail of an observability source or of the audit log SHALL be carried by `FlezhaConsole.Service.EventFeed`, the mechanism that carries runtime events. A second subscription mechanism SHALL NOT be introduced.

#### Scenario: Tailing a source

- **WHEN** an operator starts a live tail of an observability source
- **THEN** `EventFeed` takes the subscription through `Flezha.Service.Observability.tail/2`
- **AND** signals arrive in the LiveView without a page reload

#### Scenario: Tailing the audit log

- **WHEN** an operator starts a live audit tail
- **THEN** `EventFeed` carries it, through `Flezha.Service.AuditLog.tail/2`

#### Scenario: One feed

- **WHEN** `lib/` is searched for calls that take a controller subscription
- **THEN** only `EventFeed` makes them

#### Scenario: The subscription ends

- **WHEN** a tail's subscription ends while the screen is open, because the controller restarted or the connection dropped
- **THEN** the tail is re-established by the event feed's recovery path
- **AND** the screen states that the tail reconnected rather than silently stopping, once the re-opened stream delivers an event or is not refused within the settle interval

#### Scenario: The re-opened tail is refused

- **WHEN** the event feed re-opens a tail and the controller refuses it
- **THEN** the screen keeps stating the refusal and does not state that the tail reconnected

#### Scenario: A tail is replaced

- **WHEN** a screen stops a feed to open another under the same tag
- **THEN** nothing the stopped feed already sent reaches the screen

#### Scenario: The pubsub sink is disabled

- **WHEN** the tail answers `{:error, %Flezha.Error{code: "observability.pubsub_disabled"}}`
- **THEN** the screen states that live tailing is unavailable and the query-based view still works

### Requirement: No code of this application runs on the controller

The UI SHALL hand the controller only data — call arguments and its caller context. It SHALL NOT compile, load or spawn any module or anonymous function of its own on the controller node, so the console and the controller may run different Elixir and Erlang/OTP releases.

#### Scenario: Nothing is compiled or loaded remotely

- **WHEN** `lib/` is searched for `Code.compile_string`, `:code.load_binary` or a `Node.spawn` / `Node.spawn_link` aimed at the controller
- **THEN** no occurrence exists

#### Scenario: A controller without this application's code

- **WHEN** the UI tails runner events, an observability source and the audit log against a controller whose code path holds no module of this application
- **THEN** every tail delivers its signals to the UI
- **AND** no `:undef` or `:badfun` is raised on the controller

### Requirement: Relay lifecycle signals reach the relays index

The console SHALL receive the `relay_started`, `relay_stopped` and `relay_exited`
signals of the `:flezha_relay` observability source through a supervised
`Flezha.Service.Observability.tail/2` feed of the same kind that carries runner
session signals. There SHALL be no second subscription mechanism. The signals
SHALL be broadcast on a topic of their own, so that only the screens handling
them receive them.

The relays index, platform-wide and namespace-scoped, and each namespace's Home
SHALL show these signals in their event river, as the `live-activity` capability
defines. Each signal SHALL carry its time, namespace, relay and what happened:

- started, with its factory;
- stopped, with its reason;
- exited, with its runner and reason.

A screen SHALL reload its rows when a signal arrives. Signals SHALL be narrowed to
the namespaces the bound token reaches before they are shown, and, on Home, to
that Home's namespace.

#### Scenario: A relay starts

- **WHEN** a relay is started while an operator has the relays index open
- **THEN** a started entry with the relay and its factory appears at the top of the river
- **AND** the relay's row appears without waiting for the refresh tick

#### Scenario: A relay stops

- **WHEN** a relay is stopped or completes
- **THEN** a stopped entry with its reason appears
- **AND** the relay's row leaves the live listing

#### Scenario: A relay's runner exits

- **WHEN** a relay's runner exits and the relay is rebound
- **THEN** an exited entry names the runner and the reason

#### Scenario: A signal from an unreachable namespace

- **WHEN** a signal names a namespace the bound token does not reach
- **THEN** it is not shown

#### Scenario: The river is bounded

- **WHEN** more than fifty signals have arrived
- **THEN** only the most recent fifty are kept

#### Scenario: The source cannot be tailed

- **WHEN** the controller refuses or cannot tail `:flezha_relay`
- **THEN** the river states why with the error's code and hint
- **AND** the screen keeps refreshing on its timer

### Requirement: A relay's call activity rides the event feed

The relay screen's call activity SHALL be received through `Flezha.Service.Relay.listen/5` with the direction `:calls` and the console's caller context, held by an `FlezhaConsole.Service.EventFeed` linked to the screen, the mechanism that carries the payload tap and the listen screen. A second subscription mechanism SHALL NOT be introduced. Each open Calls panel SHALL hold exactly one such listen. The listen SHALL be opened when the panel opens and SHALL end when the panel folds or the screen closes. A replacement listen SHALL be opened only after the previous one was stopped under its tag, so nothing the previous one sent reaches the screen.

#### Scenario: Opening the panel

- **WHEN** an operator opens the Calls panel on a relay screen
- **THEN** `EventFeed` opens `Relay.listen/5` for that relay with direction `:calls`
- **AND** call events arrive on the screen without a page reload

#### Scenario: The panel starts folded

- **WHEN** an operator opens a relay screen without opening the Calls panel
- **THEN** no listen with direction `:calls` is held for it

#### Scenario: Folding the panel

- **WHEN** an operator folds an open Calls panel
- **THEN** its listen ends on the controller
- **AND** the calls already listed stay on screen

#### Scenario: Leaving the screen

- **WHEN** the relay screen closes with the Calls panel open
- **THEN** its listen ends without the operator doing anything

#### Scenario: Listening again

- **WHEN** the listen has ended or was refused and the operator asks to listen again
- **THEN** one new listen is held and the previous one sends nothing more to the screen

#### Scenario: The listen is refused

- **WHEN** `listen/5` answers `{:error, %Flezha.Error{}}` for the `:calls` direction
- **THEN** the panel states the refusal with the error's code and message
- **AND** the rest of the relay screen renders unaffected

### Requirement: A source says what it can emit

The controller SHALL declare, for every observability source it registers itself:

- a plain title;
- a one-line description written for an operator;
- an area;
- every signal the source can emit, each with:
  - its kind;
  - a plain label;
  - an outcome of `:normal` or `:failure`;
  - a one-line meaning;
  - optionally, a sentence template.

It SHALL answer these in `list_sources/1`. The controller SHALL NOT register a
source that nothing can make emit.

The UI SHALL show a source's title and description on its row. When the source is
tailed, the UI SHALL list its signals in two groups, failures first and then normal
activity. Each signal SHALL be shown with:

- its label;
- an outcome badge;
- its meaning;
- its technical name in full, never cut off.

A signal emitted under a name the source does not declare SHALL still be shown, by
its name, with no meaning.

#### Scenario: Every core source is described

- **WHEN** the controller has booted with its default configuration
- **THEN** every source `list_sources/1` answers has a non-empty title, description and an area
- **AND** every signal it declares has a kind, a non-empty label, an outcome and a non-empty meaning

#### Scenario: No source that cannot emit is listed

- **WHEN** an operator opens the observability screen against the controller after this change
- **THEN** neither `flezha_reconcile`, `flezha_leadership` nor `flezha_bounded_mailbox` is listed

#### Scenario: The tail names what may appear, failures first

- **WHEN** an operator tails `flezha_file_sink` and nothing has arrived yet
- **THEN** the tail lists `refused` and `failed` under a heading for what goes wrong, and `flushed` under normal activity
- **AND** each shows its label, its outcome badge, its meaning and its full technical name

### Requirement: A tail opens with the source's recent history

When an operator starts a tail of a source, the UI SHALL first show the source's
most recent signals from the controller's history, read through
`Flezha.Service.Observability.query/2` with the UI's caller context. It SHALL show
up to 50, under a divider stating they arrived before the tail was opened. Live
signals SHALL be added above the divider as they arrive. History and live signals
together SHALL be capped at 200.

#### Scenario: A source with history

- **WHEN** an operator tails a source whose history holds signals
- **THEN** the tail shows them at once, below a divider stating they arrived before the tail was opened
- **AND** signals that arrive afterwards appear above the divider, newest first

#### Scenario: The pubsub sink is disabled

- **WHEN** an operator tails a source and the tail answers `{:error, %Flezha.Error{code: "observability.pubsub_disabled"}}`
- **THEN** the screen states that live tailing is unavailable
- **AND** the source's history is still shown

### Requirement: A tail line says when, what, about whom and how much

Each signal in a tail SHALL be shown as:

- the time of day it was emitted, shown as the console's other live streams show
  theirs. It SHALL be derived from the signal's controller timestamp and one
  reading of the controller's clock taken when the tail is opened;
- one sentence about its subject, built from the signal's sentence template. The
  subject SHALL be the first present label of `relay`, `relay_id`, `plugin_id`,
  `runner`, `runner_id`, `hub` and `namespace`. When the template names a value
  the signal does not carry, or the signal has no template, the sentence SHALL be
  the subject and the signal's label;
- a warning mark, when the signal's outcome is `:failure`;
- a details toggle that reveals its labels as sorted `key=value` pairs and its
  numbers.

A value that is a path SHALL show only its last segment in the sentence and in
full in the details. On a phone-width screen a line SHALL wrap into a block, not
scroll sideways.

#### Scenario: A file sink signal

- **WHEN** `flezha_file_sink` emits `flushed`, whose template is `"{plugin_id} saved {count:record} to {path}"`, with measurements `%{count: 1}` and metadata `%{plugin_id: "showcase_orders", path: "/data/out.log"}` during a tail
- **THEN** the line shows the time it was emitted and reads "showcase_orders saved 1 record to out.log"
- **AND** its details reveal `path=/data/out.log plugin_id=showcase_orders` and `count 1`

#### Scenario: A failure line stands out

- **WHEN** `flezha_file_sink` emits `failed`, whose outcome is `:failure`, during a tail
- **THEN** its line carries a warning mark

#### Scenario: A template names a value the signal lacks

- **WHEN** a signal's template names `{path}` and the signal carries no `path`
- **THEN** the line reads its subject and its label, and shows no unfilled placeholder

#### Scenario: Buffered and live signals share one clock

- **WHEN** a buffered signal was emitted 60 seconds of controller time before a live one
- **THEN** their shown times are 60 seconds apart

### Requirement: The tail drawer separates what it shows

The tail drawer SHALL give each kind of text its own place, size and ink, using the
console's existing type and surface recipes and no new colour or size token:

- the source's title as the drawer title, with its technical name beneath it, small
  and in the monospace face;
- the description as the lead, in body ink;
- a status line, small and quiet, stating whether the tail is live or waiting and how
  many signals it shows, separated from what follows by a rule;
- while nothing has arrived, the console's empty-state component;
- the signal catalogue as bordered rows under small-caps group headings;
- the tail's lines, with the history divider in the small-caps heading style.

#### Scenario: Waiting for the first signal

- **WHEN** an operator tails a source that has sent nothing
- **THEN** the drawer shows the title, the technical name, the lead, a status line saying it is waiting, the empty-state component and the catalogue
- **AND** the lead, the status line, the empty-state text and a catalogue row's meaning each compute to a different size or ink

#### Scenario: Signals are flowing

- **WHEN** signals have arrived
- **THEN** the status line says the tail is live and how many signals it shows
- **AND** the catalogue is folded into a toggle the reader opens, which stays open as signals arrive

