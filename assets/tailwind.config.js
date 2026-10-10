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
      // Every alias resolves to a flezha_stylebook token, so the utility
      // classes already spread across these templates inherit the brand
      // palette without being rewritten one by one. `th-brand` is the brand
      // ink, `--text-brand`; `brand` is the fill, never a text colour.
      // `font-mono` / `font-sans` land on the self-hosted faces, so the
      // hundred-odd existing utility usages pick up JetBrains Mono and Inter
      // without being rewritten.
      fontFamily: {
        sans: "var(--font-body)",
        mono: "var(--font-mono)",
        display: "var(--font-display)",
      },
      colors: {
        brand: "var(--brand-solid)",
        surface: {
          base: "var(--surface-base)",
          DEFAULT: "var(--surface-raised)",
          hover: "var(--surface-hover)",
          input: "var(--surface-sunken)",
        },
        th: {
          primary: "var(--text-primary)",
          secondary: "var(--text-secondary)",
          muted: "var(--text-muted)",
          brand: "var(--text-brand)",
        },
        brd: {
          DEFAULT: "var(--border-default)",
          subtle: "var(--border-subtle)",
          input: "var(--border-default)",
          focus: "var(--brand-solid)",
        },
        success: "var(--positive)",
        danger: {
          DEFAULT: "var(--negative)",
          text: "var(--negative)",
        },
        warning: "var(--warning)",
      },
      // Radius stays literal, per the stylebook: 6px controls, 8px cards,
      // 12px large surfaces. Tailwind's own md/lg/xl already are those.
      boxShadow: {
        sm: "var(--shadow-sm)",
        DEFAULT: "var(--shadow-md)",
        md: "var(--shadow-md)",
        lg: "var(--shadow-lg)",
      },
    },
  },
  plugins: [
    // No @tailwindcss/forms: the stylebook's base.css is the form baseline,
    // and the plugin's `[type='text']` selectors would outrank its
    // zero-specificity `:where()` rules and re-declare the same properties.
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
