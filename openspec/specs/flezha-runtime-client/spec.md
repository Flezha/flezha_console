# flezha-runtime-client Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Single ERPC seam

All calls from the UI into the flezha controller SHALL pass through `FlezhaUi.Service.NodeManager`. No LiveView, controller, or other service module SHALL invoke `:erpc` or reference a `Flezha.*` remote module name directly.

#### Scenario: A LiveView needs controller data

- **WHEN** a LiveView needs data or an action from the controller
- **THEN** it calls a named `NodeManager` function
- **AND** no `Flezha.*` module name appears outside `NodeManager`

#### Scenario: A new controller call is added

- **WHEN** a new controller API is needed by any screen
- **THEN** the remote module, function, and argument shape are declared in `NodeManager` only

### Requirement: Controller vocabulary matches flezha

`NodeManager` SHALL expose the current flezha API under its current names: `list_namespaces/0`, `list_operatives/1`, `list_runners/1`, `list_factories/1`, `start_operative/5`, `stop_operative/2`, `entity_state/2`, `entity_state/3`, and `get_overwatch_state/2`.

#### Scenario: Listing operatives in a namespace

- **WHEN** `NodeManager.list_operatives/1` is called with a namespace
- **THEN** it invokes `Flezha.list_operatives/1` on the connected node
- **AND** returns the operative id list

#### Scenario: Listing runners in a namespace

- **WHEN** `NodeManager.list_runners/1` is called with a namespace
- **THEN** it invokes `Flezha.list_runners/1` on the connected node

#### Scenario: Removed names are absent

- **WHEN** the codebase is searched for `list_processors`, `list_compute_engines`, `start_processor`, `stop_processor`, or `processor_state`
- **THEN** no occurrence exists in `lib/`, `test/`, or `e2e/`

### Requirement: Operative start builds a valid operative spec

`NodeManager.start_operative/5` SHALL construct a spec carrying `id`, `factory_id`, `kind`, `init_values`, and `opts` and pass it to `Flezha.start_operative/2`, defaulting `kind` to `:stream` when the caller does not supply one.

#### Scenario: Starting an operative with defaults

- **WHEN** a caller supplies only namespace, id, and factory id
- **THEN** the spec sent to the controller carries `kind: :stream`, `init_values: %{}`, and `opts: []`

#### Scenario: Starting an operative with an explicit kind

- **WHEN** a caller supplies `kind: :workflow`
- **THEN** the spec sent to the controller carries `kind: :workflow`

### Requirement: Errors are normalized into a closed set

`NodeManager` SHALL classify every remote-call failure into exactly one of `{:error, :node_not_connected}`, `{:error, {:api_missing, module, function, arity}}`, `{:error, :timeout}`, or `{:error, {:remote_error, term}}`. Raw `:erpc` exits and `:badrpc` tuples SHALL NOT escape `NodeManager`.

#### Scenario: No controller node is connected

- **WHEN** any `NodeManager` function is called while no flezha node is connected
- **THEN** it returns `{:error, :node_not_connected}`
- **AND** no exception is raised

#### Scenario: The controller lacks the called function

- **WHEN** a remote call raises `:undef` because the controller does not export it
- **THEN** `NodeManager` returns `{:error, {:api_missing, module, function, arity}}`
- **AND** the remote stacktrace is logged at warning level

#### Scenario: The controller does not answer in time

- **WHEN** a remote call exceeds its timeout
- **THEN** `NodeManager` returns `{:error, :timeout}`

#### Scenario: The controller returns a domain error

- **WHEN** the remote function itself returns `{:error, reason}`
- **THEN** `NodeManager` returns that `{:error, reason}` unchanged rather than wrapping it as a transport failure

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

`NodeManager` SHALL expose `liveness_snapshot/0`, calling `Flezha.Transport.LivenessCounters.snapshot_all/0` on the controller and answering the controller's own map of `channels` and `operatives` counter lists, with transport failures normalized into the seam's closed error set.

#### Scenario: Snapshot succeeds

- **WHEN** the controller exports the liveness counters module
- **THEN** `liveness_snapshot/0` answers the map of per-channel and per-operative counter snapshots as the controller produced it

#### Scenario: Controller predates liveness counters

- **WHEN** the connected controller does not export `Flezha.Transport.LivenessCounters.snapshot_all/0`
- **THEN** `liveness_snapshot/0` answers `{:error, {:api_missing, module, function, arity}}` and the divergence is logged, per the seam's version-skew requirement

### Requirement: Observability ring-buffer query

`NodeManager` SHALL expose `observability_query/1`, taking the query params map and calling `Flezha.Service.Observability.query/2` on the controller with the seam's caller context. The remote's own `{:error, reason}` answers — including the observability subsystem being disabled — SHALL pass through untouched, distinguishable from normalized transport failures.

#### Scenario: Query succeeds

- **WHEN** the observability subsystem is enabled and signals exist for the requested source
- **THEN** `observability_query/1` answers `{:ok, signals}` as the controller produced them

#### Scenario: Observability is disabled

- **WHEN** the controller's observability subsystem is disabled
- **THEN** `observability_query/1` answers the controller's own error reason untouched, and callers can render the affected region as absent rather than failed

### Requirement: Controller clock reference

`NodeManager` SHALL expose `controller_monotonic_us/0`, answering the connected controller's monotonic time in microseconds. Observability signals are stamped with the controller's monotonic clock, which shares no epoch with this node's, so a caller judging a signal's age SHALL measure it against this reading rather than a local clock.

#### Scenario: Ageing a signal

- **WHEN** a caller holds a signal stamped with the controller's monotonic time
- **THEN** `controller_monotonic_us/0` answers a reading on that same clock, from which the signal's age follows

### Requirement: Overwatch state decoding

`NodeManager` SHALL expose `overwatch_facts/2`, answering the facts screens read out of an operative's overwatch state — factory, runner binding, kind, suspension, effectively-once, default input type, start time, uptime, dead-letter class, and the extension-table entries — with each field's decoding rule applied once. `overwatch_facts/0` SHALL answer the same shape with nothing in it, for a screen whose read failed.

#### Scenario: Kind falls back to the builder

- **WHEN** an overwatch state carries no `kind` but its builder does
- **THEN** `overwatch_facts/2` answers the builder's kind

#### Scenario: Dead-letter class defaults to the id

- **WHEN** an overwatch state's builder declares no `operative_class` option
- **THEN** the answered dead-letter class is the operative's own id, matching the controller's own rule

#### Scenario: The read fails

- **WHEN** the controller cannot answer the overwatch state
- **THEN** `overwatch_facts/2` answers the seam's normalized error, and a caller can fall back to `overwatch_facts/0` rather than special-casing every field

### Requirement: Registered-name identifiers

`identifier_id/1` SHALL answer the id out of a controller identifier whatever shape it arrives in, including the `:via` tuple an entity registered through the controller's process registry is named by.

#### Scenario: A channel names itself through the registry

- **WHEN** a liveness snapshot reports a channel whose name is `{:via, Registry, {scope, id}}`
- **THEN** `identifier_id/1` answers `id` as text, rather than failing to render it
