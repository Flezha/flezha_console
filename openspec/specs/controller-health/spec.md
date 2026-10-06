# controller-health Specification

## Purpose
TBD - created by archiving change resync-with-flezha-platform. Update Purpose after archive.
## Requirements
### Requirement: Durability posture is visible

The controller screen SHALL show the configured backend, the posture, the count of RPO breaches and the count of superseded shipments from one read of `Flezha.Service.Controller.status/1`, and the breached references from `durability_breaches/1`, each called with the UI's caller context.

#### Scenario: The remote tier is enabled

- **WHEN** the posture is `:remote_tier`
- **THEN** the backend, breach count, and superseded count are shown

#### Scenario: The controller is local-only

- **WHEN** the posture is `:local_only`
- **THEN** the screen states that durable state has exactly one copy
- **AND** it is presented as a stated posture, not as an alarm

#### Scenario: References are past their RPO target

- **WHEN** `durability_breaches/1` answers a non-empty list
- **THEN** the breached references are listed with how far past target they are

#### Scenario: A durability read is refused

- **WHEN** the status read answers `{:error, %Flezha.Error{class: :denied}}`
- **THEN** the durability panel states the refusal with its code and message
- **AND** the rest of the screen still renders

### Requirement: Shutdown and boot status

The controller screen SHALL show the shutdown state `Flezha.Service.Controller.status/1` carries — whether a shutdown is in progress, its phase, the signal handler status, and the graceful-shutdown setting and timeout — and the controller's boot status from `Flezha.Service.Controller.boot_status/1`: the readiness verdict and each running namespace's hub recovery state.

#### Scenario: The controller is running normally

- **WHEN** no shutdown is in progress
- **THEN** the screen states so and shows the graceful-shutdown configuration

#### Scenario: A shutdown is in progress

- **WHEN** a shutdown is under way
- **THEN** the current phase is shown and refreshes on the tick

#### Scenario: Boot status is shown per namespace

- **WHEN** `boot_status/1` answers a readiness verdict and a list of namespaces
- **THEN** the screen shows the verdict and, for each namespace, its recovery state

#### Scenario: A namespace's recovery state is unknown

- **WHEN** a namespace row in `boot_status/1` carries the recovery state `:unknown`
- **THEN** that namespace is shown as unknown rather than as serving

#### Scenario: The coordinator cannot be reached

- **WHEN** the shutdown status call fails or is refused
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

The controller screen SHALL offer a memory snapshot — top processes, ETS tables, DETS files, and the allocator breakdown — read from `Flezha.Service.Controller.mem_top/1`, and SHALL take it only when an operator asks for it, never on the refresh tick.

#### Scenario: An operator requests a snapshot

- **WHEN** an operator triggers the memory snapshot
- **THEN** the hot spots are rendered with the time the snapshot was taken

#### Scenario: The screen ticks without a request

- **WHEN** the refresh timer fires and no snapshot was requested
- **THEN** no `mem_top/1` call is made

#### Scenario: A stale snapshot is labelled

- **WHEN** a previously taken snapshot is still on screen after subsequent ticks
- **THEN** its capture time is shown so it is not mistaken for live data

#### Scenario: The snapshot is refused

- **WHEN** `mem_top/1` answers `{:error, %Flezha.Error{class: :denied}}`
- **THEN** the panel states the refusal and no snapshot is rendered

