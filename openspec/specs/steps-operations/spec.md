# steps-operations Specification

## Purpose
What the console shows and does for relays whose factory runs as `steps`: the steps
facts panel, suspension as a health verdict, finished relays within their retention
window, the task journal and input log, and rescale and rewind.
## Requirements
### Requirement: Suspension is a health value, carried by the flat listing read

The UI SHALL treat `suspended` as one of the health verdicts it renders and filters, and SHALL NOT issue a per-relay call to determine it. Filtering to suspended relays SHALL cost nothing beyond the listing's own read.

Suspension is not a separate fact to fetch: the Convergence Loop ranks it among its verdicts — a steps relay put to sleep at a committed iteration boundary classifies as `suspended` rather than `healthy` or `failed` — and that verdict rides `Flezha.Service.Relay.list/2` like every other health value.

#### Scenario: A suspended relay in a listing

- **WHEN** a relay is suspended at a committed iteration boundary
- **THEN** every listing that shows it renders its health as suspended, distinctly from healthy, degraded, recovering, unbound, failed, and parked

#### Scenario: Filtering to suspended relays

- **WHEN** an operator filters the relays index by suspended
- **THEN** the health filter answers it from rows already read
- **AND** no per-relay call is made and no extra-cost notice is shown

#### Scenario: The listing tick does not grow with suspended relays

- **WHEN** a listing refreshes on its timer
- **THEN** the tick's controller-call count is unchanged by how many relays are suspended

#### Scenario: Suspension is distinguished from stopped

- **WHEN** a relay is suspended and another has been stopped
- **THEN** the suspended one is listed with suspended health and the stopped one is absent from the live listing

### Requirement: Finished instances are listed within their retention window

The UI SHALL list steps relays that have finished but are still retained, as `Flezha.Service.Relay.info/2` reports them: the controller already selects the finished relays of the namespace whose completion record is inside their retention window. The UI SHALL NOT re-derive that selection from relay classes, completion records, or retention settings. Opening a finished relay SHALL read its completion record through `Flezha.Service.Steps.completion/2`.

#### Scenario: A recently finished relay

- **WHEN** a relay finished within its retention window
- **THEN** it is listed as finished with its finish time and status
- **AND** it is visibly separated from live relays

#### Scenario: A relay past its retention window

- **WHEN** a relay's completion is older than its retention window
- **THEN** the controller does not report it and it is not listed

#### Scenario: A finished relay is opened

- **WHEN** an operator opens a finished relay
- **THEN** its completion record is shown
- **AND** actions that require a live relay are absent rather than failing when used

### Requirement: Rescale and rewind

An operator SHALL be able to rescale a partition group to a target member count, through `Flezha.Service.Steps.rescale/5`, and to rewind a durable steps relay to a committed iteration, through `Flezha.Service.Steps.rewind/4` naming the relay rather than a process. Both SHALL require an explicit confirmation, and rewind SHALL state that iterations after the target are discarded.

#### Scenario: Rescaling a group

- **WHEN** an operator confirms a new target for a partition group
- **THEN** the rescale is requested with that target
- **AND** the group's member count and coverage re-render on the next tick

#### Scenario: Rewinding to a committed iteration

- **WHEN** an operator confirms a rewind to an iteration the journal reports as committed
- **THEN** the rewind is requested for that relay and iteration

#### Scenario: Rewind target is not offered freely

- **WHEN** the rewind form is opened
- **THEN** only iterations the journal reports as committed are selectable

#### Scenario: The controller refuses the rewind

- **WHEN** the controller answers an error such as `relay.not_running` or `relay.iteration_not_committed`
- **THEN** the error's message is shown and nothing is reported as rewound

#### Scenario: Neither action is confirmed

- **WHEN** an operator opens either confirmation and dismisses it
- **THEN** no call is made

### Requirement: Steps facts are shown as their own panel

For a relay whose run is `steps`, the relay detail screen SHALL show a steps panel carrying `durable_steps`, `effectively_once`, `correction_window_ms`, `arrived_via_hotswap?`, and `init_error` from the overwatch state, alongside the already-decoded `suspended`.

#### Scenario: A durable steps relay

- **WHEN** an operator opens a steps relay whose overwatch reports `durable_steps: true`
- **THEN** the steps panel states that the relay is durable

#### Scenario: A flow relay

- **WHEN** an operator opens a relay whose run is `flow`
- **THEN** no steps panel is rendered

#### Scenario: A relay failed to initialise

- **WHEN** the overwatch state carries a non-nil `init_error`
- **THEN** the error is shown on the steps panel rather than the relay reading as healthy

### Requirement: The task journal and input log are readable

For a durable steps relay the UI SHALL show its task journal from `Flezha.Service.Steps.journal/2` and `Flezha.Service.Steps.committed_iterations/2`, and the depth and last offset of its input log from `Flezha.Service.Steps.undelivered/2` and `Flezha.Service.Steps.last_offset/2`. The journal SHALL be shown as the report the controller answers: the entries in append order, the leaf tasklets that define done, and whether the in-flight iteration has committed every leaf.

#### Scenario: A journal with committed iterations

- **WHEN** an operator opens the task journal for a durable steps relay
- **THEN** the committed iterations are listed most recent first
- **AND** each journal entry shows its type, iteration, and sequence

#### Scenario: A dead-lettered entry

- **WHEN** the journal holds an entry of type `dead_lettered`
- **THEN** it names the tasklet that failed and the dead-letter entry it was parked as

#### Scenario: Whether the iteration is complete

- **WHEN** the journal report is shown
- **THEN** it states the leaf tasklets and whether the in-flight iteration has committed every one of them

#### Scenario: An input log with undelivered records

- **WHEN** the input log holds records the relay has not consumed
- **THEN** their count and the last offset are shown

#### Scenario: An empty input log

- **WHEN** the controller answers the last offset as `-1`
- **THEN** the input log is shown as holding no records rather than an offset of `-1`

#### Scenario: A non-durable relay

- **WHEN** a relay is not a durable steps relay
- **THEN** the task journal and input log panels are absent rather than empty

