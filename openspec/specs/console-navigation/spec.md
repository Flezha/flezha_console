# console-navigation Specification

## Purpose
The console's information architecture: how an operator reaches a screen,
what tells them where they are, and what a screen says about its own
currency.
## Requirements
### Requirement: The sidebar separates namespace-scoped from platform-global

The navigation rail SHALL present two labelled sections. A `NAMESPACE` section
SHALL hold Home, Relays, Factories, Plugins and Schedules for the namespace in scope. A
`PLATFORM` section SHALL hold Problems, Fleet, Namespaces, Cluster, Controller,
Observability, Dead-letter and Logs. Fleet is the listing of every reachable relay
at `/relays`, and Logs leads to `/logs`. A screen SHALL appear in the `NAMESPACE` section
only when the controller call behind it accepts a namespace, or when the rows it
returns each carry one. With no namespace in scope the `NAMESPACE` section SHALL
say so rather than offer destinations it has no scope to point at. The rail and
the topbar SHALL keep the stylebook's shell recipe.

#### Scenario: The sections are labelled

- **WHEN** an operator looks at the sidebar
- **THEN** the two groups are separated and each carries a visible heading

#### Scenario: The namespace's Home

- **WHEN** a namespace is in scope
- **THEN** the `NAMESPACE` section's first entry is Home, at `/namespaces/:ns`

#### Scenario: The scoped relay entry

- **WHEN** a namespace is in scope
- **THEN** the `NAMESPACE` section's Relays entry points at `/namespaces/:ns/relays`
- **AND** the `PLATFORM` section's Fleet entry points at `/relays`

#### Scenario: No namespace is in scope

- **WHEN** an operator is on a platform screen whose namespace was never chosen
- **THEN** the `NAMESPACE` section carries its heading and states that no
  namespace is in scope, offering a way to pick one

#### Scenario: Dead-letter and observability are not presented as scoped

- **WHEN** the sidebar is rendered
- **THEN** Dead-letter and Observability sit in the `PLATFORM` section
- **AND** no route offers a namespace-scoped form of either

#### Scenario: The current destination is marked

- **WHEN** an operator is on a screen reachable from the sidebar
- **THEN** that entry carries `aria-current="page"`
- **AND** exactly one entry carries it

#### Scenario: The scoped factories entry

- **WHEN** a namespace is in scope
- **THEN** the `NAMESPACE` section's Factories entry, after Relays, points at `/namespaces/:ns/factories`
- **AND** it carries `aria-current="page"` on that listing and on every factory page below it

#### Scenario: Logs replaces the audit entry

- **WHEN** the sidebar is rendered
- **THEN** it offers a Logs entry leading to `/logs` and no Audit entry
- **AND** the Logs entry carries `aria-current="page"` on every `/logs/:kind` screen

#### Scenario: The dashboard entry is gone

- **WHEN** the sidebar is rendered
- **THEN** it offers no Dashboard entry

### Requirement: A namespace scope is carried in the route

Namespace-scoped screens SHALL take their namespace from a path segment, not from
session or socket state, so that the address bar always names the scope on
display.

#### Scenario: The scope is in the address bar

- **WHEN** an operator opens a namespace's relays
- **THEN** the URL is `/namespaces/:ns/relays`

#### Scenario: A shared link opens the same scope

- **WHEN** an operator copies the URL of a scoped screen and another operator opens it
- **THEN** the second operator sees the same namespace scoped, without depending on
  what either of them looked at previously

#### Scenario: A scoped screen states its scope as fixed

- **WHEN** a scoped screen renders its namespace
- **THEN** the namespace is presented as the screen's scope rather than as a
  clearable filter control

### Requirement: The namespace picker means one thing everywhere

The topbar SHALL offer one namespace picker. Choosing a namespace SHALL navigate
as follows:

- from a namespace-scoped screen, to the same screen kind under the chosen
  namespace;
- from one relay, to the chosen namespace's relays;
- from a platform screen or from an all-namespaces listing, to the chosen
  namespace's Home.

On a platform screen the picker and the rail SHALL show the namespace the operator
last worked in.

#### Scenario: Switching scope keeps the screen

- **WHEN** an operator viewing one namespace's relays picks another namespace
- **THEN** they land on the second namespace's relays, not on a list

#### Scenario: Switching scope from one relay

- **WHEN** an operator viewing one relay picks another namespace
- **THEN** they land on the second namespace's relays, because the relay id means nothing there

#### Scenario: Switching scope from a platform screen

- **WHEN** an operator on Cluster picks a namespace
- **THEN** they land on that namespace's Home

#### Scenario: The picker offers only reachable namespaces

- **WHEN** the bound flezha token is scoped to one namespace
- **THEN** the picker offers only namespaces `scoped_namespaces/1` returns

### Requirement: Every screen below the top level shows a crumb trail

A screen deeper than a rail destination SHALL render a crumb trail in its page
header, above the eyebrow. The trail SHALL name each ancestor in words, with every
ancestor but the current screen navigable. It SHALL be derived from the route by
the shell, not assembled by each screen. The crumb for the `relays` segment SHALL
read Relays, for `listen` Listen, and for `state` State.

#### Scenario: A deep screen names its ancestors

- **WHEN** an operator opens a relay's state at `/namespaces/:ns/relays/:id/state`
- **THEN** the trail names the namespace, Relays, the relay, and State
- **AND** the namespace, Relays and the relay are links

#### Scenario: The listen view's crumb

- **WHEN** an operator opens `/namespaces/:ns/relays/:id/listen`
- **THEN** the last crumb reads Listen

#### Scenario: The current crumb is not a link

- **WHEN** a crumb trail is rendered
- **THEN** the last crumb is plain text and is marked as the current page

#### Scenario: A rail destination carries no trail

- **WHEN** an operator opens a namespace's Home or the Cluster screen
- **THEN** no crumb trail is rendered

#### Scenario: The bare back arrow is gone

- **WHEN** the codebase is searched for the `header/1` component's `back` attribute
- **THEN** no occurrence exists

### Requirement: An object's views are presented as tabs on that object

Where one object is shown by more than one route, those routes SHALL be presented
as tabs in the object's page header, with the active view marked. Each tab SHALL
remain its own route, so that a view holding a live subscription is not mounted
while another view is being read. A relay SHALL have three views:

- **Live**, at `/namespaces/:ns/relays/:id`, for what it is doing;
- **Listen**, at `/namespaces/:ns/relays/:id/listen`, for its records;
- **State**, at `/namespaces/:ns/relays/:id/state`, for what it has kept.

#### Scenario: A relay's three views

- **WHEN** an operator opens a relay
- **THEN** Live, Listen and State are shown as tabs on that relay
- **AND** the active tab is marked with `aria-current`

#### Scenario: Tabs navigate rather than toggle panels

- **WHEN** an operator selects the Listen tab
- **THEN** the browser navigates to `/namespaces/:ns/relays/:id/listen`

#### Scenario: Leaving the listen view releases it

- **WHEN** an operator moves from the Listen tab to the State tab
- **THEN** the listen view's live subscription is not left running

### Requirement: Long screens open on what matters

A screen carrying more than four sections SHALL render its lower sections so that
they collapse, with each screen declaring which sections are open on a first
visit. A section's open state SHALL persist per viewer. A collapsed section's
title line SHALL state in a few words what the section holds — its count, its
newest item or its condition — so that the operator can judge whether to open it.

#### Scenario: A first visit

- **WHEN** an operator opens a long screen for the first time
- **THEN** the screen's declared default sections are open and the rest are collapsed

#### Scenario: The choice persists

- **WHEN** an operator collapses a section and returns to that screen later
- **THEN** the section is still collapsed

#### Scenario: Persistence is unavailable

- **WHEN** the browser refuses to store the preference
- **THEN** the screen renders its declared defaults rather than failing or
  leaving a section stuck shut

#### Scenario: A collapsed section is reachable without a pointer

- **WHEN** an operator moves through the screen with the keyboard
- **THEN** each section's toggle is focusable and reports its expanded state

#### Scenario: A collapsed section states what it holds

- **WHEN** a relay's task journal section is collapsed
- **THEN** its title line states how many iterations are committed and when the
  latest was, without being opened

### Requirement: A command palette reaches any object by name

The shell SHALL offer a command palette on `Cmd+K` and `Ctrl+K`. It SHALL navigate to a relay by id, a namespace by name,
or any screen by name. It SHALL also offer actions on a named object that the
operator's operations allow: stop a relay, diagnose a relay, listen to a relay's
output, open open problems, and run a schedule now. An action that changes state
SHALL open the same confirmation its own screen uses, and SHALL NOT act on the
keystroke alone. The palette SHALL NOT open while a text input has focus. Every
destination and action the palette offers SHALL also be reachable by clicking.

#### Scenario: Jumping to a relay

- **WHEN** an operator opens the palette and types a relay id
- **THEN** the matching relay is offered with its namespace and health
- **AND** choosing it opens `/namespaces/:ns/relays/:id`

#### Scenario: Jumping to a screen

- **WHEN** an operator types a screen's name
- **THEN** that screen is offered

#### Scenario: Acting on a relay

- **WHEN** an operator types `stop orders` and chooses the offered action
- **THEN** the stop confirmation for `orders` opens, and nothing is stopped until
  it is confirmed

#### Scenario: An action the role does not grant

- **WHEN** the operator's operations do not include stopping a relay
- **THEN** no stop action is offered

#### Scenario: The palette does not steal typing

- **WHEN** an operator presses the shortcut while focused in a text field
- **THEN** the keystroke reaches the field and the palette does not open

#### Scenario: The index is built on first open

- **WHEN** an operator loads a screen and never opens the palette
- **THEN** no relay listing call is made on that screen's behalf for the palette

#### Scenario: A stale entry

- **WHEN** an operator chooses a relay that has since stopped
- **THEN** the relay screen's existing not-found state is shown rather than an error page

#### Scenario: Nothing matches

- **WHEN** the typed text matches no relay, namespace, screen or action
- **THEN** the palette says so rather than showing an empty list

### Requirement: Account controls are one menu

The topbar's identity, settings link, log-out action and theme toggle SHALL be
presented as a single account menu rather than as adjacent controls, so that
logging out cannot be reached by a single stray click.

#### Scenario: The menu holds the account actions

- **WHEN** an operator opens the account menu
- **THEN** the signed-in identity, settings, theme and log out are inside it

#### Scenario: Log out is not a bare topbar control

- **WHEN** the topbar is rendered
- **THEN** no log-out control sits outside the account menu

### Requirement: A screen states its own liveness

A screen that refreshes on a timer SHALL state that it does, SHALL show when it
last refreshed, and SHALL offer the operator a control to pause and resume it. A
paused screen SHALL stop replacing what is on display.

#### Scenario: The screen reports its last refresh

- **WHEN** an operator looks at an auto-refreshing screen
- **THEN** it shows when it last refreshed

#### Scenario: Pausing holds the view still

- **WHEN** an operator pauses refreshing
- **THEN** the displayed rows stop changing
- **AND** the screen states that it is paused

#### Scenario: Resuming picks the timer back up

- **WHEN** an operator resumes a paused screen
- **THEN** it refreshes and continues on its interval

#### Scenario: An open modal still suspends refreshing

- **WHEN** a screen that suspends refreshing while a modal is open has one open
- **THEN** refreshing is suspended as before, independently of the operator's pause

### Requirement: Relay routes

The router SHALL serve relays at these paths and no others: `/relays` for every
reachable relay, `/namespaces/:ns/relays` for one namespace's relays,
`/namespaces/:ns/relays/:id` for one relay's detail,
`/namespaces/:ns/relays/:id/listen` for its live input and output, and
`/namespaces/:ns/relays/:id/state` for its state. The retired `/operatives`
paths and the `…/stream` view SHALL NOT be routed or redirected; a request for one
SHALL answer 404.

#### Scenario: Each relay route mounts its screen

- **WHEN** an authenticated operator requests each of the five relay paths
- **THEN** each mounts its screen and answers 200

#### Scenario: A retired path answers 404

- **WHEN** an authenticated operator requests `/operatives`, `/namespaces/:ns/operatives`, `/namespaces/:ns/operatives/:id`, `/namespaces/:ns/operatives/:id/stream`, or `/namespaces/:ns/relays/:id/stream`
- **THEN** the response is 404 and no redirect is issued

#### Scenario: Links point at the new paths

- **WHEN** any screen renders a link to a relay or a relay listing
- **THEN** the link's path starts with `/relays` or `/namespaces/:ns/relays`

### Requirement: The rail counts open problems

The rail's `PLATFORM` section SHALL carry a Problems entry, leading to
`/problems`, that shows the number of open attention items in the tone of the
most severe of them, and nothing when there are none. The count SHALL come from
the shell's pulse and SHALL NOT be shown on a page with no socket.

#### Scenario: Two problems

- **WHEN** one relay is suspended and one relay has failed
- **THEN** the Problems entry shows 2 in the negative tone

#### Scenario: All clear

- **WHEN** no item is open
- **THEN** the Problems entry shows no count

#### Scenario: The settings page

- **WHEN** the settings page, which is not a LiveView, is rendered
- **THEN** it shows the same rail and topbar, without a problem count

### Requirement: The topbar offers help

The topbar SHALL carry a help control, labelled for assistive technology, that
opens the help overlay for the current screen, between the screen's liveness and
the account menu.

#### Scenario: Opening help from the topbar

- **WHEN** an operator activates the topbar's help control on a namespace's Home
- **THEN** the help overlay for Home opens

### Requirement: Factory routes

The router SHALL serve factories at `/factories` for the factories of every reachable namespace, `/namespaces/:ns/factories` for one namespace's factories, and `/namespaces/:ns/factories/:id` for one factory's page. Each SHALL carry the namespace scope in its route as every scoped screen does, and SHALL show a crumb trail. A factory page's crumbs SHALL be the namespace, Factories and the factory's id.

#### Scenario: Each factory route mounts its screen

- **WHEN** an authenticated operator requests each of the three factory paths
- **THEN** each mounts its screen and answers 200

#### Scenario: A factory page's crumbs

- **WHEN** an operator opens `/namespaces/default/factories/fan_trade`
- **THEN** the crumb trail reads default, Factories, fan_trade, each but the last a link

### Requirement: The rail is lifted off the page at desk width and collapses to its icons

At 1024 px and wider the rail SHALL stand off the page as a surface of its own, running the screen's full height with a hairline where it meets the content and a shadow cast onto it, in both themes, collapsed or not.

The rail SHALL carry, in its head beside the brand, a control that collapses it to its icons and expands it again. The control SHALL be shown at desk width only, SHALL keep focus after a press, and SHALL be named for what a press would do: "Collapse navigation" while the rail is expanded, "Expand navigation" while it is collapsed.

A collapsed rail SHALL show the brand's mark, every destination as its icon, a rule between sections, the open-problem count on the Problems icon and the connection's dot, so the topbar and canvas take the room it gives up. Every destination SHALL stay reachable by Tab and SHALL keep its name for assistive technology, and SHALL be named beside its icon on hover and on keyboard focus. Collapsing and expanding SHALL animate, and SHALL switch at once when the operator prefers reduced motion.

The choice SHALL be remembered in the browser and applied before the first paint of every later page, including a reload, a live navigation and the account settings page, which has no socket. With nothing stored, or with storage unavailable, the rail SHALL be expanded. The choice SHALL NOT affect the drawer below 1024 px.

#### Scenario: The rail stands off the page

- **WHEN** an operator opens any screen at 1440 px
- **THEN** the rail runs the screen's full height and casts a shadow onto the content beside it

#### Scenario: Collapsing the rail

- **WHEN** an operator at 1440 px activates the rail's collapse control
- **THEN** the rail narrows to its icons and the canvas widens into the room it gave up
- **AND** the control is named "Expand navigation" and keeps focus

#### Scenario: Expanding the rail

- **WHEN** the rail is collapsed and the operator activates the same control
- **THEN** the rail shows every section heading and destination name again
- **AND** the control is named "Collapse navigation"

#### Scenario: An icon is named beside it

- **WHEN** the rail is collapsed and the operator hovers or tabs to a destination's icon
- **THEN** the destination's name is shown beside the icon, outside the rail

#### Scenario: The count stays on the rail

- **WHEN** there are open problems and the rail is collapsed at 1440 px
- **THEN** the Problems icon carries their count

#### Scenario: Remembered across a reload

- **WHEN** an operator collapses the rail and reloads the screen
- **THEN** the screen opens with the rail collapsed, without first showing it expanded

#### Scenario: Remembered across screens

- **WHEN** an operator collapses the rail on a relay and follows a crumb to the namespace's Relays
- **THEN** Relays is shown with the rail collapsed

#### Scenario: On the settings page

- **WHEN** the rail was collapsed and the operator opens the account settings page, which has no socket
- **THEN** the rail is collapsed there too, and its control expands it

#### Scenario: The drawer ignores the desk choice

- **WHEN** the rail was collapsed at 1440 px and the window narrows to 768 px
- **THEN** the collapse control is hidden and the menu control opens the drawer with every heading and destination name

