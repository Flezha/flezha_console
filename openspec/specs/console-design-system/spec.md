# console-design-system Specification

## Purpose
The console's own design layer: role-named tokens and their contrast and use gates, self-hosted typefaces, the single component kit, the page grammar, loading skeletons, visible focus, and the dev-only kit page.
## Requirements
### Requirement: The console names its design tokens by role

The console SHALL define every colour, spacing, radius, elevation, motion and type
value its kit uses as a `--fui-*` custom property in
`assets/css/console/tokens.css`. The scales — type, space, radius, control height,
drawer width, motion and layering — are the console's own. Each colour role SHALL
alias a `flezha_stylebook` token, so the console takes the stylebook's palette in
both themes and follows its theme switch:

| Role | Stylebook token |
| --- | --- |
| `--fui-page` | `--surface-base` |
| `--fui-canvas` | `--surface-sheet` |
| `--fui-surface`, `--fui-raised` | `--surface-raised` |
| `--fui-hover` | `--surface-hover` |
| `--fui-line` | `--border-default` |
| `--fui-line-strong` | `--field-border` |
| `--fui-ink-1`, `-2`, `-3` | `--text-primary`, `--text-secondary`, `--text-muted` |
| `--fui-accent`, `--fui-brand` | `--text-brand` |
| `--fui-on-accent` | `--text-on-brand`; `--text-on-gold` in the dark theme |
| `--fui-positive`, `--fui-warning`, `--fui-negative` | `--positive`, `--warning`, `--negative` |
| `--fui-on-positive`, `-warning`, `-negative` | `--text-on-positive`, `--text-on-warning`, `--text-on-negative` |

Each fill role SHALL have a `-subtle` variant, mixed from that role and
`--fui-surface`. The console SHALL add only what the stylebook has no token for:

- `--fui-signal`, for live data only, and its `--fui-on-signal` ink — the
  stylebook's `--gold` in the dark theme;
- the overlay scrim and the overlay shadow.

#### Scenario: A role follows the stylebook

- **WHEN** the stylebook changes the value of `--text-primary`
- **THEN** the console's primary ink changes with it, with no edit to the console

#### Scenario: Both themes are defined

- **WHEN** the dark theme is applied
- **THEN** every `--fui-*` colour role resolves, either through the stylebook's own
  dark value or through the console's dark override

#### Scenario: Signal is not a status

- **WHEN** a relay's flow, a rate or a change mark is painted
- **THEN** it uses `--fui-signal`, and no outcome badge uses `--fui-signal`

### Requirement: The console's tokens are gated for contrast and use

The console SHALL run the stylebook's token gate with a console config over
`assets/` and `lib/`. The config names the console token file, the pairs to grade,
and the stylebook token file as its base, whose palettes resolve the roles that
alias it. The gate SHALL fail on:

- a `var(--fui-*)` that no file defines;
- a `--fui-*` token that nothing references;
- an ink-on-surface pairing below 4.5:1, or a solid fill and its matched ink below
  4.5:1, in either theme;
- a colour literal outside a token file.

The gate script SHALL take the config, and the base within it, as options, and
behave exactly as before without them.

#### Scenario: A low-contrast token

- **WHEN** `--fui-ink-3` is set so that it reaches 4.2:1 on `--fui-raised` in the
  light theme
- **THEN** the console gate fails, naming the pair and the theme

#### Scenario: An aliased role is graded

- **WHEN** the console gate grades `--fui-ink-3` on `--fui-raised`
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

Every control and display SHALL be rendered through the console's `fui-` kit, on
every screen including the auth, settings and error pages. Two parts keep the
stylebook's recipes: the shell's rail and topbar, with their brand, menus and
chrome buttons, and the relay pipeline graph until its own redesign. Each element SHALL have
exactly one Phoenix function component:

- button, in primary, secondary, ghost and danger variants, at two sizes;
- text, select and textarea fields, checkbox, switch, segmented control and
  combobox;
- chip;
- state badge;
- grid (table);
- row menu;
- section, with an optional digest;
- page header;
- tabs;
- drawer, dialog, popover and tooltip;
- toast;
- sparkline and meter;
- indicator tile, with a figure, a tone, a condition sentence, an optional link
  and room for a strip, meter or sparkline;
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
  tone and with and without a link

#### Scenario: No stylebook skin outside the shell and the relay graph

- **WHEN** `lib/` is searched for `flz-` classes
- **THEN** they occur only in the shell layout, the chrome form of the brand
  lockup, and the relay pipeline graph's rendering

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
- a toast.

#### Scenario: A relay screen

- **WHEN** an operator opens a relay
- **THEN** the header shows the eyebrow "Relay", the relay id in the display face,
  a sentence about its condition, its actions, and its tabs

#### Scenario: No card in a card

- **WHEN** any screen is rendered
- **THEN** no raised surface is nested inside another raised surface

### Requirement: A screen awaiting data shows skeletons

Before its first controller read completes, a screen SHALL render skeleton
placeholders in the shape of what it will show. It SHALL NOT render an empty
table or an empty-state message that the data has not yet confirmed.

#### Scenario: The first render

- **WHEN** the relays index is rendered before its socket connects
- **THEN** skeleton rows are shown, and no "no relays" message appears

### Requirement: Focus is always visible and icons are labelled

Every interactive element SHALL show a focus ring in `--fui-accent` on keyboard
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

