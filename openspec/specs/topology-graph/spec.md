# topology-graph Specification

## Purpose
The live picture of the flezha data plane: one operative's pipeline — what is
attached to it, in what order, what is flowing through it and what is stuck —
plus a namespace-level summary whose cost does not grow with the size of the
fleet.

## Requirements
### Requirement: Operative pipeline graph

The system SHALL render, on an operative's page, a graph of the path a record takes through that operative: a transport ingest node, the operative's `on_input` plugins in position order, the operative core, its `on_output` plugins in position order, the bound runner's stream channel, and an output sink. Pipeline structure SHALL come from the operative's overwatch extension table, so the graph shows the plugins that are actually attached in the order the controller runs them. Extension points that do not sit on the record path SHALL render as satellites of the core rather than as steps in the chain.

#### Scenario: Operative with attached plugins

- **WHEN** an operator opens an operative whose extension table names an `on_input` plugin and an `on_output` plugin
- **THEN** the graph renders ingest, that input plugin, the core, that output plugin, the channel, and output as one chain, each plugin node naming its plugin id and provider

#### Scenario: Ordering follows position

- **WHEN** an operative has two `on_output` plugins at positions 0 and 1
- **THEN** they render in that order between the core and the channel

#### Scenario: Off-path extension

- **WHEN** an operative has a plugin subscribed to `on_interval`
- **THEN** it renders as a satellite attached to the core, not as a step on the record path

#### Scenario: Operative with no plugins

- **WHEN** an operative has nothing attached
- **THEN** the chain still renders ingest, core, channel and output, and states that no plugins are attached

#### Scenario: Operative is not bound to a runner

- **WHEN** an operative's overwatch state names no runner
- **THEN** the channel node renders as unbound and the edge into it renders degraded

#### Scenario: Controller is unreachable

- **WHEN** no controller node is connected
- **THEN** the graph region shows the same degraded state the hosting screen already uses for a disconnected controller, and no graph markup renders

### Requirement: Flow rates where the controller counts them

The system SHALL compute message rates as the difference between successive data-plane liveness snapshots divided by the elapsed time between them, measured on the UI's monotonic clock. Negative differences SHALL clamp to zero. Rates SHALL be displayed only on edges the controller actually counts — into the operative (`io_in_received`), out of the operative (`forwarded`), and out of the channel (`send_frame_calls`) — and edges between plugins SHALL carry no rate figure. Edges SHALL animate at a speed bucket derived from their rate; edges at zero rate SHALL render static and their figures SHALL be visually subdued.

#### Scenario: Rates appear after two snapshots

- **WHEN** the graph has received two consecutive snapshots where the operative's counts advanced
- **THEN** its ingest and output edges each display a messages-per-second rate derived from the count delta and elapsed time, and carry an animation class for the matching speed bucket

#### Scenario: First snapshot has no baseline

- **WHEN** the graph renders from its first snapshot
- **THEN** edges display no rate figure and no flow animation

#### Scenario: Controller restart resets counters

- **WHEN** a snapshot reports counts lower than the previous snapshot's
- **THEN** the affected rates display as zero for that tick and recover on the following tick

#### Scenario: No rate is invented between plugins

- **WHEN** the pipeline renders a chain of plugins
- **THEN** the edges between plugin nodes carry no messages-per-second figure, because the controller keeps no per-extension counter

#### Scenario: Liveness surface is missing on the controller

- **WHEN** the snapshot call reports the controller does not export the liveness module
- **THEN** the graph still renders structure and states from the remaining sources, with the screen's standard version-skew notice and no rate figures

### Requirement: On-demand payload tap

The system SHALL let an operator tap the operative's input or output and watch live payloads. A tap SHALL attach the controller's existing monitored-I/O listener through the shared reference-counted stream bridge, SHALL report the messages per second and bytes per second measured over the tap's own window along with the most recent payloads, and SHALL detach when the operator closes it or leaves the page. Byte figures SHALL be measured from the raw payload before it is rendered printable.

#### Scenario: Tapping the output

- **WHEN** the operator taps the operative's output and messages flow
- **THEN** the panel reports a message count, a total size, a messages-per-second and a bytes-per-second figure measured since the tap opened, and shows the most recent payloads

#### Scenario: Closing a tap detaches it

- **WHEN** the operator closes an open tap
- **THEN** the listener is detached from the controller and the panel stops reporting

#### Scenario: Leaving the page detaches it

- **WHEN** the operator navigates away with a tap open
- **THEN** the listener is detached without the operator doing anything

#### Scenario: The controller refuses the tap

- **WHEN** attaching the listener fails
- **THEN** the panel reports that the tap could not be attached and the rest of the graph renders unaffected

### Requirement: Realtime updates without operator action

The graph and the summary SHALL refresh their snapshot-derived data on a periodic tick of at most 2 seconds while mounted, and SHALL apply relayed runner lifecycle events to runner and channel state as they arrive, without waiting for the next tick.

#### Scenario: Tick refreshes rates

- **WHEN** the graph is mounted and the refresh tick fires
- **THEN** a new liveness snapshot is fetched and edge rates, node states and counts re-render without any operator action

#### Scenario: Runner disconnect arrives between ticks

- **WHEN** a relayed runner-disconnected event arrives before the next tick
- **THEN** the channel node re-renders as degraded immediately

### Requirement: Backpressure and stall surfacing

The system SHALL surface channel credit state — a backpressure indicator when the operative's channel reports credit active with an exhausted ledger — and SHALL query recent observability signals for data-plane stall verdicts each tick, rendering verdicts younger than 60 seconds as a banner naming the stalled layer and affected entity. Verdict age SHALL be measured against the controller's own clock, since the controller stamps those signals with its monotonic time.

#### Scenario: Channel exhausts credit

- **WHEN** a snapshot shows the operative's channel with `credit_active` set and `credit_ledger_level` at zero
- **THEN** the channel node renders a backpressure indicator and its detail lists the channel's credit figures

#### Scenario: Stall verdict is recent

- **WHEN** the observability query returns a `stall_localized` event younger than 60 seconds naming a layer and entity
- **THEN** a banner renders naming both

#### Scenario: Stall verdict is stale

- **WHEN** the newest `stall_localized` event is older than 60 seconds
- **THEN** no banner renders

#### Scenario: Observability is unavailable

- **WHEN** the observability query returns any error, including the subsystem being disabled
- **THEN** the graph renders normally with no stall banner and no error notice

### Requirement: Node detail and legend

The system SHALL show a detail panel for a selected node — for the core, its raw monotonic counters, current rates, a rate sparkline retained in memory for the session at most 60 samples, factory, runner, kind and uptime; for the channel, its per-channel counters, credit state and heartbeat figures; for a plugin, its plugin id, provider, extension point and position. Selecting another node SHALL replace the panel and dismissing it SHALL clear the selection. The system SHALL render a legend naming every line style and node state used on the graph.

#### Scenario: Selecting the core

- **WHEN** the operator clicks the operative core node
- **THEN** the detail panel shows its counters, rates, rate sparkline, factory, runner, kind and uptime

#### Scenario: Selecting a plugin

- **WHEN** the operator clicks a plugin node
- **THEN** the detail panel names that plugin's id, provider, extension point and position

#### Scenario: Legend is present

- **WHEN** the graph renders
- **THEN** a legend names what each line style and node state means

#### Scenario: Dismissing the panel

- **WHEN** the operator closes the detail panel
- **THEN** the selection clears and no panel renders

### Requirement: Fleet summary at fixed cost

The system SHALL render, on the dashboard and on a namespace page, a summary of the namespace's data plane: operative and runner counts, runners whose channels report backpressure, dead-letter pressure, recent stall verdicts, and the busiest operatives by measured throughput. The summary SHALL be assembled from a number of controller calls that does not grow with the number of operatives, and each listed operative SHALL link to its pipeline graph.

#### Scenario: Dashboard summarises the selected namespace

- **WHEN** an operator opens the dashboard while namespaces exist
- **THEN** the summary renders for the namespace named by `?ns=`, or the first namespace in sorted order when the parameter is absent, and changing the selector updates both the summary and the query parameter

#### Scenario: Namespace page summarises its own namespace

- **WHEN** an operator opens a namespace's show page
- **THEN** the same summary renders scoped to that namespace, without a namespace selector

#### Scenario: Busiest operatives are ranked and linked

- **WHEN** two snapshots have been taken and several operatives have advanced their counters
- **THEN** the summary lists the operatives with the highest measured throughput, each linking to its own pipeline graph

#### Scenario: Summary cost does not grow with the fleet

- **WHEN** the summary is assembled for a namespace
- **THEN** it issues no per-operative controller call

#### Scenario: Namespace has nothing running

- **WHEN** the selected namespace has no operatives and no runners
- **THEN** the summary shows an empty state naming the namespace

#### Scenario: Controller is unreachable

- **WHEN** no controller node is connected
- **THEN** the summary shows the degraded state the hosting screen already uses for a disconnected controller

### Requirement: Click-through navigation

Every entity on the graph SHALL link to the screen that owns it: the operative core to that operative's stream view, the channel to the cluster page, the dead-letter branch to the DLQ page, and a plugin to the operative's plugin bindings.

#### Scenario: Channel click-through

- **WHEN** the operator activates the channel node's navigate action
- **THEN** the browser navigates to the cluster page

#### Scenario: Dead-letter click-through

- **WHEN** the operator activates the dead-letter node
- **THEN** the browser navigates to the DLQ page
