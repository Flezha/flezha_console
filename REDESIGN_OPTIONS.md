# FlezhaUI Visual Redesign — Options

> Pick one direction (A, B, or C) or mix elements from several. Once you choose, we'll detail every component.

## Interactive Sketches (open in browser)

All sketches have **Day/Night toggle** and use **purple accent** colors.

- **[Option A — Mission Control](design/option_a_mission_control.html)** — Dense, utilitarian, icon sidebar, status bar, drawer modals
- **[Option B — Clean Dashboard](design/option_b_clean_dashboard.html)** — Spacious, refined, full sidebar, centered blur modals
- **[Option C — Neon Operator](design/option_c_neon_operator.html)** — Top nav (no sidebar), glow effects, terminal aesthetic

Each file shows: Dashboard view + Processor detail view + Stream viewer + Modal form

---

## Current State Summary

- Dark zinc theme, orange `#FD4F00` accent
- Fixed left sidebar (w-56) + top header bar + content area
- Tables, cards, modals — all Tailwind utility classes, no custom CSS
- Pages: Dashboard, Namespaces (list/show), Processor detail, Plugins, Stream Viewer, Auth

---

## Option A — "Mission Control"

**Vibe:** NASA flight-control room. Dense, information-rich, utilitarian. Every pixel earns its place.

### Color Palette

| Role           | Token              | Value        |
|----------------|--------------------|--------------|
| Base BG        | `--bg-base`        | `#0B0E14`    |
| Surface        | `--bg-surface`     | `#111620`    |
| Surface raised | `--bg-raised`      | `#1A1F2E`    |
| Border         | `--border`         | `#252D3D`    |
| Text primary   | `--text-1`         | `#E6EDF3`    |
| Text secondary | `--text-2`         | `#8B949E`    |
| Accent         | `--accent`         | `#3B82F6`    |
| Accent hover   | `--accent-hover`   | `#60A5FA`    |
| Success        | `--success`        | `#22C55E`    |
| Warning        | `--warning`        | `#EAB308`    |
| Danger         | `--danger`         | `#EF4444`    |

Deep navy-ink background. Blue accent instead of orange. Cooler, calmer.

### Layout Sketch

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ▸ flezha                      [node: flezha@agent ●]    user@  Settings │  <- slim top bar (h-10)
├────────┬─────────────────────────────────────────────────────────────────┤
│ DASH   │                                                                │
│ NS     │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐              │
│ PLUG   │  │ Namespaces  │ │ Processors  │ │ Plugins     │              │
│        │  │     3       │ │     12      │ │     8       │  <- stat     │
│        │  └─────────────┘ └─────────────┘ └─────────────┘    cards     │
│        │                                                                │
│        │  ┌──────────────────────────────────────────────────────────┐  │
│        │  │ COMPUTE ENGINES                                    [+]  │  │
│        │  ├──────┬────────────┬──────────┬──────────────────────────┤  │
│        │  │ ID   │ Namespace  │ Status   │ Uptime                   │  │
│        │  ├──────┼────────────┼──────────┼──────────────────────────┤  │
│        │  │ ce1  │ default    │ ● alive  │ 3h 21m                   │  │
│        │  │ ce2  │ default    │ ● alive  │ 1h 04m                   │  │
│        │  └──────┴────────────┴──────────┴──────────────────────────┘  │
│        │                                                                │
│ v0.4.1 │  ┌─ NAMESPACES ─────────────────────────────────────────────┐  │
│        │  │  [ default ]  [ staging ]  [ prod ]                      │  │
│        │  └──────────────────────────────────────────────────────────┘  │
├────────┴─────────────────────────────────────────────────────────────────┤
│ ◆ Connected  │  3 ns  │  12 proc  │  8 plug                    14:22:07│  <- status bar (h-7)
└──────────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

- **Collapsed sidebar (w-14)** — icon-only by default, expands on hover to w-48. Maximises content area.
- **Status bar at the bottom** — persistent connection state, quick counts, clock. Like a terminal or IDE.
- **Stat cards** are compact boxes with large number + small label. No decorative borders — just subtle bg difference.
- **Tables** have tight row height (h-8), monospace IDs, row-hover highlights in `--bg-raised`.
- **Modals** slide in from the right as panels (drawer style), not centered overlays. Feels more integrated.
- **Stream viewer** looks like a terminal: black bg, green monospace text, scrolling log lines.
- **Buttons** are small, pill-shaped, blue accent. Danger actions are red text-only until confirmed.
- **No rounded-xl anywhere** — `rounded-md` max. Sharp, technical feel.

### Typography

- Headings: Inter (or system sans-serif), semibold, uppercase tracking-wider for section labels
- Body: Inter, regular, text-sm
- Data/IDs: JetBrains Mono (or monospace), text-xs

---

## Option B — "Clean Dashboard"

**Vibe:** Vercel/Linear. Refined, spacious, elegant dark mode. Fewer elements, more breathing room.

### Color Palette

| Role           | Token              | Value        |
|----------------|--------------------|--------------|
| Base BG        | `--bg-base`        | `#0A0A0A`    |
| Surface        | `--bg-surface`     | `#141414`    |
| Surface raised | `--bg-raised`      | `#1C1C1C`    |
| Border         | `--border`         | `#2A2A2A`    |
| Text primary   | `--text-1`         | `#FAFAFA`    |
| Text secondary | `--text-2`         | `#A1A1AA`    |
| Accent         | `--accent`         | `#FD4F00`    |
| Accent hover   | `--accent-hover`   | `#FF6B2B`    |
| Success        | `--success`        | `#10B981`    |
| Warning        | `--warning`        | `#F59E0B`    |
| Danger         | `--danger`         | `#F43F5E`    |

Pure blacks and neutrals. Keeps the orange brand accent. Warmer feel.

### Layout Sketch

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   flezha                                                                 │
│                                                                          │
│   Dashboard                                                  user@  ⚙   │
│   Namespaces                                                             │
│   Plugins             ┌──────────────────────────────────────────────┐   │
│                       │                                              │   │
│                       │   Dashboard                                  │   │
│                       │                                              │   │
│                       │   ┌──────────┐  ┌──────────┐  ┌──────────┐  │   │
│                       │   │          │  │          │  │          │   │   │
│                       │   │  3       │  │  12      │  │  8       │   │   │
│                       │   │  spaces  │  │  procs   │  │  plugins │   │   │
│                       │   │          │  │          │  │          │   │   │
│                       │   └──────────┘  └──────────┘  └──────────┘  │   │
│                       │                                              │   │
│                       │   Compute Engines                            │   │
│                       │   ──────────────────────────────────────────  │   │
│                       │   ce-abc123     default     ● running        │   │
│                       │   ──────────────────────────────────────────  │   │
│                       │   ce-def456     default     ● running        │   │
│                       │   ──────────────────────────────────────────  │   │
│                       │                                              │   │
│                       │   Namespaces                                 │   │
│                       │   ┌────────────────┐ ┌────────────────┐      │   │
│                       │   │   default   →  │ │   staging   →  │      │   │
│                       │   └────────────────┘ └────────────────┘      │   │
│                       │                                              │   │
│   v0.4.1              └──────────────────────────────────────────────┘   │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

- **Full sidebar (w-56)** stays visible. Navigation text always readable. Similar to current layout but refined.
- **Content area has a visible card** — `bg-surface` panel with subtle border and shadow, inset from the page bg. Creates depth.
- **No top header bar.** User info lives in the sidebar bottom, node status is a badge in the sidebar top. Cleaner horizontal space.
- **Tables are borderless** — rows separated by thin divider lines only. No cell borders. Hover lifts row background.
- **Stat cards** are tall, padded (p-6), with the number large (text-3xl) and label small below.
- **Modals** are centered overlays with backdrop blur (`backdrop-blur-sm`). Rounded-xl, generous padding.
- **Stream viewer** white-on-dark with a softer green (#10B981), each message is a card with timestamp badge.
- **Spacing is generous** — `gap-6` between cards, `p-8` content padding, `space-y-8` sections.
- **Rounded corners everywhere** — `rounded-xl` on cards/modals, `rounded-lg` on buttons/inputs.
- **Animations:** Fade-in on page load, slide-up on modal open, smooth transitions on hover states.

### Typography

- Headings: Inter, medium weight, normal case (no uppercase labels)
- Body: Inter, regular, text-sm
- Data/IDs: Fira Code (or monospace), text-xs, slightly dimmed

---

## Option C — "Neon Operator"

**Vibe:** Cyberpunk dev tools. High contrast, glowing accents, terminal aesthetic with modern polish.

### Color Palette

| Role           | Token              | Value        |
|----------------|--------------------|--------------|
| Base BG        | `--bg-base`        | `#0D0D0D`    |
| Surface        | `--bg-surface`     | `#151515`    |
| Surface raised | `--bg-raised`      | `#1E1E1E`    |
| Border         | `--border`         | `#2D2D2D`    |
| Text primary   | `--text-1`         | `#E0E0E0`    |
| Text secondary | `--text-2`         | `#777777`    |
| Accent         | `--accent`         | `#00FF9F`    |
| Accent dim     | `--accent-dim`     | `#00CC7F`    |
| Secondary      | `--secondary`      | `#BD93F9`    |
| Success        | `--success`        | `#50FA7B`    |
| Warning        | `--warning`        | `#F1FA8C`    |
| Danger         | `--danger`         | `#FF5555`    |

Black base. Neon green accent. Purple secondary for differentiation.

### Layout Sketch

```
┌──────────────────────────────────────────────────────────────────────────┐
│  ┌──┐ ┌──┐ ┌──┐                            ● flezha@agent    user@ [⚙] │
│  │DS│ │NS│ │PL│                                                         │
│  └──┘ └──┘ └──┘                                                         │
├──────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ╔══════════════╗  ╔══════════════╗  ╔══════════════╗                    │
│  ║   3          ║  ║   12         ║  ║   8          ║                    │
│  ║   NAMESPACES ║  ║   PROCESSORS ║  ║   PLUGINS    ║                    │
│  ╚══════════════╝  ╚══════════════╝  ╚══════════════╝                    │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │ > COMPUTE ENGINES                                                  │  │
│  │ ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ │  │
│  │   ce-abc123    default    ● active    3h 21m                       │  │
│  │   ce-def456    default    ● active    1h 04m                       │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │ > NAMESPACES                                                       │  │
│  │   ┌────────────┐  ┌────────────┐  ┌────────────┐                  │  │
│  │   │  default   │  │  staging   │  │  prod      │                  │  │
│  │   │  ● 4 proc  │  │  ● 3 proc  │  │  ● 5 proc  │                  │  │
│  │   └────────────┘  └────────────┘  └────────────┘                  │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  [status: connected]─────────────────────────────[3 ns │ 12 pr │ 8 pl]  │
└──────────────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

- **Top horizontal nav** instead of sidebar. Navigation is 3 pill-shaped tabs. Frees all horizontal space for content.
- **No sidebar at all.** Full-width content. Better for wide tables and the stream viewer.
- **Stat cards have glow** — `box-shadow: 0 0 20px rgba(0, 255, 159, 0.08)` on the accent color. Subtle neon bleed.
- **Section headers use `>` prefix** — terminal-style. `> COMPUTE ENGINES`
- **Tables have dashed separators** (border-dashed) not solid lines. Lighter feel.
- **Namespace cards** show inline stats (processor count + status dot). Click to navigate.
- **Modals** have a thin accent-colored top border (`border-t-2 border-accent`). Slide up from bottom.
- **Stream viewer** is full-width, terminal black, green monospace text with timestamps in purple (secondary color).
- **Buttons** have subtle glow on hover. Primary buttons are outlined (`border border-accent text-accent`) not filled.
- **Active nav tab** gets an underline glow effect.
- **Status bar** at bottom — thin, with connection status and counts.

### Typography

- Headings: Space Grotesk (or system sans), bold, uppercase
- Body: Inter, regular, text-sm
- Data/IDs/Everything code: JetBrains Mono, text-xs
- Section labels: monospace, uppercase, prefixed with `>`

---

## Comparison Matrix

| Aspect              | A — Mission Control          | B — Clean Dashboard          | C — Neon Operator            |
|---------------------|------------------------------|------------------------------|------------------------------|
| **Nav style**       | Collapsible icon sidebar     | Fixed text sidebar           | Top horizontal tabs          |
| **Density**         | High — tight rows, compact   | Low — generous spacing       | Medium                       |
| **Accent color**    | Blue `#3B82F6`               | Orange `#FD4F00` (current)   | Neon green `#00FF9F`         |
| **Background**      | Navy-ink `#0B0E14`           | Pure black `#0A0A0A`         | Black `#0D0D0D`              |
| **Corner radius**   | Minimal (rounded-md)         | Large (rounded-xl)           | Medium (rounded-lg)          |
| **Modal style**     | Right-side drawer            | Centered overlay + blur      | Bottom slide-up + glow       |
| **Tables**          | Bordered, tight, colored hdr | Borderless, divider lines    | Dashed separators            |
| **Stream viewer**   | Terminal (black+green)       | Softer cards per message     | Terminal (black+green+purple)|
| **Status bar**      | Yes (bottom)                 | No                           | Yes (bottom)                 |
| **Animation**       | Minimal                      | Smooth fade/slide            | Glow transitions             |
| **Personality**     | Utilitarian, technical       | Refined, modern              | Expressive, cyberpunk        |
| **Closest to**      | Grafana, k9s                 | Vercel, Linear               | Warp terminal, Fig           |

---

## Shared Improvements (Apply Regardless of Option)

These are independent of which visual direction you pick:

1. **CSS custom properties for theming** — define all colors as CSS variables so switching themes or adding light mode later is trivial.
2. **Component extraction** — move repeated patterns (stat card, data table, modal shell, status badge) into reusable `core_components.ex` function components.
3. **Consistent button system** — primary, secondary, danger, ghost variants defined once, used everywhere. No more inline `style=` attributes.
4. **Responsive breakpoints** — sidebar collapses on `md:` and below, tables scroll horizontally, stat grid goes 1-col on mobile.
5. **Loading states** — skeleton placeholders for cards/tables while ERPC calls resolve.
6. **Keyboard shortcuts** — `?` opens help, `g d` goes to dashboard, `g n` to namespaces, `g p` to plugins.
7. **Toast notifications** — replace flash messages with auto-dismissing toasts (bottom-right).

---

## What I Need From You

1. **Pick A, B, or C** (or "A's layout with C's colors" etc.)
2. **Any elements you want to keep from the current design?** (e.g., orange accent, sidebar, specific card layouts)
3. **Any pages that need special attention?** (stream viewer is very different from the others — should it get its own layout?)
4. **Density preference?** Do you want to see more data at once (A) or prefer breathing room (B)?

Once you decide, I'll create a detailed component spec and start implementation.
