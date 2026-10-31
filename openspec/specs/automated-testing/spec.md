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
- **THEN** the run keeps a screenshot and the error context, with the page snapshot, for that test
- **AND** it keeps a trace too when the run was asked for one with `E2E_TRACE=1`, since recording one costs every test

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

Every browser test that creates controller state — a relay, a plugin enabled or bound, a schedule, a namespace, a token, a role binding — SHALL remove it before finishing. It SHALL use an identifier unique to the run, so a leftover from a failed run cannot collide. A plugin a test enabled and bound SHALL be unbound from its relay before it is disabled, because a disabled plugin keeps its bindings.

#### Scenario: A test that starts a relay

- **WHEN** a relay-lifecycle test finishes
- **THEN** every relay it started has been stopped and is no longer listed

#### Scenario: A test that enables a plugin

- **WHEN** a plugin test finishes
- **THEN** every plugin it enabled has been disabled and every binding it made has been removed

#### Scenario: A bound plugin is cleaned up

- **WHEN** a test cleans up a plugin it bound to its own relay
- **THEN** the binding is removed from the relay before the plugin is disabled
- **AND** the binding the test made is no longer listed

#### Scenario: A test that creates a schedule

- **WHEN** a schedule test finishes
- **THEN** the schedule it created has been removed, so no cron job keeps firing against the dev controller

#### Scenario: A test that administers access

- **WHEN** a test issues a token, binds a role or creates a namespace
- **THEN** the token is revoked, the role binding removed and the namespace deleted before it finishes

### Requirement: Login is established once per run

The browser suite SHALL create one console user per worker and authenticate each one once per run, by driving the real login form in global setup. Each worker SHALL reuse its own session across specs. Stored sessions SHALL be kept out of version control. The login form itself SHALL still have a test that exercises it directly.

#### Scenario: Specs that need a logged-in session

- **WHEN** a spec other than the login spec runs
- **THEN** it starts authenticated as its worker's user without submitting the login form

#### Scenario: Per-user state does not cross workers

- **WHEN** one worker stores a flezha token or a remembered namespace for its user
- **THEN** no other worker's screens change

#### Scenario: The login path is covered

- **WHEN** the login spec runs
- **THEN** it submits the form with the seeded dev credentials and asserts it lands on a namespace's Dashboard

#### Scenario: The stored session is not committed

- **WHEN** the repository status is inspected after a browser run
- **THEN** the stored session files are ignored by git

### Requirement: Every LiveView has ExUnit coverage

Each LiveView the router serves SHALL have an ExUnit test module using `Phoenix.LiveViewTest`. That coverage SHALL include:
- the screen's rendered content and its events;
- the error states `NodeManager` can return: a refusal, another `%Flezha.Error{}` failure, a missing controller function, a timeout, a connection lost mid-call, and no connected controller.

An error state a screen handles through a shared mechanic MAY be covered by that mechanic's table-driven test, with the screen as a row.

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

#### Scenario: The connection drops during a call

- **WHEN** the controller node goes away while a call or a stream is in flight
- **THEN** `NodeManager` answers `:node_not_connected` and the screen renders its disconnected state

### Requirement: The fake controller stands in by name

ExUnit's fake controller SHALL be compiled only under `MIX_ENV=test`, SHALL be loaded onto the peer node rather than into the test VM, and SHALL mirror the controller's published consumer API: every stand-in module SHALL be a module on core's published surface (`Flezha.Service.*`), core's door (`Flezha.Service.Admin`, whose `run/4` applies the stand-in an operation names and answers as core's door does, and whose `context/2` is a context-free read), or the context-free `Flezha.AuthZ.enforcement_posture/0`, plus a `Flezha.Error` struct carrying `code`, `class`, `message`, `details` and `hint`. Every stub SHALL carry the published function's name and arity, take the caller context last, and answer in the real return shapes — `{:ok, value}` or `:ok` on success and `{:error, %Flezha.Error{}}` with a code from core's error catalogue on failure. Tests SHALL reach the controller through `NodeManager` and its `:erpc` transport, not around it.

#### Scenario: A screen's controller calls are served

- **WHEN** a LiveView test drives a screen that calls the controller
- **THEN** the call travels through `NodeManager.erpc_call/4` to the peer and is answered by the fake

#### Scenario: The fake holds only published names

- **WHEN** the modules in `FakeController.modules/0` and the functions they export are compared with core's `docs/internal/api/consumers/published.txt`, the door and the two context-free reads
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

Tests that boot a peer node SHALL run non-concurrently. They SHALL boot at most one peer per test module, in the module's shared setup, and SHALL reset the fake controller and the authorization identity cache before each test. Only a test that stops or disconnects its peer SHALL boot its own, and such tests SHALL live in a module of their own. Peer-backed tests SHALL be tagged so they can be excluded from a fast local run.

#### Scenario: Two peer-backed modules in one run

- **WHEN** the suite runs modules that each boot a peer
- **THEN** they do not run concurrently, and neither module's peer is mistaken for the other's controller

#### Scenario: Tests within one peer-backed module

- **WHEN** a module's tests run against the module's peer
- **THEN** each starts with no canned answers, no recorded calls and no cached identity or posture from an earlier test

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

Every change that alters which controller functions the console calls SHALL regenerate core's `docs/internal/api/consumers/flezha_console.txt` from this checkout with core's `scripts/consumer_surface.py`, and core's `test/flezha/api/consumer_surface_test.exs` SHALL pass with `FLEZHA_CONSOLE_PATH` pointing at this checkout. Once the console calls only the published surface, that test's list of calls known not to resolve SHALL be empty, and the test SHALL assert that every recorded console call is on the published surface, is the door `Flezha.Service.Admin.run/4`, or is one of the two context-free reads.

#### Scenario: The record matches the console

- **WHEN** core's consumer-surface test runs with `FLEZHA_CONSOLE_PATH` set to this checkout
- **THEN** the regenerated call set equals the recorded `flezha_console.txt` and the test passes

#### Scenario: No call is recorded as broken

- **WHEN** the consumer-surface test's record of unresolved calls is read
- **THEN** it is empty

#### Scenario: Every console call is published

- **WHEN** the recorded console calls are compared with `docs/internal/api/consumers/published.txt`
- **THEN** each is on the published surface, is `Flezha.Service.Admin.run/4`, or is `Flezha.Service.Admin.context/2` or `Flezha.AuthZ.enforcement_posture/0`

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

A figure the console derives from live controller data SHALL be asserted to grow between two reads. This covers the listen count, a tap's message and byte rates, pipeline flow rates, sparkline samples, the periodic refresh, and every live feed the console shows, including the relay lifecycle feed and the audit and observability tails. The test SHALL cause the events that move the figure itself, through the console's own controls or a CLI call, against state it owns. It SHALL NOT rely on the dev stack's seeded traffic. An assertion that such a figure exists, carries a unit or matches a digit pattern SHALL NOT stand alone, because a frozen feed satisfies it.

#### Scenario: A feed is dead

- **WHEN** a live figure stays at its initial value after the test sent traffic
- **THEN** the test asserting that figure fails and names the figure that did not move

#### Scenario: The test causes the traffic

- **WHEN** a test sends to a relay, starts or stops a relay, runs a schedule now, or performs an audited administration action
- **THEN** it asserts that the figure or feed reporting that event grew to include it

#### Scenario: A rate over time

- **WHEN** a test asserts a rate or a sample series
- **THEN** it sends traffic to its own relay across at least two refresh ticks of the dev stack's configured cadence
- **AND** it waits within the default expectation timeout

#### Scenario: A figure the browser cannot move

- **WHEN** a figure cannot be made to advance by the test's own actions against a healthy dev stack
- **THEN** the assertion lives in ExUnit against the fake controller
- **AND** no browser test reports success for a figure it did not observe move

### Requirement: Every route and every control is driven by a named test

Every route SHALL be reached by at least one test: every route the router serves to an authenticated user, plus the login, registration, account settings and logout paths. Every interactive control on those screens — button, link, toggle, filter, picker, form field, dialog, keyboard shortcut — SHALL be driven through its markup by a test that asserts the effect of driving it, not merely that it is visible. In ExUnit, driving through the markup means `element/2` or `form/2` piped to a render function, or `render_hook/3` for an event a JS hook pushes. A test that pushes an event the markup does not offer SHALL exist only to assert that the server refuses or ignores a forged event, and SHALL say so in its name. A control's test SHALL name the control, so a broken control fails under its own name.

#### Scenario: A control stops working

- **WHEN** a control no longer has an effect — a button that opens nothing, a filter that does not filter, a link that does not navigate
- **THEN** a test fails and names that control
- **AND** the other controls on the screen still pass

#### Scenario: A control is wired to the wrong event

- **WHEN** a button's `phx-click` names a different event, or carries different values, than the test expects
- **THEN** the ExUnit test that clicks it through `element/2` fails

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

The browser suite SHALL drive the controller's stop up to its typed confirmation and cancel there, asserting the controller is still serving, because a confirmed stop ends the dev stack for every other test and session. The confirmed stop SHALL be asserted in ExUnit against the fake controller. Dropping a runner SHALL be treated the same way, because a dropped runner takes every worker's relays with it.

#### Scenario: Stopping the controller in the browser

- **WHEN** a browser test opens the controller's stop dialog
- **THEN** it asserts the confirm control stays disabled until the exact confirmation is typed
- **AND** it cancels, and asserts the controller is still serving and no shutdown phase is shown

#### Scenario: The confirmed stop

- **WHEN** an ExUnit test confirms the controller stop against the fake controller
- **THEN** it asserts the call the console made and the progress and shutdown phase the screen shows

#### Scenario: The confirmed runner drop

- **WHEN** an ExUnit test confirms a runner drop and then readmits it against the fake controller
- **THEN** it asserts the calls the console made, the dropped mark, the refusal shown while dropped, and the mark cleared on readmit

### Requirement: Dialogs are driven through both their confirm and cancel paths

Every modal or confirmation dialog SHALL be opened, asserted, and closed by each of its paths in a test. The cancel path SHALL assert that the controller was not called and that the target is unchanged. This SHALL be asserted for every dialog in one table-driven test. The confirm path SHALL assert the change took effect on the screen behind the dialog.

#### Scenario: A dialog cannot be dismissed

- **WHEN** a dialog's cancel or close control no longer closes it
- **THEN** the table-driven cancel test fails and names that dialog

#### Scenario: Cancelling does not act

- **WHEN** a test cancels out of a destructive confirmation — stopping a relay, unbinding or disabling a plugin, dropping a dead letter, removing a schedule, deleting a namespace, revoking a token, dropping a runner, stopping the controller
- **THEN** it asserts no call reached the controller and the target is still shown unchanged

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

An ExUnit test SHALL read `lib/` each time it runs, collect every LiveView event there, and fail, naming each event that no test drives. An event SHALL count as driven only when:
- an ExUnit test drives it through `element/2` or `form/2` piped to a render function;
- a `render_hook/3` call reaches it; or
- a browser spec under `e2e/` acts on the control bound to it.

An event pushed directly by name SHALL NOT count. Events SHALL be read from literal `handle_event/3` clauses and from event lists a module dispatches through a guard. The test SHALL also fail when markup binds a literal event name that no clause handles. The set it checks SHALL come from `lib/` itself, not from a hand-maintained list. Exemptions SHALL be listed individually with a reason, and an exemption without a reason SHALL fail the check. Naming a test id in a test SHALL NOT count as covering anything.

#### Scenario: New UI arrives untested

- **WHEN** an event is added to `lib/` and no test drives it through its markup
- **THEN** `mix test` fails and names the event and the file it is in

#### Scenario: Coverage sits in the other layer

- **WHEN** an event is driven through its markup by an ExUnit test rather than a browser spec
- **THEN** the check counts it as covered
- **AND** it does not require a browser test that would have to branch on discovered state

#### Scenario: An event pushed past the markup

- **WHEN** the only test reaching an event calls `render_click(view, "event", params)` directly
- **THEN** the check names the event as not driven

#### Scenario: A button that does nothing

- **WHEN** markup binds a `phx-click`, `phx-submit` or `phx-change` to a literal event name that no `handle_event/3` clause or dispatched event list handles
- **THEN** the check fails and names the binding and its file

#### Scenario: The check needs no running stack

- **WHEN** a developer runs `mix test` with no dev stack up
- **THEN** the coverage check runs and reports its result

### Requirement: No test waits on the wall clock

No test in either layer SHALL wait for time to pass. A test SHALL wait only for a condition it caused, and SHALL stop waiting as soon as the condition holds. A test SHALL NOT depend on traffic, ticks or retries it did not cause. A tree gate SHALL fail the ExUnit run naming each file and line that:
- contains a fixed-duration wait: `waitForTimeout`, `setTimeout`, `Process.sleep` or `:timer.sleep`;
- raises a time limit: `test.setTimeout`, `test.slow`, poll `intervals`, or a literal timeout of 5,000 ms or more in `e2e/`;
- uses an `assert_receive` or `refute_receive` timeout of 1,000 ms or more in `test/`.

Each exemption SHALL be listed individually with its reason, and an exemption nothing needs any more SHALL fail the gate.

#### Scenario: A fixed sleep is added

- **WHEN** a test under `test/` or `e2e/` gains `Process.sleep(500)` or `page.waitForTimeout(500)`
- **THEN** `mix test` fails, naming the file, the line and what to do instead

#### Scenario: A long timeout is added to wait out a cadence

- **WHEN** a browser test passes `{ timeout: 12_000 }` to an expectation
- **THEN** the gate fails naming it
- **AND** the run stays red until the test causes the condition itself or an exemption with a reason is added

#### Scenario: Polling a condition the test caused

- **WHEN** a test sends a record and polls for the screen to show it
- **THEN** the poll uses the layer's default timeout and returns as soon as the record shows

#### Scenario: A stale exemption

- **WHEN** an exempted occurrence is removed from the tree but its exemption stays
- **THEN** the gate fails naming the exemption

### Requirement: Each layer runs within a time budget

ExUnit SHALL cap every test at 5 s. The browser suite SHALL cap every test at 20 s, every expectation and action at 5 s, and every navigation at 10 s. A test that cannot meet its cap SHALL be fixed or moved to the layer that can produce its state quickly. The documented budgets SHALL be 90 s for the full ExUnit run and 4 min for the full browser run on the developer machine. The testing guide SHALL state how to list the slowest tests in each layer.

#### Scenario: A test exceeds its cap

- **WHEN** an ExUnit test runs longer than 5 s, or a browser test longer than 20 s
- **THEN** that test fails with a timeout naming it

#### Scenario: Finding what is slow

- **WHEN** a developer wants to know what dominates a run
- **THEN** the testing guide gives the command that lists the slowest tests for each layer

### Requirement: The browser suite runs in parallel workers

The browser suite SHALL run spec files in parallel across workers. The default worker count SHALL be 4, overridable by an environment variable. Tests within one file SHALL run in order in one worker. A test SHALL NOT depend on another file's tests having run, or on their absence.

The suite SHALL be deterministic: on unchanged code, a full run SHALL pass or fail the same way every time. To that end:

- Global setup SHALL hold a lock on the stack for the length of the run, kept in the controller. A second run against a held stack SHALL refuse to start, naming the holder. A lock whose run is no longer running SHALL count as stale and MAY be taken over; a run that is still going SHALL keep the stack however long it lasts.
- Global setup SHALL wait until the controller reports itself ready and every namespace's hub is serving before any test starts, and SHALL fail the run naming what is not ready past a fixed bound.
- A flake check SHALL run the whole suite several times with its normal workers and report every test whose outcome differed between runs or that failed in any run. A browser test that failed in a full run SHALL count as fixed only when the flake check passes; passing alone SHALL NOT count.
- The flake check SHALL be a separate command and SHALL NOT run as part of the normal suite. The measures that keep the suite deterministic SHALL NOT make a normal run slower than its measured baseline by more than 10%.

#### Scenario: Two specs run at once

- **WHEN** two spec files run in different workers against the same stack
- **THEN** neither one's assertions are affected by the other's actions

#### Scenario: A file shares an expensive setup

- **WHEN** a spec file needs several dead letters parked
- **THEN** it parks all of them in one setup step before its tests
- **AND** its tests run in order in one worker

#### Scenario: A second run against a held stack

- **WHEN** a run is in progress on a stack and another run starts against it
- **THEN** the second run stops in global setup, naming the run holding the stack
- **AND** the first run's users stay logged in

#### Scenario: A run right after a controller restart

- **WHEN** the suite starts while the controller is still booting or a hub is recovering
- **THEN** global setup waits until the controller is ready before the first test
- **AND** fails naming what is not ready if that takes longer than its bound

#### Scenario: A test that passes alone but failed in the full run

- **WHEN** a browser test failed in a full run and then passes when run alone
- **THEN** it is not counted as fixed
- **AND** the flake check is run, and the test counts as fixed only when every run passes

#### Scenario: Determinism costs no run time

- **WHEN** the suite's wall time is measured as the median of three runs before and after the deterministic measures
- **THEN** the after median is within 10% of the before median
- **AND** `npm run e2e` does not run the flake check

#### Scenario: Unchanged code, repeated runs

- **WHEN** the flake check runs the suite three times on unchanged code
- **THEN** every test has the same outcome in every run

### Requirement: Browser tests own the state they assert on

A browser test SHALL assert only on state it created or caused: relays it started, plugins bound to its own relay, schedules, namespaces, tokens, records it sent. It SHALL identify that state by run-unique ids, a key, or a pair. It SHALL NOT mutate the dev stack's seeded relays. It SHALL NOT assert a global count equals a value it read earlier. Actions that affect every session on the stack, such as stopping the controller or dropping a runner, SHALL be driven to their confirmation and cancelled in the browser, with the confirmed path asserted in ExUnit.

Each worker SHALL have a namespace of its own, made in global setup and removed when the run ends, and a test that creates namespace-scoped records (tokens, role bindings) SHALL create them there. A test SHALL NOT assert on a value the stack decides rather than the test: a count of runners, nodes, late runners or relays by health; the first row of a listing other workers write to; or a layout that depends on live text. It MAY assert the form of such a value. A test that acts on a row SHALL act on its own row, and SHALL open its menu through the shared row-action helper.

#### Scenario: Another worker starts a relay mid-test

- **WHEN** a test lists relays while another worker starts one
- **THEN** the test still passes, because it asserts that its own relay is or is not listed

#### Scenario: A plugin attach test

- **WHEN** a test binds a plugin
- **THEN** it binds it to a relay that test started, never to a seeded relay

#### Scenario: Dropping a runner in the browser

- **WHEN** a browser test opens a runner's drop dialog
- **THEN** it asserts the dialog's warning and cancels
- **AND** the confirmed drop, the refused process and the readmit are asserted in ExUnit

#### Scenario: Another worker binds a role while a test unbinds one

- **WHEN** a test binds and unbinds a principal while another worker binds principals
- **THEN** the test's bindings live in its worker's namespace, and the other worker's never appear in its listing

#### Scenario: A live figure on a screen

- **WHEN** a test checks the runner summary or a health breakdown on the live stack
- **THEN** it asserts that the figures are shown in their form, such as a number followed by "late"
- **AND** never that they equal a particular number

#### Scenario: Tiles whose text is live

- **WHEN** a test checks that indicator tiles stand level
- **THEN** it compares tiles within one row
- **AND** does not compare rows whose height depends on live text

### Requirement: Test doubles are checked against the real controller

The error catalogue the fake controller uses SHALL equal core's published error catalogue, read from the core checkout the published-surface test already locates. The fake controller's answers for every published read the console makes SHALL have the shape the real controller answers with: the tuple tag, map keys and value types, recursively, never the values. That shape SHALL be checked against a committed file recorded from the dev controller. Every browser run SHALL re-record the shapes and fail, naming each call whose live shape differs from the committed file.

#### Scenario: Core adds or reclassifies an error code

- **WHEN** core's error catalogue gives a code a different class than the fake's
- **THEN** `mix test` fails naming the code and both classes

#### Scenario: A fixture drifts from the real answer

- **WHEN** a fake controller fixture returns a map missing a key the real answer carries
- **THEN** `mix test` fails naming the call and the missing key

#### Scenario: The controller changes an answer's shape

- **WHEN** the dev controller answers a published read in a shape different from the committed recording
- **THEN** the browser run fails in global setup naming the call, before any spec runs

### Requirement: A shared mechanic is tested once

A behaviour that several screens get from one shared module or one shared pattern SHALL be asserted by one table-driven test that iterates its screens. This covers a confirmation's cancel calling nothing, a refused primary read, an empty state, the disconnected screen, a tail closing its stream, and the relay launcher. Each row SHALL fail under its own screen's name. A per-screen copy of that assertion SHALL NOT exist alongside the table.

#### Scenario: A screen breaks its cancel path

- **WHEN** one screen's cancel control starts calling the controller
- **THEN** the table-driven cancel test fails naming that screen and its control

#### Scenario: A new screen with a confirmation

- **WHEN** a screen with a confirmation dialog is added
- **THEN** covering its cancel path takes one new row in the table, not a new test

### Requirement: A test asserts behaviour, not presence

A test SHALL fail when the behaviour it names breaks. These are not tests and SHALL NOT exist:
- a test whose only assertions are that markup, a test id, a CSS class or a label is present;
- a test that reads source files to prove something is absent;
- an assertion that holds for any rendered page;
- a test of a function the application never calls.

#### Scenario: A presence-only test

- **WHEN** a test only asserts that `data-testid="x"` is in the rendered HTML
- **THEN** it is replaced by a test of what the control does, or deleted

#### Scenario: A vacuous assertion

- **WHEN** a test asserts `html =~ "flezha"` on a page whose layout always contains that word
- **THEN** the assertion is replaced by one about the state under test

### Requirement: One testing guide covers both layers

`docs/testing.md` SHALL state:
- the commands for each layer;
- the rule for which layer an assertion belongs to;
- the no-wait rule and how to cause traffic instead;
- state ownership and parallel workers;
- the table-driven mechanics and how to add a row;
- the time caps and budgets;
- how to re-record controller shapes.

`README.md` SHALL point to it. `docs/e2e-tests.md` SHALL NOT exist.

#### Scenario: A developer writes a new test

- **WHEN** a developer reads `docs/testing.md` before writing a test
- **THEN** it tells them which layer to use, how to make the condition they assert, and which gates will fail if they wait on time or assert presence

### Requirement: The ExUnit layer SHALL run in CI on `master` and on pull requests

Every push to `master` and every pull request SHALL run, on a Linux runner, a format check, a
compile with warnings as errors, the ExUnit suite against a Postgres service, and the asset
build with the stylebook checked out beside the console and the core repository's published
API checked out for the published-surface test. A failure in any of them SHALL fail
the run. The browser suite SHALL NOT run in CI.

#### Scenario: A push to master is checked
- **WHEN** a commit is pushed to `master`
- **THEN** the CI workflow runs the format check, the warnings-as-errors compile, `mix test` and `mix assets.deploy`, and reports failure if any of them fails

#### Scenario: A missing token fails before the build
- **WHEN** the workflow runs without access to `flezha/flezha_stylebook`
- **THEN** the step checking it out, named after the repository, fails, and no later step runs

