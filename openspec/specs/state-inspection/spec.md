# state-inspection Specification

## Purpose
TBD - created by archiving change resync-with-flezha-platform. Update Purpose after archive.
## Requirements
### Requirement: Durability lag is charted, and labelled as the controller's own figure

The state screen SHALL chart `fsync_durability_lag_ms` and the gap between `wal_seq` and `snapshot_seq` over the UI's own refresh ticks, and SHALL state that the series is sampled by this UI at its tick rate rather than recorded by the controller.

#### Scenario: A lagging cell

- **WHEN** a cell's durability lag rises across successive ticks
- **THEN** the chart shows the rise
- **AND** the cell is marked as lagging in the listing

#### Scenario: The series is honest about its origin

- **WHEN** the chart is rendered
- **THEN** it states that points are sampled at the UI's refresh interval

#### Scenario: A tick is missed

- **WHEN** the controller is unreachable for one or more ticks
- **THEN** the gap is shown as a gap rather than interpolated across

### Requirement: Point-in-time state reads

An operator SHALL be able to ask where a selected cell's history stands at a sequence number or a time, through `Flezha.Service.Steps.time_travel/3` with the cell written as `<relay_class>/<tasklet>/<cell_key>` and the target written as a sequence number or an ISO 8601 time. The controller answers the sequence the target resolves to and the sizes of the snapshot and change log behind it, not the state itself, and the UI SHALL show exactly that.

#### Scenario: Reading at a sequence

- **WHEN** an operator selects a cell and supplies a sequence number
- **THEN** the resolved sequence, the snapshot size, and the change-log size are shown
- **AND** the target that was asked for is stated alongside them

#### Scenario: Reading at a time

- **WHEN** an operator supplies a time
- **THEN** it is sent to the controller as an ISO 8601 time
- **AND** the sequence it resolves to is shown with the two sizes

#### Scenario: The target is not a sequence or a time

- **WHEN** an operator supplies a target that is neither a whole number nor a valid time
- **THEN** the form says so and no read is made

#### Scenario: The target is unreachable

- **WHEN** the controller refuses the target, for example with `relay.outside_retention`
- **THEN** the error's message is shown and no result is rendered

#### Scenario: State is not presented as replayed bytes

- **WHEN** a point-in-time read succeeds
- **THEN** the screen does not present the answer as the cell's state at that point

### Requirement: A relay's durable cells are listed with their metrics

The relay state screen SHALL list the cells with persisted state belonging to the relay's class — its `relay_class`, which defaults to its id — from `Flezha.Service.Steps.cells/2` for that class, showing each cell's tasklet id, cell key, `wal_seq`, `snapshot_seq`, `flush_latency_ms_p99`, `fsync_durability_lag_ms`, and `dedup_drops_total`.

#### Scenario: A relay with durable cells

- **WHEN** an operator opens the state screen for a relay whose cells have persisted
- **THEN** each cell is listed with its sequence numbers and durability metrics

#### Scenario: A relay with no durable state

- **WHEN** the controller answers no cell for the relay's class
- **THEN** an empty state says the relay has no durable state yet

#### Scenario: Cells are grouped by tasklet

- **WHEN** a relay has cells across several tasklets
- **THEN** the listing groups them by tasklet id

#### Scenario: Only the relay's own class is read

- **WHEN** the state screen refreshes
- **THEN** it reads the cells of the relay's class alone, not the controller's counters for every class

### Requirement: Retention facts

The state screen SHALL show the retention facts that apply to the relay's class, each labelled for what it keeps: how long the cells' write-ahead history is retained, from the `history_retention_hours` that `Flezha.Service.Steps.cells/2` answers, and, for a steps relay, how long a finished instance is retained, from `Flezha.Service.Steps.completed_retention_hours/3`. An operator SHALL be able to set the history retention through `Flezha.Service.Steps.set_retention/3`; the form SHALL state that the value lasts until the controller next boots unless its runtime configuration says the same.

#### Scenario: Retention is shown

- **WHEN** an operator opens the state screen
- **THEN** the history retention that applies to the class is stated in hours
- **AND** for a steps relay the finished-instance retention is stated beside it under its own label

#### Scenario: Retention cannot be read

- **WHEN** the controller refuses or cannot answer the retention read
- **THEN** the retention is shown as unavailable and the cell listing still renders

#### Scenario: An older controller

- **WHEN** the `cells/2` answer carries no `history_retention_hours`
- **THEN** the history retention is stated as unknown rather than omitted

#### Scenario: History retention is set

- **WHEN** an operator submits a new history retention in whole hours
- **THEN** `set_retention/3` is called with the relay class and those hours
- **AND** the screen shows the value the controller answered
- **AND** it states that the value lasts until the controller next boots

#### Scenario: An invalid retention

- **WHEN** an operator submits a negative or non-numeric retention
- **THEN** the form names the field
- **AND** no call is made

### Requirement: A cell's persisted state is inspected and maintained from the state screen

Selecting a cell on the state screen SHALL read its outbox through `Flezha.Service.Steps.outbox/2` and show its durable sequence, flush cursor, epoch, pending and held entries, and the relay's input watermark. An operator SHALL be able to rotate a cell's persisted state through `Flezha.Service.Steps.rotate/2` and delete it through `Flezha.Service.Steps.delete/2`, each after an explicit confirmation that names the cell. The delete confirmation SHALL state that the cell's write-ahead log, snapshots and outbox deduplication are removed and cannot be recovered.

#### Scenario: A cell's outbox

- **WHEN** an operator selects a cell
- **THEN** its outbox facts are shown
- **AND** pending and held entries are shown as unknown when the controller answers that the cell's writer is not running

#### Scenario: Rotating a cell

- **WHEN** an operator confirms rotating a cell
- **THEN** `rotate/2` is called with the cell path
- **AND** the screen states that a compaction was requested

#### Scenario: Deleting a cell

- **WHEN** an operator confirms deleting a cell
- **THEN** `delete/2` is called with the cell path
- **AND** the cell's row is refreshed from the controller

#### Scenario: A destructive action is not confirmed

- **WHEN** an operator opens the rotate or delete confirmation and dismisses it
- **THEN** no call is made

#### Scenario: The role cannot change state

- **WHEN** the bound role is not granted rotate, delete or retention
- **THEN** the controls it is not granted are not rendered
- **AND** the read-only facts are still shown

### Requirement: Lagging means a lag that is large and rising

A cell SHALL be marked lagging only while its latest `fsync_durability_lag_ms` is above one second and higher than the sample before it. A lag of a few milliseconds SHALL NOT mark a cell lagging.

#### Scenario: A normal fsync lag

- **WHEN** a cell's fsync lag holds at tens of milliseconds
- **THEN** it is not marked lagging

#### Scenario: A rising lag

- **WHEN** a cell's fsync lag rises from 1,200 ms to 1,800 ms between samples
- **THEN** it is marked lagging

### Requirement: The state screen explains its columns and actions

Each column of the cell listing (WAL seq, Snapshot seq, Flush p99, Fsync lag, Dedup drops) and each row action (Read where its history stands, Rotate, Delete) SHALL carry an explanation in place from the glossary.

#### Scenario: Asking what Rotate does

- **WHEN** an operator opens the explanation beside Rotate
- **THEN** it says that rotate asks the runner for a fresh snapshot and compacts the cell's write-ahead log behind it, and that the cell's state is kept

