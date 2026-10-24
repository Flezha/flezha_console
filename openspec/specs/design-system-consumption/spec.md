# design-system-consumption Specification

## Purpose
How the console takes its look from `flezha_stylebook`: the stylebook is a declared
npm dependency rather than a copy, its token contract is gated in this repository,
and components another Flezha surface could reuse are contributed upstream.
## Requirements
### Requirement: The stylebook is a declared dependency, not a copy

`flezha_console` SHALL depend on the `flezha_stylebook` repository, published as the
package `@flezha/stylebook`, as an npm `file:` dependency declared in
`assets/package.json` as `file:../../flezha_stylebook`. From it the console SHALL
take only:

- the palette: its `tokens.css`, which every console colour role aliases;
- the shell's recipes: the rail, the topbar, its menus and chrome buttons;
- the brand lockup, favicon and mascots;
- the theme contract's hydrate and toggle scripts;
- the token gate script;
- until the relay graph's own redesign, the recipes that graph uses.

It SHALL reference each through the package name. `flezha_console` SHALL NOT keep a
checked-in copy of the stylebook's stylesheets, behaviours, scripts or logo kit.

#### Scenario: A stylebook script is referenced

- **WHEN** `assets/js/app.js` pulls in the theme scripts
- **THEN** it does so by package specifier, resolved through `assets/node_modules`

#### Scenario: The package resolves to the sibling checkout

- **WHEN** the asset dependencies are installed with `flezha_stylebook` checked out beside `flezha_console`
- **THEN** `assets/node_modules/@flezha/stylebook` resolves to that checkout and is not a dangling link

#### Scenario: Only the declared parts are taken

- **WHEN** `assets/css/app.css` and `assets/js/app.js` are inspected
- **THEN** they import the stylebook's theme scripts, its tokens and its
  component recipes, and do not import its `base.css`, its dropdown or its tabs
  behaviour

#### Scenario: No duplicate stylebook lives in the repo

- **WHEN** the repository is searched for vendored stylebook CSS, JS, or logo SVGs
  outside the generated static tree
- **THEN** no copy exists

### Requirement: The three CSS layers are imported in a defined order

`app.css` SHALL import, in this order:

1. Tailwind's base layer;
2. the console's `assets/css/console/tokens.css`, `base.css` and
   `components.css`;
3. the stylebook's `tokens.css` and `components.css`, for the palette, the shell
   and the relay graph;
4. Tailwind's components and utilities layers.

This order lets the console's reset and form baseline win over Tailwind
preflight, while Tailwind utilities still win over component recipes.

#### Scenario: A kit class is combined with a utility

- **WHEN** an element carries both an `fcon-` component class and a Tailwind
  spacing or layout utility
- **THEN** the utility takes effect and the component skin is otherwise preserved

#### Scenario: A bordered element is rendered

- **WHEN** an element uses a Tailwind `border` utility
- **THEN** the border is visible, because Tailwind preflight is still enabled

#### Scenario: A form element is rendered

- **WHEN** a text input, select, or textarea is rendered with no extra classes
- **THEN** it already has the console's surface, border, radius, padding and
  focus ring

### Requirement: The console's typefaces are self-hosted and served

The application SHALL serve the console's three self-hosted woff2 faces —
Bricolage Grotesque for display, IBM Plex Sans for interface text and IBM Plex
Mono for identifiers and figures — with their OFL licence files beside them, from
its own origin, with no network request to a third party. The stylebook asset step
SHALL place only the brand lockup, adaptive favicon, ICO and the two mascot WebP
poses, copied from the resolved package. It SHALL place no stylebook typeface.

#### Scenario: A page loads

- **WHEN** any console page is opened
- **THEN** all three faces load successfully from the application's own origin

#### Scenario: A build produces the static tree

- **WHEN** the asset step runs
- **THEN** `images/flezha-console-badger-line-text-white.svg`, `favicon.svg`,
  `favicon.ico`, `images/badger-laptop.webp` and `images/badger-not-found.png` are
  placed in the static tree from the resolved package, and no Inter, Space
  Grotesk or JetBrains Mono face is

#### Scenario: A retired asset is not left behind

- **WHEN** `priv/static/images` is listed after the asset build
- **THEN** it holds no F-mark lockup other than the current Flezha Console lockup

### Requirement: The token contract is gated in this repository

`flezha_console` SHALL run the stylebook's token gate as part of its checks, invoking
the gate script through the installed `@flezha/stylebook` package, twice:

- with the console's config, grading the `--fcon-*` tokens in
  `assets/css/console/tokens.css`, resolved through the stylebook's palette;
- with the graph's config, grading the stylebook tokens the relay graph still uses
  and ignoring `--fcon-*` names.

Each run SHALL fail on:

- a `var()` naming a token nobody defines;
- a token defined but never referenced;
- any ink/surface or fill/ink pairing below its WCAG AA floor in either theme;
- a colour literal outside a token file.

Third-party code in a `vendor/` directory SHALL NOT be scanned.

#### Scenario: A developer references a token that does not exist

- **WHEN** a template or stylesheet uses `var(--fcon-not-a-token)`
- **THEN** the gate reports it and fails

#### Scenario: A developer writes a colour literal

- **WHEN** a template, stylesheet or script in `assets/` or `lib/` contains a hex,
  `rgb()` or `hsl()` colour outside a token file
- **THEN** the gate reports its file and line and fails

#### Scenario: Vendored code is skipped

- **WHEN** the gate runs over `assets/`
- **THEN** `assets/vendor/topbar.js` is not scanned

#### Scenario: The gate runs from a clean checkout

- **WHEN** a developer installs the asset dependencies with `flezha_stylebook` beside the project and runs `npm run tokens`
- **THEN** both gate runs are found through the installed package and report their result

#### Scenario: The gate is discoverable

- **WHEN** a developer looks up how to check their work in `README.md`
- **THEN** the command to run the token gate is documented alongside the test
  commands

