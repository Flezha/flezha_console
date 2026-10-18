# controller-health Specification

## Purpose
TBD - created by archiving change resync-with-flezha-platform. Update Purpose after archive.
## Requirements
### Requirement: Durability posture is visible

The controller screen SHALL show the configured backend, the posture, the count of RPO breaches and the count of superseded shipments from one read of `Flezha.Service.Controller.status/1`, and the breached references from `durability_breaches/1`, each called with the UI's caller context.

#### Scenario: The remote tier is enabled

- **WHEN** the posture is `:remote_tier`
- **THEN** the backend, breach count, and superseded count are shown

#### Scenario: The controller is local-only

- **WHEN** the posture is `:local_only`
- **THEN** the screen states that durable state has exactly one copy
- **AND** it is presented as a stated posture, not as an alarm

#### Scenario: References are past their RPO target

- **WHEN** `durability_breaches/1` answers a non-empty list
- **THEN** the breached references are listed with how far past target they are

#### Scenario: A durability read is refused

- **WHEN** the status read answers `{:error, %Flezha.Error{class: :denied}}`
- **THEN** the durability panel states the refusal with its code and message
- **AND** the rest of the screen still renders

### Requirement: Shutdown and boot status

The controller screen SHALL show the shutdown state `Flezha.Service.Controller.status/1` carries — whether a shutdown is in progress, its phase, the signal handler status, and the graceful-shutdown setting and timeout — and the controller's boot status from `Flezha.Service.Controller.boot_status/1`: the readiness verdict and each running namespace's hub recovery state.

#### Scenario: The controller is running normally

- **WHEN** no shutdown is in progress
- **THEN** the screen states so and shows the graceful-shutdown configuration

#### Scenario: A shutdown is in progress

- **WHEN** a shutdown is under way
- **THEN** the current phase is shown and refreshes on the tick

#### Scenario: Boot status is shown per namespace

- **WHEN** `boot_status/1` answers a readiness verdict and a list of namespaces
- **THEN** the screen shows the verdict and, for each namespace, its recovery state

#### Scenario: A namespace's recovery state is unknown

- **WHEN** a namespace row in `boot_status/1` carries the recovery state `:unknown`
- **THEN** that namespace is shown as unknown rather than as serving

#### Scenario: The coordinator cannot be reached

- **WHEN** the shutdown status call fails or is refused
- **THEN** the panel states that shutdown status is unavailable and the rest of the screen still renders

### Requirement: Authorization configuration is auditable from the UI

The controller screen SHALL state the authorization posture, and when the posture is `:open` SHALL state that authorization is disabled.

#### Scenario: Authorization is enforced

- **WHEN** the posture is `:enforced`
- **THEN** the screen states that authorization is enforced

#### Scenario: Authorization is switched off

- **WHEN** the posture is `:open`
- **THEN** the screen states that authorization is disabled on this controller

### Requirement: Memory hot spots are operator-triggered

The controller screen SHALL offer a memory snapshot — top processes, ETS tables, DETS files, and the allocator breakdown — read from `Flezha.Service.Controller.mem_top/1`, and SHALL take it only when an operator asks for it, never on the refresh tick. Each top process SHALL be shown by its registered name, falling back to its pid, with its memory, its message queue length and its initial call.

#### Scenario: An operator requests a snapshot

- **WHEN** an operator triggers the memory snapshot
- **THEN** the hot spots are rendered with the time the snapshot was taken

#### Scenario: A named process

- **WHEN** a top process carries a `registered_name`
- **THEN** its row shows that name rather than its pid
- **AND** shows its queue length and initial call

#### Scenario: The screen ticks without a request

- **WHEN** the refresh timer fires and no snapshot was requested
- **THEN** no `mem_top/1` call is made

#### Scenario: A stale snapshot is labelled

- **WHEN** a previously taken snapshot is still on screen after subsequent ticks
- **THEN** its capture time is shown so it is not mistaken for live data

#### Scenario: The snapshot is refused

- **WHEN** `mem_top/1` answers `{:error, %Flezha.Error{class: :denied}}`
- **THEN** the panel states the refusal and no snapshot is rendered

### Requirement: The controller can be drained and stopped from the console

The controller screen SHALL offer Stop controller when the operations whoami answers
for the operator include `Controller.stop`, which core grants to `admin` at `_system`. Stop SHALL open a dialog that names the controller node, offers a
drain timeout and a force option (finalise only, skipping the quiesce and the drain),
and is confirmed only after the operator types the node name and any timeout is a
whole number of seconds. On confirm the console SHALL call
`Flezha.Service.Controller.stop/2` on exactly the node named, with an emit pid, and
SHALL refuse rather than stop another node that has since become the connected one.
Stop SHALL NOT be offered while a shutdown is already in progress. It SHALL show each
progress event as it arrives, and SHALL follow `Flezha.Service.Controller.shutdown_status/1`
on the tick until the call answers or the node goes away. A stop that ends with the
controller node disconnecting SHALL be presented as a completed stop, not as an
error. The rest of the console SHALL then show its existing disconnected state.

#### Scenario: An admin stops the controller

- **WHEN** an operator granted `Controller.stop` types the node name and confirms
- **THEN** the console calls `stop/2`, lists the drain progress as it streams, and
  shows the shutdown phase advancing

#### Scenario: The controller goes away

- **WHEN** the controller node disconnects after a stop was requested and the call
  ends with a lost connection
- **THEN** the dialog states the controller stopped, with the last phase and the
  elapsed time
- **AND** the shell's liveness shows the controller as disconnected

#### Scenario: The confirmation is not typed

- **WHEN** the typed name does not match the node name
- **THEN** the confirm button stays disabled and nothing is called

#### Scenario: The connected node changed

- **WHEN** the node named in the dialog is no longer connected when the operator
  confirms
- **THEN** no node is stopped and the dialog states the controller is not connected

#### Scenario: A shutdown is already under way

- **WHEN** the controller reports a shutdown in progress
- **THEN** no Stop control is rendered

#### Scenario: A forced stop

- **WHEN** the operator ticks force and confirms
- **THEN** `stop/2` is called with `force: true`

#### Scenario: The role does not grant stop

- **WHEN** the operator's operations do not include `Controller.stop`
- **THEN** no Stop control is rendered

#### Scenario: The stop is refused

- **WHEN** `stop/2` answers an error
- **THEN** the dialog shows it with its code and hint and the controller keeps running

### Requirement: The durability shipper's health is visible

The controller screen's durability panel SHALL show the shipper's own status from
`Flezha.Service.Controller.durability_status/1`, alongside the posture and the
breaches it already shows. Every field the answer carries SHALL be presented with a
readable label. The panel SHALL show a pending retry as the time remaining, from the
`retry_in_ms` the controller computes, and SHALL NOT format a controller timer value
as a calendar date. A last error SHALL be shown as the text the controller answers,
without quoting it again. A missing or refused answer SHALL be stated without blanking
the panel.

#### Scenario: The remote tier is shipping

- **WHEN** the posture is `:remote_tier` and `durability_status/1` answers
- **THEN** the panel shows the shipper's status fields, such as its lag and its last
  shipment, beside the breach count

#### Scenario: A shipment is waiting to retry

- **WHEN** a shipper row carries `retry_in_ms: 12000`
- **THEN** its retry reads "in 12 s"

#### Scenario: A shipment failed

- **WHEN** a shipper row carries `last_error: "{:error, :econnrefused}"`
- **THEN** the panel shows `{:error, :econnrefused}` with no surrounding quotes

#### Scenario: The controller is local-only

- **WHEN** the posture is `:local_only`
- **THEN** the shipper status is shown as not applicable rather than as a failure

#### Scenario: The status read fails

- **WHEN** `durability_status/1` answers an error
- **THEN** the panel states that shipper status is unavailable, with the error's code,
  and still shows posture and breaches

