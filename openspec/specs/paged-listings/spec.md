# paged-listings Specification

## Purpose
Every listing in the console shows a first page and grows by a page on request, with one shared mechanism whose shown count is held on the server so a refresh tick never shrinks it.
## Requirements
### Requirement: A listing shows a first page and grows on request

Every list-style listing in the console SHALL render at most its page size of rows,
20 unless the listing declares another, and SHALL render a foot control stating how
many rows are shown out of how many, which adds one more page when activated. The
control SHALL NOT render when every row is shown. Listings already
bounded by design — the live tail, the river, the command palette and an audit
read, which its limit bounds — SHALL keep their own bound and render no control.

A listing of a controller collection that can grow with the fleet SHALL read only
the rows it shows: its shown count is the limit it asks the controller for, and the
"out of how many" is the total the controller answers. Such a listing SHALL grow to
at most 500 rows, the controller's page limit. Past that its foot SHALL state the
total and ask the operator to search or filter to narrow it, instead of offering
another page. These collections are relays, plugins, dead letters, Cells, journal
entries and committed iterations.

#### Scenario: A long token list

- **WHEN** a namespace holds 43 tokens and the operator opens Access
- **THEN** the tokens grid shows 20 rows and a control reading "Show 20 more · 20 of 43"

#### Scenario: Growing the list

- **WHEN** the operator activates that control twice
- **THEN** all 43 tokens are shown and the control is gone

#### Scenario: An open group stays whole

- **WHEN** a relay partition group is the last row of a page and the operator opens it
- **THEN** its partitions are shown under it as their own paged listing, and the page still counts the group as one row

#### Scenario: A short list

- **WHEN** a listing holds 7 rows
- **THEN** all 7 are shown and no control renders

#### Scenario: A controller listing reads only its page

- **GIVEN** a namespace running 5,000 relays
- **WHEN** the operator opens its relays and grows the listing once
- **THEN** the controller is asked for 20 rows, then for 40, and the foot reads "Show 20 more · 40 of 5,000"

#### Scenario: The reach of a controller listing

- **GIVEN** a relays listing grown to 500 rows of 5,000
- **WHEN** the operator looks at its foot
- **THEN** it states 500 of 5,000 and asks them to search or filter, and offers no further page

### Requirement: The shown count survives the refresh tick

The number of rows a listing shows SHALL be held on the server, per listing, by the
same mechanism that holds a screen's folded sections, so a refresh tick that re-reads
the rows SHALL NOT shrink a listing the operator has grown. A listing whose rows
shrink below its shown count SHALL show every row it still has.

#### Scenario: A tick after growing

- **WHEN** the operator has grown the role-bindings grid to 40 rows and the screen ticks
- **THEN** the grid still shows 40 rows

### Requirement: One paging mechanism serves every listing

Paging SHALL be implemented once: the kit grid slices its rows and renders the foot
control, and any listing that is not a grid renders the same control from the same
state. No screen SHALL keep its own paging state or its own "show more" control.

#### Scenario: Paging is shared

- **WHEN** the web layer is searched for a listing's paging
- **THEN** every paged listing reads its shown count from the shared mechanism and
  renders the kit's control

### Requirement: An open row menu survives changes to other rows

A row's action menu that an operator has opened SHALL stay open, on the same row, when the listing's refresh adds, removes or reorders other rows. The action the operator then chooses SHALL act on the row whose menu they opened.

#### Scenario: Another operator adds a row while a menu is open

- **WHEN** an operator has a row's menu open and another session adds a row to the same listing
- **THEN** the menu stays open on the operator's row
- **AND** it stays placed against that row's menu control
- **AND** choosing an item acts on that row

#### Scenario: The refresh ticks while a menu is open

- **WHEN** the screen refreshes while a row's menu is open and no row changed
- **THEN** the menu stays open

