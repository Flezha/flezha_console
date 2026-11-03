# operator-language Specification

## Purpose
How the console speaks: controller values in words with a tone, no raw atoms in visible text, an opening sentence for every object, shortened copyable identifiers, providers described by what they do, and empty states that teach.
## Requirements
### Requirement: Controller values are rendered in words with a tone

Every controller value that names a state SHALL be rendered through one
translation module that answers its words and its tone: positive, warning,
negative or neutral. The states covered SHALL include:

- relay health;
- authorization posture;
- durability posture;
- boot readiness;
- shutdown phase;
- signal handler state;
- hub recovery;
- schedule status;
- namespace running state;
- quota state;
- steps facts;
- boolean facts.

No screen SHALL keep its own label map for a value the module translates.

#### Scenario: A durability posture

- **WHEN** the controller reports durability posture `:local_only`
- **THEN** the screen reads that durable state has one copy, on the node that
  wrote it, in a neutral tone

#### Scenario: Boot readiness

- **WHEN** the controller reports readiness `:ready`
- **THEN** the screen reads "Ready" in a positive tone

#### Scenario: No private label maps

- **WHEN** the web layer is searched for a function mapping a translated state to
  display text outside the translation module
- **THEN** none exists

### Requirement: No raw atom reaches visible text

Visible text on any routed screen SHALL contain no Elixir atom literal: no token
that begins with a colon and is followed by a lower-case identifier. The only
exception is inside a `code`, `pre` or `kbd` element showing a payload, schema or
command. A test SHALL render every routed screen against the fake controller and
fail on any such token.

#### Scenario: The gate catches a regression

- **WHEN** a screen renders `:enforced` as plain text
- **THEN** the language gate fails, naming the screen and the token

#### Scenario: Payloads are exempt

- **WHEN** a payload containing `:ok` is shown inside a code block
- **THEN** the gate passes

### Requirement: Every object opens on a sentence

Object headers SHALL be sentences: the header of a relay, a runner, a namespace,
the controller and the cluster SHALL include one sentence assembled from translated values. The sentence SHALL
say what the object is, where it runs, and its condition. An object's health SHALL
be shown once in its header, not repeated as a second badge.

#### Scenario: A relay header

- **WHEN** an operator opens relay `orders`
- **THEN** its header reads as a sentence naming its run, its factory, its runner,
  its node, its uptime and its health

#### Scenario: Health is not doubled

- **WHEN** a suspended relay's header renders
- **THEN** the suspension is stated once

### Requirement: Long identifiers are shortened and copyable

An identifier longer than 16 characters SHALL be shown shortened to its last 7
characters after an ellipsis. Its full value SHALL be its accessible name and its
tooltip, and activating it SHALL copy the full value. A relay id and a namespace
name SHALL always be shown in full.

#### Scenario: A runner id

- **WHEN** runner `default_58efe7505741` is shown
- **THEN** it reads `…7505741`, its accessible name is the full id, and
  activating it copies the full id

### Requirement: Providers are described by what they do

Wherever a plugin provider is listed, it SHALL be presented by its name, its
description, and the hooks it supports, as the controller declares them. Its
implementing module SHALL be secondary detail, available on request and not shown
by default.

#### Scenario: The plugins listing

- **WHEN** an operator opens a namespace's plugins
- **THEN** each plugin shows its provider's description and hooks, and no module
  name is visible until asked for

### Requirement: Empty states teach and offer the next step

An empty listing or region SHALL say in one sentence what would appear there and
what produces it. It SHALL offer the action that produces it when the operator's
operations allow that action.

#### Scenario: No schedules

- **WHEN** a namespace has no schedules
- **THEN** the screen says a schedule starts a relay on a cron expression, and
  offers New schedule when allowed

#### Scenario: A tap with nothing yet

- **WHEN** a tap is open and nothing has arrived
- **THEN** it says what it is waiting for and offers Send or call on the same
  relay when allowed

### Requirement: Each relay-state word means one thing

The console SHALL use each relay-state word with the one meaning the controller's
verdict gives it, and SHALL NOT use one state's word to explain another:

- **Suspended:** stopped at a committed boundary on purpose, not a fault. It holds
  no runner, and the next message or its timer wakes it on a runner that serves its
  factory;
- **Halted:** stopped by a fault the system cannot fix by itself; Flezha retries its
  bind, but a person has to fix the cause;
- **Unbound:** no runner is bound, and Flezha is binding one;
- **Failed:** its runner is gone past its grace, and Flezha is rebinding it;
- **Recovering:** unbound or failed within its grace;
- **Degraded:** running, and being repaired in place.

Every state SHALL be shown with who handles it: Nobody, Flezha or You (see
`relay-state-summary`).

The visible copy SHALL NOT contain:

- "parked", whether as a relay state, a dead-letter entry or anything else;
- "asleep".

A dead-letter entry SHALL be called a dead letter.

#### Scenario: Explaining a suspension

- **WHEN** any screen explains why a relay is suspended
- **THEN** the text says it stopped at a committed boundary on purpose
- **AND** it does not say "parked" or "asleep"

#### Scenario: A fault stop reads Halted

- **WHEN** the controller reports a relay `halted`
- **THEN** every screen shows the state as "Halted", with its glossary term and the
  shape and negative tone of the worst state

#### Scenario: No copy says parked

- **WHEN** the web layer's visible copy is searched for "parked" and "asleep"
- **THEN** neither word is found

### Requirement: Who handles a condition is said in three words

The console SHALL name who acts next on any condition with exactly one of:

- **Nobody:** planned, nothing to do;
- **Flezha:** the system is fixing it;
- **You:** an operator has to act.

Each word SHALL carry a glossary definition, and SHALL NOT be replaced by a sentence.

#### Scenario: Three words only

- **WHEN** the Handled by row of any condition renders
- **THEN** its value is "Nobody", "Flezha" or "You"

