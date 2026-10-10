# topology-graph Specification

## Purpose
The live picture of the flezha data plane: one relay's pipeline — what is
attached to it, in what order, what is flowing through it and what is stuck —
plus a namespace-level summary whose cost does not grow with the size of the
fleet.
## Requirements
### Requirement: Flow rates where the controller counts them

The system SHALL compute message rates as the difference between successive data-plane liveness snapshots, read from `Flezha.Service.Controller.liveness_counters/1`, divided by the elapsed time between them, measured on the UI's monotonic clock. A relay's counters SHALL be read from the snapshot's `relays` list, keyed by `relay_id`. Negative differences SHALL clamp to zero. Rates SHALL be displayed only on edges the controller actually counts — into the relay (`io_in_received`), out of the relay (`forwarded`), and out of the channel (`send_frame_calls`) — and edges between plugins SHALL carry no rate figure. Edges SHALL animate at a speed bucket derived from their rate; edges at zero rate SHALL render static and their figures SHALL be visually subdued.

#### Scenario: Rates appear after two snapshots

- **WHEN** the graph has received two consecutive snapshots where the relay's counts advanced
- **THEN** its ingest and output edges each display a messages-per-second rate derived from the count delta and elapsed time, and carry an animation class for the matching speed bucket

#### Scenario: Counters are found by relay id

- **WHEN** a snapshot's `relays` list holds an entry whose `relay_id` is the relay on display
- **THEN** that entry's counters are the ones the rates are computed from

#### Scenario: First snapshot has no baseline

- **WHEN** the graph renders from its first snapshot
- **THEN** edges display no rate figure and no flow animation

#### Scenario: Controller restart resets counters

- **WHEN** a snapshot reports counts lower than the previous snapshot's
- **THEN** the affected rates display as zero for that tick and recover on the following tick

#### Scenario: No rate is invented between plugins

- **WHEN** the pipeline renders a chain of plugins
- **THEN** the edges between plugin nodes carry no messages-per-second figure, because the controller keeps no per-hook counter

#### Scenario: Liveness counters cannot be read

- **WHEN** the snapshot call fails, is refused, or the controller does not export `Flezha.Service.Controller.liveness_counters/1`
- **THEN** the graph still renders structure and states from the remaining sources, with the screen's standard error notice and no rate figures

### Requirement: On-demand payload tap

The system SHALL let an operator tap the relay's input or output and watch live payloads. A tap SHALL listen through `Flezha.Service.Relay.listen/5` with direction `input` or `output`, held by an `EventFeed` linked to the page, and SHALL run no code of this application on the controller. It SHALL report the messages per second and bytes per second measured over the tap's own window along with the most recent payloads, and SHALL stop listening when the operator closes it or leaves the page. Byte figures SHALL be measured from the raw payload before it is rendered printable.

#### Scenario: Tapping the output

- **WHEN** the operator taps the relay's output and messages flow
- **THEN** the panel reports a message count, a total size, a messages-per-second and a bytes-per-second figure measured since the tap opened, and shows the most recent payloads

#### Scenario: Closing a tap stops the listen

- **WHEN** the operator closes an open tap
- **THEN** the listen on the controller ends and the panel stops reporting

#### Scenario: Leaving the page stops the listen

- **WHEN** the operator navigates away with a tap open
- **THEN** the listen ends without the operator doing anything

#### Scenario: The controller refuses the tap

- **WHEN** `listen/5` answers `{:error, %Flezha.Error{}}`
- **THEN** the panel reports that the tap could not be opened, with the error's code and message, and the rest of the graph renders unaffected

### Requirement: Realtime updates without operator action

The graph and the summary SHALL refresh their snapshot-derived data on a periodic tick of at most 2 seconds while mounted, and SHALL apply runner session events forwarded by the event feed to runner and channel state as they arrive, without waiting for the next tick.

#### Scenario: Tick refreshes rates

- **WHEN** the graph is mounted and the refresh tick fires
- **THEN** a new liveness snapshot is fetched and edge rates, node states and counts re-render without any operator action

#### Scenario: Runner disconnect arrives between ticks

- **WHEN** a runner-disconnected event arrives before the next tick
- **THEN** the channel node re-renders as degraded immediately

### Requirement: Backpressure and stall surfacing

The system SHALL surface channel credit state — a backpressure indicator when the relay's channel reports credit active with an exhausted ledger — and SHALL query recent observability signals for data-plane stall verdicts each tick, rendering verdicts younger than 60 seconds as a banner naming the stalled layer and the affected relay, runner or channel. Verdict age SHALL be measured against the controller's own clock, since the controller stamps those signals with its monotonic time. When the observability query is refused, the graph SHALL state that stall detection is unavailable and why, rather than rendering as though no stall exists.

#### Scenario: Channel exhausts credit

- **WHEN** a snapshot shows the relay's channel with `credit_active` set and `credit_ledger_level` at zero
- **THEN** the channel node renders a backpressure indicator and its detail lists the channel's credit figures

#### Scenario: Stall verdict is recent

- **WHEN** the observability query returns a `stall_localized` event younger than 60 seconds naming a layer and a `relay_id`, `runner_id` or channel
- **THEN** a banner renders naming the layer and that relay, runner or channel

#### Scenario: Stall verdict is stale

- **WHEN** the newest `stall_localized` event is older than 60 seconds
- **THEN** no banner renders

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

The system SHALL show a detail panel for a selected node — for the core, its raw monotonic counters, current rates, a rate sparkline retained in memory for the session at most 60 samples, factory, runner, run (`flow` or `steps`, from the relay's builder) and uptime; for the channel, its per-channel counters, credit state and heartbeat figures; for a plugin, its plugin id, provider, hook and position. Selecting another node SHALL replace the panel and dismissing it SHALL clear the selection. The system SHALL render a legend naming every line style and node state used on the graph. Nodes, wires and the legend SHALL be drawn with the stylebook's relay-graph recipe, so a plugin, the relay core, the runner's channel, a degraded wire and a dead or suspended node look as they do on flezha.com. The detail panel SHALL be a stylebook panel.

#### Scenario: Selecting the core

- **WHEN** the operator clicks the relay core node
- **THEN** the detail panel shows its counters, rates, rate sparkline, factory, runner, run and uptime

#### Scenario: Selecting a plugin

- **WHEN** the operator clicks a plugin node
- **THEN** the detail panel names that plugin's id, provider, hook and position

#### Scenario: Legend is present

- **WHEN** the graph renders
- **THEN** a legend names what each line style and node state means

#### Scenario: Dismissing the panel

- **WHEN** the operator closes the detail panel
- **THEN** the selection clears and no panel renders

#### Scenario: The graph speaks the shared vocabulary

- **WHEN** the graph markup is rendered
- **THEN** its plugin nodes carry the stylebook's plugin role, the core the tasklet role, the channel the runner role, a degraded edge the failed-wire style and a disconnected node the dead state
- **AND** the flow animation still carries its `topo-flow-*` speed bucket class

#### Scenario: A dead-letter branch is not a failure

- **WHEN** a relay has a dead-letter branch and nothing is degraded
- **THEN** the branch is drawn as a dotted amber wire, not in the failed-wire style, and the legend names it apart from a wire with nothing bound at its far end

#### Scenario: The legend names node states

- **WHEN** the graph renders
- **THEN** its legend shows the plugin, relay-code, runner-channel and record-end roles and the suspended and unbound states, each drawn as the graph draws it

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

The system SHALL render, on a relay's page, a graph of the path a record takes through that relay: a transport ingest node, the relay's `on_input` plugins in position order, the relay core, its `on_output` plugins in position order, the bound runner's channel, and the relay's output. Pipeline structure SHALL come from the relay's overwatch state, read through `Flezha.Service.Relay.overwatch_state/3`, and its table of bound hooks, so the graph shows the plugins that are actually bound in the order the controller runs them. Hooks that do not sit on the record path SHALL render as satellites of the core rather than as steps in the chain. The last node of the chain SHALL be presented as the relay's output in markup, class names and test ids, not as a sink.

#### Scenario: Relay with bound plugins

- **WHEN** an operator opens a relay whose hook table names an `on_input` plugin and an `on_output` plugin
- **THEN** the graph renders ingest, that input plugin, the core, that output plugin, the channel, and output as one chain, each plugin node naming its plugin id and provider

#### Scenario: Ordering follows position

- **WHEN** a relay has two `on_output` plugins at positions 0 and 1
- **THEN** they render in that order between the core and the channel

#### Scenario: Off-path hook

- **WHEN** a relay has a plugin bound on the `on_interval` hook
- **THEN** it renders as a satellite attached to the core, not as a step on the record path

#### Scenario: Relay with no plugins

- **WHEN** a relay has nothing bound
- **THEN** the chain still renders ingest, core, channel and output, and states that no plugins are bound

#### Scenario: Relay is not bound to a runner

- **WHEN** a relay's overwatch state names no runner
- **THEN** the channel node renders as unbound and the edge into it renders degraded

#### Scenario: The output node is named output

- **WHEN** the graph markup is rendered
- **THEN** the last node carries an output class and test id, and no class or test id on the graph names a sink

#### Scenario: Controller is unreachable

- **WHEN** no controller node is connected
- **THEN** the graph region shows the same degraded state the hosting screen already uses for a disconnected controller, and no graph markup renders

