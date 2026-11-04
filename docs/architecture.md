# How the console is built

## How it looks

The colours, the shell and the brand come from
[`flezha_stylebook`](https://github.com/Flezha/flezha_stylebook), the Flezha group's design system;
the content of every screen is drawn with the console's own component kit.

- **Colour has one source.** The kit reads colour only through `--fcon-*` roles
  in `assets/css/console/tokens.css`, and each role names the stylebook token it
  takes — `--fcon-ink-1` is `--text-primary`, `--fcon-canvas` is
  `--surface-sheet` — so the palette and both themes are the stylebook's. The
  console adds only a signal colour for live data, and the overlay scrim and
  shadow.
- **Status colour states an outcome.** The positive, warning and negative roles
  say healthy, degraded and failed, and every state is also said in words and
  by a shape. The accent marks interaction; the signal marks live data — flow,
  rates, change marks — and never a status.
- **The shell is the stylebook's**: the rail and topbar in the chrome, which is
  pale in light and deep plum in dark, and the content on a square-cornered sheet set
  into the chrome, the only part that scrolls.
- **The content kit** is `assets/css/console/` (`tokens.css`, `base.css`,
  `components.css`) with one function component per element in
  `FlezhaConsoleWeb.CoreComponents`: buttons, fields, switches, segmented controls,
  comboboxes, chips, state badges, grids with row menus, sections with digests,
  the page header, tabs, drawers, dialogs, popovers, tooltips, toasts,
  sparklines, meters, skeletons, code blocks, steps and identifiers. A screen
  opens on its page header — the kind of object, its name, one sentence on its
  condition, its actions and its tabs — and its sections are separated by space
  and hairlines rather than nested cards. Tiles are the one raised surface on
  a page: the stylebook's `.flz-tile`, with a tone edge, a lift on
  hover and fixed rows so a row of them stands level, and figures that shrink
  to fit (`.flz-figure-fit`) rather than spill. Every listing shows 20 rows
  and grows by a page on request, its count kept by the server
  (`FlezhaConsoleWeb.Live.Sections`). In dev, `/dev/kit` shows every component in
  every state.
- **Type**: flezha.com's faces — Space Grotesk for display, Inter for the
  interface and JetBrains Mono for identifiers and figures — from the
  stylebook's `fonts.css`, served from `priv/static/fonts`.
- **Theme contract**: attribute `data-theme="light|dark"` on `<html>`, storage
  key `flezha-theme`, set before the first paint by the stylebook's inlined
  `theme-hydrate.js`. The toggle sits in the topbar and on the signed-out
  pages, with flezha.com's sun and moon.
- **The relay pipeline graph** draws nodes and wires with the stylebook's
  relay-graph recipe (`.flz-graph-*`); the console's own `topo-*` rules add
  the relay's edge, nets in six hues (`--fcon-wire-0` to `--fcon-wire-5`, both
  themes; a channel keeps its hue through its port), halos and junction dots, ports and their taps, badges, focus, the
  view controls, the Cell sheet, the flow sentence and the timeline.
  `Topology.pipeline/1` places every node on abstract ranks and orders — sources
  and input filters, entry ports, tasklets by depth, exit ports, then the
  plugins, called relays and "no plugin bound" ends — routes each channel
  leaving a point as one net with its own lane in each gap, and only then maps
  the layout to x and y; layouts are kept per shape and direction, so no tick
  moves a node. A plugin is a source when its provider's `feeds` flag says so
  (`Fleet.providers/1`), on the entry it names or the first one. The
  `FlzPipeline` hook owns the view box (Fit, zoom, ctrl/⌘ + wheel, drag to pan,
  full screen) and the viewer's direction, kept in `localStorage` and sent with
  the panel size so Auto picks the direction that fits larger. Once the viewer
  zooms or pans, opening or closing a tasklet's Cells keeps that zoom and only
  pans the tasklet beside the sheet. Each tick the server pushes how many
  records each counted node took (`pipeline_counts`): IN by entry, each
  tasklet's admitted advance from `Relay.activity/4`, each output channel's
  count from a tally listen held while the page shows a relay with two or more
  outputs, and what was skipped and dead-lettered; and what each channel carried —
  every reader takes all of it, so it is worked out from its readers' intake,
  else its tally — and each wire into a tasklet reading several channels, its
  channel's share. A channel's label shows that rate, so a tasklet that emits
  several records per input reads as a jump along the graph. The hook starts
  marks at the sources and hands them on node by node on a canvas over the SVG,
  at about 24 frames a second, only while something moves and the graph is on
  screen; a wire of twelve or more records a second flows instead. Selecting a
  tasklet opens its Cells (`Relay.activity/4` with `cells_of`, read only while
  the sheet is open). The graph is read when the page opens and again when the
  relay is bound anew, and nothing is read while the tab is hidden. Without a
  graph the relay is an empty boundary and a line says why.
- **The gate.** `npm run tokens` holds every colour to these rules
  ([The design-token gate](testing.md#the-design-token-gate)).

## How the console talks to the controller

Every remote call goes through `FlezhaConsole.Service.NodeManager`, which is the
only module that names a `Flezha.*` module, and every call is an operation on
core's **published consumer API**: a `Flezha.Service.*` function listed in
core's `docs/internal/api/consumers/published.txt`, sent over the controller's
HTTPS channel as `POST /v1/call/<Module.function>` with its arguments as a JSON
array and the operator's token as its bearer token. The controller builds the
caller context from that token and runs the call through its one door, as it
does for every surface; the console builds no context. Answers are decoded from
JSON by the recorded shapes (`FlezhaConsole.Service.ControllerShapes`,
`priv/controller_shapes.json`), so screens read the terms they always did:
atom keys, atoms the console knows, tuples and times. A name the console has no
atom for stays text, so the controller's data never grows the atom table, and
node names are always text.
The door keeps the operations core does not let the network reach — issuing,
revoking and binding, deleting a namespace, claiming the bootstrap and stopping
the controller — away from the console; `flz` makes them.
`test/flezha_console/service/published_surface_test.exs` holds the console to that
with core's own extractor and list (`FLEZHA_CORE_PATH`, default `../flezha`).

The controller is the one `FLEZHA_CONTROLLER_URL` names, and only that one.
`FlezhaConsole.Service.NodeConnector` resolves its host, pins the first address
that answers an unauthenticated `GET /v1/catalogue`, keeps it while it answers,
and broadcasts `:controller_up` and `:controller_down`. TLS checks the server's
certificate against the URL's host, also on the pinned address.
`NodeManager.connected_node/0` answers the reached controller's name, from the
`local?` row of its `Controller.controllers` answer, while the channel is up, and
`nil` otherwise.

A call answers the controller's `{:ok, value}`, or its error read from the
channel's error body — code, class, message, hint, details — or one of
the transport conditions only this node sees: not connected, API missing,
timeout, remote error. An operation the door does not publish reads as API
missing. `NodeManager.error/1` reads any of them as one map, so a
screen decides how to present an error from its class and code, never from its
text, and a refusal reads as a refusal with the controller's own message rather
than as an empty table. `CoreComponents.runtime_error/1` renders every one of
them, and a diagnosis finding, with its code, its hint and a link to the code's
family in core's errors reference (`:core_docs_url`, default
`https://docs.flezha.com`).

Controls follow the bound role. The operations a token's role grants are read
once with its verification, from the `operations` that
`Flezha.Service.Namespace.whoami/1` answers, and `NodeManager.granted?/2` decides
whether a control renders. A controller that answers no list, or one whose
posture is `:open`, renders every control; either way the controller still
judges each call.

Identity comes *only* from `Flezha.Service.Namespace.whoami`, called with the
token: one answer gives the principal, namespace, role, granted operations and
the controller's enforcement posture. A name typed into this console is never
sent as a principal; the controller judges each call by the token it carries.
Verifications are cached briefly, and never for a transient
`authz.registry_unavailable`; a refused call evicts the entry. Without a token
the console makes no call at all, and every screen says it needs one, since the
HTTP API refuses any request without a bearer token.

A screen reads what it shows, never a whole namespace, so it costs the
controller the same with ten relays or ten thousand. A listing of relays,
plugins, dead letters, Cells, journal entries or committed iterations asks for
the page it shows (`limit`, `sort`, `filter`, as the controller's paged reads
take them), counts come from the controller's summary, one relay is read by
id, and rates are read for the relays on screen and, for Dashboard's Flow, as the
namespace's summed totals. Pickers of such a collection search the
controller as the operator types. Screens that refresh read off their
process and hold while their tab is hidden, as the shell's pulse does, and
reads of liveness counters and dead-letter seen counts are shared between an
operator's tabs through `NodeManager`'s read cache.
`FlezhaConsoleWeb.ListingView` is the one search, filter and sort view every
listing shares, written to the query string.

Behaviour shared across screens is a `use`-able module rather than a copied
block: `FlezhaConsoleWeb.Live.Refresh` (the tick, the forwarded runner events —
ignored by a screen scoped to another namespace — what a screen says about
its own currency and, for a screen declaring `background: true`, reading off
the LiveView process), `FlezhaConsoleWeb.Live.Tail` (a live
tail), `FlezhaConsoleWeb.Topology` (the pipeline graph, drawn live for a relay
and still for a factory, and the fleet summary),
`FlezhaConsoleWeb.Live.Launcher` (starting a relay, rendered by both
`/namespaces/:ns` and `/relays`), `FlezhaConsoleWeb.Live.PluginForm` (enabling,
binding and updating a plugin, from a relay's screen and the plugins screen),
`FlezhaConsoleWeb.Live.Target` (the namespace and
factory a write is aimed at, shared by the launcher and the schedule form) and
`FlezhaConsoleWeb.Live.Sections` (which of a long screen's panels are open);
`Layouts.scope_switch/1` is the one switch between a scoped listing and its
all-namespaces twin. A write
path implemented twice drifts, and the half that drifts is the one nobody is
looking at.

Live data rides `FlezhaConsole.Service.EventFeed`, and **no code of this
application runs on the controller**. A feed holds one published stream
operation — `Observability.tail/2`, `Logs.tail/2` or `Relay.listen/5` —
open on the channel's stream route, `POST /v1/stream/<Module.function>`, by a
process linked to it, which hands each server-sent event, decoded, to the feed
as `{:flezha_emit, event}`. The stream ends with the operation's answer (`end`),
with `overrun` when the console fell behind, which the feed always opens again
and tells the screen about the gap, or with a lost connection.
Runner connects and disconnects are observability signals on `:flezha_runner`,
which a supervised feed tails and broadcasts on `"flezha:events"`; relay starts,
stops and exits on `:flezha_relay` get a supervised feed of their own, on
`"flezha:relays"`, which only the relays index hears; the audit
and observability tails, the listen screen, the pipeline graph's payload tap
and the relay screen's Calls section (a `:calls` listen, held only while the
section is open) each hold a feed linked to the screen. When the feed exits its
request is closed and the controller ends the operation, so stopping the feed —
or closing the screen — releases the subscription. There
is no second mechanism. `EventFeed.stop/2` also drops what the feed already
sent under its tag, so a screen that replaces a feed never hears the old one,
and a retrying feed reports a reconnect only once its re-opened stream is held.
