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

Every browser test that creates controller state — a relay, a plugin enabled or bound, a schedule — SHALL remove it before finishing, and SHALL use an identifier unique to the run so a leftover from a failed run cannot collide.

#### Scenario: A test that starts a relay

- **WHEN** a relay-lifecycle test finishes
- **THEN** every relay it started has been stopped
- **AND** the relay count is what it was before the test

#### Scenario: A test that enables a plugin

- **WHEN** a plugin test finishes
- **THEN** every plugin it enabled has been disabled and every binding it made has been removed

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

Each LiveView the router serves SHALL have an ExUnit test module using `Phoenix.LiveViewTest`. Coverage SHALL include the screen's rendered content, its events, and the error states `NodeManager` can return: a refusal, another `%Flezha.Error{}` failure, a missing controller function, a timeout, and no connected controller.

#### Scenario: A screen renders against a controller that answers

- **WHEN** a LiveView test mounts a screen with the fake controller returning data
- **THEN** the rendered HTML contains that data

#### Scenario: A screen handles a controller that refuses

- **WHEN** the fake controller answers `{:error, %Flezha.Error{class: :denied}}` for a call the screen makes
- **THEN** the screen renders its refusal state, naming the error's code, rather than crashing

#### Scenario: A screen handles another controller failure

- **WHEN** the fake controller answers `{:error, %Flezha.Error{}}` with a class other than `:denied`
- **THEN** the screen renders its error state with the error's message rather than crashing

#### Scenario: A screen handles no controller at all

- **WHEN** no controller node is connected
- **THEN** the screen renders its disconnected state and names the condition

### Requirement: The fake controller stands in by name

ExUnit's fake controller SHALL be compiled only under `MIX_ENV=test`, SHALL be loaded onto the peer node rather than into the test VM, and SHALL mirror the controller's published consumer API: every stand-in module SHALL be a module on core's published surface (`Flezha.Service.*`) or one of the two context-free reads (`Flezha.AuthZ.TokenStore.verify/1`, `Flezha.AuthZ.enforcement_posture/0`), plus a `Flezha.Error` struct carrying `code`, `class`, `message`, `details` and `hint`. Every stub SHALL carry the published function's name and arity, take the caller context last, and answer in the real return shapes — `{:ok, value}` or `:ok` on success and `{:error, %Flezha.Error{}}` with a code from core's error catalogue on failure. Tests SHALL reach the controller through `NodeManager` and its `:erpc` transport, not around it.

#### Scenario: A screen's controller calls are served

- **WHEN** a LiveView test drives a screen that calls the controller
- **THEN** the call travels through `NodeManager.erpc_call/4` to the peer and is answered by the fake

#### Scenario: The fake holds only published names

- **WHEN** the modules in `FakeController.modules/0` and the functions they export are compared with core's `docs/api/consumers/published.txt` and the two context-free reads
- **THEN** every stub is on that list
- **AND** no stand-in remains for a retired module such as `Flezha.Service.EventManager`, `Flezha.Service.HubManager`, `Flezha.Service.CliManager` or a top-level `Flezha` function

#### Scenario: Stubs record the caller context

- **WHEN** a test reads back the calls the fake received
- **THEN** each recorded call carries the caller context as its last argument, with `source: :ui`

#### Scenario: Refusals have the real shape

- **WHEN** a test configures the fake to refuse a call
- **THEN** the fake answers `{:error, %Flezha.Error{}}` whose `code` and `class` are those core's catalogue gives that code

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

### Requirement: A naming gate holds the retired vocabulary out of the tree

One ExUnit test SHALL read every file `git ls-files` lists and SHALL fail on any occurrence of a retired name, reporting each as file, line and the current term to use instead. The gate SHALL replace the scattered per-name absence checks; no other test SHALL assert the absence of a retired name. It SHALL skip `deps/`, `node_modules/`, binary files and `LICENSE`, and SHALL exclude `openspec/changes/` — the archive there is history, and the directory is not tracked. The banned names SHALL include at least:

- `operative` in any spelling or case (not `cooperative`), which also covers `max_operatives`, `max_entities_per_operative`, `operative_*` provider ids and `on_operative_init`;
- the tasklet sense of procedure: `procedure`, `procedure_id`, `ProcJournal`, `ProcInbox`, `proc_journal`, `proc_inbox` (not `:proc_lib` or `/proc`);
- `entity`, `entities`, `entity_key` (not `identity`);
- the retired kinds: the atoms `:stream`, `:workflow`, `:bounded`, `:unbounded`, a `kind:` naming one of them, and `workflow`;
- the authz role spelled `:operator` or `"operator"` (the word operator for the person using the console stays allowed);
- `EventRelay`, `compute_engine`, `processor`, `response()`, and `io_listen` as a whole word (core's current `io_listener` plugin name stays allowed);
- the I/O tap's old name in module and file names: `StreamLive`, `stream_live`, `StreamBridge`, `stream_bridge`;
- `sink` naming the topology graph's output node (observability sinks stay allowed);
- the stylebook's retired path `flezha-stylebook`.

The gate SHALL skip its own test file, which must name every banned term, and SHALL skip a living spec under `openspec/specs/` while a change on disk under `openspec/changes/` (outside the archive) carries a delta for that capability; once that change is archived the spec is judged like any other file. Each permitted occurrence of a banned name SHALL be listed in the gate's allowlist by path and text with the reason it stays. An allowlist entry that no longer matches anything SHALL fail the gate, so the list cannot outlive what it excuses.

#### Scenario: A retired name is introduced

- **WHEN** a tracked file outside the allowlist gains the word `operative`
- **THEN** `mix test` fails and the report names the file, the line and the term `relay`

#### Scenario: The current vocabulary passes

- **WHEN** the gate runs over the tree after this change
- **THEN** it passes with no unexplained occurrence

#### Scenario: Allowed words are not flagged

- **WHEN** a tracked file uses `cooperative`, `identity`, the word operator for a person, an observability sink, or a Phoenix LiveView stream, or `io_listener`
- **THEN** the gate does not report it

#### Scenario: An allowlisted occurrence

- **WHEN** a tracked file outside the console's own vocabulary, such as OpenSpec tooling text under `.claude/`, uses a banned word in its generic English sense
- **THEN** it passes only because an allowlist entry names that path and text with a reason

#### Scenario: A stale allowlist entry

- **WHEN** the text an allowlist entry excuses is removed from its file
- **THEN** the gate fails and names the entry to delete

#### Scenario: A spec with a pending delta

- **WHEN** a living spec still uses a retired name and an unarchived change on disk carries a delta for that capability
- **THEN** the gate does not report the spec
- **AND** once that change is archived the gate judges the merged spec

#### Scenario: History is excluded

- **WHEN** a file under `openspec/changes/archive/` contains a retired name
- **THEN** the gate does not report it

#### Scenario: The old absence check is gone

- **WHEN** `test/` is searched for a test that refutes `compute_engine` outside the gate
- **THEN** no such test exists

### Requirement: Core's record of the console's calls is kept in step

Every change that alters which controller functions the console calls SHALL regenerate core's `docs/api/consumers/flezha_ui.txt` from this checkout with core's `scripts/consumer_surface.py`, and core's `test/flezha/api/consumer_surface_test.exs` SHALL pass with `FLEZHA_UI_PATH` pointing at this checkout. Once the console calls only the published surface, that test's list of calls known not to resolve SHALL be empty, and the test SHALL assert that every recorded console call is on the published surface or is one of the two context-free reads.

#### Scenario: The record matches the console

- **WHEN** core's consumer-surface test runs with `FLEZHA_UI_PATH` set to this checkout
- **THEN** the regenerated call set equals the recorded `flezha_ui.txt` and the test passes

#### Scenario: No call is recorded as broken

- **WHEN** the consumer-surface test's record of unresolved calls is read
- **THEN** it is empty

#### Scenario: Every console call is published

- **WHEN** the recorded console calls are compared with `docs/api/consumers/published.txt`
- **THEN** each is on the published surface or is `Flezha.AuthZ.TokenStore.verify/1` or `Flezha.AuthZ.enforcement_posture/0`

