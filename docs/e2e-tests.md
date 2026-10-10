# Browser tests

Playwright specs under `e2e/`, driving the running dev stack.

```bash
docker compose -f docker-compose.dev.yml up   # the suite needs this up
npx playwright install chromium               # one-time
npm run e2e                                   # headless
npm run e2e:ui                                # Playwright UI mode
npm run e2e:headed                            # watch it drive a real browser
npx playwright test plugin-attach             # one spec
npx playwright show-report                    # last run's HTML report
```

## Which layer an assertion belongs to

An assertion lives at the layer that can **produce** the state it asserts.

Put it in **ExUnit** (`test/flezha_ui_web/live/`) when the state is one a
healthy dev stack refuses to enter: audit logging switched off, a controller
that is disconnected, timing out, version-skewed or shutting down, a partition
group to rescale, a second running namespace. `test/support/fake_controller.ex`
produces all of those in milliseconds. A dead letter is not one of them: the dev
runner's `poison_probe` factory parks the input `poison`, so `dlq.spec.ts`
parks its own.

Put it in **Playwright** when only a real browser can observe it: a `phx-click`
actually binding, a modal being visible and clickable, a JS hook running,
navigation between screens, a provider form the controller really accepts, a
keyboard shortcut reaching the page, a preference surviving a reload, or a
browser refusing to store one.

**A browser spec never branches on discovered state.** If an assertion needs an
`if (present)` guard, that is the signal it belongs in ExUnit. The suite this
replaced wrapped four of six specs in such guards, and on a healthy stack the
dead-letter tests had never executed a single assertion. Where a case genuinely
cannot run here, it gets `test.skip` with the reason — visible in the report,
not buried in a log.

The exception is cleanup: `stopRelay` and `removeSchedule` tolerate an
already-gone target so they are safe to call from `finally`. They skip no
assertion.

## Page-health guards

The `test` exported from `fixtures.ts` arms every test with three guards, with
no opt-in. Each collects while the test runs and fails it at teardown, naming
the problem and the URL:

- **Script errors**: an uncaught error on the page, or a console message of type
  `error`.
- **LiveView health**: a `phx_error` frame or an error reply on a LiveView topic,
  and a LiveView container taking `phx-error`, `phx-client-error` or
  `phx-server-error`. A crashed LiveView re-joins the same container, so only the
  frame or the class arriving records that it crashed. A join answered with a
  redirect is navigation, not an error.
- **Transport**: a document, script, stylesheet, image, font, XHR or fetch
  answered 400 or above, and any request that got no answer.

Noise that is benign everywhere goes in `PAGE_HEALTH_EXEMPTIONS` in
`fixtures.ts`, one matcher per entry with the reason it is benign; an entry
without a reason fails the run. A test that causes a problem on purpose — the
socket-drop test in `topology.spec.ts` — allows it itself with
`pageHealth.allow(match, reason)`. There is no way to switch a guard off.

## Live figures

A figure the controller feeds is asserted to move, never only to exist or to
carry a unit. `expectAdvances(figure, name, cause?)` takes a locator showing a
number, or a function reading one such as a count of rows. It reads the figure, runs
`cause` when the test makes the traffic itself, and polls for a strictly larger
read within `ADVANCE_WINDOW_MS`, which is more than two intervals of the seeded
sources in `config/dev.exs`. `readFigure` reads a number, scaling `KB`/`MB`.

Counts of discrete events are fed by the console's own controls: a send from
the relay screen (`sendToRelay()`), a call to `orders`, a relay started and
stopped, an administration action the audit tail must show. Rates and samples
— tap rates, flow rates, the sparkline, the periodic refresh — are fed by the
seeded sources. The first test in `listen.spec.ts` checks that precondition by
name: the seeded sources are bound to their relays and deliver, so a silent
stack fails there and not as a timeout in every liveness assertion.

## The coverage ledger

`test/flezha_ui/coverage_ledger_test.exs` runs with `mix test` and needs no
stack. It reads `lib/` through `FlezhaUi.NamingGate.all_files/1` and fails
naming each test id that no spec or ExUnit test names, each `handle_event`
event that no test drives or binds to a named test id, and each markup binding
to an event no clause handles. Its module doc states the matching rules.

When it fails on new UI, add the test that drives the control. When a control
can truly never be driven, add it to `@exempt` in the ledger with the reason;
an exemption without one, or one that no longer excuses anything, fails.

## Controls that stop the stack

Stopping the controller ends the dev stack for every other session, so
`controller-health.spec.ts` drives the stop dialog to its typed confirmation
and cancels. The confirmed stop, its progress and the shutdown phase are
asserted in `controller_live_test.exs`. Dropping the dev runner is driven in
full, because readmitting it restores the stack.

## Layout

```
e2e/
  global-setup.ts   logs in once, saves the session to e2e/.auth/user.json
  fixtures.ts       `test` extended with `live()` — navigate + wait for the
                    LiveView — and the page-health guards (`pageHealth`);
                    `expectAdvances()`/`readFigure()` for live figures,
                    `sendToRelay()` for traffic the test makes, `openPage()`
                    for a second page beside the one under test,
                    `fillPluginForm()`/`optionError()` for the plugin form
                    both plugin specs drive, and `confirmEach()` for cleanup
                    that confirms one row action at a time; plus
                    `startRelay()`/`stopRelay()`, since
                    one launcher serves two screens and driving it twice would
                    stop catching the drift it exists to prevent; and the shell
                    helpers `openSection()`/`closeSection()` (a screen's folded
                    panels), `toggleTheme()` (the toggle lives in the account
                    menu) and `openPalette()`; the schedule form helpers, and
                    `openSettings()`/`clearStoredToken()` for the token a spec
                    stores and must leave behind it undone; and `cliCall()`,
                    which calls the controller as `flz` does
  login.spec.ts     the form itself, with no stored session
  account.spec.ts   registration, logging in by the emailed link, logging out,
                    and the settings forms, as a user each test registers
  listen.spec.ts    the seeded-traffic precondition, then the listen screen
  dlq.spec.ts       entries parked by a `poison_probe` relay of its own
  dashboard.spec.ts namespaces.spec.ts audit.spec.ts schedules.spec.ts
  relay-lifecycle.spec.ts plugin-attach.spec.ts topology.spec.ts
  authz.spec.ts              the posture banner and the flezha-token round-trip
  relays-index.spec.ts       the cross-namespace index and its filters
  namespace-health.spec.ts   the health column on a namespace
  namespace-admin.spec.ts    quota meters, create and delete
  steps.spec.ts              the steps panel, task journal, input log, finished relays
  controller-health.spec.ts  durability posture and the shipper, shutdown, boot,
                             memory; the stop dialog's typed-name gate, cancelled
  cluster.spec.ts            nodes, hubs, runners and factories; a namespace's
                             recovery per node; dropping the dev runner, its
                             process refused until readmitted
  theme.spec.ts              the theme following the device, a stored choice,
                             the chrome flipping with it, the badger and icons
  observability.spec.ts      sources, sinks, toggles, the live tail
  relay-state.spec.ts        durable cells and point-in-time reads
  relay-calls.spec.ts        diagnosis, the relay's API, calling `orders`'
                             channels from schema fields, raw send and call
  relay-call-activity.spec.ts the Calls panel: calls from the terminal and the
                             dialog with their sources and outcomes, a timeout,
                             a folded panel holding no listen
  relay-state-tools.spec.ts  outbox, rotate, replay, delete and retention on a
                             relay of its own; the input log's records
  plugin-management.spec.ts  the loaded and the refused package, a controller
                             plugin with hooks, bind, unbind and update
  access.spec.ts             tokens issued and revoked, role bindings, and the
                             controls a viewer token does not get
  fleet-actions.spec.ts      runner pids, a schedule run now, audit rotation,
                             the relay lifecycle feed
  console-navigation.spec.ts the shell: the two-section rail, the scope in the
                             route, breadcrumbs, a relay's tabs, the
                             palette's keyboard, a fold surviving a reload
playwright.config.ts
```

Every spec starts authenticated from the stored session except `login.spec.ts`,
`account.spec.ts` and the brand tests outside the shell in `theme.spec.ts`.
`e2e/.auth/` is gitignored — it holds a live dev session cookie.

## Single worker, on purpose

`workers: 1` and `fullyParallel: false`. The dev stack is one controller with
one shared `default` namespace and one shared `testnet_store_1` relay, and
several specs assert that a count returns to its starting value — which is what
catches a leaked relay or binding. Parallel workers mutating that state
would make those assertions lie in both directions. Unlocking parallelism means
giving each worker its own namespace, which is a dev-stack change.

## Seeded state

`startRelay()` starts from a seeded factory chosen by run — `{flow:
'store_input', steps: 'chat_loop_steps'}`, the factories core's
`test/apps/rust_runner` announces — and never asks for a kind: how a relay runs
is its factory's, and the start form only states it. The seeds themselves are
`:dev_setup` in `config/dev.exs`.

Seeds the newer specs rely on:

- `orders`, the dev runner's relay API fixture: `place` is a JSON channel whose
  schema asks for `pair` and `amount` and which answers the placed order;
  `audit` takes a line of text and answers nothing.
- `lifecycle_webhook`, a `hook_webhook` controller plugin enabled with
  `on_relay_started` and `on_relay_stopped`, so the plugins screen lists a
  controller plugin with no relay.
- Two plugin packages the `plugin_packages` service places in the controller's
  plugin root before it boots (`priv/dev/plugin_packages.sh`): `flezha_http`,
  built with the controller's toolchain, which loads, and
  `flezha_http_tampered`, whose manifest changed after it was checksummed,
  which the loader refuses with `plugin.package_invalid`.

Calls from outside the console go through `cliCall()`, which runs
`priv/dev/cli_call.exs` inside `fui_web` and sends the one request `flz` sends,
so the controller names the caller `cli`. `flz` itself cannot reach this
controller: it shells out to the release launcher, which a controller running
under `iex -S mix` does not have.

A spec that writes state does it on something it made itself — a relay, a
plugin, a schedule, a token, a binding, a namespace, a parked entry — and
undoes it in `finally`; the one seeded value a spec changes, a relay class's
history retention, it sets back. A disabled plugin keeps its bindings, so
`disablePlugin()` unbinds every relay first.
A revoked token stays listed as revoked: the controller has no way to delete
one.

## Plugin providers

`plugin-attach.spec.ts` runs one test per provider (`relay_stdout`,
`relay_websocket`), so a broken provider fails under its own name.

A plugin is enabled by name and bound to the relay in one call. The form offers
the hooks the provider itself reports through `Fleet.provider/2`, and one field
per option the provider lists there, each of the control its type needs, with
the option's description as its hint and its default as its placeholder. Only
filled options are sent, in their types and keyed by text; the controller turns
only the names the provider declares into atoms. The single JSON object field
remains only for a controller that lists no options, which the dev stack never
is, so that fallback is covered by ExUnit.

The specs drive `relay_http_push` (a text, a selection, a JSON, a
comma-separated and a bounded number field), `relay_io_filter` (a true/false
selection) and `hook_webhook` through typed fields: a number outside its bounds
is stated on its field before anything is sent, the controller's
`plugin.url_scheme_unsupported` lands on the `url` field, and an update fills
one option and says it restarts the plugin's copies.

A plugin runs **on the controller**, inside the compose network, so options
that name a service point at it there — Kafka at `fui_kafka:9092`, Postgres at
`flezha_ui_db:5432`, HTTP at `http://fui_web:4000` — never at `localhost`.

Every plugin a test enables is unbound and disabled before it finishes, so the
plugin listing and the relay's bindings are what they were before the test.
