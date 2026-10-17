# visual-identity Specification

## Purpose
How the console looks and identifies itself: its brand lockup and favicon, one
source of colour, status colour that states an outcome, one control vocabulary, and
the shared theme contract.
## Requirements
### Requirement: The console carries a Flezha UI brand lockup

The console SHALL identify itself with the Flezha UI lockup: the badger over the
FLEZHA name with UI beside it, `priv/static/images/flezha-ui-badger-line-text-white.svg`.
UI SHALL be set at about FLEZHA's cap height, in FLEZHA's face, centred on the
lockup's height. It SHALL be rendered as a CSS mask, so that it takes the ink of
the surface it sits on, with its aspect ratio read from the file's own `viewBox`.
The mark SHALL NOT be a fixed-colour `<img>` or a raster image. Inside the shell,
the lockup SHALL sit at the top of the rail, in the stylebook's chrome brand recipe.

#### Scenario: A screen inside the shell

- **WHEN** the rail renders its brand link in either theme
- **THEN** it shows the lockup as a mask in the chrome's ink
- **AND** the link carries an accessible name of "Flezha UI"

#### Scenario: A screen sitting on the content canvas

- **WHEN** the login, registration, confirmation or not-found screen renders its
  brand mark
- **THEN** it shows the same lockup in the brand ink, with no per-theme image swap

#### Scenario: The lockup keeps its proportions

- **WHEN** the lockup file is replaced by one with a different `viewBox`
- **THEN** the lockup takes the new proportions without a code change

#### Scenario: The product name is legible

- **WHEN** the rail renders the lockup
- **THEN** UI stands at about the cap height of FLEZHA and is not clipped by the
  `viewBox`

#### Scenario: The old marks are gone

- **WHEN** the web layer and `priv/static` are searched for `flezha-ui-purple`,
  `flezha-ui-gold`, or a brand name styled with its own font-size and font-weight
- **THEN** no occurrence remains

### Requirement: The console ships the Flezha favicon

The console SHALL serve the stylebook's adaptive badger favicon,
`assets/logo/flezha-favicon-badger-adaptive.svg`, as its SVG icon, with the
stylebook's multi-size `flezha-favicon-badger.ico` as the raster fallback copied
verbatim. It SHALL NOT ship the stock Phoenix favicon or an ICO it builds itself.

#### Scenario: A browser requests the icon

- **WHEN** any page loads
- **THEN** the document head links `/favicon.svg` as an SVG icon and `/favicon.ico` as
  the fallback, and both answer with the badger

#### Scenario: The icon follows the browser

- **WHEN** `priv/static/favicon.svg` is inspected
- **THEN** it is byte-identical to the stylebook's adaptive badger and carries a
  `prefers-color-scheme` rule

#### Scenario: The fallback is the stylebook's own file

- **WHEN** `priv/static/favicon.ico` is compared with the stylebook's
  `assets/logo/flezha-favicon-badger.ico`
- **THEN** the two are identical

### Requirement: Colour has exactly one source

Every colour the console paints SHALL resolve to a `flezha_stylebook` token. The
kit SHALL read colours through its `--fui-*` roles in
`assets/css/console/tokens.css`, each of which names the stylebook token it takes,
so the console follows the stylebook's palette and its theme switch. The token
file MAY define colours the stylebook has no token for — the signal colour for
live data, the overlay scrim and shadow, and the ink laid on a solid fill in the
dark theme — and nowhere else. `flezha_ui` SHALL NOT contain colour literals — no
hex, `rgb()`, `hsl()`, or named colour — in stylesheets, templates, Elixir modules,
JavaScript, or build configuration, outside that token file.

#### Scenario: A role names the stylebook

- **WHEN** `tokens.css` is read
- **THEN** the surface, ink, line, accent, outcome and brand roles each name a
  stylebook token, such as `--fui-ink-1: var(--text-primary)`

#### Scenario: An undefined token is introduced

- **WHEN** the console gate runs over `flezha_ui`'s `assets/` and `lib/`
- **THEN** it reports any `var()` naming a token nobody defines, and the check fails

#### Scenario: A colour literal is introduced

- **WHEN** a hex, `rgb()`, `rgba()`, `hsl()` or `hsla()` colour is added anywhere the
  console gate scans, outside the console token file
- **THEN** the gate reports it with its file and line, and the check fails

#### Scenario: The progress bar takes theme colours

- **WHEN** the page-load progress indicator renders
- **THEN** its colour comes from a `--fui-*` role and changes with the theme

### Requirement: Status colour states an outcome

Colour that reports an outcome SHALL come from the stylebook's outcome tokens,
through the roles `--fui-positive`, `--fui-warning` and `--fui-negative`. Two
other roles SHALL NOT report status:

- `--fui-accent` marks interaction: focus, the current place, links and primary
  actions;
- `--fui-signal` marks live data only: flow, rates and change marks.

Status SHALL never be conveyed by colour alone: a state is also stated in words or
by a distinct shape, which keeps a warning apart from the signal colour where the
two are close in hue. Every solid fill SHALL be painted with its matched
`--fui-on-*` ink.

#### Scenario: A relay's health is rendered

- **WHEN** the health of a relay is shown in either theme
- **THEN** healthy reads in the positive role, degraded, unbound and suspended in
  the warning role, and failed in the negative role, each also stated in words and
  by its shape

#### Scenario: A solid status fill is painted

- **WHEN** a control or badge takes a solid outcome fill
- **THEN** its text uses that fill's matched ink, so the pairing clears WCAG AA in
  both themes

#### Scenario: The gate grades the outcome colours

- **WHEN** the console gate runs
- **THEN** every outcome ink is graded against every surface in both themes, and a
  value below the floor fails the check

#### Scenario: A dropped runner is rendered

- **WHEN** a runner row is in the dropped state
- **THEN** its badge reads in the negative role, not in the accent or the signal

### Requirement: Controls share one vocabulary

Every control SHALL come from the console kit. Text inputs, selects, textareas,
the combobox and a dropdown trigger SHALL be the same box. A labelled control SHALL
use the kit's field block. A picker whose menu must be styled SHALL use the kit's
popover menu. An exclusive set of choices SHALL use the kit's segmented control,
and an on/off setting the kit's switch.

#### Scenario: Two different controls sit side by side

- **WHEN** a text input, a select and a dropdown trigger are rendered together
- **THEN** their surface, border, radius, padding, height and type match

#### Scenario: A picker is opened

- **WHEN** an operator opens a picker whose menu the console styles
- **THEN** the menu is the kit's popover, the chosen row is marked, hover takes
  the accent, and the keyboard moves through the rows and closes on Escape

#### Scenario: A field is labelled

- **WHEN** any form field in the console is rendered
- **THEN** its label, hint and error come from the kit's field block rather than
  a per-screen class

### Requirement: The console adopts the shared theme contract

The console SHALL use the Flezha theme contract exactly: attribute
`data-theme="light|dark"` on the `<html>` element, storage key `flezha-theme`, values
`light` and `dark`. With no stored choice the theme SHALL be the device's colour
scheme, dark when the device states none, and SHALL keep following the device while
the page is open. A choice that differs from the device SHALL be stored; toggling back
to the device's own scheme SHALL remove the stored choice. The attribute SHALL be set
before first paint by the stylebook's hydrate script, and the toggle SHALL be wired by
the stylebook's `bindThemeToggles`.

#### Scenario: A first-time visitor on a light device

- **WHEN** someone with no stored preference opens the console on a device that
  prefers light
- **THEN** the page renders in the light theme from the first painted frame

#### Scenario: A first-time visitor on a device with no preference

- **WHEN** someone with no stored preference opens the console on a device that
  states no colour scheme
- **THEN** the page renders in the dark theme

#### Scenario: The device switches while the console is open

- **WHEN** no choice is stored and the device's colour scheme changes
- **THEN** `data-theme` follows it without a reload

#### Scenario: A returning visitor who chose light

- **WHEN** someone with `flezha-theme=light` in storage loads any page on a dark
  device
- **THEN** the light theme is applied before first paint, with no flash of dark

#### Scenario: Toggling the theme

- **WHEN** the theme control in the account menu is activated
- **THEN** `data-theme` flips, both the chrome and the content canvas settle into the
  new theme, and the stored choice is written when it differs from the device and
  removed when it matches

#### Scenario: The theme survives live navigation

- **WHEN** the operator navigates between LiveViews after toggling
- **THEN** the chosen theme is still applied and the toggle control still works

#### Scenario: The superseded contract is gone

- **WHEN** the web layer and `assets/js/app.js` are searched for the `.light` class
  contract, the `theme` storage key, a global `toggleTheme` function, or a
  server-rendered `data-theme="dark"` default
- **THEN** no occurrence remains

### Requirement: Every screen is rendered on the shared component vocabulary

Every LiveView template, controller template and core component SHALL express
its surfaces, controls and data displays through the console kit, except the
shell's rail and topbar, which keep the stylebook's shell recipe, and the relay
pipeline graph, which keeps its current rendering until its own redesign. Tailwind utilities SHALL be limited to layout and spacing, and SHALL NOT
carry a colour, an arbitrary font size or an opacity modifier.

#### Scenario: A control is rendered

- **WHEN** a button, input, select, or textarea is rendered anywhere in the console
- **THEN** it is the kit's component and declares no colour, border, radius or
  padding of its own

#### Scenario: A data screen is rendered

- **WHEN** a screen renders a section, a grid, a figure, a state badge, a dialog,
  a drawer, a toast, an empty state, a skeleton, a meter or a payload block
- **THEN** it uses the corresponding kit component

#### Scenario: A row action is rendered

- **WHEN** a grid row offers actions such as inspect, replay, remove, drop or stop
- **THEN** they sit in the row's menu, not as text links beside each other
- **AND** a destructive action opens a confirmation whose confirm button is the
  danger variant

#### Scenario: A payload is shown

- **WHEN** a payload, schema, token, help text or dead letter is shown in a code
  block
- **THEN** long lines wrap instead of scrolling sideways

#### Scenario: Every screen survives the sweep

- **WHEN** each of the console's screens is driven in a real browser in both themes,
  at desktop and at phone width
- **THEN** every screen renders correctly, with no unstyled element, no unreadable
  text, and no control that lost its affordance

#### Scenario: Existing behaviour is untouched

- **WHEN** the ExUnit and Playwright suites run after the rebuild
- **THEN** both are green, including the topology spec that asserts on the
  `topo-flow-*` class contract

### Requirement: The chrome follows the theme

The sidebar and topbar SHALL take the stylebook's chrome in each theme: the pale
chrome in light and the deep plum chrome in dark, with the chrome's own ink, and the
topbar painted with the chrome band. The accent SHALL mark hover and the current
navigation destination. The console SHALL NOT set a chrome colour of its own.

#### Scenario: Switching to the light theme

- **WHEN** the operator switches to light
- **THEN** the sidebar and topbar take the pale chrome and dark ink, together with
  the canvas

#### Scenario: Switching to the dark theme

- **WHEN** the operator switches to dark
- **THEN** the sidebar and topbar take the deep plum chrome and light ink

#### Scenario: The active navigation item

- **WHEN** a navigation destination is the current page
- **THEN** that link is marked `aria-current` and rendered in the accent, plum in
  light and gold in dark

#### Scenario: Chrome controls stay legible

- **WHEN** a chrome icon button, the namespace picker or the account menu is hovered
  or opened in either theme
- **THEN** its ink and hover fill come from chrome tokens and clear the gate's
  contrast floor

### Requirement: The login and not-found screens show the mascot

The login screen and the not-found page SHALL show a honey-badger pose from the
stylebook, served as WebP from the application's static tree. The image SHALL be
decorative, with an empty `alt`. No data screen SHALL show a mascot.

#### Scenario: The login screen

- **WHEN** the login page renders
- **THEN** it shows the laptop pose beside the form, and hides it at phone width

#### Scenario: An unknown route

- **WHEN** an operator requests a path the router does not know
- **THEN** a 404 page on the auth layout shows the badger lockup, the not-found pose,
  a short message and a link back to the dashboard

#### Scenario: A data screen

- **WHEN** a data screen, including one with an empty listing, is rendered
- **THEN** it shows no mascot

### Requirement: Flash messages never cover the topbar

Inside the console shell, messages SHALL be shown as toasts stacked at the bottom
right of the viewport, below the topbar's layer, so they never cover the topbar's
controls. An informational toast SHALL dismiss itself after five seconds. An error
toast SHALL stay until it is dismissed. Every toast SHALL be dismissible from the
keyboard and SHALL be announced to assistive technology.

#### Scenario: A flash after logging in

- **WHEN** a message is shown on a screen inside the shell
- **THEN** it appears as a toast at the bottom right, and the account menu stays
  reachable without dismissing it

#### Scenario: An error message

- **WHEN** an error toast is shown
- **THEN** it stays until the operator dismisses it

#### Scenario: An informational message

- **WHEN** an informational toast is shown
- **THEN** it dismisses itself after five seconds

### Requirement: Only the rail is chrome

Inside the shell, only the rail SHALL wear the chrome colour. The topbar SHALL belong
to the page beside it: it SHALL be painted the stylebook's `--surface-sheet`, like the
content canvas, and set apart from the canvas by a hairline in the default border, so
that the rail and topbar do not join into a frame around the content. The canvas
SHALL carry no border, radius or shadow of its own, and SHALL be the only part of the
shell that scrolls. The current rail destination SHALL be marked by an accent left
bar, a faint accent wash and bold type, and SHALL keep its left-edge marker under
forced colours. These rules SHALL live in the stylebook's shell recipe, not in a
console override. How the shell folds below desk width is owned by the
small-screen layout.

#### Scenario: A screen inside the shell

- **WHEN** any screen inside the shell renders at desk width in either theme
- **THEN** the rail is chrome, the topbar and the content share the page surface
  divided by a hairline, and the content has no border, radius or shadow

#### Scenario: Scrolling a long screen

- **WHEN** an operator scrolls a long screen
- **THEN** only the content moves, and the rail and topbar stay in place

#### Scenario: Forced colours

- **WHEN** the operating system forces colours
- **THEN** the current rail destination is still marked by its left edge

#### Scenario: The recipe has one home

- **WHEN** the console's stylesheets are searched for rules on `flz-canvas`,
  `flz-sidebar` or `flz-topbar`
- **THEN** none are found; the shell comes from the stylebook's `components.css`

