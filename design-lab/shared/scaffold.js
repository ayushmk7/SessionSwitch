import * as engine from './engine.js';
import { VARIANTS } from './variants.js';
import { EFFORT_ORDER } from './data.js';

const BAR_CHARS = ['▁', '▃', '▅', '▇'];
const MODE_ORDER = ['model', 'effort', 'preset'];

// ui: transient interaction state, independent of engine state.
// Dropdown open/closed is NOT tracked here — it lives directly on the
// persistent .ss-dropdown node's classList (see wireDropdownToggle).
let ui = {
  menu: null,                                   // { sid, kind: 'model'|'effort'|'preset' } | null
  badgeOpen: null,                               // sid | null
  picker: { open: false, query: '', mode: 'model', idx: 0 },
};

let currentVariant = null;

// persistent DOM handles, created once in buildStaticDom()
let appEl, dropdownEl, toastWrapEl;
let windowEls = {};
let pickerEl, pickerInputEl, pickerSessionEl, pickerModesEl, pickerListEl;

export function mount({ variant }) {
  currentVariant = variant;
  engine.init();
  document.body.className = `ss v-${variant}`;
  injectStructureCss();
  buildStaticDom();
  wireKeyboard();
  engine.subscribe(render);
  render(engine.getState());
}

// ---------------------------------------------------------------------------
// bootstrap
// ---------------------------------------------------------------------------

function injectStructureCss() {
  const link = document.createElement('link');
  link.rel = 'stylesheet';
  link.href = '../../shared/structure.css';
  document.head.appendChild(link);
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function buildStaticDom() {
  // menu bar
  const menubar = el('div', 'ss-menubar');
  appEl = el('div', 'ss-menubar-app', 'SessionSwitch ▾');
  const clock = el('div', 'ss-menubar-clock', 'Mon 9:41 AM');
  menubar.append(appEl, clock);

  // dropdown (persistent shell; content rebuilt in render())
  dropdownEl = el('div', 'ss-dropdown');
  wireDropdownToggle();

  // desktop + fake terminal windows
  const desktop = el('div', 'ss-desktop');
  ['w1', 'w2'].forEach(wid => {
    const win = el('div', 'ss-window');
    win.id = wid;
    const title = el('div', 'ss-window-title');
    const body = el('div', 'ss-window-body');
    body.appendChild(document.createElement('pre'));
    win.append(title, body);
    win.addEventListener('click', e => {
      if (e.target.closest('.ss-badge')) return;
      const s = engine.getState().sessions.find(x => x.window === wid);
      if (!s) return;
      ui.menu = null;
      engine.focusSession(s.id);
      render(engine.getState());
    });
    desktop.appendChild(win);
    windowEls[wid] = win;
  });

  // quick picker shell (persistent; input never destroyed so typing keeps focus)
  pickerEl = el('div', 'ss-picker');
  pickerInputEl = document.createElement('input');
  pickerInputEl.className = 'ss-picker-input';
  pickerInputEl.type = 'text';
  pickerInputEl.autocomplete = 'off';
  pickerInputEl.spellcheck = false;
  pickerInputEl.placeholder = 'Jump to a session…';
  pickerInputEl.addEventListener('input', () => {
    ui.picker.query = pickerInputEl.value;
    ui.picker.idx = 0;
    render(engine.getState());
  });
  pickerSessionEl = el('div', 'ss-picker-session');
  pickerModesEl = el('div', 'ss-picker-modes');
  pickerListEl = el('div', 'ss-picker-list');
  pickerEl.append(pickerInputEl, pickerSessionEl, pickerModesEl, pickerListEl);

  // toast stack (persistent; toasts appended directly by showToast())
  toastWrapEl = el('div', 'ss-toast-wrap');

  // lab link
  const labLink = document.createElement('a');
  labLink.className = 'ss-lab-link';
  labLink.href = '../../index.html';
  labLink.textContent = '← Lab';

  document.body.append(menubar, dropdownEl, desktop, pickerEl, toastWrapEl, labLink);
}

function wireDropdownToggle() {
  appEl.addEventListener('click', () => {
    const opening = !dropdownEl.classList.contains('ss-open');
    dropdownEl.classList.toggle('ss-open');
    if (!opening) {
      ui.menu = null;
      render(engine.getState());
    }
  });
}

// ---------------------------------------------------------------------------
// render — full rebuild of dropdown / badges / picker from engine state + ui
// ---------------------------------------------------------------------------

function render(state) {
  appEl.classList.toggle('ss-attention', state.sessions.some(s => s.state === 'awaiting'));
  renderDropdown(state);
  renderWindows(state);
  renderPicker(state);
}

function pendingKind(s) {
  if (!s.pending) return null;
  if (s.pending.startsWith('model ')) return 'model';
  if (s.pending.startsWith('effort ')) return 'effort';
  if (s.pending.startsWith('preset ')) return 'preset';
  return null;
}

function buildEffortBars(s, m) {
  const wrap = el('span', 'ss-effort-bars');
  const lit = m.efforts.length === 0 ? 0 : EFFORT_ORDER.indexOf(s.effort) + 1;
  BAR_CHARS.forEach((ch, i) => {
    const bar = el('span', i < lit ? 'on' : null, ch);
    wrap.appendChild(bar);
  });
  wrap.title = m.efforts.length === 0 ? `${m.name}: no effort control` : '';
  return wrap;
}

function openMenu(sid, kind) {
  ui.menu = (ui.menu && ui.menu.sid === sid && ui.menu.kind === kind) ? null : { sid, kind };
  render(engine.getState());
}

function buildMenu(s, state, kind) {
  const menu = el('div', 'ss-menu');
  let items;
  if (kind === 'model') {
    items = state.models.map(m => ({
      label: m.name, hint: m.hint, active: m.id === s.model,
      run: () => engine.applyModel(s.id, m.id),
    }));
  } else if (kind === 'effort') {
    items = engine.validEfforts(s.model).map(level => ({
      label: level, hint: '', active: level === s.effort,
      run: () => engine.applyEffort(s.id, level),
    }));
  } else {
    items = state.presets.map(p => ({
      label: p.name, hint: '', active: false,
      run: () => engine.applyPreset(s.id, p.id),
    }));
  }
  items.forEach(it => {
    const item = el('div', 'ss-menu-item' + (it.active ? ' is-active' : ''), it.label);
    if (it.hint) item.title = it.hint;
    item.addEventListener('click', e => {
      e.stopPropagation();
      ui.menu = null;
      it.run().then(showToast);
      render(engine.getState());
    });
    menu.appendChild(item);
  });
  return menu;
}

function buildRow(s, state) {
  const stateClass = `is-${s.state}`;
  const roClass = s.flags.includes('read-only') ? ' is-readonly' : '';
  const row = el('div', `ss-row ${stateClass}${roClass}`);
  row.dataset.sid = s.id;

  const dot = el('span', 'ss-state-dot');
  const proj = el('span', 'ss-row-project', s.project);
  const term = el('span', 'ss-row-terminal', s.terminal);

  const m = engine.model(s.model);
  const pk = pendingKind(s);

  const modelChip = el('div', 'ss-chip-model' + (pk === 'model' ? ' is-pending' : ''), m.name);
  modelChip.addEventListener('click', e => {
    e.stopPropagation();
    openMenu(s.id, 'model');
  });

  const effortChip = el('div', 'ss-chip-effort' + (pk === 'effort' ? ' is-pending' : ''));
  effortChip.appendChild(buildEffortBars(s, m));
  effortChip.addEventListener('click', e => {
    e.stopPropagation();
    engine.cycleEffort(s.id).then(showToast);
  });
  effortChip.addEventListener('contextmenu', e => {
    e.preventDefault();
    e.stopPropagation();
    openMenu(s.id, 'effort');
  });

  const presetChip = el('div', 'ss-row-preset' + (pk === 'preset' ? ' is-pending' : ''), 'preset ▸');
  presetChip.addEventListener('click', e => {
    e.stopPropagation();
    openMenu(s.id, 'preset');
  });

  row.append(dot, proj, term, modelChip, effortChip, presetChip);

  if (ui.menu && ui.menu.sid === s.id) {
    const anchor = ui.menu.kind === 'model' ? modelChip
      : ui.menu.kind === 'effort' ? effortChip
        : presetChip;
    anchor.appendChild(buildMenu(s, state, ui.menu.kind));
  }

  row.addEventListener('click', () => {
    ui.menu = null;
    engine.focusSession(s.id);
    render(engine.getState());
  });

  return row;
}

function buildFooter() {
  const footer = el('div', 'ss-dropdown-footer');
  const newBtn = document.createElement('button');
  newBtn.type = 'button';
  newBtn.textContent = 'New Session…';
  const refreshBtn = document.createElement('button');
  refreshBtn.type = 'button';
  refreshBtn.textContent = 'Refresh';
  footer.append(newBtn, refreshBtn);
  return footer;
}

function renderDropdown(state) {
  dropdownEl.innerHTML = '';
  state.sessions.forEach(s => dropdownEl.appendChild(buildRow(s, state)));
  dropdownEl.appendChild(buildFooter());
}

// ---------------------------------------------------------------------------
// badges + windows
// ---------------------------------------------------------------------------

function buildBadgeCol(items) {
  const col = el('div', 'ss-badge-col');
  items.forEach(it => {
    const item = el('div', 'ss-menu-item' + (it.active ? ' is-active' : ''), it.label);
    item.addEventListener('click', e => {
      e.stopPropagation();
      ui.badgeOpen = null;
      it.run().then(showToast);
      render(engine.getState());
    });
    col.appendChild(item);
  });
  return col;
}

function buildBadge(s, m, state) {
  const badge = el('div', 'ss-badge' + (ui.badgeOpen === s.id ? ' is-open' : ''));
  badge.dataset.sid = s.id;

  const summary = el('div', 'ss-badge-summary');
  summary.appendChild(el('span', null, m.name));
  summary.appendChild(buildEffortBars(s, m));
  summary.addEventListener('click', e => {
    e.stopPropagation();
    ui.badgeOpen = ui.badgeOpen === s.id ? null : s.id;
    render(engine.getState());
  });
  badge.appendChild(summary);

  if (ui.badgeOpen === s.id) {
    const panel = el('div', 'ss-badge-panel');
    const modelCol = buildBadgeCol(state.models.map(mo => ({
      label: mo.name, active: mo.id === s.model,
      run: () => engine.applyModel(s.id, mo.id),
    })));
    const effortCol = buildBadgeCol(engine.validEfforts(s.model).map(level => ({
      label: level, active: level === s.effort,
      run: () => engine.applyEffort(s.id, level),
    })));
    const presetCol = buildBadgeCol(state.presets.map(p => ({
      label: p.name, active: false,
      run: () => engine.applyPreset(s.id, p.id),
    })));
    panel.append(modelCol, effortCol, presetCol);
    badge.appendChild(panel);
  }

  return badge;
}

function fakeTerminalBody(s, m) {
  const stateLine = { idle: '$ ', working: '… working', awaiting: '? awaiting your input' }[s.state] ?? '$ ';
  const effortPart = s.effort ? ` --effort=${s.effort}` : '';
  const flagPart = s.flags.length ? ` [${s.flags.join(', ')}]` : '';
  return `${s.project}${flagPart}\n${s.terminal} · ${m.name}${effortPart}\n${stateLine}`;
}

function renderWindows(state) {
  ['w1', 'w2'].forEach(wid => {
    const winEl = windowEls[wid];
    const s = state.sessions.find(x => x.window === wid);
    if (!s) {
      winEl.style.display = 'none';
      return;
    }
    winEl.style.display = '';
    winEl.classList.toggle('is-front', s.id === state.focusedId);

    const m = engine.model(s.model);
    winEl.querySelector('.ss-window-title').textContent = `${s.terminal} — ${s.project}`;
    winEl.querySelector('.ss-window-body pre').textContent = fakeTerminalBody(s, m);

    const oldBadge = winEl.querySelector('.ss-badge');
    if (oldBadge) oldBadge.remove();
    winEl.appendChild(buildBadge(s, m, state));
  });
}

// ---------------------------------------------------------------------------
// quick picker (⌘K)
// ---------------------------------------------------------------------------

function pickerTarget(state) {
  const q = ui.picker.query.trim().toLowerCase();
  if (q) {
    const match = state.sessions.find(s => s.project.toLowerCase().includes(q));
    if (match) return match;
  }
  return state.sessions.find(s => s.id === state.focusedId) ?? state.sessions[0];
}

function pickerOptions(state, target) {
  if (ui.picker.mode === 'model') {
    return state.models.map(m => ({ key: m.id, label: m.name, active: m.id === target.model }));
  }
  if (ui.picker.mode === 'effort') {
    return engine.validEfforts(target.model).map(level => ({ key: level, label: level, active: level === target.effort }));
  }
  return state.presets.map(p => ({ key: p.id, label: p.name, active: false }));
}

function applyPickerChoice(target, key) {
  const mode = ui.picker.mode;
  closePicker();
  const promise = mode === 'model' ? engine.applyModel(target.id, key)
    : mode === 'effort' ? engine.applyEffort(target.id, key)
      : engine.applyPreset(target.id, key);
  promise.then(showToast);
}

function renderPicker(state) {
  pickerEl.classList.toggle('ss-open', ui.picker.open);

  if (pickerInputEl.value !== ui.picker.query) pickerInputEl.value = ui.picker.query;

  const target = pickerTarget(state);
  const opts = pickerOptions(state, target);
  if (ui.picker.idx >= opts.length) ui.picker.idx = Math.max(0, opts.length - 1);

  pickerSessionEl.textContent = `${target.project} · ${target.terminal}`;

  pickerModesEl.innerHTML = '';
  MODE_ORDER.forEach(mode => {
    const tab = el('div', 'ss-picker-mode' + (ui.picker.mode === mode ? ' is-active' : ''), mode);
    tab.addEventListener('click', () => {
      ui.picker.mode = mode;
      ui.picker.idx = 0;
      render(engine.getState());
    });
    pickerModesEl.appendChild(tab);
  });

  pickerListEl.innerHTML = '';
  opts.forEach((opt, i) => {
    const item = el('div', 'ss-picker-option' + (i === ui.picker.idx ? ' is-active' : ''), opt.label);
    item.addEventListener('click', () => applyPickerChoice(target, opt.key));
    pickerListEl.appendChild(item);
  });
}

function togglePicker() {
  if (ui.picker.open) {
    closePicker();
  } else {
    ui.picker = { open: true, query: '', mode: 'model', idx: 0 };
    render(engine.getState());
    pickerInputEl.value = '';
    pickerInputEl.focus();
  }
}

function closePicker() {
  ui.picker = { open: false, query: '', mode: 'model', idx: 0 };
  render(engine.getState());
  pickerInputEl.value = '';
  pickerInputEl.blur();
}

// ---------------------------------------------------------------------------
// keyboard
// ---------------------------------------------------------------------------

function wireKeyboard() {
  document.addEventListener('keydown', e => {
    if (e.metaKey && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      togglePicker();
      return;
    }
    if (ui.picker.open) {
      handlePickerKey(e);
    } else {
      handleNavKey(e);
    }
  });
}

function handlePickerKey(e) {
  const state = engine.getState();
  const target = pickerTarget(state);
  const opts = pickerOptions(state, target);

  if (e.key === 'Tab') {
    e.preventDefault();
    ui.picker.mode = MODE_ORDER[(MODE_ORDER.indexOf(ui.picker.mode) + 1) % MODE_ORDER.length];
    ui.picker.idx = 0;
    render(engine.getState());
  } else if (e.key === 'ArrowDown') {
    e.preventDefault();
    if (opts.length) ui.picker.idx = (ui.picker.idx + 1) % opts.length;
    render(engine.getState());
  } else if (e.key === 'ArrowUp') {
    e.preventDefault();
    if (opts.length) ui.picker.idx = (ui.picker.idx - 1 + opts.length) % opts.length;
    render(engine.getState());
  } else if (e.key === 'Enter') {
    e.preventDefault();
    if (opts.length) applyPickerChoice(target, opts[ui.picker.idx].key);
  } else if (e.key === 'Escape') {
    e.preventDefault();
    closePicker();
  }
}

function handleNavKey(e) {
  if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
    e.preventDefault();
    const idx = VARIANTS.findIndex(v => v.dir.slice(3) === currentVariant);
    if (idx === -1) return;
    const delta = e.key === 'ArrowLeft' ? -1 : 1;
    const next = (idx + delta + VARIANTS.length) % VARIANTS.length;
    location.href = `../${VARIANTS[next].dir}/`;
    return;
  }
  if (/^[0-9]$/.test(e.key)) {
    e.preventDefault();
    const n = e.key === '0' ? 10 : Number(e.key);
    const target = VARIANTS[n - 1];
    if (target) location.href = `../${target.dir}/`;
  }
}

// ---------------------------------------------------------------------------
// toasts
// ---------------------------------------------------------------------------

function showToast(result) {
  if (!result) return;
  const toast = el('div', `ss-toast is-${result.status}`);
  const appliedText = result.applied ?? 'rejected';
  const reasonPart = result.reason ? ` · ${result.reason}` : '';
  toast.textContent = `${result.requested} → ${appliedText}${reasonPart}`;
  toastWrapEl.appendChild(toast);
  setTimeout(() => toast.remove(), 3500);
}
