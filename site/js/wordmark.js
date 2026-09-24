/**
 * The name, poured the way the mark is.
 *
 * test/icon.html pours the M: a skeleton stroked wide, a pool tapered onto the
 * end of every stem that hangs, a disc where two strokes meet at the bottom,
 * then surface tension. These are the other eight capitals in the same
 * grammar, so the name and the mark are one liquid.
 *
 * Units are H, the skeleton's cap height: the skeleton runs from y 0 to y 1 and
 * the ink stands outside it. Every piece is one primitive, an uneven capsule —
 * a segment from `a` to `b` whose radius runs from `ra` to `rb` — so a stroke,
 * a pool and a disc are the same shape to whatever draws them: a shader, a
 * tracer, a hit test.
 */

// icon.html's MARK, divided through by MARK.height so it is in H.
export const POUR = {
  stroke: 0.124 / 0.495,
  fuse: 0.034 / 0.495,
  pool: 0.026 / 0.495,
  span: 0.24,
};

/**
 * The pour as a distance field has to draw it.
 *
 * The icon's pool is a run of discs, each blurred, and blurred discs pile their
 * coverage up: the half-coverage edge lands well outside any one of them, so
 * the drop a distance field needs is much wider than `half + pool`. So are its
 * joins, and its fillets. These are FITTED to the icon's own M — the contour
 * test/gen-mark.mjs traces from the master — by `node test/gen-wordmark.mjs
 * --fit`, not derived from POUR.
 */
export const SHAPE = {
  half: 0.128,
  pool: 0.16,
  span: 0.465,
  lift: 0.059,
  join: 0.036,
  tension: 0.04,
};

/** Kinds, for anything that treats the pools differently from the strokes. */
export const STROKE = 0;
export const POOL = 1;
export const JOIN = 2;

/** How far a polyline turns at `b`, in radians. */
function angleBetween(a, b, c) {
  const u = Math.atan2(b[1] - a[1], b[0] - a[0]), v = Math.atan2(c[1] - b[1], c[0] - b[0]);
  return Math.abs(((v - u + 3 * Math.PI) % (2 * Math.PI)) - Math.PI);
}

function arc(cx, cy, rx, ry, from, to, steps) {
  const points = [];
  for (let i = 0; i <= steps; i++) {
    const a = ((from + ((to - from) * i) / steps) * Math.PI) / 180;
    points.push([cx + rx * Math.cos(a), cy + ry * Math.sin(a)]);
  }
  return points;
}

// Each letter: its skeleton width and its pieces, in the order a pour lays them.
// ['line', points] strokes a polyline; ['pool', from, to, share] hangs a pool
// on the end of a stroke; ['join', point, share] gathers two strokes.
const LETTERS = {
  M: () => {
    const w = 1.394;
    return { w, parts: [
      ['line', [[0, 1], [0, 0], [w / 2, 0.66], [w, 0], [w, 1]]],
      ['pool', [0, 0], [0, 1]], ['pool', [w, 0], [w, 1]],
      ['join', [w / 2, 0.66], 1],
    ] };
  },
  A: () => {
    const w = 1.16, bar = 0.72, inset = ((1 - bar) * w) / 2;
    return { w, parts: [
      ['line', [[0, 1], [w / 2, 0], [w, 1]]],
      ['line', [[inset, bar], [w - inset, bar]]],
      ['pool', [w / 2, 0], [0, 1]], ['pool', [w / 2, 0], [w, 1]],
    ] };
  },
  G: () => {
    const w = 1.08;
    // Fine enough that the pour's facets, flat between joints, stay under
    // its shading's notice: at 18 the bowl read as a polygon, lit.
    const bowl = arc(w / 2, 0.5, w / 2, 0.53, -40, -360, 36);
    return { w, parts: [
      ['line', bowl],
      ['line', [[w, 0.5], [w, 0.56], [w * 0.56, 0.56]]],
      ['join', bowl[0], 0.5],
    ] };
  },
  N: () => {
    const w = 1;
    return { w, parts: [
      ['line', [[0, 1], [0, 0], [w, 1], [w, 0]]],
      ['pool', [0, 0], [0, 1]], ['pool', [w, 0], [w, 1]],
    ] };
  },
  E: () => {
    const w = 0.74;
    return { w, parts: [
      ['line', [[w, 0], [0, 0], [0, 1], [w, 1]]],
      ['line', [[0, 0.5], [w * 0.86, 0.5]]],
      ['join', [0, 1], 1],
      ['pool', [0, 1], [w, 1], 0.6],
    ] };
  },
  T: () => {
    const w = 0.94;
    return { w, parts: [
      ['line', [[0, 0], [w, 0]]], ['line', [[w / 2, 0], [w / 2, 1]]],
      ['pool', [w / 2, 0], [w / 2, 1]],
    ] };
  },
  I: () => ({ w: 0, parts: [['line', [[0, 0], [0, 1]]], ['pool', [0, 0], [0, 1]]] }),
};

/** The tracking the approved sheet was set with, in H: before and after. */
const GAP = 0.24;
const SIDE = { A: [0.18, 0], N: [0, 0.12], E: [0.04, 0] };

/**
 * The word as primitives: `{ pieces, bounds, width, height }`, each piece
 * `{ a, b, ra, rb, kind, letter }` in H with the skeleton's cap line at y 0.
 * The bounds are the INK's, pools and all, so a box drawn from them holds the
 * whole pour.
 */
export function pour(word = 'MAGNETITE', shape = SHAPE) {
  const { half } = shape;
  const pieces = [];
  let x = 0;
  [...word].forEach((ch, letter) => {
    const glyph = LETTERS[ch]();
    x += SIDE[ch]?.[0] ?? 0;
    const ox = x + half;
    const at = ([px, py]) => [ox + px, py];
    for (const part of glyph.parts) {
      if (part[0] === 'line') {
        const pts = part[1].map(at);
        for (let i = 1; i < pts.length; i++) {
          // A bend gentler than this is a curve, not a corner: its segments
          // join by plain union, because a smooth union swells every joint and
          // an arc of them comes out scalloped. Corners keep the fillet.
          const turn = i > 1 && angleBetween(pts[i - 2], pts[i - 1], pts[i]) < 0.6;
          pieces.push({ a: pts[i - 1], b: pts[i], ra: half, rb: half, kind: STROKE, letter, hard: turn });
        }
      } else if (part[0] === 'pool') {
        const [, from, to, share = 1] = part;
        const [fx, fy] = at(from), [tx, ty] = at(to);
        const len = Math.hypot(tx - fx, ty - fy);
        const ux = (fx - tx) / len, uy = (fy - ty) / len;
        const s = Math.min(len, shape.span);
        const lift = shape.lift * share;
        pieces.push({
          a: [tx + ux * s, ty + uy * s], b: [tx + ux * lift, ty + uy * lift],
          ra: half, rb: half + shape.pool * share, kind: POOL, letter,
        });
      } else {
        const p = at(part[1]);
        const r = half + shape.join * part[2];
        pieces.push({ a: p, b: p, ra: r, rb: r, kind: JOIN, letter });
      }
    }
    x += glyph.w + POUR.stroke + GAP + (SIDE[ch]?.[1] ?? 0);
  });
  // A pool continues its stroke rather than lying on top of it. Two pieces
  // covering the same ground both count in a smooth union, which swells the
  // stroke there by a quarter of the tension, so the stroke stops where its
  // pool starts and the two meet end to end.
  for (const pool of pieces.filter((p) => p.kind === POOL)) {
    const end = pool.b, dir = [pool.b[0] - pool.a[0], pool.b[1] - pool.a[1]];
    for (const piece of pieces) {
      if (piece.kind !== STROKE || piece.letter !== pool.letter) continue;
      const near = (p) => Math.hypot(p[0] - end[0], p[1] - end[1]) < POUR.span * 0.6;
      const along = (from, to) => (to[0] - from[0]) * dir[0] + (to[1] - from[1]) * dir[1] > 0
        && Math.abs((to[0] - from[0]) * dir[1] - (to[1] - from[1]) * dir[0]) < 1e-6;
      if (near(piece.b) && along(piece.a, piece.b)) piece.b = pool.a;
      else if (near(piece.a) && along(piece.b, piece.a)) piece.a = pool.a;
    }
  }
  return { pieces, ...measure(pieces, shape.tension) };
}

/** The ink's box, sampled from the field so fillets and pools are in it. */
function measure(pieces, k) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const { a, b, ra, rb } of pieces) {
    x0 = Math.min(x0, a[0] - ra, b[0] - rb); x1 = Math.max(x1, a[0] + ra, b[0] + rb);
    y0 = Math.min(y0, a[1] - ra, b[1] - rb); y1 = Math.max(y1, a[1] + ra, b[1] + rb);
  }
  return { bounds: [x0, y0, x1, y1], width: x1 - x0, height: y1 - y0, tension: k };
}

/** Signed distance to one piece. Negative inside. */
export function pieceDistance(px, py, { a, b, ra, rb }) {
  const bx = b[0] - a[0], by = b[1] - a[1];
  const h = bx * bx + by * by;
  const qx0 = px - a[0], qy0 = py - a[1];
  if (h < 1e-12) return Math.hypot(qx0, qy0) - ra;
  // iq's uneven capsule.
  const qx = Math.abs(qx0 * by - qy0 * bx) / h;
  const qy = (qx0 * bx + qy0 * by) / h;
  const r = ra - rb;
  const cx = Math.sqrt(Math.max(h - r * r, 0)), cy = r;
  const k = cx * qy - cy * qx;
  const m = cx * qx + cy * qy;
  const n = qx * qx + qy * qy;
  if (k < 0) return Math.sqrt(h * n) - ra;
  if (k > cx) return Math.sqrt(h * (n + 1 - 2 * qy)) - rb;
  return m - ra;
}

/** Polynomial smooth minimum, iq's quadratic. */
export function smin(d1, d2, k) {
  const h = Math.max(k - Math.abs(d1 - d2), 0) / k;
  return Math.min(d1, d2) - h * h * k * 0.25;
}

/** The whole word's signed distance at a point, in H. */
export function distance(px, py, pieces, k = SHAPE.tension) {
  let d = Infinity;
  for (const piece of pieces) {
    const e = pieceDistance(px, py, piece);
    d = d === Infinity ? e : piece.hard ? Math.min(d, e) : smin(d, e, k);
  }
  return d;
}
