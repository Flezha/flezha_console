# audit-log-viewer Specification

## Purpose
Every call the console makes into the controller's logs service carries the UI caller context built in one place, and a refusal for want of a bound principal is stated rather than shown as an empty log.
## Requirements
### Requirement: Audit calls carry a UI caller context

Every call into the logs service, for every log kind, SHALL supply the caller context built by `NodeManager.caller_context/1` — `source: :ui` plus the principal, namespace, and role resolved from a verified token. A single shared helper SHALL build it. When no principal is bound, the Logs screen SHALL state that its reads are refused for want of a bound principal rather than rendering as an empty log.

#### Scenario: Reading the audit log

- **WHEN** any logs call is made, for any kind
- **THEN** the caller context carries `source: :ui` and the bound principal, namespace, and role

#### Scenario: The caller context is built in one place

- **WHEN** the codebase is searched for logs caller-context construction
- **THEN** exactly one helper constructs it

#### Scenario: No principal is bound

- **WHEN** a logs read answers `{:error, %Flezha.Error{code: "authz.principal_not_bound"}}`
- **THEN** the screen states that a flezha token is required and links to settings
- **AND** the log is not rendered as empty

#### Scenario: The bound role may not read a log

- **WHEN** a logs read answers `{:error, %Flezha.Error{class: :denied}}` with any other `authz.*` code
- **THEN** the screen states the refusal with its code and message
- **AND** the log is not rendered as empty

