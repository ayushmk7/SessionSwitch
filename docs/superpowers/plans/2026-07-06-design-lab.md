# SessionSwitch Design Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A zero-build static site at `design-lab/` serving 10 fully interactive UI design variants of SessionSwitch (menu bar dropdown + floating badge + hotkey quick picker) behind one gallery hub, so the user can pick a design direction.

**Architecture:** Shared headless engine (`engine.js`, fake data + apply/verify/clamp logic, pub/sub) + shared DOM scaffold (`scaffold.js`, builds the three surfaces and a fake macOS desktop with stable `ss-*` class hooks) + one folder per variant containing only `index.html` (6 lines) and `style.css` (the creative identity). Hub lists variants as live scaled iframes.

**Tech Stack:** Plain HTML/CSS/ES modules. No npm, no build. Served with `python3 -m http.server`. Tests: plain `node` asserts.

## Global Constraints

- No external network resources: system font stacks only, no CDN, no Google Fonts (must work offline).
- No framework, no build step, no `package.json`.
- All engine/scaffold class hooks use the `ss-` prefix exactly as defined in Task 3.
- Spec: `docs/superpowers/specs/2026-07-06-design-lab-design.md`.
- Every commit message ends with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Fake data + variant manifest

**Files:**
- Create: `design-lab/shared/data.js`
- Create: `design-lab/shared/variants.js`

**Interfaces:**
- Produces: `MODELS` (array of `{id, alias, name, efforts: string[], hint}`), `PRESETS` (`{id, name, model, effort, color}`), `SESSIONS` (`{id, project, terminal, model, effort, state, flags, window}`), `EFFORT_ORDER`, `VARIANTS` (`{dir, name, vibe}`).

- [ ] **Step 1: Write `design-lab/shared/data.js`**

```js
export const EFFORT_ORDER = ['low', 'medium', 'high', 'max'];

export const MODELS = [
  { id: 'claude-fable-5',   alias: 'fable',  name: 'Fable 5',   efforts: ['low', 'medium', 'high', 'max'], hint: 'frontier reasoning · $$$$' },
  { id: 'claude-opus-4-8',  alias: 'opus',   name: 'Opus 4.8',  efforts: ['low', 'medium', 'high'],        hint: 'flagship · $$$' },
  { id: 'claude-sonnet-5',  alias: 'sonnet', name: 'Sonnet 5',  efforts: ['low', 'medium', 'high'],        hint: 'balanced · $$' },
  { id: 'claude-haiku-4-5', alias: 'haiku',  name: 'Haiku 4.5', efforts: [],                               hint: 'fast · $ · no effort control' },
];

export const PRESETS = [
  { id: 'deep-work',  name: 'Deep Work',    model: 'claude-fable-5',   effort: 'high',   color: '#7c5cff' },
  { id: 'balanced',   name: 'Balanced',     model: 'claude-sonnet-5',  effort: 'medium', color: '#2f9e6e' },
  { id: 'cheap-fast', name: 'Cheap & Fast', model: 'claude-haiku-4-5', effort: null,     color: '#d97706' },
];

// state: 'idle' | 'working' | 'awaiting'
// flags: 'read-only' (SSH remote, FR-5), 'org-capped' (effort ceiling medium, FR-35)
// window: id of fake desktop window a badge docks to, or null
export const SESSIONS = [
  { id: 's1', project: '~/work/api-gateway',   terminal: 'iTerm2',    model: 'claude-fable-5',   effort: 'high',   state: 'working',  flags: [],             window: 'w1' },
  { id: 's2', project: '~/work/checkout-web',  terminal: 'VS Code',   model: 'claude-sonnet-5',  effort: 'medium', state: 'idle',     flags: [],             window: null },
  { id: 's3', project: '~/oss/zig-parser',     terminal: 'Terminal',  model: 'claude-opus-4-8',  effort: 'high',   state: 'awaiting', flags: [],             window: 'w2' },
  { id: 's4', project: '~/work/infra-tf',      terminal: 'JetBrains', model: 'claude-sonnet-5',  effort: 'low',    state: 'idle',     flags: ['org-capped'], window: null },
  { id: 's5', project: '~/ml/notebooks',       terminal: 'iTerm2',    model: 'claude-haiku-4-5', effort: null,     state: 'working',  flags: [],             window: null },
  { id: 's6', project: 'ssh://legacy-billing', terminal: 'Terminal',  model: 'claude-sonnet-5',  effort: 'medium', state: 'idle',     flags: ['read-only'],  window: null },
];
```

- [ ] **Step 2: Write `design-lab/shared/variants.js`**

```js
export const VARIANTS = [
  { dir: '01-cupertino-glass',    name: 'Cupertino Glass',    vibe: 'Native macOS vibrancy — frosted, precise, springy' },
  { dir: '02-terminal-brutalist', name: 'Terminal Brutalist', vibe: 'Phosphor green TUI — ASCII borders, block cursor' },
  { dir: '03-cyberpunk-hud',      name: 'Cyberpunk HUD',      vibe: 'Neon target-lock interface — scanlines, glitch' },
  { dir: '04-system-7',           name: 'System 7',           vibe: '1-bit classic Mac — stripes, dithers, radio buttons' },
  { dir: '05-swiss-minimal',      name: 'Swiss Minimal',      vibe: 'Typographic grid — black, white, one red' },
  { dir: '06-synthwave-arcade',   name: 'Synthwave Arcade',   vibe: 'Sunset chrome — high-score tables, neon pulse' },
  { dir: '07-eink-paper',         name: 'E-Ink Paper',        vibe: 'Warm paper calm — stamps, serifs, zero glow' },
  { dir: '08-avionics-cockpit',   name: 'Avionics Cockpit',   vibe: 'Instrument panel — gauges, annunciators, CAUTION' },
  { dir: '09-blueprint',          name: 'Blueprint',          vibe: 'Technical drawing — dimension lines, title block' },
  { dir: '10-clay-pop',           name: 'Clay Pop',           vibe: 'Squishy claymorphism — jelly buttons, confetti' },
];
```

- [ ] **Step 3: Commit**

```bash
git add design-lab/shared
git commit -m "feat(design-lab): fake data and variant manifest"
```

---

### Task 2: Engine (TDD)

**Files:**
- Create: `design-lab/shared/engine.test.mjs`
- Create: `design-lab/shared/engine.js`

**Interfaces:**
- Consumes: everything from `data.js`.
- Produces (all exported from `engine.js`):
  - `init(options?: {latencyMs?: number, ambient?: boolean})` — resets state; `latencyMs` default 600, `ambient` default true starts a 4 s ticker flipping a random non-read-only, non-awaiting session between idle/working.
  - `getState(): {sessions, focusedId, models, presets}` — sessions carry runtime fields `pending: string|null` and `lastResult: {status, requested, applied, reason}|null`.
  - `subscribe(fn): unsubscribe` — fn called with `getState()` on every change.
  - `model(idOrAlias)` — catalog lookup.
  - `validEfforts(modelId): string[]`
  - `focusSession(id)` / `getState().focusedId`
  - `applyModel(id, modelId): Promise<Result>` — switching models re-validates effort: if current effort unsupported by the new model, effort becomes `'medium'` if supported else `efforts[0]` else `null`.
  - `applyEffort(id, level): Promise<Result>` — unsupported level → immediate `rejected` with reason naming the model and the fallback (`efforts[efforts.length-1]` or none); org-capped session requesting a level ranked above `medium` in `EFFORT_ORDER` → `clamped` to `medium`, reason `'limited by org policy'`.
  - `cycleEffort(id): Promise<Result>` — next level in the model's `efforts` (wraps); empty list → `rejected` with reason `'no effort control for this model'`.
  - `applyPreset(id, presetId): Promise<Result>` — model + effort atomically, same clamp rules.
  - `Result = {status: 'verified'|'clamped'|'rejected', requested: string, applied: string|null, reason: string|null}`
  - Read-only sessions: every apply resolves immediately `rejected`, reason `'read-only session (SSH remote)'`.
  - During fake latency the session's `pending` holds a human label (e.g. `'model Fable 5'`); cleared on resolve; `lastResult` set on resolve. Both trigger `emit`.

- [ ] **Step 1: Write the failing test `design-lab/shared/engine.test.mjs`**

```js
import assert from 'node:assert/strict';
import * as engine from './engine.js';

const find = id => engine.getState().sessions.find(s => s.id === id);

// deterministic: no latency, no ambient ticker
engine.init({ latencyMs: 0, ambient: false });

// 1. applyModel verifies and re-validates effort (fable/high -> haiku/null)
let r = await engine.applyModel('s1', 'claude-haiku-4-5');
assert.equal(r.status, 'verified');
assert.equal(find('s1').model, 'claude-haiku-4-5');
assert.equal(find('s1').effort, null);

// 2. model switch keeps a still-valid effort (sonnet/medium -> opus keeps medium)
r = await engine.applyModel('s2', 'claude-opus-4-8');
assert.equal(find('s2').effort, 'medium');

// 3. invalid effort rejected with fallback in reason (max on opus)
r = await engine.applyEffort('s2', 'max');
assert.equal(r.status, 'rejected');
assert.match(r.reason, /Opus 4.8/);
assert.match(r.reason, /high/);
assert.equal(find('s2').effort, 'medium'); // unchanged

// 4. org-capped clamp: s4 requesting high applies medium
r = await engine.applyEffort('s4', 'high');
assert.equal(r.status, 'clamped');
assert.equal(r.applied, 'medium');
assert.equal(r.reason, 'limited by org policy');
assert.equal(find('s4').effort, 'medium');

// 5. read-only rejects everything
r = await engine.applyModel('s6', 'claude-haiku-4-5');
assert.equal(r.status, 'rejected');
assert.match(r.reason, /read-only/);
assert.equal(find('s6').model, 'claude-sonnet-5');

// 5b. read-only wins over invalid-level rejection
r = await engine.applyEffort('s6', 'max');
assert.equal(r.status, 'rejected');
assert.match(r.reason, /read-only/);

// 6. preset applies model+effort atomically
r = await engine.applyPreset('s2', 'deep-work');
assert.equal(r.status, 'verified');
assert.equal(find('s2').model, 'claude-fable-5');
assert.equal(find('s2').effort, 'high');

// 7. preset clamp on org-capped session (deep-work high -> medium)
r = await engine.applyPreset('s4', 'deep-work');
assert.equal(r.status, 'clamped');
assert.equal(find('s4').model, 'claude-fable-5');
assert.equal(find('s4').effort, 'medium');

// 8. cycleEffort wraps through valid levels; haiku rejects
r = await engine.cycleEffort('s5');
assert.equal(r.status, 'rejected');
await engine.applyModel('s5', 'claude-sonnet-5'); // -> medium
r = await engine.cycleEffort('s5');
assert.equal(find('s5').effort, 'high');

// 9. subscribe fires on change and unsubscribe stops it
let calls = 0;
const un = engine.subscribe(() => calls++);
engine.focusSession('s3');
assert.ok(calls >= 1);
un();
const before = calls;
engine.focusSession('s1');
assert.equal(calls, before);

// 10. pending is set during latency
engine.init({ latencyMs: 30, ambient: false });
const p = engine.applyModel('s1', 'claude-sonnet-5');
assert.ok(find('s1').pending);
await p;
assert.equal(find('s1').pending, null);
assert.equal(find('s1').lastResult.status, 'verified');

console.log('engine.test.mjs: all assertions passed');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node design-lab/shared/engine.test.mjs`
Expected: FAIL — `Cannot find module ... engine.js`

- [ ] **Step 3: Write `design-lab/shared/engine.js`**

```js
import { MODELS, PRESETS, SESSIONS, EFFORT_ORDER } from './data.js';

let cfg = { latencyMs: 600, ambient: true };
let sessions = [];
let focusedId = null;
let timer = null;
const listeners = new Set();

export function init(options = {}) {
  cfg = { latencyMs: 600, ambient: true, ...options };
  sessions = SESSIONS.map(s => ({ ...s, pending: null, lastResult: null }));
  focusedId = sessions[0].id;
  clearInterval(timer);
  if (cfg.ambient) timer = setInterval(tick, 4000);
  emit();
}

function tick() {
  const live = sessions.filter(s => !s.flags.includes('read-only') && s.state !== 'awaiting');
  const s = live[Math.floor(Math.random() * live.length)];
  s.state = s.state === 'working' ? 'idle' : 'working';
  emit();
}

export function getState() {
  return { sessions, focusedId, models: MODELS, presets: PRESETS };
}

export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

function emit() { listeners.forEach(fn => fn(getState())); }

export function focusSession(id) { focusedId = id; emit(); }

export const model = idOrAlias =>
  MODELS.find(m => m.id === idOrAlias || m.alias === idOrAlias);

export const validEfforts = modelId => model(modelId)?.efforts ?? [];

const get = id => sessions.find(s => s.id === id);
const sleep = ms => new Promise(r => setTimeout(r, ms));

function reject(s, requested, reason) {
  s.lastResult = { status: 'rejected', requested, applied: null, reason };
  emit();
  return Promise.resolve(s.lastResult);
}

// shared apply pipeline: read-only guard -> pending -> latency -> mutate -> result
async function run(s, requested, mutate) {
  if (s.flags.includes('read-only')) {
    return reject(s, requested, 'read-only session (SSH remote)');
  }
  s.pending = requested;
  emit();
  await sleep(cfg.latencyMs);
  const { status, applied, reason } = mutate();
  s.pending = null;
  s.lastResult = { status, requested, applied, reason: reason ?? null };
  emit();
  return s.lastResult;
}

// org cap: ceiling 'medium' for flagged sessions
function capEffort(s, level) {
  if (level && s.flags.includes('org-capped') &&
      EFFORT_ORDER.indexOf(level) > EFFORT_ORDER.indexOf('medium')) {
    return { level: 'medium', clamped: true };
  }
  return { level, clamped: false };
}

// effort revalidation on model change
function effortForModel(m, current) {
  if (m.efforts.includes(current)) return current;
  if (m.efforts.includes('medium')) return 'medium';
  return m.efforts[0] ?? null;
}

export function applyModel(id, modelId) {
  const s = get(id);
  const m = model(modelId);
  return run(s, `model ${m.name}`, () => {
    s.model = m.id;
    s.effort = effortForModel(m, s.effort);
    return { status: 'verified', applied: m.name };
  });
}

export function applyEffort(id, level) {
  const s = get(id);
  if (s.flags.includes('read-only')) {
    return reject(s, `effort ${level}`, 'read-only session (SSH remote)');
  }
  const m = model(s.model);
  if (!m.efforts.includes(level)) {
    const fallback = m.efforts[m.efforts.length - 1];
    return reject(s, `effort ${level}`,
      `${m.name} does not support "${level}"` +
      (fallback ? `; falls back to ${fallback}` : ''));
  }
  return run(s, `effort ${level}`, () => {
    const { level: applied, clamped } = capEffort(s, level);
    s.effort = applied;
    return clamped
      ? { status: 'clamped', applied, reason: 'limited by org policy' }
      : { status: 'verified', applied };
  });
}

export function cycleEffort(id) {
  const s = get(id);
  if (s.flags.includes('read-only')) {
    return reject(s, 'effort', 'read-only session (SSH remote)');
  }
  const m = model(s.model);
  if (m.efforts.length === 0) {
    return reject(s, 'effort', 'no effort control for this model');
  }
  const next = m.efforts[(m.efforts.indexOf(s.effort) + 1) % m.efforts.length];
  return applyEffort(id, next);
}

export function applyPreset(id, presetId) {
  const s = get(id);
  const p = PRESETS.find(x => x.id === presetId);
  const m = model(p.model);
  return run(s, `preset ${p.name}`, () => {
    s.model = m.id;
    const wanted = p.effort === null ? null : p.effort;
    const { level, clamped } = capEffort(s, wanted);
    s.effort = m.efforts.length === 0 ? null : (level ?? effortForModel(m, null));
    return clamped
      ? { status: 'clamped', applied: `${m.name} · ${s.effort}`, reason: 'limited by org policy' }
      : { status: 'verified', applied: `${m.name}${s.effort ? ' · ' + s.effort : ''}` };
  });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node design-lab/shared/engine.test.mjs`
Expected: `engine.test.mjs: all assertions passed`

- [ ] **Step 5: Commit**

```bash
git add design-lab/shared/engine.js design-lab/shared/engine.test.mjs
git commit -m "feat(design-lab): headless engine with apply/verify/clamp logic + node self-test"
```

---

### Task 3: Scaffold + structure.css + first variant (Cupertino Glass)

**Files:**
- Create: `design-lab/shared/scaffold.js`
- Create: `design-lab/shared/structure.css`
- Create: `design-lab/variants/01-cupertino-glass/index.html`
- Create: `design-lab/variants/01-cupertino-glass/style.css`

**Interfaces:**
- Consumes: full engine API from Task 2, `VARIANTS` from Task 1.
- Produces: `mount({variant})` from `scaffold.js` — builds all DOM, wires engine, keyboard. The **class-hook contract** below is what every variant's `style.css` targets; it is frozen after this task.

**Class-hook contract (stable, all variants style these):**

```
body.ss.v-<variant>            page root
.ss-menubar                    fake macOS menu bar strip (top)
  .ss-menubar-app              "SessionSwitch ▾" status item, .ss-attention when any session awaits
  .ss-menubar-clock            fake clock (static "Mon 9:41 AM")
.ss-dropdown (.ss-open)        dropdown panel anchored under menubar item
  .ss-row (.is-idle|.is-working|.is-awaiting|.is-readonly)   one session
    .ss-state-dot
    .ss-row-project            project dir text
    .ss-row-terminal           terminal app name
    .ss-chip-model             current model chip (click -> model menu)
    .ss-chip-effort            effort chip, contains .ss-effort-bars (▁▃▅▇ spans, .on for lit) (click -> cycle, right-click -> menu)
    .ss-row-preset             "preset ▸" (click -> preset menu)
    .is-pending                pulsing outline modifier on chips while pending
  .ss-menu                     any open submenu (model/effort/preset); .ss-menu-item children, .is-active for current
  .ss-dropdown-footer          global actions row: "New Session…", "Refresh"
.ss-desktop                    desktop area under menubar
  .ss-window (#w1, #w2, .is-front)  fake terminal windows
    .ss-window-title           title bar text
    .ss-window-body            fake terminal <pre> content
  .ss-badge (.is-open)         floating pill docked top-right of its window
    .ss-badge-summary          collapsed content: model name + effort bars
    .ss-badge-panel            expanded picker: three .ss-badge-col (models | efforts | presets)
.ss-picker (.ss-open)          centered quick-picker overlay
  .ss-picker-input             real <input>
  .ss-picker-session           resolved target session line
  .ss-picker-modes             three .ss-picker-mode tabs (model/effort/preset), .is-active
  .ss-picker-list              .ss-picker-option items, .is-active for highlighted
.ss-toast-wrap                 fixed toast stack
  .ss-toast (.is-verified|.is-clamped|.is-rejected)
.ss-lab-link                   fixed "← Lab" link, bottom-left
```

**Behavior wired by scaffold (identical across variants):**
- Menubar app item click toggles `.ss-open` on dropdown.
- Model chip click → model menu; item click → `engine.applyModel`; effort chip click → `engine.cycleEffort`; contextmenu → effort menu with valid levels; preset click → preset menu → `engine.applyPreset`.
- Row click (not on a chip) → `engine.focusSession` + raises that session's window (`.is-front`).
- Badge click toggles `.is-open`; items inside call the same engine applies for that session, then collapse.
- `⌘K` (metaKey && 'k', preventDefault) toggles picker. Picker: input filters sessions by project substring (target = first match, else focused session); `Tab` cycles mode model→effort→preset (preventDefault); `↑`/`↓` move option highlight; `Enter` applies highlighted option to target session and closes; `Esc` closes picker only.
- When picker closed: `←`/`→` navigate `location` to prev/next variant dir from `VARIANTS`; digits `1`–`9`,`0` jump to variant N (0 = 10th).
- Every settled apply result raises a toast showing `requested` → `applied` + `reason` (auto-dismiss 3.5 s).
- Render model: scaffold keeps a `ui` state object `{menu: {sid, kind}|null, badgeOpen: sid|null, picker: {open, query, mode, idx}}` and fully rebuilds dropdown/badges/picker DOM on every engine emit or ui change. Effort bars: 4 spans `▁▃▅▇`; number lit = `EFFORT_ORDER.indexOf(effort)+1`; zero lit + `title` note for models without effort.

**`structure.css` (layout mechanics only — zero aesthetics: no colors, no fonts, no borders):** positions menubar (fixed, top, `height: var(--ss-menubar-h, 28px)`), dropdown (absolute, below menubar, right-anchored, `display:none` → `.ss-open{display:block}`), desktop (fills viewport), windows (`#w1{left:6%;top:16%;width:46%}`, `#w2{left:40%;top:44%;width:50%}`, absolute), badges (absolute, top-right corner of parent window, `transform: translateY(-50%)`), picker (fixed, centered, `display:none` → `.ss-open`), toast stack (fixed, bottom-right, column), menus (absolute under their chip), lab link (fixed, bottom-left, `z-index:300`). Body: `margin:0; height:100vh; overflow:hidden`.

- [ ] **Step 1: Write `design-lab/shared/structure.css`** per the layout spec above (complete file, mechanics only).

- [ ] **Step 2: Write `design-lab/shared/scaffold.js`** implementing the DOM builders, `ui` state, render-on-emit, and all behaviors above. Shape:

```js
import * as engine from './engine.js';
import { VARIANTS } from './variants.js';
import { EFFORT_ORDER } from './data.js';

export function mount({ variant }) {
  engine.init();
  document.body.className = `ss v-${variant}`;
  injectStructureCss();          // <link rel=stylesheet> to ../../shared/structure.css
  buildStaticDom();              // menubar, desktop+windows, picker shell, toast wrap, lab link
  wireKeyboard();
  engine.subscribe(render);
  render(engine.getState());
}
```

All submenus/badge panels/picker rebuilt inside `render()` from `engine.getState()` + `ui`. Toasts appended in a `showToast(result)` helper called from every apply `.then()`.

- [ ] **Step 3: Write `design-lab/variants/01-cupertino-glass/index.html`** (this exact file is the template for all 10 variants — only title and variant slug change):

```html
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cupertino Glass — SessionSwitch Lab</title>
<link rel="stylesheet" href="style.css">
<script type="module">
  import { mount } from '../../shared/scaffold.js';
  mount({ variant: 'cupertino-glass' });
</script>
```

- [ ] **Step 4: Write `design-lab/variants/01-cupertino-glass/style.css`** per the Variant CSS contract (below) and this brief:
  - Tokens: `--bg` macOS Sonoma-style wallpaper gradient (deep blue→purple radial), panels `rgba(30,30,32,.6)` with `backdrop-filter: blur(24px) saturate(180%)`, text `rgba(255,255,255,.9)`, hairlines `rgba(255,255,255,.14)`, accent `#0a84ff`.
  - Font: `-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif`, 13px base.
  - Dropdown = real macOS menu geometry: 6px radius rows, full-panel 12px radius, shadow `0 10px 40px rgba(0,0,0,.45)`.
  - Badge = frosted pill; picker = Spotlight clone (wide, large input, blurred panel).
  - Motion: `transition: transform .35s cubic-bezier(.2,1.4,.4,1)` spring-ish on menus/badge; pending pulse = animated `box-shadow` ring in accent.
  - State dots: idle gray, working green pulse, awaiting orange; read-only row at 50% opacity with 🔒 glyph via `::after`.

- [ ] **Step 5: Verify in browser**

Run: `cd design-lab && python3 -m http.server 4400` then open `http://localhost:4400/variants/01-cupertino-glass/`.
Expected: desktop renders; dropdown opens; model/effort/preset applies show pending pulse then toast; badge expands; ⌘K picker filters/Tab/Enter works; s6 rejects (read-only toast); s4 high clamps to medium with org-policy toast.

- [ ] **Step 6: Commit**

```bash
git add design-lab/shared design-lab/variants/01-cupertino-glass
git commit -m "feat(design-lab): scaffold, structure css, cupertino glass variant"
```

---

### Task 4: Hub

**Files:**
- Create: `design-lab/index.html`
- Create: `design-lab/hub.css`
- Create: `design-lab/hub.js`
- Create: `design-lab/README.md`

**Interfaces:**
- Consumes: `VARIANTS` from `shared/variants.js`.

- [ ] **Step 1: Write hub files.** `index.html` loads `hub.css` + module `hub.js`. `hub.js` renders header ("SessionSwitch Design Lab", count, "←/→ cycle · 1–0 jump · ⌘K inside a variant") and a responsive grid: one card per variant — live `<iframe src="variants/<dir>/" loading="lazy">` at 1280×800 scaled to fit card via `transform: scale()`, `pointer-events: none` on iframe, whole card an `<a href="variants/<dir>/">`, name + vibe caption. Keyboard: digits jump, `←`/`→` from hub go to last/first variant. `hub.css`: neutral near-black identity, system font, subtle card hover lift — deliberately plain so it doesn't bias the vote.

- [ ] **Step 2: Write `design-lab/README.md`**

```markdown
# SessionSwitch Design Lab

10 interactive design directions for SessionSwitch. Pick one.

    cd design-lab && python3 -m http.server 4400

Open http://localhost:4400 — click a card. ←/→ cycles variants, 1–0 jumps,
⌘K opens the quick picker inside any variant.

Engine self-test: `node shared/engine.test.mjs`
```

- [ ] **Step 3: Verify** hub at `http://localhost:4400/` shows 10 cards (9 will 404 inside their iframes until built — acceptable during development), navigation works.

- [ ] **Step 4: Commit**

```bash
git add design-lab/index.html design-lab/hub.css design-lab/hub.js design-lab/README.md
git commit -m "feat(design-lab): gallery hub with live iframe cards"
```

---

## Variant CSS contract (applies to Tasks 5–13)

Each variant task creates exactly two files:
- `design-lab/variants/<dir>/index.html` — copy the Task 3 Step 3 template verbatim; change only `<title>` and the `variant` slug.
- `design-lab/variants/<dir>/style.css` — must style **every** hook in the Task 3 class contract: wallpaper/desktop, menubar + app item (+ `.ss-attention`), dropdown + rows + both chips + effort bars + state dots (3 states) + read-only treatment, menus, windows (front/back), badge collapsed + expanded panel, picker (input, modes, options, active states), toasts (3 statuses), pending pulse animation, `.ss-lab-link`. System font stacks only. Honor `prefers-reduced-motion: reduce` by disabling looping animations.

**Per-variant acceptance checklist (run in browser each task):**
1. All 3 surfaces visibly styled in the variant's identity (nothing default-unstyled).
2. Apply flows work: pending → verified toast; s4 clamp toast; s6 rejected toast; haiku effort rejection.
3. ⌘K picker fully keyboard-drivable.
4. Read-only session visually distinct.
5. Identity is unmistakably different from all previously built variants.

---

### Task 5: Variant 02 — Terminal Brutalist

**Files:** Create `design-lab/variants/02-terminal-brutalist/index.html`, `style.css`

- [ ] **Step 1: index.html** from template (title "Terminal Brutalist", slug `terminal-brutalist`).
- [ ] **Step 2: style.css** — Tokens: bg `#050805`, phosphor `#33ff66`, dim `#1a8f3c`, alert `#ffb000`. Font: `ui-monospace, 'SF Mono', Menlo, monospace` everywhere, 13px. Signature: every panel drawn with ASCII box characters via `::before/::after` content (`┌─┐│└┘`) or 1px solid phosphor borders + `box-shadow: 0 0 8px rgba(51,255,102,.35)` glow; dropdown = TUI table with column rules; effort bars are the raw `▁▃▅▇` glyphs at full size; blinking block cursor (`▮`, steps() animation) after focused row; apply = brief full-panel flicker (opacity keyframes, 2 frames); scanline overlay `repeating-linear-gradient(transparent 0 2px, rgba(0,0,0,.25) 2px 4px)` fixed and `pointer-events:none`; toasts render as `[ OK ]` / `[WARN]` / `[FAIL]` prefixed lines.
- [ ] **Step 3: Verify** against acceptance checklist.
- [ ] **Step 4: Commit** `feat(design-lab): terminal brutalist variant`

---

### Task 6: Variant 03 — Cyberpunk HUD

**Files:** Create `design-lab/variants/03-cyberpunk-hud/index.html`, `style.css`

- [ ] **Step 1: index.html** from template (slug `cyberpunk-hud`).
- [ ] **Step 2: style.css** — Tokens: bg `#0a0e1a` with faint grid (`linear-gradient` crosshatch), cyan `#00e5ff`, magenta `#ff2d78`, amber warn `#ffc400`. Fonts: wide grotesk stack `'Avenir Next Condensed', 'Arial Narrow', sans-serif` for labels + mono for data. Signature: panels get angular corners via `clip-path: polygon(...)` (one clipped corner each); chips = hexagonal-cut tags; sessions in picker framed as target lock-ons (corner brackets via `::before/::after` borders); pending = glitch flash (`transform: translateX` jitter keyframes, 120ms); working state dot = radar sweep (conic-gradient spin); scanlines + chromatic edge (`text-shadow: 1px 0 rgba(255,45,120,.5), -1px 0 rgba(0,229,255,.5)` on headings); clamped toast = amber hazard stripes background.
- [ ] **Step 3: Verify** checklist. **Step 4: Commit** `feat(design-lab): cyberpunk hud variant`

---

### Task 7: Variant 04 — System 7

**Files:** Create `design-lab/variants/04-system-7/index.html`, `style.css`

- [ ] **Step 1: index.html** from template (slug `system-7`).
- [ ] **Step 2: style.css** — Tokens: paper `#ffffff`, ink `#000000`, desktop dither = tiny repeating checkerboard via `repeating-conic-gradient(#000 0 25%, #fff 0 50%) 0 0/4px 4px` at low size (classic gray). Font: `Charcoal, Geneva, 'Lucida Grande', sans-serif`, `-webkit-font-smoothing: none`. Signature: dropdown + picker are classic Mac windows — 1px black border, title bar with 6 horizontal pinstripes (`repeating-linear-gradient`), close box square left; buttons = 1px border, 2px black offset shadow, `border-radius: 6px 6px 6px 6px / 50% 50%`... use classic rounded-rect; model menu items carry real radio-button glyphs (`◉/○`), presets checkboxes (`☒/☐`); badge = tiny WindowShade bar that "rolls up"; clamp/reject toasts = modal alert box with ⚠︎ icon and an "OK" button (clicking dismisses); everything strictly 1-bit black/white except selection inversion (black bg, white text).
- [ ] **Step 3: Verify** checklist. **Step 4: Commit** `feat(design-lab): system 7 variant`

---

### Task 8: Variant 05 — Swiss Minimal

**Files:** Create `design-lab/variants/05-swiss-minimal/index.html`, `style.css`

- [ ] **Step 1: index.html** from template (slug `swiss-minimal`).
- [ ] **Step 2: style.css** — Tokens: paper `#fafafa`, ink `#111`, red `#e30613`, hairline `#d4d4d4`. Font: `'Helvetica Neue', Helvetica, Arial, sans-serif`; sizes locked to an 8px baseline grid (13/16/24/40px); generous letter-spacing on uppercase micro-labels. Signature: zero boxes — hierarchy purely typographic: rows separated by 1px hairlines, session project set large (24px light), metadata in 11px uppercase tracked labels; effort = four thin rules of increasing weight (1/2/3/4px bars, red when lit); active/hover = red text, nothing else; menus are borderless floating type columns with a red index number per item (01, 02…); picker = editorial index page (huge input, numbered option list); toasts = single red rule + text bottom-right; transitions: none (instant), pending = red underline only.
- [ ] **Step 3: Verify** checklist. **Step 4: Commit** `feat(design-lab): swiss minimal variant`

---

### Task 9: Variant 06 — Synthwave Arcade

**Files:** Create `design-lab/variants/06-synthwave-arcade/index.html`, `style.css`

- [ ] **Step 1: index.html** from template (slug `synthwave-arcade`).
- [ ] **Step 2: style.css** — Tokens: sky gradient `linear-gradient(#1a0533, #ff2975 85%, #ff8c42)`, horizon grid floor (perspective `linear-gradient` lines, `transform: perspective() rotateX()` strip at bottom), neon pink `#ff2975`, cyan `#00f0ff`, chrome text via `background: linear-gradient(#eee, #999, #fff) ; -webkit-background-clip: text`. Fonts: bold condensed stack for display, mono for data. Signature: dropdown = high-score table (RANK/PLAYER/MODEL/PWR columns, session rows as entries); applying = neon pulse traveling the row border (animated `box-shadow`); badge = arcade token (circular, coin-edge dashed border, spins on expand); picker = "INSERT COIN" attract screen framing, blinking `PRESS ENTER`; clamped toast = VHS tracking bar (skewed noise stripe) with `SIGNAL LIMITED — ORG POLICY`; star field dots on sky via multiple `radial-gradient` backgrounds.
- [ ] **Step 3: Verify** checklist. **Step 4: Commit** `feat(design-lab): synthwave arcade variant`

---

### Task 10: Variant 07 — E-Ink Paper

**Files:** Create `design-lab/variants/07-eink-paper/index.html`, `style.css`

- [ ] **Step 1: index.html** from template (slug `eink-paper`).
- [ ] **Step 2: style.css** — Tokens: warm paper `#f4efe6`, ink `#2b2925`, faded `#8a857c`, stamp red `#b5442e`. Fonts: serif display `Georgia, 'Iowan Old Style', serif` for headings, humanist `Seravek, Verdana, sans-serif` body. Signature: paper grain via subtle repeating noise (two layered `radial-gradient` dot patterns at 3px/7px, opacity .04); zero glow, zero saturation outside stamp red; chips = rubber-stamped labels (1.5px slightly-rotated borders `transform: rotate(-1deg)`, ink-bleed `text-shadow: 0 0 .4px`); state dots = pencil-shaded circles; menus/pickers unfold with a page-turn (single `transform: rotateX` from top, 200ms, disabled under reduced motion); e-ink "refresh" on apply: brief full-invert flash then settle (like a real e-reader page change); toasts = margin notes in italic serif with a manicule ☞.
- [ ] **Step 3: Verify** checklist. **Step 4: Commit** `feat(design-lab): e-ink paper variant`

---

### Task 11: Variant 08 — Avionics Cockpit

**Files:** Create `design-lab/variants/08-avionics-cockpit/index.html`, `style.css`

- [ ] **Step 1: index.html** from template (slug `avionics-cockpit`).
- [ ] **Step 2: style.css** — Tokens: panel charcoal `#1b1d1f` with brushed texture (fine vertical `repeating-linear-gradient`), instrument green `#7dff9b`, amber `#ffb648`, red `#ff5f4d`, off-white stencil `#e8e6e0`. Fonts: stencil-feel condensed uppercase for panel labels, mono for readouts. Signature: each dropdown row = an instrument cluster: effort rendered as an analog gauge (conic-gradient arc dial with a needle `div` rotated `transform: rotate(calc(...))` proportional to effort rank); model = rotary selector look (circular knob with position ticks); states as annunciator lights — small rectangular caption lights `IDLE`/`WORK`/`HOLD` that illuminate; screws in panel corners (radial-gradient circles); clamp = amber `CAUTION` strip with diagonal hatching sliding in; read-only = `INOP` placard; picker = center MFD screen with green phosphor text and soft CRT curvature (`border-radius` + inner shadow vignette).
- [ ] **Step 3: Verify** checklist. **Step 4: Commit** `feat(design-lab): avionics cockpit variant`

---

### Task 12: Variant 09 — Blueprint

**Files:** Create `design-lab/variants/09-blueprint/index.html`, `style.css`

- [ ] **Step 1: index.html** from template (slug `blueprint`).
- [ ] **Step 2: style.css** — Tokens: blueprint blue `#123a75` (subtle grid: 1px lines every 24px + heavier every 120px via layered `linear-gradient`s), line white `#dce9ff`, cyan accent `#7ed0ff`. Fonts: drafting feel — `'Futura', 'Century Gothic', sans-serif` uppercase for labels, mono for dims. Signature: every panel drawn as schematic line work — 1px white borders, no fills; dimension lines with arrowheads (`::before/::after` triangles) annotating the dropdown width ("SESSIONS — QTY 6"); each window/badge labeled with section markers (`A-A'`, `B-B'`); title block in bottom-right corner of desktop (project name, "SCALE 1:1", "DWG NO. SS-001", date); effort bars = crosshatched rect fills; pending = dashed outline marching (`stroke-dashoffset`-style via animated `background-position` dashed border image or animated `outline` offset); toasts stamped `REV A — APPROVED` / `HOLD — POLICY` in a revision-table box.
- [ ] **Step 3: Verify** checklist. **Step 4: Commit** `feat(design-lab): blueprint variant`

---

### Task 13: Variant 10 — Clay Pop

**Files:** Create `design-lab/variants/10-clay-pop/index.html`, `style.css`

- [ ] **Step 1: index.html** from template (slug `clay-pop`).
- [ ] **Step 2: style.css** — Tokens: candy pastels — bg `#fdf1f5`, panels `#ffffff`, lilac `#c9b6ff`, mint `#a8e6c9`, butter `#ffe29a`, bubblegum `#ff9ec6`, ink `#4a3f5c`. Font: rounded sans stack `'SF Pro Rounded', 'Arial Rounded MT Bold', 'Comic Sans MS', sans-serif`. Signature: claymorphism — chunky 20px+ radii, double shadow (outer soft drop + inset top-light `inset 0 4px 8px rgba(255,255,255,.8), inset 0 -6px 10px rgba(0,0,0,.06)`); every interactive squishes on `:active` (`transform: scale(.94)`); effort = stacked clay bars that plump when lit; badge = jelly button with idle wobble keyframes (disabled under reduced motion); verified apply fires a confetti micro-burst implemented purely in CSS on the verified toast: its `::before`/`::after` pseudo-elements render 2 pastel squares each and animate outward/rotating for 600 ms as the toast appears; rejected = gentle head-shake (`translateX` 3 keyframes); state dots = googly-eye style (white circle + dark pupil offset per state).
- [ ] **Step 3: Verify** checklist. **Step 4: Commit** `feat(design-lab): clay pop variant`

---

### Task 14: Final QA sweep + push

**Files:** none new (fixes only, any file)

- [ ] **Step 1:** `node design-lab/shared/engine.test.mjs` → all assertions pass.
- [ ] **Step 2:** Serve and walk hub: all 10 cards render live previews, no 404s, no console errors on any page.
- [ ] **Step 3:** Run the per-variant acceptance checklist on all 10 variants; run ←/→ full cycle from variant 01 through 10 back to 01; digits jump; `.ss-attention` visible on menubar item (s3 awaits) in every variant.
- [ ] **Step 4:** Fix anything found; commit fixes as `fix(design-lab): qa sweep`.
- [ ] **Step 5:** `git push`.
