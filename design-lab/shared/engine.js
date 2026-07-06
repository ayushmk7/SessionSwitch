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
  const m = model(s.model);
  if (s.flags.includes('read-only')) {
    return reject(s, `effort ${level}`, 'read-only session (SSH remote)');
  }
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
  const m = model(s.model);
  if (s.flags.includes('read-only')) {
    return reject(s, 'effort', 'read-only session (SSH remote)');
  }
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
