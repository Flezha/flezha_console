# glossary-and-help Specification

## Purpose
How the console explains itself: flezha terms defined where they appear, a README vocabulary that agrees with the glossary, help for the current screen, and keyboard shortcuts to the main places.
## Requirements
### Requirement: flezha terms explain themselves in place

The console SHALL keep one glossary of the flezha terms it uses. Each term SHALL
have a one- or two-sentence definition. The terms SHALL include at least:

- namespace, relay, run, runner, factory, tasklet, cell and output;
- task journal and input log;
- plugin, provider and hook;
- hub, posture, principal, role and quota;
- partition group and coverage;
- health;
- each relay state: suspended, halted, unbound, failed, recovering and degraded;
- handled by, with its three values: Nobody, Flezha and You;
- dead letter.

The glossary SHALL NOT define "parked" or "asleep".

Where a term first occurs in a page header, a sentence or a section title on a
screen, it SHALL be rendered with a term marker. That marker SHALL show the
definition on pointer hover and on keyboard focus, and the definition SHALL be its
accessible description.

#### Scenario: Hovering a term

- **WHEN** an operator hovers "runner" in a relay's header sentence
- **THEN** a popover gives the glossary's definition of runner

#### Scenario: Reaching a term by keyboard

- **WHEN** an operator tabs to a term marker
- **THEN** its definition is shown and announced

#### Scenario: Each term is marked once

- **WHEN** a screen's text uses "relay" several times
- **THEN** only its first occurrence carries the marker

#### Scenario: A state explains itself

- **WHEN** an operator hovers "Suspended" in a relay's condition
- **THEN** a popover says the relay stopped at a committed boundary on purpose, holds
  no runner, and wakes on the next message or its timer on a runner that serves its
  factory

#### Scenario: Halted explains itself

- **WHEN** an operator hovers "Halted" in a relay's condition
- **THEN** a popover says a fault stopped it that the system cannot fix by itself,
  that Flezha retries its bind, and that it stays stopped until a person fixes the
  cause

### Requirement: The README vocabulary and the glossary agree

Every term in the README's vocabulary table SHALL have a glossary entry, and a test
SHALL fail when one is missing.

#### Scenario: A new term in the README

- **WHEN** a term is added to the README vocabulary without a glossary entry
- **THEN** the glossary test fails, naming the term

### Requirement: Help explains the current screen

Pressing `?` outside a text field, or activating the topbar's help control, SHALL
open a help overlay for the current screen. The overlay SHALL hold:

- one paragraph saying what the screen shows and what it is for;
- the glossary entries for the terms the screen marks;
- the list of keyboard shortcuts.

Every routed screen kind SHALL have a purpose paragraph. Escape SHALL close the
overlay and return focus.

#### Scenario: Help on Dashboard

- **WHEN** an operator presses `?` on a namespace's Dashboard
- **THEN** the overlay explains that Dashboard draws the namespace's runners and relays
  live, lists the terms on screen, and lists the shortcuts

#### Scenario: Typing a question mark

- **WHEN** an operator types `?` into a text field
- **THEN** the character is typed and no overlay opens

#### Scenario: Every screen has a purpose

- **WHEN** the help test renders the overlay for every routed screen kind
- **THEN** each has a non-empty purpose paragraph

### Requirement: Keyboard shortcuts reach the main places

Outside a text field, the console SHALL bind these keys:

- `g d` to the namespace's Dashboard;
- `g r` to Relays;
- `g p` to Open problems;
- `g c` to Cluster;
- `?` to help;
- `Escape` to close the topmost overlay.

The shortcuts SHALL be listed in the help overlay. Each destination SHALL also be
reachable by clicking.

#### Scenario: Going to problems

- **WHEN** an operator presses `g` then `p` outside a text field
- **THEN** the browser navigates to `/problems`

#### Scenario: Shortcuts do not steal typing

- **WHEN** an operator types `g` then `d` into a filter field
- **THEN** both characters are typed and no navigation happens

### Requirement: Activating a term pins its own definition

Activating a term marker SHALL open a panel next to it with that term's own glossary definition, the same text its hover shows. The term SHALL be marked active and expanded while the panel is open. Clicking outside or pressing Escape SHALL close it. Activating a term SHALL NOT open the screen's help.

#### Scenario: Two terms, two definitions

- **WHEN** an operator clicks "role" and then "principal" on the Controller screen
- **THEN** the first panel shows the definition of role, and the second shows the definition of principal
- **AND** only the clicked term is marked active

### Requirement: A definition shown on hover stays on screen

A definition or hint shown on hover or focus SHALL be shown whole inside the viewport, kept at least 8 px from its edges. It SHALL open over what it explains, and under it when there is no room above. Near the right edge it SHALL move left rather than run past the edge. A scrolling region around what it explains SHALL NOT clip it.

#### Scenario: A term near the right edge

- **WHEN** an operator at 1440 px hovers the quota term on the Limits tile, the last tile in its row
- **THEN** the definition is shown whole, its right edge at least 8 px inside the viewport

