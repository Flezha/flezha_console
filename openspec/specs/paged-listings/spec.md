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

#### Scenario: A long token list

- **WHEN** a namespace holds 43 tokens and the operator opens Access
- **THEN** the tokens grid shows 20 rows and a control reading "Show 20 more · 20 of 43"

#### Scenario: Growing the list

- **WHEN** the operator activates that control twice
- **THEN** all 43 tokens are shown and the control is gone

#### Scenario: An open group stays whole

- **WHEN** a relay partition group is the last row of a page and the operator opens it
- **THEN** its partitions are shown under it, and the page still counts it as one row

#### Scenario: A short list

- **WHEN** a listing holds 7 rows
- **THEN** all 7 are shown and no control renders

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

