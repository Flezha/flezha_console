# runner-drop Specification

## Purpose
How an operator takes a misbehaving runner process out of service: core drops it
and refuses that same process on every controller until a different process of the
runner connects, lists and lifts the marks, and the console offers the drop, shows
the marks and readmits a process.
## Requirements
### Requirement: Core drops a runner and refuses that process until a different one connects

Core SHALL publish `Flezha.Service.Fleet.drop_runner(namespace, runner_id, caller_context)`.
It resolves the runner session anywhere in the controller cluster and records a drop
mark for that runner's process. The mark holds the namespace, the runner's stable
identity, its SDK incarnation, its OS pid when known, the node it was on, when it was
dropped and the principal who dropped it. Core then closes the runner's session
without telling the runner to stop. The runner's relays are re-placed the way they are
when a retiring runner leaves, without waiting for the reconnect grace.

While the mark stands, any connection from the same stable identity and incarnation
SHALL be refused on every controller node with the coded error `runner.dropped`,
whose hint says how to readmit it. A connection from the same stable identity with a
different incarnation — a different process — SHALL be admitted, and admitting it
SHALL clear the mark. Marks SHALL be replicated across the controller cluster and
survive a controller restart, the same way revoked tokens are.

The operation SHALL be authorized as the action `runner.drop`, granted to the `ops`
and `admin` roles, scoped to the namespace argument, and audited with its outcome.

#### Scenario: An operator drops a connected runner

- **WHEN** `drop_runner/3` is called for a runner connected to any controller node
- **THEN** it answers `{:ok, mark}` with the stable id, incarnation, pid and node
- **AND** the runner's session is closed and its relays are re-placed onto the
  namespace's other runners

#### Scenario: The same process reconnects

- **WHEN** the dropped runner process retries its connection, on the same or on
  another controller node
- **THEN** the connection is refused with `runner.dropped` and no session is created

#### Scenario: A new process of the same runner connects

- **WHEN** a runner with the dropped stable identity connects with a different
  incarnation
- **THEN** it is admitted as normal and the drop mark is removed on every node

#### Scenario: The mark survives a restart

- **WHEN** a controller restarts while a mark stands
- **THEN** the same process is still refused after the restart

#### Scenario: The runner cannot be tracked

- **WHEN** the runner has no stable identity
- **THEN** `drop_runner/3` answers `{:error, %Flezha.Error{code: "runner.untrackable"}}`
  and leaves the runner connected

#### Scenario: The runner does not exist

- **WHEN** no session in the cluster has the given runner id
- **THEN** `drop_runner/3` answers `{:error, %Flezha.Error{code: "runner.not_found"}}`

#### Scenario: A viewer tries to drop

- **WHEN** a caller whose role does not grant `runner.drop` calls `drop_runner/3`
- **THEN** it answers a `:denied` error and an audit signal records the refusal

### Requirement: Core lists and lifts drop marks

Core SHALL publish `Flezha.Service.Fleet.dropped_runners(namespace, caller_context)`.
It answers the namespace's standing marks, authorized like the other fleet reads. Core
SHALL publish `Flezha.Service.Fleet.readmit_runner(namespace, stable_id, caller_context)`,
which removes a mark on every node, is authorized as `runner.drop`, and is audited.
The `flz` CLI SHALL offer `flz runner drop`, `flz runner dropped` and
`flz runner readmit` over the same operations.

#### Scenario: Marks are listed

- **WHEN** `dropped_runners/2` is called for a namespace with one standing mark
- **THEN** it answers that mark with its stable id, incarnation, pid, node, time and
  principal

#### Scenario: An operator readmits a process

- **WHEN** `readmit_runner/3` is called for a marked stable id
- **THEN** the mark is removed everywhere, and the same process is admitted on its
  next retry

#### Scenario: The CLI drops a runner

- **WHEN** `flz runner drop <id> -n <namespace>` is run with an ops token
- **THEN** the runner is dropped and the CLI prints the mark

### Requirement: Drop activity is observable

Core SHALL emit `runner_dropped`, `runner_readmitted` and `runner_drop_refused` signals
on the `:flezha_runner` observability source, beside `runner_connected` and
`runner_disconnected`. Each signal carries the namespace and stable id, and the
refusal signal also carries the pid and the node that refused it.

#### Scenario: A drop is announced

- **WHEN** a runner is dropped
- **THEN** a `runner_dropped` signal is emitted on `:flezha_runner`

#### Scenario: A refusal is announced

- **WHEN** a dropped process is refused
- **THEN** a `runner_drop_refused` signal is emitted, at the rate the runner's own
  reconnect backoff sets

### Requirement: The console drops and readmits runners

The console SHALL render the runner listings that act on runners — the cluster
screen's per-namespace runners and the namespace detail's runners panel — through
one shared runner-table component. The dashboard's cross-namespace runner summary
stays a read-only table. Each row SHALL offer a Drop action when the operations whoami answers for the
operator include `Fleet.drop_runner`. Drop SHALL open a confirmation naming the runner id and OS pid, saying
that the same process will be refused until a different one connects, with the solid
danger fill on its confirm button. Below the runners, the listing SHALL show the
namespace's standing marks from `dropped_runners/2`, each with a Readmit action when the
operations include `Fleet.readmit_runner`. Errors SHALL be shown through the console's coded-error display.

#### Scenario: Dropping from the namespace screen

- **WHEN** an ops operator confirms Drop on a runner row
- **THEN** the console calls `drop_runner/3` and the runner leaves the list
- **AND** a dropped mark with the runner's stable id, pid and time appears under the
  list with a negative badge

#### Scenario: Cancelling a drop

- **WHEN** the operator cancels the confirmation
- **THEN** nothing is called and the runner stays listed

#### Scenario: A viewer sees no drop control

- **WHEN** the operator's operations include neither `Fleet.drop_runner` nor
  `Fleet.readmit_runner`
- **THEN** neither Drop nor Readmit is rendered, while the marks are still listed

#### Scenario: Readmitting a process

- **WHEN** the operator confirms Readmit on a mark
- **THEN** the console calls `readmit_runner/3` and the mark disappears

#### Scenario: A drop is refused

- **WHEN** `drop_runner/3` answers `runner.untrackable`
- **THEN** the confirmation closes and the error is shown with its code and hint

#### Scenario: The fleet follows drop activity

- **WHEN** a runner is dropped or readmitted from another console or from `flz`
- **THEN** the open runner listings update without a page reload

