# console-design-system Specification

## Purpose
The console's own design layer: role-named tokens and their contrast and use gates, self-hosted typefaces, the single component kit, the page grammar, loading skeletons, visible focus, and the dev-only kit page.
## Requirements
### Requirement: The console names its design tokens by role

The console SHALL define every colour, spacing, radius, elevation, motion and type
value its kit uses as a `--fcon-*` custom property in
`assets/css/console/tokens.css`. The scales — type, space, radius, control height,
drawer width, motion and layering — are the console's own. Each colour role SHALL
alias a `flezha_stylebook` token, so the console takes the stylebook's palette in
both themes and follows its theme switch:

| Role | Stylebook token |
| --- | --- |
| `--fcon-page` | `--surface-base` |
| `--fcon-canvas` | `--surface-sheet` |
| `--fcon-surface`, `--fcon-raised` | `--surface-raised` |
| `--fcon-hover` | `--surface-hover` |
| `--fcon-line` | `--border-default` |
| `--fcon-line-strong` | `--field-border` |
| `--fcon-ink-1`, `-2`, `-3` | `--text-primary`, `--text-secondary`, `--text-muted` |
| `--fcon-accent`, `--fcon-brand` | `--text-brand` |
| `--fcon-on-accent` | `--text-on-brand`; `--text-on-gold` in the dark theme |
| `--fcon-positive`, `--fcon-warning`, `--fcon-negative` | `--positive`, `--warning`, `--negative` |
| `--fcon-on-positive`, `-warning`, `-negative` | `--text-on-positive`, `--text-on-warning`, `--text-on-negative` |

Each fill role SHALL have a `-subtle` variant, mixed from that role and
`--fcon-surface`. The console SHALL add only what the stylebook has no token for:

- `--fcon-signal`, for live data only, and its `--fcon-on-signal` ink — the
  stylebook's `--gold` in the dark theme;
- the overlay scrim and the overlay shadow.

#### Scenario: A role follows the stylebook

- **WHEN** the stylebook changes the value of `--text-primary`
- **THEN** the console's primary ink changes with it, with no edit to the console

#### Scenario: Both themes are defined

- **WHEN** the dark theme is applied
- **THEN** every `--fcon-*` colour role resolves, either through the stylebook's own
  dark value or through the console's dark override

#### Scenario: Signal is not a status

- **WHEN** a relay's flow, a rate or a change mark is painted
- **THEN** it uses `--fcon-signal`, and no outcome badge uses `--fcon-signal`

### Requirement: The console's tokens are gated for contrast and use

The console SHALL run the stylebook's token gate with a console config over
`assets/` and `lib/`. The config names the console token file, the pairs to grade,
and the stylebook token file as its base, whose palettes resolve the roles that
alias it. The gate SHALL fail on:

- a `var(--fcon-*)` that no file defines;
- a `--fcon-*` token that nothing references;
- an ink-on-surface pairing below 4.5:1, or a solid fill and its matched ink below
  4.5:1, in either theme;
- a colour literal outside a token file.

The gate script SHALL take the config, and the base within it, as options, and
behave exactly as before without them.

#### Scenario: A low-contrast token

- **WHEN** `--fcon-ink-3` is set so that it reaches 4.2:1 on `--fcon-raised` in the
  light theme
- **THEN** the console gate fails, naming the pair and the theme

#### Scenario: An aliased role is graded

- **WHEN** the console gate grades `--fcon-ink-3` on `--fcon-raised`
- **THEN** it resolves each through the stylebook's palette for that theme and
  grades the resulting colours

#### Scenario: The stylebook's own run is unchanged

- **WHEN** the stylebook gate runs without a config
- **THEN** it grades the stylebook's tokens exactly as before, and flezha.com's
  check still passes

#### Scenario: A literal colour in a template

- **WHEN** a HEEx template contains `#ff0000`
- **THEN** the console gate fails with its file and line

### Requirement: The console has its own self-hosted typefaces

The console SHALL serve:

- Bricolage Grotesque for display: page names, headlines and large figures;
- IBM Plex Sans for interface text;
- IBM Plex Mono for identifiers and figures, with tabular numerals.

Each SHALL be a self-hosted latin woff2 with `font-display: swap`, beside its OFL
licence file, making no request to a third party. The two text faces SHALL be
preloaded. Inter, Space Grotesk and JetBrains Mono SHALL no longer be served.

#### Scenario: A page loads

- **WHEN** any console page is opened
- **THEN** the three faces load from the application's own origin, and no font
  request leaves it

#### Scenario: Retired faces

- **WHEN** `priv/static/fonts` is listed
- **THEN** it holds the three console faces and their licences, and no Inter,
  Space Grotesk or JetBrains Mono file

### Requirement: Every element comes from one component kit

Every control and display SHALL be rendered through the console's `fcon-` kit, on
every screen including the auth, settings and error pages. The stylebook's own
recipes are kept for the buttons, for tiles and the figures that fit them, for the
shell's rail and topbar with their brand, menus and chrome buttons, and for the
relay pipeline graph until its own redesign. Each element SHALL have exactly one
Phoenix function component:

- button, in primary, secondary, ghost and danger variants, at two sizes;
- text, select and textarea fields, checkbox, switch, segmented control and
  combobox;
- chip;
- state badge;
- grid (table), paged;
- the control that grows a listing by a page;
- row menu;
- section, with an optional digest;
- page header;
- tabs;
- drawer, dialog, popover and tooltip;
- toast;
- sparkline and meter;
- indicator tile, with a figure and its unit, a tone, a condition sentence, an
  optional link, room for a strip, meter or sparkline, and a foot;
- empty state;
- skeleton;
- code block;
- steps layout;
- identifier.

No screen SHALL declare its own colour, border, radius or padding for one of these
elements.

#### Scenario: A button is rendered

- **WHEN** any screen renders an action
- **THEN** it is the kit's button component in one of its declared variants

#### Scenario: An indicator is rendered

- **WHEN** Home renders a count or a condition as a tile
- **THEN** it is the kit's tile component, and `/dev/kit` shows that tile in each
  tone, with and without a link, with a unit and with a foot

#### Scenario: No stylebook skin outside its places

- **WHEN** `lib/` is searched for `flz-` classes
- **THEN** they occur only on buttons, on tiles and their figures, in the shell
  layout, in the chrome form of the brand lockup, and in the relay pipeline graph's
  rendering

### Requirement: Screens follow one page grammar

Every screen SHALL open on the kit's page header. The header SHALL carry:

- an eyebrow naming the object's kind;
- the object's name in the display face;
- one sentence stating its condition;
- its actions;
- its local tabs when it has more than one view.

Crumbs SHALL sit above the eyebrow on screens deeper than a destination. Sections
below the header SHALL be separated by space and hairlines with sentence-case
titles, not nested inside cards. A raised surface SHALL be used only for:

- a live canvas;
- a drawer;
- a dialog;
- a popover;
- a toast;
- a tile — an indicator, or an object such as a namespace, a node or a sink
  laid out in a row of tiles.

A tile SHALL take the stylebook's tile recipe: a raised surface with an
edge in its tone, a lift and an accent border on hover when it is a link, and the
focus ring on keyboard focus, with no movement when the operator prefers reduced
motion.

#### Scenario: A relay screen

- **WHEN** an operator opens a relay
- **THEN** the header shows the eyebrow "Relay", the relay id in the display face,
  a sentence about its condition, its actions, and its tabs

#### Scenario: No card in a card

- **WHEN** any screen is rendered
- **THEN** no raised surface is nested inside another raised surface

#### Scenario: Hovering a link tile

- **WHEN** the pointer rests on a tile that links somewhere
- **THEN** the tile lifts and takes the accent border and a deeper shadow

### Requirement: A screen awaiting data shows skeletons

Before its first controller read completes, a screen SHALL render skeleton
placeholders in the shape of what it will show. It SHALL NOT render an empty
table or an empty-state message that the data has not yet confirmed.

#### Scenario: The first render

- **WHEN** the relays index is rendered before its socket connects
- **THEN** skeleton rows are shown, and no "no relays" message appears

### Requirement: Focus is always visible and icons are labelled

Every interactive element SHALL show a focus ring in `--fcon-accent` on keyboard
focus in both themes. Every icon-only control SHALL carry an accessible name.
Icons SHALL be Heroicons outline at 16 or 20 pixels.

#### Scenario: Tabbing through the topbar

- **WHEN** an operator tabs through the topbar
- **THEN** each control shows the focus ring, and each icon-only control
  announces its name

### Requirement: A dev-only kit page shows every component

In the dev environment the console SHALL serve `/dev/kit`, rendering every kit
component in each of its variants and states, with a control to flip the theme.
Outside the dev environment the route SHALL NOT exist.

#### Scenario: In dev

- **WHEN** a developer opens `/dev/kit` in the dev stack
- **THEN** every component is shown in every variant and state

#### Scenario: In production

- **WHEN** the application runs without dev routes
- **THEN** `/dev/kit` answers 404

### Requirement: A figure never leaves its box

A figure in a tile or a fact SHALL shrink with its container down to a legible floor,
SHALL NOT wrap or overflow it, and SHALL carry its full value as its title when it is
cut. Counts and rates of 10 000 or more SHALL be written in compact notation
(`12.4k`, `3.1M`), with the exact value as the title. A sparkline SHALL take its
container's width rather than a fixed width. The figure-fit recipe SHALL live in the
stylebook.

#### Scenario: A large rate in a narrow tile

- **WHEN** the Flow tile shows 123 456 msgs/s at 360 px wide
- **THEN** it reads "123.5k" with the unit "msgs/s", inside the tile, and its title
  carries 123456

#### Scenario: No tile overflows

- **WHEN** any screen with tiles renders at 1280, 390 and 360 px wide
- **THEN** no element inside a tile extends past the tile's box

