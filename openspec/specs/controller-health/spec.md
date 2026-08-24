# controller-health Specification

## Purpose
TBD - created by archiving change resync-with-flezha-platform. Update Purpose after archive.
## Requirements
### Requirement: Durability posture is visible

The controller screen SHALL show the configured backend from `Flezha.State.DurabilityTier.configured_backend/0`, the posture from `posture/0`, the count of RPO breaches from `breaches/0`, and the count of superseded shipments from `status/0`.

#### Scenario: The remote tier is enabled

- **WHEN** the posture is `:remote_tier`
- **THEN** the backend, breach count, and superseded count are shown

#### Scenario: The controller is local-only

- **WHEN** the posture is `:local_only`
- **THEN** the screen states that durable state has exactly one copy
- **AND** it is presented as a stated posture, not as an alarm

#### Scenario: References are past their RPO target

- **WHEN** `breaches/0` answers a non-empty list
- **THEN** the breached references are listed with how far past target they are

### Requirement: Shutdown and boot status

The controller screen SHALL show `Flezha.Shutdown.Coordinator.status/0` — whether a shutdown is in progress, its phase, the signal handler status, and the graceful-shutdown setting and timeout — and the controller's boot status.

#### Scenario: The controller is running normally

- **WHEN** no shutdown is in progress
- **THEN** the screen states so and shows the graceful-shutdown configuration

#### Scenario: A shutdown is in progress

- **WHEN** a shutdown is under way
- **THEN** the current phase is shown and refreshes on the tick

#### Scenario: The coordinator cannot be reached

- **WHEN** the status call fails
- **THEN** the panel states that shutdown status is unavailable and the rest of the screen still renders

### Requirement: Authorization configuration is auditable from the UI

The controller screen SHALL state the authorization posture, and when the posture is `:open` SHALL state that authorization is disabled.

#### Scenario: Authorization is enforced

- **WHEN** the posture is `:enforced`
- **THEN** the screen states that authorization is enforced

#### Scenario: Authorization is switched off

- **WHEN** the posture is `:open`
- **THEN** the screen states that authorization is disabled on this controller

### Requirement: Memory hot spots are operator-triggered

The controller screen SHALL offer a memory snapshot — top processes, ETS tables, DETS files, and the allocator breakdown — and SHALL take it only when an operator asks for it, never on the refresh tick.

#### Scenario: An operator requests a snapshot

- **WHEN** an operator triggers the memory snapshot
- **THEN** the hot spots are rendered with the time the snapshot was taken

#### Scenario: The screen ticks without a request

- **WHEN** the refresh timer fires and no snapshot was requested
- **THEN** no memory snapshot call is made

#### Scenario: A stale snapshot is labelled

- **WHEN** a previously taken snapshot is still on screen after subsequent ticks
- **THEN** its capture time is shown so it is not mistaken for live data

