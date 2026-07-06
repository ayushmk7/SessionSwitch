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
