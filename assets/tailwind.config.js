// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration

const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/flezha_ui_web.ex",
    "../lib/flezha_ui_web/**/*.*ex"
  ],
  theme: {
    extend: {
      colors: {
        brand: "var(--color-accent)",
        surface: {
          base: "var(--color-bg-base)",
          DEFAULT: "var(--color-bg-surface)",
          hover: "var(--color-bg-surface-hover)",
          input: "var(--color-bg-input)",
        },
        th: {
          primary: "var(--color-text-primary)",
          secondary: "var(--color-text-secondary)",
          tertiary: "var(--color-text-tertiary)",
          muted: "var(--color-text-muted)",
        },
        accent: {
          DEFAULT: "var(--color-accent)",
          hover: "var(--color-accent-hover)",
          text: "var(--color-accent-text)",
          subtle: "var(--color-accent-subtle)",
        },
        brd: {
          DEFAULT: "var(--color-border)",
          subtle: "var(--color-border-subtle)",
          input: "var(--color-border-input)",
          focus: "var(--color-border-focus)",
        },
        sidebar: {
          bg: "var(--color-sidebar-bg)",
          border: "var(--color-sidebar-border)",
          hover: "var(--color-sidebar-hover)",
          active: "var(--color-sidebar-active)",
        },
        modal: {
          bg: "var(--color-modal-bg)",
          border: "var(--color-modal-border)",
        },
        badge: {
          bg: "var(--color-badge-bg)",
          text: "var(--color-badge-text)",
        },
        success: "var(--color-success)",
        danger: {
          DEFAULT: "var(--color-danger)",
          hover: "var(--color-danger-hover)",
          text: "var(--color-danger-text)",
        },
        warning: "var(--color-warning)",
        code: "var(--color-code-text)",
      },
      borderRadius: {
        panel: "var(--radius-panel)",
        modal: "var(--radius-modal)",
      },
      boxShadow: {
        panel: "var(--shadow-panel)",
        modal: "var(--shadow-modal)",
        "panel-hover": "var(--shadow-panel-hover)",
        "btn-hover": "var(--shadow-btn-hover)",
        "btn-active": "0 1px 4px rgba(0, 0, 0, 0.2)",
      },
      backgroundColor: {
        overlay: "var(--color-bg-overlay)",
      },
      animation: {
        "fade-in": "fade-in 300ms ease-out both",
        "fade-in-up": "fade-in-up 400ms ease-out both",
        "scale-in": "scale-in 200ms ease-out both",
        "pulse-dot": "pulse-dot 2s ease-in-out infinite",
      },
      keyframes: {
        "fade-in": {
          from: { opacity: "0", transform: "translateY(8px)" },
          to: { opacity: "1", transform: "translateY(0)" },
        },
        "fade-in-up": {
          from: { opacity: "0", transform: "translateY(12px)" },
          to: { opacity: "1", transform: "translateY(0)" },
        },
        "scale-in": {
          from: { opacity: "0", transform: "scale(0.95)" },
          to: { opacity: "1", transform: "scale(1)" },
        },
        "pulse-dot": {
          "0%, 100%": { opacity: "1" },
          "50%": { opacity: "0.5" },
        },
      },
      transitionTimingFunction: {
        "out-expo": "cubic-bezier(0.16, 1, 0.3, 1)",
      },
    },
  },
  plugins: [
    require("@tailwindcss/forms"),
    // Allows prefixing tailwind classes with LiveView classes to add rules
    // only when LiveView classes are applied, for example:
    //
    //     <div class="phx-click-loading:animate-ping">
    //
    plugin(({addVariant}) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({addVariant}) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({addVariant}) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),

    // Embeds Heroicons (https://heroicons.com) into your app.css bundle
    // See your `CoreComponents.icon/1` for more information.
    //
    plugin(function({matchComponents, theme}) {
      let iconsDir = path.join(__dirname, "../deps/heroicons/optimized")
      let values = {}
      let icons = [
        ["", "/24/outline"],
        ["-solid", "/24/solid"],
        ["-mini", "/20/solid"],
        ["-micro", "/16/solid"]
      ]
      icons.forEach(([suffix, dir]) => {
        fs.readdirSync(path.join(iconsDir, dir)).forEach(file => {
          let name = path.basename(file, ".svg") + suffix
          values[name] = {name, fullPath: path.join(iconsDir, dir, file)}
        })
      })
      matchComponents({
        "hero": ({name, fullPath}) => {
          let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
          let size = theme("spacing.6")
          if (name.endsWith("-mini")) {
            size = theme("spacing.5")
          } else if (name.endsWith("-micro")) {
            size = theme("spacing.4")
          }
          return {
            [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
            "-webkit-mask": `var(--hero-${name})`,
            "mask": `var(--hero-${name})`,
            "mask-repeat": "no-repeat",
            "background-color": "currentColor",
            "vertical-align": "middle",
            "display": "inline-block",
            "width": size,
            "height": size
          }
        }
      }, {values})
    })
  ]
}
