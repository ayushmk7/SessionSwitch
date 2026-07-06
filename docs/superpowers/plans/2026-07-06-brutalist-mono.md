# Brutalist Mono (Variant 11) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add variant 11 "Brutalist Mono" to the design lab: the Terminal Brutalist direction reworked in black & white with sparse color hints, plus a live animated glyph-rain background.

**Architecture:** Same pure-reskin pattern as variants 01–10 (scaffold-owned DOM, per-variant style.css) plus one variant-local `fx.js` that injects a background layer of falling ASCII glyph columns; all motion lives in CSS so reduced-motion is handled in one place. Variant 02 (green phosphor) stays untouched for side-by-side comparison.

**Tech Stack:** Plain HTML/CSS/ES modules. No build, no deps.

## Global Constraints

- No external network resources; system font stacks only (`ui-monospace, 'SF Mono', Menlo, monospace`).
- No framework/build/package.json.
- Frozen ss-* class-hook contract (see `.superpowers/sdd/task-3-brief.md` "Class-hook contract"); scaffold.js and structure.css are read-only.
- Variant CSS contract + acceptance checklist: `.superpowers/sdd/variant-contract.md`.
- Known hazards: no clip-path/overflow:hidden on `.ss-row/.ss-dropdown/.ss-window/.ss-chip-*`; no position overrides on `.ss-dropdown/.ss-window`; read-only dimming via color not opacity; hex escapes in `content` strings need doubled spaces; no `:active` squish on elements hosting open submenus; nav-modifier guard already in scaffold — don't duplicate.
- Color discipline (the point of this variant): everything grayscale (`#0a0a0a` bg, `#e8e8e8` ink, `#7a7a7a` dim, `#2e2e2e` faint) EXCEPT sparse accent signals — amber `#ffb000` (awaiting / clamped / attention), cyan `#00e5ff` (verified / active-selection), red `#ff3b3b` (rejected). Accents appear only on: state dots, `.ss-attention`, `.is-active` markers, toast borders/prefixes, `.is-pending` pulse, ~10% of rain glyphs. Chrome, chips, tables, windows stay strictly B&W.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Work on branch `brutalist-mono` off `main`.

---

### Task 1: Variant 11 — files + manifest

**Files:**
- Create: `design-lab/variants/11-brutalist-mono/index.html`
- Create: `design-lab/variants/11-brutalist-mono/fx.js`
- Create: `design-lab/variants/11-brutalist-mono/style.css`
- Modify: `design-lab/shared/variants.js` (append one entry)

**Interfaces:**
- Consumes: `mount({variant})` from `shared/scaffold.js`; the ss-* class contract.
- Produces: `startRain()` exported from `fx.js` (no args, no return); manifest entry `{ dir: '11-brutalist-mono', name: 'Brutalist Mono', vibe: 'B&W terminal — live glyph rain, sparse color signals' }` (hub + arrow nav pick it up automatically; digit keys only cover variants 1–10 — variant 11 is reachable via arrows and hub click, accepted).

- [ ] **Step 1: Write `design-lab/variants/11-brutalist-mono/index.html`**

```html
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Brutalist Mono — SessionSwitch Lab</title>
<link rel="stylesheet" href="style.css">
<script type="module">
  import { mount } from '../../shared/scaffold.js';
  import { startRain } from './fx.js';
  mount({ variant: 'brutalist-mono' });
  startRain();
</script>
```

- [ ] **Step 2: Write `design-lab/variants/11-brutalist-mono/fx.js`**

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

- [ ] **Step 3: Write `design-lab/variants/11-brutalist-mono/style.css`**

Start from `design-lab/variants/02-terminal-brutalist/style.css` (same ASCII-border TUI DNA: box-drawing panels, TUI table dropdown, full-size ▁▃▅▇ effort bars, blinking block cursor, `[ OK ]/[WARN]/[FAIL]` toast prefixes) and transform it:

1. Recolor to the Global Constraints palette: all green (`#33ff66`/`#1a8f3c`) → ink/dim grays; remove all `box-shadow` glow entirely (no glow in this variant — hard 1px `#e8e8e8`/`#7a7a7a` borders only). Scanline overlay stays but neutral (black stripes, opacity ≤ .18).
2. Apply the accent discipline exactly as listed in Global Constraints (amber awaiting/clamp/attention, cyan verified/active, red rejected; everything else B&W). Toast prefixes: `[ OK ]` cyan, `[WARN]` amber, `[FAIL]` red — text prefix colored, toast body stays B&W with 1px border in the accent.
3. `.is-pending`: alternate the chip's 1px border between `#e8e8e8` and amber (steps(2) animation), no glow.
4. Read-only row: dim via `color: #7a7a7a` + `[RO]` tag, never opacity.
5. Add the fx layer styling (fx.js DOM):

```css
.fx-rain { position: fixed; inset: 0; z-index: 1; pointer-events: none; overflow: hidden; }
.fx-col {
  position: absolute; top: 0; white-space: pre;
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  line-height: 1.1; color: #2e2e2e;
  animation: fx-fall linear infinite;
}
@keyframes fx-fall { from { transform: translateY(-100%); } to { transform: translateY(100vh); } }
@media (prefers-reduced-motion: reduce) {
  .fx-col { animation: none; opacity: .35; }
}
```

6. Layering so the rain shows through: body carries the `#0a0a0a` background; `.ss-desktop` background transparent; `.ss-window`, `.ss-dropdown`, `.ss-menu`, `.ss-badge-summary`, `.ss-badge-panel`, `.ss-picker`, `.ss-toast` get opaque `#0a0a0a` (or `#0f0f0f`) fills so UI stays legible over the rain (rain is z-index 1; structure.css puts windows at z 10+, so panels paint above it).
7. Reduced-motion block: keep 02's coverage (cursor blink, scanline flicker, pending pulse, dot blinks) and the `.fx-col` rule above; the fx.js interval already self-disables via `matchMedia`.

- [ ] **Step 4: Append manifest entry to `design-lab/shared/variants.js`** (inside the `VARIANTS` array, after the clay-pop line):

```js
  { dir: '11-brutalist-mono',     name: 'Brutalist Mono',     vibe: 'B&W terminal — live glyph rain, sparse color signals' },
```

- [ ] **Step 5: Verify in browser** (Playwright headless pattern used by all prior tasks; cached Chromium):

Serve design-lab/ on port 4411. Check on `variants/11-brutalist-mono/`:
- zero console errors (favicon 404 acceptable)
- `.fx-rain` present with 44 `.fx-col` children, columns animating (computed `animation-name: fx-fall`), ~4–5 accent-colored columns
- acceptance checklist basics: dropdown opens/styled, one full apply flow (pending → `[ OK ]` toast), s4 clamp → `[WARN]` amber toast, s6 read-only → `[FAIL]` red toast, haiku effort rejection, ⌘K picker keyboard flow, `.ss-attention` amber on menubar, read-only row distinct
- accents audit: grep computed colors of chips/table/window chrome — must be grayscale
- reduced-motion emulation: `.fx-col` animation none, static field visible
- hub (`/`): 11 cards render, 11th card link correct; from variant 10, ArrowRight lands on 11, ArrowRight again wraps to 01
Kill the server after.

- [ ] **Step 6: Run `node design-lab/shared/engine.test.mjs`** — expected: `engine.test.mjs: all assertions passed`

- [ ] **Step 7: Commit**

```bash
git add design-lab/variants/11-brutalist-mono design-lab/shared/variants.js
git commit -m "feat(design-lab): brutalist mono variant with live glyph rain"
```

---

### Task 2: Lab-wide sanity + finish

**Files:**
- Modify (only if defects found): any variant/hub file

**Interfaces:**
- Consumes: everything from Task 1.

- [ ] **Step 1:** Serve and walk the hub with 11 cards: no console errors on hub; iframe previews all load; digit keys 1–0 still map to variants 1–10 (11 has no digit — expected); arrows cycle 10 → 11 → 01 both on hub links and inside variant pages. Check hub.js `digitFor` handling for index 10 — the 11th card's keyboard badge must render empty/hidden, not the string "undefined"; if it shows "undefined", fix `digitFor` to return `''` for indexes > 9.
- [ ] **Step 2:** Load variants 01, 02, and 11 side-by-side checks: 02 unchanged (still green phosphor); 11 clearly B&W+accents; identities distinct.
- [ ] **Step 3:** Fix anything broken found (smallest fix), commit as `fix(design-lab): variant 11 integration` with trailer. If nothing found, no commit.
- [ ] **Step 4:** Done — hand back for merge via finishing-a-development-branch.
