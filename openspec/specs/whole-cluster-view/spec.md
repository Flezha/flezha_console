# whole-cluster-view Specification

## Purpose
How the console reads and presents a cluster of controllers through the one it is connected to: answers that a controller did not fully give, the controller each row lives on, relay health wherever a relay runs, dead letters, schedules, observability, quotas and namespaces across the cluster, and each controller's own facts.

## Requirements
### Requirement: A partial cluster answer says which controllers did not answer

Every cluster-wide read that answers the controllers that did not answer in its `unreachable` field SHALL be shown with one notice, built on the console kit's `notice` component and rendered by one shared helper. The notice SHALL read how many of the cluster's controllers answered and name each one that did not, as "2 of 3 controllers answered; flezha@c3 did not, so what it holds is missing here." The cluster's controller count SHALL come from the controllers read the shell already makes. A screen SHALL show the notice once, above the region the partial read fills, however many of its reads were partial. A partial answer that holds no rows SHALL NOT be shown with the screen's "nothing here" empty state. It SHALL say that nothing was found on the controllers that answered. When every controller answered, no notice SHALL be shown.

#### Scenario: One controller does not answer

- **WHEN** the dead-letter listing answers two entries and `unreachable: ["flezha@c3"]` in a cluster of three controllers
- **THEN** the two entries are listed
- **AND** one notice reads that 2 of 3 controllers answered and names `flezha@c3`

#### Scenario: A partial answer with no rows

- **WHEN** the schedule listing answers no entries and `unreachable: ["flezha@c2"]`
- **THEN** the screen says no schedule was found on the controllers that answered, with the notice
- **AND** the empty state that teaches how to create a schedule is not shown

#### Scenario: Every controller answered

- **WHEN** a cluster-wide read answers `unreachable: []`
- **THEN** no partial-answer notice is shown

#### Scenario: Two partial reads on one screen

- **WHEN** both the relay rows and the factory catalog on Dashboard answer `unreachable: ["flezha@c2"]`
- **THEN** Dashboard shows the notice once

### Requirement: Relay health is known wherever a relay runs

Relay health SHALL be read from the cluster-wide relay rows, whose health each hosting controller decides for its own relays. Every screen that shows or counts health SHALL use those rows. That includes Dashboard's tiles and headline, the Cluster tiles and per-node rollup, the scoped and Fleet relay listings, the relay screen, the Problems screen and the shell's pulse. A relay hosted by a controller the console is not connected to SHALL show the health that controller decided. A relay SHALL read unknown only when its hosting controller did not answer, and that relay's row SHALL then say its controller did not answer.

#### Scenario: A healthy relay on another controller

- **WHEN** a relay hosted on `flezha@c2` is healthy and the console is connected to `flezha@c1`
- **THEN** the relays listing and the relay screen show it as healthy
- **AND** Dashboard's health tile counts it as healthy

#### Scenario: The hosting controller does not answer

- **WHEN** a relay's hosting controller is listed in the read's `unreachable` field
- **THEN** that relay's health reads unknown with a note that its controller did not answer
- **AND** the partial-answer notice is shown

### Requirement: A row says which controller holds it

Where a cluster-wide answer's rows each carry the `node` that holds them, the console SHALL show that controller on the row by its machine name, as the Controller screen names controllers, with the full node name on hover. This applies to dead letters, schedules, observability signals in a query or a tail, installed plugins and providers. A listing whose rows come from more than one controller SHALL offer a filter by controller. When every row comes from one controller, the controller SHALL still be named and no filter SHALL be offered.

#### Scenario: Dead letters on two controllers

- **WHEN** the dead-letter listing answers entries held by `flezha@c1` and by `flezha@c2`
- **THEN** each entry names its controller
- **AND** a controller filter narrows the listing to one controller's entries

#### Scenario: One controller holds everything

- **WHEN** every row of a listing carries the same `node`
- **THEN** each row names that controller and no controller filter is offered

### Requirement: Actions reach the controller that holds their target

Dropping, replaying and marking a dead letter seen, and running or removing a schedule, SHALL act on the entry whichever controller holds it, through the published call the core contract routes to that controller. The console SHALL NOT refuse or hide an action because the entry lives on another controller. A refusal SHALL be shown as the controller answers it.

#### Scenario: Replaying a dead letter held elsewhere

- **WHEN** an operator replays a dead letter whose row names `flezha@c2` while connected to `flezha@c1`
- **THEN** the replay is sent and its outcome is reported as for any other entry

#### Scenario: Removing a schedule created elsewhere

- **WHEN** an operator removes a schedule held by another controller
- **THEN** the schedule is removed and the listing no longer shows it

### Requirement: The Controller screen shows each controller's own facts

The Controller screen SHALL show the durability posture, breaches, shipper status, shutdown state, boot status and memory snapshot of each controller in the cluster, not only of the connected one. The screen SHALL keep its existing listing of the connected controllers. The screen SHALL show one controller's facts at a time, chosen from that listing, with the connected controller chosen on open. The chosen controller SHALL be carried in the URL query so it survives a reload. A controller that does not answer SHALL be selectable and SHALL show that its facts could not be read, while the listing still renders. The memory snapshot SHALL still be taken only when an operator asks, and only of the chosen controller.

#### Scenario: Choosing another controller

- **WHEN** an operator chooses `flezha@c2` in the controller listing
- **THEN** the durability, shutdown, boot and shipper panels show `flezha@c2`'s answers
- **AND** the URL names `flezha@c2`

#### Scenario: A chosen controller does not answer

- **WHEN** the chosen controller is unreachable
- **THEN** its panels state that its facts could not be read and the listing still renders

#### Scenario: A memory snapshot of another controller

- **WHEN** an operator chooses `flezha@c2` and asks for a memory snapshot
- **THEN** the snapshot is taken of `flezha@c2` and labelled with its machine and capture time

### Requirement: Observability spans every controller

The Observability screen SHALL list each source once, with its enabled state on every controller. A source enabled on some controllers and not others SHALL say on how many it is enabled ("on 2 of 3 controllers") and SHALL show its switch in the mixed state. Switching a source on or off SHALL apply to every controller through the published call. When some controllers did not apply it, the screen SHALL name them. A source's activity line SHALL count the signals of every controller. The sinks line SHALL mark a sink that is not running on any controller, naming that controller. Queried and tailed signals SHALL come from every controller and name theirs.

#### Scenario: A source enabled on part of the cluster

- **WHEN** `flezha_file_sink` is enabled on two of three controllers
- **THEN** its row reads that it is on 2 of 3 controllers and its switch shows the mixed state

#### Scenario: Switching a source on everywhere

- **WHEN** an operator switches that source on
- **THEN** the switch applies to every controller and the row reads that it is on everywhere

#### Scenario: A controller does not apply the switch

- **WHEN** the switch answers that `flezha@c3` did not apply it
- **THEN** the screen names `flezha@c3` and the row keeps its mixed state

### Requirement: Quotas and namespaces are cluster totals

A namespace's quota counters SHALL be shown as the cluster totals the controller answers, and a breach SHALL be judged against those totals. The namespace listing SHALL mark a namespace as running when any controller runs its hub, and as declared with no hub only when no controller does.

#### Scenario: Relays on two controllers count against one quota

- **WHEN** a namespace with `max_relays: 5` runs three relays on one controller and two on another
- **THEN** its relays counter reads 5 of 5 and the quota is marked as breached

#### Scenario: A hub runs on another controller

- **WHEN** a namespace's hub runs only on a controller the console is not connected to
- **THEN** the namespace listing marks it as running

### Requirement: A relay's own reads reach the controller that holds them

The relay screen, its Listen view and its State tab SHALL read a relay's facts, Cells, task journal, input log, outbox, time travel and diagnosis through the published calls the core contract routes to the controller holding them. A relay on another controller SHALL therefore show the same sections and figures as one on the connected controller. A diagnosis SHALL include the dead letters and input-log findings of the relay's own controller.

#### Scenario: The State tab of a relay on another controller

- **WHEN** an operator opens the State tab of a durable steps relay hosted on `flezha@c2`
- **THEN** its Cells, task journal and input log are listed as for a relay on the connected controller

#### Scenario: Factories served elsewhere

- **WHEN** a factory is served only by a runner connected to another controller
- **THEN** the launcher, the schedule form and the Cluster factory lookup offer it as served, with that runner

