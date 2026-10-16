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

// A viewer preference; storage that is blocked or full reads as unset.
const pref = {
  get: key => { try { return window.localStorage.getItem(key) } catch (_error) { return null } },
  set: (key, value) => { try { window.localStorage.setItem(key, value) } catch (_error) {} }
}

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

// A shortcut fires only outside a field and with no navigation drawer or
// dialog open.
const shortcutsHeld = target =>
  typing(target) || navOpen() || document.querySelector("dialog[open], [aria-modal='true']") !== null
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
  if (shortcutsHeld(event.target)) { return }

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
    const raw = pref.get(this.storageKey())
    return raw === null ? null : raw === "true"
  },
  remember() { pref.set(this.storageKey(), String(this.isOpen())) }
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

// The relay pipeline. The server places every node and routes every wire; the
// hook owns how the viewer looks at it and what moves on it.
//
// The view: the graph fits its panel, the zoom buttons, ctrl/⌘ + wheel and a
// drag on the background change only the SVG's view box, and full screen only
// the frame. Once the viewer has zoomed or panned, opening or closing a Cell
// sheet keeps that zoom and only brings the tasklet into view. The direction
// is the viewer's own choice, kept in this browser and sent with the panel's
// size, since Auto is decided by the fit.
//
// The motion: each tick's `pipeline_counts` says how many records each
// counted node took, and what the wires into a tasklet reading several
// channels and each channel carried. Marks start only at sources; a mark
// reaching a node is handed on along its wires in proportion to what each
// wire carried, while the next node's budget lasts, so records are drawn in
// the order they pass. A mark stands for as many records as its wire's
// sampling needs, a wire streaming twelve or more a second flows continuously
// instead, and budget no mark has reached within a few seconds is launched as
// is. Marks are drawn on a canvas laid over the SVG, at about 24 frames a
// second, only while something moves and the graph is on screen.
const MARKS_DRAWN = 80
const MARKS_A_SECOND = 4
const marksIn = span => (MARKS_A_SECOND * span) / 1000
const TASKLET_PAUSE_MS = 90
const CALL_MS = 250
const FRAME_MS = 1000 / 24
// How long a node's budget waits for a mark to reach it before it is drawn
// anyway: long enough for a mark to cross the longest path of a tick.
const GRACE_MS = 5000
const TICK_SPAN_MS = 2500
const TAP_FLUSH_MS = 250
const FLOW_PERIOD = 18
const FLOW_DASH = 4
const FLOW_STEPS_A_SECOND = 20
const DIRECTION_KEY = "flz-pipeline-direction"
// Counts that belong to wires, never to a node waiting for marks.
const WIRE_COUNTS = new Set(["chan", "feed"])

const storedDirection = () => {
  const value = pref.get(DIRECTION_KEY)
  return ["auto", "LR", "TB"].includes(value) ? value : "auto"
}

const kindOf = id => id === "skipped" ? "skip" : (id.match(/^([a-z]+)-/)?.[1] ?? id)

// Cumulative lengths, so a mark's position is a cheap interpolation.
function measure(pts) {
  const acc = [0]
  for (let i = 1; i < pts.length; i++) {
    acc.push(acc[i - 1] + Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]))
  }
  return {pts, acc, len: acc[acc.length - 1]}
}

function pointAt(m, d) {
  let i = 1
  while (i < m.acc.length - 1 && m.acc[i] < d) { i++ }
  const [ax, ay] = m.pts[i - 1]
  const [bx, by] = m.pts[i]
  const t = Math.max(0, Math.min(1, (d - m.acc[i - 1]) / (m.acc[i] - m.acc[i - 1] || 1)))
  return [ax + (bx - ax) * t, ay + (by - ay) * t]
}

Hooks.FlzPipeline = {
  mounted() {
    this.frameEl = this.el.closest(".topo-frame")
    this.marks = []
    this.pending = []
    this.tick = null
    this.lit = new Set()
    this.onScreen = true
    this.reduced = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.readGraph()
    this.layoutKey = this.el.dataset.layout
    this.cellsKey = this.el.dataset.cells
    this.readInks()
    this.sizeStage()
    this.fit()

    this.handleEvent("pipeline_counts", counts => this.counts(counts))
    this.handleEvent("pipeline_records", records => this.records(records))

    this.listen(this.frameEl, "click", event => this.control(event))
    this.listen(this.el, "pointerover", event => this.hover(event.target))
    this.listen(this.el, "pointerleave", () => this.hover(null))
    this.listen(this.el, "focusin", event => this.hover(event.target))
    this.listen(this.el, "focusout", () => this.hover(null))
    this.listen(this.el, "keydown", event => this.walk(event))
    this.listen(this.el, "pointerdown", event => this.grab(event))
    this.listen(this.el, "pointermove", event => this.drag(event))
    this.listen(this.el, "pointerup", event => this.drop(event))
    this.listen(this.el, "pointercancel", event => this.drop(event))
    this.listen(this.el, "click", event => this.swallow(event), true)
    this.listen(this.el, "wheel", event => this.wheel(event), {passive: false})
    this.listen(window, "keydown", event => this.escape(event))
    this.listen(document, "flz-theme-change", () => { this.readInks(); this.draw(performance.now()) })
    this.listen(this.reduced, "change", () => {
      this.marks = []
      this.pending = []
      if (this.tick) { this.tick.remaining = {}; this.tick.since = {} }
      this.draw(performance.now())
    })

    // A hidden tab's page keeps ticking, so the screen is told to stop reading.
    this.onVisibility = () => {
      this.pushEvent("refresh_visibility", {hidden: document.hidden})
      if (!document.hidden) { this.resume() }
    }
    this.listen(document, "visibilitychange", this.onVisibility)
    if (document.hidden) { this.onVisibility() }

    this.seen = new IntersectionObserver(entries => {
      this.onScreen = entries.some(entry => entry.isIntersecting)
      if (this.onScreen) { this.resume() }
    })
    this.seen.observe(this.el)

    this.resized = new ResizeObserver(() => {
      clearTimeout(this.resizeTimer)
      this.resizeTimer = setTimeout(() => this.resize(), 150)
    })
    this.resized.observe(this.el.parentElement)

    this.direction = storedDirection()
    this.pushView()
    // Read by the browser specs: which wire each mark first rode, and when.
    this.launched = new Map()
    this.el.flzMotion = this
  },

  updated() {
    this.readGraph()
    const layout = this.el.dataset.layout
    const cells = this.el.dataset.cells
    if (layout !== this.layoutKey || (cells !== this.cellsKey && !this.adjusted)) {
      this.layoutKey = layout
      this.cellsKey = cells
      this.sizeStage()
      this.fit()
    } else if (cells !== this.cellsKey) {
      this.cellsKey = cells
      this.restage()
      if (cells) { this.reveal(cells) }
      this.applyView()
    } else {
      this.applyView()
    }
    this.hover(this.rehover())
  },

  // The element hovered before a patch, or the one that replaced it.
  rehover() {
    const h = this.hovered
    if (!h || h.isConnected) { return h }
    const wire = h.closest?.(".topo-hit")?.dataset.wire ?? h.dataset?.wire
    const node = h.closest?.("[data-node]")?.dataset.node ?? h.dataset?.node
    if (wire) { return this.el.querySelector(`.topo-hit[data-wire="${CSS.escape(wire)}"]`) }
    return node ? this.el.querySelector(`[data-node="${CSS.escape(node)}"]`) : null
  },

  // A rejoined LiveView starts afresh, so it is told again about a hidden tab
  // and about the viewer's direction.
  reconnected() {
    if (document.hidden) { this.onVisibility() }
    this.pushView()
  },

  destroyed() {
    for (const [target, type, fn, opts] of this.listeners ?? []) { target.removeEventListener(type, fn, opts) }
    this.seen?.disconnect()
    this.resized?.disconnect()
    clearTimeout(this.resizeTimer)
    cancelAnimationFrame(this.raf)
    this.frameEl?.removeAttribute("data-full")
  },

  listen(target, type, fn, opts) {
    target.addEventListener(type, fn, opts)
    ;(this.listeners ||= []).push([target, type, fn, opts])
  },

  // ---- What the server drew ----

  readGraph() {
    this.svg = this.el.querySelector("#topology-svg")
    this.canvas = this.el.querySelector("#topology-motion canvas")
    this.focusStyle = this.el.querySelector("#topology-motion style")
    const [x, y, w, h] = (this.el.dataset.bounds || "0 0 1 1").split(" ").map(Number)
    this.bounds = {x, y, w, h}
    const old = this.wires ?? new Map()
    this.wires = new Map()
    this.outOf = new Map()
    this.inTo = new Map()
    for (const el of this.el.querySelectorAll(".topo-hit[data-wire]")) {
      const pts = (el.dataset.pts || "").split(" ").filter(Boolean).map(p => p.split(",").map(Number))
      if (pts.length < 2) { continue }
      const wire = {
        id: el.dataset.wire,
        from: el.dataset.from,
        to: el.dataset.to,
        entry: el.dataset.entry || null,
        kind: el.dataset.kind,
        key: el.dataset.key || null,
        mode: el.dataset.mode,
        rate: Number(el.dataset.rate) || 0,
        m: measure(pts),
        carry: old.get(el.dataset.wire)?.carry ?? 0,
        owed: old.get(el.dataset.wire)?.owed ?? null
      }
      this.wires.set(wire.id, wire)
      if (!this.outOf.has(wire.from)) { this.outOf.set(wire.from, []) }
      this.outOf.get(wire.from).push(wire)
      if (!this.inTo.has(wire.to)) { this.inTo.set(wire.to, []) }
      this.inTo.get(wire.to).push(wire)
    }
    // A mark in flight keeps its wire through a re-render, by id; one whose
    // wire is gone ends where it is.
    const rebind = item => !item.wire || (item.wire = this.wires.get(item.wire.id))
    this.marks = this.marks.filter(rebind)
    this.pending = this.pending.filter(rebind)
    this.backpressure = this.el.querySelector(".topo-backpressure") !== null
  },

  // The inks the canvas draws with, from the theme's own tokens.
  readInks() {
    const style = getComputedStyle(this.el)
    const ink = name => style.getPropertyValue(name).trim()
    this.inks = {
      signal: ink("--fui-signal"),
      surface: ink("--fui-surface"),
      fail: ink("--fui-negative"),
      warning: ink("--fui-warning"),
      text: ink("--fui-ink-2"),
      // A canvas does not resolve custom properties, so the face is read here.
      mono: `10px ${ink("--font-mono") || "monospace"}`
    }
  },

  // ---- The view ----

  // The Cell sheet lies over the stage's right side, as wide as CSS makes it.
  sheetWidth() {
    return this.el.querySelector("#topology-cells")?.offsetWidth ?? 0
  },

  maxHeight() {
    if (this.full) {
      return Math.max(240, window.innerHeight - this.el.getBoundingClientRect().top - 12)
    }
    return Math.min(window.innerHeight * 0.72, 860)
  },

  // The stage width the Cell sheet leaves, as wide as a desktop panel before
  // the panel has a width.
  freeWidth() { return Math.max(200, this.stageWidth() - this.sheetWidth()) },

  stageWidth() { return this.el.clientWidth || 1200 },

  sizeStage() {
    const max = this.maxHeight()
    const scale = Math.min(1, this.freeWidth() / this.bounds.w, max / this.bounds.h)
    const least = this.el.dataset.cells ? 480 : 320
    this.el.style.height = `${this.full ? max : Math.min(max, Math.max(least, Math.ceil(this.bounds.h * scale)))}px`
  },

  // The whole graph, in the part of the stage the Cell sheet leaves free.
  fit() {
    const b = this.bounds
    const cw = this.el.clientWidth || 1
    const ch = this.el.clientHeight || 1
    const free = Math.max(200, cw - this.sheetWidth())
    const s = Math.min(1, free / b.w, ch / b.h)
    this.view = {x: b.x - (free / s - b.w) / 2, y: b.y - (ch / s - b.h) / 2, w: cw / s, h: ch / s}
    this.adjusted = false
    this.applyView()
  },

  // A stage sized afresh keeps the viewer's own zoom, from the same corner,
  // or refits. A stage with no size has no zoom to keep, so the view waits.
  restage() {
    const s = this.scale()
    this.sizeStage()
    if (!this.adjusted) { this.fit(); return }
    const {clientWidth: cw, clientHeight: ch} = this.el
    if (s > 0 && Number.isFinite(s) && cw && ch) { this.view = {...this.view, w: cw / s, h: ch / s} }
  },

  // Pans no further than needed to bring a node into the part of the stage
  // the Cell sheet leaves free.
  reveal(id) {
    const box = this.el.querySelector(`[data-node="${CSS.escape(id)}"]`)?.getBBox?.()
    const s = this.scale()
    if (!box || !(s > 0 && Number.isFinite(s))) { return }
    const pad = 16 / s
    const into = (lo, size, at, len) =>
      at - pad < lo || len + 2 * pad > size ? at - pad - lo : Math.max(0, at + len + pad - (lo + size))
    const v = this.view
    this.view = {...v, x: v.x + into(v.x, this.freeWidth() / s, box.x, box.width),
      y: v.y + into(v.y, (this.el.clientHeight || 1) / s, box.y, box.height)}
  },

  scale() {
    return Math.min(this.el.clientWidth / this.view.w, this.el.clientHeight / this.view.h)
  },

  applyView() {
    if (!this.view || !this.svg) { return }
    const {x, y, w, h} = this.view
    this.svg.setAttribute("viewBox", `${x} ${y} ${w} ${h}`)
    const pct = this.frameEl?.querySelector("#topology-zoom")
    if (pct) { pct.textContent = `${Math.round(this.scale() * 100)}%` }
    this.draw(performance.now())
  },

  zoomBy(factor, px, py) {
    const s = this.scale()
    const k = s / Math.max(0.25, Math.min(3, s * factor))
    const cx = px ?? this.view.x + this.view.w / 2
    const cy = py ?? this.view.y + this.view.h / 2
    this.adjust({x: cx - (cx - this.view.x) * k, y: cy - (cy - this.view.y) * k, w: this.view.w * k, h: this.view.h * k})
  },

  oneToOne() {
    const cx = this.view.x + this.view.w / 2
    const cy = this.view.y + this.view.h / 2
    const w = this.el.clientWidth
    const h = this.el.clientHeight
    this.adjust({x: cx - w / 2, y: cy - h / 2, w, h})
  },

  // A view the viewer chose, kept until they ask for a fit.
  adjust(view) {
    this.view = view
    this.adjusted = true
    this.applyView()
  },

  setFull(on) {
    this.full = on
    this.frameEl.toggleAttribute("data-full", on)
    this.frameEl.querySelector("[data-zoom='full']")?.setAttribute("aria-pressed", String(on))
    this.sizeStage()
    this.fit()
  },

  // The panel's controls: zoom, fit, full screen and the direction.
  control(event) {
    const zoom = event.target.closest("[data-zoom]")
    const dir = event.target.closest("[data-dir]")
    if (zoom) {
      ({in: () => this.zoomBy(1.25), out: () => this.zoomBy(1 / 1.25), fit: () => this.fit(),
        one: () => this.oneToOne(), full: () => this.setFull(!this.full)})[zoom.dataset.zoom]?.()
    } else if (dir) {
      this.direction = dir.dataset.dir
      pref.set(DIRECTION_KEY, this.direction)
      this.pushView()
    }
  },

  // The width sent leaves the Cell sheet out, so opening one never makes Auto
  // turn the graph.
  pushView() {
    const width = this.stageWidth()
    const height = this.maxHeight()
    this.sentSize = [width, height]
    this.pushEvent("graph_view", {direction: this.direction, width, height: Math.round(height)})
  },

  // A panel that changed size refits, or keeps the viewer's own zoom; Auto
  // may now fit the other direction larger, so the server is told the size.
  resize() {
    this.restage()
    this.applyView()
    const width = this.stageWidth()
    const [w0, h0] = this.sentSize ?? [0, 0]
    if (Math.abs(width - w0) > w0 * 0.1 || Math.abs(this.maxHeight() - h0) > h0 * 0.1) { this.pushView() }
  },

  svgPoint(event) {
    const box = this.el.getBoundingClientRect()
    const s = this.scale()
    return [this.view.x + (event.clientX - box.left) / s, this.view.y + (event.clientY - box.top) / s]
  },

  wheel(event) {
    if (!(event.ctrlKey || event.metaKey)) { return }
    event.preventDefault()
    const [x, y] = this.svgPoint(event)
    this.zoomBy(event.deltaY < 0 ? 1.15 : 1 / 1.15, x, y)
  },

  // A drag on anything but a node or the sheet pans; the click that ends a
  // drag selects nothing.
  grab(event) {
    this.dragged = false
    if (event.button !== 0 || event.target.closest("[data-node], .topo-cells, a, button")) { return }
    this.panning = {x: event.clientX, y: event.clientY, view: {...this.view}, moved: false, id: event.pointerId}
  },

  drag(event) {
    const pan = this.panning
    if (!pan || pan.id !== event.pointerId) { return }
    const dx = event.clientX - pan.x
    const dy = event.clientY - pan.y
    if (!pan.moved && Math.hypot(dx, dy) < 3) { return }
    if (!pan.moved) { pan.moved = true; this.el.setPointerCapture(event.pointerId); this.el.classList.add("is-panning") }
    const s = this.scale()
    this.adjust({...pan.view, x: pan.view.x - dx / s, y: pan.view.y - dy / s})
  },

  drop(event) {
    if (!this.panning || this.panning.id !== event.pointerId) { return }
    this.dragged = this.panning.moved
    this.panning = null
    this.el.classList.remove("is-panning")
  },

  swallow(event) {
    if (this.dragged) { event.stopPropagation(); event.preventDefault() }
    this.dragged = false
  },

  // ---- Focus: what a wire or a node touches ----

  // Hovering or focusing a wire or a node lights the nets touching it and
  // their ends and dims the rest; with nothing hovered, the tasklet whose
  // Cells are open keeps that focus. The rules are written into a style the
  // server patch leaves alone.
  hover(target) {
    const el = target && this.el.contains(target) ? target : null
    this.hovered = el
    const wire = el?.closest?.(".topo-hit")
    const node = el?.closest?.("[data-node]")
    const nets = new Set()
    const nodes = new Set()
    const touching = id => {
      for (const g of this.el.querySelectorAll(".topo-net[data-ends]")) {
        if (g.dataset.ends.split(" ").includes(id)) { nets.add(g.dataset.net) }
      }
    }
    if (wire) {
      nets.add(wire.closest(".topo-net").dataset.net)
    } else if (node) {
      nodes.add(node.dataset.node)
      touching(node.dataset.node)
    } else if (this.el.dataset.cells) {
      nodes.add(this.el.dataset.cells)
      touching(this.el.dataset.cells)
    }
    for (const id of nets) {
      const g = this.el.querySelector(`.topo-net[data-net="${CSS.escape(id)}"]`)
      for (const end of g?.dataset.ends.split(" ") ?? []) { nodes.add(end) }
    }
    const on = nets.size + nodes.size > 0
    this.el.toggleAttribute("data-focus", on)
    this.focusStyle.textContent = on
      ? [...[...nets].map(id => `#topology-canvas[data-focus] .topo-net[data-net="${CSS.escape(id)}"]`),
         ...[...nodes].map(id => `#topology-canvas[data-focus] [data-node="${CSS.escape(id)}"]`)].join(",\n") +
        " { opacity: 1; }\n" +
        [...nets].map(id => `#topology-canvas .topo-net[data-net="${CSS.escape(id)}"] .topo-wire`).join(",\n") +
        (nets.size ? " { stroke: var(--fui-accent); stroke-opacity: 1; stroke-width: 2; }" : "")
      : ""
  },

  // ---- The keyboard ----

  // Along the drawn direction the arrows follow the record path; across it
  // they move within the rank. LiveView hands a window key binding only to a
  // focused element binding none, so Escape is handled here: it closes the
  // Cell sheet, then full screen, then the selection.
  walk(event) {
    if (event.altKey || event.ctrlKey || event.metaKey) { return }
    const from = event.target.closest?.("[data-node]")
    const lr = this.el.dataset.direction !== "TB"
    const step = (lr
      ? {ArrowRight: "next", ArrowLeft: "prev", ArrowDown: 1, ArrowUp: -1}
      : {ArrowDown: "next", ArrowUp: "prev", ArrowRight: 1, ArrowLeft: -1})[event.key]
    if (!from || step === undefined) { return }
    let target = null
    if (typeof step === "string") {
      const id = (from.dataset[step] || "").split(" ").filter(Boolean)[0]
      target = id && this.el.querySelector(`[data-node="${CSS.escape(id)}"]`)
    } else if (from.dataset.rank !== undefined) {
      const order = Number(from.dataset.order)
      target = [...this.el.querySelectorAll(`[data-node][data-rank="${from.dataset.rank}"]`)]
        .filter(el => Math.sign(Number(el.dataset.order) - order) === step)
        .sort((a, b) => Math.abs(Number(a.dataset.order) - order) - Math.abs(Number(b.dataset.order) - order))[0]
    }
    if (target) {
      event.preventDefault()
      target.focus()
    }
  },

  escape(event) {
    if (event.key !== "Escape" || event.defaultPrevented || shortcutsHeld(event.target)) { return }
    if (this.el.dataset.cells) { this.pushEvent("graph_cells_close", {}) }
    else if (this.full) { this.setFull(false) }
    else if (this.el.dataset.selected) { this.pushEvent("graph_dismiss", {}) }
    else { return }
    event.preventDefault()
  },

  // ---- Motion ----

  // Marks start at the sources, and at an entry nothing drawn feeds, whose
  // records were sent to the relay directly; every other node's count waits
  // for the marks that reach it.
  counts({interval_ms, budgets, parked}) {
    const now = performance.now()
    const span = Math.min(interval_ms, TICK_SPAN_MS)
    const {remaining = {}, since = {}} = this.tick ?? {}
    this.tick = {at: now, span, budgets, remaining, since}
    this.lit = new Set([...this.wires.values()].filter(w => (budgets[w.key] ?? 0) > 0).map(w => w.id))
    if (!this.watched()) { return }
    // Still: the wires that carried records are drawn heavier, and nothing moves.
    if (this.reduced.matches) { this.draw(now); return }

    const starts = []
    for (const [id, n] of Object.entries(budgets)) {
      const kind = kindOf(id)
      if (kind === "source" || (kind === "entry" && !this.inTo.get(id)?.length)) {
        if (n > 0) { starts.push([id, n, kind]) }
      } else if (n > 0 && !WIRE_COUNTS.has(kind)) {
        remaining[id] = (remaining[id] ?? 0) + n
        since[id] ??= now
      }
    }
    this.settleOwed(now)

    for (const [id, n, kind] of starts) {
      if (kind === "source") {
        for (const wire of this.outOf.get(id) ?? []) { this.spread(wire, n, now, span) }
      } else {
        this.marksOver(n, now, span, (share, at) => this.handLater(id, share, null, at))
      }
    }
    // Every dead letter is drawn, one mark each.
    const dlq = this.wires.get("relay>dead-letter")
    for (let i = 0; dlq && i < parked; i++) { this.queue(dlq, 1, null, now + (span * i) / parked, "fail") }
    this.wake()
  },

  // A tap's records ride the tapped port's own wires, filled, with the start
  // of their payload while they are few.
  records({port, records, previews}) {
    if (!this.watched() || this.reduced.matches) { return }
    const now = performance.now()
    const wires = kindOf(port) === "entry" ? this.inTo.get(port) ?? [] : this.outOf.get(port) ?? []
    for (let i = 0; i < records && wires.length; i++) {
      this.queue(wires[i % wires.length], 0, null, now + (TAP_FLUSH_MS * i) / records, "tapped", previews[i])
    }
    this.wake()
  },

  spread(wire, count, now, span) {
    if (count <= 0) { return }
    this.marksOver(count, now, span, (share, at) => this.queue(wire, share, wire.entry, at, "counted"))
  },

  // `count` records over the span, sampled to at most four marks a second,
  // each standing for its share.
  marksOver(count, now, span, place) {
    const n = Math.max(1, Math.min(Math.round(count), Math.ceil(marksIn(span))))
    for (let i = 0; i < n; i++) { place(count / n, now + (span * i) / n) }
  },


  queue(wire, weight, entry, at, kind, preview) {
    this.pending.push({wire, weight, entry, at, kind, preview})
  },

  unit(wire) {
    const t = this.tick
    if (!t || !wire.key) { return 1 }
    return Math.max(1, (t.budgets[wire.key] ?? 0) / marksIn(t.span))
  },

  // A streaming wire hands its records on at once and draws its flow; any
  // other carries a mark across in 0.35 to 1.2 seconds, whatever its length.
  launch(item, now) {
    const {wire} = item
    if (wire.mode === "streaming" && item.kind === "counted") { this.handOn(wire.to, item.weight, item.entry, now); return }
    this.marks.push({...item, t0: now, dur: Math.max(350, Math.min(1200, wire.m.len / 0.45))})
    if (!this.launched.has(wire.id)) { this.launched.set(wire.id, now) }
  },

  // `weight` records reach `id`: each outgoing wire takes its share, the
  // share of what it carried against what this node took, as far as the
  // budget of the node it reaches lasts.
  handOn(id, weight, entry, now) {
    const t = this.tick
    if (!t) { return }
    const kind = kindOf(id)
    if (kind === "call") {
      const answer = `answer-${id.slice(5)}`
      this.handLater(answer, weight, entry, now + CALL_MS)
      return
    }
    let outs = this.outOf.get(id) ?? []
    if (kind === "filter" && entry) { outs = outs.filter(w => w.kind === "skip" || !w.entry || w.entry === entry) }
    const counted = outs.filter(w => t.budgets[w.to] !== undefined)
    const own = t.budgets[id] ?? 0
    const of = own > 0 ? own : counted.reduce((sum, w) => sum + this.carried(w), 0)
    const pause = kind === "tasklet" ? TASKLET_PAUSE_MS : kind === "run" ? TASKLET_PAUSE_MS * 2 : 0
    for (const wire of outs) {
      let give = weight
      if (t.budgets[wire.to] !== undefined) {
        // What the next node has not counted yet is owed to it, and handed on
        // when its count arrives, often a tick after this mark's.
        const want = of > 0 && t.budgets[wire.to] > 0 ? (weight * this.carried(wire)) / of : weight
        give = this.take(wire.to, want)
        if (want - give > 0.01) { wire.owed = {weight: (wire.owed?.weight ?? 0) + want - give, entry, at: wire.owed?.at ?? now} }
      }
      this.carryOn(wire, give, wire.entry ?? entry, now + pause)
    }
  },

  // What a wire carried this tick: its own count, else what its node took.
  carried(wire) { return this.tick.budgets[wire.key] ?? this.tick.budgets[wire.to] },

  // Takes up to `want` of a node's budget.
  take(id, want) {
    const t = this.tick
    const left = t.remaining[id] ?? 0
    const give = Math.min(want, left)
    t.remaining[id] = left - give
    if (left - give < 0.5) { delete t.since[id] }
    return give
  },

  carryOn(wire, weight, entry, at) {
    if (weight <= 0) { return }
    wire.carry += weight
    const unit = this.unit(wire)
    while (wire.carry >= unit) {
      wire.carry -= unit
      this.queue(wire, unit, entry, at, "counted")
    }
  },

  // A tick's counts pay what marks already owe the nodes they reached
  // earlier; a debt no count pays within the grace is forgotten.
  settleOwed(now) {
    for (const wire of this.wires.values()) {
      const owed = wire.owed
      if (!owed) { continue }
      const give = this.take(wire.to, owed.weight)
      owed.weight -= give
      this.carryOn(wire, give, owed.entry, now)
      if (owed.weight < 0.01 || now - owed.at > GRACE_MS) { wire.owed = null }
    }
  },

  handLater(id, weight, entry, at) {
    this.pending.push({hand: id, weight, entry, at})
  },

  // A count no mark has reached within the grace is launched as is, on the
  // wires into its node by what each carried, so no count goes undrawn and a
  // quiet input stays quiet.
  flushStale(now) {
    const t = this.tick
    for (const [id, at] of Object.entries(t.since)) {
      if (now - at < GRACE_MS) { continue }
      const left = t.remaining[id] ?? 0
      const into = this.inTo.get(id) ?? []
      delete t.since[id]
      t.remaining[id] = 0
      if (left < 0.5 || !into.length) { continue }
      const shares = into.map(w => this.carried(w) ?? 0)
      const total = shares.reduce((sum, n) => sum + n, 0)
      into.forEach((wire, i) => this.spread(wire, total > 0 ? (left * shares[i]) / total : left / into.length, now, TAP_FLUSH_MS * 2))
    }
  },

  // Back in view: what fell due while nobody could see it is dropped, not
  // launched in one burst.
  resume() {
    const now = performance.now()
    this.pending = this.pending.filter(item => item.at > now)
    this.marks = []
    this.wake()
  },

  // Nothing is queued for a graph nobody can see.
  watched() { return !document.hidden && this.onScreen },

  wake() {
    if (!this.raf && this.watched()) { this.raf = requestAnimationFrame(now => this.frame(now)) }
  },

  frame(now) {
    this.raf = null
    if (!this.watched()) { return }
    if (now - (this.lastFrame ?? 0) < FRAME_MS) { this.wake(); return }
    this.lastFrame = now
    if (this.tick) { this.flushStale(now) }

    const due = this.pending.filter(item => item.at <= now)
    this.pending = this.pending.filter(item => item.at > now)
    for (const item of due) { item.hand ? this.handOn(item.hand, item.weight, item.entry, now) : this.launch(item, now) }

    const landed = this.marks.filter(mark => now - mark.t0 >= mark.dur)
    this.marks = this.marks.filter(mark => now - mark.t0 < mark.dur)
    for (const mark of landed) {
      if (mark.kind === "counted") { this.handOn(mark.wire.to, mark.weight, mark.entry, now) }
    }

    this.draw(now)
    if (this.marks.length || this.pending.length || this.flowing() || Object.keys(this.tick?.since ?? {}).length) { this.wake() }
  },

  flowing() {
    return !this.reduced.matches && !this.backpressure && [...this.wires.values()].some(w => w.mode === "streaming")
  },

  // Everything moving, on the canvas, in the SVG's own coordinates.
  draw(now) {
    const canvas = this.canvas
    if (!canvas || !this.view) { return }
    const dpr = window.devicePixelRatio || 1
    const w = this.el.clientWidth
    const h = this.el.clientHeight
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr)
      canvas.height = Math.round(h * dpr)
    }
    const ctx = canvas.getContext("2d")
    const s = this.scale() * dpr
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.clearRect(0, 0, canvas.width, canvas.height)
    ctx.setTransform(s, 0, 0, s, -this.view.x * s, -this.view.y * s)
    ctx.lineCap = "round"
    ctx.lineJoin = "round"
    const trace = m => { ctx.beginPath(); m.pts.forEach(([x, y], i) => (i ? ctx.lineTo(x, y) : ctx.moveTo(x, y))) }

    if (this.reduced.matches) {
      // Still: a wire that carried records in the last tick is drawn heavier.
      ctx.strokeStyle = this.inks.signal
      ctx.lineWidth = 3
      for (const id of this.lit) { const wire = this.wires.get(id); if (wire) { trace(wire.m); ctx.stroke() } }
      return
    }

    // A stream: a continuous flow, faster and thicker for a higher rate,
    // stepped so it never seems to run backwards; stopped in the warning
    // colour while the runner's channel has no credit.
    for (const wire of this.wires.values()) {
      if (wire.mode !== "streaming") { continue }
      const out = this.backpressure && kindOf(wire.from) === "exit"
      const speed = 60 + 40 * Math.log10(1 + wire.rate)
      const step = Math.floor(((now / 1000) * FLOW_STEPS_A_SECOND))
      ctx.setLineDash([FLOW_DASH, FLOW_PERIOD - FLOW_DASH])
      ctx.lineDashOffset = out ? 0 : -((step / FLOW_STEPS_A_SECOND) * speed) % FLOW_PERIOD
      ctx.strokeStyle = out ? this.inks.warning : this.inks.signal
      ctx.lineWidth = Math.min(5, 1.5 + Math.log10(1 + wire.rate) * 1.6)
      trace(wire.m)
      ctx.stroke()
    }
    ctx.setLineDash([])

    let drawn = 0
    for (const mark of this.marks) {
      if (mark.kind !== "fail" && drawn >= MARKS_DRAWN) { continue }
      drawn++
      const [x, y] = pointAt(mark.wire.m, ((now - mark.t0) / mark.dur) * mark.wire.m.len)
      ctx.beginPath()
      ctx.arc(x, y, 3.5, 0, Math.PI * 2)
      ctx.fillStyle = mark.kind === "tapped" ? this.inks.signal : mark.kind === "fail" ? this.inks.fail : this.inks.surface
      ctx.fill()
      ctx.lineWidth = 1.75
      ctx.strokeStyle = mark.kind === "fail" ? this.inks.fail : this.inks.signal
      ctx.stroke()
      if (mark.preview) {
        ctx.font = this.inks.mono
        ctx.fillStyle = this.inks.text
        ctx.textAlign = "center"
        ctx.fillText(mark.preview, x, y - 9)
      }
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
