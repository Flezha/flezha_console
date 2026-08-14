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

The namespace detail screen SHALL list the namespace's operatives, its available factories, and its active runners.

#### Scenario: Namespace has operatives

- **WHEN** an operator opens a namespace that has running operatives
- **THEN** each operative id is listed and links to its detail screen

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

The operative detail screen SHALL display, from the overwatch state, the operative's factory id, bound runner id, kind, uptime, suspended flag, effectively-once tier, and its subscribed plugins.

#### Scenario: Operative is running and bound

- **WHEN** an operator opens a running operative
- **THEN** its factory id, runner id, kind, and uptime are displayed

#### Scenario: Operative is suspended

- **WHEN** the overwatch state reports `suspended: true`
- **THEN** the screen marks the operative as suspended

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

