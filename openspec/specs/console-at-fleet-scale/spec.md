# console-at-fleet-scale Specification

## Purpose
The console stays fast at thousands of relays per namespace: every screen reads only what it shows, as pages, single relays, summaries and totals, so what one open screen costs the console and the controller does not grow with the fleet.
## Requirements
### Requirement: A screen SHALL read what it shows, not the whole namespace

A screen SHALL ask the controller only for what it shows. A page of rows SHALL be read as a page. One relay SHALL be read by its id. Counts SHALL be read from the controller's summary or totals. Rates SHALL be read for the relays on screen and, for a namespace's flow, as the namespace's totals. No screen's periodic read SHALL answer every relay of a namespace.

#### Scenario: One relay among thousands

- **GIVEN** a namespace running 5,000 relays
- **WHEN** an operator keeps a relay's screen open
- **THEN** each tick reads that relay's row with the `ids` filter, and the liveness counters of that relay only

#### Scenario: Dashboard in a large namespace

- **GIVEN** a namespace running 5,000 relays, 12 of them failed
- **WHEN** an operator keeps its Dashboard open
- **THEN** each tick reads the namespace summary with at most 50 unhealthy rows, and the namespace's liveness totals
- **AND** the Relays tile reads 5,000 relays, 12 failed

#### Scenario: Rates for the shown rows

- **WHEN** the relays index shows 20 rows
- **THEN** its rate read names those 20 relays and no other

### Requirement: A fleet-sized listing SHALL be searchable and sortable on the controller

A listing of relays, plugins, dead letters, Cells, journal entries or committed iterations SHALL offer a search box and the sorts and filters the controller declares for it. These SHALL be applied by the controller, written to the query string, and restored from it. Searching SHALL reach any row of the collection, whatever its position.

#### Scenario: Finding a relay by part of its id

- **GIVEN** a namespace running 5,000 relays
- **WHEN** an operator types `00500` into the relays index search
- **THEN** the listing shows the relays whose id or factory contains `00500`, and states how many match

#### Scenario: A search is shareable

- **WHEN** an operator searches the plugins screen and copies the address
- **THEN** opening that address shows the same search and its results

#### Scenario: The runner table keeps its view

- **WHEN** an operator searches, filters and sorts the runner table
- **THEN** it behaves as before, through the same shared listing view the relays index uses

### Requirement: A picker of a fleet-sized collection SHALL search the controller

A picker offering relays or committed iterations SHALL show the first matches and ask the controller for more as the operator types, saying how many more match. It SHALL NOT render the whole collection as options. Pickers of bounded sets, namespaces among them, SHALL be searchable in the browser. No form SHALL render a native `<select>` of a controller collection.

#### Scenario: Binding a plugin in a namespace of 5,000 relays

- **GIVEN** a namespace running 5,000 relays
- **WHEN** an operator opens Bind relay on a plugin and types `orders_17`
- **THEN** the picker shows at most 20 matching relays and how many more match, and opens in under 2 s

#### Scenario: Rewinding a long-lived relay

- **GIVEN** an instance with 20,000 committed iterations
- **WHEN** an operator opens Rewind
- **THEN** the picker shows the 20 newest iterations and an Older control that reads the next 20

### Requirement: No screen SHALL render an unbounded list

Every list a screen renders SHALL be paged or SHALL show a sample with a count. This covers grids, partition members, menus, charts, a plugin's bound relays, problem lists and namespace sections. No render SHALL draw one element per relay, Cell, partition or bound relay beyond the shown page.

#### Scenario: Opening a large partition group

- **WHEN** an operator opens a partition group of 1,000 members
- **THEN** its first page of members is shown with a control to show more

#### Scenario: The lag chart in a class with many Cells

- **GIVEN** a relay class with 5,000 Cells
- **WHEN** an operator opens its state screen
- **THEN** the lag chart draws only the Cells on the shown page of the Cells grid

#### Scenario: A plugin bound to a thousand relays

- **WHEN** the plugins screen shows a plugin bound to 1,000 relays
- **THEN** its row shows 10 relay ids and "+ 990 more", and its menu offers Unbind for those 10 and "Unbind another relay…"

### Requirement: A screen's work per tick SHALL NOT grow with the namespace

Rendering a screen on a tick SHALL take time that does not grow with the number of relays in the namespace. Dashboard's flow history SHALL be one series of namespace totals. The namespace switcher SHALL be re-sent only when the namespaces change.

#### Scenario: Dashboard at 10,000 relays

- **GIVEN** a namespace running 10,000 relays
- **WHEN** Dashboard renders on a tick
- **THEN** the render takes no longer than with 100 relays, within a factor of 2

#### Scenario: The switcher is not re-sent

- **WHEN** a screen updates on a tick and the reachable namespaces did not change
- **THEN** the diff sent to the browser carries none of the namespace switcher's entries

### Requirement: Screens SHALL read off their own process and share reads between tabs

Every refreshing screen that reads the controller SHALL do so in the background, so a slow read never delays a click. A hidden tab SHALL make no periodic read, the shell's pulse included. Within one tick, reads with the same token and the same arguments for liveness counters, and for dead-letter seen counts, SHALL be answered once and shared.

#### Scenario: A click during a slow read

- **GIVEN** a controller that takes 5 s to answer a listing
- **WHEN** an operator activates "Show 20 more" on the relays index during that read
- **THEN** the screen answers the click without waiting for the read

#### Scenario: A hidden tab

- **WHEN** the operator switches to another browser tab
- **THEN** that tab's screen and its pulse make no controller call until it is visible again

#### Scenario: Two tabs, one read

- **WHEN** one operator has the same relay open in two tabs
- **THEN** within one tick the controller answers that relay's liveness counters once

### Requirement: The console SHALL stay usable at 5,000 relays and 1,000 plugins

On the dev stack, with 5,000 relays and 1,000 bound plugins in one namespace, every screen SHALL show its figures within 2 s of opening and SHALL answer a click within 300 ms. One open screen SHALL keep the controller's added CPU below one core.

#### Scenario: The scale run

- **GIVEN** the dev stack with 5,000 relays and 1,000 bound plugins in one namespace
- **WHEN** Dashboard, the relays index, a relay, its state screen, the plugins screen with Bind relay, Problems and Cluster are each opened
- **THEN** each shows its figures within 2 s, and "Show 20 more" answers within 300 ms

