# cluster-and-fleet Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: The Cluster screen opens with an overview in tiles

Above its nodes, the Cluster screen SHALL show one row of tiles for everything the
operator's token reaches:

- **Namespaces:** how many are reachable.
- **Controller nodes:** how many, and which one this console is connected to.
- **Runners:** how many distinct runners serve any reachable namespace. A runner
  answered by more than one namespace SHALL count once, here and in the screen's
  sentence.
- **Relays:** how many across the reachable namespaces, with a health strip and
  the healthy count.
- **Open problems:** how many, in the tone of the worst, linking to `/problems`.
- **Controller:** whether it is connected, its durability posture, and its
  durability breaches.

Namespaces, nodes, runners and the controller's posture SHALL come from the reads
this screen already makes. Relay health, open problems and durability breaches
SHALL come from the shell pulse (see `attention`). The row SHALL show a skeleton
until the pulse has answered once.

#### Scenario: Two namespaces are reachable

- **WHEN** the token reaches `default` with three relays and `sandbox` with two
- **THEN** the Namespaces tile reads 2 and the Relays tile reads 5

#### Scenario: One runner serves two namespaces

- **WHEN** both reachable namespaces answer the same runner
- **THEN** the Runners tile reads 1 and the sentence says one runner

#### Scenario: Nothing needs attention

- **WHEN** no attention item is open anywhere
- **THEN** the Open problems tile reads that nothing needs attention, in the
  positive tone

#### Scenario: A durability breach

- **WHEN** the controller reports a durability RPO breach
- **THEN** the Controller tile says so in words and in the negative tone

### Requirement: Cluster membership view

The UI SHALL show the controller cluster's node membership, marking which node the UI is connected to. The node list SHALL be the union of the nodes `Flezha.Service.Controller.cluster_status/2` answers for each namespace the caller can see; the UI SHALL NOT call `:erlang.nodes/1` or any other unpublished function on the controller to list members. A node that hosts no hub for any namespace visible to the caller is not listed.

#### Scenario: Single-node controller

- **WHEN** the controller runs alone
- **THEN** one node is listed and marked as the connected node

#### Scenario: Multi-node controller

- **WHEN** the controller is clustered with peers
- **THEN** every member node that hosts a hub for a namespace the caller can see is listed
- **AND** the node the UI is connected to is distinguished from its peers

#### Scenario: Membership is read through the published API

- **WHEN** `lib/` is searched for `:erlang.nodes`
- **THEN** no call made on the controller node is found

### Requirement: Namespace hub placement

The UI SHALL show, per namespace, which nodes host that namespace's hub, read from the nodes `Flezha.Service.Controller.cluster_status/2` answers for it.

#### Scenario: A namespace hub is running

- **WHEN** a namespace has a running hub
- **THEN** the namespace is listed with its hub nodes

#### Scenario: A namespace hub spans nodes

- **WHEN** a namespace's hub is present on more than one node
- **THEN** every hosting node is listed for that namespace

#### Scenario: The read is refused

- **WHEN** `cluster_status/2` answers `{:error, %Flezha.Error{class: :denied}}`
- **THEN** the namespace's hub column states the refusal and the rest of the screen still renders

### Requirement: Runner fleet view

The UI SHALL list the runners serving a namespace anywhere in the controller cluster, read from the cluster-wide `Flezha.Service.Fleet.runners/2`. The node-local `Flezha.Service.Fleet.runners_on_this_node/2` SHALL NOT be used for any listing that presents itself as the namespace's fleet.

Each runner SHALL be listed with:

- the controller node that holds its session;
- how long it has been connected, with the absolute connect time;
- how long ago the controller last heard from it, in the warning tone when the controller answers `late?`;
- the number of relays on it, linking to the relays index filtered to that runner;
- the factories it serves, from the `runners` of each `Flezha.Service.Fleet.factories/2` row.

The Serves cell SHALL show at most two factories, plus a control that reveals the rest and states how many there are. When other runners serve exactly the same set of factories, the cell SHALL say how many.

Above the table, the listing SHALL state how many runners are connected, on how many nodes, how many factories they serve, and how many are late. An operator SHALL be able to:

- filter the runners by runner id or factory;
- limit them to one node;
- show only late runners;
- sort them, with late runners first by default.

#### Scenario: Runners are connected

- **WHEN** a namespace has active runners
- **THEN** each runner id is listed with its node, connection time, last contact, relay count and factories

#### Scenario: Runners on another node are listed

- **WHEN** a runner of the namespace is connected to a peer controller node rather than the node the UI is connected to
- **THEN** that runner is listed too, with that peer as its node

#### Scenario: A runner is late

- **WHEN** `runners/2` answers `late?: true` for a runner
- **THEN** its last-contact cell has the warning tone
- **AND** the summary counts it as late
- **AND** it is listed before runners that are not late under the default sort

#### Scenario: A runner serves many factories

- **WHEN** a runner serves more than two factories
- **THEN** its Serves cell shows two of them and a control stating how many more there are
- **AND** using that control shows every factory it serves

#### Scenario: Runners share a factory set

- **WHEN** other runners serve exactly the same factories as a runner
- **THEN** that runner's Serves cell says how many other runners serve the same set

#### Scenario: Filtering runners

- **WHEN** an operator enters a factory id in the runner filter
- **THEN** only runners serving a factory matching it are listed
- **AND** the summary still counts the whole fleet

#### Scenario: Only late runners

- **WHEN** an operator ticks "Late only"
- **THEN** only runners answered `late?: true` are listed

#### Scenario: The controller answers no connection facts

- **WHEN** a runner row carries no `node`, `connected_at` or `silent_ms`
- **THEN** those cells show a placeholder and the runner is still listed

#### Scenario: No runners are connected

- **WHEN** a namespace has no active runners
- **THEN** an empty state explains that no runner has connected to this namespace

#### Scenario: Runner list updates live

- **WHEN** a runner connects or disconnects while the screen is open
- **THEN** the list updates without a page reload

#### Scenario: The node-local read is not mistaken for the fleet

- **WHEN** `lib/` is searched for `runners_on_this_node`
- **THEN** no runner listing screen calls it

### Requirement: Factory placement lookup

An operator SHALL be able to select a factory and see which runners can serve it. The factories SHALL come from `Flezha.Service.Fleet.factories/2`, each shown with its id, its description and its run (`flow` or `steps`) as the controller reports it. The runners serving each factory SHALL come from the `runners` that the same `factories/2` row carries. The console SHALL NOT call `Flezha.Service.Fleet.runners_for_factory/3` once per factory to build a listing.

#### Scenario: A factory has runners

- **WHEN** an operator selects a factory registered in the namespace
- **THEN** the runners serving that factory are listed

#### Scenario: A factory's run is shown

- **WHEN** the factories of a namespace are listed
- **THEN** each factory states whether it runs as `flow` or as `steps`

#### Scenario: A factory has no runners

- **WHEN** a factory has no runner currently serving it
- **THEN** the screen states that no runner serves this factory

#### Scenario: One read per refresh

- **WHEN** the cluster screen refreshes a namespace with many factories
- **THEN** it reads the factories and their runners with one `factories/2` call
- **AND** makes no `runners_for_factory/3` call

### Requirement: Per-node health rollup

The cluster screen SHALL show, per namespace and per node, how many relays that node hosts broken down by health, and SHALL name the relays that have no live node. The figures SHALL come from `Flezha.Service.Relay.relay_rows/2`, the same rows `Flezha.Service.Controller.cluster_status/2` and `flz cluster status` read, so the UI and the controller cannot disagree. Every health verdict the controller returns SHALL be counted under its own name, including `recovering` and `parked`.

#### Scenario: A healthy cluster

- **WHEN** every relay in a namespace is healthy and placed
- **THEN** each node shows its relay count and the rollup reports no unhealthy relays

#### Scenario: Relays are unplaced

- **WHEN** relay rows have no live node
- **THEN** they are listed as unplaced and named

#### Scenario: Relays are moving off a dead runner

- **WHEN** relay rows report the verdict `recovering` or `parked`
- **THEN** the rollup counts them under that verdict rather than as unknown

#### Scenario: A split view

- **WHEN** one node reports relays and a peer reports none for the same namespace
- **THEN** the per-node counts make the disagreement visible

#### Scenario: The rollup agrees with the controller

- **WHEN** the same namespace is read by the UI and by `flz cluster status`
- **THEN** both report the same per-node counts and health breakdown

### Requirement: Hub recovery state

The cluster screen SHALL show each namespace hub's recovery state per node, read from the per-node `recovery_state` `Flezha.Service.Controller.cluster_status/2` answers, so a hub still recovering is distinguishable from one that is serving.

#### Scenario: A hub is recovering

- **WHEN** a namespace's hub on a node reports a recovery in progress
- **THEN** that node's row states it is recovering

#### Scenario: A hub has finished recovery

- **WHEN** recovery has completed on every hosting node
- **THEN** the namespace is shown as serving

#### Scenario: A node cannot be reached

- **WHEN** `cluster_status/2` answers `:unreachable` as one node's recovery state
- **THEN** that node's row states it could not be reached and the other nodes' states are still shown

#### Scenario: Recovery state is unavailable

- **WHEN** the recovery read fails or is refused
- **THEN** the column states that recovery state is unavailable and the rest of the screen still renders

### Requirement: Runner sessions carry their identity

The runner fleet view SHALL show, for each active runner, the namespace-derived principal the controller mints for it at connect, read from `Flezha.Service.Fleet.runner_caller_context/2`, so an operator can tie a runner to what the audit log will name.

#### Scenario: A connected runner

- **WHEN** a runner is connected to a namespace
- **THEN** its runner id and its `runner@<namespace>` principal are shown

#### Scenario: The controller does not report principals

- **WHEN** the controller's answer carries no principal, or the read fails
- **THEN** the column is absent rather than showing a guess

### Requirement: Recovery can be inspected per hub and per namespace

The cluster screen SHALL let the operator open a namespace's recovery detail. The
detail SHALL show the hub id from `Flezha.Service.Controller.hub_id/2`, that hub's
recovery state on the node the console is connected to from
`Flezha.Service.Controller.recovery_state/2`, and the namespace's recovery state on
every cluster node from `Flezha.Service.Controller.recovery_per_node/3`. The local
hub SHALL be read only when the connected node hosts the namespace's hub, and the
local and per-node reads SHALL fail independently. It SHALL refresh on the tick
while open.

#### Scenario: Opening a namespace's recovery

- **WHEN** the operator opens the recovery detail of a namespace
- **THEN** the hub id, the local hub state and one row per cluster node with its
  recovery state are shown

#### Scenario: A node is unreachable

- **WHEN** `recovery_per_node/3` answers `:unreachable` for one node
- **THEN** that node's row states it could not be reached and the other rows still
  show their state

#### Scenario: Recovery finishes while the detail is open

- **WHEN** a node's state changes from recovering to serving
- **THEN** its row shows serving on the next tick, without a reload

#### Scenario: The connected node hosts no hub for the namespace

- **WHEN** the namespace's hub runs only on other nodes
- **THEN** the local state reads "no hub on this node", the local hub is not asked,
  and every node's row still shows

#### Scenario: The per-node read is refused

- **WHEN** `recovery_per_node/3` answers an error
- **THEN** the hub id and the local state still show, with the per-node error
  beside them

#### Scenario: The recovery read is refused

- **WHEN** either read answers an error
- **THEN** the detail shows the error with its code and hint, and the rest of the
  cluster screen still renders

