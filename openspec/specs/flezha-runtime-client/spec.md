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

