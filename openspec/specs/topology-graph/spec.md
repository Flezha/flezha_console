# topology-graph Specification

## Purpose
The live picture of the flezha data plane: one relay's pipeline — what is
attached to it, in what order, what is flowing through it and what is stuck —
plus a namespace-level summary whose cost does not grow with the size of the
fleet.
## Requirements
### Requirement: Flow rates where the controller counts them

The system SHALL compute message rates as the difference between successive data-plane liveness snapshots, read from `Flezha.Service.Controller.liveness_counters/1`, divided by the elapsed time between them, measured on the UI's monotonic clock. A relay's counters SHALL be read from the snapshot's `relays` list, keyed by `relay_id`. Negative differences SHALL clamp to zero. Rates SHALL be displayed only where the controller actually counts: at the IN port (`io_in_received`), at the OUT port (`forwarded`), and on the edge out of the channel (`send_frame_calls`). Edges between plugins SHALL carry no rate figure. The pipeline SHALL display, and SHALL animate from, the mean of the relay's newest seven rate samples. A mean above zero that would round to zero SHALL read `<0.1/s`. Each port SHALL state how long ago its counter last advanced, or that it has not advanced since the page opened. Edges SHALL animate at a speed bucket derived from their displayed rate. Edges at zero rate SHALL render static, and their figures SHALL be visually subdued.

#### Scenario: Rates appear after two snapshots

- **WHEN** the graph has received two consecutive snapshots where the relay's counts advanced
- **THEN** its IN and OUT ports each display a messages-per-second rate derived from the count delta and elapsed time, and their wires carry an animation class for the matching speed bucket

#### Scenario: Counters are found by relay id

- **WHEN** a snapshot's `relays` list holds an entry whose `relay_id` is the relay on display
- **THEN** that entry's counters are the ones the rates are computed from

#### Scenario: First snapshot has no baseline

- **WHEN** the graph renders from its first snapshot
- **THEN** the ports display no rate figure and no wire animates

#### Scenario: Controller restart resets counters

- **WHEN** a snapshot reports counts lower than the previous snapshot's
- **THEN** that tick contributes a zero sample to the rates instead of a negative one

#### Scenario: A slow relay does not read zero

- **WHEN** a relay's input advances by one record on one tick out of every three
- **THEN** the IN port reads a steady non-zero rate rather than alternating between a figure and `0.0/s`

#### Scenario: A trickle below one decimal

- **WHEN** the mean of the newest seven samples is above zero and below 0.05
- **THEN** the port reads `<0.1/s`

#### Scenario: Last record recency

- **WHEN** the relay's output counter last advanced two ticks ago
- **THEN** the OUT port states roughly how many seconds ago a record last passed

#### Scenario: No rate is invented between plugins

- **WHEN** the pipeline renders a chain of plugins
- **THEN** the edges between plugin nodes carry no messages-per-second figure, because the controller keeps no per-hook counter

#### Scenario: Liveness counters cannot be read

- **WHEN** the snapshot call fails, is refused, or the controller does not export `Flezha.Service.Controller.liveness_counters/1`
- **THEN** the graph still renders structure and states from the remaining sources, with the screen's standard error notice and no rate figures

### Requirement: On-demand payload tap

The system SHALL let an operator tap the relay's input or output from the graph's IN or OUT port and watch live payloads. A tap SHALL listen through `Flezha.Service.Relay.listen/5` with direction `input` or `output`, held by an `EventFeed` linked to the page, and SHALL run no code of this application on the controller. The tapped port SHALL be marked while the tap is open, and the tap's figures SHALL render in a dock below the canvas. A tap SHALL report the messages per second and bytes per second measured over the tap's own window, the dead-letter notices it heard, and the most recent payloads. It SHALL stop listening when the operator closes it or leaves the page. Opening a tap on the other port SHALL close the first. Byte figures SHALL be measured from the raw payload before it is rendered printable.

#### Scenario: Tapping the output

- **WHEN** the operator activates the OUT port and messages flow
- **THEN** the dock reports a message count, a total size, a messages-per-second and a bytes-per-second figure measured since the tap opened, and shows the most recent payloads
- **AND** the OUT port is marked as tapped

#### Scenario: Switching ports

- **WHEN** the output tap is open and the operator activates the IN port
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

The system SHALL surface channel credit state — a backpressure indicator when the relay's channel reports credit active with an exhausted ledger — and SHALL query recent observability signals for data-plane stall verdicts each tick, rendering verdicts younger than 60 seconds as a banner naming the stalled layer and the affected relay, runner or channel. When the verdict's subject is the relay on display, its runner, or its channel, the pipeline SHALL also mark that node. Verdict age SHALL be measured against the controller's own clock, since the controller stamps those signals with its monotonic time. When the observability query is refused, the graph SHALL state that stall detection is unavailable and why, rather than rendering as though no stall exists.

#### Scenario: Channel exhausts credit

- **WHEN** a snapshot shows the relay's channel with `credit_active` set and `credit_ledger_level` at zero
- **THEN** the channel node renders a backpressure indicator and its detail lists the channel's credit figures

#### Scenario: Stall verdict is recent

- **WHEN** the observability query returns a `stall_localized` event younger than 60 seconds naming a layer and a `relay_id`, `runner_id` or channel
- **THEN** a banner renders naming the layer and that relay, runner or channel

#### Scenario: Stall verdict names a node on the graph

- **WHEN** a recent `stall_localized` event names the relay on display, its runner, or its channel
- **THEN** the matching node renders a stall marker as well as the banner

#### Scenario: Stall verdict is stale

- **WHEN** the newest `stall_localized` event is older than 60 seconds
- **THEN** no banner and no stall marker render

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

The system SHALL show an inspector for a selected node, in the dock below the canvas: for the core, its raw monotonic counters, current rates, factory, runner, run (`flow` or `steps`, from the relay's builder) and uptime; for the channel, its per-channel counters, credit state and heartbeat figures; for a plugin, its plugin id, provider, hook and position. Selecting another node SHALL replace the inspector and dismissing it SHALL clear the selection. The system SHALL offer a legend, behind a control in the graph's header, naming every line style, node state, port and observer mark used on the graph. Nodes, wires, flow dots and the legend SHALL be drawn with the stylebook's relay-graph recipe, so a plugin, the relay core, the runner's channel, a degraded wire and a dead or suspended node look as they do on flezha.com. The inspector SHALL be a stylebook panel.

#### Scenario: Selecting the core

- **WHEN** the operator clicks the relay core node
- **THEN** the inspector shows its counters, rates, factory, runner, run and uptime

#### Scenario: Selecting a plugin

- **WHEN** the operator clicks a plugin node
- **THEN** the inspector names that plugin's id, provider, hook and position

#### Scenario: Legend opens on demand

- **WHEN** the operator activates the legend control
- **THEN** a popover names what each line style, node state, port and observer mark means

#### Scenario: Dismissing the panel

- **WHEN** the operator closes the inspector
- **THEN** the selection clears and no inspector renders

#### Scenario: The graph speaks the shared vocabulary

- **WHEN** the graph markup is rendered
- **THEN** its plugin nodes carry the stylebook's plugin role, the core the tasklet role, the channel the runner role, a degraded edge the failed-wire style, a disconnected node the dead state, and a flow dot the stylebook's flow-dot class
- **AND** the flow animation still carries its `topo-flow-*` speed bucket class

#### Scenario: A dead-letter branch is not a failure

- **WHEN** a relay has a dead-letter branch and nothing is degraded
- **THEN** the branch is drawn as a dotted amber wire, not in the failed-wire style, and the legend names it apart from a wire with nothing bound at its far end

#### Scenario: The legend names node states

- **WHEN** the legend is open
- **THEN** it shows the plugin, relay-code, runner-channel and record-end roles and the suspended and unbound states, each drawn as the graph draws it

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

Every node on the graph SHALL link to the screen that owns it: the relay core to that relay's listen view at `/namespaces/:ns/relays/:id/listen`, the channel to the cluster page, the dead-letter branch to the DLQ page, and a plugin to the relay's plugin bindings.

#### Scenario: Core click-through

- **WHEN** the operator activates the relay core node's navigate action
- **THEN** the browser navigates to that relay's listen view

#### Scenario: Channel click-through

- **WHEN** the operator activates the channel node's navigate action
- **THEN** the browser navigates to the cluster page

#### Scenario: Dead-letter click-through

- **WHEN** the operator activates the dead-letter node
- **THEN** the browser navigates to the DLQ page

### Requirement: Relay pipeline graph

The system SHALL render, on a relay's page, a graph of the path a record takes through that relay, laid out as three left-to-right lanes. The record lane SHALL hold a transport ingest node, the IN port, the relay's `on_input` plugins in position order, the relay core, the OUT port, its `on_output` plugins in position order, the bound runner's channel, and the relay's output. The lifecycle lane SHALL hold one chip per plugin bound only to hooks that do not sit on the record path, naming each of its hooks, attached to the core. The failures lane SHALL hold a filtered sink, for records the relay dropped by returning nil, and the dead-letter sink. Both SHALL be drawn whether or not anything has reached them. Pipeline structure SHALL come from the relay's overwatch state, read through `Flezha.Service.Relay.overwatch_state/3`, and its table of bound hooks, so the graph shows the plugins that are actually bound in the order the controller runs them. Node positions SHALL depend only on the relay's non-observer bindings. Every node SHALL carry a unique id. Selecting a node or opening a tap SHALL NOT move or resize the canvas. When the chain is too wide for its panel, the canvas SHALL scale down to no less than three quarters of its size and SHALL then scroll inside its panel, never the page. The last node of the record lane SHALL be presented as the relay's output in markup, class names and test ids, not as a sink.

#### Scenario: Relay with bound plugins

- **WHEN** an operator opens a relay whose hook table names an `on_input` plugin and an `on_output` plugin
- **THEN** the record lane renders ingest, the IN port, that input plugin, the core, the OUT port, that output plugin, the channel, and output from left to right, each plugin node naming its plugin id and provider

#### Scenario: Ordering follows position

- **WHEN** a relay has two `on_output` plugins at positions 0 and 1
- **THEN** they render in that order between the OUT port and the channel

#### Scenario: Off-path hook

- **WHEN** a relay has a plugin bound on the `on_interval` hook
- **THEN** it renders as a chip in the lifecycle lane attached to the core, not as a step on the record lane

#### Scenario: One plugin on several hooks

- **WHEN** a plugin is bound to `on_input` and to `on_terminate`
- **THEN** it renders once as an input step and once as a lifecycle chip, and no two elements on the graph share a test id

#### Scenario: Relay with no plugins

- **WHEN** a relay has nothing bound
- **THEN** the record lane still renders ingest, both ports, core, channel and output, and states that no plugins are bound

#### Scenario: Nothing parked yet

- **WHEN** the relay has no parked records
- **THEN** the dead-letter sink renders muted with zero parked, at the position it keeps once records park
- **AND** the filtered sink is drawn beside it in the same way

#### Scenario: Relay is not bound to a runner

- **WHEN** a relay's overwatch state names no runner
- **THEN** the channel node renders as unbound and the edge into it renders degraded

#### Scenario: The output node is named output

- **WHEN** the graph markup is rendered
- **THEN** the last node carries an output class and test id, and no class or test id on the graph names a sink

#### Scenario: Selecting does not move the canvas

- **WHEN** the operator selects a node or opens a tap
- **THEN** the canvas keeps the position and size it had before

#### Scenario: Controller is unreachable

- **WHEN** no controller node is connected
- **THEN** the graph region shows the same degraded state the hosting screen already uses for a disconnected controller, and no graph markup renders

### Requirement: Listeners are observers, not steps

The pipeline SHALL treat every binding whose provider is `Flezha.Plugin.Provider.MonitoredIOForward` as an observer of the relay, not as a plugin on its path. Observers SHALL NOT render as nodes, SHALL NOT affect the position of any node, and SHALL be grouped by plugin id, so one listener bound to several hooks counts once. An observer bound to `on_input` SHALL be counted on the IN port, one bound to `on_output` or `on_preview` on the OUT port, and one bound to `on_call` on the relay core. Each count SHALL list the observing plugin ids on hover and focus. While the operator's own tap is open on a port, that port SHALL say so, whatever its count. The graph header SHALL count distinct non-observer plugin ids, and SHALL state the number of observers separately when there are any.

#### Scenario: Opening a tap does not reshape the pipeline

- **WHEN** the operator opens a tap on the relay's input or output and the next tick reads a hook table holding its listener binding
- **THEN** the same nodes render at the same coordinates as before the tap opened
- **AND** the tapped port's observer count includes the listener

#### Scenario: An output listener counts once

- **WHEN** the hook table holds one `MonitoredIOForward` plugin bound to both `on_output` and `on_preview`
- **THEN** the OUT port counts one observer and no node renders for it

#### Scenario: Another caller's listen comes and goes

- **WHEN** a listener binding held by another caller appears in the hook table and is gone on a later tick
- **THEN** only the matching port's observer count changes between those ticks

#### Scenario: The header counts plugins

- **WHEN** a relay has one plugin bound to two hooks and one output listener
- **THEN** the header reads one plugin attached and one listening

### Requirement: Records are drawn as they pass

The graph SHALL show record movement from the controller's counters on every tick, whether or not a tap is open. On each tick, the advance of the relay's `io_in_received`, `forwarded` and `filtered_nil` counters, and of the relay class's parked dead-letter count, SHALL be replayed as that many flow dots spread across the following tick interval. A dot SHALL travel the route its counter names: input from Ingest to the core, forwarded from the core through the channel to Output, filtered from the core into the filtered sink, and parked from the core into the dead-letter sink. Counted dots SHALL be drawn hollow. While a tap is open, the records it hears SHALL instead be drawn as filled dots on the tapped side. While traffic is rare, a filled dot SHALL carry the start of its payload. The server SHALL send the browser one push per tick for counted records and at most one push per 250 milliseconds for tapped records. Each push SHALL carry counts and, for tapped records, payload previews of at most 40 characters. At most 24 dots SHALL be in flight at once, except that every dead letter SHALL be drawn. Records beyond that limit SHALL be left out of the animation but SHALL still be counted. No dot SHALL move when the viewer prefers reduced motion. Dots SHALL use the stylebook's flow-dot recipe and SHALL survive the graph's own re-renders.

#### Scenario: A rare record is seen without a tap

- **WHEN** no tap is open and the relay's `io_in_received` and `forwarded` counters each advance by one between two ticks
- **THEN** one hollow dot travels from Ingest to the core during the next tick interval, and one from the core to Output

#### Scenario: Tapped records are the real ones

- **WHEN** the output tap is open and a record passes
- **THEN** a filled dot carrying the start of its payload travels from the core to Output

#### Scenario: Filtered and parked records go where they went

- **WHEN** a tick shows `filtered_nil` advanced by two and the parked count by one
- **THEN** two dots travel into the filtered sink and one failure-styled dot into the dead-letter sink
- **AND** both sinks update their counts

#### Scenario: A dead letter inside a stream is still drawn

- **WHEN** a wire carries a stream and one record is parked during that tick
- **THEN** that dead letter is drawn as its own dot

#### Scenario: A burst is capped

- **WHEN** a tick shows a hundred records forwarded on a wire that is not yet streaming
- **THEN** no more than 24 dots are in flight on the graph
- **AND** the figures show all hundred

#### Scenario: Reduced motion

- **WHEN** the viewer's browser prefers reduced motion
- **THEN** no dot moves, the wires still light on arrival, and every figure still advances

#### Scenario: A tick re-renders mid-flight

- **WHEN** the refresh tick re-renders the graph while dots are travelling
- **THEN** those dots continue to their destinations

### Requirement: A stream and a trickle read differently

Each counted wire SHALL be in one of three states, decided from its displayed rate with hysteresis. A wire SHALL be **streaming** from 5 records a second until it falls to 3. It SHALL be **trickling** below that while a record has passed in the last 30 seconds, and **quiet** otherwise. A streaming wire SHALL be drawn as a moving band whose width grows with the logarithm of its rate, and it SHALL draw no per-record dots except dead letters. A trickling wire SHALL draw one dot per record. Every wire a record crosses SHALL stay lit and fade over about six seconds, so a single record remains visible after it has passed. A quiet wire SHALL be static. Its port SHALL say how long the wire has been quiet. When the channel reports backpressure, the band out of the core SHALL stop moving and SHALL turn to the warning colour. No count of waiting records SHALL be shown, because the controller reports none.

#### Scenario: A busy relay streams

- **WHEN** the IN port's displayed rate reaches 5 records a second
- **THEN** the wire is drawn as a moving band and per-record dots stop on it

#### Scenario: Hysteresis

- **WHEN** a streaming wire's rate falls to 4 records a second
- **THEN** it stays streaming until its rate falls to 3

#### Scenario: A single record leaves a trace

- **WHEN** one record passes a trickling relay
- **THEN** each wire on its route lights as the dot crosses it, and the light fades over about six seconds

#### Scenario: A relay goes quiet

- **WHEN** no counter has advanced for more than 30 seconds
- **THEN** the wires are static and unlit, and the IN port states how long it has been quiet

#### Scenario: The runner is full

- **WHEN** the channel reports credit active with an exhausted ledger
- **THEN** the band out of the core stops moving in the warning colour, and the channel shows its backpressure indicator

### Requirement: The graph says what is happening

Below the canvas the graph SHALL state the relay's flow in one plain sentence led by a state word. The state word SHALL be **Stuck** when the channel reports backpressure. Failing the Stuck rule, it SHALL be **Failing** when more than a tenth of the records taken in the last two ticks were parked. Failing both, it SHALL be **Streaming**, **Trickle** or **Quiet** after the IN port's state. Beneath the sentence a timeline SHALL show, per tick over a history retained in memory for the session of at most 60 samples, how many records came in, were delivered, were filtered and were parked, each on its own row. Hovering or focusing a node, wire or port SHALL highlight every element on the routes through it and dim the rest. The highlighted path SHALL be shown together with a tooltip that names what passes there, its rate, and when a record last passed. A wire the controller does not count SHALL say so.

#### Scenario: The sentence follows the flow

- **WHEN** the relay is streaming at about 120 records a second with a tenth of them filtered
- **THEN** the sentence reads Streaming and states the in rate, the delivered rate and the filtered share

#### Scenario: Failing outranks streaming

- **WHEN** a streaming relay parks more than a tenth of what it took over the last two ticks
- **THEN** the state word reads Failing

#### Scenario: The timeline shows when

- **WHEN** a batch of thirty records passed forty seconds ago and nothing since
- **THEN** the timeline shows bars at that point on the In and Delivered rows and nothing after them

#### Scenario: Tracing a dead letter's path

- **WHEN** the operator hovers the dead-letter sink
- **THEN** Ingest, the input steps, the core, the dead-letter wire and the sink are highlighted and the output route is dimmed

#### Scenario: An uncounted wire says so

- **WHEN** the operator hovers the wire between two plugins
- **THEN** the tooltip states that the controller keeps no counter there

### Requirement: The graph is driven from the keyboard

Every selectable node and every port SHALL take keyboard focus and carry an accessible name. Enter SHALL select a focused node or open the tap on a focused port. The arrow keys SHALL move focus left and right along the record lane and up and down between the lanes. Escape SHALL dismiss the selected node.

#### Scenario: Walking the record lane

- **WHEN** the IN port has focus and the operator presses the right arrow key repeatedly
- **THEN** focus moves along the record lane in path order

#### Scenario: Selecting from the keyboard

- **WHEN** the relay core has focus and the operator presses Enter
- **THEN** the inspector shows the core

#### Scenario: Tapping from the keyboard

- **WHEN** the OUT port has focus and the operator presses Enter
- **THEN** the output tap opens

#### Scenario: Dismissing from the keyboard

- **WHEN** a node is selected and the operator presses Escape
- **THEN** the selection clears

