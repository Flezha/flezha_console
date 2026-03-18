---
name: Theme redesign — Option B implemented
description: Full visual redesign to "Clean Dashboard" style with CSS custom properties for day/night mode, purple accent
type: project
---

Option B "Clean Dashboard" redesign implemented (2026-03-18).

**What changed:**
- All colors now use CSS custom properties defined in `assets/css/app.css`
- `:root` = night (dark) mode, `.light` = day (light) mode
- Purple accent (`#7c3aed`) replaces orange (`#FD4F00`) everywhere
- Tailwind config maps semantic tokens (surface, accent, brd, th, etc.) to CSS vars
- Theme toggle button (sun icon) in top bar, persists to localStorage
- All templates use semantic classes (bg-surface, text-th-primary, border-brd, etc.)
- rounded-xl/rounded-panel corners, backdrop-blur-sm modals, shadow-panel cards
- All 96 tests pass, all data-testid attributes preserved

**Why:** User chose Option B for its spacious, refined feel (Vercel/Linear-like). Purple accent preferred.

**How to apply:** To adjust colors, edit CSS variables in `assets/css/app.css`. To change accent, modify `--color-accent` and related vars. All page templates and core_components.ex use the semantic Tailwind classes, so no per-file changes needed for color tweaks.
