# topology-graph Specification

## Purpose
The live picture of the flezha data plane: one relay's pipeline — what is
attached to it, in what order, what is flowing through it and what is stuck —
plus a namespace-level summary whose cost does not grow with the size of the
fleet.
## Requirements
### Requirement: Flow rates where the controller counts them

The system SHALL compute message rates as the difference between successive counter reads, divided by the elapsed time between them:
- **Relay counters:** read from `Flezha.Service.Controller.liveness_counters/1`, measured on the UI's monotonic clock. A relay's counters SHALL be read from the snapshot's `relays` list, keyed by `relay_id`.
- **Tasklets:** from the difference of `admitted_total` between successive reads of `Flezha.Service.Relay.activity/4`, divided by the difference of the reads' `read_at_ms`.
- **Output channels:** from a tally listen's totals between successive reports. A new epoch starts a new baseline.

Negative differences SHALL clamp to zero.

Rates SHALL be displayed only where a counter exists:
- on each entry port's wire: the relay's IN rate, split by entry as the motion is;
- on each tasklet node, beside its name, in a slot whose width does not depend on the figure;
- on each output channel's wire, from the tally, or from the relay's `forwarded` count when the relay has one output channel or no tally can be read.

Plugin-to-plugin wires SHALL carry no rate figure.

The pipeline SHALL display, and SHALL animate from, the mean of the newest seven rate samples. A mean above zero that would round to zero SHALL read `<0.1/s`. Each entry wire SHALL state how long ago a record last arrived, or that none has since the page opened.

#### Scenario: Rates appear after two snapshots

- **WHEN** the graph has received two consecutive snapshots where the relay's counts advanced
- **THEN** its entry wires display a messages-per-second rate derived from the count delta and elapsed time

#### Scenario: Counters are found by relay id

- **WHEN** a snapshot's `relays` list holds an entry whose `relay_id` is the relay on display
- **THEN** that entry's counters are the ones the rates are computed from

#### Scenario: First snapshot has no baseline

- **WHEN** the graph renders from its first snapshot
- **THEN** no wire displays a rate figure and nothing moves

#### Scenario: Controller restart resets counters

- **WHEN** a snapshot reports counts lower than the previous snapshot's
- **THEN** that tick contributes a zero sample to the rates instead of a negative one

#### Scenario: A slow relay does not read zero

- **WHEN** a relay's input advances by one record on one tick out of every three
- **THEN** the entry wire reads a steady non-zero rate rather than alternating between a figure and `0.0/s`

#### Scenario: A trickle below one decimal

- **WHEN** the mean of the newest seven samples is above zero and below 0.05
- **THEN** the figure reads `<0.1/s`

#### Scenario: Last record recency

- **WHEN** the relay's input counter last advanced two ticks ago
- **THEN** the entry wire states roughly how many seconds ago a record last arrived

#### Scenario: A tasklet's rate comes from its activity

- **WHEN** two successive activity reads report tasklet `ohlc`'s `admitted_total` as 100 and 150, 10 seconds apart by `read_at_ms`
- **THEN** `ohlc`'s node contributes a 5.0/s sample, smoothed like the other rates, and its width is the same as before the figure appeared

#### Scenario: Each output channel has its own rate

- **WHEN** a tally listen reports `alerts` advancing by 10 and `orders` by 2 over 5 seconds
- **THEN** the wire out of `alerts` reads 2.0/s and the wire out of `orders` 0.4/s

#### Scenario: Liveness counters cannot be read

- **WHEN** the snapshot call fails, is refused, or the controller does not export `Flezha.Service.Controller.liveness_counters/1`
- **THEN** the graph still renders structure and states from the remaining sources, with the screen's standard error notice and no relay rate figures

#### Scenario: Activity cannot be read

- **WHEN** the activity read is refused, times out, or the runner does not report activity
- **THEN** the tasklet graph still renders and no tasklet carries a rate figure

### Requirement: On-demand payload tap

The system SHALL let an operator tap a relay's input from any entry port, or its output from any output channel port, and watch live payloads.

**Listening:**
- A tap SHALL listen through `Flezha.Service.Relay.listen/5` with direction `input` or `output`, held by an `EventFeed` linked to the page, and SHALL run no code of this application on the controller.
- An output tap SHALL show first the records whose `channel` is the tapped port's, and SHALL offer to show every channel.

**What it shows:**
- The tapped port SHALL be marked while the tap is open, and the tap's figures SHALL render in a dock below the canvas.
- A tap SHALL report the messages per second and bytes per second measured over its own window, the dead-letter notices it heard, and the most recent payloads.
- Byte figures SHALL be measured from the raw payload before it is rendered printable.

**Ending:** a tap SHALL stop listening when the operator closes it or leaves the page. Opening a tap on another port SHALL close the first.

#### Scenario: Tapping an output channel

- **WHEN** the operator activates the `alerts` port and records flow on `alerts` and `orders`
- **THEN** the dock reports a message count, a total size, a messages-per-second and a bytes-per-second figure measured since the tap opened, and shows the most recent `alerts` payloads
- **AND** the `alerts` port is marked as tapped

#### Scenario: Switching ports

- **WHEN** an output tap is open and the operator activates an entry port
- **THEN** the output listen ends and an input listen opens in its place

#### Scenario: Closing a tap stops the listen

- **WHEN** the operator closes an open tap
- **THEN** the listen on the controller ends and the dock stops reporting

#### Scenario: Leaving the page stops the listen

- **WHEN** the operator navigates away with a tap open
- **THEN** the listen ends without the operator doing anything

#### Scenario: The controller refuses the tap

- **WHEN** `listen/5` answers `{:error, %Flezha.Error{}}`
- **THEN** the dock reports that the tap could not be opened, with the error's code and message, and the rest of the graph renders unaffected

### Requirement: Realtime updates without operator action

The graph and the summary SHALL refresh their snapshot-derived data on a periodic tick of at most 2 seconds while mounted, and SHALL apply runner session events forwarded by the event feed to runner and channel state as they arrive, without waiting for the next tick.

#### Scenario: Tick refreshes rates

- **WHEN** the graph is mounted and the refresh tick fires
- **THEN** a new liveness snapshot is fetched and edge rates, node states and counts re-render without any operator action

#### Scenario: Runner disconnect arrives between ticks

- **WHEN** a runner-disconnected event arrives before the next tick
- **THEN** the channel node re-renders as degraded immediately

### Requirement: Backpressure and stall surfacing

**Backpressure:** when the relay's runner channel reports credit active with an exhausted ledger, the system SHALL mark the relay's output edge with a backpressure mark. The relay inspector SHALL list the channel's credit figures.

**Stalls:**
- The system SHALL query recent observability signals for data-plane stall verdicts each tick. Verdicts younger than 60 seconds SHALL render as a banner naming the stalled layer and the affected relay, runner or channel.
- When the verdict's subject is the relay on display, its runner or its channel, the relay boundary SHALL carry a stall mark.
- Verdict age SHALL be measured against the controller's own clock, since the controller stamps those signals with its monotonic time.
- When the observability query is refused, the graph SHALL state that stall detection is unavailable and why, rather than rendering as though no stall exists.

#### Scenario: Channel exhausts credit

- **WHEN** a snapshot shows the relay's channel with `credit_active` set and `credit_ledger_level` at zero
- **THEN** the boundary's output edge carries a backpressure mark and the relay inspector lists the channel's credit figures

#### Scenario: Stall verdict is recent

- **WHEN** the observability query returns a `stall_localized` event younger than 60 seconds naming a layer and a `relay_id`, `runner_id` or channel
- **THEN** a banner renders naming the layer and that relay, runner or channel

#### Scenario: Stall verdict names this relay

- **WHEN** a recent `stall_localized` event names the relay on display, its runner, or its channel
- **THEN** the relay boundary carries a stall mark as well as the banner

#### Scenario: Stall verdict is stale

- **WHEN** the newest `stall_localized` event is older than 60 seconds
- **THEN** no banner and no stall mark render

#### Scenario: Observability is refused

- **WHEN** the observability query returns `{:error, %Flezha.Error{class: :denied}}`
- **THEN** the graph states that stall detection is unavailable and gives the error's code and message
- **AND** the rest of the graph renders normally

#### Scenario: Observability is switched off

- **WHEN** the observability query returns `{:error, %Flezha.Error{code: "observability.disabled"}}`
- **THEN** the graph states that stall detection is switched off on this controller

#### Scenario: Observability fails for another reason

- **WHEN** the observability query returns any other error
- **THEN** the graph renders normally with no stall banner and no error notice

### Requirement: Node detail and legend

The system SHALL show an inspector for a selected node in the dock below the canvas.

**Inspector contents:**
- **Relay** (its boundary's header): factory, runner, run (`flow` or `steps`, from the relay's builder), uptime, its counters and rates, the runner channel's credit and heartbeat figures, and every lifecycle-only binding with its hooks.
- **Source:** id, provider, the entry it feeds and any other hooks it is bound to. When it names no channel, the inspector SHALL say that it feeds the first entry channel.
- **Input filter:** id, provider, the entries it acts on and its skipped count.
- **Entry or output channel port:** name, kind, producer, readers and bound plugins. An unbound output channel SHALL say that only a listener sees its records.
- **Plugin:** id, provider, hook, position and channels. An `on_output` plugin's inspector SHALL state that the controller runs every `on_output` plugin in position order and that each acts only on its own channels.

A tasklet's details SHALL be shown in its Cell sheet. Selecting another node SHALL replace the inspector, and dismissing it SHALL clear the selection.

**Legend:** the system SHALL offer a legend naming every node role, port, wire style, mark and motion form used on the graph, including:
- the relay boundary;
- a tasklet with one Cell and with several;
- a folded run;
- a source;
- an input filter and its skipped end;
- a "no plugin bound" end;
- a junction dot;
- a moving mark, stating that its speed is not the record's;
- a streaming wire;
- the dead-letter and backlog badges.

**Styling:** nodes and the legend SHALL be drawn with the stylebook's relay-graph roles, so a plugin, a tasklet and the relay boundary look as they do on flezha.com. The inspector SHALL be a stylebook panel.

#### Scenario: Selecting the relay

- **WHEN** the operator activates the relay boundary's header
- **THEN** the inspector shows its factory, runner, run, uptime, counters, channel credit figures and lifecycle-only bindings

#### Scenario: Selecting a source that names no channel

- **WHEN** the operator selects `ws_chain` on `testnet_chain`
- **THEN** the inspector names provider `relay_websocket`, entry `input`, that it feeds the first entry channel because its options name none, and that it is also bound to `on_terminate`

#### Scenario: Legend opens on demand

- **WHEN** the operator activates the legend control
- **THEN** a popover names what each node role, port, wire style, mark and motion form means

#### Scenario: Dismissing the panel

- **WHEN** the operator closes the inspector
- **THEN** the selection clears and no inspector renders

#### Scenario: The graph speaks the shared vocabulary

- **WHEN** the graph markup is rendered
- **THEN** its plugin and source nodes carry the stylebook's plugin role and each tasklet inside the boundary carries the tasklet role

#### Scenario: An output plugin explains its order

- **WHEN** the operator clicks an `on_output` plugin
- **THEN** the inspector names the channels it takes from, its position, and that every `on_output` plugin runs in position order and acts only on its own channels

### Requirement: Fleet summary at fixed cost

The system SHALL render, on the dashboard and on a namespace page, a summary of the namespace's data plane: relay and runner counts broken down by the health `Flezha.Service.Relay.relay_rows/2` reports, runners whose channels report backpressure, dead-letter pressure, recent stall verdicts, and the busiest relays by measured throughput. Every health verdict the controller returns, including `recovering` and `parked`, SHALL be its own bucket. A relay that is unhealthy, unplaced, suspended, parked, or a member of a partition group whose coverage is faulted SHALL be surfaced by the summary even when its throughput is zero. The summary SHALL be assembled from a number of controller calls that does not grow with the number of relays, and each listed relay SHALL link to its pipeline graph.

#### Scenario: Dashboard summarises the selected namespace

- **WHEN** an operator opens the dashboard while namespaces exist
- **THEN** the summary renders for the namespace named by `?ns=`, or the first namespace in sorted order when the parameter is absent, and changing the selector updates both the summary and the query parameter

#### Scenario: Namespace page summarises its own namespace

- **WHEN** an operator opens a namespace's show page
- **THEN** the same summary renders scoped to that namespace, without a namespace selector

#### Scenario: Health is broken out

- **WHEN** the summary renders for a namespace whose relays are not all healthy
- **THEN** the counts are broken down by health
- **AND** each non-healthy bucket links to those relays on the `/relays` listing

#### Scenario: An idle unhealthy relay is not hidden

- **WHEN** a relay is unhealthy or unplaced but its counters have not advanced
- **THEN** the summary surfaces it despite its zero throughput

#### Scenario: Busiest relays are ranked and linked

- **WHEN** two snapshots have been taken and several relays have advanced their counters
- **THEN** the summary lists the relays with the highest measured throughput, each linking to its own pipeline graph

#### Scenario: Summary cost does not grow with the fleet

- **WHEN** the summary is assembled for a namespace
- **THEN** it issues no per-relay controller call

#### Scenario: Namespace has nothing running

- **WHEN** the selected namespace has no relays and no runners
- **THEN** the summary shows an empty state naming the namespace

#### Scenario: Controller is unreachable

- **WHEN** no controller node is connected
- **THEN** the summary shows the degraded state the hosting screen already uses for a disconnected controller

### Requirement: Click-through navigation

The relay inspector SHALL link to that relay's listen view at `/namespaces/:ns/relays/:id/listen` and to the cluster page for its runner. The dead-letter end SHALL link to the DLQ page. A plugin's inspector SHALL link to the relay's plugin bindings.

#### Scenario: Relay click-through

- **WHEN** the operator activates the relay inspector's listen link
- **THEN** the browser navigates to that relay's listen view

#### Scenario: Runner click-through

- **WHEN** the operator activates the relay inspector's runner link
- **THEN** the browser navigates to the cluster page

#### Scenario: Dead-letter click-through

- **WHEN** the operator activates the dead-letter end
- **THEN** the browser navigates to the DLQ page

### Requirement: Relay pipeline graph

The system SHALL render, on a relay's page, a graph of the path a record takes through that relay. It SHALL be one layered layout:
- **Sources first:** sources on the far side, then input filters.
- **Then the relay boundary,** holding:
  - its entry channels as ports on its near edge;
  - its tasklets inside, ranked by longest path from the entries;
  - the channels between tasklets as wires named by channel at their producer;
  - its output and call channels as ports on its far edge.

  The boundary's header SHALL name the relay and `factory <id>`.
- **Then the ends:** output plugins, call targets and "no plugin bound" ends, beyond the far edge.
- **Dead letters:** a dead-letter end past the boundary on the cross side.

**Shapes:**
- A channel that is both read by a tasklet and bound to plugins SHALL have both its inner wire and its port.
- A call end SHALL lead to its target relay, and the target SHALL be drawn again as the source of the call's answer channel.

**Plugins:**
- **Sources:** a plugin whose provider feeds a relay (the provider listing's `feeds` flag) SHALL be drawn as a source on its `entry_channel`, or on the first announced entry channel when it names none. On a controller whose listing lacks the flag, only a plugin naming an entry channel SHALL be drawn as a source.
- **Input filters:** an `on_input` plugin SHALL sit between the sources of the entries in its `filter_channel` and those entries; one naming no channel acts on every entry but a call's answer entry. Its "skipped by filter" end SHALL be drawn only when such a plugin is bound or its count is above zero.
- **Output plugins:** an `on_output` plugin SHALL end each output channel in its `filter_channel`. A plugin on several channels SHALL be drawn once.
- **Other plugins:** a plugin bound only to hooks off the record path SHALL NOT be drawn; it is listed in the relay inspector. A plugin that names no channel, or none the graph has, SHALL attach to the boundary and be marked as such.

**Tasklets:**
- Each tasklet SHALL be as wide as its name, with names over 34 characters shortened in the middle. A rank SHALL be as thick as its widest node.
- A tasklet with several Cells SHALL be drawn as a stack captioned with its keys (static) or live Cell count (dynamic). A single-Cell tasklet SHALL be drawn as one card.
- Dead letters a tasklet parked, and a backlog, SHALL be badges on its lower edge, so a badge appearing moves no node.
- A straight run of four or more tasklets, each reading only the one before it, SHALL fold into one node naming its first and last tasklet; activating it SHALL expand the run.

**No announced graph:** the relay SHALL be drawn as an empty boundary between its sources and its output plugins, with a line naming why its inside is not shown.

**Sources of the structure:** pipeline structure SHALL come from the relay's overwatch state (read through `Flezha.Service.Relay.overwatch_state/3`, its hook table and plugin table), the provider listing, and the relay's announced graph.

**Stability:**
- Node positions SHALL depend only on the relay's non-observer bindings, its announced graph, the folded runs and the drawn direction.
- Every node SHALL carry a unique id.
- Selecting a node, opening a tap or opening the Cell sheet SHALL NOT move any node.

#### Scenario: A source bound only to tear down is a source

- **WHEN** `testnet_chain`'s `relay_websocket` plugin `ws_chain` is bound only to `on_terminate` and names no channel
- **THEN** `ws_chain` is drawn as a source feeding the `input` port, and no lifecycle chip, runner channel or runner output node is drawn

#### Scenario: Inside and outside line up

- **WHEN** a source feeds an entry read by one tasklet
- **THEN** the source, its wire, the entry port and the tasklet lie on one line along the main axis

#### Scenario: The relay's own graph is drawn inside its boundary

- **WHEN** the relay's factory announces entry `trades_in` read by tasklets `ohlc` and `trades`, and `ohlc` producing `ohlc_out`, read by tasklet `atr` and bound to a plugin
- **THEN** the boundary shows a `trades_in` port on its near edge, tasklets `ohlc` and `trades` after it, a wire named `ohlc_out` from `ohlc` to `atr`, and an `ohlc_out` port on its far edge

#### Scenario: An unbound output channel says so

- **WHEN** the output channel `kafka` has no plugin bound
- **THEN** its port leads to a muted "no plugin bound" end

#### Scenario: Several plugins on one channel

- **WHEN** `alerts_webhook` and `alerts_stdout` both name channel `alerts`
- **THEN** both end the `alerts` channel, each naming its position

#### Scenario: One plugin on several channels

- **WHEN** plugin `demo_indicators` names five output channels
- **THEN** it is drawn once with a wire from each of the five ports

#### Scenario: A plugin names a channel the relay does not have

- **WHEN** an `on_output` plugin names channel `ohcl_out` and the announced graph has no such channel
- **THEN** the plugin attaches to the relay boundary, is marked as attached to every channel, and its inspector states that the relay has no channel `ohcl_out`

#### Scenario: Names are not clipped

- **WHEN** a tasklet is named `static_downstream_tasklet`
- **THEN** its node shows the whole name

#### Scenario: A straight run folds

- **WHEN** four tasklets form a straight run
- **THEN** one node reads "4 tasklets" naming the first and last, and activating it draws the four tasklets

#### Scenario: No graph announced

- **WHEN** the relay's runner announced no graph, or the controller does not export `Flezha.Service.Relay.graph/3`
- **THEN** the boundary is drawn empty between the sources and the output plugins, and a line states that the relay's inside is not shown and why

#### Scenario: Nothing parked yet

- **WHEN** the relay has no parked records
- **THEN** the dead-letter end renders muted with zero parked, at the position it keeps once records park

#### Scenario: Selecting does not move the graph

- **WHEN** the operator selects a node, opens a tap or opens the Cell sheet
- **THEN** every node keeps its position in the graph's coordinates

#### Scenario: Controller is unreachable

- **WHEN** no controller node is connected
- **THEN** the graph region shows the same degraded state the hosting screen already uses for a disconnected controller, and no graph markup renders

### Requirement: Listeners are observers, not steps

The pipeline SHALL treat every binding whose provider is `Flezha.Plugin.Provider.MonitoredIOForward` as an observer of the relay, not as a plugin on its path:
- Observers SHALL NOT render as nodes and SHALL NOT affect the position of any node.
- They SHALL be grouped by plugin id, so one listener bound to several hooks counts once.
- The page's own tally listen SHALL NOT be counted.

**Where they are counted:** an observer bound to `on_input` SHALL be counted on the boundary's entry edge, one bound to `on_output` or `on_preview` on its output edge, and one bound to `on_call` on the boundary's header. Each count SHALL list the observing plugin ids on hover and focus.

**The operator's own tap:** while it is open on a port, that port SHALL say so, whatever the count.

**Header:** the graph header SHALL count distinct non-observer plugin ids, and SHALL state the number of observers separately when there are any.

#### Scenario: Opening a tap does not reshape the pipeline

- **WHEN** the operator opens a tap on an entry and the next tick reads a hook table holding its listener binding
- **THEN** the same nodes render at the same coordinates as before the tap opened
- **AND** the entry edge's observer count includes the listener

#### Scenario: The page's tally is not an observer

- **WHEN** the page holds a tally listen on the relay and nobody else listens
- **THEN** no observer count is shown and the header states no listener

#### Scenario: An output listener counts once

- **WHEN** the hook table holds one `MonitoredIOForward` plugin bound to both `on_output` and `on_preview`
- **THEN** the output edge counts one observer and no node renders for it

#### Scenario: Another caller's listen comes and goes

- **WHEN** a listener binding held by another caller appears in the hook table and is gone on a later tick
- **THEN** only the matching edge's observer count changes between those ticks

#### Scenario: The header counts plugins

- **WHEN** a relay has one plugin bound to two hooks and one output listener
- **THEN** the header reads one plugin attached and one listening

### Requirement: Records are drawn as they pass

The graph SHALL show record movement on every tick, whether or not a tap is open, from these counters:
- the relay's IN, filtered and forwarded counters;
- the relay class's parked count;
- each tasklet's admitted delta;
- each output channel's tally delta.

**Causal order:**
- A mark SHALL start only on a source's wire.
- A mark reaching a node SHALL be handed on along that node's outgoing wires while their budget for the tick lasts:
  - a filter hands it to the entry or to the skipped end;
  - an entry port hands it to every tasklet reading it;
  - a tasklet hands it on after a short pause, as many as its own outputs allow;
  - an output port hands it to its plugins;
  - a call target hands it to the answer channel.
- A count no mark reaches within a few seconds SHALL be launched as is, so every count is drawn or counted. A mark reaching a node whose count arrives a tick later SHALL wait for that count rather than be dropped.
- An entry nothing drawn feeds, its records sent to the relay directly, SHALL start marks as a source does.

**Sampling:**
- At most four marks a second SHALL travel a wire. A mark on a sampled wire SHALL stand for the records it represents, so the wires after it receive their right share.
- At most 80 marks SHALL be drawn at once. Marks beyond that SHALL still be handed on unseen, and every figure SHALL still count them. Every dead letter SHALL be drawn.

**Taps:** while a tap is open, the records it hears SHALL be drawn as filled marks on the tapped wire. While traffic is rare, a filled mark SHALL carry the start of its payload, at most 40 characters.

**Drawing:**
- Marks SHALL be drawn on a canvas laid over the graph, SHALL survive the graph's re-renders, and SHALL stop while the page is hidden or the graph is off screen.
- No mark SHALL move when the viewer prefers reduced motion.
- The server SHALL send the browser one push per tick for counted records and at most one push per 250 milliseconds for tapped records.

#### Scenario: A record crosses the relay in order

- **WHEN** one record enters `testnet_chain` and leaves on `kafka` within one tick
- **THEN** its mark travels the source wire, then the wire into `static_entry_tasklet`, then `hop`, then the wire out to `kafka`, each starting only after the previous one arrived

#### Scenario: A tasklet that emits less hands on less

- **WHEN** a tick shows 100 records admitted to `volume_window` and 20 admitted to the tasklet it feeds
- **THEN** the marks leaving `volume_window` stand for 20 records in total

#### Scenario: Filtered and parked records go where they went

- **WHEN** a tick shows `filtered_nil` advanced by two and the parked count by one
- **THEN** two marks travel from the filter into its skipped end and one failure-styled mark into the dead-letter end
- **AND** both ends update their counts

#### Scenario: A burst is capped

- **WHEN** a tick shows a thousand records forwarded
- **THEN** no more than 80 marks are drawn and the figures show all thousand

#### Scenario: Reduced motion

- **WHEN** the viewer's browser prefers reduced motion
- **THEN** no mark moves, wires that carried records in the last tick are drawn heavier, and every figure still advances

#### Scenario: A tick re-renders mid-flight

- **WHEN** the refresh tick re-renders the graph while marks are travelling
- **THEN** those marks continue to their destinations

### Requirement: A stream and a trickle read differently

Each counted wire SHALL be in one of three states, decided from its displayed rate with hysteresis:
- **Streaming:** from 12 records a second until it falls to 9.
- **Trickling:** below that, while a record has passed in the last 30 seconds.
- **Quiet:** otherwise.

**Streaming wires:** a streaming wire SHALL be drawn as a continuous flow moving at `60 + 40·log10(1 + rate)` pixels a second, thicker for a higher rate. It SHALL draw no per-record marks except dead letters. A record arriving on a streaming wire SHALL be handed on at once.

**Trickling wires:** a trickling wire SHALL draw marks as `Records are drawn as they pass` describes. A mark SHALL cross a wire in 0.35 to 1.2 seconds whatever its length, and the legend SHALL say that this is not the record's own speed.

**Quiet wires:** a quiet wire SHALL be static, and its entry wire SHALL say how long it has been quiet.

**Backpressure:** when the channel reports backpressure, the flows out of the relay SHALL stop and turn to the warning colour. No count of waiting records SHALL be shown, because the controller reports none.

#### Scenario: A busy wire streams

- **WHEN** a wire's displayed rate reaches 12 records a second
- **THEN** it is drawn as a continuous flow and per-record marks stop on it

#### Scenario: Hysteresis

- **WHEN** a streaming wire's rate falls to 10 records a second
- **THEN** it stays streaming until its rate falls to 9

#### Scenario: A relay goes quiet

- **WHEN** no counter has advanced for more than 30 seconds
- **THEN** the wires are static and each entry wire states how long it has been quiet

#### Scenario: The runner is full

- **WHEN** the channel reports credit active with an exhausted ledger
- **THEN** the flows out of the relay stop in the warning colour and the boundary's output edge carries its backpressure mark

### Requirement: The graph says what is happening

Below the canvas the graph SHALL state the relay's flow in one plain sentence led by a state word, chosen in this order:
1. **Stuck** when the channel reports backpressure.
2. **Failing** when more than a tenth of the records taken in the last two ticks were parked.
3. Otherwise **Streaming**, **Trickle** or **Quiet**, after the busiest entry wire's state.

**Timeline:** beneath the sentence, a timeline SHALL show per tick how many records came in, were delivered, were skipped and were parked, each on its own row. The history SHALL be retained in memory for the session, at most 60 samples.

**Tooltips:** hovering or focusing a wire SHALL show a tooltip naming its channel, its rate and when a record last passed. A wire the system does not count SHALL say so.

#### Scenario: The sentence follows the flow

- **WHEN** the relay is streaming at about 120 records a second with a tenth of them skipped by its filter
- **THEN** the sentence reads Streaming and states the in rate, the delivered rate and the skipped share

#### Scenario: Failing outranks streaming

- **WHEN** a streaming relay parks more than a tenth of what it took over the last two ticks
- **THEN** the state word reads Failing

#### Scenario: The timeline shows when

- **WHEN** a batch of thirty records passed forty seconds ago and nothing since
- **THEN** the timeline shows bars at that point on the In and Delivered rows and nothing after them

#### Scenario: A wire's tooltip

- **WHEN** the operator hovers the wire named `hop`
- **THEN** the tooltip names `hop`, its rate and when a record last passed on it

### Requirement: The graph is driven from the keyboard

Every selectable node and every port SHALL take keyboard focus and carry an accessible name.
- **Enter** SHALL select a focused node, open a focused tasklet's Cell sheet, expand a focused folded run, or open the tap on a focused port.
- **Arrow keys along the main axis** SHALL move focus to the next or previous node a record reaches.
- **Arrow keys across it** SHALL move focus to the neighbouring node in the same rank.
- **Escape** SHALL close the Cell sheet, then full screen, then dismiss the selected node.

#### Scenario: Walking the record path

- **WHEN** the `input` port of `testnet_chain` has focus, the graph is drawn left to right, and the operator presses the right arrow key twice
- **THEN** focus moves to `static_entry_tasklet` and then to `static_downstream_tasklet`

#### Scenario: Opening Cells from the keyboard

- **WHEN** a tasklet has focus and the operator presses Enter
- **THEN** its Cell sheet opens

#### Scenario: Tapping from the keyboard

- **WHEN** an output port has focus and the operator presses Enter
- **THEN** the output tap opens on that channel

#### Scenario: Dismissing from the keyboard

- **WHEN** the Cell sheet is open and the operator presses Escape
- **THEN** the sheet closes, and a second Escape clears the selection

### Requirement: Tasklet figures only while the page is watched

The system SHALL make three reads only while the relay page is connected and visible, and SHALL stop them when the page is hidden or closed:
- **Activity:** the relay's activity through `Flezha.Service.Relay.activity/4`, on the page's own tick.
- **Cell rows:** only while a Cell sheet is open.
- **Tally:** a tally listen through `Flezha.Service.Relay.listen/5`, held by an `EventFeed` linked to the page, only while the relay has two or more output channels. It SHALL end when the page is hidden, closed or crashes, and start again when the page is visible again.

**Marks:**
- A tasklet whose `queued_max` has been above zero for two consecutive reads SHALL carry a backlog badge with that count, the deepest such tasklet marked first.
- A tasklet whose dropped totals advanced since the previous read SHALL carry a shed badge with the number shed.

**Structure:** the graph structure SHALL be read once when the page opens and again when the relay's runner reconnects, not on every tick.

#### Scenario: Reads stop when the tab is hidden

- **WHEN** the operator switches to another browser tab for a minute
- **THEN** no activity read is made for the relay during that minute, the tally listen ends, and both resume after the tab is visible again

#### Scenario: The tally ends with the page

- **WHEN** the operator leaves the relay page
- **THEN** within the listener's heartbeat interval the relay lists no listener plugin

#### Scenario: A one-output relay needs no tally

- **WHEN** the relay has one output channel
- **THEN** no tally listen is opened and that channel's rate comes from the relay's `forwarded` count

#### Scenario: A backlog is marked

- **WHEN** tasklet `book` reports `queued_max` 40 on two consecutive reads
- **THEN** `book` carries a backlog badge reading 40 queued

#### Scenario: Shedding is marked

- **WHEN** tasklet `ticks`'s `dropped_oldest_total` rose by 3 since the previous read
- **THEN** `ticks` carries a shed badge reading 3 shed

#### Scenario: Structure is not re-read every tick

- **WHEN** the page has been open for ten ticks and no runner reconnected
- **THEN** the relay's graph has been read once

### Requirement: The viewer chooses the direction and the zoom

The pipeline panel SHALL offer the following controls:
- a direction control with Auto, Left to right and Top to bottom;
- zoom out, zoom in, Fit and 100%;
- full screen.

**Direction:**
- The choice SHALL be remembered per viewer in the browser. It SHALL be Auto until the viewer picks one.
- Auto SHALL draw the direction in which the whole graph fits its panel at the larger scale.
- Both directions SHALL apply the same layout rules: the layout SHALL be computed on a main axis, the way records travel, and a cross axis, and only then mapped to x and y.

**Zoom and pan:**
- The graph SHALL open fitted to its panel, never scrolling the page. The panel SHALL be at most about three quarters of the viewport high.
- Ctrl or ⌘ with the wheel SHALL zoom around the pointer, and dragging the canvas background SHALL pan.
- Zooming, panning and full screen SHALL change only the view, never the layout, and SHALL NOT be sent to the server.
- Escape SHALL leave full screen.

#### Scenario: Auto picks the fitting direction

- **WHEN** the market relay, with seven tasklets reading one entry, is opened with the direction on Auto in a 1,400 px wide panel
- **THEN** it is drawn left to right, and the header names the direction it chose

#### Scenario: The choice is remembered

- **WHEN** a viewer picks Top to bottom and reloads the page
- **THEN** the graph is drawn top to bottom

#### Scenario: The graph fits instead of scrolling

- **WHEN** a relay whose graph is twice the panel's width is opened
- **THEN** the whole graph is visible in the panel, the page does not scroll sideways, and the zoom reads the fitted scale

#### Scenario: Zoom does not move the layout

- **WHEN** the viewer zooms in twice and drags the canvas
- **THEN** no node changes its position in the graph's own coordinates and the server receives no event

### Requirement: Every wire can be told apart

The graph SHALL draw wires at right angles with rounded corners.

**Nets:**
- All wires leaving one point on one channel SHALL form one net, drawn as one trunk that splits.
- In each gap between ranks, each net that bends SHALL have its own lane, at least 12 px from the next. Lanes SHALL be ordered to cross as few other nets as possible.
- Nets meeting one node SHALL arrive, or leave, at separate points along its side, never merging into one line.

**Crossings and splits:**
- Where one net crosses another, the line beneath SHALL be visibly cut by the one above.
- Every point where a net splits SHALL carry a junction dot.

**Colours:** each net SHALL take one of six wire colours, defined for both themes. Two nets that run side by side in a gap, or arrive at the same node, SHALL NOT share a colour, and nets sharing a gap SHALL avoid sharing one while a colour is left. Motion SHALL keep the signal colour on any wire.

**Focus:** hovering or focusing a wire or a node SHALL light the nets touching it and their ends, and dim the rest. With nothing hovered, a selected tasklet SHALL keep that focus.

#### Scenario: Two entries into one tasklet stay apart

- **WHEN** tasklet `route_latest` reads both `trades_in` and `config_in`
- **THEN** the two wires reach `route_latest` at different points on its side and carry different colours

#### Scenario: A fan-out is one trunk

- **WHEN** entry `trades_in` is read by seven tasklets
- **THEN** one trunk leaves the `trades_in` port and splits, with a junction dot at each split

#### Scenario: Hover traces a path

- **WHEN** the viewer hovers `merge_ticks`
- **THEN** its two input wires and its fan-out are lit and every other wire and node is dimmed

### Requirement: A tasklet's Cells open in a table

Selecting a tasklet SHALL open a sheet over the graph's right side.

**Header:**
- the tasklet's name, Cell mode, live Cell count and intake rate;
- one control per neighbouring tasklet, upstream and downstream, naming the channel between them; each SHALL open that tasklet's sheet.

**Table:**
- Rows SHALL list up to 50 Cells, from `Flezha.Service.Relay.activity/4` with `cells_of`.
- Columns: key, records in per second (from the Cell's admitted total between reads), queued, blocked, dropped, and time since the last record.
- The table SHALL be sortable by any column, by default the busiest first.
- A row whose Cell admitted a record since the previous read SHALL carry a fresh mark.
- When the tasklet has more Cells than rows, the sheet SHALL say how many, and that the rows are the most recently active ones the runner picked.

**Layout:** the graph SHALL refit into the width the sheet leaves free.

**Reads:** the Cell rows SHALL be read only while the sheet is open. When the runner answers no Cells, the sheet SHALL say that this runner does not report its Cells.

**Closing:** Escape or the close control SHALL close the sheet and refit the graph.

#### Scenario: A static tasklet's Cells

- **WHEN** the viewer selects `static_entry_tasklet` on `testnet_chain`
- **THEN** the sheet lists the Cells `a`, `b`, `c` and `d` with their rates and counts, and the hop control names `hop → static_downstream_tasklet`

#### Scenario: A large dynamic tasklet

- **WHEN** the viewer selects a dynamic tasklet with 342 live Cells
- **THEN** the sheet lists 50 Cells and says it shows the 50 most recently active of 342

#### Scenario: Reads stop when the sheet closes

- **WHEN** the sheet is closed
- **THEN** the next tick reads the relay's activity without `cells_of`

#### Scenario: A runner that does not report Cells

- **WHEN** the relay's runner answers `cells: nil` (a runner built before the SDKs shared the core's per-Cell counters)
- **THEN** the sheet states that this runner does not report its Cells, and the tasklet's own figures still show

