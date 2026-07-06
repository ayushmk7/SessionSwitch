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
