# visual-identity Specification

## Purpose
TBD - created by archiving change restyle-on-flezha-stylebook. Update Purpose after archive.
## Requirements
### Requirement: The console carries a Flezha UI brand lockup

The console SHALL identify itself with a `flezha-ui` lockup built on the same
construction as the `flezha-market` lockups: the F mark and the FLEZHA wordmark on
the left with a letterspaced `UI` sub-wordmark beneath, a hairline vertical rule,
and a pipeline node-graph mark on the right. The lockup SHALL be a true-vector SVG
shipped by `flezha-stylebook`, not text styled to look like a wordmark and not a
raster image.

The lockup SHALL exist in the same variant matrix as the other Flezha lockups:
`flezha-ui-{purple,gold}[-mono]-on-{dark,light}.svg`.

#### Scenario: A screen sitting on brand chrome

- **WHEN** the sidebar renders its brand link
- **THEN** it shows the single-colour `flezha-ui` mono lockup, whose flat fill does
  not clash with the plum chrome behind it
- **AND** the link carries an accessible name of "Flezha UI"

#### Scenario: A screen sitting on the content canvas

- **WHEN** the login, registration, or confirmation screen renders its brand mark
- **THEN** it shows the gradient `flezha-ui` lockup matched to the active theme

#### Scenario: The old text wordmark is gone

- **WHEN** the web layer is searched for a hand-set `flezha` wordmark styled with
  font-size and font-weight
- **THEN** no occurrence remains

#### Scenario: The lockup reads as a sibling of the market lockup

- **WHEN** `flezha-ui-purple-on-dark.svg` and `flezha-market-purple-on-dark.svg`
  are placed side by side
- **THEN** the F mark, wordmark, sub-wordmark baseline, and divider rule occupy the
  same relative geometry, and only the right-hand pictogram differs

### Requirement: The console ships the Flezha favicon

The console SHALL serve the Flezha group favicon — the rounded-square gradient F
mark from `flezha-stylebook` — as an SVG icon with a raster fallback, and SHALL NOT
ship the stock Phoenix favicon.

#### Scenario: A browser requests the icon

- **WHEN** any page loads
- **THEN** the document head links an SVG favicon and a raster fallback, both
  resolving to the Flezha mark

#### Scenario: The Phoenix default is gone

- **WHEN** `priv/static/favicon.ico` is inspected
- **THEN** it is the Flezha mark, not the framework default

### Requirement: Colour has exactly one source

Every colour the console paints SHALL resolve to a `flezha-stylebook` token.
`flezha_ui` SHALL NOT define its own colour tokens and SHALL NOT contain colour
literals — no hex, `rgb()`, `hsl()`, or named colour — in stylesheets, templates,
Elixir modules, JavaScript, or build configuration.

#### Scenario: The private palette is removed

- **WHEN** `assets/css/app.css` is inspected
- **THEN** the `--color-*` declarations and the `.light` palette block no longer
  exist, and no rule declares a colour literal

#### Scenario: A colour literal is introduced

- **WHEN** the token gate runs over `flezha_ui`'s `assets/` and `lib/`
- **THEN** it reports any `var()` naming a token nobody defines, and the check fails

#### Scenario: The progress bar and topology graph take theme colours

- **WHEN** the topbar progress indicator or the topology graph renders
- **THEN** its colours come from stylebook tokens and change with the theme

### Requirement: Status colour states an outcome

Colour that reports an outcome SHALL come from the semantic tokens — green for
a healthy result, amber for one needing attention, red for a failure — and
SHALL NOT reuse a brand colour. The gold accent marks interaction and the
magenta brand colour is a fill; neither reports status. Every solid fill SHALL
be painted with its matched foreground token.

#### Scenario: An operative's health is rendered

- **WHEN** the health of an operative is shown in either theme
- **THEN** healthy reads green, degraded and unbound read amber, and failed
  reads red, each from its semantic token

#### Scenario: A solid status fill is painted

- **WHEN** a control or badge takes a solid semantic fill
- **THEN** its text uses that fill's matched foreground token, so the pairing
  clears WCAG AA in both themes

#### Scenario: The token gate grades the semantic colours

- **WHEN** the design-token gate runs
- **THEN** every semantic ink is graded against every surface in both themes,
  and a value that falls below the floor fails the check

### Requirement: Controls share one vocabulary

Every control SHALL take its skin from `flezha-stylebook`. Text inputs,
selects, textareas and a dropdown trigger SHALL be the same box; a labelled
control SHALL use the shared field block; a picker whose menu must be styled
SHALL use the shared dropdown, and an exclusive set of choices the shared
segmented control.

#### Scenario: Two different controls sit side by side

- **WHEN** a text input, a select and a dropdown trigger are rendered together
- **THEN** their surface, border, radius, padding, height and type match

#### Scenario: A picker is opened

- **WHEN** an operator opens a picker whose menu the console styles
- **THEN** the menu is the stylebook's panel, the chosen row is marked and
  filled with the brand pair, hover takes the accent pair, and the keyboard
  moves through the rows and closes on Escape

#### Scenario: A field is labelled

- **WHEN** any form field in the console is rendered
- **THEN** its label, hint and error come from the shared field block rather
  than a per-screen class

### Requirement: The console adopts the shared theme contract

The console SHALL use the Flezha theme contract exactly: attribute
`data-theme="light|dark"` on the `<html>` element, storage key `flezha-theme`,
values `light` and `dark`, dark by default, with no `prefers-color-scheme`
fallback. The attribute SHALL be set before first paint.

#### Scenario: A first-time visitor

- **WHEN** someone opens the console with no stored preference
- **THEN** the page renders in the dark theme from the first painted frame

#### Scenario: A returning visitor who chose light

- **WHEN** someone with `flezha-theme=light` in storage loads any page
- **THEN** the light theme is applied before first paint, with no flash of dark

#### Scenario: Toggling the theme

- **WHEN** the theme control in the topbar is activated
- **THEN** `data-theme` flips, the choice is written to `flezha-theme`, and both
  the chrome and the content canvas settle into the new theme

#### Scenario: The theme survives live navigation

- **WHEN** the operator navigates between LiveViews after toggling
- **THEN** the chosen theme is still applied and the toggle control still works

#### Scenario: The superseded contract is gone

- **WHEN** the web layer and `assets/js/app.js` are searched for the `.light`
  class contract, the `theme` storage key, or a global `toggleTheme` function
- **THEN** no occurrence remains

### Requirement: Chrome is theme-invariant, content is not

The sidebar and topbar SHALL stay deep plum in both themes, with gold marking
hover and the active navigation item. Only the content canvas SHALL flip with the
theme.

#### Scenario: Switching to the light theme

- **WHEN** the operator switches to light
- **THEN** the sidebar and topbar keep their plum surface and their light-on-plum
  ink, while panels, tables, and page background flip to the light canvas

#### Scenario: The active navigation item

- **WHEN** a navigation destination is the current page
- **THEN** that link is marked `aria-current` and is rendered in gold, in both
  themes

### Requirement: Every screen is rendered on the shared component vocabulary

Every LiveView template, controller template, layout, and core component SHALL
express its surfaces, controls, and data displays through `flezha-stylebook`
component classes rather than locally invented ones. Tailwind utilities SHALL be
limited to layout and spacing.

#### Scenario: A control is rendered

- **WHEN** a button, input, select, or textarea is rendered anywhere in the console
- **THEN** it takes its skin from the stylebook — the `.flz-button` recipes and the
  shared form baseline — and declares no colour, border, radius, or padding of its
  own

#### Scenario: A data screen is rendered

- **WHEN** a screen renders a panel, a table, a stat tile, a status badge, a modal,
  a flash message, an empty state, or a payload block
- **THEN** it uses the corresponding stylebook app-layer class

#### Scenario: Every screen survives the sweep

- **WHEN** each of the console's screens is driven in a real browser in both themes
- **THEN** every screen renders correctly, with no unstyled element, no unreadable
  text, and no control that lost its affordance

#### Scenario: Existing behaviour is untouched

- **WHEN** the ExUnit and Playwright suites run after the sweep
- **THEN** both are green, including the topology spec that asserts on the
  `topo-flow-*` class contract

