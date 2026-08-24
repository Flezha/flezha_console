# operative-management Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Namespace overview

The UI SHALL list every running namespace with its operative count and active runner count, and link each to its detail screen.

#### Scenario: Namespaces exist

- **WHEN** an operator opens the namespaces screen and the controller reports running namespaces
- **THEN** each namespace is listed with its operative count and runner count

#### Scenario: No namespaces are running

- **WHEN** the controller reports no running namespaces
- **THEN** an empty state explains that no namespace has been started

### Requirement: Operative listing within a namespace

The namespace detail screen SHALL list the namespace's operatives, its available factories, and its active runners. Each operative row SHALL carry the health the Convergence Loop classified, the node it is placed on, its factory, and its bound runner, read from `Flezha.Service.HubManager.operative_rows/1`. An operative the loop has not yet observed SHALL be shown as `unknown` and SHALL NOT be reported as healthy.

#### Scenario: Namespace has operatives

- **WHEN** an operator opens a namespace that has running operatives
- **THEN** each operative id is listed with its health, node, factory, and runner
- **AND** the id links to its detail screen

#### Scenario: An operative is unhealthy

- **WHEN** an operative's health is `degraded`, `unbound`, or `failed`
- **THEN** the row states that health distinctly from a healthy row

#### Scenario: An operative has not yet been classified

- **WHEN** a registry row has no health from the Convergence Loop
- **THEN** the row reads `unknown`

#### Scenario: An operative is unplaced

- **WHEN** a registry row has no live node
- **THEN** the row states that it is unplaced

#### Scenario: Namespace has registered factories

- **WHEN** runners in the namespace have registered factories
- **THEN** each factory id is listed and is selectable when starting an operative

### Requirement: Operative lifecycle

An operator SHALL be able to start an operative by supplying a namespace, id, factory id, kind, and init values, and SHALL be able to stop a running operative. Stopping SHALL require an explicit confirmation step.

#### Scenario: Starting an operative succeeds

- **WHEN** an operator submits a valid id, factory id, and init values
- **THEN** the operative is started via `Flezha.start_operative/2`
- **AND** it appears in the namespace's operative list

#### Scenario: Starting an operative is rejected by the controller

- **WHEN** the controller rejects the start, for example a duplicate id or unknown factory
- **THEN** the controller's reason is displayed on the form
- **AND** no operative is created

#### Scenario: Stopping an operative

- **WHEN** an operator confirms stopping an operative
- **THEN** `Flezha.stop_operative/2` is called
- **AND** the operator is returned to the namespace screen with the operative absent from the list

#### Scenario: Stop is not confirmed

- **WHEN** an operator opens the stop confirmation and dismisses it
- **THEN** no stop call is made

### Requirement: Operative introspection

The operative detail screen SHALL display, from the overwatch state, the operative's factory id, bound runner id, kind, uptime, suspended flag, effectively-once tier, and its subscribed plugins. It SHALL additionally display the health and node the namespace's rows report for it, and — for a workflow — the workflow panel defined by the `workflow-operations` capability.

#### Scenario: Operative is running and bound

- **WHEN** an operator opens a running operative
- **THEN** its factory id, runner id, kind, uptime, health, and node are displayed

#### Scenario: Operative is suspended

- **WHEN** the overwatch state reports `suspended: true`
- **THEN** the screen marks the operative as suspended

#### Scenario: Operative is a partition member

- **WHEN** the operative carries a partition identity
- **THEN** its partition index, key-group range, and its group are shown
- **AND** the group links to the namespace's group row

#### Scenario: Operative is not found

- **WHEN** the requested operative does not exist in the namespace
- **THEN** a not-found message is shown instead of an error page

### Requirement: Entity state reads

The UI SHALL read entity state through a selector supporting whole-operative, per-procedure, and per-procedure-and-entity-key scopes, and SHALL display the returned change sequence when the controller supplies one.

#### Scenario: Reading whole-operative state

- **WHEN** an operator requests state with no selector
- **THEN** the full JSON state for every procedure is displayed

#### Scenario: Reading a single entity

- **WHEN** an operator supplies a procedure name and entity key
- **THEN** only that entity's state is displayed
- **AND** the change sequence it was serialized at is shown

#### Scenario: Kind does not support persistent state

- **WHEN** the controller returns `{:error, {:unsupported_for_kind, :persistent_state}}`
- **THEN** the screen explains that this operative's kind has no per-entity state
- **AND** this is presented as an explanation, not as a failure

#### Scenario: Entity is not resident

- **WHEN** the controller returns a `{:not_resident, reason}` refusal
- **THEN** the reason is displayed and the operator is told the entity is not held in memory

### Requirement: Live I/O streaming

An operator SHALL be able to stream a running operative's input or output. The UI SHALL register the stream through `Flezha.Service.PluginHelper.enable_io_listener/4` with an explicit receiver pid, and SHALL disable the listener when the last viewer disconnects.

#### Scenario: Opening an output stream

- **WHEN** an operator opens the stream screen for output
- **THEN** an io listener is enabled for `"output"`
- **AND** messages appear in the viewer as they are produced

#### Scenario: Last viewer leaves

- **WHEN** the last LiveView subscribed to a stream disconnects
- **THEN** the io listener plugin is disabled on the controller

#### Scenario: Two viewers share one stream

- **WHEN** a second operator opens the same operative's stream
- **THEN** both receive messages from a single controller-side listener

### Requirement: A cross-namespace operatives index

The UI SHALL provide an operatives screen at `/operatives` listing every operative across every namespace the bound token can reach, showing operative id, namespace, factory, health, kind, node, runner, and plugin count, with the id linking to the operative's detail screen. The listing SHALL cost one `operative_rows/1` and one `operative_plugins/1` call per namespace, not one call per operative.

#### Scenario: Operatives exist across namespaces

- **WHEN** an operator opens the operatives screen
- **THEN** every operative in every reachable namespace is listed with its namespace and health

#### Scenario: Filtering the index

- **WHEN** an operator filters by namespace, health, or kind
- **THEN** only matching operatives are listed

#### Scenario: The index is reachable from the navigation

- **WHEN** an operator looks at the sidebar
- **THEN** an Operatives entry sits between Namespaces and Plugins

#### Scenario: No operatives are running

- **WHEN** no namespace holds an operative
- **THEN** an empty state says so rather than rendering an empty table

### Requirement: Partition groups and their coverage

A namespace holding partition group members SHALL present them as one group row per group, produced by `Flezha.Service.CliManager.group_partition_rows/1`, showing the member count against the declared partition count and the group's health as its sickest member's. A group whose key-range coverage has gaps or overlaps SHALL be marked as faulted, and the gaps and overlapping owners SHALL be named.

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
- **THEN** the group row reports degraded

#### Scenario: Members are reachable

- **WHEN** an operator expands a group row
- **THEN** each member is listed with its partition index, key-group range, runner, and health

