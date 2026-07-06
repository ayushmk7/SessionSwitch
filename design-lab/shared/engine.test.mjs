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
