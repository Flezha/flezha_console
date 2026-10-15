# namespace-home Specification

## Purpose
A namespace's Home: the screen the root address lands on, its headline sentence, the namespace map with its lanes, bounds and selection, and the teaching state of an empty namespace.

## Requirements
### Requirement: Home is the namespace's own screen

The console SHALL serve each namespace's Home at `/namespaces/:ns`. Home SHALL
replace both the former dashboard and the former namespace overview. From top to
bottom it SHALL hold:

- a headline sentence;
- the namespace's attention items;
- the live namespace map;
- the event river;
- the namespace's folded sections: limits, access, partition groups, finished
  relays and runners.

No other screen SHALL render the namespace data-plane summary.

#### Scenario: Opening a namespace

- **WHEN** an operator opens `/namespaces/default`
- **THEN** the headline, the attention items for `default`, the map and the river
  render in that order above the folded sections

#### Scenario: The summary is not duplicated

- **WHEN** the routed screens are rendered
- **THEN** only Home renders the namespace data-plane summary and its map

#### Scenario: The dashboard module is gone

- **WHEN** the codebase is searched for `DashboardLive`
- **THEN** no module, route or template of that name exists

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
- **THEN** the headline states that the controller cannot be reached, and no map
  renders

### Requirement: The namespace map draws the data plane at fixed cost

Home SHALL draw the namespace's data plane as a map. The map SHALL be built from
the reads the namespace summary already makes, plus one
`Flezha.Service.Relay.relay_plugins/2` call, and SHALL issue no per-relay
controller call. It SHALL draw these columns:

- sources: each distinct `on_input` plugin binding, and one source for calls and
  sends;
- runner bands: one per runner serving the namespace, labelled with the runner's
  shortened id and its OS pid, and holding a lane for each relay bound to it;
- an unbound zone below the bands, holding relays that have no runner, drawn in
  the warning style;
- outputs: each distinct `on_output` plugin binding, and the runner stream;
- a dead-letter drain carrying the parked count, linked to the dead-letter screen.

Wires SHALL join each lane to the sources and outputs it is bound to.

#### Scenario: A relay bound to a runner

- **WHEN** relay `orders` is bound to runner `default_58efe7505741`
- **THEN** its lane sits inside that runner's band

#### Scenario: A relay with no runner

- **WHEN** relay `testnet_echo` has no runner
- **THEN** its lane sits in the unbound zone outside every band, in the warning
  style, and says it is waiting for a runner

#### Scenario: Plugins become sources and outputs

- **WHEN** `orders` has an `on_input` binding and an `on_output` binding
- **THEN** the map draws that input as a source and that output as an output,
  each wired to the `orders` lane

#### Scenario: The cost does not grow with relays

- **WHEN** the map is assembled for a namespace of any size
- **THEN** no controller call is made per relay

#### Scenario: Parked entries are visible

- **WHEN** the dead-letter statistics report parked entries
- **THEN** the drain shows their count and links to `/dlq`

### Requirement: Map lanes carry health, history and flow

Each relay lane SHALL be a focusable control. It SHALL show:

- the relay id;
- its run;
- its health, both in words and as a shape distinct per verdict, never by colour
  alone;
- a sparkline of the relay's last 60 measured rates;
- its current inbound rate.

A wire SHALL animate at the speed bucket of its measured rate and SHALL be static
at zero rate or before two snapshots exist. Lanes SHALL be ordered with relays
needing attention first, then by measured throughput, then by id.

#### Scenario: A busy relay

- **WHEN** a relay's inbound rate is above zero after two snapshots
- **THEN** its lane shows the rate and a sparkline, and its wires carry the
  matching `topo-flow-*` speed class

#### Scenario: The first snapshot

- **WHEN** the map renders from its first snapshot
- **THEN** no wire animates and no rate figure is shown

#### Scenario: Attention comes first

- **WHEN** a suspended relay and a busier healthy relay share a band
- **THEN** the suspended relay's lane is drawn first

#### Scenario: Health is not colour alone

- **WHEN** a lane's health is anything other than healthy
- **THEN** the lane carries the health in words and a shape distinct from a
  healthy lane

### Requirement: The map stays bounded at any fleet size

Within a runner band, more than three relays started from one factory SHALL be
drawn as one stack lane. A stack lane SHALL name the factory and the member count,
and SHALL show its members' health counts and combined rate. A stack lane SHALL
expand into its member lanes on request. A band SHALL draw at most twelve lanes,
and then a link reading "+N more", which opens the relays index filtered to that
runner.

#### Scenario: Several relays of one factory

- **WHEN** four relays started from `store_input` share a runner
- **THEN** the band draws one `store_input ×4` stack lane

#### Scenario: Expanding a stack

- **WHEN** the operator activates a stack lane's expand control
- **THEN** its four member lanes are drawn in its place

#### Scenario: A crowded band

- **WHEN** a band would hold more than twelve lanes after stacking
- **THEN** it draws twelve and a "+N more" link to the relays index filtered by
  that runner

### Requirement: Selecting on the map inspects in place

Home SHALL inspect map selections in place: activating a relay lane, a runner
band's heading, or a source or output node SHALL open that object's inspector on Home, as the `in-place-inspection`
capability defines, without navigating away. The selected element SHALL be marked
on the map.

#### Scenario: Selecting a relay

- **WHEN** the operator activates the `orders` lane
- **THEN** the relay inspector for `orders` opens beside the map
- **AND** the address bar carries the selection

#### Scenario: Selecting a runner

- **WHEN** the operator activates a runner band's heading
- **THEN** the runner inspector opens for that runner

### Requirement: An empty namespace teaches instead of drawing nothing

When a namespace has no relays and no runners, the map region SHALL say in one
sentence what a runner and a relay are. It SHALL offer Start relay when the
operator's operations include starting one. It SHALL state that a runner must
connect before a relay can run.

#### Scenario: A fresh namespace

- **WHEN** an operator opens the Home of a namespace with nothing running
- **THEN** the map region explains that runners serve factories and relays are
  started from them, and offers Start relay when allowed

