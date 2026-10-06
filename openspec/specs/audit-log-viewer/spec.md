# audit-log-viewer Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Audit calls carry a UI caller context

Every call into `Flezha.Service.AuditLog` SHALL supply the caller context built by `NodeManager.caller_context/1` — `source: :ui` plus the principal, namespace, and role resolved from a verified token. A single shared helper SHALL build it. When no principal is bound, the audit screen SHALL state that its reads are refused for want of a bound principal rather than rendering as an empty log.

#### Scenario: Reading the audit log

- **WHEN** any audit function is called
- **THEN** the caller context carries `source: :ui` and the bound principal, namespace, and role

#### Scenario: The caller context is built in one place

- **WHEN** the codebase is searched for audit caller-context construction
- **THEN** exactly one helper constructs it

#### Scenario: No principal is bound

- **WHEN** an audit read answers `{:error, %Flezha.Error{code: "authz.principal_not_bound"}}`
- **THEN** the screen states that a flezha token is required and links to settings
- **AND** the log is not rendered as empty

#### Scenario: The bound role may not read the audit log

- **WHEN** an audit read answers `{:error, %Flezha.Error{class: :denied}}` with any other `authz.*` code
- **THEN** the screen states the refusal with its code and message
- **AND** the log is not rendered as empty

### Requirement: Audit file catalog

The UI SHALL list the controller's audit log files with the metadata the controller reports for each.

#### Scenario: Audit files exist

- **WHEN** an operator opens the audit log screen
- **THEN** the audit files are listed with their reported metadata

#### Scenario: Audit logging is disabled

- **WHEN** the controller returns `{:error, %Flezha.Error{code: "audit.disabled"}}` or `{:error, %Flezha.Error{code: "observability.disabled"}}`
- **THEN** the screen explains which flag is off and how to enable it
- **AND** presents this as a configuration state, not a failure

### Requirement: Filtered record reads

An operator SHALL be able to read audit records filtered by file, source, name, time range, and limit.

#### Scenario: Reading with a filter

- **WHEN** an operator applies a source and time-range filter
- **THEN** only matching records are displayed

#### Scenario: No records match

- **WHEN** a filter matches nothing
- **THEN** an empty state states that no record matches the filter

#### Scenario: A limit is applied

- **WHEN** more records match than the requested limit
- **THEN** at most the limit is displayed
- **AND** the operator is told the result was truncated

### Requirement: Live tail

An operator SHALL be able to tail the audit log live. The tail SHALL start paused, SHALL be established through `FlezhaUi.Service.EventFeed` by `Flezha.Service.AuditLog.tail/2`, and SHALL be released by stopping the `EventFeed` process holding it when the tail is stopped or the screen closes; the controller removes the subscription when that process exits.

#### Scenario: Starting a tail

- **WHEN** an operator starts the tail
- **THEN** the event feed takes the subscription and new records appear as they are written

#### Scenario: The screen opens

- **WHEN** an operator opens the audit log screen
- **THEN** the tail is not running until it is explicitly started

#### Scenario: Leaving the screen

- **WHEN** an operator navigates away while tailing
- **THEN** the tail subscription is removed on the controller

#### Scenario: The tail is refused

- **WHEN** `AuditLog.tail/2` answers `{:error, %Flezha.Error{}}`
- **THEN** the screen states that the tail could not be started, with the error's code and message, and the filtered reads still work

### Requirement: Audit statistics

The UI SHALL display the controller's reported audit statistics.

#### Scenario: Viewing statistics

- **WHEN** an operator opens the audit log screen
- **THEN** the controller's reported statistics are displayed

### Requirement: The audit log is rotated on request

The audit screen SHALL offer a control that closes the current audit file and starts a new one through `Flezha.Service.AuditLog.rotate/1`, and SHALL reload the file catalog afterwards so the closed file is listed.

#### Scenario: Rotating the audit log

- **WHEN** an operator rotates the audit log
- **THEN** `rotate/1` is called
- **AND** the file catalog is reloaded and lists the file that was closed

#### Scenario: Rotation is refused

- **WHEN** the controller refuses the rotation, for example because the role lacks `audit.rotate`
- **THEN** the error is shown with its code and hint
- **AND** the file catalog is left as it was

