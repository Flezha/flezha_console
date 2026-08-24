# dev-environment Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: The dev stack builds against current flezha

`docker-compose.dev.yml` SHALL build the controller service from `flezha/docker/dev/Dockerfile.toolchain` and SHALL NOT reference any deleted path, image, or binary.

#### Scenario: Building the dev stack

- **WHEN** an operator runs `docker compose -f docker-compose.dev.yml build`
- **THEN** every service builds with no missing-file error

#### Scenario: No stale references remain

- **WHEN** the compose file is searched for `Dockerfile.agent` or `rust_compute_engine`
- **THEN** no occurrence exists

### Requirement: The runner runs as its own service

The Rust runner SHALL run as a dedicated compose service that waits for the controller's control socket before starting, mirroring the topology in flezha's own dev compose. It SHALL NOT be launched through the controller, whose port owner dying would take the runner with it.

#### Scenario: Runner registers once the controller is up

- **WHEN** the stack starts
- **THEN** the runner waits for the control socket, connects, and its factories become listable

#### Scenario: Runner survives a controller restart

- **WHEN** the controller container restarts
- **THEN** the runner process stays up and reconnects on its own

### Requirement: One command brings up the whole stack

`docker compose -f docker-compose.dev.yml up` SHALL start the controller, the UI, the database, and Kafka, and the UI SHALL connect to the controller node with no manual step.

#### Scenario: Cold start

- **WHEN** an operator brings the stack up from a clean state
- **THEN** the UI reaches the controller node and the dashboard reports a connected controller

#### Scenario: Controller restarts

- **WHEN** the controller container restarts
- **THEN** the UI reconnects on its own and screens recover

### Requirement: Dev seeding populates the dashboard

In the dev environment the UI SHALL seed testnet operatives and plugins on boot using the current operative and plugin APIs, and the seeding SHALL be idempotent.

#### Scenario: First boot

- **WHEN** the stack starts against an empty controller
- **THEN** the seeded operatives and plugins exist and the dashboard is populated

#### Scenario: Repeated boot

- **WHEN** the UI restarts against a controller that is already seeded
- **THEN** nothing is duplicated and no error is reported

#### Scenario: The controller is not yet reachable

- **WHEN** seeding runs before the controller accepts calls
- **THEN** it retries rather than crashing the UI application

#### Scenario: Seeding is dev-only

- **WHEN** the application runs outside the dev environment
- **THEN** no seeding is attempted

### Requirement: The dev stack claims its own authorization bootstrap

The dev stack SHALL leave authorization enforced and SHALL claim its own bootstrap: after the controller's control socket is up, a one-shot step claims the bootstrap, issues a `_system` token, and makes it available to the UI container as `FLEZHA_TOKEN`. The stack SHALL NOT set `FLEZHA_AUTHZ_ENABLED=false`, because a dev environment that skips enforcement leaves the UI's whole identity path untested.

#### Scenario: Cold start with authorization enforced

- **WHEN** an operator brings the stack up from a clean state
- **THEN** the bootstrap is claimed, a token is issued, and the UI's posture banner shows `enforced` with a bound principal

#### Scenario: The bootstrap is already claimed

- **WHEN** the stack restarts against a controller whose bootstrap was claimed on a previous run
- **THEN** the step reuses the existing token and reports success
- **AND** nothing is re-claimed

#### Scenario: The opt-out is not used

- **WHEN** the compose file is searched for `FLEZHA_AUTHZ_ENABLED`
- **THEN** it is either absent or set to a value that keeps enforcement on

#### Scenario: The controller's transport credentials are provisioned

- **WHEN** the stack starts
- **THEN** the distribution cookie and the certificates the controller now requires are provisioned by the stack
- **AND** no service fails to start for want of them

### Requirement: A dev namespace is declared, not merely running

Dev seeding SHALL declare its namespace through the controller's namespace store with quotas set, so the namespace administration screens have real data on a fresh stack rather than only a running hub with no declaration.

#### Scenario: First boot

- **WHEN** the stack starts against an empty controller
- **THEN** the seeded namespace exists as a declared namespace with quotas
- **AND** the namespace screen shows quota meters rather than an unset state

#### Scenario: Repeated boot

- **WHEN** the UI restarts against a controller whose namespace is already declared
- **THEN** the declaration is left alone and no error is reported

### Requirement: Dev seeding covers both operative kinds

Dev seeding SHALL start at least one stream operative and one workflow instance, so the workflow panels, the journal view, and the finished-instance listing are populated on a fresh stack.

#### Scenario: First boot seeds both kinds

- **WHEN** the stack starts against an empty controller
- **THEN** at least one `:stream` operative and one `:workflow` instance are running

#### Scenario: A workflow instance completes

- **WHEN** a seeded workflow instance runs to completion
- **THEN** it appears in the finished-instance listing within its retention window

