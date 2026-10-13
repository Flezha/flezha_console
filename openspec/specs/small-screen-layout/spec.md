# small-screen-layout Specification

## Purpose
How the console lays itself out and behaves below desk width and under touch: the three shell modes, the navigation drawer, the phone's bottom bar, the one-row topbar, tables as cards, dialogs as sheets, menus kept on screen, touch targets, the device's edges, and the browser project that holds a phone to all of it.
## Requirements
### Requirement: The shell has three modes by width

The console shell SHALL lay itself out in one of three modes, chosen by viewport width alone:

- **desk**, at 1024 px and wider: the rail sits beside the content and the topbar is as it was before this change;
- **compact**, from 600 to 1023 px: the rail becomes a navigation drawer, and the topbar keeps to one row that begins with a menu control;
- **phone**, at 599 px and narrower: the rail becomes a navigation drawer, the topbar keeps to one row, and a bottom bar carries the main destinations.

No routed screen SHALL scroll the page sideways in any mode.

#### Scenario: Desk width keeps the rail

- **WHEN** an operator opens any screen at 1440 px
- **THEN** the rail with its section headings sits beside the content
- **AND** no menu control and no bottom bar is shown

#### Scenario: A tablet opens the drawer from the topbar

- **WHEN** an operator opens any screen at 768 px
- **THEN** no rail sits beside the content
- **AND** the topbar is one row and begins with a menu control that opens the navigation drawer

#### Scenario: A phone shows the bottom bar

- **WHEN** an operator opens any screen at 390 px
- **THEN** a bottom bar is shown and the topbar is one row no taller than 56 px plus the top safe area

#### Scenario: No sideways scroll

- **WHEN** any routed screen is rendered at 360 px, 390 px or 768 px
- **THEN** the document is no wider than the viewport

### Requirement: The navigation drawer is the rail

Below 1024 px the rail SHALL be shown as a drawer against the left edge, over a scrim, holding every destination, every section heading, the problems count and the rail foot that the rail holds at desk width. The drawer SHALL be the same navigation element as the rail, not a copy. While it is open, nothing behind it SHALL take focus or a tap. Escape, a tap outside it, and following any link SHALL close it. When it closes, focus SHALL return to the control that opened it, or to the menu control shown when that one has since been hidden by a change of width. A screen refresh SHALL NOT close it. Below 1024 px the page itself scrolls, so the page behind the drawer, a dialog, an inspector drawer or help SHALL hold still while it is open. The drawer SHALL work on a page that holds no LiveView socket.

#### Scenario: Opening the drawer

- **WHEN** an operator activates a menu control
- **THEN** the drawer opens showing every destination and section heading
- **AND** the control reports `aria-expanded="true"`
- **AND** focus moves to the current destination inside the drawer

#### Scenario: Closing by Escape

- **WHEN** the drawer is open and the operator presses Escape
- **THEN** the drawer closes and focus returns to the control that opened it

#### Scenario: Closing by tapping outside

- **WHEN** the drawer is open and the operator taps the scrim
- **THEN** the drawer closes and the tap does not reach the content behind it

#### Scenario: Following a destination

- **WHEN** the operator follows a destination in the drawer
- **THEN** the destination is shown and the drawer is closed

#### Scenario: Focus stays inside

- **WHEN** the drawer is open and the operator tabs past its last control
- **THEN** focus does not reach the content behind the drawer

#### Scenario: The page behind holds still

- **WHEN** the drawer is open at 390 px and the operator scrolls over the scrim
- **THEN** the page behind does not scroll

#### Scenario: A refresh tick does not close it

- **WHEN** the drawer is open on a screen that refreshes on a timer and a refresh arrives
- **THEN** the drawer stays open

#### Scenario: On the settings page

- **WHEN** an operator on the account settings page, which has no socket, activates the menu control
- **THEN** the drawer opens and closes as it does on any other screen

### Requirement: The drawer foot carries what the narrow topbar leaves out

Below 1024 px the drawer's foot SHALL show the connected node, the signed-in flezha principal with its namespace and role, the theme toggle, and the console version. These SHALL be drawn by the same components the desk topbar uses. Exactly one copy of each control SHALL be shown at any width.

#### Scenario: The principal on a phone

- **WHEN** an operator opens the drawer at 390 px
- **THEN** its foot names the bound principal, its namespace and its role

#### Scenario: Switching theme on a phone

- **WHEN** an operator activates the theme toggle in the drawer foot
- **THEN** the theme switches and the choice is stored as the topbar toggle stores it

#### Scenario: One copy per width

- **WHEN** the shell is rendered at 1440 px
- **THEN** only the topbar theme toggle is shown
- **AND** at 390 px only the drawer foot theme toggle is shown

### Requirement: The narrow topbar keeps one row by priority

Below 1024 px the topbar SHALL keep to one row and SHALL stay at the top of the screen while the page scrolls. On a phone it SHALL hold the namespace picker, the liveness state with its pause control, and the account menu. In compact mode it SHALL also hold the menu control, the search control, help and the theme toggle, and the menu control SHALL carry the open-problem count in the worst problem's tone, as the rail does, since no rail or bar shows it there. The namespace picker SHALL take the room that is left and shorten a long name rather than wrap the row. Liveness SHALL still state when the screen last refreshed, or that it is paused. A disconnected controller SHALL be stated in the topbar at every width.

#### Scenario: Liveness on a phone

- **WHEN** an auto-refreshing screen is shown at 390 px
- **THEN** the topbar shows the time of the last refresh and the pause control
- **AND** pausing makes it say "Paused"

#### Scenario: A long namespace name

- **WHEN** the namespace in scope has a name wider than the room left in the row
- **THEN** the picker shortens the name with an ellipsis and the topbar stays one row

#### Scenario: The problem count on a tablet

- **WHEN** there are open problems and a screen is shown at 768 px
- **THEN** the menu control shows their count

#### Scenario: Not connected

- **WHEN** the console has no connected controller node and is shown at 390 px
- **THEN** the topbar states that it is not connected

#### Scenario: Help on a phone

- **WHEN** a routed screen is shown at 390 px
- **THEN** its page header offers the help control for that screen

### Requirement: A phone has a bottom bar of main destinations

At 599 px and narrower a bar SHALL sit along the bottom edge, clear of the device's home indicator. In order, it SHALL hold Home, Relays and Problems, which are the destinations the `g h`, `g r` and `g p` shortcuts reach, then Search, which opens the command palette, then Menu, which opens the navigation drawer. Each item SHALL show an icon and a label. The item for the current screen SHALL carry `aria-current="page"`. Problems SHALL show the open-problem count in the worst problem's tone, as the rail does, and nothing when there is no open problem. The bar and the keyboard shortcuts SHALL be drawn from one set of links. The bar SHALL never cover the last content on a screen.

#### Scenario: Reaching Relays from the bar

- **WHEN** an operator taps Relays in the bottom bar with a namespace in scope
- **THEN** that namespace's relays screen is shown and the Relays item is marked current

#### Scenario: No namespace in scope

- **WHEN** no namespace is in scope and the operator taps Home
- **THEN** the namespaces listing is shown, as the `g h` shortcut does

#### Scenario: The problems count

- **WHEN** there are open problems
- **THEN** the Problems item shows their count in the worst problem's tone

#### Scenario: Search from the bar

- **WHEN** an operator taps Search
- **THEN** the command palette opens with its input focused

#### Scenario: Shortcuts still work at desk width

- **WHEN** an operator at 1440 px presses `g` then `c`
- **THEN** the cluster screen is shown, though no bottom bar is visible

#### Scenario: The end of a long screen

- **WHEN** an operator scrolls a long screen to its end at 390 px
- **THEN** the last content sits fully above the bottom bar

### Requirement: The command palette opens without a keyboard

Below 1024 px a visible control SHALL open the command palette: the bottom bar's Search on a phone, and a topbar search control in compact mode. On a phone the palette SHALL fill the screen with its input at the top, beside a Cancel control that closes it, since a phone has no Escape key. While it is open, focus SHALL stay inside it, and when it closes focus SHALL return to the control that opened it. The control SHALL be offered only on screens that hold the palette.

#### Scenario: Opening the palette in compact mode

- **WHEN** an operator at 768 px activates the topbar search control
- **THEN** the palette opens with its input focused

#### Scenario: Leaving the palette on a phone

- **WHEN** an operator at 390 px taps the palette's Cancel
- **THEN** the palette closes without navigating
- **AND** focus returns to the bar's Search

#### Scenario: A page without the palette

- **WHEN** the account settings page is shown at 768 px or 390 px
- **THEN** no search control is offered

### Requirement: Tables read as cards on a phone

Every table SHALL label each of its cells with its column's name. At 599 px and narrower every table SHALL show each row as a card: the row's first cell is its title, its menu sits at the card's top right, its other cells follow as captioned values, and its tone is the card's leading edge. No cell's content SHALL lie outside the viewport, and the table SHALL still be read as a table by assistive technology. Every table in the console SHALL be drawn by the shared grid component.

#### Scenario: The relays list on a phone

- **WHEN** an operator opens the relays screen at 390 px
- **THEN** each relay is a card titled with its id
- **AND** its health, run and node are visible with their captions, without sideways scrolling

#### Scenario: A row's menu on a card

- **WHEN** a row with actions is shown as a card
- **THEN** its menu control sits at the card's top right and opens its actions

#### Scenario: An activatable row

- **WHEN** an operator taps a card whose row opens an inspector
- **THEN** the inspector opens as it does when the row is clicked at desk width

#### Scenario: Assistive technology

- **WHEN** a screen reader reads a table shown as cards
- **THEN** each value is announced with its column's name

### Requirement: The page header gives the title its room

A page header SHALL keep at least 20rem for its title block. When its actions do not fit beside that, they SHALL move under the title. They SHALL NOT narrow it. This SHALL hold at every canvas width, with or without the rail.

#### Scenario: A tablet header

- **WHEN** the relays screen is shown at 768 px
- **THEN** the title "Relays in …" reads on one or two lines
- **AND** the scope switch and Start relay sit under it

#### Scenario: A desk header

- **WHEN** a screen is shown at 1440 px
- **THEN** its actions sit beside the title, as before

### Requirement: Dialogs are bottom sheets on a phone

At 599 px and narrower, or 500 px tall and shorter (a phone on its side), a dialog — help included — SHALL rise from the bottom edge, as wide as the screen and no taller than the dynamic viewport less its top safe area. Its title, the actions in its foot, a stepped form's step controls and a form's closing row of buttons SHALL stay in view while its body scrolls. The command palette SHALL fill the screen under the same condition.

#### Scenario: A long form

- **WHEN** an operator opens the start-relay dialog at 390 px and scrolls its factory list
- **THEN** the dialog's title and its foot actions stay in view

#### Scenario: A phone on its side

- **WHEN** an operator opens the start-relay dialog at 844×390
- **THEN** it is a sheet whose title and step controls are in view

#### Scenario: Closing a sheet

- **WHEN** an operator presses Escape or taps a sheet's close control
- **THEN** it closes as the dialog does at desk width

### Requirement: Menus stay on screen

Every placed popover — a menu, a picker, a combobox list, a help tip — SHALL be shown entirely inside the viewport with at least 8 px to spare. It SHALL be no wider than the viewport less 16 px.

#### Scenario: The account menu on a phone

- **WHEN** an operator opens the account menu at 390 px
- **THEN** the whole menu is inside the viewport
- **AND** Settings and Log out can be activated

#### Scenario: A row menu near the edge

- **WHEN** an operator opens a row's menu on a card at 360 px
- **THEN** the whole menu is inside the viewport

### Requirement: Touch is a first-class input

On a coarse pointer every interactive control SHALL offer a hit area at least 44 px tall, except a target inside a line of text — a glossary term or an identifier — which keeps the text's height. Nothing SHALL be reachable only by hovering. A tooltip that hovering would show SHALL NOT be shown where the device has no hover. A tap on a glossary term SHALL open its explanation. No text field SHALL be drawn below 16 px at 599 px and narrower.

#### Scenario: Target size

- **WHEN** a routed screen is rendered with a coarse pointer
- **THEN** every visible button, segment, switch and field outside a line of text is at least 44 px tall

#### Scenario: A term on a phone

- **WHEN** an operator taps a glossary term on a touch device
- **THEN** its explanation opens
- **AND** no half-shown tooltip is left on screen

#### Scenario: Focusing a field

- **WHEN** an operator focuses any text field at 390 px, including a list's filter box
- **THEN** its font size is at least 16 px

### Requirement: The shell respects the device's edges

The console SHALL declare `viewport-fit=cover` and `interactive-widget=resizes-content`. It SHALL size the shell against the dynamic viewport height, and SHALL pad its topbar, drawer and bottom bar for the device's safe areas. On a phone, toasts SHALL rise from just above the bottom bar. They SHALL NOT cover the topbar.

#### Scenario: A toast on a phone

- **WHEN** a flash is shown at 390 px
- **THEN** it sits above the bottom bar
- **AND** the topbar's account menu stays reachable

#### Scenario: The viewport declaration

- **WHEN** any console page is served
- **THEN** its viewport meta declares `viewport-fit=cover` and `interactive-widget=resizes-content`

### Requirement: The relay graph shows that it scrolls

At 599 px and narrower the relay pipeline graph SHALL run to the screen's edges, and an edge beyond which more of the graph lies SHALL carry a shade. The graph SHALL keep its own size, so that its text never shrinks.

#### Scenario: A graph wider than the phone

- **WHEN** a relay whose graph is wider than the screen is shown at 390 px
- **THEN** the graph's right edge carries a shade
- **AND** scrolling it to its end removes that shade and shades the left edge

### Requirement: The browser suite runs a phone project

The Playwright configuration SHALL define a phone project: Chromium at 390×844 with touch and a mobile viewport. That project SHALL run a phone spec driving the drawer, every bottom-bar item, search, the account menu, a card table, a bottom sheet and the one-row topbar. The spec SHALL also check every routed screen for sideways scroll at 390 px and at 360 px. It SHALL include one compact-mode case at 768 px. The desktop project SHALL NOT run the phone spec.

#### Scenario: Running the suite

- **WHEN** `npm run e2e` runs against the dev stack
- **THEN** the desktop project runs the existing specs and the phone project runs the phone spec

#### Scenario: A phone regression

- **WHEN** a change makes any routed screen scroll sideways at 360 px
- **THEN** the phone spec fails and names that screen

