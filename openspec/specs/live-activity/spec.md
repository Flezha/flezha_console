# live-activity Specification

## Purpose
How the console shows change over time: recent history behind throughput figures, marks on changed figures, the event river, and motion that is never needed to read state.
## Requirements
### Requirement: Throughput figures show their recent history

Every measured rate the console shows outside the relay pipeline graph SHALL be
accompanied by a sparkline of the samples this console measured for it. That
covers:

- Dashboard's Flow tile, over the namespace's summed inbound rate;
- a relay inspector;
- the relays index rate column.

At most 60 samples SHALL be kept, in memory, per relay per screen. A sparkline
with fewer than two samples SHALL render nothing rather than a flat line.

#### Scenario: A rate with history

- **WHEN** a relay has been measured over ten ticks
- **THEN** its rate is shown beside a sparkline drawn from those ten samples

#### Scenario: Too few samples

- **WHEN** a relay has been measured once
- **THEN** no sparkline is drawn

#### Scenario: The namespace's flow

- **WHEN** Dashboard has measured its namespace over ten ticks
- **THEN** the Flow tile's sparkline is drawn from ten samples, each the sum of
  the namespace's relays' inbound rates on that tick

### Requirement: Changed figures are marked as they change

A count or rate that changes between refreshes SHALL be briefly marked as
changed. The mark SHALL be applied on the client and SHALL survive the server
patch for its duration. It SHALL carry no state and SHALL NOT be the only way the
new value is conveyed.

#### Scenario: A count goes up

- **WHEN** the parked count rises between two refreshes
- **THEN** the figure shows its new value and is marked as changed for a moment

### Requirement: The event river shows what this console saw happen

Dashboard and the relays index SHALL show an event river: a newest-first list with a
15-minute time track. It SHALL hold these events:

- relay lifecycle signals;
- runner session events;
- attention items appearing and clearing between pulses.

Each event SHALL carry its time, its object and a sentence. The river SHALL keep
at most the fifty most recent events. It SHALL state that it covers what this
console saw since the screen opened. Dashboard's river SHALL show only events for its
own namespace.

#### Scenario: A relay starts

- **WHEN** a relay is started while Dashboard is open
- **THEN** a sentence naming the relay and its factory appears at the top of the
  river and a mark appears on its track

#### Scenario: A problem clears

- **WHEN** an attention item present on one pulse is gone on the next
- **THEN** the river records that it cleared

#### Scenario: Another namespace's event

- **WHEN** a relay starts in another namespace while Dashboard for `default` is open
- **THEN** it does not appear in `default`'s river

### Requirement: Motion is never required to read state

Every animation SHALL stop under `prefers-reduced-motion: reduce`, and every state
it conveys SHALL remain readable without it. That covers flow dots, change marks and
the drawer's entrance.

#### Scenario: Reduced motion

- **WHEN** the device asks for reduced motion
- **THEN** no wire or mark animates, and rates, health and liveness
  are still stated in words or figures

