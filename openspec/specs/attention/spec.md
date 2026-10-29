# attention Specification

## Purpose
How the console finds what needs an operator: one derivation of open problems — only conditions Flezha or the operator handles, a missing runner folded into one item per factory, every kind in the same condition rows — the per-operator pulse that refreshes it, the rail's count, the Open problems screen and the problems shown inline on a Home.
## Requirements
### Requirement: Open problems are gathered by one derivation

The console SHALL derive its open problems in one pure module from controller
reads it already makes. Each problem SHALL be an attention item carrying:

- a kind;
- a severity;
- the namespace it concerns, if any;
- the object it concerns;
- a title saying what is wrong;
- its condition rows: State, Cause, Impact, Handled by and Next step, built from
  the read that found it, never stating a fact the read did not hold;
- for a relay, its state and factory and, when read, the runners serving that
  factory;
- the time it was first seen;
- the actions that address it.

An item SHALL be opened only for a condition whose Handled by is Flezha or You.
A condition handled by Nobody is not a problem. The severity SHALL follow the
handler: You is negative, Flezha is warning. Dead letters are the one exception:
their records wait safely in the queue, so their severity SHALL be warning.

A dead-letter item SHALL name the namespace whose relay rows hold the relay of its
class, and no namespace when no namespace read holds it.

The kinds SHALL be:

- a relay whose condition is handled by Flezha or You, other than one folded into
  a factory item;
- a factory that no runner serves, while at least one relay waits on it;
- a partition group whose coverage is faulted;
- a quota at or over its limit;
- dead letters waiting for a relay class;
- references past their RPO target;
- a recent stall verdict;
- an unclaimed authorization bootstrap;
- version skew between the console and the controller.

A relay whose Handled by is You only because no runner serves its factory SHALL be
folded into its factory's item rather than given one of its own. The factory item
SHALL:

- name the factory;
- say how many relays wait on it, by state;
- offer Open cluster.

Each kind's condition rows SHALL be:

| Kind | State | Cause | Impact | Handled by | Next step |
|---|---|---|---|---|---|
| Factory | No runner | 0 runners serve `<factory>` | N relays wait, by state | You | Start a runner that serves `<factory>` |
| Partition group | Coverage broken | Members leave key groups uncovered or overlapping | Traffic for those key groups is lost | You | Fix the members' key ranges |
| Quota | Limit reached | `<value>` of `<limit>` `<kind>` in use | Another is refused | You | Free one or raise the limit |
| Dead letters | Dead letters | `<tasklets>` could not process N records | They wait in the dead-letter queue | You | Replay or drop them |
| RPO | Behind target | N references not shipped within the RPO target | Their state has one copy | Flezha | Shipped by the remote tier |
| Stall | Stalled | Localized at the `<layer>` on `<subject>` | Records stop moving there | Flezha | Cleared when records move again |
| Bootstrap | Unclaimed | No admin claimed authorization | Every operator verb is refused | You | Run `flz auth bootstrap` |
| Skew | Version skew | The controller lacks `<call>` | Screens that need it fail | You | Run matching console and controller versions |

A relay item's rows SHALL be those of `relay-state-summary`.

Home, the shell and the Open problems screen SHALL all read their items from this
one derivation. Every item SHALL be rendered with the shared condition component.

#### Scenario: A suspended relay a runner can wake

- **WHEN** relay `pwi4eosjk` is suspended and one runner serves its factory
- **THEN** no item is opened for it

#### Scenario: Suspended relays nothing can run

- **WHEN** relays `a` and `b` are suspended, relay `c` is unbound, all three of
  factory `echo_steps`, and no runner serves `echo_steps`
- **THEN** one negative item reads "No runner serves factory echo_steps"
- **AND** its Impact reads "3 relays wait: 2 suspended, 1 unbound"
- **AND** its Handled by reads "You", and it offers Open cluster
- **AND** no item is opened for `a`, `b` or `c` on their own

#### Scenario: A halted relay keeps its own item

- **WHEN** a relay of a factory no runner serves is halted
- **THEN** it has its own negative item with Handled by "You"
- **AND** it is not folded into the factory item

#### Scenario: A failed relay Flezha is rebinding

- **WHEN** a relay is failed and a runner serves its factory
- **THEN** a warning item reads Handled by "Flezha" and Next step "Rebound to
  another runner by Flezha"

#### Scenario: A quota breach

- **WHEN** a namespace's relay counter has reached its limit
- **THEN** a negative item shows State "Limit reached" and Handled by "You", and
  links to that namespace's limits section

#### Scenario: Dead letters

- **WHEN** the dead-letter statistics report entries for a relay class
- **THEN** a warning item names the class and the count of dead letters
- **AND** it shows State "Dead letters", Handled by "You" and Next step "Replay or
  drop them"
- **AND** it links to the dead-letter screen filtered to that class
- **AND** its text does not say "parked"

#### Scenario: Dead letters belong to their relay's namespace

- **WHEN** relay `orders` runs in namespace `default` and its class has dead letters
- **THEN** the dead-letter item names namespace `default`

#### Scenario: Every kind has the same rows

- **WHEN** one item of each kind is rendered
- **THEN** each shows State, Cause, Impact, Handled by and Next step, in that order

#### Scenario: One source of items

- **WHEN** the codebase is inspected
- **THEN** Home's problems, the shell's counts and the Open problems screen call
  the same derivation, and no other module builds attention items

### Requirement: The shell keeps a per-operator pulse

On a connected screen, the shell SHALL gather attention items every 10 seconds
with the operator's own token, for every namespace that token reaches. For each
namespace it SHALL make a fixed number of controller calls, plus one runner read per
distinct factory that a suspended, unbound, failed or recovering relay names. It
SHALL make none per relay. Home SHALL read runners through the same function. The
pulse SHALL NOT run on the disconnected first render. No item SHALL be gathered
with any principal but the operator's.

Beside its items, the pulse SHALL keep the fleet totals its reads already answer:
the relay health counts summed across the reachable namespaces and the number of
durability breaches. The pulse SHALL NOT read runners, controller nodes or the
controller's status.

#### Scenario: The pulse runs only when connected

- **WHEN** a screen renders over plain HTTP before the socket connects
- **THEN** no pulse call is made

#### Scenario: The pulse cost does not grow with relays

- **WHEN** a namespace holds any number of relays of one factory, some of them
  suspended
- **THEN** the pulse makes the same number of calls for it, with one runner read for
  that factory

#### Scenario: No waiting relay, no runner read

- **WHEN** every relay in a namespace is healthy
- **THEN** the pulse makes no `runners_for_factory` call for it

#### Scenario: Scope follows the token

- **WHEN** the operator's token is bound to one namespace
- **THEN** only that namespace's items are gathered and shown

#### Scenario: The pulse reads no fleet figures

- **WHEN** the pulse runs on any screen
- **THEN** it makes no `runners`, `cluster_status` or `controller_status` call

### Requirement: The shell shows how much needs attention

The rail's Problems entry SHALL show the number of open attention items, in the
tone of the most severe of them, and nothing when there are none.

#### Scenario: Two problems

- **WHEN** one relay is halted and one relay class has dead letters
- **THEN** the rail's Problems entry shows 2 in the negative tone

#### Scenario: Only dead letters

- **WHEN** the only open item is a relay class's dead letters
- **THEN** the rail's Problems entry shows 1 in the warning tone

#### Scenario: A sleeping relay is not counted

- **WHEN** the only relay that is not healthy is suspended, and a runner serves its
  factory
- **THEN** the rail's Problems entry shows no count

#### Scenario: All clear

- **WHEN** no item is open
- **THEN** the rail's Problems entry shows no count

### Requirement: The Open problems screen lists every open problem with its fix

The console SHALL serve `/problems`, reached from the rail's Problems entry in its
platform group. The screen SHALL list every open item, ordered by severity and then
by first-seen time, oldest first. Each item SHALL show:

- its title;
- its condition rows;
- its namespace and object;
- how long it has been seen;
- its actions as buttons.

A relay item SHALL show the same rows here as on Home, including the runners serving
its factory. Actions SHALL be offered only when the operator's operations allow them.
An action that changes state SHALL go through the confirmation its own screen already
uses. With nothing open, the screen SHALL say so in a sentence and state when it last
checked.

#### Scenario: Acting on an item

- **WHEN** the operator activates Diagnose on a degraded relay's item
- **THEN** the controller's diagnosis appears beneath that item, as its Diagnosis row

#### Scenario: Home and Open problems agree

- **WHEN** a relay item is shown on Home and on Open problems on the same pulse
- **THEN** both show the same State, Cause, Impact, Runner, Handled by and Next step

#### Scenario: A problem resolves

- **WHEN** a failed relay becomes healthy before the next pulse
- **THEN** its item leaves the list on that pulse without a reload

#### Scenario: A runner connects

- **WHEN** a runner serving `echo_steps` connects while its factory item is open
- **THEN** the factory item leaves the list on the next pulse
- **AND** its suspended relays open no items of their own

#### Scenario: Nothing is wrong

- **WHEN** no item is open
- **THEN** the screen says nothing needs attention and when it last checked

### Requirement: Home shows its namespace's items inline

Home SHALL list the attention items of its own namespace, its relays' dead letters
included, directly below the namespace indicator tiles, in a section titled with how
many need attention, using the same item component and actions as the Open problems
screen. It SHALL collapse to the first three items, with a link to the rest.

#### Scenario: More than three items

- **WHEN** a namespace has five open items
- **THEN** Home shows three and a link reading that two more are on the Open problems
  screen

#### Scenario: Placement below the namespace tiles

- **WHEN** a namespace has two relays needing attention
- **THEN** the section titled "2 relays need attention" renders after the namespace
  tiles and before "What happened"

#### Scenario: Dead letters on Home

- **WHEN** a relay of the namespace has dead letters
- **THEN** Home lists the dead-letter item

### Requirement: A seen dead letter raises no problem

The derivation SHALL leave out dead letters whose reference and generation are marked seen. The rail count, the Open problems screen, Home's problem list, headline and tiles SHALL agree on that set.

#### Scenario: The only dead letter is seen

- **WHEN** the only open problem is a dead letter and an operator marks it seen
- **THEN** the rail shows no count, Open problems lists nothing, and Home's headline says nothing needs attention

