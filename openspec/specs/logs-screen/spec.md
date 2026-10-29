# logs-screen Specification

## Purpose
One Logs screen serves every durable log the controller declares: a tab per kind, filters and columns from each kind's declaration, newest-first reads across the cluster continued by cursor, a live tail that starts paused, and files, statistics and rotation per controller.
## Requirements
### Requirement: One screen serves every log kind the controller declares

The console SHALL serve one Logs screen at `/logs/:kind`. It SHALL read the kinds of log the controller keeps from the logs service's kinds call, each with its id, title and description. It SHALL show them as tabs on the screen, ordered as the controller answers them. The tab of the kind on display SHALL be marked current. `/logs` SHALL redirect to the first kind the controller declares. `/audit` SHALL redirect to `/logs/audit`, keeping its query. A kind the controller does not declare SHALL be answered with the screen and its tabs, and with a sentence saying the controller keeps no log of that name, not with an error page. A kind the controller adds later SHALL appear as a tab with no console change.

#### Scenario: Two kinds are declared

- **WHEN** the controller declares the kinds `audit` and `relay_history`
- **THEN** the Logs screen shows a tab for each, titled as declared, and the tab of the kind on display is marked current

#### Scenario: A new kind

- **WHEN** the controller declares a third kind, `deploys`, with its own filters and columns
- **THEN** a Deploys tab appears and its records are read and listed with the filters and columns it declares

#### Scenario: The old audit address

- **WHEN** an operator requests `/audit`
- **THEN** the console redirects to `/logs/audit`

#### Scenario: An unknown kind

- **WHEN** an operator requests `/logs/nope`
- **THEN** the screen shows its tabs and says the controller keeps no log named `nope`

### Requirement: A kind's filters and columns come from its declaration

The screen SHALL offer the filters the kind declares, each labelled as declared, together with a time range and a limit. A declared filter with a fixed set of values SHALL be offered as a choice of those values, and any other as text. The applied filters SHALL be carried in the URL query, so a filtered view can be linked to and survives a reload. Records SHALL be listed with the columns the kind declares, each headed by its declared label. A kind the console knows how to say in a sentence SHALL also be read as that sentence (see `relay-history`). A kind the console has no sentence for SHALL still be listed by its declared columns.

#### Scenario: Filtering the audit log by name

- **WHEN** an operator filters the audit kind by a declared `name` filter
- **THEN** only matching records are listed and the URL query carries the filter

#### Scenario: A link opens a filtered view

- **WHEN** an operator follows a link to `/logs/relay_history?relay=fan_trade-7f3a`
- **THEN** the screen opens with that relay filter applied and lists that relay's records

### Requirement: Reads are newest first and continue on request

A read SHALL list the newest matching records first, up to its limit, from every controller. When more records match, the screen SHALL say so and offer Read more. Read more SHALL read the next older records with the same filters, through the cursor the previous answer carried, and append them. No record SHALL be shown twice and none skipped. Read more SHALL stop once 5000 records are shown and say to narrow the filter instead. A read with no match SHALL state that no record matches the filter. A refused read SHALL show the refusal and SHALL NOT also state that nothing matches.

#### Scenario: Reading on

- **WHEN** a read of 100 records answers a next cursor and the operator activates Read more
- **THEN** the next older records are appended, none repeated

#### Scenario: Reading on stops at the cap

- **WHEN** 5000 records are shown and more match
- **THEN** Read more is gone and the screen says to narrow the filter

#### Scenario: A refused read

- **WHEN** the read answers `{:error, %Flezha.Error{class: :denied}}`
- **THEN** the refusal is shown with its code and message and no "no record matches" statement is shown

#### Scenario: A controller does not answer

- **WHEN** a read answers records and `unreachable: ["flezha@c2"]`
- **THEN** the records are listed and the shared partial-answer notice names `flezha@c2`

### Requirement: The tail is live across the cluster and starts paused

The screen SHALL offer a live tail of the kind on display, opened through `FlezhaConsole.Service.EventFeed` by the logs service's tail call, carrying records from every controller. The tail SHALL NOT run until the operator starts it. New records SHALL appear at the top as they are written, bounded to the latest 200, and SHALL be narrowed by the filters applied. Stopping the tail, switching kind or leaving the screen SHALL stop the feed, releasing the controller's subscription. A refused tail SHALL be stated with its code and message while reads keep working.

#### Scenario: Starting the tail

- **WHEN** an operator starts the tail on the relay history and a relay starts
- **THEN** the relay's `started` record appears at the top of the list

#### Scenario: The screen opens

- **WHEN** an operator opens the Logs screen
- **THEN** no tail runs until it is started

#### Scenario: Switching kind

- **WHEN** an operator switches from a tailing audit tab to the relay history tab
- **THEN** the audit tail's feed is stopped

### Requirement: Files, statistics and rotation are shown per controller

For a kind that keeps files, the screen SHALL list each controller's files: the file being written first, marked current, then the rotated ones. Each file SHALL be listed with its controller, name, record count and size. The screen SHALL also show each controller's statistics. The listing SHALL page like every listing. An operator whose operations include the rotate call SHALL be offered Rotate on each controller's current file. Rotate SHALL close that controller's current file and start a new one, and the listing SHALL be reloaded so the closed file is listed. A refused rotation SHALL be shown with its code and hint, leaving the listing as it was. Opening a listed file SHALL read that file's records with the other filters kept, and SHALL bring the records into view.

#### Scenario: Two controllers keep files

- **WHEN** the audit kind's files answer files from `flezha@c1` and `flezha@c2`
- **THEN** each controller's current file is listed first among its files, and every file names its controller

#### Scenario: Rotating one controller's file

- **WHEN** an operator activates Rotate on `flezha@c2`'s current file
- **THEN** that controller's rotate call is made and its closed file is listed after the reload

#### Scenario: A viewer without the rotate call

- **WHEN** the operator's operations do not include rotation
- **THEN** no file row offers Rotate

### Requirement: Records are readable rows

Each record SHALL be shown as one row, as its kind's sentence or by its declared columns. A field a record does not carry SHALL be shown as a dash. Activating a row SHALL expand it in place to the whole record, pretty-printed, and activating it again SHALL fold it. A record's time SHALL be shown relative to now, with the absolute time beside it, from the wall-clock time its controller stamped.

#### Scenario: Expanding a record

- **WHEN** an operator activates a record row
- **THEN** it expands to the whole record as indented JSON
- **AND** activating it again folds it

### Requirement: A disabled log is a configuration state

When the controller answers that a kind's log is switched off, or that observability is switched off, the screen SHALL say which setting is off and how to switch it on, as a configuration state and not as a failure. The other kinds' tabs SHALL still work.

#### Scenario: The audit log is switched off

- **WHEN** the audit kind's read answers `audit.disabled`
- **THEN** the audit tab states that the audit log is switched off and how to switch it on
- **AND** the relay history tab still reads its records

