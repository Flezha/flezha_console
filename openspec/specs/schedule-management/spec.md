# schedule-management Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Schedule listing with live status

The UI SHALL list persisted schedule entries with their name, cron expression, timezone, and target, joined with each entry's live job status from the schedule hub.

#### Scenario: Schedules exist

- **WHEN** an operator opens the schedules screen
- **THEN** each entry is listed with its cron expression, timezone, target, and current job status

#### Scenario: An entry has no live job

- **WHEN** a persisted entry has not been asserted onto the hub
- **THEN** the entry is listed with an explicit not-armed status rather than a blank status

#### Scenario: No schedules exist

- **WHEN** no schedule entries are persisted
- **THEN** an empty state explains that no schedule has been created

### Requirement: Schedule creation

An operator SHALL be able to create a schedule by supplying a name, cron expression, timezone, and target. The entry SHALL be persisted and then asserted onto the schedule hub.

#### Scenario: Creating a valid schedule

- **WHEN** an operator submits a valid name, cron expression, timezone, and target
- **THEN** the entry is persisted and asserted onto the hub
- **AND** it appears in the list with an armed status

#### Scenario: The cron expression is invalid

- **WHEN** the controller rejects the cron expression
- **THEN** the rejection reason is displayed on the form
- **AND** nothing is persisted

#### Scenario: The timezone is invalid

- **WHEN** the controller rejects the timezone
- **THEN** the rejection reason is displayed on the form
- **AND** nothing is persisted

#### Scenario: The name is already taken

- **WHEN** an entry with that name already exists
- **THEN** the conflict is reported and the existing entry is left unchanged

### Requirement: Schedule removal

Removing a schedule SHALL retract it from the hub and delete the persisted entry, and SHALL require an explicit confirmation step.

#### Scenario: Removing a schedule

- **WHEN** an operator confirms removing a schedule
- **THEN** it is retracted from the hub and deleted from the store
- **AND** it leaves the list

#### Scenario: Removal is not confirmed

- **WHEN** an operator dismisses the removal confirmation
- **THEN** the schedule remains armed and listed

