/* Ink — web version of the macOS board.
   Same model and same .ink file format, so files move between the two.
   World coordinates here are y-down (screen-like); the .ink format is y-up
   (CoreGraphics), so I/O flips the sign. */

const bg = document.getElementById('bg');
const ink = document.getElementById('ink');
const overlay = document.getElementById('overlay');
const stage = document.getElementById('stage');
const hintEl = document.getElementById('hint');
const bgx = bg.getContext('2d');
const ctx = ink.getContext('2d');

const PEN_PALETTE = [
  '#000000', '#7f8085', '#e74c3c', '#e67e22', '#f1c40f',
  '#2ecc71', '#1abc9c', '#3498db', '#5b6ef5', '#9b59b6', '#e84393',
];

/** A highlighter case holds five fluorescent barrels, not eleven inks —
    these are the Monami Adding Super colours. */
const HL_PALETTE = ['#ff2e88', '#ff8a1e', '#ffe800', '#7cd80a', '#3bbdf5'];

const state = {
  strokes: [],
  items: [],            // {id, type:'card'|'img', x, y, w, h, source?, src?, el}
  cam: { x: -400, y: -300, z: 1 },
  tool: 'select',
  lastInk: 'pen',
  // pen and highlighter remember their own colour, like a real pen case
  inkColors: { pen: '#000000', highlighter: '#ffe800' },
  size: 3,
  sel: { strokes: [], items: [] },
  live: null,           // stroke being drawn
  marquee: null,
  space: false,
};

let nextId = 1;
const undoStack = [];
const redoStack = [];

/* ------------------------------------------------------------- geometry */

const toWorld = (px, py) => [px / state.cam.z + state.cam.x, py / state.cam.z + state.cam.y];

/** Which colour slot the toolbar is editing right now. */
const activeInk = () =>
  (state.tool === 'ink' && state.lastInk === 'highlighter') ? 'highlighter' : 'pen';
const currentColor = () => state.inkColors[activeInk()];

function strokeBounds(s) {
  let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
  for (const [x, y] of s.pts) {
    if (x < x1) x1 = x; if (y < y1) y1 = y;
    if (x > x2) x2 = x; if (y > y2) y2 = y;
  }
  const p = s.width;
  return { x: x1 - p, y: y1 - p, w: x2 - x1 + p * 2, h: y2 - y1 + p * 2 };
}

function contentBounds() {
  let b = null;
  const grow = (r) => {
    if (!b) { b = { ...r }; return; }
    const x2 = Math.max(b.x + b.w, r.x + r.w), y2 = Math.max(b.y + b.h, r.y + r.h);
    b.x = Math.min(b.x, r.x); b.y = Math.min(b.y, r.y);
    b.w = x2 - b.x; b.h = y2 - b.y;
  };
  state.strokes.forEach((s) => grow(strokeBounds(s)));
  state.items.forEach((i) => grow({ x: i.x, y: i.y, w: i.w, h: i.h }));
  return b;
}

function distToSeg(px, py, ax, ay, bx, by) {
  const dx = bx - ax, dy = by - ay;
  const len = dx * dx + dy * dy;
  let t = len ? ((px - ax) * dx + (py - ay) * dy) / len : 0;
  t = Math.max(0, Math.min(1, t));
  const cx = ax + t * dx, cy = ay + t * dy;
  return Math.hypot(px - cx, py - cy);
}

function strokeSegments(s) {
  if (s.kind === 'rect' && s.pts.length >= 2) {
    const [a, b] = s.pts;
    const c2 = [b[0], a[1]], c4 = [a[0], b[1]];
    return [[a, c2], [c2, b], [b, c4], [c4, a]];
  }
  const out = [];
  for (let i = 0; i < s.pts.length - 1; i++) out.push([s.pts[i], s.pts[i + 1]]);
  return out;
}

function strokeHit(s, x, y, tol) {
  const t = tol + s.width / 2;
  const segs = strokeSegments(s);
  if (!segs.length) {
    const [p] = s.pts;
    return p && Math.hypot(p[0] - x, p[1] - y) <= t;
  }
  return segs.some(([a, b]) => distToSeg(x, y, a[0], a[1], b[0], b[1]) <= t);
}

/** Did the eraser path a→b touch this stroke? Segment-vs-segment, so a fast
    wipe can't slip between two pointer events. */
function strokeCrossed(s, ax, ay, bx, by, tol) {
  const t = tol + s.width / 2;
  const segs = strokeSegments(s);
  if (!segs.length) {
    const [p] = s.pts;
    return p && distToSeg(p[0], p[1], ax, ay, bx, by) <= t;
  }
  const orient = (px, py, qx, qy, rx, ry) => (qx - px) * (ry - py) - (qy - py) * (rx - px);
  for (const [p1, p2] of segs) {
    const d1 = orient(ax, ay, bx, by, p1[0], p1[1]);
    const d2 = orient(ax, ay, bx, by, p2[0], p2[1]);
    const d3 = orient(p1[0], p1[1], p2[0], p2[1], ax, ay);
    const d4 = orient(p1[0], p1[1], p2[0], p2[1], bx, by);
    if ((d1 > 0) !== (d2 > 0) && (d3 > 0) !== (d4 > 0)) return true;
    if (Math.min(
      distToSeg(p1[0], p1[1], ax, ay, bx, by),
      distToSeg(p2[0], p2[1], ax, ay, bx, by),
      distToSeg(ax, ay, p1[0], p1[1], p2[0], p2[1]),
      distToSeg(bx, by, p1[0], p1[1], p2[0], p2[1]),
    ) <= t) return true;
  }
  return false;
}

const rectsOverlap = (a, b) =>
  a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;

/* -------------------------------------------------------------- history */

function snapshot() {
  return JSON.stringify({
    strokes: state.strokes,
    // The pictures can't survive JSON — an Image or a canvas comes back as
    // `{}`, and drawing that throws. They're rebuilt from the source anyway.
    items: state.items.map(({ el, svg, bmp, bmpScale, baking, imgEl, ...rest }) => rest),
  });
}

function pushUndo() {
  undoStack.push(snapshot());
  if (undoStack.length > 80) undoStack.shift();
  redoStack.length = 0;
  notifyDirty();
}

function restore(snap) {
  const data = JSON.parse(snap);
  state.strokes = data.strokes;
  state.items.forEach((i) => i.el.remove());
  state.items = [];
  data.items.forEach((it) => {
    const item = { ...it };
    item.el = it.type === 'card' ? buildCardEl(it.source) : buildImgEl(it.src);
    overlay.appendChild(item.el);
    state.items.push(item);
    if (item.type === 'card') trackCard(item); else attachImage(item);
  });
  state.sel = { strokes: [], items: [] };
  syncItems();
  draw();
}

function undo() {
  if (!undoStack.length) return;
  redoStack.push(snapshot());
  restore(undoStack.pop());
}

function redo() {
  if (!redoStack.length) return;
  undoStack.push(snapshot());
  restore(redoStack.pop());
}

/* --------------------------------------------------------------- render */

function resize() {
  const dpr = window.devicePixelRatio || 1;
  for (const c of [bg, ink]) {
    c.width = Math.round(stage.clientWidth * dpr);
    c.height = Math.round(stage.clientHeight * dpr);
  }
  bgx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  draw();
}

function drawGrid() {
  const w = stage.clientWidth, h = stage.clientHeight;
  bgx.clearRect(0, 0, w, h);
  bgx.fillStyle = '#fff';
  bgx.fillRect(0, 0, w, h);
  if (snapshotCam) return;   // exported images get plain paper, no grid

  let spacing = 40;
  while (spacing * state.cam.z < 22) spacing *= 2;
  const step = spacing * state.cam.z;
  const startX = -((state.cam.x % spacing) * state.cam.z);
  const startY = -((state.cam.y % spacing) * state.cam.z);
  bgx.fillStyle = '#c9cbd0';
  for (let x = startX; x < w + step; x += step) {
    for (let y = startY; y < h + step; y += step) {
      bgx.beginPath();
      bgx.arc(x, y, 1.4, 0, Math.PI * 2);
      bgx.fill();
    }
  }
}

function pathStroke(s) {
  const p = s.pts;
  ctx.beginPath();
  if (s.kind === 'rect' && p.length >= 2) {
    const [a, b] = p;
    ctx.rect(Math.min(a[0], b[0]), Math.min(a[1], b[1]),
             Math.abs(b[0] - a[0]), Math.abs(b[1] - a[1]));
    return;
  }
  if (!p.length) return;
  ctx.moveTo(p[0][0], p[0][1]);
  if (s.kind === 'line' || p.length < 3) {
    for (let i = 1; i < p.length; i++) ctx.lineTo(p[i][0], p[i][1]);
  } else {
    // quadratics through segment midpoints — mouse input reads as ink
    for (let i = 1; i < p.length - 1; i++) {
      const mx = (p[i][0] + p[i + 1][0]) / 2;
      const my = (p[i][1] + p[i + 1][1]) / 2;
      ctx.quadraticCurveTo(p[i][0], p[i][1], mx, my);
    }
    ctx.lineTo(p[p.length - 1][0], p[p.length - 1][1]);
  }
}

function drawStroke(s) {
  ctx.save();
  ctx.globalAlpha = s.kind === 'highlighter' ? 0.35 : 1;
  ctx.strokeStyle = s.color;
  ctx.fillStyle = s.color;
  ctx.lineWidth = s.width;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  if (s.pts.length === 1 && s.kind !== 'rect') {
    ctx.beginPath();
    ctx.arc(s.pts[0][0], s.pts[0][1], s.width / 2, 0, Math.PI * 2);
    ctx.fill();
  } else {
    pathStroke(s);
    ctx.stroke();
  }
  ctx.restore();
}

function selectionBounds() {
  let b = null;
  const grow = (r) => {
    if (!b) { b = { ...r }; return; }
    const x2 = Math.max(b.x + b.w, r.x + r.w), y2 = Math.max(b.y + b.h, r.y + r.h);
    b.x = Math.min(b.x, r.x); b.y = Math.min(b.y, r.y);
    b.w = x2 - b.x; b.h = y2 - b.y;
  };
  state.sel.strokes.forEach((s) => grow(strokeBounds(s)));
  state.sel.items.forEach((i) => grow({ x: i.x, y: i.y, w: i.w, h: i.h }));
  return b;
}

/** Pointer events arrive faster than the screen refreshes, so a drag that
    painted on every one of them did the same work several times a frame.
    Coalescing to one paint per frame is what makes dragging feel smooth. */
let drawPending = 0;
function drawSoon() {
  if (drawPending) return;
  drawPending = requestAnimationFrame(() => { drawPending = 0; draw(); });
}

function draw() {
  if (drawPending) { cancelAnimationFrame(drawPending); drawPending = 0; }
  drawGrid();
  const w = stage.clientWidth, h = stage.clientHeight;
  ctx.clearRect(0, 0, w, h);
  ctx.save();
  ctx.scale(state.cam.z, state.cam.z);
  ctx.translate(-state.cam.x, -state.cam.y);

  drawItems();
  state.strokes.forEach(drawStroke);
  if (state.live) drawStroke(state.live);

  const sel = selectionBounds();
  if (sel) {
    ctx.save();
    ctx.strokeStyle = '#2f7cf6';
    ctx.lineWidth = 1 / state.cam.z;
    ctx.setLineDash([4 / state.cam.z, 4 / state.cam.z]);
    ctx.strokeRect(sel.x - 4, sel.y - 4, sel.w + 8, sel.h + 8);
    ctx.restore();
    const solo = soloItem();
    if (solo) drawHandles(solo);

  }
  if (state.marquee) {
    const m = state.marquee;
    ctx.save();
    ctx.fillStyle = 'rgba(47,124,246,.10)';
    ctx.strokeStyle = '#2f7cf6';
    ctx.lineWidth = 1 / state.cam.z;
    ctx.fillRect(m.x, m.y, m.w, m.h);
    ctx.strokeRect(m.x, m.y, m.w, m.h);
    ctx.restore();
  }
  ctx.restore();
  syncItems();
}

/** Cards and images are bitmaps now, so painting them is one drawImage. */
function drawItems() {
  const interacting = !!drag;   // dragging: favour speed over sharpness
  for (const it of state.items) {
    let pic = null;
    if (it.type === 'card') pic = (interacting && it.bmp) ? it.bmp : (it.svg || it.bmp);
    else if (it.imgEl?.complete) pic = it.imgEl;
    if (pic) ctx.drawImage(pic, it.x, it.y, it.w, it.h);
    if (it.type === 'card' && !it.svg && !it.baking) bakeCard(it, 2);
  }
}

/** The hidden layout element only needs its natural width; it is never seen. */
function syncItems() {
  for (const it of state.items) {
    if (it.type === 'card') {
      ensureCardMetrics(it);
      it.el.style.width = it.nw + 'px';
    }
  }
}

/** The single selected item, when exactly one is picked. */
function soloItem() {
  return (state.sel.strokes.length === 0 && state.sel.items.length === 1)
    ? state.sel.items[0] : null;
}

const CORNERS = ['nw', 'ne', 'sw', 'se'];

function cornerPoint(item, c) {
  return [
    c === 'nw' || c === 'sw' ? item.x : item.x + item.w,
    c === 'nw' || c === 'ne' ? item.y : item.y + item.h,
  ];
}

function cornerHit(item, wx, wy) {
  const tol = 9 / state.cam.z;
  return CORNERS.find((c) => {
    const [cx, cy] = cornerPoint(item, c);
    return Math.abs(wx - cx) <= tol && Math.abs(wy - cy) <= tol;
  });
}

function drawHandles(item) {
  const s = 8 / state.cam.z;
  ctx.save();
  ctx.fillStyle = '#fff';
  ctx.strokeStyle = '#2f7cf6';
  ctx.lineWidth = 1.5 / state.cam.z;
  for (const c of CORNERS) {
    const [cx, cy] = cornerPoint(item, c);
    ctx.beginPath();
    ctx.rect(cx - s / 2, cy - s / 2, s, s);
    ctx.fill();
    ctx.stroke();
  }
  ctx.restore();
}

/** Aspect-locked corner drag, anchored at the opposite corner. */
function resizedRect(start, corner, x, y) {
  const ax = corner === 'nw' || corner === 'sw' ? start.x + start.w : start.x;
  const ay = corner === 'nw' || corner === 'ne' ? start.y + start.h : start.y;
  const aspect = start.w / start.h;
  let w = Math.abs(x - ax), h = Math.abs(y - ay);
  if (w / Math.max(h, 0.001) > aspect) h = w / aspect; else w = h * aspect;
  const min = 24 / state.cam.z;
  if (w < min) { w = min; h = w / aspect; }
  return {
    x: x < ax ? ax - w : ax,
    y: y < ay ? ay - h : ay,
    w, h,
  };
}

/* ------------------------------------------------------- baking cards */

/* Excalidraw is smooth because it paints text onto the canvas; a scaled DOM
   node re-lays-out and re-rasterises on every pointer move. Cards are laid
   out in a hidden element, baked once into a bitmap with the KaTeX fonts
   embedded, and from then on drawn like any other image. */

const BAKE_CAP = 4;          // don't bake finer than 4× board pixels
const CARD_MAX_W = 620;      // where a card starts wrapping
let cardStylePromise = null;

function cardStyleSheet() {
  if (cardStylePromise) return cardStylePromise;
  cardStylePromise = (async () => {
    const base = new URL('vendor/', location.href);
    let css = await fetch(new URL('katex.min.css', base)).then((r) => r.text());
    // A bitmap is rendered in an isolated context, so the fonts have to
    // travel with it — this is what the old export got wrong.
    const refs = [...new Set([...css.matchAll(/url\(([^)]+\.woff2)\)/g)]
      .map((m) => m[1].replace(/['"]/g, '')))];
    await Promise.all(refs.map(async (ref) => {
      try {
        const buf = await fetch(new URL(ref, base)).then((r) => r.arrayBuffer());
        let bin = '';
        new Uint8Array(buf).forEach((b) => { bin += String.fromCharCode(b); });
        css = css.split(ref).join('data:font/woff2;base64,' + btoa(bin));
      } catch { /* leave the reference; the glyph falls back */ }
    }));
    return css + CARD_BITMAP_CSS;
  })();
  return cardStylePromise;
}

const CARD_BITMAP_CSS = `
  .card {
    box-sizing: border-box;
    background: #fff; color: #111;
    padding: 10px 14px;
    /* Named fonts only: -apple-system resolves on the page but not inside an
       SVG image, and the two contexts then wrap text differently. */
    font: 15px/1.5 "Helvetica Neue", "Apple SD Gothic Neo", Helvetica, Arial, sans-serif;
  }
  .card > :first-child { margin-top: 0 } .card > :last-child { margin-bottom: 0 }
  .card h1 { font-size: 1.5em } .card h2 { font-size: 1.3em } .card h3 { font-size: 1.15em }
  .card table { border-collapse: collapse; margin: 8px 0 }
  .card th, .card td { border: 1px solid #c8c8c8; padding: 4px 10px }
  .card th { background: #f2f2f2 }
  .card code { background: #f2f2f2; padding: 1px 4px; border-radius: 3px; font-size: 13px }
  .card blockquote { margin: 8px 0; padding-left: 10px; border-left: 3px solid #ddd; color: #555 }
`;

/** Build the card's picture: an SVG image, which the canvas re-rasterises at
    whatever size it is drawn — so a card stays sharp however far you zoom —
    plus a flat bitmap used only while dragging, where re-rasterising every
    frame is what made the old DOM cards lag. */
/** The stylesheet belongs to the <svg>, not inside the card: as a child of the
    card it was its own `:first-child`, so the rule that zeroes the first
    paragraph's top margin hit the <style> and the text sat an em too low. */
function cardSVG(body, styles, w, h, sizing) {
  // `sizing` lets the card take its own width, up to the wrap limit, which is
  // how its natural size is found before it is drawn at that size.
  const style = sizing ? `width:max-content;max-width:${CARD_MAX_W}px` : `width:${w}px`;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}">`
    + `<style>${styles}</style>`
    + `<foreignObject width="100%" height="100%">`
    + `<div xmlns="http://www.w3.org/1999/xhtml" class="card" style="${style}">`
    + `${body}</div></foreignObject></svg>`;
}

function loadSVG(svg) {
  return new Promise((res, rej) => {
    const i = new Image();
    i.onload = () => res(i);
    i.onerror = rej;
    i.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  });
}

/** The size the card really came out at inside the SVG. The page and the SVG
    are separate documents and don't wrap text identically, so the page's
    measurement is only a starting guess — believing it cut long cards off at
    the bottom and folded short ones onto two lines. The card paints itself
    white, so the last row and column it painted are its size. */
function svgCardBounds(img, w, h) {
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.round(w));
  c.height = Math.max(1, Math.round(h));
  const g = c.getContext('2d');
  g.drawImage(img, 0, 0, c.width, c.height);
  const px = g.getImageData(0, 0, c.width, c.height).data;
  let right = 0, bottom = 0;
  for (let y = 0; y < c.height; y++) {
    const row = y * c.width * 4;
    for (let x = c.width - 1; x >= 0; x--) {
      if (px[row + x * 4 + 3] > 8) {
        if (x + 1 > right) right = x + 1;
        bottom = y + 1;
        break;
      }
    }
  }
  return [right, bottom];
}

async function bakeCard(item, scale) {
  if (item.baking) return;
  item.baking = true;
  try {
    const styles = await cardStyleSheet();
    let w = Math.max(1, Math.round(item.nw));
    let h = Math.max(1, Math.round(item.nh));
    const body = item.el.innerHTML;

    // Let the card lay itself out on a sheet big enough to hold it and read
    // back the width it wanted; then measure the height at that width, since
    // fixing the width is what the drawn card will actually get.
    const roomW = CARD_MAX_W + 40, roomH = h * 3 + 400;
    const wide = await loadSVG(cardSVG(body, styles, roomW, roomH, true));
    const [painted] = svgCardBounds(wide, roomW, roomH);
    // Whole pixels only, so the last fraction of the widest line is lost —
    // hand it back, or that line wraps when the width is pinned.
    const realW = painted ? painted + 1 : 0;
    const tall = realW
      ? await loadSVG(cardSVG(body, styles, realW, roomH))
      : null;
    const [, realH] = tall ? svgCardBounds(tall, realW, roomH) : [0, 0];
    if (realW && realH && (Math.abs(realW - w) > 1 || Math.abs(realH - h) > 1)) {
      // Keep any resize the user has applied while the natural size moves.
      const kw = item.nw ? item.w / item.nw : 1;
      const kh = item.nh ? item.h / item.nh : 1;
      item.nw = w = realW;
      item.nh = h = realH;
      item.w = realW * kw;
      item.h = realH * kh;
    }

    const img = await loadSVG(cardSVG(body, styles, w, h));
    item.svg = img;          // vector: sharp at any size
    const c = document.createElement('canvas');
    c.width = Math.max(1, Math.round(w * scale));
    c.height = Math.max(1, Math.round(h * scale));
    const g = c.getContext('2d');
    g.fillStyle = '#fff';
    g.fillRect(0, 0, c.width, c.height);
    g.scale(scale, scale);
    g.drawImage(img, 0, 0, w, h);
    item.bmp = c;
    item.bmpScale = scale;
    draw();
  } catch (e) {
    reportError('card bake failed', e && (e.message || e));
  } finally {
    item.baking = false;
  }
}

/** The drag stand-in only needs to match the size it is shown at. */
function needsBake(item) {
  const dpr = window.devicePixelRatio || 1;
  const want = Math.min(BAKE_CAP, state.cam.z * (item.w / (item.nw || item.w)) * dpr);
  if (!item.bmp) return Math.max(1, want);
  return want > item.bmpScale * 1.4 ? Math.min(BAKE_CAP, want) : 0;
}

/* ---------------------------------------------------------------- items */

function guardedMarkdown(src) {
  // Markdown eats LaTeX backslashes, so pull math out first and splice back.
  const math = [];
  const guarded = src.replace(/\$\$[\s\S]+?\$\$|\$[^\n$]+?\$/g, (m) => {
    math.push(m);
    return `@@MATH${math.length - 1}@@`;
  });
  let html = marked.parse(guarded);
  html = html.replace(/@@MATH(\d+)@@/g, (_, i) =>
    math[+i].replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'));
  return html;
}

function buildCardEl(source) {
  const el = document.createElement('div');
  el.className = 'item card';
  el.innerHTML = guardedMarkdown(source);
  renderMathInElement(el, {
    throwOnError: false,
    delimiters: [
      { left: '$$', right: '$$', display: true },
      { left: '$', right: '$', display: false },
    ],
  });
  return el;
}

function buildImgEl(src) {
  // a bare element keeps the item list uniform; the bitmap below is painted
  const el = document.createElement('div');
  el.className = 'item img';
  return el;
}

/** Pasted images are painted straight from an Image object. */
function attachImage(item) {
  const img = new Image();
  img.onload = () => draw();
  img.src = item.src;
  item.imgEl = img;
  return item;
}

/** Natural size of a card in world units. The element carries no transform
    while it's being measured, so its layout size *is* world size — dividing
    by the zoom here would shrink the box away from the rendered card. */
function measureCard(el) {
  el.style.transform = 'none';
  el.style.width = 'max-content';
  el.style.maxWidth = CARD_MAX_W + 'px';
  const w = Math.ceil(el.offsetWidth) || 320;
  const h = Math.ceil(el.offsetHeight) || 120;
  el.style.maxWidth = 'none';
  return [w, h];
}

/** A card's height changes after render — KaTeX swaps in its own fonts, images
    inside it load — and a stale height leaves the selection box cutting through
    the content. Watch the element instead of measuring once. */
const cardObserver = new ResizeObserver((entries) => {
  let changed = false;
  for (const entry of entries) {
    const item = state.items.find((i) => i.el === entry.target);
    if (!item) continue;
    const w = entry.target.offsetWidth;
    const h = entry.target.offsetHeight;
    if (!w || !h) continue;
    // Compare against what the page last reported, not against nh — the
    // height of record comes from the bake, and comparing the two would have
    // the observer and the bake overwrite each other forever.
    if (Math.abs(w - item.nw) < 0.5 && Math.abs(h - (item.domH ?? h)) < 0.5) continue;
    const scale = (item.nw ? item.w / item.nw : 1) || 1;   // keep any user resize
    if (!Number.isFinite(scale) || scale <= 0) continue;
    item.domH = h;
    item.nw = w;
    item.nh = h;
    item.w = w * scale;
    item.h = h * scale;
    item.bmp = null;     // natural size moved, so the picture is stale
    item.svg = null;
    changed = true;
  }
  if (changed) draw();
});

function trackCard(item) {
  ensureCardMetrics(item);
  cardObserver.observe(item.el);
}

/** A card is drawn at its natural layout size and scaled to the size it is
    shown at, so both are needed. Cards rebuilt from a file arrive with the
    display size only. */
function ensureCardMetrics(item) {
  if (item.type !== 'card' || (item.nw && item.nh)) return;
  const [w, h] = measureCard(item.el);
  item.nw = w;
  item.nh = h;
  item.domH = h;
  if (!item.w || !item.h) { item.w = w; item.h = h; }
}

function addCard(source, at) {
  const el = buildCardEl(source);
  overlay.appendChild(el);
  const [w, h] = measureCard(el);
  const c = at || centerWorld();
  const item = { id: nextId++, type: 'card', source, nw: w, nh: h, domH: h,
                 x: c[0] - w / 2, y: c[1] - h / 2, w, h, el };
  state.items.push(item);
  state.sel = { strokes: [], items: [item] };
  draw();
  trackCard(item);
  return item;
}

function addImage(src, w, h) {
  const el = buildImgEl(src);
  overlay.appendChild(el);
  const vis = Math.min(stage.clientWidth, stage.clientHeight) / state.cam.z;
  const scale = Math.min(1, (vis * 0.8) / Math.max(w, h));
  const c = centerWorld();
  const item = {
    id: nextId++, type: 'img', src,
    w: w * scale, h: h * scale,
    x: c[0] - (w * scale) / 2, y: c[1] - (h * scale) / 2, el,
  };
  attachImage(item);
  state.items.push(item);
  state.sel = { strokes: [], items: [item] };
  draw();
}

const centerWorld = () =>
  toWorld(stage.clientWidth / 2, stage.clientHeight / 2);

/* --------------------------------------------------------------- camera */

function setZoom(z, anchorPx) {
  const [ax, ay] = anchorPx || [stage.clientWidth / 2, stage.clientHeight / 2];
  const [wx, wy] = toWorld(ax, ay);
  state.cam.z = Math.max(0.1, Math.min(8, z));
  state.cam.x = wx - ax / state.cam.z;
  state.cam.y = wy - ay / state.cam.z;
  syncZoomUI();
  draw();
}

function zoomToFit() {
  const b = contentBounds();
  if (!b) { setZoom(1); return; }
  const pad = 60;
  // never zoom *past* 100% just to fill the window with one small item
  const z = Math.max(0.1, Math.min(1,
    Math.min(stage.clientWidth / (b.w + pad * 2), stage.clientHeight / (b.h + pad * 2))));
  state.cam.z = z;
  state.cam.x = b.x + b.w / 2 - stage.clientWidth / (2 * z);
  state.cam.y = b.y + b.h / 2 - stage.clientHeight / (2 * z);
  syncZoomUI();
  draw();
}

function syncZoomUI() {
  const sel = document.getElementById('zoom');
  const pct = Math.round(state.cam.z * 100);
  let opt = [...sel.options].find((o) => o.value === String(state.cam.z));
  if (!opt) {
    opt = [...sel.options].find((o) => o.dataset.live);
    if (!opt) {
      opt = new Option(`${pct}%`, 'live');
      opt.dataset.live = '1';
      sel.insertBefore(opt, sel.firstChild);
    }
    opt.text = `${pct}%`;
    opt.value = 'live';
    sel.value = 'live';
  } else {
    sel.value = opt.value;
  }
}

/* -------------------------------------------------------------- pointer */

let drag = null;

function pos(e) {
  const r = ink.getBoundingClientRect();
  return [e.clientX - r.left, e.clientY - r.top];
}

ink.addEventListener('pointerdown', (e) => {
  if (e.button === 1 || state.space || e.altKey) {
    drag = { mode: 'pan', last: pos(e) };
    ink.setPointerCapture(e.pointerId);
    return;
  }
  const [px, py] = pos(e);
  const [x, y] = toWorld(px, py);
  ink.setPointerCapture(e.pointerId);
  hintEl?.classList.add('gone');   // absent in the app, which starts bare

  const tol = 6 / state.cam.z;

  // A selection only moves while the select tool is active — otherwise a
  // leftover selection swallows pen and eraser strokes.
  if (state.tool === 'select') {
    const solo = soloItem();
    if (solo) {
      const corner = cornerHit(solo, x, y);
      if (corner) {
        pushUndo();
        drag = { mode: 'resize', item: solo, corner, start: { ...solo } };
        return;
      }
    }
    const sb = selectionBounds();
    if (sb && x >= sb.x - 6 && x <= sb.x + sb.w + 6 &&
        y >= sb.y - 6 && y <= sb.y + sb.h + 6) {
      pushUndo();
      drag = { mode: 'move', last: [x, y] };
      return;
    }
  } else if (state.sel.strokes.length || state.sel.items.length) {
    state.sel = { strokes: [], items: [] };
  }

  if (state.tool === 'select') {
    const item = [...state.items].reverse()
      .find((i) => x >= i.x && x <= i.x + i.w && y >= i.y && y <= i.y + i.h);
    if (item) {
      pushUndo();
      state.sel = { strokes: [], items: [item] };
      drag = { mode: 'move', last: [x, y] };
      draw();
      return;
    }
    const s = [...state.strokes].reverse().find((k) => strokeHit(k, x, y, tol));
    if (s) {
      pushUndo();
      state.sel = { strokes: [s], items: [] };
      drag = { mode: 'move', last: [x, y] };
      draw();
      return;
    }
    state.sel = { strokes: [], items: [] };
    drag = { mode: 'marquee', start: [x, y] };
    draw();
    return;
  }

  if (state.tool === 'text') {
    const card = [...state.items].reverse().find(
      (i) => i.type === 'card' && x >= i.x && x <= i.x + i.w && y >= i.y && y <= i.y + i.h);
    openEditor(card || null, [x, y]);
    return;
  }

  if (state.tool === 'eraser') {
    pushUndo();
    drag = { mode: 'erase', last: [x, y] };
    eraseAt(x, y, x, y);
    return;
  }

  pushUndo();
  const kind = state.tool === 'ink'
    ? (state.lastInk === 'highlighter' ? 'highlighter' : 'pen')
    : state.tool;
  const width = kind === 'highlighter' ? state.size * 3 : state.size;
  state.live = { kind, pts: [[x, y]], width, color: currentColor() };
  if (kind === 'line' || kind === 'rect') state.live.pts.push([x, y]);
  drag = { mode: 'draw' };
  draw();
});

ink.addEventListener('pointermove', (e) => {
  const [px, py] = pos(e);
  if (drag && drag.mode === 'pan') {
    const [lx, ly] = drag.last;
    state.cam.x -= (px - lx) / state.cam.z;
    state.cam.y -= (py - ly) / state.cam.z;
    drag.last = [px, py];
    drawSoon();
    return;
  }
  if (!drag) return;
  const [x, y] = toWorld(px, py);

  if (drag.mode === 'resize') {
    const { item, corner, start } = drag;
    Object.assign(item, resizedRect(start, corner, x, y));
    drawSoon();
    return;
  }

  if (drag.mode === 'move') {
    const dx = x - drag.last[0], dy = y - drag.last[1];
    state.sel.items.forEach((i) => { i.x += dx; i.y += dy; });
    state.sel.strokes.forEach((s) => {
      s.pts = s.pts.map(([sx, sy]) => [sx + dx, sy + dy]);
    });
    drag.last = [x, y];
    drawSoon();
  } else if (drag.mode === 'marquee') {
    const [sx, sy] = drag.start;
    state.marquee = {
      x: Math.min(sx, x), y: Math.min(sy, y),
      w: Math.abs(x - sx), h: Math.abs(y - sy),
    };
    drawSoon();
  } else if (drag.mode === 'erase') {
    eraseAt(drag.last[0], drag.last[1], x, y);
    drag.last = [x, y];
  } else if (drag.mode === 'draw' && state.live) {
    const p = state.live.pts;
    if (state.live.kind === 'line' || state.live.kind === 'rect') {
      p[1] = [x, y];
    } else {
      const last = p[p.length - 1];
      if (Math.abs(x - last[0]) * state.cam.z > 0.5 ||
          Math.abs(y - last[1]) * state.cam.z > 0.5) p.push([x, y]);
    }
    drawSoon();
  }
});

function endDrag() {
  if (!drag) return;
  if (drag.mode === 'resize') {
    // a bigger card wants a finer bitmap
    const want = needsBake(drag.item);
    if (want) bakeCard(drag.item, want);
    drag = null;
    draw();
    return;
  }
  if (drag.mode === 'draw' && state.live) {
    const s = state.live;
    state.live = null;
    const tiny = (s.kind === 'line' || s.kind === 'rect') &&
      Math.abs(s.pts[0][0] - s.pts[1][0]) * state.cam.z < 3 &&
      Math.abs(s.pts[0][1] - s.pts[1][1]) * state.cam.z < 3;
    if (!tiny) state.strokes.push(s); else undoStack.pop();
  }
  if (drag.mode === 'marquee') {
    const m = state.marquee;
    if (m && (m.w > 3 || m.h > 3)) {
      state.sel = {
        strokes: state.strokes.filter((s) => rectsOverlap(strokeBounds(s), m)),
        items: state.items.filter((i) => rectsOverlap(i, m)),
      };
    }
    state.marquee = null;
  }
  drag = null;
  draw();
}

ink.addEventListener('pointerup', endDrag);
ink.addEventListener('pointercancel', endDrag);

/* Double-clicking a card reopens its source, whatever tool is selected. */
ink.addEventListener('dblclick', (e) => {
  const [x, y] = toWorld(...pos(e));
  const card = [...state.items].reverse().find(
    (i) => i.type === 'card' && x >= i.x && x <= i.x + i.w && y >= i.y && y <= i.y + i.h);
  if (!card) return;
  e.preventDefault();
  drag = null;
  state.live = null;
  openEditor(card, null);
});

function eraseAt(ax, ay, bx, by) {
  const tol = Math.max(8, state.size * 2) / state.cam.z;
  const before = state.strokes.length;
  state.strokes = state.strokes.filter((s) => !strokeCrossed(s, ax, ay, bx, by, tol));
  if (state.strokes.length !== before) draw();
}

/* wheel: scroll pans, ⌘/Ctrl+scroll (and trackpad pinch) zooms */
ink.addEventListener('wheel', (e) => {
  e.preventDefault();
  if (e.ctrlKey || e.metaKey) {
    setZoom(state.cam.z * Math.exp(-e.deltaY * 0.01), pos(e));
  } else {
    state.cam.x += e.deltaX / state.cam.z;
    state.cam.y += e.deltaY / state.cam.z;
    draw();
  }
}, { passive: false });

/* --------------------------------------------------------------- editor */

const modal = document.getElementById('modal');
const srcBox = document.getElementById('src');
let editing = null, editorAnchor = null;

const previewBox = document.getElementById('preview');

function renderPreview() {
  if (!previewBox) return;
  const src = srcBox.value.trim();
  if (!src) {
    previewBox.innerHTML = '<p class="empty">The rendered card appears here.</p>';
    return;
  }
  previewBox.innerHTML = guardedMarkdown(src);
  renderMathInElement(previewBox, {
    throwOnError: false,
    errorColor: '#c0392f',
    delimiters: [
      { left: '$$', right: '$$', display: true },
      { left: '$', right: '$', display: false },
    ],
  });
}

let previewTimer = null;
srcBox.addEventListener('input', () => {
  syncInsertButton();
  clearTimeout(previewTimer);
  previewTimer = setTimeout(renderPreview, 120);
});

function openEditor(card, at) {
  editing = card;
  editorAnchor = at || null;
  srcBox.value = card ? card.source : '';
  const title = document.getElementById('editorTitle');
  if (title) title.textContent = card ? 'Edit text' : 'Insert text';
  document.getElementById('insertBtn').textContent = card ? 'Update' : 'Insert';
  modal.hidden = false;
  renderPreview();
  syncInsertButton();
  setTimeout(() => srcBox.focus(), 0);
}

/** Nothing to insert → say so instead of ignoring the click. */
function syncInsertButton() {
  const btn = document.getElementById('insertBtn');
  const empty = !srcBox.value.trim();
  btn.disabled = empty;
  btn.style.opacity = empty ? 0.45 : 1;
  btn.style.cursor = empty ? 'not-allowed' : 'pointer';
}

function closeEditor() { modal.hidden = true; editing = null; editorAnchor = null; }

/* Formatting buttons: wrap the selection, or drop in a snippet. */
const MD_SNIPPETS = {
  b: { before: '**', after: '**', placeholder: 'bold' },
  i: { before: '*', after: '*', placeholder: 'italic' },
  table: { block: '| a | b |\n|---|---|\n| 1 | 2 |' },
  imath: { before: '$', after: '$', placeholder: 'x^2' },
  dmath: { block: '$$\nx = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}\n$$' },
};

document.getElementById('mdbar')?.addEventListener('click', (e) => {
  const key = e.target.closest('button')?.dataset.md;
  const snip = MD_SNIPPETS[key];
  if (!snip) return;
  const start = srcBox.selectionStart, end = srcBox.selectionEnd;
  const text = srcBox.value;

  if (snip.block) {
    const pad = start > 0 && text[start - 1] !== '\n' ? '\n\n' : '';
    const insert = pad + snip.block + '\n';
    srcBox.value = text.slice(0, start) + insert + text.slice(end);
    srcBox.selectionStart = srcBox.selectionEnd = start + insert.length;
  } else if (snip.line) {
    // prefix the line the caret is on
    const lineStart = text.lastIndexOf('\n', start - 1) + 1;
    const selected = text.slice(start, end) || snip.placeholder;
    srcBox.value = text.slice(0, lineStart) + snip.before
      + text.slice(lineStart, start) + selected + text.slice(end);
    srcBox.selectionStart = lineStart + snip.before.length + (start - lineStart);
    srcBox.selectionEnd = srcBox.selectionStart + selected.length;
  } else {
    const selected = text.slice(start, end) || snip.placeholder;
    srcBox.value = text.slice(0, start) + snip.before + selected + snip.after + text.slice(end);
    srcBox.selectionStart = start + snip.before.length;
    srcBox.selectionEnd = srcBox.selectionStart + selected.length;
  }
  srcBox.focus();
  // Setting .value in script fires no input event, so the button that watches
  // for one has to be told: text put here by a formatting button counts.
  renderPreview();
  syncInsertButton();
});

function commitEditor() {
  const src = srcBox.value.trim();
  const target = editing, at = editorAnchor;
  closeEditor();
  if (!src) return;
  pushUndo();
  if (target) {
    const el = buildCardEl(src);
    target.el.replaceWith(el);
    target.el = el;
    target.source = src;
    const scale = target.w / (target.nw || target.w);
    const [w, h] = measureCard(el);
    target.bmp = null;   // the source changed; the old picture is stale
    target.svg = null;
    target.nw = w;
    target.nh = h;
    target.domH = h;
    target.w = w * scale;
    target.h = h * scale;
    draw();
    trackCard(target);
  } else {
    addCard(src, at);
  }
  // the card arrives selected, so hand over the tool that can move it
  setTool('select');
}

document.getElementById('insertBtn').onclick = commitEditor;
document.getElementById('cancelBtn').onclick = closeEditor;
srcBox.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); commitEditor(); return; }
  if (e.key === 'Escape') { e.preventDefault(); closeEditor(); return; }
  if ((e.metaKey || e.ctrlKey) && !e.shiftKey && 'bi'.includes(e.key.toLowerCase())) {
    e.preventDefault();
    document.querySelector(`#mdbar button[data-md="${e.key.toLowerCase()}"]`)?.click();
  }
});

/* ------------------------------------------------------------- clipboard */

/** Board objects go on the system clipboard as tagged text, so a copy travels
    between windows and between the app and the browser. The copy kept here is
    the fallback for when the clipboard can't be read back. */
const CLIP_TAG = 'ink-board-v1:';
const PASTE_OFFSET = 16;      // world units, so a paste doesn't hide the original
let objClipboard = null;

/** Drop whatever is selected. The caller decides whether it is one undo step. */
function deleteSelection() {
  if (!state.sel.strokes.length && !state.sel.items.length) return false;
  state.strokes = state.strokes.filter((s) => !state.sel.strokes.includes(s));
  state.sel.items.forEach((i) => i.el.remove());
  state.items = state.items.filter((i) => !state.sel.items.includes(i));
  state.sel = { strokes: [], items: [] };
  return true;
}

function selectionAsClip() {
  const { strokes, items } = state.sel;
  if (!strokes.length && !items.length) return null;
  return CLIP_TAG + JSON.stringify({
    strokes: strokes.map((s) => ({ ...s, pts: s.pts.map((p) => [...p]) })),
    items: items.map(({ el, svg, bmp, bmpScale, baking, imgEl, ...rest }) => rest),
  });
}

/** Put the copied objects back, nudged clear of the originals and selected so
    they can be dragged straight away. Returns false if the text wasn't ours. */
function pasteClip(text) {
  if (!text?.startsWith(CLIP_TAG)) return false;
  let data;
  try { data = JSON.parse(text.slice(CLIP_TAG.length)); } catch { return false; }
  if (!data.strokes?.length && !data.items?.length) return false;

  pushUndo();
  const d = PASTE_OFFSET;
  const strokes = (data.strokes || []).map((s) => ({
    ...s, pts: s.pts.map(([x, y]) => [x + d, y + d]),
  }));
  strokes.forEach((s) => state.strokes.push(s));

  const items = (data.items || []).map((it) => {
    const item = { ...it, id: nextId++, x: it.x + d, y: it.y + d };
    item.el = it.type === 'card' ? buildCardEl(it.source) : buildImgEl(it.src);
    overlay.appendChild(item.el);
    state.items.push(item);
    if (item.type === 'card') trackCard(item);   // it already knows its size
    else attachImage(item);
    return item;
  });

  setTool('select');
  state.sel = { strokes, items };
  syncItems();
  draw();
  return true;
}

document.addEventListener('copy', (e) => {
  if (!modal.hidden) return;          // the editor's own text copy
  const clip = selectionAsClip();
  if (!clip) return;
  objClipboard = clip;
  e.clipboardData?.setData('text/plain', clip);
  e.preventDefault();
});

document.addEventListener('cut', (e) => {
  if (!modal.hidden) return;
  const clip = selectionAsClip();
  if (!clip) return;
  objClipboard = clip;
  e.clipboardData?.setData('text/plain', clip);
  e.preventDefault();
  pushUndo();
  deleteSelection();
  draw();
});

document.addEventListener('paste', (e) => {
  if (!modal.hidden) return;
  const file = [...(e.clipboardData?.items || [])]
    .find((i) => i.type.startsWith('image/'))?.getAsFile();
  if (!file) {
    // A screenshot always wins; board objects are what's left.
    const text = e.clipboardData?.getData('text/plain');
    if (pasteClip(text) || pasteClip(objClipboard)) e.preventDefault();
    return;
  }
  e.preventDefault();
  const reader = new FileReader();
  reader.onload = () => {
    const img = new Image();
    img.onload = () => {
      pushUndo();
      // the pasted image comes in selected, so switch to the tool that can
      // actually move it — otherwise the toolbar and the board disagree
      setTool('select');
      addImage(reader.result, img.width, img.height);
    };
    img.src = reader.result;
  };
  reader.readAsDataURL(file);
});

/* ---------------------------------------------------------------- files */

/** .ink is y-up (CoreGraphics); flip on the way in and out. */
function toInkJSON() {
  return {
    strokes: state.strokes.map((s) => ({
      points: s.pts.map(([x, y]) => [x, -y]),
      width: s.width,
      rgba: hexToRGBA(s.color),
      kind: s.kind,
    })),
    images: state.items.map((i) => ({
      png: (i.png || '').replace(/^data:image\/png;base64,/, ''),
      rect: [[i.x, -(i.y + i.h)], [i.w, i.h]],
      ...(i.type === 'card' ? { source: i.source } : {}),
    })),
  };
}

function fromInkJSON(doc) {
  state.strokes = (doc.strokes || []).map((s) => ({
    kind: s.kind || 'pen',
    width: s.width,
    color: rgbaToHex(s.rgba),
    pts: s.points.map(([x, y]) => [x, -y]),
  }));
  state.items.forEach((i) => i.el.remove());
  state.items = [];
  for (const im of doc.images || []) {
    const [[rx, ry], [rw, rh]] = im.rect;
    const base = { id: nextId++, x: rx, y: -(ry + rh), w: rw, h: rh };
    let item;
    if (im.source) {
      item = { ...base, type: 'card', source: im.source, el: buildCardEl(im.source) };
    } else {
      const src = 'data:image/png;base64,' + im.png;
      item = attachImage({ ...base, type: 'img', src, el: buildImgEl(src) });
    }
    overlay.appendChild(item.el);
    state.items.push(item);
    if (item.type === 'card') trackCard(item);
  }
  state.sel = { strokes: [], items: [] };
  zoomToFit();
}

function hexToRGBA(hex) {
  const n = parseInt(hex.slice(1), 16);
  return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255, 1];
}
function rgbaToHex(rgba) {
  const c = (v) => Math.round(Math.max(0, Math.min(1, v)) * 255)
    .toString(16).padStart(2, '0');
  return '#' + c(rgba[0]) + c(rgba[1]) + c(rgba[2]);
}

function download(name, blob) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

document.getElementById('saveBtn').onclick = async () => {
  // cards need a bitmap for the macOS app; rasterize them best-effort
  for (const it of state.items) {
    if (it.type !== 'card') { it.png = it.src; continue; }
    if (!it.bmp) await bakeCard(it, 2);
    it.png = it.bmp ? it.bmp.toDataURL('image/png') : '';
  }
  download('board.ink', new Blob([JSON.stringify(toInkJSON())], { type: 'application/json' }));
};

document.getElementById('openBtn').onclick = () => document.getElementById('file').click();
document.getElementById('file').onchange = (e) => {
  const f = e.target.files[0];
  if (!f) return;
  const reader = new FileReader();
  reader.onload = () => {
    try { pushUndo(); fromInkJSON(JSON.parse(reader.result)); }
    catch { alert('That file could not be read.'); }
  };
  reader.readAsText(f);
  e.target.value = '';
};

document.getElementById('clearBtn').onclick = () => {
  if (!state.strokes.length && !state.items.length) return;
  pushUndo();
  state.strokes = [];
  state.items.forEach((i) => i.el.remove());
  state.items = [];
  state.sel = { strokes: [], items: [] };
  draw();
};

document.getElementById('pngBtn').onclick = async () => {
  const url = await exportPNGDataURL();
  if (!url) return;
  const bin = atob(url.split(',')[1]);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  download('board.png', new Blob([buf], { type: 'image/png' }));
};

/** Render the whole board (strokes, images, cards) to a PNG data URL. */
async function exportPNGDataURL() {
  const b = contentBounds();
  if (!b) return null;
  const pad = 40, s = 2;
  const c = document.createElement('canvas');
  c.width = (b.w + pad * 2) * s;
  c.height = (b.h + pad * 2) * s;
  const g = c.getContext('2d');
  g.fillStyle = '#fff';
  g.fillRect(0, 0, c.width, c.height);
  g.scale(s, s);
  g.translate(-b.x + pad, -b.y + pad);

  for (const it of state.items) {
    if (it.type === 'card' && !it.bmp) await bakeCard(it, 2);
    const bmp = it.type === 'card' ? it.bmp : it.imgEl;
    if (bmp) g.drawImage(bmp, it.x, it.y, it.w, it.h);
  }
  drawStrokesInto(g, state.strokes);
  return c.toDataURL('image/png');
}

/** Stroke painter for an arbitrary 2D context (screen canvas or export). */
function drawStrokesInto(g, strokes) {
  for (const s of strokes) {
    g.save();
    g.globalAlpha = s.kind === 'highlighter' ? 0.35 : 1;
    g.strokeStyle = s.color;
    g.fillStyle = s.color;
    g.lineWidth = s.width;
    g.lineCap = 'round';
    g.lineJoin = 'round';
    const p = s.pts;
    if (p.length === 1 && s.kind !== 'rect') {
      g.beginPath(); g.arc(p[0][0], p[0][1], s.width / 2, 0, Math.PI * 2); g.fill();
    } else {
      g.beginPath();
      if (s.kind === 'rect' && p.length >= 2) {
        g.rect(Math.min(p[0][0], p[1][0]), Math.min(p[0][1], p[1][1]),
               Math.abs(p[1][0] - p[0][0]), Math.abs(p[1][1] - p[0][1]));
      } else {
        g.moveTo(p[0][0], p[0][1]);
        if (s.kind === 'line' || p.length < 3) {
          for (let i = 1; i < p.length; i++) g.lineTo(p[i][0], p[i][1]);
        } else {
          for (let i = 1; i < p.length - 1; i++) {
            g.quadraticCurveTo(p[i][0], p[i][1],
                               (p[i][0] + p[i + 1][0]) / 2, (p[i][1] + p[i + 1][1]) / 2);
          }
          g.lineTo(p[p.length - 1][0], p[p.length - 1][1]);
        }
      }
      g.stroke();
    }
    g.restore();
  }
}

/* ------------------------------------------------------------------ UI */

const toolButtons = [...document.querySelectorAll('#tools button')];

function setTool(tool) {
  if (tool === 'ink' && state.tool === 'ink') {
    state.lastInk = state.lastInk === 'pen' ? 'highlighter' : 'pen';
  } else if (tool === 'pen' || tool === 'highlighter') {
    state.lastInk = tool;
    tool = 'ink';
  }
  state.tool = tool;
  toolButtons.forEach((b) => b.classList.toggle('on', b.dataset.tool === tool));
  const inkBtn = toolButtons.find((b) => b.dataset.tool === 'ink');
  inkBtn.style.color = (tool === 'ink' && state.lastInk === 'highlighter')
    ? '#f5c542' : '';
  ink.style.cursor = tool === 'select' ? 'default'
    : tool === 'text' ? 'text' : 'crosshair';
  if (tool !== 'select') state.sel = { strokes: [], items: [] };
  renderDots();
  syncInkControls();
  draw();
}

toolButtons.forEach((b) => { b.onclick = () => setTool(b.dataset.tool); });

const dots = document.getElementById('dots');
const custom = document.createElement('i');
const picker = document.createElement('input');

function markActiveDot() {
  const c = currentColor().toLowerCase();
  [...dots.children].forEach((k) => k.classList?.remove('on'));
  const hit = [...dots.querySelectorAll('i')]
    .find((d) => d.dataset.color?.toLowerCase() === c);
  if (hit) hit.classList.add('on');
  else { custom.style.color = c; custom.classList.add('on'); }
}

function pickColor(c) {
  state.inkColors[activeInk()] = c;
  markActiveDot();
}

/** The pen and the highlighter carry different colours, so the toolbar shows
    one case or the other — round ink dots, or fluorescent marker tips. */
function renderDots() {
  const highlighter = activeInk() === 'highlighter';
  dots.classList.toggle('hl', highlighter);
  dots.replaceChildren();
  for (const c of highlighter ? HL_PALETTE : PEN_PALETTE) {
    const d = document.createElement('i');
    d.style.background = c;
    d.style.color = c;
    d.dataset.color = c;
    d.onclick = () => pickColor(c);
    dots.appendChild(d);
  }
  dots.append(custom, picker);
  markActiveDot();
}

/** Colour and thickness belong to the tools that draw with them; on select,
    eraser or text there is nothing for them to change. */
const COLOURED_TOOLS = ['ink', 'line', 'rect'];
function syncInkControls() {
  const live = COLOURED_TOOLS.includes(state.tool);
  for (const el of [dots, sizeDot, sizeInput]) el.classList.toggle('off', !live);
  sizeInput.disabled = !live;
}

custom.className = 'rainbow';
custom.title = 'Custom colour';
picker.type = 'color';
picker.style.display = 'none';
custom.onclick = () => picker.click();
picker.oninput = () => pickColor(picker.value);

const sizeInput = document.getElementById('size');
const sizeDot = document.getElementById('sizedot');
sizeInput.oninput = () => {
  state.size = +sizeInput.value;
  sizeDot.style.setProperty('--d', Math.max(2, Math.min(state.size, 18)) + 'px');
};
sizeInput.oninput();
renderDots();
syncInkControls();

document.getElementById('zoom').onchange = (e) => {
  const v = e.target.value;
  if (v === 'fit') zoomToFit();
  else if (v !== 'live') setZoom(+v);
};

/* ------------------------------------------------------------- keyboard */

const KEYS = {
  Digit1: 'select', KeyV: 'select',
  Digit2: 'ink',
  KeyP: 'pen', KeyH: 'highlighter',
  Digit3: 'eraser', KeyE: 'eraser',
  Digit4: 'text', KeyT: 'text',
  Digit5: 'line', KeyL: 'line',
  Digit6: 'rect', KeyR: 'rect',
};

document.addEventListener('keydown', (e) => {
  if (!modal.hidden) return;
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName);
  if (typing) return;

  if ((e.metaKey || e.ctrlKey) && e.code === 'KeyZ') {
    e.preventDefault();
    e.shiftKey ? redo() : undo();
    return;
  }
  if ((e.metaKey || e.ctrlKey) && e.code === 'Digit0') { e.preventDefault(); setZoom(1); return; }
  if ((e.metaKey || e.ctrlKey) && e.code === 'Digit9') { e.preventDefault(); zoomToFit(); return; }
  if (e.metaKey || e.ctrlKey || e.altKey) return;

  if (e.code === 'Space' && !e.repeat) {
    state.space = true;
    ink.style.cursor = 'grab';
    e.preventDefault();
    return;
  }
  if (e.code === 'Backspace' || e.code === 'Delete') {
    e.preventDefault();
    pushUndo();
    if (deleteSelection()) {
      /* handled */
    } else if (state.items.length || state.strokes.length) {
      // nothing selected: peel off the most recent object
      const lastItem = state.items[state.items.length - 1];
      const lastStroke = state.strokes[state.strokes.length - 1];
      if (lastItem && (!lastStroke || lastItem.id > 0 && state.strokes.length === 0)) {
        lastItem.el.remove();
        state.items.pop();
      } else if (lastStroke) {
        state.strokes.pop();
      }
    } else {
      undoStack.pop();
    }
    draw();
    return;
  }
  if (e.code === 'Escape') {
    // escape hatch: drop the selection and go back to the pointer
    state.sel = { strokes: [], items: [] };
    state.marquee = null;
    setTool('select');
    return;
  }
  const t = KEYS[e.code];
  if (t) { e.preventDefault(); setTool(t); }
});

document.addEventListener('keyup', (e) => {
  if (e.code === 'Space') {
    state.space = false;
    ink.style.cursor = state.tool === 'select' ? 'default' : 'crosshair';
  }
});

/* ------------------------------------------------- native shell bridge */

/* The macOS app is a WKWebView around this page, so the board is implemented
   once. It drives us through `inkNative` and we report edits back. */
const shell = window.webkit?.messageHandlers?.ink || null;
if (shell) document.body.classList.add('shell');

// Send failures to the app's log instead of dumping them on the board.
function reportError(what, detail) {
  const text = `${what}: ${detail}`;
  if (shell) shell.postMessage({ type: 'error', text });
  else console.error(text);
}
window.addEventListener('error', (e) => {
  reportError('JS error', `${e.message} @${(e.filename || '').split('/').pop()}:${e.lineno}`
    + (e.error?.stack ? `\n${e.error.stack}` : ''));
});
window.addEventListener('unhandledrejection', (e) => {
  reportError('Unhandled promise rejection', e.reason?.stack || String(e.reason));
});

function notifyDirty(value = true) {
  shell?.postMessage({ type: 'dirty', value });
}

/** Cards live as HTML; rasterize them so saved files carry a bitmap too. */
async function rasterizeCards() {
  for (const it of state.items) {
    if (it.type !== 'card') { it.png = it.src; continue; }
    if (!it.bmp) await bakeCard(it, 2);
    it.png = it.bmp ? it.bmp.toDataURL('image/png') : '';
  }
}

window.inkNative = {
  async serialize() {
    await rasterizeCards();
    return JSON.stringify(toInkJSON());
  },
  load(json) {
    fromInkJSON(typeof json === 'string' ? JSON.parse(json) : json);
    undoStack.length = 0;
    redoStack.length = 0;
    return true;
  },
  newBoard() {
    state.strokes = [];
    state.items.forEach((i) => i.el.remove());
    state.items = [];
    state.sel = { strokes: [], items: [] };
    undoStack.length = 0;
    redoStack.length = 0;
    setZoom(1);
    state.cam.x = -stage.clientWidth / 2;
    state.cam.y = -stage.clientHeight / 2;
    draw();
    return true;
  },
  undo() { undo(); return true; },
  redo() { redo(); return true; },
  setZoom(z) { setZoom(z); return true; },
  zoomBy(f) { setZoom(state.cam.z * f); return true; },
  zoomToFit() { zoomToFit(); return true; },
  async exportPNG() { return exportPNGDataURL(); },

  /* The app exports by photographing the web view, so the PNG carries the
     real fonts and KaTeX layout instead of a re-drawn approximation. Fit the
     board, drop the selection chrome, and hand back the rectangle to shoot
     (page coordinates, since that is what the snapshot API wants). */
  prepareSnapshot() {
    snapshotCam = { ...state.cam };   // also tells drawGrid to stay off
    state.sel = { strokes: [], items: [] };
    state.marquee = null;
    zoomToFit();
    const b = contentBounds();
    if (!b) { draw(); return null; }
    const r = stage.getBoundingClientRect();
    const pad = 24;
    const x = (b.x - state.cam.x) * state.cam.z + r.left - pad;
    const y = (b.y - state.cam.y) * state.cam.z + r.top - pad;
    return {
      x: Math.max(r.left, x),
      y: Math.max(r.top, y),
      w: Math.min(r.width, b.w * state.cam.z + pad * 2),
      h: Math.min(r.height, b.h * state.cam.z + pad * 2),
    };
  },

  endSnapshot() {
    if (snapshotCam) {
      state.cam = snapshotCam;
      snapshotCam = null;
      syncZoomUI();
      draw();
    }
    return true;
  },
};

let snapshotCam = null;

/* ----------------------------------------------------------------- boot */

window.addEventListener('resize', resize);
resize();
setTool('select');

// Always start on an empty board. The hint pill below the canvas is the only
// on-screen guidance, and the app hides even that.
if (shell) hintEl?.remove();
