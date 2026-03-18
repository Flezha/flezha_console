// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//

// Theme: restore saved preference
const htmlEl = document.getElementById("html-root")
if (htmlEl) {
  const saved = localStorage.getItem("theme")
  if (saved === "light") htmlEl.classList.add("light")
}

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// Hooks
let Hooks = {}

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

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#8B5CF6"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Sidebar active link highlighting
function highlightActiveNav() {
  const path = window.location.pathname
  document.querySelectorAll("[data-nav-link]").forEach(link => {
    const href = link.getAttribute("href")
    const isActive = href === "/" ? path === "/" : path.startsWith(href)
    if (isActive) {
      link.classList.add("bg-sidebar-active", "text-accent-text", "border-l-2", "border-accent")
      link.classList.remove("text-th-secondary")
    } else {
      link.classList.remove("bg-sidebar-active", "text-accent-text", "border-l-2", "border-accent")
      link.classList.add("text-th-secondary")
    }
  })
}
highlightActiveNav()
window.addEventListener("phx:page-loading-stop", highlightActiveNav)

// Smooth theme toggle
window.toggleTheme = function() {
  const htmlEl = document.getElementById("html-root")
  if (!htmlEl) return
  htmlEl.classList.add("transitioning")
  htmlEl.classList.toggle("light")
  localStorage.setItem("theme", htmlEl.classList.contains("light") ? "light" : "dark")
  setTimeout(() => htmlEl.classList.remove("transitioning"), 250)
}
