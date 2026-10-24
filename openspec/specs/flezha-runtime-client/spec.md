# flezha-runtime-client Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Single ERPC seam

All calls from the console into the flezha controller SHALL pass through `FlezhaConsole.Service.NodeManager`. No LiveView, controller, or other service module SHALL invoke `:erpc` or reference a `Flezha.*` remote module name directly.

#### Scenario: A LiveView needs controller data

- **WHEN** a LiveView needs data or an action from the controller
- **THEN** it calls a named `NodeManager` function
- **AND** no `Flezha.*` module name appears outside `NodeManager`

#### Scenario: A new controller call is added

- **WHEN** a new controller API is needed by any screen
- **THEN** the remote module, function, and argument shape are declared in `NodeManager` only

### Requirement: Controller vocabulary matches flezha

`NodeManager` SHALL expose the controller's reads and actions under core's current vocabulary, each function named after the published function it calls: among them `list_namespaces`, `list_relays`, `relay_list` (`Relay.list/2`), `runners`, `factories`, `start_relay`, `stop_relay`, `cell_state`, and `overwatch_state`. No `NodeManager` function SHALL keep a name core has retired.

#### Scenario: Listing relays in a namespace

- **WHEN** `NodeManager.list_relays` is called with a namespace
- **THEN** it calls `Flezha.Service.Relay.list_relays/2` on the connected node with the caller context last
- **AND** answers the relay id list

#### Scenario: Listing runners in a namespace

- **WHEN** `NodeManager.runners` is called with a namespace
- **THEN** it calls `Flezha.Service.Fleet.runners/2` on the connected node
- **AND** the answer covers every runner serving the namespace anywhere in the cluster, not only those on the node the UI reached

#### Scenario: Function names follow the published surface

- **WHEN** the public functions of `NodeManager` are listed
- **THEN** every one that reaches the controller uses the relay, tasklet, and cell vocabulary of the published function it calls

### Requirement: Errors are normalized into a closed set

`NodeManager` SHALL classify every transport failure into exactly one of `{:error, :node_not_connected}`, `{:error, {:api_missing, module, function, arity}}`, `{:error, :timeout}`, or `{:error, {:remote_error, term}}`. A refusal or failure the controller answers SHALL arrive as `{:error, error}`, where `error` is the controller's `%Flezha.Error{}` carrying `code`, `class`, `message`, `details`, and `hint`, and SHALL be returned unchanged. The UI SHALL read that error by its fields, without needing core's modules loaded on its own node. Raw `:erpc` exits and `:badrpc` tuples SHALL NOT escape `NodeManager`.

#### Scenario: No controller node is connected

- **WHEN** any `NodeManager` function is called while no flezha node is connected
- **THEN** it returns `{:error, :node_not_connected}`
- **AND** no exception is raised

#### Scenario: The controller lacks the called function

- **WHEN** a remote call raises `:undef` because the controller does not export it
- **THEN** `NodeManager` returns `{:error, {:api_missing, module, function, arity}}`
- **AND** the remote stacktrace is logged at warning level

#### Scenario: The door does not publish the operation

- **WHEN** the door answers `control.unknown_function` for an operation
- **THEN** `NodeManager` returns `{:error, {:api_missing, module, function, arity}}` naming the published function it asked for

#### Scenario: The controller does not answer in time

- **WHEN** a remote call exceeds its timeout
- **THEN** `NodeManager` returns `{:error, :timeout}`

#### Scenario: The controller refuses the call

- **WHEN** authorization refuses a call, or no principal is bound
- **THEN** `NodeManager` returns `{:error, error}` where `error.class` is `:denied` and `error.code` names the refusal, such as `authz.role_insufficient` or `authz.principal_not_bound`
- **AND** the refusal is not folded into `{:remote_error, term}`

#### Scenario: The controller answers a domain failure

- **WHEN** a published function answers `{:error, error}` for a reason of its own, such as `relay.not_found`
- **THEN** `NodeManager` returns that `{:error, error}` unchanged rather than wrapping it as a transport failure

#### Scenario: A refusal is shown to the operator

- **WHEN** a screen renders a controller error
- **THEN** it shows the error's `message`
- **AND** it decides how to present the error from its `class` and `code`, never by matching message text

### Requirement: Version skew is visible to the operator

Any screen receiving `{:error, {:api_missing, _, _, _}}` SHALL render a banner naming the missing controller function and stating that the UI and controller versions have diverged. The screen SHALL NOT crash and SHALL continue rendering the data it did obtain.

#### Scenario: One call on a screen is missing on the controller

- **WHEN** a screen makes several calls and one returns `{:api_missing, ...}`
- **THEN** a banner names the missing function
- **AND** the sections backed by the successful calls still render

#### Scenario: The controller node is down

- **WHEN** a screen loads while the controller is disconnected
- **THEN** a banner states the controller is not connected
- **AND** the LiveView remains mounted and retries on reconnect

### Requirement: Data-plane liveness snapshot

`NodeManager` SHALL expose `liveness_snapshot`, calling `Flezha.Service.Controller.liveness_counters/1` with the caller context and answering the controller's own map of `channels` and `relays` counter lists, with transport failures normalized into the seam's closed error set.

#### Scenario: Snapshot succeeds

- **WHEN** the controller answers the liveness counters
- **THEN** `liveness_snapshot` answers the map of per-channel and per-relay counter snapshots as the controller produced it, each relay snapshot keyed by `relay_id`

#### Scenario: Controller predates the published counters read

- **WHEN** the connected controller does not export `Flezha.Service.Controller.liveness_counters/1`
- **THEN** `liveness_snapshot` answers `{:error, {:api_missing, module, function, arity}}` and the divergence is logged, per the seam's version-skew requirement

### Requirement: Observability ring-buffer query

`NodeManager` SHALL expose `observability_query`, taking the query params map and calling `Flezha.Service.Observability.query/2` on the controller with the seam's caller context. The controller's own error answers — including the observability subsystem being disabled — SHALL pass through untouched, distinguishable from normalized transport failures.

#### Scenario: Query succeeds

- **WHEN** the observability subsystem is enabled and signals exist for the requested source
- **THEN** `observability_query` answers `{:ok, signals}` as the controller produced them

#### Scenario: Observability is disabled

- **WHEN** the controller's observability subsystem is disabled
- **THEN** `observability_query` answers the controller's error with code `observability.disabled`, and callers can render the affected region as absent rather than failed

### Requirement: Controller clock reference

`NodeManager` SHALL expose `controller_monotonic_us`, answering the connected controller's monotonic time in microseconds, read through the published consumer API like every other controller read. Observability signals are stamped with the controller's monotonic clock, which shares no epoch with this node's, so a caller judging a signal's age SHALL measure it against this reading rather than a local clock.

#### Scenario: Ageing a signal

- **WHEN** a caller holds a signal stamped with the controller's monotonic time
- **THEN** `controller_monotonic_us` answers a reading on that same clock, from which the signal's age follows

#### Scenario: The clock is read through a published function

- **WHEN** the call `controller_monotonic_us` makes is inspected
- **THEN** it names a published `Flezha.Service.*` function and passes the caller context last

### Requirement: Overwatch state decoding

`NodeManager` SHALL expose `overwatch_facts`, answering the facts screens read out of a relay's overwatch state — factory, runner binding, run, suspension, effectively-once, default input type, start time, uptime, relay class, and the hook-table entries — with each field's decoding rule applied once. The read SHALL go through `Flezha.Service.Relay.overwatch_state/3`. `overwatch_facts/0` SHALL answer the same shape with nothing in it, for a screen whose read failed.

#### Scenario: The run is read from the builder

- **WHEN** an overwatch state's builder carries `run: :steps`
- **THEN** `overwatch_facts` answers the run `steps`
- **AND** a builder carrying `run: :flow`, or no run, answers `flow`

#### Scenario: Relay class defaults to the id

- **WHEN** an overwatch state's builder declares no `relay_class` option
- **THEN** the answered relay class is the relay's own id, matching the controller's own rule

#### Scenario: The read fails

- **WHEN** the controller cannot answer the overwatch state
- **THEN** `overwatch_facts` answers the seam's normalized error, and a caller can fall back to `overwatch_facts/0` rather than special-casing every field

### Requirement: Registered-name identifiers

`identifier_id/1` SHALL answer the id out of a controller identifier whatever shape it arrives in, including the `:via` tuple a process registered through the controller's process registry is named by.

#### Scenario: A channel names itself through the registry

- **WHEN** a liveness snapshot reports a channel whose name is `{:via, Registry, {scope, id}}`
- **THEN** `identifier_id/1` answers `id` as text, rather than failing to render it

### Requirement: The caller context carries a bound principal

`NodeManager.caller_context/1` SHALL build the context the way `Flezha.Service.CallerContext.from_token/2` builds it on the controller: `source: :ui` plus the `principal`, `namespace`, and `role` that `Flezha.Service.Admin.context/2` returns for the token, and nothing else. Exactly one helper SHALL construct it, and every published operation SHALL be run through `Flezha.Service.Admin.run/4` with it.

#### Scenario: A verified token binds the context

- **WHEN** the UI's token verifies
- **THEN** the caller context carries `source: :ui`, the principal, the namespace, and the role from the verification result

#### Scenario: No token resolves

- **WHEN** no token verifies
- **THEN** the caller context carries `source: :ui` and no principal
- **AND** a call made with it is answered by the controller's own refusal rather than refused by the UI

#### Scenario: One construction site

- **WHEN** the codebase is searched for caller-context construction
- **THEN** exactly one helper constructs it

### Requirement: Namespace-flat listing reads

`NodeManager` SHALL expose the controller's bulk reads so a listing costs a fixed number of calls per namespace regardless of how many relays it holds: `Flezha.Service.Relay.list/2` for the rows, with partition members already collapsed into one row per group by the controller's rule, `Flezha.Service.Relay.relay_plugins/2` for the plugin bindings, and `Flezha.Service.Relay.registry/2` for each relay's run. A group's key-group coverage SHALL come from `Flezha.Service.Relay.partition_groups/2`. The UI SHALL NOT derive group rows, group health, or coverage itself.

#### Scenario: Listing a namespace's relays

- **WHEN** a screen lists a namespace's relays
- **THEN** one `Service.Relay.list/2` call answers every row's id, health, runner, factory, partition width, and node

#### Scenario: Listing plugin counts

- **WHEN** a screen shows a plugin count per relay
- **THEN** one `Service.Relay.relay_plugins/2` call answers the whole namespace

#### Scenario: Reading each relay's run

- **WHEN** a screen shows whether each relay runs as flow or steps
- **THEN** one `Service.Relay.registry/2` call answers it for the whole namespace, read from each relay's builder
- **AND** registry entries that are not relays, such as enabled plugins, are skipped rather than failing the read

#### Scenario: Partition groups are collapsed by the controller's rule

- **WHEN** a namespace holds partition group members
- **THEN** the group rows, and each group's health as its sickest member's, come from `Service.Relay.list/2`
- **AND** the UI contains no second implementation of group rollup or health ranking

#### Scenario: Call count does not grow with fleet size

- **WHEN** a namespace's relay count changes
- **THEN** the number of controller calls a listing tick makes does not change

### Requirement: A relay start carries no run

`NodeManager.start_relay` SHALL call `Flezha.Service.Relay.start/3` with the named fields core reads — `factory_id`, an optional `id`, `init_values`, `opts`, and, when given, `plugins` and `partitions` — and SHALL NOT send a run or any other field the start does not read. How a relay runs is the factory's, announced by its runners. The answer `{:ok, %{id: id, outcome: outcome}}` SHALL be returned to the caller unchanged, so a screen can name the id the relay runs under and say whether this call started it.

#### Scenario: Starting a relay with defaults

- **WHEN** a caller supplies only a namespace and a factory id
- **THEN** the fields sent to the controller are the factory id, `init_values: %{}`, and `opts: []`
- **AND** no id is sent, so the controller generates one

#### Scenario: Starting a relay under a chosen id

- **WHEN** a caller supplies an id
- **THEN** that id is sent with the other fields

#### Scenario: The answer names the started relay

- **WHEN** the controller answers `{:ok, %{id: id, outcome: :started}}`
- **THEN** `start_relay` answers the same, and the caller can name `id` without knowing whether it chose it

#### Scenario: No run is sent

- **WHEN** any start is made
- **THEN** the fields sent carry no run and no other field saying how the relay runs

### Requirement: Overwatch decoding covers the steps fields

`NodeManager.overwatch_facts` SHALL additionally decode `durable_steps`, `correction_window_ms`, `arrived_via_hotswap?`, and `init_error` from the overwatch state, alongside the fields it already decodes, so every screen reading relay facts receives them from one decoder.

#### Scenario: A durable steps relay

- **WHEN** the overwatch state reports `durable_steps: true`
- **THEN** the decoded facts carry it

#### Scenario: A field the controller does not carry

- **WHEN** an older controller's overwatch state omits one of the fields
- **THEN** the decoded facts carry a default for it rather than failing the decode

#### Scenario: One decoder

- **WHEN** the codebase is searched for overwatch field extraction
- **THEN** only `overwatch_facts` reads overwatch fields

### Requirement: Only the published consumer API is called

Every remote call `NodeManager` makes SHALL run an operation on core's published consumer surface — a `Flezha.Service.*` function listed in core's `docs/internal/api/consumers/published.txt` — through core's door, `Flezha.Service.Admin.run/4`, with the caller context and the placement `:given`, or be one of the two context-free calls, `Flezha.Service.Admin.context/2` and `Flezha.AuthZ.enforcement_posture/0`. The operation is named as core's catalogue names it, the module's last segment and the function (`"Relay.start"`). No top-level `Flezha` function, internal manager, store, configuration read, or non-Flezha module SHALL be called on the controller.

#### Scenario: Every call site is published

- **WHEN** core's consumer-surface script records the console's call sites
- **THEN** every recorded call resolves to a published function, the door, or one of the two context-free calls

#### Scenario: A call goes through the door

- **WHEN** `NodeManager` calls a published `Flezha.Service.*` function
- **THEN** it calls `Flezha.Service.Admin.run/4` with the operation's name, its arguments, the context `caller_context/1` built and `:given`

#### Scenario: Context-free calls stay context-free

- **WHEN** `NodeManager` verifies a token or reads the enforcement posture
- **THEN** it calls `Admin.context/2` or `AuthZ.enforcement_posture/0` with no caller context
- **AND** no other call is made without one

### Requirement: A controller error is shown with its code, hint and reference

Wherever the console shows a `%Flezha.Error{}`, it SHALL show the error's message, its `code`, its `hint` when it has one, and a link to the section of core's errors reference for the code's family (the part of the code before the first dot). The reference's base address SHALL come from application configuration, defaulting to `https://docs.flezha.com`. One component SHALL render every controller error and every diagnosis finding.

#### Scenario: An error with a hint

- **WHEN** a call fails with an error carrying a code and a hint
- **THEN** the message, the code and the hint are shown
- **AND** a link points at `<base>/errors.html#<family>` for that code

#### Scenario: An error without a hint

- **WHEN** an error's hint is `nil`
- **THEN** the message, code and link are shown and no empty hint is rendered

#### Scenario: The reference address is configured

- **WHEN** the application config sets a different docs base address
- **THEN** every error link uses that address

#### Scenario: A transport failure

- **WHEN** a call fails because no controller is connected or the call timed out
- **THEN** the existing transport message is shown and no reference link is rendered

### Requirement: The console calls only the configured controller

`NodeManager` SHALL send every remote call and open every stream only to the controller node named by `FLEZHA_NODE`, or by the `:flezha_node` application setting when that variable is unset. `NodeManager.connected_node/0` SHALL answer that node while it is connected and `nil` otherwise, whatever other nodes are connected to the console. No other connected node SHALL receive a call, a caller context or a token.

#### Scenario: Another node is connected as well

- **WHEN** the configured controller and another node are both connected to the console
- **THEN** every `NodeManager` call is answered by the configured controller
- **AND** the other node receives no call

#### Scenario: Only some other node is connected

- **WHEN** the configured controller is not connected but another node is
- **THEN** `NodeManager.connected_node/0` answers `nil`
- **AND** every `NodeManager` call answers `{:error, :node_not_connected}` without contacting the other node

#### Scenario: The configured controller comes back

- **WHEN** the configured controller reconnects after being away
- **THEN** the next `NodeManager` call is answered by it

