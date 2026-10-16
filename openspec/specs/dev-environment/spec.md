# dev-environment Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: The dev stack builds against current flezha

`docker-compose.dev.yml` SHALL build the controller service from `flezha/docker/dev/Dockerfile.toolchain` and SHALL NOT reference any deleted path, image, or binary. The runner service SHALL run core's `test/apps/rust_runner`.

#### Scenario: Building the dev stack

- **WHEN** an operator runs `docker compose -f docker-compose.dev.yml build`
- **THEN** every service builds with no missing-file error

#### Scenario: No stale references remain

- **WHEN** the compose file is searched for `Dockerfile.agent`
- **THEN** no occurrence exists
- **AND** the naming gate fails on any `compute_engine` occurrence in the tracked tree, so `rust_compute_engine` cannot return

### Requirement: The runner runs as its own service

The Rust runner SHALL run as a dedicated compose service that waits for the controller's control socket before starting, mirroring the topology in flezha's own dev compose. It SHALL NOT be launched through the controller, whose port owner dying would take the runner with it.

#### Scenario: Runner registers once the controller is up

- **WHEN** the stack starts
- **THEN** the runner waits for the control socket, connects, and its factories become listable

#### Scenario: Runner survives a controller restart

- **WHEN** the controller container restarts
- **THEN** the runner process stays up and reconnects on its own

### Requirement: One command brings up the whole stack

`docker compose -f docker-compose.dev.yml up` SHALL start the controller, the UI, the database, and Kafka, and the UI SHALL connect to the controller node with no manual step. The UI service SHALL also have the `flezha_stylebook` sibling repository bind-mounted at the container path that the resolved package symlink points to, so the asset watchers can build the stylesheet without a further step.

#### Scenario: Cold start

- **WHEN** an operator brings the stack up from a clean state
- **THEN** the UI reaches the controller node and the Cluster screen reports a connected controller

#### Scenario: Controller restarts

- **WHEN** the controller container restarts
- **THEN** the UI reconnects on its own and screens recover

#### Scenario: The stylebook is reachable from the UI container

- **WHEN** the resolved stylebook package path is dereferenced inside the running UI container
- **THEN** it points at the mounted `flezha_stylebook` repository and its `css` directory is readable

#### Scenario: The stylesheet builds inside the container

- **WHEN** the Tailwind watcher rebuilds after the stack is up
- **THEN** the generated stylesheet contains the stylebook's tokens and component recipes, and the console renders styled rather than bare

#### Scenario: No hyphenated stylebook path remains

- **WHEN** the compose file, `assets/package.json`, the root `package.json`, `lib/mix/tasks/assets.stylebook.ex` and `README.md` are searched for `flezha-stylebook`
- **THEN** no occurrence exists

### Requirement: Dev seeding populates the dashboard

In the dev environment the UI SHALL seed testnet relays and plugins on boot through the published consumer API — relays with `Flezha.Service.Relay.start/3`, plugins enabled by name with `Flezha.Service.PluginManager.enable/3` and bound to their relay — and the seeding SHALL be idempotent. Seeded relays SHALL name factories the runner at core's `test/apps/rust_runner` announces, and seeded plugins SHALL use current provider ids such as `relay_websocket`. A seeded relay SHALL carry no kind: its run is its factory's.

#### Scenario: First boot

- **WHEN** the stack starts against an empty controller
- **THEN** the seeded relays and plugins exist and the `default` namespace's Home counts them in its Relays and Plugins tiles
- **AND** each seeded plugin is bound to the relay its seed names

#### Scenario: Repeated boot

- **WHEN** the UI restarts against a controller that is already seeded
- **THEN** nothing is duplicated and no error is reported
- **AND** a start answering `outcome: :already_running` and an enable answering `outcome: :already_enabled` count as seeded

#### Scenario: The controller is not yet reachable

- **WHEN** seeding runs before the controller accepts calls
- **THEN** it retries rather than crashing the UI application

#### Scenario: Seeding is dev-only

- **WHEN** the application runs outside the dev environment
- **THEN** no seeding is attempted

#### Scenario: The seeds use current names

- **WHEN** `config/dev.exs` is read
- **THEN** its seeds name relays, `relay_websocket` and `max_relays`, and carry no `kind`

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

Dev seeding SHALL declare its namespace through `Flezha.Service.Namespace.create/3` with quotas set under the controller's current quota keys (`max_relays`, `max_runners`), so the namespace administration screens have real data on a fresh stack rather than only a running hub with no declaration.

#### Scenario: First boot

- **WHEN** the stack starts against an empty controller
- **THEN** the seeded namespace exists as a declared namespace with quotas
- **AND** the namespace screen shows quota meters rather than an unset state

#### Scenario: Repeated boot

- **WHEN** the UI restarts against a controller whose namespace is already declared
- **THEN** the declaration is left alone and no error is reported

### Requirement: The asset build resolves the stylebook from a clean checkout

Asset setup SHALL install the `flezha_ui` asset dependencies and place the stylebook's fonts and brand SVGs into the served static tree. It SHALL fail with an actionable message when the sibling `flezha_stylebook` repository is absent, rather than producing an unstyled build.

#### Scenario: Setting up a clean checkout

- **WHEN** a developer runs the project's setup command with the sibling repository present at `../flezha_stylebook`
- **THEN** the stylebook is installed, the fonts and brand SVGs land in the static tree, and the asset build produces a styled stylesheet

#### Scenario: The sibling repository is missing

- **WHEN** asset setup runs without `flezha_stylebook` alongside the project
- **THEN** it stops with a message naming the missing `flezha_stylebook` repository and the expected location

#### Scenario: A developer looks up the prerequisite

- **WHEN** a developer reads `README.md`
- **THEN** the `flezha_stylebook` sibling-repository requirement and the asset setup command are documented

### Requirement: Dev seeding covers both runs

Dev seeding SHALL start at least one relay of a `flow` factory and at least one relay of a `steps` factory — a long-lived `chat_loop_steps` relay and a run-once `echo_steps` relay — so the steps panels, the task journal view, and the finished-relay listing are populated on a fresh stack.

#### Scenario: First boot seeds both runs

- **WHEN** the stack starts against an empty controller
- **THEN** at least one relay of a `flow` factory and one relay of a `steps` factory are running

#### Scenario: A steps relay completes

- **WHEN** the seeded `echo_steps` relay runs to completion
- **THEN** it appears in the finished-relay listing within its retention window

### Requirement: Controller state from before the rename is wiped, not migrated

The dev environment SHALL NOT migrate controller state written under the retired vocabulary. `README.md` SHALL document a one-time reset of the dev stack's controller state — stop the controller, clear its durable state with `flz reset --yes` or by removing the dev state directory, then bring the stack up — after which a cold start seeds cleanly in the current vocabulary.

#### Scenario: Starting over from old state

- **WHEN** a developer whose dev controller holds state from before the rename follows the documented reset and brings the stack up
- **THEN** the controller boots, seeding completes, and only the seeded relays and plugins exist

#### Scenario: The reset is documented

- **WHEN** `README.md` is read
- **THEN** it gives the reset steps and states that they discard all dev controller state

### Requirement: The dev console restarts itself on a configuration change

When the dev console runs in the `fui_web` container and a config file Phoenix's code reloader checks (`Mix.Project.config_files/0` under `config/`), `mix.exs` or `mix.lock` changes, the console SHALL stop its VM so that the container's restart policy starts it again with the new configuration and dependencies. Any other file, including an editor's lock or temporary file beside a config file, SHALL NOT stop it. The behaviour SHALL be enabled only by `FLEZHA_UI_RESTART_ON_CONFIG_CHANGE=true`, which the dev compose file sets on `fui_web`, only in the VM that serves the endpoint, and SHALL NOT be active in any other run.

#### Scenario: A config file changes in the dev stack

- **WHEN** `config/dev.exs` is saved while the dev stack runs
- **THEN** `fui_web` restarts once
- **AND** the console serves pages again without the "You must restart your server" error

#### Scenario: Several writes from one save

- **WHEN** an editor writes the same config file several times within half a second
- **THEN** the console restarts once

#### Scenario: An editor's lock file

- **WHEN** an editor creates `config/.#dev.exs` while the config file is being edited
- **THEN** the console keeps running

#### Scenario: Outside the container

- **WHEN** `mix phx.server` runs without `FLEZHA_UI_RESTART_ON_CONFIG_CHANGE=true`
- **THEN** no watcher is started and a config change does not stop the server

### Requirement: Screen refresh cadence is configurable and fast in dev

Each screen's periodic refresh SHALL use the interval from `:flezha_ui, :refresh_interval_ms` when that is set, and the screen's own declared interval otherwise. The liveness readout SHALL show the interval actually in use. The dev stack SHALL set the interval to 500 ms through `FLEZHA_UI_REFRESH_INTERVAL_MS`, so that a browser test sees a tick-fed figure settle within a second. The ExUnit environment SHALL set it to one hour, so that only the ticks a test sends fire. Production SHALL leave it unset.

#### Scenario: The dev stack refreshes fast

- **WHEN** the dev stack is up with its compose defaults
- **THEN** every screen with a periodic refresh re-reads every 500 ms, and its liveness readout says so

#### Scenario: Unset, each screen keeps its own cadence

- **WHEN** the variable is not set
- **THEN** each screen refreshes at the interval it declares

#### Scenario: ExUnit drives ticks itself

- **WHEN** an ExUnit test needs a refresh
- **THEN** it sends the tick to the view
- **AND** no timer-driven refresh fires during the test, because the configured interval outlasts any test

### Requirement: Dev seeding covers a graph with every shape

The dev seed SHALL start a `testnet_showcase` relay on the runner's `showcase` factory and bind the following plugins to it:
- a `relay_websocket` source on `trades`, also bound to `on_terminate`;
- an `http_poll` source on `quotes`;
- a `relay_io_filter` `on_input` filter skipping sell trades; the provider names no channel, so it acts on every entry;
- `relay_file_output` plugins: one on `prices`, two on `alerts`, one on `orders` and one on `audit`, leaving `volumes` unbound.

The quotes are polled from a small JSON answer the dev stack serves, since the testnet serves no HTTP.

The seed SHALL also keep `testnet_chain`. Like every seed, it SHALL be idempotent. When the runner does not announce `showcase`, it SHALL be skipped with one log line rather than failing the boot.

#### Scenario: The showcase is seeded

- **WHEN** the dev stack boots against a runner that announces `showcase`
- **THEN** `testnet_showcase` is running with its two sources, its filter and five output plugins, and its relay page draws every output channel

#### Scenario: An older runner

- **WHEN** the runner does not announce `showcase`
- **THEN** the other seeds run, and the log states that `testnet_showcase` was skipped and why

