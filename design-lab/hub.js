import { VARIANTS } from './shared/variants.js';

// ---------------------------------------------------------------------------
// build
// ---------------------------------------------------------------------------

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function digitFor(index) {
  // card 1-9 => '1'-'9', card 10 (index 9) => '0'
  return index === 9 ? '0' : String(index + 1);
}

function buildHeader() {
  const header = el('header', 'hub-header');
  header.append(
    el('h1', 'hub-title', 'SessionSwitch Design Lab'),
    el('p', 'hub-count', `${VARIANTS.length} interactive design directions — pick one`),
    el('p', 'hub-hints', '←/→ cycle · 1–0 jump · ⌘K opens the quick picker inside a variant'),
  );
  return header;
}

function observeScale(frame, iframe) {
  const ro = new ResizeObserver(entries => {
    for (const entry of entries) {
      const width = entry.contentRect.width;
      iframe.style.transform = `scale(${width / 1280})`;
    }
  });
  ro.observe(frame);
}

function buildCard(variant, index) {
  const card = document.createElement('a');
  card.className = 'hub-card';
  card.href = `variants/${variant.dir}/`;

  const frame = el('div', 'hub-frame');
  frame.appendChild(el('span', 'hub-kbd', digitFor(index)));

  const iframe = document.createElement('iframe');
  iframe.src = `variants/${variant.dir}/`;
  iframe.loading = 'lazy';
  iframe.tabIndex = -1;
  iframe.setAttribute('aria-hidden', 'true');
  iframe.setAttribute('title', variant.name);
  frame.appendChild(iframe);
  observeScale(frame, iframe);

  const caption = el('div', 'hub-caption');
  caption.append(
    el('span', 'hub-name', variant.name),
    el('span', 'hub-vibe', variant.vibe),
  );

  card.append(frame, caption);
  return card;
}

function buildGrid() {
  const grid = el('div', 'hub-grid');
  VARIANTS.forEach((variant, index) => grid.appendChild(buildCard(variant, index)));
  return grid;
}

function render() {
  document.body.append(buildHeader(), buildGrid());
}

// ---------------------------------------------------------------------------
// keyboard: digits jump to a variant, ←/→ go to last/first variant
// ---------------------------------------------------------------------------

function goToVariant(index) {
  const target = VARIANTS[index];
  if (target) location.href = `variants/${target.dir}/`;
}

function wireKeyboard() {
  document.addEventListener('keydown', e => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === 'ArrowLeft') {
      e.preventDefault();
      goToVariant(VARIANTS.length - 1);
      return;
    }
    if (e.key === 'ArrowRight') {
      e.preventDefault();
      goToVariant(0);
      return;
    }
    if (/^[0-9]$/.test(e.key)) {
      e.preventDefault();
      const n = e.key === '0' ? 10 : Number(e.key);
      goToVariant(n - 1);
    }
  });
}

render();
wireKeyboard();
