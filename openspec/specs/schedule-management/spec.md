# schedule-management Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Schedule listing with live status

The UI SHALL list schedule entries from `Flezha.Service.Schedule.list/1`, which answers each stored entry with its name, cron expression, timezone, and target joined with what the schedule hub holds for it: the node that fires it, its last fire, and its next fire. The same LiveView SHALL additionally serve a namespace-scoped listing at `/namespaces/:ns/schedules`, filtering on the namespace each entry already carries. Because the controller keeps one schedule registry for the whole cluster and answers it whole, the scoped screen SHALL state that its scope is a view filter over the full listing rather than a controller-side scope.

#### Scenario: Schedules exist

- **WHEN** an operator opens the schedules screen
- **THEN** each entry is listed with its cron expression, timezone, target, the node that fires it, its last fire, and its next fire

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
- **THEN** the entry is listed with an explicit not-armed status rather than a blank status

#### Scenario: No schedules exist

- **WHEN** no schedule entries are stored
- **THEN** an empty state explains that no schedule has been created

### Requirement: Schedule creation

An operator SHALL be able to create a schedule by supplying a name, cron expression, timezone, and target. The schedule SHALL be created through one call to `Flezha.Service.Schedule.add/2`, which stores the entry and asserts it on the schedule hub. Only a factory whose run is `steps` can be scheduled: the controller refuses a factory its runners announce as `flow`, and the form SHALL offer only steps factories. The target's namespace and factory SHALL be chosen from what the controller reports — the namespaces the bound token can reach, and the factories registered in the chosen namespace — rather than typed from memory, with free text kept only for the case where the controller cannot answer.

#### Scenario: Creating a valid schedule

- **WHEN** an operator submits a valid name, cron expression, timezone, and a steps factory as target
- **THEN** `Service.Schedule.add/2` is called once with those fields
- **AND** the entry appears in the list with an armed status and its next fire

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
- **THEN** the schedule remains armed and listed

