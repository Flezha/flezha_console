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
navigation between screens, a provider form the controller really accepts.

**A browser spec never branches on discovered state.** If an assertion needs an
`if (present)` guard, that is the signal it belongs in ExUnit. The suite this
replaced wrapped four of six specs in such guards, and on a healthy stack the
dead-letter tests had never executed a single assertion. Where a case genuinely
cannot run here, it gets `test.skip` with the reason — visible in the report,
not buried in a log.

The exception is cleanup: `stopOperative` and `removeSchedule` tolerate an
already-gone target so they are safe to call from `finally`. They skip no
assertion.

## Layout

```
e2e/
  global-setup.ts   logs in once, saves the session to e2e/.auth/user.json
  fixtures.ts       `test` extended with `live()` — navigate + wait for the
                    LiveView — plus `startOperative()`/`stopOperative()`, since
                    one launcher serves two screens and driving it twice would
                    stop catching the drift it exists to prevent
  login.spec.ts     the form itself, with no stored session
  dashboard.spec.ts namespaces.spec.ts stream.spec.ts
  audit.spec.ts cluster.spec.ts dlq.spec.ts schedules.spec.ts
  operative-lifecycle.spec.ts plugin-attach.spec.ts topology.spec.ts
  authz.spec.ts              the posture banner and the flezha-token round-trip
  operatives-index.spec.ts   the cross-namespace index and its filters
  namespace-health.spec.ts   the health column on a namespace
  namespace-admin.spec.ts    quota meters, create and delete
  workflows.spec.ts          the workflow profile, journal, inbox, completions
  controller-health.spec.ts  durability posture, shutdown, boot, memory
  observability.spec.ts      sources, sinks, toggles, the live tail
  operative-state.spec.ts    durable entities and point-in-time reads
playwright.config.ts
```

Every spec except `login.spec.ts` starts authenticated from the stored session.
`e2e/.auth/` is gitignored — it holds a live dev session cookie.

## Single worker, on purpose

`workers: 1` and `fullyParallel: false`. The dev stack is one controller with
one shared `default` namespace and one shared `testnet_store_1` operative, and
several specs assert that a count returns to its starting value — which is what
catches a leaked operative or binding. Parallel workers mutating that state
would make those assertions lie in both directions. Unlocking parallelism means
giving each worker its own namespace, which is a dev-stack change.

## Plugin providers

`plugin-attach.spec.ts` runs one test per provider, so a broken provider fails
under its own name.

Only the fields the form marks `data-required="true"` are filled. Optional
fields are left blank so the provider's own default applies — several of them
are runtime handles (`worker_pid`, `producer_pid`, `registry_ref`) that a
caller must not supply at all.

A plugin runs **on the controller**, inside the compose network, so
`FIELD_OVERRIDES` points it at real services there: Kafka at `fui_kafka:9092`,
Postgres at `flezha_ui_db:5432`, HTTP poll at `http://fui_web:4000`. Pointing
these at `localhost` is why they used to fail.

Values otherwise come from the `guessFieldValue` name heuristic, which encodes
what the providers demand: `ws_opts` must be a JSON array (it is passed to
`Keyword.get`), `payload_metadata` a JSON object, the filter's `inverted` the
string `"true"`/`"false"`.

Each provider is subscribed to the extension it actually exports — sources like
the websocket and HTTP poll providers export `on_terminate`, not `on_input`.
`position` is sent only for `on_input`/`on_output`; it orders a chain and is
refused elsewhere.

`operative_message_forward` is skipped: it exports none of the extensions this
UI offers, so every subscription is refused with `{:missing_callback, …}`.
