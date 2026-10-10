# cluster-and-fleet Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
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

The UI SHALL list the runners serving a namespace anywhere in the controller cluster, read from the cluster-wide `Flezha.Service.Fleet.runners/2`, with the factories each runner serves. The node-local `Flezha.Service.Fleet.runners_on_this_node/2` SHALL NOT be used for any listing that presents itself as the namespace's fleet.

#### Scenario: Runners are connected

- **WHEN** a namespace has active runners
- **THEN** each runner id is listed with its factory ids

#### Scenario: Runners on another node are listed

- **WHEN** a runner of the namespace is connected to a peer controller node rather than the node the UI is connected to
- **THEN** that runner is listed too

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

An operator SHALL be able to select a factory and see which runners can serve it. The factories SHALL come from `Flezha.Service.Fleet.factories/2`, each shown with its id, its description and its run (`flow` or `steps`) as the controller reports it, and the runners serving one factory from `Flezha.Service.Fleet.runners_for_factory/3`.

#### Scenario: A factory has runners

- **WHEN** an operator selects a factory registered in the namespace
- **THEN** the runners serving that factory are listed

#### Scenario: A factory's run is shown

- **WHEN** the factories of a namespace are listed
- **THEN** each factory states whether it runs as `flow` or as `steps`

#### Scenario: A factory has no runners

- **WHEN** a factory has no runner currently serving it
- **THEN** the screen states that no runner serves this factory

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

### Requirement: Runner rows show the runner's OS process id

Every runner listing SHALL show each runner's operating-system process id, from the `pid` that `Flezha.Service.Fleet.runners/2` answers. When the controller cannot say, the row SHALL show a placeholder rather than an empty cell. The pid SHALL be presented as information about the runner host and SHALL NOT be used by the console for any action.

#### Scenario: A connected runner

- **WHEN** a runner is connected and its control channel reports its process id
- **THEN** its row shows that process id

#### Scenario: The pid is unknown

- **WHEN** `runners/2` answers `pid: nil` for a runner
- **THEN** the row shows a placeholder in the pid column

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

