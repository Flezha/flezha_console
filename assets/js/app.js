// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {bindThemeToggles} from "@flezha/stylebook/js/theme.js"
import {initTabs} from "@flezha/stylebook/js/tabs.js"
import {initDropdowns} from "@flezha/stylebook/js/dropdown.js"

// Hooks
let Hooks = {}

// A dropdown can appear with any LiveView update, not only a navigation, so it
// wires itself on mount rather than being swept for afterwards.
Hooks.FlzDropdown = {
  mounted() { initDropdowns(this.el) },
  updated() { initDropdowns(this.el) }
}

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
      if (this.typing(event.target)) { return }
      event.preventDefault()
      this.pushEventTo(this.el, "open", {})
    }
    window.addEventListener("keydown", this.onKeydown)
  },
  updated() {
    const input = this.el.querySelector(".flz-palette-input")
    if (input && document.activeElement !== input) { input.focus() }
  },
  destroyed() { window.removeEventListener("keydown", this.onKeydown) },
  typing(el) {
    return !!el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable)
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

// Progress bar on live navigation and form submits. Its colours are read from
// the live theme rather than hard-coded, and re-read when the theme flips.
const token = name =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim()

function configureTopbar() {
  topbar.config({barColors: {0: token("--brand-solid")}, shadowColor: token("--purple-chrome")})
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

initTabs()
bindThemeToggles()
// The account menu also hangs in the shell of the plain controller pages, which
// have no LiveView to run the FlzDropdown hook for them.
initDropdowns()

// Re-binding is idempotent: the DOM ignores a listener already registered with
// the same function reference, toggleTheme is module-level, and initDropdowns
// skips a container it has already wired. The sidebar's current destination is
// marked server-side, so nothing else to re-run here.
window.addEventListener("phx:page-loading-stop", () => {
  bindThemeToggles()
  initDropdowns()
})
