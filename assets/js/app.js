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
// trigger's right edge when it is an end-aligned menu.
function placePop(pop) {
  const panel = popPanel(pop)
  const rect = popTrigger(pop).getBoundingClientRect()
  const end = panel.matches(".fui-popover--end, .right-0")
  // Every side is set, so no stylesheet offset is left to apply against the
  // viewport.
  Object.assign(panel.style, {position: "fixed", top: "auto", bottom: "auto", left: "auto", right: "auto", marginTop: "0"})
  if (pop.closest(".fui-combobox")) { panel.style.minWidth = `${rect.width}px` }
  if (end) { panel.style.right = `${document.documentElement.clientWidth - rect.right}px` }
  else { panel.style.left = `${rect.left}px` }
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
// dialog or drawer.

let pendingG = 0

document.addEventListener("keydown", event => {
  if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey) { return }
  if (typing(event.target) || document.querySelector("dialog[open], [aria-modal='true']")) { return }

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
// controller page has no socket, so its toasts are dismissed here.

const deadToast = el => !el.closest("[data-phx-session]")

document.addEventListener("click", event => {
  const dismiss = event.target.closest("[data-toast-dismiss]")
  if (dismiss && deadToast(dismiss)) { dismiss.closest(".fui-toast").hidden = true }
})

for (const toast of document.querySelectorAll('.fui-toast[data-kind="info"]')) {
  if (deadToast(toast)) { setTimeout(() => { toast.hidden = true }, 5000) }
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
    this.timer = setTimeout(() => this.el.querySelector("[data-toast-dismiss]")?.click(), 5000)
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
      if (typing(event.target)) { return }
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
