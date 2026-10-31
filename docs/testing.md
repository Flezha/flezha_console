# Testing

Two layers. ExUnit (`test/`) covers everything that runs inside the BEAM,
against a fake controller on a peer node. The Playwright suite (`e2e/`) drives
the running dev stack in a real browser. Both are fast because neither waits for
time to pass, and both are trusted because the gates below fail a run that
would only look green.

```bash
mix test                          # ExUnit, under a minute
mix test --exclude distributed    # the fast loop: no peer node booted
mix test --slowest 25             # what dominates a run

docker compose -f docker-compose.dev.yml up   # the browser suite needs this up
npx playwright install chromium               # one-time
npm run e2e                                   # headless, 4 workers, about a minute
E2E_WORKERS=1 npm run e2e                     # one worker, to read a failure in order
npm run e2e:ui                                # Playwright UI mode
npx playwright test plugin-attach             # one spec
npx playwright test --project=phone           # the phone spec alone
E2E_BASE_URL=http://localhost:4001 npm run e2e  # a stack on another port
npx playwright show-report                    # durations per test, slowest first
E2E_TRACE=1 npx playwright test topology     # record a trace for each failure
npm run e2e:flake-check                       # the whole suite 3 times; lists any test that wavered
npm run e2e:flake-check -- 5 access           # 5 runs of the files matching `access`
```

CI (`.github/workflows/ci.yml`) runs the ExUnit layer on every push to `master`
and every pull request, beside the format check, the warnings-as-errors compile
and the asset build. The browser suite needs the dev stack and runs only locally.

## Which layer an assertion belongs to

An assertion lives at the layer that can **produce** the state it asserts, and
only there.

Put it in **ExUnit** when the state is one a healthy dev stack refuses to enter:
a log switched off, a controller that is disconnected, timing out,
version-skewed or shutting down, a partition group to rescale, a second running
namespace, a confirmed runner drop. `FakeController`
produces all of those in milliseconds.

Put it in **Playwright** when only a real browser can observe it: a JS hook, a
`phx-click` actually binding, navigation and URL patches, a keyboard shortcut,
localStorage, layout and scrolling, the pipeline graph drawing, a provider
form the real controller accepts. A browser test that only re-asserts what an
ExUnit test already asserts is deleted, not kept "for coverage".

**A browser test never branches on discovered state.** If an assertion needs an
`if (present)` guard, it belongs in ExUnit. A case the stack truly cannot run
gets `test.skip` with its reason. Cleanup helpers (`stopRelay`,
`removeSchedule`) tolerate an already-gone target so they are safe in `finally`;
they skip no assertion.

## No test waits for time

A test waits only for a condition it caused, and stops as soon as it holds:

- **Browser.** Cause the record, then assert the screen shows it. `sendRecords(relay,
  payloads)` sends many records as `flz relay send` does, in one request;
  `sendToRelay(page, payload)` sends one through the relay's Talk dialog;
  `cliCall(door, args)` calls any controller door as `flz` does. A live figure is
  asserted with `expectAdvances(figure, name, cause)`, which reads it, runs the
  cause and polls at the default timeout. Nothing reads the seeded websocket
  sources — they are there for a person looking at the console.
- **Rates.** The dev stack refreshes every screen every 500 ms
  (`FLEZHA_CONSOLE_REFRESH_INTERVAL_MS` in `docker-compose.dev.yml`), so traffic sent
  across two ticks moves a rate within a second.
- **ExUnit.** A test sends `:refresh` to a view itself; `config/test.exs` sets the
  screens' interval to an hour so no timer fires one in its place, and the
  window that coalesces an event's read to zero, so a forwarded event reads at
  once. A test of the coalescing itself sets a window longer than the test
  (`TestEnv.put_app(:refresh_coalesce_ms, …)`) and sends `:refresh_requested`
  itself, as it sends `:refresh`. A screen that reads in the background
  (Dashboard) and the shell's pulse answer in a task, so a test awaits them with
  `render_async/1` before it reads the screen or counts calls; a plain
  `render/1` races the task. `LiveCase.live_loaded/2` opens a screen and
  answers `{view, html}` once those first reads have answered. A controller
  that is slow for as long as the test says is a gated answer:
  `FakeController.close_gate/2`, an answer set as `{:gated, gate, value}`,
  `assert_receive {:gate_reached, gate}` once a read gets that far, then
  `FakeController.open_gate/2`. A rate needs
  time between two readings, so `LiveCase.tick/1` moves the last reading a
  second into the past and ticks, awaiting the reads in flight before and
  after, rather than waiting a second. A message
  that must not arrive is refuted after a synchronous barrier — `:sys.get_state/1`
  on the process, or a call it must answer first — never after a timeout.
  `PeerNode.eventually/2` is the one sanctioned poll, for remote state that
  settles on its own.

`test/support/naming_gate.ex` enforces this: `mix test` fails on
`waitForTimeout`, `setTimeout`, `test.setTimeout`, `test.slow`, poll `intervals`,
a literal timeout of 5 s or more, or a named one, in `e2e/`; and on
`Process.sleep`, `:timer.sleep` and a receive timeout of a second or more in
`test/`. An exemption carries its reason, and one nothing needs any more fails.

## Caps and budgets

Every ExUnit test has 5 s (`test/test_helper.exs`). Every browser test has 20 s,
each expectation and action 5 s, each navigation 10 s (`playwright.config.ts`).
A test that needs longer is waiting on something it did not cause; fix it, or
move it to the layer that can produce its state at once.

The budgets are 90 s for `mix test` and 4 minutes for `npm run e2e` on a
developer machine. `mix test --slowest 25` and the HTML report's durations say
what to look at first when a run creeps up.

A browser run is bound by CPU, not by waiting: the stack, the browsers and the
runner share one machine, and a starved machine slows every test at once. So
nothing pays per test what it need not. The dev endpoint runs Phoenix's
whole-project reload check only after the file monitor has seen code change
(`ConfigWatcher.code_changed?/0`), and never on a socket connect: run on every
request, it cost the console more than the page itself. The dev stack never falls back
from a page's websocket to long polling (`:longpoll_fallback_ms` is unset in
`config/dev.exs`): on a busy machine Phoenix's client would otherwise switch a
slow page to long polling, whose LiveView outlives a dropped connection by
seconds and whose frames the page-health guard cannot see. No trace is recorded
unless `E2E_TRACE=1`: recording one costs every test, and a failure keeps its
screenshot and `error-context.md`, with the page snapshot, without it. The
phone project paints at one device pixel, and every test runs under reduced
motion unless it is about the motion and asks for it. A relay that is only a
fixture is started and stopped through the controller (`ownRelay`,
`startRelayCli`); the launcher form is driven by the specs whose
subject it is. Every controller call a worker makes goes through one node it
boots on first use (`priv/dev/cli_call.exs --serve`), because each node boot
costs the console's container over a CPU-second. A check that needs a test of its own is one a single page
session cannot reach: otherwise it is a step in the test that already holds
that page.

## Parallel workers own their state

Spec files run side by side in 4 workers (`E2E_WORKERS`); tests in one file run
in order in one worker, so a file can share a `beforeAll`. A long file whose
tests stand alone and that starts nothing for them opts into parallel mode
instead (`phone`), so it does not run last on one worker. `ownRelay(prefix,
opts)` gives a file a relay of its own: started through the controller under a
run-unique id before its tests and stopped after them. `dlq.spec.ts` parks its one entry the same
way — the controller keys an entry on its payload, so a relay parks `poison`
once — and its tests read, mark seen, replay and drop that entry in turn.

Global setup makes one console user per worker, afresh each run
(`pw-worker-<n>@flezha.test`, through `priv/dev/console_users.exs`), logs each
in through the real form and stores the
session in `e2e/.auth/worker-<n>.json`; the `test` fixture picks the worker's
own. A stored flezha token, the namespace last worked in and other per-user
state therefore never cross workers.

Before it changes anything on the stack, global setup:

- **waits for both controllers**: it reads `Controller.boot_status` until
  `flezha@flezha_controller` and `flezha@flezha_controller_2` both answer
  ready with every namespace's hub `normal`, and until the second controller's
  runner serves `second/store_input`; it fails after 30 s naming what is not,
  so no test meets a cluster still recovering;
- **takes the stack's lock**: it creates the namespace `e2e-run-lock`, which
  the controller refuses to create twice. A second run against a held stack
  stops there, naming the run that holds it and how long ago it started, and
  leaves that run's users logged in. A run is known to be going by its nodes
  in `fcon_web`, which are named after it (`pw_<run>_…`): a lock whose run has
  no node left was left by a run that died, and is taken over with a warning.
  `E2E_TAKE_LOCK=1` takes a lock over regardless. A run in UI mode holds the
  stack until it is closed. Playwright clears `test-results/` before global
  setup runs, so a refused run has already cleared the holder's failure
  screenshots;
- **makes each worker a namespace**, `e2e-w<n>-<run>`, where the run id is the
  run's start time in base 36, and deletes the worker namespaces of runs that
  have gone. The worker fixture `workerNamespace` names it.

The dev stack is a cluster of two controllers. The console is connected to
`flezha_controller`; `flezha_controller_2` joins it and keeps its storage in a
volume of its own. The second runner is a second copy of the Rust runner rather
than the sandbox Elixir runner: it shares the first one's build, so it adds no
compile and little CPU. It connects only to the second controller and serves the
namespace `second`, which no runner of the first serves, so a relay started
there runs on the second controller. A test reaching the other controller uses
`CONTROLLERS`, `SECOND_NAMESPACE` and `SECOND_FACTORY` from `global-setup.ts`.

The teardown global setup answers deletes the run's worker namespaces and its
lock, whether the tests passed or not. A lock left behind by hand is removed
with `flz namespace delete e2e-run-lock`.

A test asserts only on what it made or caused — a relay it started, a plugin
bound to that relay, a schedule, a namespace, a token, records it sent — named
by `uniqueId()`, and removes it in `finally`. Tokens and role bindings are made
in the worker's namespace, so no other worker's rows redraw a listing a test
acts on. Relays stay in `default`, under run-unique ids, because only `default`
has a runner. A test asserts its own ids are or are
not listed, never that a global count equals an earlier read: another worker may
have started a relay in between. Every listing shows 20 rows and grows by a page,
so other workers' rows — revoked tokens, ended runs, rotated log files —
can push a test's own row past the first page: `growListing(page, listing, row)`
grows the listing until that row is shown, and without a row shows every one. No test binds a plugin to or retunes a seeded
relay. Actions that reach every session on the stack — stopping the controller,
dropping a runner — are driven to their confirmation and cancelled in the
browser; the confirmed path is asserted in ExUnit.

No browser test asserts a value the stack decides rather than the test: how
many runners, nodes, namespaces or late runners there are, how many relays are
in each health, the first row of a listing other workers write to, or a layout
that depends on how long live text is. It may assert such a value's form — a
number followed by "late" — and the value itself is asserted in ExUnit, where
the fake controller fixes it. Tiles are compared within one row, never across
rows whose text is live.

A row's action goes through `menuAction(page, menu, item)`: it opens the row's
menu, opens it again if a redraw closed it, and clicks the item once it shows,
within the action timeout. It is the one sanctioned retry, of a gesture and
never of a test. An open menu itself stays open, and placed against its row,
while other rows of its listing change, which `access.spec.ts` drives with two
sessions.

An ExUnit test that changes the VM's environment — an application setting or
an OS variable such as `FLEZHA_TOKEN` — does it through `FlezhaConsole.TestEnv`,
which restores what it found when the test ends, and runs serially.

## When a browser test fails

A red run means a bug, in the code or in the test; nothing about the suite is
random once the stack is ready and held by one run.

1. Read the failure once: the error, its screenshot and `error-context.md`
   under `test-results/`.
2. Reproduce it under the load that failed it, never alone:
   `npx playwright test --repeat-each=3` runs every file three times in one
   run, so the failing test runs beside all the others on four workers. A
   second run beside it is refused by the stack's lock. A test that passes
   alone after failing in a full run is not fixed.
3. Fix the cause: state the test does not own, a value the stack decides, a
   menu acted on outside `menuAction`.
4. Confirm with `npm run e2e:flake-check`, which runs the whole suite three
   times with its normal workers and lists every test that failed in any run
   or changed outcome between runs. It exits non-zero while it lists one. No
   test is skipped or retried to pass it.

Restart the controllers with `priv/dev/stack.sh restart-controllers`, which
drains each the way `flz controller stop` does and lets compose start it again,
rather than killing them: a killed controller can leave its DETS files to
repair, and its next boot spends that time recovering.

## Shared mechanics are tested once

A behaviour several screens get from one module is one table-driven test, with
one row per screen, each failing under its screen's name:
`test/flezha_console_web/live/shared_mechanics_test.exs` holds cancelling a
confirmation, a refused primary read, an empty screen, closing a tail and a
relay's verdicts on each screen that lists it; `launcher_test.exs` the relay
launcher both screens serve; `disconnected_screens_test.exs` every screen with
no controller. A new screen with one of these takes a row, not a test.

## A test asserts behaviour

A test fails when the behaviour it names breaks. These are not tests: one whose
only assertion is that a test id, class or label is in the HTML; one that reads
source files to prove something is gone; an assertion that holds for any page;
a test of a function `lib/` never calls.

In ExUnit, drive a control through its markup — `element(view, sel) |>
render_click()`, `form(view, sel, params) |> render_submit()` — so a button
wired to the wrong event fails. `render_hook/3` is for an event a JS hook
pushes. Pushing an event by name past the markup is only for a test that
forges what the operator's screen does not offer — a viewer's stop, a second
submit — named as a forgery and asserting the server refuses it.

## The coverage ledger

`test/flezha_console/coverage_ledger_test.exs` reads `lib/` on every run and fails
naming each LiveView event no test drives through its markup, and each binding
to an event no clause handles. An event counts as driven when a test clicks,
fills, checks or selects the control bound to it — in the browser or through
`element/2`/`form/2` — when a selector names its binding (`[phx-click="x"]`),
when `render_hook/3` pushes it, or when a table row names the control under
`open:`, `cancel:` or `before:`. A bare `render_click(view, "x")` counts for
nothing. Its module doc states the matching rules; an exemption carries its
reason.

## The fake is checked against the controller

`FakeController` stands in for the published `Flezha.Service.*` modules by name,
on a peer node with this application's code left off its path.
`PeerNode.start!/3` names the peer it starts as `FLEZHA_NODE` until the test or
module that started it ends, and the console calls only that node, so a test
that links a second node by hand names its controller itself. Two checks keep
it honest:

- `published_surface_test.exs` reads the core checkout beside this repository
  (`FLEZHA_CORE_PATH` or `../flezha`): every call the console makes is
  published, every stub stands in for a published function, and every error code
  the fake answers carries the class core's `crates/flz_transport/errors.json` gives
  it.
- `controller_shapes_test.exs` checks every stub's default answer and every
  fixture builder (`relay_row/2`, `runner_row/2`, `graph_channel/5`,
  `graph_tasklet/2`, `factory_row/2`, `activity_row/2`, `option_row/2`,
  `history_record/2`, `relay_counters/2`) against
  `test/support/fixtures/controller_shapes.json`: tuple tags, map keys and value
  types recorded from the dev controller, never values. A map keyed by data
  rather than by fields — a provider's `opts` and the `provider_opts` it runs
  with, a relay's hook `chains`, one count per health verdict — is recorded by
  its values alone, since which keys it holds depends on what the stack runs.
  A paged read — a stub declared with `paged:` — answers the page
  `FakeController.page/3` cuts from the whole collection a test sets, refusing
  what core refuses, so a test sets thousands of rows and a screen reads them a
  page at a time.

Every browser run starts by checking the live controller against that file, and
fails naming each read whose answer moved. When core changes an answer,
re-record and fix the fake in the same change:

```bash
docker exec fcon_web sh -c 'exec elixir --sname rs1 --cookie "$ERLANG_COOKIE" \
  /flezha_console/priv/dev/record_shapes.exs'          # writes the file
docker exec fcon_web sh -c 'exec elixir --sname rs2 --cookie "$ERLANG_COOKIE" \
  /flezha_console/priv/dev/record_shapes.exs --check'  # what global setup runs
```

A new read the console makes is added to `FlezhaConsole.ControllerShapes.reads/0`.

## Page-health guards

The `test` exported from `e2e/fixtures.ts` arms every browser test with three
guards, with no opt-in. Each collects while the test runs and fails it at
teardown, naming the problem and the URL:

- **Script errors**: an uncaught error on the page, or a console message of type
  `error`.
- **LiveView health**: a `phx_error` frame or an error reply on a LiveView topic,
  and a LiveView container taking `phx-error`, `phx-client-error` or
  `phx-server-error`. A join answered with a redirect is navigation.
- **Transport**: a document, script, stylesheet, image, font, XHR or fetch
  answered 400 or above, and any request that got no answer.

Benign noise goes in `PAGE_HEALTH_EXEMPTIONS`, one matcher per entry with its
reason. A test that causes a problem on purpose allows it itself with
`pageHealth.allow(match, reason)`. There is no way to switch a guard off.

## Seeded state

The dev stack seeds relays and plugins (`:dev_setup` in `config/dev.exs`) for a
person using the console. Tests start their own relays from the seeded
factories (`startRelay()` picks `store_input` for a flow run and
`chat_loop_steps` for a steps run) and read the seeds only where a seed is the
fixture itself:

- `orders`, the dev runner's relay API: `place` is a JSON channel whose schema
  asks for `pair` and `amount` and answers the placed order; `audit` takes a
  line of text and answers nothing. Calls are told apart by a run-unique pair.
  `relay-call-activity.spec.ts` starts a relay of its own from the `orders`
  factory instead, because its Calls panel would hear every other spec's calls.
- `lifecycle_webhook`, a controller plugin bound to no relay.
- `testnet_chain`, whose websocket source names no channel and is bound only
  to tear down: the graph draws it as a source on the relay's first entry.
  The graph's other cases run on relays `topology.spec.ts` starts from the
  `static_cell` and `showcase` factories.
- Two plugin packages placed in the controller's plugin root before it boots
  (`priv/dev/plugin_packages.sh`): `flezha_http`, which loads, and
  `flezha_http_tampered`, which the loader refuses with `plugin.package_invalid`.
- `poison_probe`, a factory whose tasklet fails on the input `poison`, so a
  spec parks a dead letter in a relay of its own and drops it after —
  `openDeadLetters()`, `deadLetterRefs()` and `dropDeadLetters()` in
  `e2e/fixtures.ts`. Never send it `antidote`: that flips a flag for the whole
  runner process.

A plugin runs on the controller, inside the compose network, so options that
name a service point at it there — Kafka at `fcon_kafka:9092`, HTTP at
`http://fcon_web:4000` — never at `localhost`. A disabled plugin keeps its
bindings, so `disablePlugin()` unbinds every relay first. A spec finds a
plugin's row with `openPluginRow()`, on the plugins list filtered to it: other
runs' plugins can push it past the first page. A revoked token stays listed as
revoked.

## The trader stack's market relay

`relay-data-flow.spec.ts` needs what only flezha_trader's dev stack runs: the
`demo` market group, its two partitions and its fourteen-tasklet graph, and an
analyzer runner with a graph of its own. That stack serves its own pinned
checkout of the console, not this one, so a change is seen there only once that
checkout carries it; it listens on the port its `FLEZHA_CONSOLE_HOST_PORT` gives
(`E2E_MARKET_URL`, `http://localhost:4000` by default). `E2E_MARKET_STACK=1`
adds a `market` project that runs the spec there, logged in as that stack's
seeded user, beside the rest of the suite on this stack. A runner without a
graph or without Cell rows is covered in ExUnit:

```bash
E2E_MARKET_STACK=1 E2E_BASE_URL=http://localhost:4001 npx playwright test           # both stacks
E2E_MARKET_STACK=1 E2E_MARKET_URL=http://localhost:4002 npx playwright test --project=market
```

Without `E2E_MARKET_STACK` the spec is skipped, with the reason in the report.
