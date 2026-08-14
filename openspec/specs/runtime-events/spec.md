# runtime-events Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Subscriptions run in a node-resident relay

For every controller API that registers the calling process as a subscriber, the UI SHALL establish the subscription from a relay process spawned on the flezha node, and that relay SHALL forward received messages to a named UI process. The UI SHALL NOT establish such subscriptions with a direct `:erpc` call, because the process an `:erpc` call runs in does not outlive the call.

#### Scenario: Establishing the event subscription

- **WHEN** the event bridge connects to the controller
- **THEN** a relay process is spawned on the flezha node
- **AND** the relay calls `Flezha.Service.EventManager.add_handler/1` from its own process
- **AND** the relay remains alive after the establishing call returns

### Requirement: The relay is shipped to the controller as a module

The relay SHALL be a named module whose object code is loaded onto the controller before it is spawned, and it SHALL reference only OTP and `Flezha.*` modules. The UI SHALL NOT spawn an anonymous function on the controller, since a function carries its defining module and no module of this application exists there.

#### Scenario: The controller has none of this application's code

- **WHEN** the relay is started on a node whose code path excludes this application
- **THEN** the relay module is loaded onto that node first
- **AND** the relay runs there without `:undef`

#### Scenario: The relay module cannot be loaded

- **WHEN** loading the relay onto the controller fails
- **THEN** the bridge reports the failure and retries rather than spawning a relay that cannot run

### Requirement: Runner lifecycle events reach LiveViews

Runner connect and disconnect events SHALL be relayed from the controller and broadcast on the UI's PubSub so subscribed LiveViews update without a page reload.

#### Scenario: A runner connects

- **WHEN** the controller dispatches `:runner_connected_event`
- **THEN** the relay forwards it and the bridge broadcasts a runner-connected message
- **AND** subscribed LiveViews update their runner list

#### Scenario: A runner disconnects

- **WHEN** the controller dispatches `:runner_disconnected_event`
- **THEN** subscribed LiveViews reflect the runner's departure

#### Scenario: Old event names are gone

- **WHEN** the codebase is searched for `compute_engine_connected` or `compute_engine_disconnected`
- **THEN** no occurrence exists

### Requirement: Relay recovery

The bridge SHALL monitor its relay and re-establish the subscription when the relay dies or the controller node reconnects. Before spawning a replacement, it SHALL remove the prior handler and terminate any prior relay, so at most one relay per subscription exists at any time.

#### Scenario: The controller node restarts

- **WHEN** the controller goes down and comes back
- **THEN** the bridge establishes a new relay
- **AND** events flow again without restarting the UI

#### Scenario: Reconnect does not duplicate subscribers

- **WHEN** the bridge reconnects several times
- **THEN** exactly one relay is registered on the controller
- **AND** each event is broadcast to the UI exactly once

#### Scenario: The relay cannot be established

- **WHEN** relay spawning fails
- **THEN** the bridge retries on its backoff interval
- **AND** affected screens fall back to periodic refresh so data still updates

