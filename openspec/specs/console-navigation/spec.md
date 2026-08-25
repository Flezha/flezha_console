# console-navigation Specification

## Purpose
The console's information architecture: how an operator reaches a screen,
what tells them where they are, and what a screen says about its own
currency.

## Requirements
### Requirement: The sidebar separates namespace-scoped from platform-global

The navigation rail SHALL present two labelled sections. A `NAMESPACE` section
SHALL hold Overview, Operatives, Plugins and Schedules for the namespace in
scope. A `PLATFORM` section SHALL hold Dashboard, Fleet, Namespaces, Cluster,
Controller, Observability, Dead-letter and Audit. A screen SHALL appear in the
`NAMESPACE` section only when the controller call behind it accepts a namespace,
or when the rows it returns each carry one. With no namespace in scope the
`NAMESPACE` section SHALL say so rather than offer destinations it has no scope
to point at.

#### Scenario: The sections are labelled

- **WHEN** an operator looks at the sidebar
- **THEN** the two groups are separated and each carries a visible heading

#### Scenario: No namespace is in scope

- **WHEN** an operator is on a platform screen
- **THEN** the `NAMESPACE` section carries its heading and states that no
  namespace is in scope, offering a way to pick one

#### Scenario: Dead-letter is not presented as scoped

- **WHEN** the sidebar is rendered
- **THEN** Dead-letter sits in the `PLATFORM` section
- **AND** no route offers a namespace-scoped dead-letter view

#### Scenario: Observability is not presented as scoped

- **WHEN** the sidebar is rendered
- **THEN** Observability sits in the `PLATFORM` section

#### Scenario: The current destination is marked

- **WHEN** an operator is on a screen reachable from the sidebar
- **THEN** that entry carries `aria-current="page"`
- **AND** exactly one entry carries it

### Requirement: A namespace scope is carried in the route

Namespace-scoped screens SHALL take their namespace from a path segment, not from
session or socket state, so that the address bar always names the scope on
display.

#### Scenario: The scope is in the address bar

- **WHEN** an operator opens a namespace's operatives
- **THEN** the URL is `/namespaces/:ns/operatives`

#### Scenario: A shared link opens the same scope

- **WHEN** an operator copies the URL of a scoped screen and another operator opens it
- **THEN** the second operator sees the same namespace scoped, without depending on
  what either of them looked at previously

#### Scenario: A scoped screen states its scope as fixed

- **WHEN** a scoped screen renders its namespace
- **THEN** the namespace is presented as the screen's scope rather than as a
  clearable filter control

### Requirement: The namespace picker means one thing everywhere

The shell SHALL offer a namespace picker. Choosing a namespace from a
namespace-scoped screen SHALL navigate to the same screen kind under the chosen
namespace. Choosing one from a platform screen SHALL navigate to the chosen
namespace's overview.

#### Scenario: Switching scope keeps the screen

- **WHEN** an operator viewing one namespace's operatives picks another namespace
- **THEN** they land on the second namespace's operatives, not on a list

#### Scenario: Switching scope from a platform screen

- **WHEN** an operator on Cluster picks a namespace
- **THEN** they land on that namespace's overview

#### Scenario: The picker offers only reachable namespaces

- **WHEN** the bound flezha token is scoped to one namespace
- **THEN** the picker offers only namespaces `scoped_namespaces/1` returns

### Requirement: Every screen below the top level shows a crumb trail

A screen deeper than the top level SHALL render a breadcrumb trail naming each
ancestor in words, with every ancestor but the current screen navigable. The
trail SHALL be derived from the route by the shell, not assembled by each screen.

#### Scenario: A deep screen names its ancestors

- **WHEN** an operator opens an operative's durable state
- **THEN** the trail names the namespace, the operative, and the current view
- **AND** the namespace and the operative are links

#### Scenario: The current crumb is not a link

- **WHEN** a crumb trail is rendered
- **THEN** the last crumb is plain text and is marked as the current page

#### Scenario: Top-level screens carry no trail

- **WHEN** an operator opens the dashboard
- **THEN** no breadcrumb trail is rendered

#### Scenario: The bare back arrow is gone

- **WHEN** the codebase is searched for the `header/1` component's `back` attribute
- **THEN** no occurrence exists

### Requirement: An object's views are presented as tabs on that object

Where one object is shown by more than one route, those routes SHALL be presented
as a tab strip on the object, with the active view marked. Each tab SHALL remain
its own route so that a view holding a live subscription is not mounted while
another view is being read.

#### Scenario: An operative's three views

- **WHEN** an operator opens an operative
- **THEN** Detail, Stream and State are shown as tabs on that operative
- **AND** the active tab is marked with `aria-current`

#### Scenario: Tabs navigate rather than toggle panels

- **WHEN** an operator selects the Stream tab
- **THEN** the browser navigates to the stream route

#### Scenario: Leaving the stream releases it

- **WHEN** an operator moves from the Stream tab to the State tab
- **THEN** the stream's live subscription is not left running

### Requirement: Long screens open on what matters

A screen carrying more than four panels SHALL render its lower panels as sections
that collapse, with each screen declaring which sections are open on a first
visit. A section's open state SHALL persist per viewer.

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

### Requirement: A command palette reaches any object by name

The shell SHALL offer a command palette on `Cmd+K` and `Ctrl+K` that navigates to
an operative by id, a namespace by name, or any screen by name. The palette SHALL
NOT open while a text input has focus. Every destination the palette offers SHALL
also be reachable by clicking.

#### Scenario: Jumping to an operative

- **WHEN** an operator opens the palette and types an operative id
- **THEN** the matching operative is offered with its namespace and health
- **AND** choosing it opens that operative

#### Scenario: Jumping to a screen

- **WHEN** an operator types a screen's name
- **THEN** that screen is offered

#### Scenario: The palette does not steal typing

- **WHEN** an operator presses the shortcut while focused in a text field
- **THEN** the keystroke reaches the field and the palette does not open

#### Scenario: The index is built on first open

- **WHEN** an operator loads a screen and never opens the palette
- **THEN** no operative listing call is made on that screen's behalf for the palette

#### Scenario: A stale entry

- **WHEN** an operator chooses an operative that has since stopped
- **THEN** the operative screen's existing not-found state is shown rather than an error page

#### Scenario: Nothing matches

- **WHEN** the typed text matches no operative, namespace, or screen
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
