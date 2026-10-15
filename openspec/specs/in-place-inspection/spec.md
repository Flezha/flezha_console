# in-place-inspection Specification

## Purpose
How objects are inspected without leaving the current screen: the drawer, the selection kept in the address bar, keyboard use, and the relay, runner, plugin and parked-entry inspectors.

## Requirements
### Requirement: Objects are inspected in a drawer on the current screen

The console SHALL open an inspector drawer on the current screen when a relay, a
runner, a plugin or a parked dead-letter entry is selected from a map or a
listing. Selecting one SHALL NOT navigate away. The drawer SHALL be the console kit's drawer component and
SHALL open beside the content at desktop width, and as a full-screen sheet at
phone width. Opening another object SHALL replace the drawer's content.

#### Scenario: Inspecting from a listing

- **WHEN** an operator activates a relay row on the relays index
- **THEN** the relay inspector opens on the relays index and the listing stays in
  place behind it

#### Scenario: Replacing the selection

- **WHEN** an inspector is open and the operator selects another object
- **THEN** the drawer shows the new object and no second drawer opens

#### Scenario: Phone width

- **WHEN** an inspector opens at a viewport width of 599 px or less
- **THEN** it covers the screen as a sheet with its close control in reach

### Requirement: The selection lives in the address bar

The open inspector SHALL be named in the query string as `inspect=<kind>:<id>`,
applied through a patch rather than a navigation. Loading a URL that carries a
selection SHALL open that inspector. Closing the inspector SHALL remove the
parameter. The browser's back control SHALL close an inspector opened by a
selection.

#### Scenario: Sharing an inspected relay

- **WHEN** an operator copies the URL while the `orders` inspector is open and
  another operator opens it
- **THEN** the same screen opens with the `orders` inspector open

#### Scenario: Back closes the drawer

- **WHEN** an operator opens an inspector and presses the browser's back control
- **THEN** the inspector closes and the screen stays

#### Scenario: A selection that no longer exists

- **WHEN** the URL names a relay that is no longer running
- **THEN** the screen renders, and the drawer states that the relay is not
  running rather than showing an error page

### Requirement: The drawer is complete from the keyboard

Opening an inspector SHALL move focus into it. Escape SHALL close it. Closing it
SHALL return focus to the element that opened it. While it is open, Tab SHALL
cycle within it. The drawer SHALL carry a dialog role and an accessible name
naming the object.

#### Scenario: Keyboard round trip

- **WHEN** an operator opens a relay inspector from a focused lane and presses
  Escape
- **THEN** the inspector closes and focus is back on that lane

### Requirement: A relay inspector says what the relay is doing

A relay inspector SHALL show:

- the relay's sentence header;
- its health once;
- its inbound and outbound rates with a sparkline, taken from the host screen's
  existing measurements;
- its factory and the factory's description;
- its node, runner and uptime;
- the number of plugins bound to it.

It SHALL offer:

- Diagnose, answered inline;
- Stop, through the existing confirmation, when the operator's operations allow;
- a link that opens the relay's Live view.

Opening it SHALL cost at most one `Flezha.Service.Relay.overwatch_state/3` call,
made when it opens and not repeated on the host's tick.

#### Scenario: Opening a running relay

- **WHEN** an operator opens the `orders` inspector
- **THEN** it shows its sentence, health, rates, factory, node, runner, uptime
  and bindings
- **AND** exactly one overwatch read was made for it

#### Scenario: Diagnosing in place

- **WHEN** the operator activates Diagnose in the inspector
- **THEN** the controller's diagnosis appears inside the drawer

#### Scenario: A viewer cannot stop

- **WHEN** the operator's operations do not include stopping a relay
- **THEN** the inspector renders no Stop control

### Requirement: Runner, plugin and parked-entry inspectors

The runner inspector SHALL show:

- the runner's shortened id with its full id copyable;
- its OS pid;
- its principal;
- the count of factories it serves, with a filterable list of them;
- the relays bound to it.

The plugin inspector SHALL show:

- the plugin's name;
- its provider, with the provider's description;
- its hooks;
- the relays bound to it;
- where it runs.

The parked-entry inspector SHALL show the entry's metadata and a payload preview.
It SHALL offer Replay and Drop through the dead-letter screen's existing actions
and confirmations.

#### Scenario: Inspecting a runner

- **WHEN** an operator opens a runner inspector
- **THEN** it shows the runner's pid, principal, factory count and bound relays

#### Scenario: Inspecting a parked entry

- **WHEN** an operator opens a parked entry from the dead-letter screen
- **THEN** its metadata and payload preview show in the drawer, with Replay and
  Drop available as the operator's operations allow

