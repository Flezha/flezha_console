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

