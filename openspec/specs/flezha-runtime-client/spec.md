# flezha-runtime-client Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
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

`NodeManager` SHALL classify every transport failure into exactly one of `{:error, :node_not_connected}`, `{:error, {:api_missing, module, function, arity}}`, `{:error, :timeout}`, or `{:error, {:remote_error, term}}`. A refusal or failure the controller answers SHALL arrive as `{:error, error}`, where `error` is a map read from the channel's error body, carrying `code`, `class` (one of the controller's classes, as an atom), `message`, `details` (with text keys), and `hint`. The UI SHALL read that error by its fields, without needing core's modules loaded on its own node. Raw HTTP responses, Finch or Mint errors, and TLS alerts SHALL NOT escape `NodeManager`.

#### Scenario: No controller is reachable

- **WHEN** any `NodeManager` function is called while the controller refuses the connection, cannot be resolved, or fails the TLS handshake
- **THEN** it returns `{:error, :node_not_connected}`
- **AND** no exception is raised

#### Scenario: The door does not publish the operation

- **WHEN** the channel answers the error code `control.unknown_function` for an operation
- **THEN** `NodeManager` returns `{:error, {:api_missing, module, function, arity}}` naming the published function it asked for
- **AND** the mismatch is logged at warning level

#### Scenario: The controller does not answer in time

- **WHEN** the channel answers `control.timeout`, or the console's own deadline for the call passes
- **THEN** `NodeManager` returns `{:error, :timeout}`

#### Scenario: The controller refuses the call

- **WHEN** authorization refuses a call, or no principal is bound
- **THEN** `NodeManager` returns `{:error, error}` where `error.class` is `:denied` and `error.code` names the refusal, such as `authz.role_insufficient` or `authz.principal_not_bound`
- **AND** the refusal is not folded into `{:remote_error, term}`

#### Scenario: The controller answers a domain failure

- **WHEN** a published function answers an error for a reason of its own, such as `relay.not_found`
- **THEN** `NodeManager` returns that `{:error, error}` with the code, class, message, details and hint the body carried, rather than wrapping it as a transport failure

#### Scenario: An answer that is not the channel's

- **WHEN** the controller answers with a body that is neither a decodable answer nor an error object
- **THEN** `NodeManager` returns `{:error, {:remote_error, term}}`

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

`NodeManager` SHALL expose `liveness_snapshot`, calling `Flezha.Service.Controller.liveness_counters` with the caller context and answering the controller's own map of `channels` and `relays` counter lists, with transport failures normalized into the seam's closed error set. It SHALL take the relays to read, as `{namespace, relay_id}` pairs of at most 500, or a namespace whose summed `totals` to read with `limit: 0`. It SHALL key every relay snapshot by namespace and relay id. A screen SHALL NOT read the unfiltered cluster snapshot to draw rates. Reads with the same token and arguments within 1.5 s SHALL be answered once from `NodeManager`'s read cache.

#### Scenario: Snapshot succeeds

- **WHEN** the controller answers the liveness counters for the named relays
- **THEN** `liveness_snapshot` answers the map of per-channel and per-relay counter snapshots as the controller produced it, each relay snapshot keyed by namespace and `relay_id`

#### Scenario: A namespace's totals

- **WHEN** Dashboard asks for its namespace's flow
- **THEN** `liveness_snapshot` asks for that namespace's totals with `limit: 0`, and answers the summed counters with no relay rows

#### Scenario: Two tabs share one read

- **WHEN** two screens with the same token ask for the same relays' counters within 1.5 s
- **THEN** the controller is called once

#### Scenario: Controller predates the published counters read

- **WHEN** the connected controller does not export `Flezha.Service.Controller.liveness_counters`
- **THEN** `liveness_snapshot` answers `{:error, {:api_missing, module, function, arity}}` and the divergence is logged, per the seam's version-skew requirement

### Requirement: Observability ring-buffer query

`NodeManager` SHALL expose `observability_query`, taking the query params map and calling `Flezha.Service.Observability.query/2` on the controller with the seam's caller context. The controller's own error answers — including the observability subsystem being disabled — SHALL pass through untouched, distinguishable from normalized transport failures.

#### Scenario: Query succeeds

- **WHEN** the observability subsystem is enabled and signals exist for the requested source
- **THEN** `observability_query` answers `{:ok, signals}` as the controller produced them

#### Scenario: Observability is disabled

- **WHEN** the controller's observability subsystem is disabled
- **THEN** `observability_query` answers the controller's error with code `observability.disabled`, and callers can render the affected region as absent rather than failed

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

### Requirement: Namespace-flat listing reads

`NodeManager` SHALL expose the controller's paged relay list so a listing costs a fixed number of calls per namespace, however many relays it holds, and answers only the rows it shows: `Flezha.Service.Relay.list` with `opts` of `limit`, `after`, `sort` and `filter`. Its rows carry partition members already collapsed into one row per group by the controller's rule, each row's run and plugin count, and the namespace `summary` (health counts, faulted groups, factories relays wait on). One relay's row SHALL be read with the `ids` filter. A group's members SHALL be read with the `group` filter. Faulted groups SHALL come from the summary. The UI SHALL NOT derive group rows, group health or coverage itself, and SHALL NOT send relay rows back to the controller.

#### Scenario: Listing a namespace's relays

- **WHEN** a screen lists a namespace's relays
- **THEN** one paged `Service.Relay.list` call answers the shown rows' id, health, runner, factory, partition width, node, run and plugin count, and the total

#### Scenario: Counting without rows

- **WHEN** a screen needs only the namespace's health counts and faulted groups
- **THEN** it reads them from the summary of a paged call with `limit: 0` or with only the rows it shows

#### Scenario: Partition groups are collapsed by the controller's rule

- **WHEN** a namespace holds partition group members
- **THEN** the group rows, and each group's health as its sickest member's, come from `Service.Relay.list`
- **AND** the UI contains no second implementation of group rollup or health ranking

#### Scenario: Call count does not grow with fleet size

- **WHEN** a namespace's relay count changes
- **THEN** the number of controller calls a listing tick makes does not change, and the rows it receives do not exceed the rows it shows

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

Every call and stream `NodeManager` makes SHALL name an operation on core's published consumer surface, a `Flezha.Service.*` function listed in core's `docs/internal/api/consumers/published.txt`, as the channel's route `/v1/call/<operation>` or `/v1/stream/<operation>`. The operation is named as core's catalogue names it, the module's last segment and the function (`"Relay.start"`). Each call site SHALL spell the published module in full, so core's consumer-surface script can record it. No other route of the controller SHALL be requested, except the unauthenticated reachability probe of the connector.

#### Scenario: Every call site is published

- **WHEN** core's consumer-surface script records the console's call sites
- **THEN** every recorded call resolves to a published function

#### Scenario: A call names its operation

- **WHEN** `NodeManager` calls a published `Flezha.Service.*` function
- **THEN** it requests `/v1/call/<Module>.<function>` with the function's arguments before the caller context, in order

#### Scenario: No context-free call remains

- **WHEN** `lib/` is searched for `Admin.context`, `Admin.run` or `AuthZ.enforcement_posture`
- **THEN** no occurrence exists

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

`NodeManager` SHALL send every call and open every stream only to the controller `FLEZHA_CONTROLLER_URL` names. When its host resolves to several addresses, the console SHALL pin one address that answers and keep it while it answers. When that address stops answering, the console SHALL move to another address the name resolves to. `NodeManager.connected_node/0` SHALL answer the name of the controller the channel reaches, as text, while the channel is up, and `nil` otherwise. The name SHALL be taken from the `local?` row of the latest `Controller.controllers` answer, and before any such answer it SHALL be the URL's host.

#### Scenario: The name resolves to two controllers

- **WHEN** the configured host resolves to two controllers that both answer
- **THEN** every call and stream goes to the same one until it stops answering

#### Scenario: The pinned controller goes away

- **WHEN** the pinned controller stops answering and another address of the name answers
- **THEN** `connected_node/0` answers `nil` until the connector reaches the other address
- **AND** the next call is answered by the other controller

#### Scenario: The controller is unreachable

- **WHEN** no address of the configured host answers
- **THEN** `NodeManager.connected_node/0` answers `nil`
- **AND** every `NodeManager` call answers `{:error, :node_not_connected}`

#### Scenario: The configured controller comes back

- **WHEN** the configured controller answers again after being away
- **THEN** the next `NodeManager` call is answered by it

### Requirement: Single controller seam

All calls and streams from the console to the flezha controller SHALL pass through `FlezhaConsole.Service.NodeManager`, over the controller's HTTPS channel. No LiveView, controller, or other service module SHALL make an HTTP request to the controller, invoke `:erpc`, or reference a `Flezha.*` remote module name directly.

#### Scenario: A LiveView needs controller data

- **WHEN** a LiveView needs data or an action from the controller
- **THEN** it calls a named `NodeManager` function
- **AND** no `Flezha.*` module name appears outside `NodeManager`

#### Scenario: A new controller call is added

- **WHEN** a new controller API is needed by any screen
- **THEN** the remote module, function, and argument shape are declared in `NodeManager` only

#### Scenario: No distribution call remains

- **WHEN** `lib/` and `config/` are searched for `:erpc`, `Node.connect`, `Node.monitor` aimed at the controller, or `RELEASE_COOKIE`
- **THEN** no occurrence exists

### Requirement: The channel is HTTPS with a client certificate

`NodeManager` SHALL send every call as `POST /v1/call/<operation>` and open every stream as `POST /v1/stream/<operation>` on the controller named by `FLEZHA_CONTROLLER_URL`. Each request SHALL carry the arguments as a JSON array and the operator's token as a bearer token. An `https` URL SHALL be reached over HTTP/2 with TLS 1.3, presenting the certificate in `FLEZHA_CLIENT_CERT` with its key `FLEZHA_CLIENT_KEY`, and SHALL accept only a server certificate that chains to `FLEZHA_CONTROLLER_CA` and names the URL's host. A plain `http` URL SHALL be accepted only for a loopback address. The application SHALL refuse to start, naming the variable, when an `https` URL lacks any of the three files or one cannot be read, or when an `http` URL is not loopback.

#### Scenario: A call over the channel

- **WHEN** a screen asks `NodeManager` for the relays of a namespace
- **THEN** one `POST /v1/call/Relay.list` carrying the namespace in a JSON array and the token as a bearer token reaches the controller

#### Scenario: The controller presents a certificate from another authority

- **WHEN** the controller's server certificate does not chain to `FLEZHA_CONTROLLER_CA`
- **THEN** no request is sent
- **AND** every call answers `{:error, :node_not_connected}` and the log names the certificate refusal

#### Scenario: The client certificate is missing

- **WHEN** the console starts with an `https` URL and no `FLEZHA_CLIENT_CERT`
- **THEN** it refuses to start and its output names `FLEZHA_CLIENT_CERT`

#### Scenario: Plain HTTP off loopback

- **WHEN** the console starts with `FLEZHA_CONTROLLER_URL=http://10.0.0.5:8765`
- **THEN** it refuses to start and says that plain HTTP is accepted only on loopback

### Requirement: Answers are decoded by the recorded shapes

`NodeManager` SHALL decode every answer and every stream event from JSON using the recorded shape of its operation or event, shipped with the application. A record's keys SHALL become atoms and a dict's keys SHALL stay text. A value whose shape is an atom SHALL become an existing atom, or stay text when no such atom exists. A node's name SHALL always be text. A value whose shape is a tuple SHALL become a tuple, a time SHALL become a `DateTime`, and a stream event SHALL become the tuple its screen matches. A key the shape does not name SHALL become an existing atom, or stay text when no such atom exists, with its value read as free-form data. Decoding SHALL NOT create an atom from the controller's data, and every atom the console's own code names SHALL exist before an answer is decoded. Every operation `NodeManager` names and every event a stream can deliver SHALL have a recorded shape.

#### Scenario: A list of relays

- **WHEN** the controller answers `Relay.list` with rows whose `health` is `"healthy"`
- **THEN** a screen receives `{:ok, %{rows: [%{health: :healthy, ...}], unreachable: []}}`

#### Scenario: A relay output event

- **WHEN** a `Relay.listen` stream delivers an `output` event
- **THEN** the feed's owner receives `{:feed_event, tag, {:output, payload, meta}}`, as it did over distribution

#### Scenario: A value naming no known atom

- **WHEN** an answer carries a node name in a field whose shape is an atom
- **THEN** the decoded value is that name as text
- **AND** the console's atom count does not grow by it

#### Scenario: A field the recording never saw filled

- **WHEN** an answer carries a key its recorded shape does not name, such as a partition a recorded row did not have
- **THEN** the key becomes the atom the console's code reads it by
- **AND** its value is read as free-form data

#### Scenario: An operation without a recorded shape

- **WHEN** `NodeManager` names an operation for which no shape is recorded
- **THEN** `mix test` fails naming the operation

