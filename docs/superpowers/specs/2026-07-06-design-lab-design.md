# Design: SessionSwitch Design Lab

**Date:** 2026-07-06
**Status:** Approved (approach C, 10 variants)

## Goal

A browsable gallery of 10 fully interactive UI design variants for SessionSwitch
(per PRD.md), served from one localhost port. Each variant renders all three
product surfaces — menu bar dropdown, floating per-window badge, and global
hotkey quick picker — in a distinct visual identity. The user browses the hub,
plays with each variant, and picks the design direction for the real macOS app.

## Non-Goals

- No real session detection, injection, or macOS integration. All data is fake.
- No framework, no build step, no npm dependencies. Static files only.
- Not production frontend code; this is a design-selection artifact.

## Architecture (Approach C — Hybrid Engine)

Zero-build static site. Plain HTML + CSS + ES modules.

```
design-lab/
  index.html            # hub gallery
  hub.css
  hub.js
  shared/
    data.js             # fake sessions, model catalog, presets
    engine.js           # headless state store + interaction logic (pub/sub)
    scaffold.js         # default DOM builders for the 3 surfaces + fake desktop
    engine.test.mjs     # assert-based self-check, runs under `node`
  variants/
    01-cupertino-glass/   index.html  style.css
    02-terminal-brutalist/ …
    03-cyberpunk-hud/      …
    04-system-7/           …
    05-swiss-minimal/      …
    06-synthwave-arcade/   …
    07-eink-paper/         …
    08-avionics-cockpit/   …
    09-blueprint/          …
    10-clay-pop/           …
```

Serve with `python3 -m http.server 4400` from `design-lab/` (ES modules require
http, not file://). No other tooling.

### shared/data.js

- **Sessions (6):** realistic project dirs (`~/work/api-gateway`,
  `~/oss/zig-parser`, etc.) spread across Terminal.app, iTerm2, VS Code,
  JetBrains. States: idle / working / awaiting-permission. One session is
  read-only (SSH remote) per FR-5.
- **Model catalog:** Fable 5, Opus 4.8, Sonnet 5, Haiku 4.5 with aliases and
  per-model supported effort levels (Haiku: none; others: low/medium/high, Fable
  adds max). Mirrors FR-11/FR-12 shape.
- **Presets (3):** Deep Work (Fable 5 + high), Balanced (Sonnet 5 + medium),
  Cheap & Fast (Haiku 4.5).

### shared/engine.js

Headless store. No DOM. API:

- `getState()` / `subscribe(fn)` — pub/sub snapshot of sessions + catalog + presets.
- `applyModel(sessionId, modelId)`, `applyEffort(sessionId, level)`,
  `applyPreset(sessionId, presetId)` — each sets a `pending` flag, then after a
  short fake latency resolves to `verified` (or `clamped` for one scripted case,
  mirroring FR-9/FR-35: requesting `max` on Opus clamps to `high` with reason
  "limited by org policy").
- Invalid model+effort combos rejected with the fallback level reported (FR-12).
- Read-only sessions reject all applies with reason (FR-5).
- Ambient simulation: a ticker randomly flips sessions between idle/working so
  every variant feels alive.

### shared/scaffold.js

Default DOM builders with stable class hooks (`ss-menubar`, `ss-dropdown`,
`ss-row`, `ss-chip-model`, `ss-chip-effort`, `ss-badge`, `ss-picker`, …):

- `buildDesktop()` — fake macOS desktop: top menu bar with SessionSwitch icon,
  two overlapping fake terminal windows (so badges have something to dock to).
- `buildDropdown()`, `buildBadge(session)`, `buildPicker()` — semantic skeletons
  wired to engine.
- Variants call these for free parity, and may override any builder with custom
  DOM (System 7 windows, cockpit dials) as long as they call the same engine API.

### Interactions (identical in every variant, via engine)

- Model chip click → model submenu → click applies (FR-16).
- Effort chip click → cycles valid levels; right-click/long-press opens level menu.
- Session row click → "focuses" its fake terminal window (raises z-index) (FR-18).
- Badge click → expands to compact picker: models | efforts | presets (FR-21).
- `⌘K` (in-page) → quick picker: type to filter, ↑/↓ navigate, Tab cycles
  model/effort/preset mode, Enter applies, Esc closes (FR-24–27). Defaults to
  frontmost fake terminal's session.
- Pending state renders as pulsing outline until verified (UX notes §8).
- Effort shown with ▁▃▅▇ bars glyph language, restyled per variant.

## Hub

- Grid of 10 cards; each card is a live scaled-down iframe of the variant plus
  name + one-line vibe.
- Click card → variant opens fullscreen (navigation, not overlay). Esc or "← Lab"
  chrome returns to hub. ←/→ keys cycle variants; digits 1–0 jump.
- Hub itself gets a neutral dark identity so it doesn't bias the vote.

## Variant Creative Briefs

| # | Name | Palette / Type | Signature moves |
|---|------|----------------|-----------------|
| 1 | Cupertino Glass | Translucent vibrancy blur, SF-ish system sans, hairline separators | Real macOS menu geometry; badge = frosted pill; picker = Spotlight clone; subtle spring animations |
| 2 | Terminal Brutalist | Phosphor green on near-black, single mono font, ASCII box-drawing borders | Dropdown renders as a TUI table; effort bars are literal `▁▃▅▇` glyphs; blinking block cursor; CRT flicker on apply |
| 3 | Cyberpunk HUD | Neon cyan/magenta on deep navy, angular clip-path corners, wide grotesk + mono data | Scanline overlay; chips are hexagonal-cut tags; apply = glitch flash; picker frames sessions like target lock-ons |
| 4 | System 7 | 1-bit black/white, Chicago-style pixel font, dithered patterns | Dropdown is a classic Mac window with stripes title bar; radio buttons + checkboxes; badge = tiny WindowShade; alert-style clamp dialog |
| 5 | Swiss Minimal | White, near-black, one red accent; Helvetica-class grotesk; strict 8pt grid | Typography-only hierarchy, no boxes; effort as thin rule weights; picker is an editorial index page; instant no-animation switches |
| 6 | Synthwave Arcade | Sunset gradient (magenta→orange), chrome/neon display type, star grid horizon | Badge = arcade token; apply triggers neon pulse down the row; picker styled as high-score table; VHS tracking artifact on clamp |
| 7 | E-Ink Paper | Warm paper, ink grays, serif headings + humanist sans body | Soft paper-grain texture; page-turn micro-transitions; chips as rubber-stamped labels; calm, zero glow |
| 8 | Avionics Cockpit | Charcoal panel, amber/green instrument phosphor, stencil + mono type | Effort = analog gauge dial per session; model = rotary selector; states as annunciator lights (IDLE/WORK/HOLD); clamp = amber CAUTION strip |
| 9 | Blueprint | Blueprint blue background, white/cyan line work, drafting annotations | Everything drawn as technical schematic: dimension lines, section labels (A-A'), title block footer; picker = parts list; dashed pending outlines |
| 10 | Clay Pop | Pastel candy palette, chunky rounded claymorphism, friendly rounded sans | Squishy press animations, blob shadows; effort as stacked clay bars; badge = jelly button; confetti micro-burst on verified apply |

Every variant must pass the same checklist: 3 surfaces present, all engine
interactions work, pending/verified/clamped states visible, read-only session
distinguishable, keyboard flow in picker complete.

## Error Handling

Mockup scope: engine rejects invalid combos and read-only applies with reasons;
variants must surface these (toast, dialog, annunciator — per identity). No
other error surface needed.

## Testing

- `node design-lab/shared/engine.test.mjs` — assert-based checks: apply/verify
  flow, clamp case, invalid-combo fallback, read-only rejection, preset apply.
- Manual: per-variant checklist above, walked in the hub.

## Success Criteria

1. `python3 -m http.server 4400` in `design-lab/` → hub at `localhost:4400`.
2. All 10 variants interactive, all 3 surfaces, behavior identical (engine parity).
3. Engine self-test passes under plain `node`.
4. User can pick a favorite from the hub.
