# schedule-management Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Schedule listing with live status

The UI SHALL list schedule entries from `Flezha.Service.Schedule.list/1`. That call answers each stored entry with its name, cron expression, timezone, creation time and target, joined with what the schedule hub holds for it:

- the node that fires it;
- its last fire, with that fire's outcome and the relay it started;
- its next fire;
- whether its job is dormant.

The UI SHALL show the last fire's outcome, and SHALL link a started relay to its screen. Times SHALL be shown relative to now, with the absolute time beside them.

The same LiveView SHALL additionally serve a namespace-scoped listing at `/namespaces/:ns/schedules`, filtering on the namespace each entry already carries. The controller keeps one schedule registry for the whole cluster and answers it whole. The scoped screen SHALL therefore state that its scope is a view filter over the full listing rather than a controller-side scope.

#### Scenario: Schedules exist

- **WHEN** an operator opens the schedules screen
- **THEN** each entry is listed with its cron expression, timezone, target, creation time, the node that fires it, its last fire and its next fire

#### Scenario: The last fire started a relay

- **WHEN** an entry's last fire carries an `instance_id`
- **THEN** the last fire links to that relay's screen and states its outcome

#### Scenario: The last fire is being retried

- **WHEN** an entry's last fire outcome is `{:retrying, reason}`
- **THEN** the last fire states that it is retrying, with the reason, in the warning tone

#### Scenario: A namespace's own schedules

- **WHEN** an operator opens `/namespaces/:ns/schedules`
- **THEN** only entries targeting that namespace are listed

#### Scenario: The scope is honestly labelled

- **WHEN** the scoped schedules screen is rendered
- **THEN** it states that the namespace is applied as a view filter over the controller's full schedule listing

#### Scenario: One LiveView serves both routes

- **WHEN** the codebase is inspected
- **THEN** `/schedules` and `/namespaces/:ns/schedules` are served by the same LiveView module

#### Scenario: Creating a schedule under a namespace scope

- **WHEN** an operator creates a schedule from a namespace-scoped screen
- **THEN** the creation form's namespace defaults to the scoped namespace

#### Scenario: An entry has no live job

- **WHEN** the hub holds nothing for a stored entry, so no node fires it
- **THEN** the entry is listed with the status "Inactive" rather than a blank status

#### Scenario: An entry a node fires

- **WHEN** the hub holds a live job for a stored entry
- **THEN** the entry is listed with the status "Active"

#### Scenario: An entry whose job is dormant

- **WHEN** the hub holds a job for an entry and answers `dormant?: true`
- **THEN** the entry is listed with the status "Dormant"
- **AND** its next fire shows a placeholder rather than a time computed from the cron

#### Scenario: No schedules exist

- **WHEN** no schedule entries are stored
- **THEN** an empty state explains that no schedule has been created

### Requirement: Schedule creation

An operator SHALL be able to create a schedule by supplying a name, cron expression, timezone, and target. The schedule SHALL be created through one call to `Flezha.Service.Schedule.add/2`, which stores the entry and asserts it on the schedule hub. Only a factory whose run is `steps` can be scheduled: the controller refuses a factory its runners announce as `flow`, and the form SHALL offer only steps factories. The target's namespace and factory SHALL be chosen from what the controller reports — the namespaces the bound token can reach, and the factories registered in the chosen namespace — rather than typed from memory, with free text kept only for the case where the controller cannot answer.

#### Scenario: Creating a valid schedule

- **WHEN** an operator submits a valid name, cron expression, timezone, and a steps factory as target
- **THEN** `Service.Schedule.add/2` is called once with those fields
- **AND** the entry appears in the list with the status "Active" and its next fire

#### Scenario: Choosing the target namespace

- **WHEN** an operator opens the schedule form
- **THEN** the namespace field offers the namespaces the bound token can reach

#### Scenario: Choosing the target factory

- **WHEN** an operator has chosen a namespace
- **THEN** the factory field offers that namespace's registered factories whose run is `steps`
- **AND** a factory no runner currently serves is marked as such

#### Scenario: A flow factory is refused

- **WHEN** a typed factory turns out to run as `flow` and the controller refuses it with `relay.factory_not_steps`
- **THEN** the error's message is displayed on the form
- **AND** nothing is stored

#### Scenario: The chosen namespace changes

- **WHEN** an operator changes the namespace after choosing a factory
- **THEN** the factory field offers the new namespace's factories

#### Scenario: The controller cannot report namespaces or factories

- **WHEN** the controller is unreachable or refuses the listing
- **THEN** the namespace and factory fields accept a typed value
- **AND** the form can still be submitted

#### Scenario: The cron expression is invalid

- **WHEN** the controller refuses the cron expression
- **THEN** the error's message is displayed on the form
- **AND** nothing is stored

#### Scenario: The timezone is invalid

- **WHEN** the controller refuses the timezone with `schedule.invalid_timezone`
- **THEN** the error's message is displayed on the form
- **AND** nothing is stored

#### Scenario: The name is already taken

- **WHEN** the controller refuses the entry with `schedule.already_exists`
- **THEN** the conflict is reported and the existing entry is left unchanged

### Requirement: Schedule removal

Removing a schedule SHALL retract it from the hub and delete the persisted entry, and SHALL require an explicit confirmation step.

#### Scenario: Removing a schedule

- **WHEN** an operator confirms removing a schedule
- **THEN** it is retracted from the hub and deleted from the store
- **AND** it leaves the list

#### Scenario: Removal is not confirmed

- **WHEN** an operator dismisses the removal confirmation
- **THEN** the schedule remains listed with the status "Active"

### Requirement: A schedule is run now on request

Each schedule row SHALL offer a control that fires the schedule once, immediately, through `Flezha.Service.Schedule.run/2`, independent of its cron expression and of whether the schedule hub is up. On `spawned` the UI SHALL name the started relay and link to it; on `already_running` it SHALL say that an instance is already running and that none was started.

#### Scenario: Running a schedule now

- **WHEN** an operator runs a schedule now
- **THEN** `run/2` is called with the schedule's name
- **AND** the started relay's id is shown with a link to its detail screen

#### Scenario: An instance is already running

- **WHEN** `run/2` answers `already_running`
- **THEN** the UI says no new instance was started because one is running

#### Scenario: The run is refused

- **WHEN** the controller refuses the run
- **THEN** the error is shown with its code and hint
- **AND** no relay is named as started

