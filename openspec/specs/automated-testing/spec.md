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

Every browser test that creates controller state — a relay, a plugin enabled or bound, a schedule, a namespace, a token, a role binding — SHALL remove it before finishing, and SHALL use an identifier unique to the run so a leftover from a failed run cannot collide. A plugin a test enabled and bound SHALL be unbound from its relay before it is disabled, because a disabled plugin keeps its bindings.

#### Scenario: A test that starts a relay

- **WHEN** a relay-lifecycle test finishes
- **THEN** every relay it started has been stopped
- **AND** the relay count is what it was before the test

#### Scenario: A test that enables a plugin

- **WHEN** a plugin test finishes
- **THEN** every plugin it enabled has been disabled and every binding it made has been removed

#### Scenario: A bound plugin is cleaned up

- **WHEN** a test cleans up a plugin it bound to a relay
- **THEN** the binding is removed from the relay before the plugin is disabled
- **AND** the relay's binding list is what it was before the test

#### Scenario: A test that creates a schedule

- **WHEN** a schedule test finishes
- **THEN** the schedule it created has been removed, so no cron job keeps firing against the dev controller

#### Scenario: A test that administers access

- **WHEN** a test issues a token, binds a role or creates a namespace
- **THEN** the token is revoked, the role binding removed and the namespace deleted before it finishes

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

### Requirement: Every browser test fails on a broken page

The browser suite SHALL arm every test with page-health guards, without the test
opting in. A test SHALL fail when the page under it raised an uncaught script error
or logged a console error, when a LiveView on it crashed, errored or lost its
socket, or when a request it made was answered with a status of 400 or above or
never answered — regardless of what that test set out to assert. Exemptions SHALL
be listed individually, each carrying the reason it is exempt; a blanket
suppression of an error class SHALL NOT be used.

#### Scenario: A screen throws while rendering

- **WHEN** a test drives a screen whose client-side code throws an uncaught error
- **THEN** that test fails and the run reports the error and the URL it happened on
- **AND** it fails even if every assertion the test wrote passed

#### Scenario: A LiveView crashes and re-joins

- **WHEN** a LiveView crashes during a test and Phoenix re-joins it
- **THEN** the test fails and names the crash
- **AND** the re-joined page rendering correctly at the end of the test does not mask it

#### Scenario: A request fails

- **WHEN** a document, script, stylesheet, image, font, XHR or fetch request made during a test is answered with a status of 400 or above, or never arrives
- **THEN** the test fails and the run reports the URL and the status or failure

#### Scenario: A message is exempted

- **WHEN** a console message or request failure is exempted
- **THEN** its exemption entry states why it is benign
- **AND** an entry without a reason fails the suite

### Requirement: Controller-fed figures are asserted to advance

A figure the console derives from live controller data SHALL be asserted to grow
between two reads within a bounded window. This covers the listen count, a tap's
message and byte rates, pipeline flow rates, sparkline samples, the periodic
refresh, and every live feed the console shows — including the relay lifecycle
feed and the audit and observability tails. Where a figure counts discrete events,
the test SHALL cause those events itself through the console's own controls and
assert the figure grew by them; where a figure is a rate over time, the dev stack's
seeded traffic SHALL feed it. An assertion that such a figure exists, carries a
unit or matches a digit pattern SHALL NOT stand alone, because a frozen feed
satisfies it.

#### Scenario: A feed is dead

- **WHEN** a live figure stays at its initial value while traffic is flowing
- **THEN** the test asserting that figure fails and names the figure that did not move

#### Scenario: The test causes the traffic

- **WHEN** a test sends to a relay, starts or stops a relay, runs a schedule now, or performs an audited administration action through the console
- **THEN** it asserts the figure or feed that reports that event grew to include it

#### Scenario: A feed is live

- **WHEN** a live figure grows within the window
- **THEN** the assertion passes as soon as it grows, without waiting out the window

#### Scenario: Waiting for the figure

- **WHEN** a test waits for a figure to advance
- **THEN** it polls the condition within a window longer than two seeded traffic intervals, defined in one place
- **AND** it contains no fixed-duration sleep

#### Scenario: A figure the dev stack cannot move

- **WHEN** a figure cannot be made to advance by a healthy dev stack or by the console's own controls
- **THEN** the assertion lives in ExUnit against the fake controller
- **AND** no browser test reports success for a figure it did not observe move

### Requirement: The seeded traffic is a named precondition

The suite SHALL assert, in a test of its own, that the dev stack's seeded source
traffic is bound to the seeded relays and flowing. That test SHALL fail by name when
the traffic is absent, so a stack that produces no records is distinguishable from a
console that does not display them.

#### Scenario: The stack is not producing traffic

- **WHEN** the seeded source plugins are not bound or deliver nothing
- **THEN** the precondition test fails and names the missing traffic
- **AND** its failure identifies the stack rather than the console

### Requirement: Every route and every control is driven by a named test

Every route SHALL be reached by at least one test: every route the router serves to
an authenticated user, plus the login, registration, account settings and logout
paths. Every interactive control on those screens — button, link, toggle, filter,
picker, form field, dialog, keyboard shortcut — SHALL be driven by a test that
asserts the effect of driving it, not merely that it is visible. A control's test
SHALL name the control, so a broken control fails under its own name.

#### Scenario: A control stops working

- **WHEN** a control no longer has an effect — a button that opens nothing, a filter that does not filter, a link that does not navigate
- **THEN** a test fails and names that control
- **AND** the other controls on the screen still pass

#### Scenario: A link is followed

- **WHEN** a test drives a link, breadcrumb, palette entry or row action that navigates
- **THEN** it asserts the destination route was reached and rendered its own content

#### Scenario: A filter, toggle or picker is driven

- **WHEN** a test drives a control that changes what a screen shows
- **THEN** it asserts the shown rows or values changed accordingly
- **AND** asserting only that the control accepted the interaction does not satisfy this

#### Scenario: The pipeline graph on a relay the test started

- **WHEN** a test starts a relay of its own with a run-unique id and opens its detail screen
- **THEN** it asserts the pipeline graph draws for that relay, before and after a plugin is bound to it
- **AND** the relay is stopped when the test ends, whatever its outcome

### Requirement: Stopping the controller stops at its confirmation

The browser suite SHALL drive the controller's stop up to its typed confirmation and
cancel there, asserting the controller is still serving, because a confirmed stop
ends the dev stack for every other test and session. The confirmed stop SHALL be
asserted in ExUnit against the fake controller.

#### Scenario: Stopping the controller in the browser

- **WHEN** a browser test opens the controller's stop dialog
- **THEN** it asserts the confirm control stays disabled until the exact confirmation is typed
- **AND** it cancels, and asserts the controller is still serving and no shutdown phase is shown

#### Scenario: The confirmed stop

- **WHEN** an ExUnit test confirms the controller stop against the fake controller
- **THEN** it asserts the call the console made and the progress and shutdown phase the screen shows

### Requirement: Dialogs are driven through both their confirm and cancel paths

Every modal or confirmation dialog SHALL be opened, asserted, and closed by each of
its paths in a test. The cancel path SHALL assert that what the dialog would have
changed is unchanged. The confirm path SHALL assert the change took effect on the
screen behind the dialog.

#### Scenario: A dialog cannot be dismissed

- **WHEN** a dialog's cancel or close control no longer closes it
- **THEN** a test fails and names that dialog

#### Scenario: Cancelling does not act

- **WHEN** a test cancels out of a destructive confirmation — stopping a relay, unbinding or disabling a plugin, dropping a dead letter, removing a schedule, deleting a namespace, revoking a token
- **THEN** it asserts the target still exists and its state is unchanged

#### Scenario: Confirming acts

- **WHEN** a test confirms a dialog
- **THEN** it asserts the resulting change is visible on the screen behind the dialog

### Requirement: Forms are driven with input they must accept and input they must reject

Every form SHALL have a test that submits input it must accept and asserts the
result, and a test that submits input it must reject and asserts the rejection is
shown to the operator. Where the controller refuses with an error carrying a hint,
the test SHALL assert the hint is shown. A form that discards a bad submission
without saying so SHALL fail its test.

#### Scenario: Valid input

- **WHEN** a test submits a form with input the form must accept
- **THEN** it asserts the action took effect and the operator was told it did

#### Scenario: Invalid input

- **WHEN** a test submits a form with input the form or the controller must reject
- **THEN** it asserts an error is shown identifying what was wrong
- **AND** it asserts no change was made

#### Scenario: A form silently drops a submission

- **WHEN** a form neither acts on a submission nor reports why
- **THEN** the test for that form fails

### Requirement: Coverage of controls and events is checked against lib at run time

An ExUnit test SHALL read `lib/` each time it runs, collect every test id and every
LiveView event there, and fail naming each one that no browser spec under `e2e/`
and no ExUnit test under `test/` drives. Test ids SHALL be read from both
`data-testid` and component `testid` attributes; an interpolated id SHALL count by
its literal prefix. Events SHALL be read from literal `handle_event/3` clauses and
from event lists a module dispatches through a guard. The test SHALL also fail when
markup binds a literal event name that no clause handles. The set it checks SHALL
come from `lib/` itself, not from a hand-maintained list. Exemptions SHALL be listed
individually with a reason, and an exemption without a reason SHALL fail the check.

#### Scenario: New UI arrives untested

- **WHEN** a control or an event is added to `lib/` and no test drives it
- **THEN** `mix test` fails and names the identifier and the file it is in

#### Scenario: Coverage sits in the other layer

- **WHEN** an event is driven by an ExUnit test rather than a browser spec
- **THEN** the check counts it as covered
- **AND** it does not require a browser test that would have to branch on discovered state

#### Scenario: A button that does nothing

- **WHEN** markup binds a `phx-click`, `phx-submit` or `phx-change` to a literal event name that no `handle_event/3` clause or dispatched event list handles
- **THEN** the check fails and names the binding and its file

#### Scenario: The check needs no running stack

- **WHEN** a developer runs `mix test` with no dev stack up
- **THEN** the coverage check runs and reports its result

