// Regenerates the vector mark — site/favicon.svg and the inline glyph in
// index.html — from the icon master at test/icon-1024.png.
//
// Why a generator and not a hand-trace.
//
// The mark is POURED, not drawn. icon.html strokes an M-shaped skeleton wide,
// tapers a pool onto each stem, blurs the whole field and thresholds the blur
// back to a hard edge. The concave fillet in every junction — the thing that
// makes it read as liquid rather than as lettering — is a product of that blur,
// so the silhouette has no closed form and cannot be written down. It has to
// come from the master's pixels.
//
// But "from the pixels" does not mean "as a polygon". What stood here before
// was traced by hand into 70 straight segments, and at masthead size every one
// of the joints was visible: the drops were faceted, the shoulders had corners
// on them, and the vertex well came to a point. This fits CUBICS to the same
// contour instead — the curve the pour actually produced, at a tolerance in
// fractions of a master pixel, in roughly a third of the commands.
//
// The tile is the opposite case and gets the opposite treatment. A superellipse
// has an exact parametric form, and icon.html evaluates it directly; tracing
// that shape out of a raster was throwing away an equation we already had. It
// is emitted here from the formula.
//
// Run: node site/test/gen-mark.mjs
// portcheck asserts the two consumers still agree with each other.

import { readFileSync, writeFileSync } from 'node:fs';
import { inflateSync } from 'node:zlib';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const site = join(repo, 'site');

// Read off icon.html rather than restated, so the tile cannot drift from the
// canvas that draws it. These three decide the squircle completely.
const iconSource = readFileSync(join(here, 'icon.html'), 'utf8');
const iconNumber = (pattern, what) => {
  const m = iconSource.match(pattern);
  if (!m) throw new Error(`icon.html no longer declares ${what}`);
  return Number(m[1]);
};
const CANVAS = iconNumber(/^const CANVAS = (\d+);/m, 'CANVAS');
const INSET = iconNumber(/^const INSET = (\d+);/m, 'INSET');
const TILE = CANVAS - INSET * 2;
// The superellipse exponent, likewise read rather than repeated. It lives in
// `squircle()` and is the number that decides how square the tile's corners sit
// next to the rest of the Dock.
const SQUIRCLE_N = iconNumber(/function squircle\([\s\S]*?const n = (\d+);/, 'the squircle exponent');

/** How far a fitted curve may stray from the contour, in master pixels. */
const TOLERANCE = 0.45;

/** The blur that recovers a sub-pixel edge from the pour's hard one. */
const EDGE_SIGMA = 2;

// ---------------------------------------------------------------- PNG

/**
 * Enough PNG to read one 8-bit RGBA image. No dependency, because the repo has
 * none and a trace of the app's own icon is not worth acquiring one.
 */
function decodePNG(buffer) {
  if (buffer.readUInt32BE(0) !== 0x89504e47) throw new Error('not a PNG');
  let at = 8;
  let width = 0, height = 0, depth = 0, colour = 0, interlace = 0;
  const idat = [];
  while (at < buffer.length) {
    const length = buffer.readUInt32BE(at);
    const type = buffer.toString('ascii', at + 4, at + 8);
    const body = buffer.subarray(at + 8, at + 8 + length);
    if (type === 'IHDR') {
      width = body.readUInt32BE(0);
      height = body.readUInt32BE(4);
      depth = body[8]; colour = body[9]; interlace = body[12];
    } else if (type === 'IDAT') idat.push(body);
    else if (type === 'IEND') break;
    at += 12 + length;
  }
  if (depth !== 8 || colour !== 6 || interlace !== 0) {
    throw new Error(`unsupported PNG: depth ${depth} colour ${colour} interlace ${interlace}`);
  }
  const raw = inflateSync(Buffer.concat(idat));
  const bpp = 4;
  const stride = width * bpp;
  const out = Buffer.alloc(height * stride);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    const row = out.subarray(y * stride, (y + 1) * stride);
    const prior = y > 0 ? out.subarray((y - 1) * stride, y * stride) : null;
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? row[i - bpp] : 0;
      const b = prior ? prior[i] : 0;
      const c = prior && i >= bpp ? prior[i - bpp] : 0;
      let value = line[i];
      if (filter === 1) value += a;
      else if (filter === 2) value += b;
      else if (filter === 3) value += (a + b) >> 1;
      else if (filter === 4) {
        const p = a + b - c;
        const pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
        value += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
      } else if (filter !== 0) throw new Error(`bad filter ${filter} on row ${y}`);
      row[i] = value & 0xff;
    }
  }
  return { width, height, data: out };
}

// ---------------------------------------------------------------- the field
//
// The ink is opaque and dark on an opaque light tile, so one scalar decides
// everything: a luminance that is negative in the tile and positive in the ink.
// The two levels are MEASURED off the master rather than named, so a change of
// palette in icon.html does not quietly retrace the wrong shape.

function inkField(image) {
  const { width, height, data } = image;
  const luma = new Float64Array(width * height);
  let lo = Infinity, hi = -Infinity;
  for (let i = 0, p = 0; i < width * height; i++, p += 4) {
    const value = 0.2126 * data[p] + 0.7152 * data[p + 1] + 0.0722 * data[p + 2];
    luma[i] = value;
    if (data[p + 3] > 200) { lo = Math.min(lo, value); hi = Math.max(hi, value); }
  }
  const level = (lo + hi) / 2;
  const field = new Float64Array(width * height);
  for (let i = 0, p = 3; i < field.length; i++, p += 4) {
    // Outside the tile the master is transparent BLACK, and black is darker
    // than the ink: read as luminance alone the surround is the darkest thing
    // in the image, and the trace comes back with the tile's own rim as a
    // second contour. Transparency is not ink, so it is pushed firmly to the
    // tile's side of the threshold before the field is ever looked at.
    field[i] = data[p] < 128 ? lo - level : level - luma[i];
  }
  return { field, width, height, level, lo, hi };
}

/**
 * Puts the sub-pixel edge back before anything is traced.
 *
 * The pour ends by thresholding its blurred field to alpha 0 or 255, and that
 * hard edge survives into the master: a scanline across a drop steps 233 to 10
 * with nothing in between. There is no anti-aliasing to interpolate, so
 * marching squares over the raw mask returns a staircase — and a fit held to
 * half a pixel then chases every stair, which is how a smooth letter comes back
 * as six hundred curves.
 *
 * Blurring the mask and taking the halfway contour is the inverse of what the
 * pour did to get here. On a straight edge it is exact; on a curve of radius R
 * it pulls in by about sigma^2/2R, which at sigma 2 against this letter's
 * tightest fillet is under a hundredth of a pixel. The staircase is a hundred
 * times that.
 */
function smooth(image, sigma) {
  const { field, width, height } = image;
  const radius = Math.ceil(sigma * 3);
  const kernel = [];
  let sum = 0;
  for (let i = -radius; i <= radius; i++) {
    const w = Math.exp(-(i * i) / (2 * sigma * sigma));
    kernel.push(w);
    sum += w;
  }
  for (let i = 0; i < kernel.length; i++) kernel[i] /= sum;
  const pass = (src, w, h) => {
    const out = new Float64Array(src.length);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let acc = 0;
        for (let k = -radius; k <= radius; k++) {
          const sx = Math.min(w - 1, Math.max(0, x + k));
          acc += src[y * w + sx] * kernel[k + radius];
        }
        out[y * w + x] = acc;
      }
    }
    return out;
  };
  const transpose = (src, w, h) => {
    const out = new Float64Array(src.length);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) out[x * h + y] = src[y * w + x];
    return out;
  };
  let f = pass(field, width, height);
  f = transpose(f, width, height);
  f = pass(f, height, width);
  f = transpose(f, height, width);
  return { ...image, field: f };
}

// ---------------------------------------------------------------- contour
//
// Marching squares at the zero crossing, with the crossing linearly
// interpolated along each cell edge. The master is anti-aliased, so that edge
// carries real sub-pixel information — the contour lands well inside a pixel of
// where the pour actually put its boundary, which a boundary walk over a binary
// mask could not do.

export function marchingSquares({ field, width, height }) {
  const at = (x, y) => field[y * width + x];
  const cut = (v0, v1) => v0 / (v0 - v1);
  const segments = [];
  let saddles = 0;
  for (let y = 0; y < height - 1; y++) {
    for (let x = 0; x < width - 1; x++) {
      const a = at(x, y), b = at(x + 1, y), c = at(x + 1, y + 1), d = at(x, y + 1);
      const index = (a > 0 ? 8 : 0) | (b > 0 ? 4 : 0) | (c > 0 ? 2 : 0) | (d > 0 ? 1 : 0);
      if (index === 0 || index === 15) continue;
      const T = [x + cut(a, b), y];
      const R = [x + 1, y + cut(b, c)];
      const B = [x + cut(d, c), y + 1];
      const L = [x, y + cut(a, d)];
      // Wound so the ink stays on a consistent side of every segment, which is
      // what lets the chain below be assembled by endpoint alone.
      const push = (p, q) => segments.push([p, q]);
      switch (index) {
        case 1: push(L, B); break;
        case 2: push(B, R); break;
        case 3: push(L, R); break;
        case 4: push(R, T); break;
        case 6: push(B, T); break;
        case 7: push(L, T); break;
        case 8: push(T, L); break;
        case 9: push(T, B); break;
        case 11: push(T, R); break;
        case 12: push(R, L); break;
        case 13: push(R, B); break;
        case 14: push(B, L); break;
        // The two ambiguous cells, resolved by the cell's own average: it says
        // whether the middle belongs to the ink or to the gap between two
        // lobes, and joining the wrong pair welds shapes that do not touch.
        case 5: {
          saddles++;
          if ((a + b + c + d) / 4 > 0) { push(T, R); push(B, L); }
          else { push(T, L); push(B, R); }
          break;
        }
        case 10: {
          saddles++;
          if ((a + b + c + d) / 4 > 0) { push(L, B); push(R, T); }
          else { push(L, T); push(R, B); }
          break;
        }
      }
    }
  }
  return { segments, saddles };
}

/** Chains the loose segments into closed rings, longest first. */
export function chain(segments) {
  const key = (p) => `${p[0].toFixed(4)},${p[1].toFixed(4)}`;
  const from = new Map();
  for (const s of segments) {
    const k = key(s[0]);
    if (!from.has(k)) from.set(k, []);
    from.get(k).push(s);
  }
  const used = new Set();
  const rings = [];
  for (const seed of segments) {
    if (used.has(seed)) continue;
    const ring = [seed[0]];
    let current = seed;
    while (current && !used.has(current)) {
      used.add(current);
      ring.push(current[1]);
      const next = (from.get(key(current[1])) || []).find((s) => !used.has(s));
      current = next;
    }
    if (ring.length > 8) rings.push(ring);
  }
  rings.sort((p, q) => q.length - p.length);
  return rings;
}

// ---------------------------------------------------------------- fitting
//
// Schneider's curve fit (Graphics Gems, 1990): fit one cubic to the whole run,
// measure the worst deviation, and if it is over tolerance either improve the
// parameterisation by Newton-Raphson or split at the worst point and recurse.
// The result is the smallest number of curves that holds the contour to
// TOLERANCE, rather than a fixed number chosen by eye.

const sub = (p, q) => [p[0] - q[0], p[1] - q[1]];
const add = (p, q) => [p[0] + q[0], p[1] + q[1]];
const mul = (p, s) => [p[0] * s, p[1] * s];
const dot = (p, q) => p[0] * q[0] + p[1] * q[1];
const len = (p) => Math.hypot(p[0], p[1]);
const norm = (p) => { const l = len(p); return l ? [p[0] / l, p[1] / l] : [0, 0]; };
const neg = (p) => [-p[0], -p[1]];

const B0 = (t) => (1 - t) ** 3;
const B1 = (t) => 3 * t * (1 - t) ** 2;
const B2 = (t) => 3 * t * t * (1 - t);
const B3 = (t) => t ** 3;

export function bezierAt(c, t) {
  return add(add(mul(c[0], B0(t)), mul(c[1], B1(t))),
             add(mul(c[2], B2(t)), mul(c[3], B3(t))));
}

function chordLengths(points, first, last) {
  const u = [0];
  for (let i = first + 1; i <= last; i++) {
    u.push(u[u.length - 1] + len(sub(points[i], points[i - 1])));
  }
  const total = u[u.length - 1] || 1;
  return u.map((v) => v / total);
}

/** Least squares for the two control-point distances, given a parameterisation. */
function generateBezier(points, first, last, u, tHat1, tHat2) {
  const n = last - first + 1;
  const A = [];
  for (let i = 0; i < n; i++) A.push([mul(tHat1, B1(u[i])), mul(tHat2, B2(u[i]))]);
  let c00 = 0, c01 = 0, c11 = 0, x0 = 0, x1 = 0;
  for (let i = 0; i < n; i++) {
    c00 += dot(A[i][0], A[i][0]);
    c01 += dot(A[i][0], A[i][1]);
    c11 += dot(A[i][1], A[i][1]);
    const tmp = sub(points[first + i], add(
      add(mul(points[first], B0(u[i])), mul(points[first], B1(u[i]))),
      add(mul(points[last], B2(u[i])), mul(points[last], B3(u[i])))));
    x0 += dot(A[i][0], tmp);
    x1 += dot(A[i][1], tmp);
  }
  const det = c00 * c11 - c01 * c01;
  const detA = x0 * c11 - c01 * x1;
  const detB = c00 * x1 - x0 * c01;
  let alphaL = det === 0 ? 0 : detA / det;
  let alphaR = det === 0 ? 0 : detB / det;
  const segLength = len(sub(points[last], points[first]));
  if (alphaL < 1e-6 * segLength || alphaR < 1e-6 * segLength) {
    const third = segLength / 3;
    alphaL = alphaR = third;
  }
  return [points[first],
          add(points[first], mul(tHat1, alphaL)),
          add(points[last], mul(tHat2, alphaR)),
          points[last]];
}

function maxError(points, first, last, curve, u) {
  let max = 0, split = Math.floor((last - first + 1) / 2);
  for (let i = first + 1; i < last; i++) {
    const d = len(sub(bezierAt(curve, u[i - first]), points[i]));
    if (d >= max) { max = d; split = i; }
  }
  return { max, split };
}

function reparameterize(points, first, last, u, curve) {
  return u.map((ui, i) => {
    const p = points[first + i];
    const d = sub(bezierAt(curve, ui), p);
    // First and second derivatives of the cubic at ui.
    const q1 = [
      mul(sub(curve[1], curve[0]), 3), mul(sub(curve[2], curve[1]), 3), mul(sub(curve[3], curve[2]), 3),
    ];
    const q2 = [mul(sub(q1[1], q1[0]), 2), mul(sub(q1[2], q1[1]), 2)];
    const d1 = add(add(mul(q1[0], (1 - ui) ** 2), mul(q1[1], 2 * ui * (1 - ui))), mul(q1[2], ui * ui));
    const d2 = add(mul(q2[0], 1 - ui), mul(q2[1], ui));
    const numerator = dot(d, d1);
    const denominator = dot(d1, d1) + dot(d, d2);
    return denominator === 0 ? ui : ui - numerator / denominator;
  });
}

function fitCubic(points, first, last, tHat1, tHat2, tolerance, out) {
  if (last - first === 1) {
    const dist = len(sub(points[last], points[first])) / 3;
    out.push([points[first], add(points[first], mul(tHat1, dist)),
              add(points[last], mul(tHat2, dist)), points[last]]);
    return;
  }
  let u = chordLengths(points, first, last);
  let curve = generateBezier(points, first, last, u, tHat1, tHat2);
  let { max, split } = maxError(points, first, last, curve, u);
  if (max < tolerance) { out.push(curve); return; }
  // Close enough that a better parameterisation is likely to land it.
  if (max < tolerance * tolerance + tolerance) {
    for (let i = 0; i < 24; i++) {
      u = reparameterize(points, first, last, u, curve);
      curve = generateBezier(points, first, last, u, tHat1, tHat2);
      ({ max, split } = maxError(points, first, last, curve, u));
      if (max < tolerance) { out.push(curve); return; }
    }
  }
  if (split <= first) split = first + 1;
  if (split >= last) split = last - 1;
  // A centre tangent taken across the split rather than at it: the contour is a
  // blurred threshold and has no corners, so the two halves must leave the
  // seam smooth or the fit invents a kink that the pour never had.
  const centre = norm(sub(points[split - 1], points[split + 1]));
  fitCubic(points, first, split, tHat1, centre, tolerance, out);
  fitCubic(points, split, last, neg(centre), tHat2, tolerance, out);
}

/** Fits a closed ring, smooth across the seam where it starts and ends. */
export function fitClosed(ring, tolerance) {
  const points = ring.slice();
  if (len(sub(points[0], points[points.length - 1])) > 1e-9) points.push(points[0]);
  const seam = norm(sub(points[1], points[points.length - 2]));
  const out = [];
  fitCubic(points, 0, points.length - 1, seam, neg(seam), tolerance, out);
  return out;
}

/**
 * Worst distance from any contour point to the fitted curves — the check on the
 * fit, measured independently of the parameterisation the fit chose.
 *
 * Each curve is sampled at roughly four points per pixel of its own length. A
 * fixed sample count per curve would make this a measurement of the sampling
 * rather than of the fit: long curves would report a deviation that is really
 * the gap between neighbouring samples, and it would grow as the fit got
 * BETTER and used fewer, longer curves.
 */
export function fitError(ring, curves) {
  const samples = [];
  for (const c of curves) {
    const rough = len(sub(c[1], c[0])) + len(sub(c[2], c[1])) + len(sub(c[3], c[2]));
    const steps = Math.max(8, Math.ceil(rough * 4));
    for (let i = 0; i <= steps; i++) samples.push(bezierAt(c, i / steps));
  }
  let worst = 0;
  for (const p of ring) {
    let best = Infinity;
    for (const s of samples) best = Math.min(best, len(sub(p, s)));
    worst = Math.max(worst, best);
  }
  return worst;
}

// ---------------------------------------------------------------- the tile

/**
 * The macOS tile: a continuous-curvature superellipse, |x|^n + |y|^n = 1 at
 * n = 5, exactly as icon.html draws it. Sampled from the equation and fitted,
 * so what ships is the curve rather than a photograph of the curve.
 */
function squircleRing(steps = 4096) {
  const r = TILE / 2;
  const cx = INSET + r;
  const cy = INSET + r;
  const ring = [];
  for (let i = 0; i < steps; i++) {
    const t = (i / steps) * Math.PI * 2;
    const c = Math.cos(t), s = Math.sin(t);
    ring.push([
      cx + Math.sign(c) * Math.abs(c) ** (2 / SQUIRCLE_N) * r,
      cy + Math.sign(s) * Math.abs(s) ** (2 / SQUIRCLE_N) * r,
    ]);
  }
  ring.push(ring[0]);
  return ring;
}

// ---------------------------------------------------------------- output

const round = (v) => {
  const r = Math.round(v * 10) / 10;
  return String(Number.isInteger(r) ? r : r.toFixed(1));
};

/** `M … C … Z`, wrapped so the file stays readable in a diff. */
export function pathData(curves, indent) {
  let out = `M${round(curves[0][0][0])} ${round(curves[0][0][1])}`;
  for (const c of curves) {
    out += `C${round(c[1][0])} ${round(c[1][1])} ${round(c[2][0])} ${round(c[2][1])}`
         + ` ${round(c[3][0])} ${round(c[3][1])}`;
  }
  out += 'Z';
  const wrapped = [];
  let line = '';
  for (const piece of out.match(/[MCZ][^MCZ]*/g)) {
    if (line.length + piece.length > 88) { wrapped.push(line); line = ''; }
    line += piece;
  }
  if (line) wrapped.push(line);
  return wrapped.join(`\n${indent}`);
}

/** The ink's true extent, unrounded — what the unit-box normalisation needs. */
function exactBounds(curves) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const c of curves) {
    for (let i = 0; i <= 256; i++) {
      const [x, y] = bezierAt(c, i / 256);
      x0 = Math.min(x0, x); y0 = Math.min(y0, y);
      x1 = Math.max(x1, x); y1 = Math.max(y1, y);
    }
  }
  return { x0, y0, x1, y1 };
}

function boundingBox(curves) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const c of curves) {
    for (let i = 0; i <= 32; i++) {
      const [x, y] = bezierAt(c, i / 32);
      x0 = Math.min(x0, x); y0 = Math.min(y0, y);
      x1 = Math.max(x1, x); y1 = Math.max(y1, y);
    }
  }
  return [Math.floor(x0), Math.floor(y0), Math.ceil(x1 - x0), Math.ceil(y1 - y0)];
}

// ---------------------------------------------------------------- deriving

/**
 * The mark, derived from the master's pixels. Pure — it reads the master and
 * icon.html and returns paths, writing nothing — so portcheck can re-derive and
 * compare rather than take the committed SVG's word for it. That is the same
 * arrangement real-levels.js is under: a generated file is only as trustworthy
 * as the check that regenerates it.
 */
export function deriveMark() {
  const master = decodePNG(readFileSync(join(here, 'icon-1024.png')));
  if (master.width !== CANVAS || master.height !== CANVAS) {
    throw new Error(`master is ${master.width}x${master.height}, icon.html draws ${CANVAS}`);
  }
  const field = smooth(inkField(master), EDGE_SIGMA);
  const { segments, saddles } = marchingSquares(field);
  const rings = chain(segments);
  if (rings.length !== 1) {
    throw new Error(`expected the poured M to be one closed ring, found ${rings.length}`);
  }

  const inkCurves = fitClosed(rings[0], TOLERANCE);
  const tileRing = squircleRing();
  const tileCurves = fitClosed(tileRing, TOLERANCE);
  const inkWorst = fitError(rings[0], inkCurves);
  const tileWorst = fitError(tileRing, tileCurves);
  if (inkWorst > TOLERANCE * 2 || tileWorst > TOLERANCE * 2) {
    throw new Error(`a fitted path strayed further than the tolerance allows: `
      + `ink ${inkWorst.toFixed(3)}px, tile ${tileWorst.toFixed(3)}px`);
  }

  return {
    inkCurves,
    tileCurves,
    tileBox: [INSET, INSET, TILE, TILE],
    inkBox: boundingBox(inkCurves),
    stats: {
      segments: segments.length, saddles, ringPoints: rings[0].length,
      level: field.level, lo: field.lo, hi: field.hi, inkWorst, tileWorst,
    },
  };
}

/** The favicon, whole — the string the committed file has to equal. */
export function faviconSVG(mark) {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${mark.tileBox.join(' ')}">
  <!--
    GENERATED by test/gen-mark.mjs from the icon master at test/icon-1024.png —
    the same pixels the icns is built from — so the tab, the Dock and the page
    cannot disagree about what the mark is. Edit the master or the generator,
    never this file.

    The tile is the superellipse icon.html evaluates, emitted from the equation
    rather than photographed out of the raster. The letter is a cubic fit to the
    master's own contour, because the pour that produced it — stroke, blur,
    threshold — has no closed form. The ground outside the tile stays
    transparent.
  -->
  <path fill="#E8E9EB" d="${pathData(mark.tileCurves, '    ')}"/>
  <path fill="#0B0A0C" d="${pathData(mark.inkCurves, '    ')}"/>
</svg>
`;
}

/**
 * The page's copy: the letter alone, in the page's own ink, cropped to the
 * letter's extent. Same curves, so the two cannot describe different shapes.
 */
export function inlineGlyph(mark) {
  return `<svg class="mark__glyph" viewBox="${mark.inkBox.join(' ')}" aria-hidden="true">\n`
    + `          <path fill="currentColor" d="${pathData(mark.inkCurves, '            ')}"/>`;
}

/**
 * The app's copy: the same curves as Swift, in a unit box with y pointing up.
 *
 * The menu bar had an SF Symbol in it — `rectangle.topthird.inset.filled`, a
 * generic notch shape — for the app's whole life. It was never the mark, so the
 * one place the app is visible when it is doing its job was the one place the
 * logo was not, and the tab, the Dock and the page could agree with each other
 * all day without that mattering.
 *
 * A path rather than a bundled image, for two reasons. It is resolution-free,
 * which a menu bar spanning Retina and non-Retina displays actually needs; and
 * it cannot go missing at runtime the way a resource that build.sh forgets to
 * copy can, which would leave the status item with no icon at all and nothing
 * to say so.
 */
export function markSwift(mark) {
  const b = exactBounds(mark.inkCurves);
  const w = b.x1 - b.x0;
  const h = b.y1 - b.y0;
  // y is flipped: SVG counts down from the top, AppKit counts up from the
  // bottom, and a mark that is not symmetric about its horizontal axis comes
  // out upside down if this is left to the drawing code to remember.
  const px = (p) => `x: ${((p[0] - b.x0) / w).toFixed(5)}, y: ${(1 - (p[1] - b.y0) / h).toFixed(5)}`;
  const lines = mark.inkCurves.map((c) =>
    `        path.addCurve(to: CGPoint(${px(c[3])}),\n`
    + `                      control1: CGPoint(${px(c[1])}),\n`
    + `                      control2: CGPoint(${px(c[2])}))`).join('\n');
  return `// GENERATED by site/test/gen-mark.mjs from site/test/icon-1024.png —
// the same contour the favicon and the page's inline logo are cut from, and the
// same pixels Magnetite.icns is built from. portcheck re-derives all three and
// asserts each is what the derivation produces.
//
// Do not edit. Change the icon master, or the generator, and re-run:
//   node site/test/gen-mark.mjs

import AppKit

/// The poured M, as geometry rather than as a picture of geometry.
enum MagnetiteMark {
    /// Width over height of the ink, so a caller can size a box for it.
    static let aspect: CGFloat = ${(w / h).toFixed(5)}

    /// The mark in a unit box, y up — ready to be scaled into any rect.
    static func path() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(${px(mark.inkCurves[0][0])}))
${lines}
        path.closeSubpath()
        return path
    }

    /// A menu-bar image: drawn at the height asked for, and a TEMPLATE, so the
    /// system inverts it for a dark menu bar and dims it when the app is not
    /// active instead of leaving a black mark on a black bar.
    static func menuBarImage(height: CGFloat) -> NSImage {
        let size = NSSize(width: (height * aspect).rounded(), height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            var scale = CGAffineTransform(scaleX: rect.width, y: rect.height)
            guard let scaled = path().copy(using: &scale) else { return false }
            context.addPath(scaled)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
`;
}

/** Matches exactly what `inlineGlyph` writes, so the check can find it again. */
export const GLYPH_IN_PAGE =
  /<svg class="mark__glyph" viewBox="[^"]*" aria-hidden="true">\s*<path fill="currentColor" d="[^"]*"\/>/;

// ---------------------------------------------------------------- run

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const mark = deriveMark();
  const s = mark.stats;
  console.log(`master: ${CANVAS}x${CANVAS}, ink/tile luminance ${s.lo.toFixed(1)}/`
    + `${s.hi.toFixed(1)}, threshold ${s.level.toFixed(1)}`);
  console.log(`contour: ${s.segments} segments, ${s.saddles} ambiguous cells, `
    + `${s.ringPoints} points on the ring`);
  console.log(`ink:  ${mark.inkCurves.length} cubics, worst deviation ${s.inkWorst.toFixed(3)}px`);
  console.log(`tile: ${mark.tileCurves.length} cubics, worst deviation ${s.tileWorst.toFixed(3)}px`);

  writeFileSync(join(site, 'favicon.svg'), faviconSVG(mark));

  const indexPath = join(site, 'index.html');
  const index = readFileSync(indexPath, 'utf8');
  if (!GLYPH_IN_PAGE.test(index)) {
    throw new Error('index.html no longer holds the inline mark in the expected shape');
  }
  writeFileSync(indexPath, index.replace(GLYPH_IN_PAGE, inlineGlyph(mark)));

  writeFileSync(join(repo, 'Sources', 'NotchApp', 'App', 'MagnetiteMark.swift'), markSwift(mark));

  console.log(`wrote site/favicon.svg (viewBox ${mark.tileBox.join(' ')}), the inline glyph in `
    + `site/index.html (viewBox ${mark.inkBox.join(' ')}) and Sources/NotchApp/App/`
    + `MagnetiteMark.swift`);
}
