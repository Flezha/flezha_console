# workflow-operations Specification

## Purpose
TBD - created by archiving change resync-with-flezha-platform. Update Purpose after archive.
## Requirements
### Requirement: Workflow facts are shown as their own panel

For an operative whose kind is `:workflow`, the operative detail screen SHALL show a workflow panel carrying `durable_workflow`, `effectively_once`, `correction_window_ms`, `arrived_via_hotswap?`, and `init_error` from the overwatch state, alongside the already-decoded `suspended`.

#### Scenario: A durable workflow instance

- **WHEN** an operator opens a workflow operative whose overwatch reports `durable_workflow: true`
- **THEN** the workflow panel states that the instance is durable

#### Scenario: A stream operative

- **WHEN** an operator opens an operative whose kind is `:stream`
- **THEN** no workflow panel is rendered

#### Scenario: An instance failed to initialise

- **WHEN** the overwatch state carries a non-nil `init_error`
- **THEN** the error is shown on the workflow panel rather than the operative reading as healthy

### Requirement: Suspension is a health value, carried by the flat listing read

The UI SHALL treat `:suspended` as one of the health kinds it renders and filters, and SHALL NOT issue a per-instance call to determine it. Filtering to suspended instances SHALL cost nothing beyond the listing's own read.

Suspension is not a separate fact to fetch: the Convergence Loop ranks it in its health ladder — an operative evicted at a committed iteration boundary classifies as `:suspended` rather than `:healthy` or `:failed` — and that classification rides `Flezha.Service.HubManager.operative_rows/1` like every other health value.

#### Scenario: A suspended instance in a listing

- **WHEN** an instance is suspended at a committed iteration boundary
- **THEN** every listing that shows it renders its health as suspended, distinctly from healthy, degraded, unbound, and failed

#### Scenario: Filtering to suspended instances

- **WHEN** an operator filters the operatives index by suspended
- **THEN** the health filter answers it from rows already read
- **AND** no per-instance call is made and no extra-cost notice is shown

#### Scenario: The listing tick does not grow with suspended instances

- **WHEN** a listing refreshes on its timer
- **THEN** the tick's controller-call count is unchanged by how many instances are suspended

#### Scenario: Suspension is distinguished from stopped

- **WHEN** an instance is suspended and another has been stopped
- **THEN** the suspended one is listed with suspended health and the stopped one is absent from the live listing

### Requirement: Finished instances are listed within their retention window

The UI SHALL list workflow instances that have completed but are still retained, using the controller's own rule: the operative classes from `Flezha.State.Registry.operative_classes/0` that are not live, whose `Flezha.State.Completion.read/1` record names the namespace, and whose `finished_at` is within `Flezha.State.PersistenceResolver.workflow_completed_retention_hours/1`.

#### Scenario: A recently finished instance

- **WHEN** an instance completed within its retention window
- **THEN** it is listed as finished with its finish time
- **AND** it is visibly separated from live operatives

#### Scenario: An instance past its retention window

- **WHEN** an instance's completion is older than its retention window
- **THEN** it is not listed

#### Scenario: A finished instance is opened

- **WHEN** an operator opens a finished instance
- **THEN** its completion record is shown
- **AND** actions that require a live operative are absent rather than failing when used

### Requirement: The proc journal and inbox are readable

For a durable workflow instance the UI SHALL show the committed iterations and journal entries from `Flezha.State.ProcJournal`, and the undelivered inbox depth and last offset from `Flezha.State.ProcInbox`.

#### Scenario: A journal with committed iterations

- **WHEN** an operator opens the journal for a durable instance
- **THEN** the committed iterations are listed most recent first
- **AND** a parked entry states its wake deadline

#### Scenario: An instance with undelivered inbox entries

- **WHEN** the inbox holds undelivered entries
- **THEN** the count and the last offset are shown

#### Scenario: A non-durable instance

- **WHEN** an operative is not a durable workflow
- **THEN** the journal and inbox panels are absent rather than empty

### Requirement: Rescale and rewind

An operator SHALL be able to rescale a partition group to a target member count and to rewind a durable workflow instance to a committed iteration. Both SHALL require an explicit confirmation, and rewind SHALL state that iterations after the target are discarded.

#### Scenario: Rescaling a group

- **WHEN** an operator confirms a new target for a partition group
- **THEN** the rescale is requested with that target
- **AND** the group's member count and coverage re-render on the next tick

#### Scenario: Rewinding to a committed iteration

- **WHEN** an operator confirms a rewind to an iteration the journal reports as committed
- **THEN** the rewind is requested for that iteration

#### Scenario: Rewind target is not offered freely

- **WHEN** the rewind form is opened
- **THEN** only iterations the journal reports as committed are selectable

#### Scenario: Neither action is confirmed

- **WHEN** an operator opens either confirmation and dismisses it
- **THEN** no call is made

