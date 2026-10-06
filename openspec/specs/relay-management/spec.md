# relay-management Specification

## Purpose
How an operator finds, starts, inspects and stops relays: the namespace overview,
the per-namespace and cross-namespace relay listings with every health verdict the
controller answers, partition groups and their coverage, a relay's detail and cell
state, and listening to its inputs and outputs.
## Requirements
### Requirement: Namespace overview

The UI SHALL list every namespace the bound token can see, from `Flezha.Service.Relay.list_namespaces/1`, with whether a hub runs for it, its relay count, and its active runner count, and link each to its detail screen.

#### Scenario: Namespaces exist

- **WHEN** an operator opens the namespaces screen and the controller reports namespaces
- **THEN** each namespace is listed with its relay count and runner count

#### Scenario: A namespace runs no hub yet

- **WHEN** a namespace is in the controller's catalog but no hub runs for it
- **THEN** it is listed with zero relays and zero runners rather than omitted

#### Scenario: No namespaces exist

- **WHEN** the controller reports no namespaces
- **THEN** an empty state explains that no namespace has been created

### Requirement: Partition groups and their coverage

A namespace holding partition group members SHALL present them as one group row per group, as `Flezha.Service.Relay.list/2` answers it, showing the member count against the declared partition count and the group's health as its sickest member's. Each group's key-group coverage SHALL be read from `Flezha.Service.Relay.partition_groups/2`. A group whose coverage has gaps or overlaps SHALL be marked as faulted, and the gaps and overlapping owners SHALL be named.

#### Scenario: A complete group

- **WHEN** a group's members cover every key group exactly once
- **THEN** the group row shows its member count against its declared count and is not marked faulted

#### Scenario: A group with a coverage gap

- **WHEN** a key group has no owner
- **THEN** the group is marked faulted and the uncovered key range is named

#### Scenario: A group with overlapping owners

- **WHEN** a key group has more than one owner
- **THEN** the group is marked faulted and the competing owners are named

#### Scenario: Group health is the sickest member's

- **WHEN** one member of a group is degraded and the rest are healthy
- **THEN** the group row reports degraded, as the controller ranked it

#### Scenario: Members are reachable

- **WHEN** an operator expands a group row
- **THEN** each member is listed with its partition index, key-group range, runner, and health

### Requirement: The registered factory catalog

The UI SHALL read a namespace's registered factories together with the runners serving each, through one `FlezhaUi.Service.NodeManager` function used by every screen that names a factory, backed by `Flezha.Service.Fleet.factories/2` and `Flezha.Service.Fleet.runners_for_factory/3`. A factory SHALL be presented with its description, its run (`flow` or `steps`), and whether any runner currently serves it. The catalog SHALL be read when a form that needs it is opened and when its namespace changes, and SHALL NOT be read on a screen's refresh tick.

#### Scenario: Factories are registered and served

- **WHEN** an operator opens a form offering factories in a namespace whose runners have registered them
- **THEN** each factory id is offered with its description and run
- **AND** the runners serving it are reported

#### Scenario: A registered factory has no runner

- **WHEN** a factory is registered in the namespace but no runner currently serves it
- **THEN** it is offered and marked as served by no runner

#### Scenario: The namespace has no factories

- **WHEN** no runner has registered a factory in the namespace
- **THEN** the factory selector says so rather than offering an empty list
- **AND** the form cannot be submitted

#### Scenario: The catalog cannot be read

- **WHEN** the controller refuses or cannot answer the factory listing
- **THEN** the form reports that factories could not be read
- **AND** the operator may still type a factory id

#### Scenario: One read serves every screen

- **WHEN** the cluster screen, the namespace screen, and the schedule form each need a namespace's factories
- **THEN** all three obtain them from the same `NodeManager` function

### Requirement: Relay listing within a namespace

The namespace detail screen SHALL list the namespace's relays, its available factories, and its active runners. Each relay row SHALL carry the health the Convergence Loop classified, the node it is placed on, its factory, its run, and its bound runner, read from `Flezha.Service.Relay.list/2`. The screen SHALL render every health verdict the controller answers — `healthy`, `degraded`, `recovering`, `unbound`, `failed`, `parked`, `suspended`, and `unknown` — each distinctly. A relay the loop has not yet observed SHALL be shown as `unknown` and SHALL NOT be reported as healthy. Runners SHALL be read from `Flezha.Service.Fleet.runners/2`, which covers the whole cluster.

#### Scenario: Namespace has relays

- **WHEN** an operator opens a namespace that has running relays
- **THEN** each relay id is listed with its health, node, factory, run, and runner
- **AND** the id links to its detail screen

#### Scenario: A relay is unhealthy

- **WHEN** a relay's health is `degraded`, `unbound`, `failed`, or `parked`
- **THEN** the row states that health distinctly from a healthy row

#### Scenario: A relay is recovering

- **WHEN** the controller reports a relay as `recovering` while it moves it off a runner that went away
- **THEN** the row reads `recovering`, distinctly from `failed` and from `healthy`

#### Scenario: A relay has not yet been classified

- **WHEN** a row has no health from the Convergence Loop
- **THEN** the row reads `unknown`

#### Scenario: A relay is unplaced

- **WHEN** a row has no live node
- **THEN** the row states that it is unplaced

#### Scenario: Runners on other controllers are listed

- **WHEN** a runner serving the namespace is connected to another controller node of the cluster
- **THEN** it is listed among the namespace's active runners

#### Scenario: Namespace has registered factories

- **WHEN** runners in the namespace have registered factories
- **THEN** each factory id is listed and is selectable when starting a relay

### Requirement: Relay lifecycle

An operator SHALL be able to start a relay by supplying a namespace, a factory id, an optional id, and init values, and SHALL be able to stop a running relay. Stopping SHALL require an explicit confirmation step. The start form SHALL be reachable from both a namespace's detail screen and the cross-namespace relays index, and SHALL be one implementation rendered by both. The start SHALL go through `Flezha.Service.Relay.start/3` and SHALL NOT ask for or send how the relay runs: the run is the factory's, and the form SHALL show the chosen factory's run read-only. A stop SHALL go through `Flezha.Service.Relay.stop/3`.

#### Scenario: Starting a relay succeeds

- **WHEN** an operator submits a factory id, an optional id, and valid init values
- **THEN** the relay is started via `Service.Relay.start/3` without a run
- **AND** it appears in the namespace's relay list under the id the controller answered

#### Scenario: Starting without an id

- **WHEN** an operator leaves the id empty
- **THEN** the controller generates one
- **AND** the form reports the generated id and links to the relay

#### Scenario: Starting an id that is already running

- **WHEN** the controller answers the start with `outcome: :already_running`
- **THEN** the form states that a relay with that id is already running and links to it
- **AND** this is not reported as a new start

#### Scenario: Starting a relay is rejected by the controller

- **WHEN** the controller refuses the start, for example an unknown factory or a reached quota
- **THEN** the controller's error message is displayed on the form
- **AND** no relay is created

#### Scenario: Starting from the relays index

- **WHEN** an operator opens the start form from the relays index
- **THEN** the form offers a namespace to start into, chosen from the namespaces the bound token can reach
- **AND** a successful start adds the relay to the index

#### Scenario: Starting from a namespace screen

- **WHEN** an operator opens the start form from a namespace's detail screen
- **THEN** the namespace is that screen's namespace and is not asked for again

#### Scenario: The factory's run is shown, not chosen

- **WHEN** an operator chooses a factory on the start form
- **THEN** the form shows whether that factory runs as `flow` or `steps`, as its runners announced it
- **AND** no control offers to change it

#### Scenario: A steps relay is started

- **WHEN** an operator starts a relay from a factory whose run is `steps`
- **THEN** the relays index reports its run as `steps`

#### Scenario: The form is incomplete

- **WHEN** an operator submits with an empty factory, or init values that are not valid JSON
- **THEN** the form says which field is wrong
- **AND** no start call is made

#### Scenario: Stopping a relay

- **WHEN** an operator confirms stopping a relay
- **THEN** `Service.Relay.stop/3` is called
- **AND** the operator is returned to the namespace screen with the relay absent from the list

#### Scenario: A steps relay stops cooperatively

- **WHEN** the controller answers a stop with `stopped: :cooperative`
- **THEN** the UI states that the relay finishes its in-flight work before it is removed
- **AND** the relay is not reported as already gone while it is still listed

#### Scenario: Stop is not confirmed

- **WHEN** an operator opens the stop confirmation and dismisses it
- **THEN** no stop call is made

### Requirement: Relay introspection

The relay detail screen SHALL display, from the overwatch state, the relay's factory id, bound runner id, run, uptime, suspended flag, effectively-once tier, and the plugins bound to it. It SHALL additionally display the health and node the namespace's rows report for it, and — for a steps relay — the steps panel defined by the `steps-operations` capability. The screen SHALL present its Detail, Listen, and State routes as a tab strip on the relay, and SHALL render its task journal, input log, SDK state, and plugin panels as sections that collapse.

#### Scenario: Relay is running and bound

- **WHEN** an operator opens a running relay
- **THEN** its factory id, runner id, run, uptime, health, and node are displayed

#### Scenario: Relay is suspended

- **WHEN** the overwatch state reports `suspended: true`
- **THEN** the screen marks the relay as suspended

#### Scenario: Relay is a partition member

- **WHEN** the relay carries a partition identity
- **THEN** its partition index, key-group range, and its group are shown
- **AND** the group links to the namespace's group row

#### Scenario: The three views are tabs

- **WHEN** an operator opens a relay
- **THEN** Detail, Listen, and State are presented as tabs on that relay
- **AND** reaching Listen or State does not require finding a link inside a panel

#### Scenario: The lower panels start collapsed

- **WHEN** an operator opens a relay for the first time
- **THEN** the pipeline graph and the relay's facts are visible without scrolling
- **AND** the task journal, input log, SDK state, and plugin sections are collapsed

#### Scenario: Relay is not found

- **WHEN** the requested relay does not exist in the namespace
- **THEN** a not-found message is shown instead of an error page

### Requirement: Cell state reads

The UI SHALL read a relay's live cell state through `Flezha.Service.Relay.cell_state/4`, with a selector naming no cell (every cell), a tasklet (`"<tasklet>"`), or one cell (`"<tasklet>/<cell_key>"`), and SHALL display the change sequence the controller answers with the state.

#### Scenario: Reading the whole relay's state

- **WHEN** an operator requests state with no selector
- **THEN** the full JSON state for every tasklet is displayed

#### Scenario: Reading a single cell

- **WHEN** an operator supplies a tasklet name and a cell key
- **THEN** the selector `"<tasklet>/<cell_key>"` is sent and only that cell's state is displayed
- **AND** the change sequence it was read at is shown

#### Scenario: A cell key without a tasklet

- **WHEN** an operator supplies a cell key but no tasklet
- **THEN** the form says a tasklet is needed, because a cell key is unique only within its tasklet
- **AND** no read is made

#### Scenario: The relay keeps no state

- **WHEN** the controller answers an error with code `state.persistence_off`
- **THEN** the screen explains that this relay declares persistence off and keeps no cell state
- **AND** this is presented as an explanation, not as a failure

#### Scenario: Cells are not held in memory

- **WHEN** the controller answers an error with code `state.not_resident`
- **THEN** the error's message is displayed and the operator is told the relay's cells are not held in memory

### Requirement: Listening to a relay's inputs and outputs

An operator SHALL be able to listen to a running relay's inputs or outputs. The UI SHALL listen through `Flezha.Service.Relay.listen/5` with the direction `:input` or `:output`, and SHALL NOT compile, load, or ship any code to the controller to receive what it hears. Each open listen screen SHALL hold its own listen, held by an `EventFeed` linked to the screen, and the listen SHALL end when that screen closes or switches direction.

#### Scenario: Listening to outputs

- **WHEN** an operator opens the listen screen for outputs
- **THEN** a listen is started with direction `:output`
- **AND** outputs, their parts, and dead-letter notices appear in the viewer as the relay produces them

#### Scenario: Listening to inputs

- **WHEN** an operator opens the listen screen for inputs
- **THEN** a listen is started with direction `:input`
- **AND** inputs appear in the viewer as the relay ingests them

#### Scenario: The viewer leaves

- **WHEN** the LiveView listening to a relay disconnects
- **THEN** its listen ends and the controller detaches its listener

#### Scenario: Switching direction

- **WHEN** an operator switches the listen screen from outputs to inputs
- **THEN** the listen on outputs ends before the listen on inputs starts

#### Scenario: The relay ends while listened to

- **WHEN** the relay ends during a listen
- **THEN** the viewer states that the relay ended and the listen is over

### Requirement: A cross-namespace relays index

The UI SHALL provide a **Fleet** screen at `/relays` listing every relay across every namespace the bound token can reach, showing relay id, namespace, factory, health, run, node, runner, and plugin count, with the id linking to the relay's detail screen. The listing SHALL cost one `Service.Relay.list/2`, one `Service.Relay.relay_plugins/2`, and one `Service.Relay.registry/2` call per namespace, not one call per relay. The same LiveView SHALL additionally serve a namespace-scoped listing at `/namespaces/:ns/relays`, taking its namespace from the path rather than from the filter form. The screen's filters SHALL be written back to the query string, so a filtered view can be bookmarked, shared, and reversed with the browser's back button.

#### Scenario: Relays exist across namespaces

- **WHEN** an operator opens the Fleet screen
- **THEN** every relay in every reachable namespace is listed with its namespace and health

#### Scenario: Filtering the index

- **WHEN** an operator filters by namespace, health, or run
- **THEN** only matching relays are listed

#### Scenario: Every health verdict can be filtered on

- **WHEN** an operator opens the health filter
- **THEN** it offers every verdict the controller answers, including `recovering` and `parked`

#### Scenario: A filtered view is a shareable URL

- **WHEN** an operator filters the Fleet screen by health
- **THEN** the query string carries that filter
- **AND** reloading the page reproduces the same filtered listing

#### Scenario: Backing out of a filter

- **WHEN** an operator applies a filter and presses the browser's back button
- **THEN** the previous filter state is restored

#### Scenario: The index is reachable from the navigation

- **WHEN** an operator looks at the sidebar
- **THEN** a Fleet entry sits in the `PLATFORM` section

#### Scenario: A namespace's own relays

- **WHEN** an operator opens `/namespaces/:ns/relays`
- **THEN** only that namespace's relays are listed
- **AND** the namespace is presented as the screen's scope rather than as a clearable filter

#### Scenario: One LiveView serves both routes

- **WHEN** the codebase is inspected
- **THEN** `/relays` and `/namespaces/:ns/relays` are served by the same LiveView module

#### Scenario: No relays are running

- **WHEN** no namespace holds a relay
- **THEN** an empty state says so rather than rendering an empty table

