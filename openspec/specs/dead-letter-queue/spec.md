# dead-letter-queue Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Entry inspection

An operator SHALL be able to open a single entry by reference and see its metadata together with a preview of its payload.

#### Scenario: Opening an entry

- **WHEN** an operator opens a parked entry
- **THEN** its metadata and a payload preview are displayed

#### Scenario: The entry no longer exists

- **WHEN** the entry has already been dropped or resolved
- **THEN** a not-found message is shown and the operator is returned to the list

### Requirement: Replay reports its outcome

Replaying an entry SHALL re-send its payload to its relay through `Flezha.Service.Dlq.replay/2`, which re-injects the payload as a new input, waits out the controller's replay grace period, and answers whether the entry was removed or re-parked. The UI SHALL report that answer as it is, and SHALL NOT mark an entry as replaying, read the grace period, or wait on its own. Replay SHALL require an explicit confirmation step.

#### Scenario: Replay succeeds

- **WHEN** an operator confirms a replay and the controller answers `outcome: :removed`
- **THEN** the result is reported as replayed
- **AND** the entry leaves the queue

#### Scenario: Replay re-parks

- **WHEN** the controller answers `outcome: :re_parked` with a new generation
- **THEN** the result is reported as re-parked with that generation
- **AND** the entry remains in the queue showing its new error

#### Scenario: The relay is not running

- **WHEN** the controller refuses the replay with `relay.not_running`
- **THEN** the error's message is displayed and the entry is left untouched

#### Scenario: The entry carries no payload

- **WHEN** the controller refuses the replay with `dlq.payload_not_replayable`, because the entry is an input between tasklets with no payload bytes
- **THEN** the error's message is displayed and the entry is left untouched

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

The UI SHALL display dead-letter statistics as reported by the controller, one figure per tasklet that holds parked entries, labelled with its relay class and tasklet in their own case. A tasklet the controller reports at zero entries SHALL NOT be shown.

#### Scenario: Viewing statistics

- **WHEN** an operator opens the dead-letter queue
- **THEN** the controller's reported statistics are displayed alongside the entry list

#### Scenario: A tasklet's last entry leaves

- **WHEN** the last parked entry of a tasklet is dropped or replayed cleanly
- **THEN** that tasklet no longer appears in the statistics, including while a durability backend has yet to ship the emptied set and the controller still reports it at zero

### Requirement: Dead-letter entry listing

The UI SHALL list dead-letter entries from `Flezha.Service.Dlq.list/2`, oldest first, and SHALL allow filtering by relay class. Each entry SHALL be shown with:

- its reference, cell key, channel, generation and error;
- when it was dead-lettered, relative to now and as an absolute time;
- how many attempts it has had;
- its payload size;
- whether it is waiting or being replayed.

Entries SHALL be grouped by tasklet, matching how the controller stores and ships them, with each tasklet's dead-letter count shown on its group. The listing SHALL show the total bytes the queue holds, from `Flezha.Service.Dlq.stats/2`. Visible text SHALL call the entries dead letters and SHALL NOT call them parked.

#### Scenario: Entries are waiting

- **WHEN** an operator opens the dead-letter queue
- **THEN** dead letters are listed oldest first with reference, cell key, channel, generation, dead-letter time, attempts, size, state and error

#### Scenario: An entry is being replayed

- **WHEN** an entry's status is `replaying`
- **THEN** its state reads "Replaying"
- **AND** an entry with no status reads "Waiting"

#### Scenario: The queue's size is shown

- **WHEN** the stats answer carries `bytes`
- **THEN** the listing shows the total size held

#### Scenario: Entries span tasklets

- **WHEN** dead letters belong to more than one tasklet
- **THEN** they are grouped by tasklet with a dead-letter count per group

#### Scenario: Filtering by relay class

- **WHEN** an operator filters by a relay class
- **THEN** only entries whose `relay_class` is that class are listed
- **AND** the tasklets listed are those `Flezha.Service.Dlq.tasklets/2` reports for that class

#### Scenario: The queue is empty

- **WHEN** no dead letter is waiting
- **THEN** an empty state states that the dead-letter queue is empty

### Requirement: A dead letter can be marked seen

An operator SHALL be able to mark a dead letter, or every dead letter of a tasklet, as seen. A seen dead letter SHALL stay in the queue and in the listing with a "Seen" badge. The listing SHALL hide seen dead letters unless "Show seen" is on. Seen SHALL be recorded in the console's database per entry reference and generation, with the operator who marked it.

#### Scenario: Marking one dead letter seen

- **WHEN** an operator marks a dead letter seen
- **THEN** it leaves the default listing, and with "Show seen" on it is listed with a "Seen" badge
- **AND** the controller's queue still holds it

#### Scenario: A seen dead letter is re-parked

- **WHEN** a seen dead letter is replayed and re-parked with a new generation
- **THEN** it is no longer seen

