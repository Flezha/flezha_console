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
healthy dev stack refuses to enter: an empty or populated dead-letter queue on
demand, audit logging switched off, a controller that is disconnected, timing
out, or version-skewed. `test/support/fake_controller.ex` produces all of those
in milliseconds.

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

## Layout

```
e2e/
  global-setup.ts   logs in once, saves the session to e2e/.auth/user.json
  fixtures.ts       `test` extended with `live()` — navigate + wait for the
                    LiveView — plus `startRelay()`/`stopRelay()`, since
                    one launcher serves two screens and driving it twice would
                    stop catching the drift it exists to prevent; and the shell
                    helpers `openSection()`/`closeSection()` (a screen's folded
                    panels), `toggleTheme()` (the toggle lives in the account
                    menu) and `openPalette()`; the schedule form helpers, and
                    `openSettings()`/`clearStoredToken()` for the token a spec
                    stores and must leave behind it undone
  login.spec.ts     the form itself, with no stored session
  dashboard.spec.ts namespaces.spec.ts listen.spec.ts
  audit.spec.ts dlq.spec.ts schedules.spec.ts
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

Every spec except `login.spec.ts` starts authenticated from the stored session.
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

A spec that writes state does it on something it made itself — a relay, a
plugin, a schedule, a token, a binding — and undoes it in `finally`; the one
seeded value a spec changes, a relay class's history retention, it sets back.
A revoked token stays listed as revoked: the controller has no way to delete
one.

## Plugin providers

`plugin-attach.spec.ts` runs one test per provider (`relay_stdout`,
`relay_websocket`), so a broken provider fails under its own name.

A plugin is enabled by name and bound to the relay in one call. The form offers
the hooks the provider itself reports through `Fleet.provider/2`, and takes the
provider's options as one JSON object beside the provider's own help text;
option keys travel as text and the controller turns only the ones the provider
declares into atoms.

A plugin runs **on the controller**, inside the compose network, so options
that name a service point at it there — Kafka at `fui_kafka:9092`, Postgres at
`flezha_ui_db:5432`, HTTP at `http://fui_web:4000` — never at `localhost`.

Every plugin a test enables is disabled before it finishes, so the plugin
listing and the relay's bindings are what they were before the test.
