# visual-identity Specification

## Purpose
How the console looks and identifies itself: its brand lockup and favicon, one
source of colour, status colour that states an outcome, one control vocabulary, and
the shared theme contract.
## Requirements
### Requirement: The console carries a Flezha UI brand lockup

The console SHALL identify itself with the badger lockup: the stylebook's
single-fill white honey-badger mark, `assets/logo/flezha-badger-white.svg`, rendered as
a mask through the `.flz-logo` recipe so it takes the ink of the surface it sits on,
beside the name "Flezha UI" set in the stylebook's `.flz-brand-name`, the two held
together by `.flz-brand`. The mark SHALL NOT be a fixed-colour `<img>` or a raster
image, and the name SHALL take its type only from `.flz-brand-name`. The F-mark
`flezha-ui-*` lockups SHALL NOT be referenced.

#### Scenario: A screen sitting on the chrome

- **WHEN** the sidebar renders its brand link in either theme
- **THEN** it shows the badger mark as a `.flz-logo` mask and the "Flezha UI" name,
  both in the chrome's ink, so they read on the pale light chrome and on the deep plum
  dark chrome
- **AND** the link carries an accessible name of "Flezha UI"

#### Scenario: A screen sitting on the content canvas

- **WHEN** the login, registration, confirmation or not-found screen renders its
  brand mark
- **THEN** it shows the same lockup in the brand ink `--text-brand`, with no
  per-theme image swap

#### Scenario: The old marks are gone

- **WHEN** the web layer and `priv/static` are searched for `flezha-ui-purple`,
  `flezha-ui-gold`, or a brand name styled with its own font-size and font-weight
  instead of `.flz-brand-name`
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

Every colour the console paints SHALL resolve to a `flezha_stylebook` token.
`flezha_ui` SHALL NOT define its own colour tokens and SHALL NOT contain colour
literals — no hex, `rgb()`, `hsl()`, or named colour — in stylesheets, templates,
Elixir modules, JavaScript, or build configuration.

#### Scenario: The private palette is removed

- **WHEN** `assets/css/app.css` is inspected
- **THEN** the `--color-*` declarations and the `.light` palette block no longer
  exist, and no rule declares a colour literal

#### Scenario: An undefined token is introduced

- **WHEN** the token gate runs over `flezha_ui`'s `assets/` and `lib/`
- **THEN** it reports any `var()` naming a token nobody defines, and the check fails

#### Scenario: A colour literal is introduced

- **WHEN** a hex, `rgb()`, `rgba()`, `hsl()` or `hsla()` colour is added anywhere the
  token gate scans in `flezha_ui`
- **THEN** the gate reports it with its file and line, and the check fails

#### Scenario: The progress bar and topology graph take theme colours

- **WHEN** the topbar progress indicator or the topology graph renders
- **THEN** its colours come from stylebook tokens and change with the theme

### Requirement: Status colour states an outcome

Colour that reports an outcome SHALL come from the semantic tokens — green for
a healthy result, amber for one needing attention, red for a failure — and
SHALL NOT reuse a brand colour. The accent, plum in light and gold in dark, marks
interaction, and the magenta brand colour is a fill; neither reports status. Every
solid fill SHALL be painted with its matched foreground token.

#### Scenario: A relay's health is rendered

- **WHEN** the health of a relay is shown in either theme
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

#### Scenario: A dropped runner is rendered

- **WHEN** a runner row is in the dropped state
- **THEN** its badge reads in the negative semantic colour, not in the accent

### Requirement: Controls share one vocabulary

Every control SHALL take its skin from `flezha_stylebook`. Text inputs,
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

Every LiveView template, controller template, layout, and core component SHALL
express its surfaces, controls, and data displays through `flezha_stylebook`
component classes rather than locally invented ones. Tailwind utilities SHALL be
limited to layout and spacing, and SHALL NOT carry an arbitrary font size or an
opacity modifier on a token alias.

#### Scenario: A control is rendered

- **WHEN** a button, input, select, or textarea is rendered anywhere in the console
- **THEN** it takes its skin from the stylebook — the `.flz-button` recipes and the
  shared form baseline — and declares no colour, border, radius, or padding of its
  own

#### Scenario: A data screen is rendered

- **WHEN** a screen renders a panel, a table, a stat tile, a status badge, a modal,
  a flash message, an empty state, a meter, or a payload block
- **THEN** it uses the corresponding stylebook app-layer class

#### Scenario: A row action is rendered

- **WHEN** a table row offers an action such as inspect, replay, remove, drop or stop
- **THEN** it is a small ghost `.flz-button`, not a text link
- **AND** a destructive action opens a confirmation whose confirm button is the solid
  danger fill

#### Scenario: A payload is shown

- **WHEN** a payload, schema, token, help text or dead letter is shown in a code block
- **THEN** the block carries `.flz-code--wrap` and long lines wrap instead of
  scrolling sideways

#### Scenario: Dead and arbitrary utilities are gone

- **WHEN** `lib/` is searched for a colour utility with an opacity modifier on a
  token alias, or for a `text-[…px]` size
- **THEN** no occurrence remains

#### Scenario: Every screen survives the sweep

- **WHEN** each of the console's screens is driven in a real browser in both themes,
  at desktop and at phone width
- **THEN** every screen renders correctly, with no unstyled element, no unreadable
  text, and no control that lost its affordance

#### Scenario: Existing behaviour is untouched

- **WHEN** the ExUnit and Playwright suites run after the sweep
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

Inside the console shell, flash messages SHALL float below the topbar, so a message never covers the controls at the topbar's right end, such as the account menu.

#### Scenario: A flash after logging in

- **WHEN** a flash is shown on a screen inside the shell
- **THEN** the account menu stays reachable without dismissing it

