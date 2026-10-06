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

The state screen SHALL show the retention window that applies to the relay's class, from `Flezha.Service.Steps.completed_retention_hours/3`. The UI SHALL NOT delete or rotate state.

#### Scenario: Retention is shown

- **WHEN** an operator opens the state screen
- **THEN** the retention window that applies to the class is stated in hours

#### Scenario: Retention cannot be read

- **WHEN** the controller refuses or cannot answer the retention read
- **THEN** the retention is shown as unavailable and the cell listing still renders

#### Scenario: Destructive state verbs are absent

- **WHEN** the state screen is rendered
- **THEN** no control deletes or rotates state
- **AND** the screen names `flz state` as where those verbs live

