# design-system-consumption Specification

## Purpose
TBD - created by archiving change restyle-on-flezha-stylebook. Update Purpose after archive.
## Requirements
### Requirement: The stylebook is a declared dependency, not a copy

`flezha_ui` SHALL depend on `flezha-stylebook` as an npm `file:` dependency
declared in `assets/package.json`, and SHALL reference its CSS, JavaScript, fonts,
and SVG assets through the package name. `flezha_ui` SHALL NOT keep a checked-in
copy of the stylebook's stylesheets, behaviours, or logo kit.

#### Scenario: A stylesheet or behaviour is referenced

- **WHEN** `assets/css/app.css` or `assets/js/app.js` pulls in stylebook code
- **THEN** it does so by package specifier, resolved through `assets/node_modules`

#### Scenario: The stylebook changes upstream

- **WHEN** a token or component recipe is edited in `flezha-stylebook`
- **THEN** the next asset build in `flezha_ui` picks the change up with no copy step

#### Scenario: No duplicate stylebook lives in the repo

- **WHEN** the repository is searched for vendored stylebook CSS, JS, or logo SVGs
  outside the generated static tree
- **THEN** no copy exists

### Requirement: The three CSS layers are imported in a defined order

`app.css` SHALL import the stylebook's `tokens.css`, `base.css`, and
`components.css` in that order, placed after Tailwind's base layer and before
Tailwind's components and utilities layers, so that the stylebook's reset and form
baseline win over Tailwind preflight while Tailwind utilities still win over
stylebook component recipes.

#### Scenario: A component class is combined with a utility

- **WHEN** an element carries both a `.flz-*` component class and a Tailwind
  spacing or layout utility
- **THEN** the utility takes effect and the component skin is otherwise preserved

#### Scenario: A bordered element is rendered

- **WHEN** an element uses a Tailwind `border` utility
- **THEN** the border is visible, because Tailwind preflight is still enabled

#### Scenario: A form element is rendered

- **WHEN** a text input, select, or textarea is rendered with no extra classes
- **THEN** it already has the stylebook's surface, border, radius, padding, and
  focus ring

### Requirement: The console's typefaces are self-hosted and served

The application SHALL serve the three self-hosted woff2 faces the stylebook
ships — Space Grotesk for display, Inter for body, JetBrains Mono for code and
data — and the stylebook's `@font-face` rules SHALL resolve against them with no
network request to a third party.

#### Scenario: A page loads

- **WHEN** any console page is opened
- **THEN** all three faces load successfully from the application's own origin

#### Scenario: A build produces the static tree

- **WHEN** the asset build runs
- **THEN** the woff2 faces and the stylebook's brand SVGs are placed in the
  application's static tree from the resolved package, not hand-copied

### Requirement: The token contract is gated in this repository

`flezha_ui` SHALL run the stylebook's token gate over its own source as part of
its checks. The gate SHALL fail on a `var()` naming a token nobody defines, on a
token defined but never referenced, and on any ink/surface pairing below its WCAG
AA floor in either theme.

#### Scenario: A developer references a token that does not exist

- **WHEN** a template or stylesheet uses `var(--not-a-token)`
- **THEN** the gate reports it and fails

#### Scenario: The gate is discoverable

- **WHEN** a developer looks up how to check their work in `README.md`
- **THEN** the command to run the token gate is documented alongside the test
  commands

### Requirement: Shared components are contributed upstream

A component that another Flezha surface could reasonably reuse SHALL be added to
`flezha-stylebook`'s component recipes, not to `flezha_ui`'s local stylesheet —
application shell, sidebar, topbar, panel, table, stat tile, badge, modal, toast,
code block, empty state. Component recipes SHALL be built from tokens that already
exist wherever the existing palette can carry them.

#### Scenario: The console needs an application shell

- **WHEN** the sidebar-and-topbar shell and the data-dense recipes are written
- **THEN** they live in `flezha-stylebook/css/components.css`, are documented in
  its README, and `flezha_ui` merely applies the classes

#### Scenario: A new recipe is added upstream

- **WHEN** the stylebook's own quality gate runs after the app layer is added
- **THEN** it passes: no undefined token, no dead token, and every pairing clears
  WCAG AA in both themes

#### Scenario: Genuinely app-specific styling

- **WHEN** styling exists that no other Flezha surface would use, such as the
  topology graph's edge and node classes
- **THEN** it stays in `flezha_ui` and consumes stylebook tokens for its colours

#### Scenario: The stylebook records its consumers

- **WHEN** `flezha-stylebook/README.md` is read after this change
- **THEN** `flezha_ui` is listed as a live consumer rather than a planned one, and
  the new assets and app-layer classes appear in its contents table

