# state-inspection Specification

## Purpose
TBD - created by archiving change resync-with-flezha-platform. Update Purpose after archive.
## Requirements
### Requirement: An operative's durable entities are listed with their metrics

The operative state screen SHALL list the entities belonging to the operative's class, from `Flezha.State.Metrics.snapshot_all/0` filtered to that class, showing each entity's procedure id, entity key, `wal_seq`, `snapshot_seq`, `flush_latency_ms_p99`, `fsync_durability_lag_ms`, and `dedup_drops_total`.

#### Scenario: An operative with durable entities

- **WHEN** an operator opens the state screen for an operative whose entities have persisted
- **THEN** each entity is listed with its sequence numbers and durability metrics

#### Scenario: An operative with no durable state

- **WHEN** no entity under the operative's class appears in the metrics snapshot
- **THEN** an empty state says the operative has no durable state yet

#### Scenario: Entities are grouped by procedure

- **WHEN** an operative has entities across several procedures
- **THEN** the listing groups them by procedure id

### Requirement: Durability lag is charted, and labelled as the controller's own figure

The state screen SHALL chart `fsync_durability_lag_ms` and the gap between `wal_seq` and `snapshot_seq` over the UI's own refresh ticks, and SHALL state that the series is sampled by this UI at its tick rate rather than recorded by the controller.

#### Scenario: A lagging entity

- **WHEN** an entity's durability lag rises across successive ticks
- **THEN** the chart shows the rise
- **AND** the entity is marked as lagging in the listing

#### Scenario: The series is honest about its origin

- **WHEN** the chart is rendered
- **THEN** it states that points are sampled at the UI's refresh interval

#### Scenario: A tick is missed

- **WHEN** the controller is unreachable for one or more ticks
- **THEN** the gap is shown as a gap rather than interpolated across

### Requirement: Point-in-time state reads

An operator SHALL be able to read a selected entity's state at a sequence number or timestamp through `Flezha.State.TimeTravel.query/2`, and SHALL see the target that was resolved.

#### Scenario: Reading state at a sequence

- **WHEN** an operator selects an entity and supplies a sequence number
- **THEN** the state at that sequence is rendered
- **AND** the resolved target is stated alongside it

#### Scenario: Reading state at a timestamp

- **WHEN** an operator supplies a timestamp
- **THEN** the state at that timestamp is rendered

#### Scenario: The target is unreachable

- **WHEN** the requested target is before the retained history
- **THEN** the controller's reason is shown and no state is rendered

### Requirement: Retention and outbox facts

The state screen SHALL show the operative class's retention hours and, for a class with an outbox, its pending entries. The UI SHALL NOT delete or rotate state.

#### Scenario: Retention is shown

- **WHEN** an operator opens the state screen
- **THEN** the retention window that applies to the class is stated

#### Scenario: An outbox with pending entries

- **WHEN** the class's outbox holds unacknowledged entries
- **THEN** the count is shown

#### Scenario: Destructive state verbs are absent

- **WHEN** the state screen is rendered
- **THEN** no control deletes or rotates state
- **AND** the screen names `flz state` as where those verbs live

