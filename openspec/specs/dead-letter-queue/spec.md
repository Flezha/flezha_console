# dead-letter-queue Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Parked entry listing

The UI SHALL list dead-letter entries oldest first, showing each entry's reference, entity key, channel, generation, age, and error, and SHALL allow filtering by operative class. Entries SHALL be grouped by procedure, matching how the controller stores and ships them, with each procedure's parked count shown on its group.

#### Scenario: Entries are parked

- **WHEN** an operator opens the dead-letter queue
- **THEN** parked entries are listed oldest first with reference, entity key, channel, generation, age, and error

#### Scenario: Entries span procedures

- **WHEN** parked entries belong to more than one procedure
- **THEN** they are grouped by procedure with a parked count per group

#### Scenario: Filtering by operative class

- **WHEN** an operator filters by an operative class
- **THEN** only entries belonging to that class are listed
- **AND** the procedures listed are those `Flezha.Dlq.Store.procedures/1` reports for that class

#### Scenario: The queue is empty

- **WHEN** no entries are parked
- **THEN** an empty state states that the dead-letter queue is empty

### Requirement: Entry inspection

An operator SHALL be able to open a single entry by reference and see its metadata together with a preview of its payload.

#### Scenario: Opening an entry

- **WHEN** an operator opens a parked entry
- **THEN** its metadata and a payload preview are displayed

#### Scenario: The entry no longer exists

- **WHEN** the entry has already been dropped or resolved
- **THEN** a not-found message is shown and the operator is returned to the list

### Requirement: Replay reports its outcome

Replaying an entry SHALL wait for the controller's replay grace period and report whether the payload was accepted or re-parked. Replay SHALL require an explicit confirmation step.

#### Scenario: Replay succeeds

- **WHEN** an operator confirms a replay and the payload is accepted
- **THEN** the entry leaves the queue and the result is reported as replayed

#### Scenario: Replay re-parks

- **WHEN** the payload fails again and is re-parked within the grace period
- **THEN** the result is reported as re-parked, with the new error
- **AND** the entry remains in the queue

#### Scenario: The operative is not running

- **WHEN** the controller refuses the replay because the operative is not running
- **THEN** that reason is displayed and the entry is left untouched

#### Scenario: Replay is not confirmed

- **WHEN** an operator dismisses the replay confirmation
- **THEN** no replay is attempted

### Requirement: Drop is confirmed and irreversible

Dropping an entry SHALL require an explicit confirmation step that states the payload is discarded permanently.

#### Scenario: Dropping an entry

- **WHEN** an operator confirms a drop
- **THEN** the entry and its payload are discarded and it leaves the list

#### Scenario: Drop is not confirmed

- **WHEN** an operator dismisses the drop confirmation
- **THEN** the entry remains in the queue

### Requirement: Queue statistics

The UI SHALL display dead-letter statistics as reported by the controller.

#### Scenario: Viewing statistics

- **WHEN** an operator opens the dead-letter queue
- **THEN** the controller's reported statistics are displayed alongside the entry list

