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

// Re-binding is idempotent: the DOM ignores a listener already registered with
// the same function reference, and toggleTheme is module-level. The sidebar's
// current destination is marked server-side, so nothing else to re-run here.
window.addEventListener("phx:page-loading-stop", () => bindThemeToggles())
