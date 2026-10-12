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
      // Utilities carry layout and spacing only; colour, borders and type
      // come from the console's kit. `font-mono` / `font-sans` land on the
      // console's own faces for the few places a utility sets them.
      fontFamily: {
        sans: "var(--fui-font-sans)",
        mono: "var(--fui-font-mono)",
        display: "var(--fui-font-display)",
      },
      // The size utilities a template reaches for land on the console's own
      // type scale, so a `text-xs` hint is as legible as the kit's.
      fontSize: {
        xs: "var(--fui-text-xs)",
        sm: "var(--fui-text-sm)",
        base: "var(--fui-text-md)",
        lg: "var(--fui-text-lg)",
        xl: "var(--fui-text-xl)",
      },
    },
  },
  plugins: [
    // No @tailwindcss/forms: the console's base.css is the form baseline,
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
