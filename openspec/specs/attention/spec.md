# attention Specification

## Purpose
How the console finds what needs an operator: one derivation of open problems, the per-operator pulse that refreshes it, the rail's count, the Open problems screen and the problems shown inline on a Home.
## Requirements
### Requirement: Open problems are gathered by one derivation

The console SHALL derive its open problems in one pure module from controller
reads it already makes. Each problem SHALL be an attention item carrying:

- a kind;
- a severity: warning or negative;
- the namespace it concerns, if any;
- the object it concerns;
- a sentence saying what is wrong;
- a sentence saying why, built from the read that found it, which states only what
  the state means and never a fact the read did not hold;
- for a relay, the runners serving its factory when the caller read them;
- the time it was first seen;
- the actions that address it.

The kinds SHALL be:

- a relay whose health is not healthy, or that is unplaced;
- a partition group whose coverage is faulted;
- a quota at or over its limit;
- dead letters waiting for a relay class;
- references past their RPO target;
- a recent stall verdict;
- an unclaimed authorization bootstrap;
- version skew between the console and the controller.

Home, the shell and the Open problems screen SHALL all read their items from this
one derivation. A relay item SHALL be rendered with the relay state summary (see
`relay-state-summary`).

#### Scenario: A suspended relay

- **WHEN** relay `testnet_echo` reports `suspended`
- **THEN** an item says `testnet_echo` is suspended, says why from what the
  controller reports, and offers Diagnose and Open relay
- **AND** the why sentence says it was suspended at a committed boundary on purpose,
  and does not call it parked or claim it has no runner

#### Scenario: A suspended relay on Home with no runner for its factory

- **WHEN** Home derives an item for a suspended relay and no runner it read serves
  the relay's factory
- **THEN** the item's summary says no runner serves its factory and that it cannot
  run until one connects

#### Scenario: A quota breach

- **WHEN** a namespace's relay counter has reached its limit
- **THEN** a negative item names the namespace and the quota, and links to that
  namespace's limits section

#### Scenario: Dead letters

- **WHEN** the dead-letter statistics report entries for a relay class
- **THEN** an item names the class and the count of dead letters, and links to the
  dead-letter screen filtered to that class
- **AND** its text does not say "parked"

#### Scenario: One source of items

- **WHEN** the codebase is inspected
- **THEN** Home's problems, the shell's counts and the Open problems screen
  call the same derivation, and `Topology.summary/1` delegates its attention list
  to it

### Requirement: The shell keeps a per-operator pulse

On a connected screen, the shell SHALL gather attention items every 10 seconds
with the operator's own token, for every namespace that token reaches. It SHALL
make a fixed number of controller calls per namespace and none per relay. The
pulse SHALL NOT run on the disconnected first render. No item SHALL be gathered
with any principal but the operator's.

The pulse SHALL read off the screen's LiveView process, so a slow controller
never delays a click, a dialog or the screen's own read. At most one pulse read
SHALL be in flight per screen. A pulse that comes due while one is in flight
SHALL be skipped. A pulse read that fails or exits SHALL keep the previous items,
fleet figures and last-read time.

Beside its items, the pulse SHALL keep the fleet totals its reads already answer:
the number of reachable namespaces and the relay health counts summed across them.
A screen that asks for fleet figures SHALL also get the runner count across those
namespaces, the controller nodes, and the controller's status. Those reads are a
fixed number per namespace, made only while that screen is visible. A screen that
does not ask SHALL cost the pulse no extra call.

#### Scenario: The pulse runs only when connected

- **WHEN** a screen renders over plain HTTP before the socket connects
- **THEN** no pulse call is made

#### Scenario: The pulse cost is fixed

- **WHEN** a namespace holds any number of relays
- **THEN** the pulse makes the same number of calls for it

#### Scenario: Scope follows the token

- **WHEN** the operator's token is bound to one namespace
- **THEN** only that namespace's items are gathered and shown

#### Scenario: Only Home pays for fleet figures

- **WHEN** the pulse runs on the relays index
- **THEN** it makes no `runners`, `cluster_status` or `controller_status` call

#### Scenario: A hidden Home pays nothing extra

- **WHEN** the pulse runs while Home's tab is hidden
- **THEN** it makes no `runners`, `cluster_status` or `controller_status` call

#### Scenario: A slow pulse does not hold the screen

- **WHEN** the pulse's calls take five seconds to answer
- **THEN** the screen answers clicks during those five seconds
- **AND** no second pulse read starts until the first has answered

#### Scenario: A failed pulse keeps the last reading

- **WHEN** the system tiles show two namespaces and the next pulse read exits
- **THEN** the tiles keep showing two namespaces with the earlier last-read time

### Requirement: The shell shows how much needs attention

The rail's Problems entry SHALL show the number of open attention items, in the
tone of the most severe of them, and nothing when there are none.

#### Scenario: Two problems

- **WHEN** one relay is suspended and one entry is parked
- **THEN** the rail's Problems entry shows 2 in the tone of the worst item

#### Scenario: All clear

- **WHEN** no item is open
- **THEN** the rail's Problems entry shows no count

### Requirement: The Open problems screen lists every open problem with its fix

The console SHALL serve `/problems`, reached from the rail's Problems entry in its
platform group. The screen SHALL list every
open item, ordered by severity and then by first-seen time, oldest first. Each
item SHALL show its what and why sentences, its namespace and object, how long it
has been seen, and its actions as buttons. Actions SHALL be offered only when the
operator's operations allow them. An action that changes state SHALL go through
the confirmation its own screen already uses. With nothing open, the screen SHALL
say so in a sentence and state when it last checked.

#### Scenario: Acting on an item

- **WHEN** the operator activates Diagnose on a suspended relay's item
- **THEN** the controller's diagnosis appears beneath that item

#### Scenario: A problem resolves

- **WHEN** a suspended relay becomes healthy before the next pulse
- **THEN** its item leaves the list on that pulse without a reload

#### Scenario: Nothing is wrong

- **WHEN** no item is open
- **THEN** the screen says nothing needs attention and when it last checked

### Requirement: Home shows its namespace's items inline

Home SHALL list the attention items of its own namespace directly below the
namespace indicator tiles, in a section titled with how many need attention, using
the same item component and actions as the Open problems screen. It SHALL collapse
to the first three items, with a link to the rest.

#### Scenario: More than three items

- **WHEN** a namespace has five open items
- **THEN** Home shows three and a link reading that two more are on the Open problems
  screen

#### Scenario: Placement below the namespace tiles

- **WHEN** a namespace has two relays needing attention
- **THEN** the section titled "2 relays need attention" renders after the namespace
  tiles and before "What happened"

