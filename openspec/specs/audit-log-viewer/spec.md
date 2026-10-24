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

An operator SHALL be able to tail the audit log live. The tail SHALL start paused, SHALL be established through `FlezhaConsole.Service.EventFeed` by `Flezha.Service.AuditLog.tail/2`, and SHALL be released by stopping the `EventFeed` process holding it when the tail is stopped or the screen closes; the controller removes the subscription when that process exits.

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

### Requirement: Catalog files are listed by name, record count and size

The audit file catalog SHALL list each rotated file by its file name, its record count and its size, and SHALL NOT render the controller's raw file record. The file being written now SHALL be listed first, named as the current file, with the record count the statistics report. The catalog SHALL page like every listing (see `paged-listings`).

#### Scenario: Rotated files are listed

- **WHEN** the catalog holds rotated files
- **THEN** each is listed by name, record count and size

#### Scenario: The current file is listed

- **WHEN** the statistics name `audit-current.jsonl` as the current file
- **THEN** the catalog's first row is that file, marked as current

### Requirement: A refused read is not shown as an empty result

When the controller refuses an audit read, the screen SHALL show the refusal and SHALL NOT also state that no record matches the filter.

#### Scenario: An unknown file is read

- **WHEN** an operator reads a file the audit log does not have
- **THEN** the controller's `audit.file_not_found` refusal is shown
- **AND** no "no record matches" statement is shown with it

### Requirement: An audit file opens into its records

An operator whose operations include `AuditLog.read` SHALL be able to open any listed
audit file with an Open control on its row, by pointer or keyboard, which SHALL read that file through the same
filtered read the Records section uses, with the file set in the filter and the other
filter fields kept, and SHALL bring the Records section into view. Without
`AuditLog.read`, no catalog row SHALL offer Open.

#### Scenario: Opening a rotated file

- **WHEN** an operator activates Open on the row of a rotated file
- **THEN** `AuditLog.read` is called with that file
- **AND** its records are shown under Records, with the File filter reading that name

#### Scenario: A viewer without the read

- **WHEN** the operator's operations do not include `AuditLog.read`
- **THEN** no catalog row offers Open

### Requirement: Audit records are readable rows

Read records SHALL be shown as rows with their time, source, name, actor and outcome
in words, each of which SHALL expand in place to the whole record, pretty-printed.
A field a record does not carry SHALL be shown as a dash.

#### Scenario: Expanding a record

- **WHEN** an operator activates a record row
- **THEN** the row expands to show the whole record as indented JSON
- **AND** activating it again folds it

### Requirement: A truncated read continues

When a read was truncated by its limit, the Records section SHALL offer Read more,
which SHALL read the next records of the same file with the filter that read used,
by their position in the file, and append them, showing no record twice and skipping
none. Position, not time, orders them: a record's timestamp is its controller's
monotonic clock, which does not carry on across a restart. The records of a read are
not paged; Read more SHALL stop once 5000 records are shown and say to narrow the
filter instead. A rotation through this screen SHALL end a read of the file being
written, since that file is replaced.

#### Scenario: Reading on

- **WHEN** a read of 100 was truncated and the operator activates Read more
- **THEN** the next records are appended after the first 100, none repeated

#### Scenario: Reading on stops at the cap

- **WHEN** 5000 records are shown and more match
- **THEN** Read more is gone and the screen says to narrow the filter

