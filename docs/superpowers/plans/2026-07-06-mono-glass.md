# Mono Glass (Variant 11) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add variant 11 "Mono Glass" to the design lab: the Cupertino Glass direction reworked as dark-mode black & white glass with sparse color accents, plus a live animated glyph-rain background.

**Architecture:** Same pure-reskin pattern as variants 01–10 (scaffold-owned DOM, per-variant style.css) plus one variant-local `fx.js` that injects a background layer of falling ASCII glyph columns; all motion lives in CSS so reduced-motion is handled in one place. Variant 01 (colorful glass) stays untouched for side-by-side comparison.

**Tech Stack:** Plain HTML/CSS/ES modules. No build, no deps.

## Global Constraints

- No external network resources; system font stacks only (UI: `-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif`; rain: `ui-monospace, 'SF Mono', Menlo, monospace`).
- No framework/build/package.json.
- Frozen ss-* class-hook contract (see `.superpowers/sdd/task-3-brief.md` "Class-hook contract"); scaffold.js and structure.css are read-only.
- Variant CSS contract + acceptance checklist: `.superpowers/sdd/variant-contract.md`.
- Known hazards: no clip-path/overflow:hidden on `.ss-row/.ss-dropdown/.ss-window/.ss-chip-*`; no position overrides on `.ss-dropdown/.ss-window`; read-only dimming via color not opacity; hex escapes in `content` strings need doubled spaces; no `:active` squish on elements hosting open submenus.
- Color discipline (the point of this variant): DARK monochrome throughout — near-black wallpaper, neutral dark frosted-glass panels (`backdrop-filter` blur stays), white/gray text (`#f2f2f2` ink, `#9a9a9a` dim, hairlines `rgba(255,255,255,.14)`) — EXCEPT sparse accent signals: amber `#ffb000` (awaiting / clamped / `.ss-attention`), cyan `#00e5ff` (verified / active-selection / focus), red `#ff3b3b` (rejected). Accents appear only on: state dots, `.ss-attention`, `.is-active` markers, toast borders/tints, `.is-pending` pulse, ~10% of rain glyphs. Chrome, chips, panels, windows stay strictly B&W glass. No blue `#0a84ff` anywhere.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Work on branch `mono-glass` off `main`.

---

### Task 1: Variant 11 — files + manifest

**Files:**
- Create: `design-lab/variants/11-mono-glass/index.html`
- Create: `design-lab/variants/11-mono-glass/fx.js`
- Create: `design-lab/variants/11-mono-glass/style.css`
- Modify: `design-lab/shared/variants.js` (append one entry)

**Interfaces:**
- Consumes: `mount({variant})` from `shared/scaffold.js`; the ss-* class contract.
- Produces: `startRain()` exported from `fx.js` (no args, no return); manifest entry `{ dir: '11-mono-glass', name: 'Mono Glass', vibe: 'Dark B&W glass — live glyph rain, sparse color signals' }` (hub + arrow nav pick it up automatically; digit keys only cover variants 1–10 — variant 11 reachable via arrows and hub click, accepted).

- [ ] **Step 1: Write `design-lab/variants/11-mono-glass/index.html`**

```html
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mono Glass — SessionSwitch Lab</title>
<link rel="stylesheet" href="style.css">
<script type="module">
  import { mount } from '../../shared/scaffold.js';
  import { startRain } from './fx.js';
  mount({ variant: 'mono-glass' });
  startRain();
</script>
```

- [ ] **Step 2: Write `design-lab/variants/11-mono-glass/fx.js`**

```js
// Live monochrome glyph rain behind the desktop. DOM + randomness live here;
// all motion lives in style.css (.fx-col animation) so prefers-reduced-motion
// is honored purely in CSS. ponytail: fixed 44 columns, no resize handling —
// columns are %-positioned so window resizes still look fine.
const GLYPHS = '01<>[]{}()|/\\-_=+*#@$%&;:.';
const ACCENTS = ['#ffb000', '#00e5ff', '#ff3b3b'];
const COLS = 44;

const glyphColumn = () => {
  const len = 10 + Math.floor(Math.random() * 22);
  let txt = '';
  for (let j = 0; j < len; j++) txt += GLYPHS[Math.floor(Math.random() * GLYPHS.length)] + '\n';
  return txt;
};

export function startRain() {
  const layer = document.createElement('div');
  layer.className = 'fx-rain';
  const cols = [];
  for (let i = 0; i < COLS; i++) {
    const col = document.createElement('span');
    col.className = 'fx-col';
    col.textContent = glyphColumn();
    col.style.left = `${((i + Math.random() * 0.8) / COLS) * 100}%`;
    col.style.animationDuration = `${7 + Math.random() * 16}s`;
    col.style.animationDelay = `${-Math.random() * 23}s`;
    col.style.fontSize = `${9 + Math.floor(Math.random() * 5)}px`;
    if (Math.random() < 0.1) col.style.color = ACCENTS[Math.floor(Math.random() * ACCENTS.length)];
    cols.push(col);
    layer.appendChild(col);
  }
  document.body.prepend(layer);
  // keep it alive: re-deal a random column's glyphs every 1.8 s
  if (!matchMedia('(prefers-reduced-motion: reduce)').matches) {
    setInterval(() => {
      cols[Math.floor(Math.random() * cols.length)].textContent = glyphColumn();
    }, 1800);
  }
}
```

- [ ] **Step 3: Write `design-lab/variants/11-mono-glass/style.css`**

Start from `design-lab/variants/01-cupertino-glass/style.css` (same glass DNA: real macOS menu geometry, frosted `backdrop-filter: blur(24px) saturate(180%)` panels, 12px panel radius / 6px row radius, hairline separators, springy `cubic-bezier(.2,1.4,.4,1)` motion, Spotlight-clone picker, frosted-pill badge) and transform it:

1. Wallpaper: replace the blue/purple gradient with dark monochrome — near-black base `#0a0a0c` with a subtle neutral radial glow (e.g. `radial-gradient(ellipse at 30% 20%, #1c1c20, #0a0a0c 70%)`). `saturate(180%)` on panels → `saturate(100%)` (nothing colorful to saturate; keep blur).
2. Panels: neutral dark glass `rgba(22,22,24,.55)` + `backdrop-filter: blur(24px)`; text `#f2f2f2`; dim text `#9a9a9a`; hairlines `rgba(255,255,255,.14)`. Shadows stay (neutral black).
3. Kill ALL color from 01: the `#0a84ff` accent is gone. Apply the accent discipline exactly per Global Constraints — amber awaiting/clamp/attention, cyan verified/active-selection (menus `.is-active`, picker `.is-active`, focused states), red rejected. State dots: idle gray `#6e6e73`, working white pulse, awaiting amber. Read-only row: `color: #9a9a9a` + 🔒 glyph (existing 01 treatment), never opacity on the row.
4. Toasts: glass panels with a 1px accent border + faint accent tint per status (`.is-verified` cyan, `.is-clamped` amber, `.is-rejected` red); text stays white.
5. `.is-pending`: pulsing ring stays but amber, not blue.
6. Add the fx layer styling (fx.js DOM):

```css
.fx-rain { position: fixed; inset: 0; z-index: 1; pointer-events: none; overflow: hidden; }
.fx-col {
  position: absolute; top: 0; white-space: pre;
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  line-height: 1.1; color: #2e2e33;
  animation: fx-fall linear infinite;
}
@keyframes fx-fall { from { transform: translateY(-100%); } to { transform: translateY(100vh); } }
@media (prefers-reduced-motion: reduce) {
  .fx-col { animation: none; opacity: .35; }
}
```

7. Layering so the rain shows through AND through the glass: body carries the wallpaper; `.ss-desktop` background transparent (rain at z-index 1 sits behind windows at z 10+, and frosted panels blur the rain behind them — that's the signature look). Panels keep translucent fills (blur handles legibility); only `.ss-window-body` may go more opaque (`rgba(12,12,14,.85)`) so fake terminal text stays readable.
8. Reduced-motion: keep 01's coverage (springs, pending pulse, working dot) and the `.fx-col` rule above; fx.js interval self-disables via `matchMedia`.

- [ ] **Step 4: Append manifest entry to `design-lab/shared/variants.js`** (inside the `VARIANTS` array, after the clay-pop line):

```js
  { dir: '11-mono-glass',         name: 'Mono Glass',         vibe: 'Dark B&W glass — live glyph rain, sparse color signals' },
```

- [ ] **Step 5: Verify in browser** (Playwright headless pattern used by all prior tasks; cached Chromium):

Serve design-lab/ on port 4411. Check on `variants/11-mono-glass/`:
- zero console errors (favicon 404 acceptable)
- `.fx-rain` present with 44 `.fx-col` children, columns animating (computed `animation-name: fx-fall`), ~4–5 accent-colored columns
- acceptance checklist basics: dropdown opens/styled glass, one full apply flow (pending amber pulse → verified toast with cyan border), s4 clamp → amber toast, s6 read-only → red toast, haiku effort rejection, ⌘K picker keyboard flow, `.ss-attention` amber on menubar, read-only row distinct
- accents audit: computed colors of panel chrome/chips/hairlines strictly neutral (no blue `#0a84ff` anywhere; only amber/cyan/red at the sanctioned spots)
- reduced-motion emulation: `.fx-col` animation none, static field visible
- hub (`/`): 11 cards render, 11th card link correct, its keyboard badge must NOT render the string "undefined" (if hub.js `digitFor` returns undefined for index 10, fix it to return `''`); from variant 10, ArrowRight lands on 11, ArrowRight again wraps to 01
Kill the server after.

- [ ] **Step 6: Run `node design-lab/shared/engine.test.mjs`** — expected: `engine.test.mjs: all assertions passed`

- [ ] **Step 7: Commit**

```bash
git add design-lab/variants/11-mono-glass design-lab/shared/variants.js
git commit -m "feat(design-lab): mono glass variant with live glyph rain"
```

(plus `design-lab/hub.js` in the `git add` if the digitFor fix from Step 5 was needed)

---

### Task 2: Lab-wide sanity + finish

**Files:**
- Modify (only if defects found): any variant/hub file

**Interfaces:**
- Consumes: everything from Task 1.

- [ ] **Step 1:** Serve and walk the hub with 11 cards: no console errors on hub; iframe previews all load; digit keys 1–0 still map to variants 1–10 (11 has no digit — expected); arrows cycle 10 → 11 → 01 both on hub links and inside variant pages.
- [ ] **Step 2:** Load variants 01 and 11 side-by-side checks: 01 unchanged (still colorful glass); 11 clearly dark B&W glass + accents + rain; identities distinct.
- [ ] **Step 3:** Fix anything broken found (smallest fix), commit as `fix(design-lab): variant 11 integration` with trailer. If nothing found, no commit.
- [ ] **Step 4:** Done — hand back for merge via finishing-a-development-branch.
