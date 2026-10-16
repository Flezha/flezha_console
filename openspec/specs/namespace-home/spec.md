# namespace-home Specification

## Purpose
A namespace's Home: the screen the root address lands on, its headline sentence, the system and namespace indicator tiles, how it reads its controller (paused while hidden, one read per burst of events), and the teaching state of an empty namespace.
## Requirements
### Requirement: Home is the namespace's own screen

The console SHALL serve each namespace's Home at `/namespaces/:ns`. Home SHALL
replace both the former dashboard and the former namespace overview. From top to
bottom it SHALL hold:

- a headline sentence;
- the namespace's attention items;
- the system indicators;
- the namespace indicators;
- the event river;
- the namespace's folded sections: limits, access, partition groups, finished
  relays and runners.

No other screen SHALL render the namespace data-plane summary. Home SHALL NOT draw
a map of the namespace's data plane.

#### Scenario: Opening a namespace

- **WHEN** an operator opens `/namespaces/default`
- **THEN** the headline, the attention items for `default`, the system indicators,
  the namespace indicators and the river render in that order above the folded
  sections

#### Scenario: The summary is not duplicated

- **WHEN** the routed screens are rendered
- **THEN** only Home renders the namespace data-plane summary and its indicators

#### Scenario: The dashboard module is gone

- **WHEN** the codebase is searched for `DashboardLive`
- **THEN** no module, route or template of that name exists

#### Scenario: The map is gone

- **WHEN** the codebase is searched for `namespace_map` and `fui-map-`
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
namespace's condition. A second line SHALL carry its figures in words: how many
relays are healthy out of how many, the runner count, the measured inbound rate
once two snapshots exist, and the parked count. The condition SHALL be one of:

- flowing: every relay is healthy and at least one moved records since the last
  tick;
- quiet: every relay is healthy and none moved;
- needs attention: at least one relay or fault needs attention, naming how many;
- empty: no relays and no runners;
- unreachable: no controller connected.

#### Scenario: Everything is healthy and moving

- **WHEN** every relay in the namespace is healthy and rates show movement
- **THEN** the headline reads that the namespace is flowing

#### Scenario: One relay is suspended

- **WHEN** seven relays are healthy and one is suspended
- **THEN** the headline says one relay needs attention
- **AND** the second line says 7 of 8 relays are healthy

#### Scenario: Rates are not yet known

- **WHEN** Home renders from its first snapshot
- **THEN** the second line omits the rate rather than showing zero

#### Scenario: The controller is unreachable

- **WHEN** no controller node is connected
- **THEN** the headline states that the controller cannot be reached, and neither
  row of indicators renders

### Requirement: An empty namespace teaches instead of drawing nothing

When a namespace has no relays and no runners, the namespace indicators SHALL be
replaced by one sentence saying what a runner and a relay are. It SHALL offer
Start relay when the operator's operations include starting one. It SHALL state
that a runner must connect before a relay can run. The system indicators SHALL
still render.

#### Scenario: A fresh namespace

- **WHEN** an operator opens the Home of a namespace with nothing running
- **THEN** in place of the namespace indicators Home explains that runners serve
  factories and relays are started from them, and offers Start relay when allowed
- **AND** the system indicators still render

### Requirement: Home shows the system in indicator tiles

Above the namespace's own figures, Home SHALL show one row of tiles for everything
the operator's token reaches:

- **Namespaces:** how many are reachable.
- **Controller nodes:** how many, and which one this console is connected to.
- **Runners:** how many serve any reachable namespace.
- **Relays:** how many across the reachable namespaces, with a health strip and
  the healthy count.
- **Open problems:** how many, in the tone of the worst, linking to `/problems`.
- **Controller:** whether it is connected, its durability posture, and its
  durability breaches.

The figures SHALL come from the shell pulse (see `attention`). The row SHALL state
when it was last read.

#### Scenario: Two namespaces are reachable

- **WHEN** the token reaches `default` with three relays and `sandbox` with two
- **THEN** the Namespaces tile reads 2 and the Relays tile reads 5

#### Scenario: Nothing needs attention

- **WHEN** no attention item is open anywhere
- **THEN** the Open problems tile reads that nothing needs attention, in the
  positive tone

#### Scenario: A durability breach

- **WHEN** the controller reports a durability RPO breach
- **THEN** the Controller tile says so in words and in the negative tone

### Requirement: Home shows its namespace in indicator tiles

Below the system tiles, Home SHALL show one row of tiles for its namespace:

- **Relays:** the total, a health strip, and a count for each non-healthy verdict,
  each linking to the relays index filtered to this namespace and that health.
- **Runners:** how many serve the namespace, and how many are dropped.
- **Plugins:** how many distinct plugins are bound to its relays.
- **Schedules:** how many belong to it, and when the next one fires.
- **Parked:** the parked dead-letter count, linking to `/dlq`.
- **Flow:** the measured inbound rate with a sparkline of its last 60 samples,
  shown only once two snapshots exist.
- **Limits:** a meter for each quota kind, breached ones first.

Every tile SHALL be a kit tile. Every tile SHALL state its figure and condition in
words and SHALL mark a non-neutral tone with a shape as well as a colour. A figure
that changes between ticks SHALL be marked as changed. The row SHALL be built from
reads Home's tick already makes, with no call per relay.

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

