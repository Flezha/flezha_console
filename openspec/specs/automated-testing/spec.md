# automated-testing Specification

## Purpose
How this project is tested. There are two layers — ExUnit for everything that runs
inside the BEAM, and a Playwright browser suite for journeys that need a real
browser — and an assertion belongs to whichever layer can *produce* the state it
asserts. The requirements below exist so that a green run means the assertions
actually ran, rather than that they were skipped over a state the environment
would not supply.

## Requirements

### Requirement: Two test layers with a decided split

The project SHALL test itself at exactly two layers: ExUnit for everything that runs inside the BEAM, and a browser suite for journeys that require a real browser. An assertion SHALL live at the layer that can produce the state it asserts. Coverage SHALL NOT be duplicated across both layers merely because it is possible at both.

#### Scenario: A state the running dev stack cannot be forced into

- **WHEN** an assertion depends on a controller state a healthy dev stack refuses to produce — an empty or populated dead-letter queue on demand, audit logging switched off, a disconnected controller, a version-skewed controller API
- **THEN** that assertion lives in ExUnit against the fake controller
- **AND** no browser test asserts it

#### Scenario: Behaviour that only a browser can observe

- **WHEN** an assertion depends on client-side behaviour — a `phx-click` binding firing, a modal being visible and clickable, a JS hook running, navigation between screens
- **THEN** that assertion lives in the browser suite

#### Scenario: Both layers are runnable from a clean checkout

- **WHEN** a developer runs the documented ExUnit command and the documented browser-suite command
- **THEN** each reports its own result independently, and neither requires the other to have run

### Requirement: Playwright is the browser test runner

Browser tests SHALL be written with `@playwright/test`. Specs SHALL live under `e2e/`, kept distinct from ExUnit's `test/`. The suite SHALL target the running dev stack at `http://localhost:4000`.

#### Scenario: Running the browser suite

- **WHEN** a developer runs the browser-suite npm script against a running dev stack
- **THEN** Playwright executes every spec under `e2e/` and reports pass or fail per test

#### Scenario: A failing test is diagnosable

- **WHEN** a browser test fails
- **THEN** the run captures a screenshot and a trace for that test

#### Scenario: Cypress is gone

- **WHEN** the repository is searched for `cypress`
- **THEN** no spec, config file, npm script, or dependency refers to it

### Requirement: Browser tests do not branch on discovered state

A browser test SHALL assert unconditionally. It SHALL NOT inspect the page to decide whether to run its assertions, and SHALL NOT report success for a code path it did not execute. Where a test cannot run against the dev stack at all, it SHALL be a named skip carrying the reason, not a silent pass.

#### Scenario: A precondition the stack does not meet

- **WHEN** a browser test's precondition is absent — no connected runner, audit logging disabled
- **THEN** the test fails and names the missing precondition
- **AND** it does not log a note and pass

#### Scenario: A case the dev stack genuinely cannot support

- **WHEN** a case cannot run in the dev environment, such as attaching the Kafka provider with no broker present
- **THEN** the test is skipped with an explicit reason visible in the run report

#### Scenario: Waiting for the page to settle

- **WHEN** a test waits for a LiveView update
- **THEN** it waits on the expected condition
- **AND** no test contains a fixed-duration sleep

### Requirement: Each provider attach is its own browser test

The plugin-attach suite SHALL run one test per provider so a provider that breaks fails under its own name. It SHALL NOT collect per-provider outcomes into a summary that passes when only some providers worked.

#### Scenario: One provider regresses

- **WHEN** a single provider can no longer be attached
- **THEN** that provider's test fails and the others still pass
- **AND** the report names the failing provider

#### Scenario: Provider discovery

- **WHEN** the attach modal is opened
- **THEN** the provider grid is non-empty and offers the providers the controller reports

### Requirement: Browser tests leave no state behind

Every browser test that creates controller state — an operative, a plugin binding, a schedule — SHALL remove it before finishing, and SHALL use an identifier unique to the run so a leftover from a failed run cannot collide.

#### Scenario: A test that starts an operative

- **WHEN** an operative-lifecycle test finishes
- **THEN** every operative it started has been stopped
- **AND** the operative count is what it was before the test

#### Scenario: A test that creates a schedule

- **WHEN** a schedule test finishes
- **THEN** the schedule it created has been removed, so no cron job keeps firing against the dev controller

### Requirement: Login is established once per run

The browser suite SHALL authenticate once by driving the real login form, reuse the resulting session across specs, and keep the stored session out of version control. The login form itself SHALL still have a test that exercises it directly.

#### Scenario: Specs that need a logged-in session

- **WHEN** a spec other than the login spec runs
- **THEN** it starts already authenticated without submitting the login form

#### Scenario: The login path is covered

- **WHEN** the login spec runs
- **THEN** it submits the form with the seeded dev credentials and asserts it lands on the dashboard

#### Scenario: The stored session is not committed

- **WHEN** the repository status is inspected after a browser run
- **THEN** the stored session file is ignored by git

### Requirement: Every LiveView has ExUnit coverage

Each LiveView the router serves SHALL have an ExUnit test module using `Phoenix.LiveViewTest`. Coverage SHALL include the screen's rendered content, its events, and the error states `NodeManager` can return.

#### Scenario: A screen renders against a controller that answers

- **WHEN** a LiveView test mounts a screen with the fake controller returning data
- **THEN** the rendered HTML contains that data

#### Scenario: A screen handles a controller that refuses

- **WHEN** the fake controller answers `{:error, reason}` for a call the screen makes
- **THEN** the screen renders its error state rather than crashing

#### Scenario: A screen handles no controller at all

- **WHEN** no controller node is connected
- **THEN** the screen renders its disconnected state and names the condition

### Requirement: The fake controller stands in by name

ExUnit's fake controller SHALL be compiled only under `MIX_ENV=test`, SHALL carry the real controller modules' names so the code under test calls it by name, and SHALL be loaded onto the peer node rather than into the test VM. Tests SHALL reach the controller through `NodeManager` and its `:erpc` transport, not around it.

#### Scenario: A screen's controller calls are served

- **WHEN** a LiveView test drives a screen that calls the controller
- **THEN** the call travels through `NodeManager.erpc_call/4` to the peer and is answered by the fake

#### Scenario: The fake is configurable per test

- **WHEN** a test sets the response the fake should give for a call
- **THEN** that response is used for that test only, and does not leak into the next

#### Scenario: The fake never ships outside test

- **WHEN** the application is compiled in any environment other than `test`
- **THEN** no fake controller module is compiled into the release

### Requirement: Peer-backed tests are isolated and skippable

Tests that boot a peer node SHALL run non-concurrently, SHALL start at most one peer per test module, and SHALL be tagged so they can be excluded from a fast local run.

#### Scenario: Two peer-backed modules in one run

- **WHEN** the suite runs modules that each boot a peer
- **THEN** they do not run concurrently, and neither module's peer is mistaken for the other's controller

#### Scenario: A fast local run

- **WHEN** a developer excludes the peer-backed tag
- **THEN** the remaining suite runs without booting any peer node

### Requirement: Test commands are documented where they are looked for

`README.md` SHALL name the command for each layer, the setup each requires, and the precondition that the dev stack must be running for the browser suite.

#### Scenario: A developer looks up how to run the tests

- **WHEN** `README.md` is read
- **THEN** it gives the ExUnit command, the browser-suite command, the browser-install step, and states that the browser suite needs the dev stack up

#### Scenario: No stale command survives

- **WHEN** the documentation is searched for the removed Cypress commands
- **THEN** no occurrence remains
