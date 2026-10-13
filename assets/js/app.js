// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {bindThemeToggles} from "@flezha/stylebook/js/theme.js"

const typing = el =>
  !!el && (
    (el.tagName === "INPUT" && !["checkbox", "radio", "button", "submit"].includes(el.type)) ||
    el.tagName === "TEXTAREA" || el.tagName === "SELECT" || el.isContentEditable
  )

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

const visible = el => !el.hidden && el.offsetParent !== null

// ---- Popovers ----
//
// A `[data-fui-pop]` holds a trigger and a panel. Delegated from the document,
// so a menu works on a plain controller page and survives LiveView replacing
// its markup; the panel's `hidden` and the trigger's `aria-expanded` are left
// alone by the server patch (`JS.ignore_attributes`).

const popPanel = pop => pop.querySelector(":scope > [data-fui-pop-panel]")
const popTrigger = pop => pop.querySelector(":scope > [data-fui-pop-trigger]")
const popItems = pop => [...popPanel(pop).querySelectorAll("[data-fui-pop-item]")].filter(i => !i.hidden)
const popOpen = pop => !popPanel(pop).hidden

// Placed against the viewport, so no scrolling ancestor — a grid, the canvas —
// clips it; it opens upward when there is no room below, and aligns to the
// trigger's right edge when it is an end-aligned menu. Whatever the trigger's
// place, the panel is kept EDGE px inside the viewport.
const EDGE = 8

function placePop(pop) {
  const panel = popPanel(pop)
  const rect = popTrigger(pop).getBoundingClientRect()
  const end = panel.matches(".fui-popover--end, .right-0")
  const width = document.documentElement.clientWidth
  // Every side is set, so no stylesheet offset is left to apply against the
  // viewport.
  Object.assign(panel.style, {position: "fixed", top: "auto", bottom: "auto", left: "auto", right: "auto", marginTop: "0", maxWidth: `${width - 2 * EDGE}px`})
  if (pop.closest(".fui-combobox")) { panel.style.minWidth = `${Math.min(rect.width, width - 2 * EDGE)}px` }
  if (end) { panel.style.right = `${width - rect.right}px` }
  else { panel.style.left = `${rect.left}px` }
  const placed = panel.getBoundingClientRect()
  if (placed.left < EDGE || placed.right > width - EDGE) {
    const left = Math.max(EDGE, Math.min(placed.left, width - EDGE - placed.width))
    Object.assign(panel.style, {left: `${left}px`, right: "auto"})
  }
  const below = window.innerHeight - rect.bottom
  if (panel.offsetHeight + 8 > below && rect.top > below) {
    panel.style.bottom = `${window.innerHeight - rect.top + 4}px`
  } else {
    panel.style.top = `${rect.bottom + 4}px`
  }
}

function openPop(pop, at = null) {
  closePops(pop)
  popPanel(pop).hidden = false
  placePop(pop)
  popTrigger(pop).setAttribute("aria-expanded", "true")
  const filter = popPanel(pop).querySelector("[data-fui-filter]")
  if (filter) { filter.value = ""; filterPop(popPanel(pop), ""); filter.focus({preventScroll: true}); return }
  const items = popItems(pop)
  if (!items.length) { return }
  const target = at === null
    ? (items.find(i => i.getAttribute("aria-checked") === "true") ?? items[0])
    : items.at(at)
  target.focus({preventScroll: true})
}

function closePop(pop, {refocus = false} = {}) {
  if (!popOpen(pop)) { return }
  popPanel(pop).hidden = true
  popTrigger(pop).setAttribute("aria-expanded", "false")
  if (refocus) { popTrigger(pop).focus() }
}

function closePops(except = null) {
  for (const pop of document.querySelectorAll("[data-fui-pop]")) {
    if (pop !== except && !pop.contains(except)) { closePop(pop) }
  }
}

// A filter box narrows the items of its popover, or of any list marked
// `data-fui-filterable`.
function filterPop(container, text) {
  const needle = text.trim().toLowerCase()
  for (const item of container.querySelectorAll("[data-fui-pop-item], [data-fui-item]")) {
    item.hidden = needle !== "" && !item.textContent.toLowerCase().includes(needle)
  }
}

document.addEventListener("click", event => {
  const trigger = event.target.closest("[data-fui-pop-trigger]")
  if (trigger) {
    const pop = trigger.closest("[data-fui-pop]")
    popOpen(pop) ? closePop(pop) : openPop(pop)
    return
  }
  const item = event.target.closest("[data-fui-pop-item]")
  if (item) { closePop(item.closest("[data-fui-pop]"), {refocus: true}); return }
  if (!event.target.closest("[data-fui-pop-panel]")) { closePops() }
})

// A placed panel follows its trigger when what holds the trigger scrolls, and
// closes once the trigger has scrolled out of sight.
function followPops(scrolled) {
  for (const pop of document.querySelectorAll("[data-fui-pop]")) {
    if (!popOpen(pop) || !scrolled.contains?.(pop)) { continue }
    const rect = popTrigger(pop).getBoundingClientRect()
    rect.bottom < 0 || rect.top > window.innerHeight ? closePop(pop) : placePop(pop)
  }
}

document.addEventListener("scroll", event => {
  followPops(event.target === document ? document.documentElement : event.target)
}, true)
window.addEventListener("resize", () => followPops(document.documentElement))

document.addEventListener("input", event => {
  if (event.target.matches("[data-fui-filter]")) {
    filterPop(event.target.closest("[data-fui-pop], [data-fui-filterable]"), event.target.value)
  }
})

document.addEventListener("keydown", event => {
  const pop = event.target.closest?.("[data-fui-pop]")
  if (!pop) { return }

  if (event.target.matches("[data-fui-pop-trigger]")) {
    const at = {ArrowDown: 0, ArrowUp: -1}[event.key]
    if (at !== undefined) { event.preventDefault(); openPop(pop, at) }
    return
  }

  const items = popItems(pop)
  if (event.target.matches("[data-fui-filter]")) {
    if (event.key === "ArrowDown" && items.length) { event.preventDefault(); items[0].focus() }
    if (event.key === "Enter" && items.length) { event.preventDefault(); items[0].click() }
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); closePop(pop, {refocus: true}) }
    return
  }

  const i = items.indexOf(document.activeElement)
  const next = {
    ArrowDown: items[(i + 1) % items.length],
    ArrowUp: items[(i - 1 + items.length) % items.length],
    Home: items[0],
    End: items[items.length - 1]
  }[event.key]

  if (next) {
    event.preventDefault()
    next.focus()
  } else if (event.key === "Escape") {
    event.preventDefault()
    event.stopPropagation()
    closePop(pop, {refocus: true})
  } else if (event.key === "Tab") {
    closePop(pop)
  }
})

// ---- The navigation drawer ----
//
// Below desk width the rail is a drawer. A `[data-fui-nav-toggle]` opens and
// closes it, delegated like the popovers so it works on a page with no
// socket; while it is open the rest of the shell is inert.

const shell = () => document.querySelector(".flz-app")
const navOpen = () => shell()?.hasAttribute("data-nav-open") ?? false
let navOpener = null

function setNav(open, {refocus = false} = {}) {
  const app = shell()
  if (!app || open === navOpen()) { return }
  app.toggleAttribute("data-nav-open", open)
  for (const part of app.querySelectorAll(":scope > :not(#shell-nav)")) { part.inert = open }
  for (const toggle of app.querySelectorAll("[data-fui-nav-toggle]")) { toggle.setAttribute("aria-expanded", String(open)) }
  if (open) {
    // Scrolled into view: in a short landscape drawer the current place can sit
    // below the fold, and the drawer is fixed, so the page does not move.
    const nav = document.getElementById("shell-nav")
    ;(nav.querySelector("[aria-current]") ?? nav.querySelector(FOCUSABLE))?.focus()
  } else if (refocus) {
    // The opener may have been hidden by a resize into another mode.
    const back = navOpener && visible(navOpener) ? navOpener : [...app.querySelectorAll("[data-fui-nav-toggle]")].find(visible)
    back?.focus({preventScroll: true})
  }
}

document.addEventListener("click", event => {
  const toggle = event.target.closest("[data-fui-nav-toggle]")
  if (toggle) { navOpener = toggle; setNav(!navOpen(), {refocus: true}); return }
  if (!navOpen()) { return }
  // A tap on the scrim lands on the inert shell around the drawer; a toast
  // floats over everything and is not beside the drawer.
  if (!event.target.closest("#shell-nav, .fui-toasts")) { setNav(false, {refocus: true}) }
  else {
    // A link to where the operator already is navigates nowhere, so focus
    // goes back to the menu control rather than to a page that never loads.
    const link = event.target.closest("#shell-nav a[href]")
    if (link) { setNav(false, {refocus: link.href === location.href}) }
  }
})

document.addEventListener("keydown", event => {
  if (event.key === "Escape" && navOpen()) { event.preventDefault(); setNav(false, {refocus: true}) }
})

window.addEventListener("phx:page-loading-start", () => setNav(false))
// At desk width the rail stands beside the page, and nothing may stay inert.
window.matchMedia("(width >= 1024px)").addEventListener("change", ({matches}) => matches && setNav(false))

// ---- Copying an identifier or a value shown once ----
//
// `data-fui-copy` names the value itself; `data-fui-copy-from` names the
// element whose text is the value. Either way the control says so for a moment.

document.addEventListener("click", event => {
  const control = event.target.closest("[data-fui-copy], [data-fui-copy-from]")
  if (!control) { return }
  const value = control.dataset.fuiCopy ??
    document.querySelector(control.dataset.fuiCopyFrom)?.textContent.trim()
  if (value === undefined || !navigator.clipboard) { return }
  // Said only once the clipboard took it: a page served over plain http has
  // no clipboard to write to.
  navigator.clipboard.writeText(value).then(() => {
    control.setAttribute("data-copied", "")
    setTimeout(() => control.removeAttribute("data-copied"), 1200)
  }, () => {})
})

// ---- Help ----

const openHelp = () => {
  const help = document.getElementById("help-overlay")
  if (help && !help.open) { help.showModal() }
}

document.addEventListener("click", event => {
  if (event.target.closest("[data-fui-help-open]")) { event.preventDefault(); openHelp() }
})

// ---- Keyboard shortcuts ----
//
// Never inside a text field, and never with a modifier: Ctrl+K belongs to the
// palette and every other chord to the browser. `g` then a letter follows the
// shell's `[data-shortcut]` link of that letter. Nothing fires under an open
// dialog, drawer or navigation drawer.

let pendingG = 0

document.addEventListener("keydown", event => {
  if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey) { return }
  if (typing(event.target) || navOpen() || document.querySelector("dialog[open], [aria-modal='true']")) { return }

  if (event.key === "?") { event.preventDefault(); openHelp(); return }
  if (event.key === "g") { pendingG = Date.now(); return }

  if (pendingG && Date.now() - pendingG < 1500 && /^[a-z]$/.test(event.key)) {
    pendingG = 0
    const link = document.querySelector(`[data-shortcut="${event.key}"]`)
    if (link) { event.preventDefault(); link.click() }
  }
})

// ---- Toasts on a plain controller page ----
//
// A LiveView page clears and times its toasts through `FlzToast`; a
// controller page has no socket, so its toasts are dismissed here. An info
// toast leaves on its own after TOAST_MS either way; an error stays.

const TOAST_MS = 6000
const deadToast = el => !el.closest("[data-phx-session]")

document.addEventListener("click", event => {
  const dismiss = event.target.closest("[data-toast-dismiss]")
  if (dismiss && deadToast(dismiss)) { dismiss.closest(".fui-toast").hidden = true }
})

for (const toast of document.querySelectorAll('.fui-toast[data-kind="info"]')) {
  if (deadToast(toast)) { setTimeout(() => { toast.hidden = true }, TOAST_MS) }
}

// ---- Hooks ----

let Hooks = {}

// A section's fold state is a viewer preference, not application state, so it
// lives in this browser. The server still owns what is rendered — the hook
// reads the stored choice on mount and asks for it; any storage failure leaves
// the screen's declared default standing.
Hooks.FlzSection = {
  mounted() {
    if (this.el.dataset.sectionForced === "true") { return }
    const stored = this.stored()
    if (stored !== null && stored !== this.isOpen()) {
      this.pushEvent("section_toggle", {key: this.el.dataset.sectionKey})
    }
  },
  // A section the screen forced open — a breached quota — is not the viewer's
  // choice, so it is neither restored from storage nor written back to it.
  updated() { if (this.el.dataset.sectionForced !== "true") { this.remember() } },
  isOpen() { return this.el.dataset.open === "true" },
  storageKey() { return `flz-section:${this.el.dataset.sectionKey}` },
  stored() {
    try {
      const raw = window.localStorage.getItem(this.storageKey())
      return raw === null ? null : raw === "true"
    } catch (_error) { return null }
  },
  remember() {
    try { window.localStorage.setItem(this.storageKey(), String(this.isOpen())) } catch (_error) {}
  }
}

// A drawer or a dialog: focus moves in when it opens, Tab cycles inside it,
// and focus goes back to whatever opened it when it closes. The opener is
// remembered by element and by id, because the server may have re-rendered it
// while the overlay was open.
Hooks.FlzFocus = {
  mounted() {
    const opener = document.activeElement
    this.opener = opener
    this.openerId = opener?.id
    const first = this.el.querySelector("[autofocus]") ||
      [...this.el.querySelectorAll("input:not([type=hidden]), select, textarea")].find(visible) ||
      [...this.el.querySelectorAll(FOCUSABLE)].find(visible)
    first?.focus()
    this.onKeydown = event => {
      if (event.key !== "Tab") { return }
      const focusable = [...this.el.querySelectorAll(FOCUSABLE)].filter(visible)
      if (!focusable.length) { return }
      const [head, tail] = [focusable[0], focusable[focusable.length - 1]]
      if (event.shiftKey && document.activeElement === head) { event.preventDefault(); tail.focus() }
      else if (!event.shiftKey && document.activeElement === tail) { event.preventDefault(); head.focus() }
    }
    this.el.addEventListener("keydown", this.onKeydown)
  },
  destroyed() {
    const back = (this.opener?.isConnected && this.opener) ||
      (this.openerId && document.getElementById(this.openerId))
    back?.focus?.()
  }
}

// A figure that changed between refreshes is marked for a moment. The mark is
// an attribute the server patch ignores, so it lasts its moment and no longer.
Hooks.FlzChange = {
  mounted() { this.last = this.el.dataset.value },
  updated() {
    const value = this.el.dataset.value
    if (value === this.last) { return }
    this.last = value
    this.el.removeAttribute("data-changed")
    void this.el.offsetWidth
    this.el.setAttribute("data-changed", "")
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.el.removeAttribute("data-changed"), 1600)
  },
  destroyed() { clearTimeout(this.timer) }
}

// An informational toast leaves after five seconds; an error stays.
Hooks.FlzToast = {
  mounted() { this.arm() },
  updated() { this.arm() },
  destroyed() { clearTimeout(this.timer) },
  arm() {
    clearTimeout(this.timer)
    if (this.el.dataset.kind !== "info" || this.el.hidden) { return }
    this.timer = setTimeout(() => this.el.querySelector("[data-toast-dismiss]")?.click(), TOAST_MS)
  }
}

// The palette's keyboard. Bound on the window so it reaches the operator
// wherever they are, and stood down while they are typing into something —
// Ctrl+K belongs to the field that has focus.
Hooks.FlzPalette = {
  mounted() {
    this.onKeydown = event => {
      if (event.key === "Escape" && this.el.dataset.open === "true") {
        this.pushEventTo(this.el, "close", {})
        return
      }
      if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== "k") { return }
      if (typing(event.target) || navOpen()) { return }
      event.preventDefault()
      this.pushEventTo(this.el, "open", {})
    }
    window.addEventListener("keydown", this.onKeydown)
  },
  updated() {
    const input = this.el.querySelector(".fui-palette-input")
    if (input && document.activeElement !== input) { input.focus() }
  },
  destroyed() { window.removeEventListener("keydown", this.onKeydown) }
}

// The relay pipeline's motion. Each tick's counter advances arrive as
// `pipeline_counts` and are replayed as hollow dots along the route each
// counter names, spread over the next tick; a tap's records arrive as
// `pipeline_records` and ride its side filled, with the start of their
// payload. A streaming wire draws its band instead, so only dead letters ride
// it. Every wire and box a dot crosses lights and fades over the CSS
// transition; inside a box the dot is hidden, so it passes through, not over.
// Hovering or focusing an element traces the routes through it, and the arrow
// keys walk the lanes in the order the server numbers them.
const DOT_POOL = 24
// Counted dots replay one tick; a longer gap, after a pause or a failed read,
// is compressed into it rather than holding the pool for the whole gap.
const SPREAD_MS = 2000
const DOT_RIDE_MS = {in: 1600, out: 1600, filter: 1000, dlq: 1000}
const TRACED = ["out", "filter", "dlq", "life"]
const SVG_NS = "http://www.w3.org/2000/svg"
const AFTERGLOW_MS = 6000
const TAP_FLUSH_MS = 250

Hooks.FlzPipeline = {
  mounted() {
    this.flights = []
    this.pool = []
    this.tappedDeadLetters = 0
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.handleEvent("pipeline_counts", counts => this.counts(counts))
    this.handleEvent("pipeline_records", records => this.records(records))

    this.onOver = event => this.trace(event.target.closest?.("[data-routes]"))
    this.onLeave = () => this.trace(this.el.contains(document.activeElement) ? document.activeElement.closest("[data-routes]") : null)
    this.onFocus = event => this.trace(event.target.closest("[data-routes]"))
    this.onKeydown = event => this.walk(event)
    this.el.addEventListener("pointerover", this.onOver)
    this.el.addEventListener("pointerleave", this.onLeave)
    this.el.addEventListener("focusin", this.onFocus)
    this.el.addEventListener("focusout", this.onLeave)
    this.el.addEventListener("keydown", this.onKeydown)

    // A hidden tab's page keeps ticking, so the screen is told to stop reading.
    this.onVisibility = () => this.pushEvent("refresh_visibility", {hidden: document.hidden})
    document.addEventListener("visibilitychange", this.onVisibility)
    if (document.hidden) { this.onVisibility() }
  },
  // A rejoined LiveView starts afresh, so it is told again about a hidden tab.
  reconnected() { if (document.hidden) { this.onVisibility() } },
  destroyed() {
    document.removeEventListener("visibilitychange", this.onVisibility)
    cancelAnimationFrame(this.frame)
    this.flights = []
  },

  route(name) { return this.el.querySelector(`#route-${name}`) },

  // Nothing is drawn behind a hidden tab, so nothing is queued for it either.
  counts({in: taken, out, filtered, parked, interval_ms, modes}) {
    this.modes = modes
    const tappedDeadLetters = this.tappedDeadLetters
    this.tappedDeadLetters = 0
    if (document.hidden) { return }
    const tapped = this.el.dataset.tapped
    const span = Math.min(interval_ms, SPREAD_MS)
    if (tapped !== "input" && modes.in !== "streaming") { this.spread("in", taken, "counted", span) }
    if (tapped !== "output" && modes.out !== "streaming") { this.spread("out", out, "counted", span) }
    this.spread("filter", filtered, "filtered", span)
    // An output tap hears the dead letters parked on input itself, but not
    // those parked further on, so the counters draw only what it did not.
    this.spread("dlq", Math.max(parked - tappedDeadLetters, 0), "fail", span)
  },

  records({port, records, dead_letters, previews}) {
    if (document.hidden) { return }
    this.tappedDeadLetters += dead_letters
    const route = port === "input" ? "in" : "out"
    if (this.modes?.[route] !== "streaming") { this.spread(route, records, "tapped", TAP_FLUSH_MS, previews) }
    this.spread("dlq", dead_letters, "fail", TAP_FLUSH_MS)
  },

  // `count` flights spread evenly over `span`; dead letters are never capped.
  spread(route, count, kind, span, previews = []) {
    const now = performance.now()
    for (let i = 0; i < count; i++) {
      this.launch({route, kind, always: kind === "fail", preview: previews[i], at: now + (span * i) / count})
    }
  },

  // A flight waits for its moment; under reduced motion it only lights its
  // route when that moment comes.
  launch(flight) {
    if (!this.route(flight.route)) { return }
    if (!flight.always && this.flights.filter(f => !f.always).length >= DOT_POOL) { return }
    this.flights.push({...flight, lit: new Set()})
    if (!this.frame) { this.frame = requestAnimationFrame(t => this.step(t)) }
  },

  step(now) {
    this.frame = null
    this.flights = this.flights.filter(flight => this.fly(flight, now))
    if (this.flights.length) { this.frame = requestAnimationFrame(t => this.step(t)) }
  },

  // Moves one flight; answers whether it is still under way.
  fly(flight, now) {
    if (now < flight.at) { return true }
    const route = this.route(flight.route)
    const ride = DOT_RIDE_MS[flight.route]
    const t = Math.min((now - flight.at) / ride, 1)
    if (!route) { this.land(flight); return false }

    if (this.reduced.matches) {
      this.light(flight, 1)
      return false
    }
    if (!flight.dot) { flight.dot = this.dot(flight) }
    const point = route.getPointAtLength(t * route.getTotalLength())
    const visibility = this.inBox(flight.route, t) ? "hidden" : "visible"
    flight.dot.setAttribute("cx", point.x)
    flight.dot.setAttribute("cy", point.y)
    flight.dot.setAttribute("visibility", visibility)
    if (flight.label) {
      flight.label.setAttribute("x", point.x)
      flight.label.setAttribute("y", point.y - 9)
      flight.label.setAttribute("visibility", visibility)
    }
    this.light(flight, t)
    if (t >= 1) { this.land(flight); return false }
    return true
  },

  inBox(route, t) {
    return [...this.el.querySelectorAll(`.flz-graph-node[data-flow="${route}"]`)]
      .some(box => Number(box.dataset.at) <= t && t < Number(box.dataset.until))
  },

  dot(flight) {
    const layer = this.el.querySelector("#topology-dots")
    const dot = (!flight.always && this.pool.pop()) || document.createElementNS(SVG_NS, "circle")
    dot.setAttribute("r", "4")
    dot.setAttribute("class", {
      counted: "flz-graph-dot topo-dot topo-dot--counted",
      filtered: "flz-graph-dot topo-dot topo-dot--counted topo-dot--filtered",
      tapped: "flz-graph-dot topo-dot",
      fail: "flz-graph-dot flz-graph-dot--fail topo-dot"
    }[flight.kind])
    dot.setAttribute("data-flying", "")
    layer.appendChild(dot)
    if (flight.preview) {
      flight.label = document.createElementNS(SVG_NS, "text")
      flight.label.setAttribute("class", "topo-dot-preview")
      flight.label.setAttribute("text-anchor", "middle")
      flight.label.textContent = flight.preview
      layer.appendChild(flight.label)
    }
    return dot
  },

  land(flight) {
    flight.label?.remove()
    if (!flight.dot) { return }
    flight.dot.removeAttribute("data-flying")
    if (flight.always) { flight.dot.remove() } else { this.pool.push(flight.dot) }
  },

  // Each wire and box of the route lights once the dot reaches where it starts, and
  // fades through the stylesheet's transition once the light is taken off.
  light(flight, t) {
    for (const wire of this.el.querySelectorAll(`[data-flow="${flight.route}"]`)) {
      if (flight.lit.has(wire) || Number(wire.dataset.at) > t) { continue }
      flight.lit.add(wire)
      wire.classList.add("is-lit")
      // Reduced motion takes the fade away, so the light is held for as long instead.
      if (this.reduced.matches) { setTimeout(() => wire.classList.remove("is-lit"), AFTERGLOW_MS); continue }
      requestAnimationFrame(() => requestAnimationFrame(() => wire.classList.remove("is-lit")))
    }
  },

  // The traced routes live on the wrapper, which the server patch leaves
  // alone, so a tick does not undo the highlight.
  trace(element) {
    const routes = element && this.el.contains(element) ? element.dataset.routes.split(" ") : []
    this.el.toggleAttribute("data-trace", routes.length > 0)
    for (const route of TRACED) { this.el.toggleAttribute(`data-trace-${route}`, routes.includes(route)) }
  },

  // LiveView hands a key to the window binding only when the focused element
  // binds no key of its own, so Escape on a focused node or port is sent here.
  walk(event) {
    if (event.key === "Escape" && event.target.hasAttribute?.("phx-keydown") && this.el.hasAttribute("phx-window-keydown")) {
      this.pushEvent(this.el.getAttribute("phx-window-keydown"), {})
      return
    }
    const step = {ArrowLeft: [0, -1], ArrowRight: [0, 1], ArrowUp: [-1, 0], ArrowDown: [1, 0]}[event.key]
    const from = event.target.closest?.("[data-nav]")
    if (!step || !from || event.altKey || event.ctrlKey || event.metaKey) { return }
    const lanes = ["life", "record", "inside", "fail"]
    const stops = [...this.el.querySelectorAll("[data-nav]")]
    const lane = lanes.indexOf(from.dataset.lane)
    const centre = el => { const box = el.getBoundingClientRect(); return box.left + box.width / 2 }
    const middle = el => { const box = el.getBoundingClientRect(); return box.top + box.height / 2 }
    let target = null

    if (step[1]) {
      target = stops.find(el => el.dataset.lane === from.dataset.lane && Number(el.dataset.nav) === Number(from.dataset.nav) + step[1])
    } else if (from.dataset.lane === "inside") {
      // Inside the relay, Up and Down walk the column first.
      target = stops
        .filter(el => el.dataset.lane === "inside" && Math.abs(centre(el) - centre(from)) < 40 && Math.sign(middle(el) - middle(from)) === step[0])
        .sort((a, b) => Math.abs(middle(a) - middle(from)) - Math.abs(middle(b) - middle(from)))[0]
    }
    if (!target && !step[1]) {
      for (let next = lane + step[0]; !target && next >= 0 && next < lanes.length; next += step[0]) {
        const row = stops.filter(el => el.dataset.lane === lanes[next])
        target = row.sort((a, b) => Math.abs(centre(a) - centre(from)) - Math.abs(centre(b) - centre(from)))[0]
      }
    }
    if (target) {
      event.preventDefault()
      target.focus()
    }
  }
}

Hooks.ScrollBottom = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.scrollToBottom())
    this.observer.observe(this.el, {childList: true, subtree: true})
  },
  updated() { this.scrollToBottom() },
  destroyed() { this.observer?.disconnect() },
  scrollToBottom() { this.el.scrollTop = this.el.scrollHeight }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

// Progress bar on live navigation and form submits. Its colour is read from
// the live theme rather than hard-coded, and re-read when the theme flips.
const token = name =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim()

function configureTopbar() {
  topbar.config({barColors: {0: token("--fui-accent")}, shadowColor: token("--fui-accent")})
}
configureTopbar()
document.addEventListener("flz-theme-change", configureTopbar)

window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// A result that renders away from the control that asked for it is brought
// into view and marked for a moment, so a click never seems to do nothing.
window.addEventListener("phx:fui:reveal", ({detail}) => {
  const el = document.getElementById(detail.id)
  if (!el) return
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches
  el.scrollIntoView({behavior: still ? "auto" : "smooth", block: "nearest"})
  el.classList.remove("fui-revealed")
  void el.offsetWidth
  el.classList.add("fui-revealed")
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

bindThemeToggles()

// Re-binding is idempotent: the DOM ignores a listener already registered with
// the same function reference, and toggleTheme is module-level.
window.addEventListener("phx:page-loading-stop", () => bindThemeToggles())
