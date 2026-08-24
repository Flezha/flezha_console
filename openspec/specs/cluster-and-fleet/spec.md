# cluster-and-fleet Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Cluster membership view

The UI SHALL show the controller cluster's node membership, marking which node the UI is connected to.

#### Scenario: Single-node controller

- **WHEN** the controller runs alone
- **THEN** one node is listed and marked as the connected node

#### Scenario: Multi-node controller

- **WHEN** the controller is clustered with peers
- **THEN** every member node is listed
- **AND** the node the UI is connected to is distinguished from its peers

### Requirement: Namespace hub placement

The UI SHALL show, per namespace, which nodes host that namespace's hub.

#### Scenario: A namespace hub is running

- **WHEN** a namespace has a running hub
- **THEN** the namespace is listed with its hub nodes

#### Scenario: A namespace hub spans nodes

- **WHEN** a namespace's hub is present on more than one node
- **THEN** every hosting node is listed for that namespace

### Requirement: Runner fleet view

The UI SHALL list the active runners for a namespace with the factories each runner has registered.

#### Scenario: Runners are connected

- **WHEN** a namespace has active runners
- **THEN** each runner id is listed with its registered factory ids

#### Scenario: No runners are connected

- **WHEN** a namespace has no active runners
- **THEN** an empty state explains that no runner has connected to this namespace

#### Scenario: Runner list updates live

- **WHEN** a runner connects or disconnects while the screen is open
- **THEN** the list updates without a page reload

### Requirement: Factory placement lookup

An operator SHALL be able to select a factory and see which runners can serve it.

#### Scenario: A factory has runners

- **WHEN** an operator selects a factory registered in the namespace
- **THEN** the runners serving that factory are listed

#### Scenario: A factory has no runners

- **WHEN** a factory has no runner currently serving it
- **THEN** the screen states that no runner serves this factory

### Requirement: Per-node health rollup

The cluster screen SHALL show, per namespace and per node, how many operatives that node hosts broken down by health, and SHALL name the operatives that have no live node. The figures SHALL come from `Flezha.Service.HubManager.operative_rows/1`, the same rows the controller's own cluster status reads, so the UI and `flz cluster status` cannot disagree.

#### Scenario: A healthy cluster

- **WHEN** every operative in a namespace is healthy and placed
- **THEN** each node shows its operative count and the rollup reports no unhealthy operatives

#### Scenario: Operatives are unplaced

- **WHEN** registry rows have no live node
- **THEN** they are listed as unplaced and named

#### Scenario: A split view

- **WHEN** one node reports operatives and a peer reports none for the same namespace
- **THEN** the per-node counts make the disagreement visible

#### Scenario: The rollup agrees with the controller

- **WHEN** the same namespace is read by the UI and by `flz cluster status`
- **THEN** both report the same per-node counts and health breakdown

### Requirement: Hub recovery state

The cluster screen SHALL show each namespace hub's recovery state per node, so a hub still recovering is distinguishable from one that is serving.

#### Scenario: A hub is recovering

- **WHEN** a namespace's hub on a node reports a recovery in progress
- **THEN** that node's row states it is recovering

#### Scenario: A hub has finished recovery

- **WHEN** recovery has completed on every hosting node
- **THEN** the namespace is shown as serving

#### Scenario: Recovery state is unavailable

- **WHEN** the recovery read fails or is not exported by this controller
- **THEN** the column states that recovery state is unavailable and the rest of the screen still renders

### Requirement: Runner sessions carry their identity

The runner fleet view SHALL show, for each active runner, the namespace-derived principal the controller minted for it at connect, so an operator can tie a runner to what the audit log will name.

#### Scenario: A connected runner

- **WHEN** a runner is connected to a namespace
- **THEN** its runner id and its `runner@<namespace>` principal are shown

#### Scenario: The controller does not report principals

- **WHEN** the controller does not carry runner principals
- **THEN** the column is absent rather than showing a guess

