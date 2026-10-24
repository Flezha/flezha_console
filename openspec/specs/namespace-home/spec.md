# namespace-home Specification

## Purpose
A namespace's Home: the screen the root address lands on, its headline sentence, the namespace indicator tiles, how it reads its controller (in the background and one read at a time, paused while hidden, one read per burst of events), and the teaching state of an empty namespace.
## Requirements
### Requirement: Home is the namespace's own screen

The console SHALL serve each namespace's Home at `/namespaces/:ns`. Home SHALL
replace both the former dashboard and the former namespace overview. From top to
bottom it SHALL hold:

- a headline sentence;
- the namespace's attention items;
- the namespace indicators;
- the event river;
- the namespace's folded sections: limits, access, partition groups, finished
  relays and runners.

No other screen SHALL render the namespace data-plane summary. Home SHALL NOT draw
a map of the namespace's data plane. Home SHALL NOT show figures for the whole
cluster; those are the Cluster screen's (see `cluster-and-fleet`).

#### Scenario: Opening a namespace

- **WHEN** an operator opens `/namespaces/default`
- **THEN** the headline, the attention items for `default`, the namespace
  indicators and the river render in that order above the folded sections
- **AND** no tile counts another namespace

#### Scenario: The summary is not duplicated

- **WHEN** the routed screens are rendered
- **THEN** only Home renders the namespace data-plane summary and its indicators

#### Scenario: The dashboard module is gone

- **WHEN** the codebase is searched for `DashboardLive`
- **THEN** no module, route or template of that name exists

#### Scenario: The map is gone

- **WHEN** the codebase is searched for `namespace_map` and `fcon-map-`
- **THEN** no component, test id or style of either name exists

### Requirement: The root address lands on a Home

A request for `/` SHALL redirect to the Home of the namespace the shell keeps in
scope for the operator, which is the namespace they last worked in. When that
namespace is no longer reachable, it SHALL redirect to the first reachable
namespace in sorted order. When none is reachable, it SHALL redirect to
`/namespaces`. The redirect SHALL keep the scope in the address bar rather than
render a scope-less screen.

#### Scenario: A returning operator

- **WHEN** an operator who last worked in `sandbox` requests `/`
- **THEN** the browser lands on `/namespaces/sandbox`

#### Scenario: The remembered namespace is gone

- **WHEN** the remembered namespace is no longer reachable and `default` is
- **THEN** `/` redirects to the first reachable namespace in sorted order

#### Scenario: Nothing is reachable

- **WHEN** the bound token reaches no namespace
- **THEN** `/` redirects to `/namespaces`, which states that no namespace is
  reachable

### Requirement: Home opens on a headline sentence

Home SHALL open on one sentence in the display face. The sentence SHALL state the
namespace's condition. A second line SHALL carry its figures in words:

- how many relays are healthy out of how many and, when any are, how many are
  suspended;
- the runner count;
- the measured inbound rate, once two snapshots exist;
- the dead-letter count.

The condition SHALL be one of:

- flowing: no attention item is open and at least one relay moved records since the
  last tick;
- quiet: no attention item is open and none moved;
- needs attention: at least one attention item is open, naming how many;
- empty: no relays and no runners;
- unreachable: no controller connected.

A suspended relay that a runner can wake SHALL NOT turn the condition to needs
attention.

#### Scenario: Everything is healthy and moving

- **WHEN** every relay in the namespace is healthy and rates show movement
- **THEN** the headline reads that the namespace is flowing

#### Scenario: One relay is suspended and can wake

- **WHEN** seven relays are healthy, one is suspended, a runner serves its factory,
  and none moved records
- **THEN** the headline reads that the namespace is quiet
- **AND** the second line says 7 of 8 relays are healthy, 1 suspended

#### Scenario: One relay is suspended and nothing can wake it

- **WHEN** seven relays are healthy and one is suspended, and no runner serves its
  factory
- **THEN** the headline says one problem needs attention

#### Scenario: Rates are not yet known

- **WHEN** Home renders from its first snapshot
- **THEN** the second line omits the rate rather than showing zero

#### Scenario: The controller is unreachable

- **WHEN** no controller node is connected
- **THEN** the headline states that the controller cannot be reached, and neither
  row of indicators renders

#### Scenario: Dead letters are counted by their name

- **WHEN** three dead-letter entries are waiting in the namespace
- **THEN** the second line reads "3 dead letters" and never "3 parked"

### Requirement: An empty namespace teaches instead of drawing nothing

When a namespace has no relays and no runners, the namespace indicators SHALL be
replaced by one sentence saying what a runner and a relay are. It SHALL offer
Start relay when the operator's operations include starting one. It SHALL state
that a runner must connect before a relay can run.

#### Scenario: A fresh namespace

- **WHEN** an operator opens the Home of a namespace with nothing running
- **THEN** in place of the namespace indicators Home explains that runners serve
  factories and relays are started from them, and offers Start relay when allowed

### Requirement: Home shows its namespace in indicator tiles

Below its attention items, Home SHALL show one row of tiles for its namespace:

- **Relays:** the total, a health strip, and a count for each non-healthy verdict,
  each linking to the relays index filtered to this namespace and that health.
- **Runners:** how many serve the namespace, and how many are dropped.
- **Plugins:** how many distinct plugins are bound to its relays.
- **Schedules:** how many belong to it, and when the next one fires.
- **Dead letters:** the dead-letter count, linking to `/dlq`.
- **Flow:** the measured inbound rate with a sparkline of its last 60 samples,
  shown only once two snapshots exist.
- **Limits:** the peak use, a meter for each of the two most used quota kinds,
  breached ones first, and a link naming how many more quota kinds the folded Limits
  section holds.

Every tile SHALL be a kit tile. Every tile SHALL state its figure and condition in
words and SHALL mark a non-neutral tone with a shape as well as a colour. A figure
that changes between ticks SHALL be marked as changed. A figure SHALL carry its unit
apart from its number. The row SHALL be built from reads Home's tick already makes,
with no call per relay.

#### Scenario: One relay is suspended

- **WHEN** seven relays are healthy and one is suspended
- **THEN** the Relays tile reads 8, its strip carries both verdicts, and a
  "1 suspended" link opens `/relays?namespace=default&health=suspended`

#### Scenario: The first snapshot

- **WHEN** Home renders from its first snapshot
- **THEN** the Flow tile says the rate is being measured and shows no figure or
  sparkline

#### Scenario: A breached quota

- **WHEN** the namespace's `relays` quota is breached
- **THEN** the Limits tile shows the `relays` meter first, in the negative tone,
  with its value and limit in words

#### Scenario: Many quota kinds

- **WHEN** the namespace has five quota kinds
- **THEN** the Limits tile shows two meters and a link reading "+3 more in Limits"
  that opens the Limits section

#### Scenario: Nothing waits in the dead-letter queue

- **WHEN** no dead-letter entry is waiting
- **THEN** the Dead letters tile reads 0 in the positive tone and never says
  "parked"

#### Scenario: The cost does not grow with relays

- **WHEN** Home ticks for a namespace of two relays and of fifty
- **THEN** it makes the same number of controller calls

### Requirement: Home reads nothing while its tab is hidden

Home SHALL stop its tick while the browser tab is hidden. When the tab is shown
again it SHALL read at once.

#### Scenario: The operator switches tabs

- **WHEN** Home's tab has been hidden for a minute
- **THEN** no tick read is made during that minute
- **AND** one read is made as soon as the tab is visible again

### Requirement: A burst of events costs one read

Relay lifecycle events and runner events that concern Home's namespace SHALL
request a read rather than make one. Requests arriving within the coalescing
window SHALL result in a single read.

#### Scenario: Ten relays stop together

- **WHEN** ten `relay_stopped` events for the namespace arrive within the window
- **THEN** Home makes one read for them, and all ten appear on the river

#### Scenario: An event for another namespace

- **WHEN** a runner of another namespace disconnects
- **THEN** Home makes no read for it

### Requirement: Home's tiles share one height

Every indicator tile on Home SHALL lay out its label, figure, condition and foot in
one fixed order, with its foot at the bottom, and the tile row SHALL keep one
minimum row height, so its tiles stand at the same height whenever no tile's
content exceeds it.

#### Scenario: The row on a desktop

- **WHEN** Home renders at 1280 px wide with the default namespace's tiles
- **THEN** every namespace tile stands at the shared minimum
  height, or at most one line of text taller where its words wrap further

### Requirement: The namespace row is headed by its kind

The namespace tile row's section heading SHALL name its kind and the namespace, with
"Namespace" in the label face and the name in the display face, so the name never
stands alone as a heading.

#### Scenario: The default namespace

- **WHEN** Home renders for `default`
- **THEN** the namespace section heading reads "Namespace" then "default", in two
  faces

### Requirement: Home is usable before its first read answers

Home's connected mount SHALL NOT wait on Home's own read. The only controller
calls a mount makes are the ones the shell makes on every screen: the namespace
picker's list and the token's granted operations. The screen frame,
the shell, the rail and every control that needs no read SHALL be live as soon
as the socket connects. Until the first read answers, the namespace's figures
SHALL show the existing loading skeleton and the headline SHALL read that the
namespace is being read. When the first read answers, the figures SHALL replace
the skeleton without a reload.

#### Scenario: A slow controller delays the figures, not the screen

- **WHEN** every controller call takes five seconds to answer
- **AND** the operator opens Home
- **THEN** the socket connects without waiting for those calls
- **AND** the operator can open the help overlay and the command palette while
  the headline still reads that the namespace is being read

#### Scenario: The first read fills the skeleton

- **WHEN** Home's first read answers with three healthy relays
- **THEN** the skeleton is replaced by the headline, its figures and the
  namespace tiles

### Requirement: Home reads in the background, one read at a time

Every Home read SHALL run off the screen's LiveView process. That includes the
first read, the periodic tick, an event-requested read and the read after an
operator action. Clicks, dialogs and the inspector SHALL be answered while a
read is in flight. Home SHALL have at most one read in flight. A tick that comes
due while a read is in flight SHALL be skipped. A read requested while one is in
flight SHALL run once that read has answered. Any number of such requests SHALL
cost one follow-up read. While a read is in flight, Home SHALL keep showing the
figures it last read.

#### Scenario: A click during a slow read

- **WHEN** a read is in flight and has not answered for several seconds
- **AND** the operator opens the confirmation to stop a relay
- **THEN** the confirmation opens at once

#### Scenario: Ticks do not pile up

- **WHEN** one read takes longer than three tick intervals
- **THEN** no second read starts while it is in flight

#### Scenario: Events during a read cost one follow-up

- **WHEN** three runner events for the namespace arrive while a read is in flight
- **THEN** exactly one more read starts after the in-flight read answers

#### Scenario: Figures stay up between reads

- **WHEN** a tick's read is in flight
- **THEN** the headline and tiles keep the figures of the previous read and no
  skeleton is shown

### Requirement: An operator's action is followed by a read that started after it

After an operator's action on Home succeeds, Home SHALL show the action's flash
at once. It SHALL then show figures from a read that started after the action.
That includes stopping a relay, rescaling a partition group, saving quotas,
issuing or revoking a token, and binding or unbinding a role. Such a read SHALL
be made even while the operator has paused the screen. If a read is in flight
when the action succeeds, the follow-up read SHALL run after it, and the
in-flight answer SHALL NOT be the last thing shown.

#### Scenario: Stopping a relay during a read

- **WHEN** a read is in flight
- **AND** the operator stops relay `orders` and the controller confirms it
- **THEN** the flash says the relay was stopped
- **AND** after the in-flight read answers, a second read runs and its answer no
  longer lists `orders` as running

#### Scenario: An action on a paused screen

- **WHEN** the operator has paused Home and revokes a token
- **THEN** a read runs and the token's row shows it revoked

### Requirement: A late or failed read never disturbs the operator

Home SHALL drop a read's answer that arrives in any of these cases:

- a dialog that pauses Home is open;
- the operator has paused the screen;
- the tab is hidden.

The first read, and a read started by an operator's action, SHALL always be
applied. A read that fails or exits SHALL leave the last figures on screen. Home
SHALL show the existing load-error state, and the next tick SHALL try again.

#### Scenario: An answer lands on an open confirmation

- **WHEN** a tick's read is in flight
- **AND** the operator opens the rescale dialog before it answers
- **THEN** its answer is dropped and the rows behind the dialog do not change
- **AND** closing the dialog lets the next tick read again

#### Scenario: The read times out

- **WHEN** Home shows five relays and the next read exits on a controller timeout
- **THEN** the five relays stay on screen
- **AND** the load error is shown
- **AND** the following tick reads again

