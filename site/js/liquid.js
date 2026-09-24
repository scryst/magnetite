/**
 * The name in wet ink.
 *
 * Everything else on the page is printed: dry, screened, multiplied into the
 * paper. The name at the bottom is the one thing still wet — the same pour as
 * the mark (js/wordmark.js), drawn as a signed distance field so it can move,
 * and lit like the ferrofluid the app is about: a black mirror that shows a
 * softbox, a little of the paper, and the two other inks along its rim.
 *
 * The pointer is a magnet. The nearest pool stretches toward it on a spring,
 * the surface nearest it bulges, and close in it throws the spikes real
 * ferrofluid throws at a magnet. Let go and it sloshes back. With the page's
 * soundtrack playing, each pool meters one of the app's twelve bands.
 *
 * WebGL2, because the pieces are read from a uniform array at an index the
 * loop computes; a browser without it gets the traced wordmark instead.
 */
import { pour, SHAPE, STROKE, POOL } from './wordmark.js';

const MAX_PIECES = 96;
const MAX_LETTERS = 16;

const VERT = `#version 300 es
in vec2 a;
void main() { gl_Position = vec4(a, 0.0, 1.0); }`;

const FRAG = `#version 300 es
precision highp float;
#define MAXP ${MAX_PIECES}
#define MAXL ${MAX_LETTERS}
uniform vec4 uAB[MAXP];
uniform vec4 uR[MAXP];
uniform int uN;
uniform vec4 uLetter[MAXL];
uniform int uL;
uniform vec2 uRes;
uniform vec3 uView;
uniform float uK;
uniform float uHalf;
uniform vec4 uMag;
uniform float uTime;
uniform vec3 uInk;
uniform vec3 uPaper;
uniform vec3 uPink;
uniform vec3 uBlue;
out vec4 outColor;

float cro(vec2 a, vec2 b) { return a.x * b.y - a.y * b.x; }

float capsule(vec2 p, vec2 a, vec2 b, float ra, float rb) {
  p -= a; b -= a;
  float h = dot(b, b);
  if (h < 1e-8) return length(p) - ra;
  vec2 q = vec2(abs(cro(p, b)), dot(p, b)) / h;
  float r = ra - rb;
  vec2 c = vec2(sqrt(max(h - r * r, 0.0)), r);
  float k = cro(c, q), m = dot(c, q), n = dot(q, q);
  if (k < 0.0) return sqrt(h * n) - ra;
  if (k > c.x) return sqrt(h * (n + 1.0 - 2.0 * q.y)) - rb;
  return m - ra;
}

float scene(vec2 p) {
  bool near[MAXL];
  for (int l = 0; l < MAXL; l++) {
    near[l] = l < uL && length(p - uLetter[l].xy) - uLetter[l].z < uK + 0.35;
  }
  float d = 1e5;
  for (int i = 0; i < MAXP; i++) {
    if (i >= uN) break;
    if (uR[i].x < 0.0 || !near[int(uR[i].z)]) continue;
    float e = capsule(p, uAB[i].xy, uAB[i].zw, uR[i].x, uR[i].y);
    if (uR[i].w > 0.5) { d = min(d, e); continue; }
    float h = max(uK - abs(d - e), 0.0) / uK;
    d = min(d, e) - h * h * uK * 0.25;
  }
  return d;
}

void main() {
  vec2 frag = vec2(gl_FragCoord.x, uRes.y - gl_FragCoord.y);
  vec2 p = uView.xy + frag / uView.z;
  float px = 1.0 / uView.z;

  // The magnet: a slight bulge toward it, and close in, the spikes real
  // ferrofluid throws at one — cones on the surface, each pointing at it.
  vec2 toM = uMag.xy - p;
  float dm = length(toM);
  float pull = uMag.z * exp(-dm * dm / 0.5);
  vec2 q = p - toM * pull * 0.07;
  float d = scene(q);
  float lobes = 22.0;
  float ang = atan(toM.y, toM.x) * lobes / 6.2831853 + uTime * 0.05;
  float tent = max(0.0, 1.0 - abs(fract(ang) - 0.5) * 3.2);
  float reach = uMag.z * exp(-dm * dm / 0.2);
  d -= reach * tent * tent * 0.11;

  float alpha = clamp(0.5 - d / px, 0.0, 1.0);

  // Contact shadow on the paper, a little below the pour.
  float shadow = 0.0;
  if (alpha < 1.0) {
    float ds = scene(q - vec2(0.0, 0.07));
    shadow = (1.0 - smoothstep(-0.02, 0.16, ds)) * 0.16;
  }

  vec3 col = vec3(0.0);
  if (alpha > 0.0) {
    vec2 g = vec2(dFdx(d), -dFdy(d));
    g = length(g) > 1e-7 ? normalize(g) : vec2(0.0);
    float t = clamp(-d / (uHalf * 1.1), 0.0, 1.0);
    float u = 1.0 - t;
    float slope = u / max(sqrt(1.0 - u * u), 0.1);
    vec3 n = normalize(vec3(g * slope * 0.85, 1.0));
    vec3 r = reflect(vec3(0.0, 0.0, -1.0), n);
    vec3 key = normalize(vec3(-0.45, -0.75, 0.55));
    float s = max(dot(r, key), 0.0);
    float spec = pow(s, 90.0) * 1.15 + pow(s, 9.0) * 0.1;
    float rimP = pow(max(dot(r, normalize(vec3(0.9, 0.15, 0.3))), 0.0), 5.0);
    float rimB = pow(max(dot(r, normalize(vec3(-0.85, 0.35, 0.3))), 0.0), 5.0);
    float fres = pow(1.0 - n.z, 2.5);
    col = uInk * 0.72 + vec3(spec)
        + fres * (uPink * rimP * 0.85 + uBlue * rimB * 0.95 + uPaper * 0.12);
  }
  float a = alpha + (1.0 - alpha) * shadow;
  vec3 c = alpha * col + (1.0 - alpha) * shadow * vec3(0.08, 0.07, 0.08);
  outColor = vec4(c, a);
}`;

const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255);

function compile(gl, type, source) {
  const s = gl.createShader(type);
  gl.shaderSource(s, source);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}

export class LiquidName {
  constructor(canvas, { reduceMotion = false, word = 'MAGNETITE' } = {}) {
    this.canvas = canvas;
    this.reduceMotion = reduceMotion;
    const gl = canvas.getContext('webgl2', { premultipliedAlpha: true, antialias: false, alpha: true });
    if (!gl) throw new Error('no webgl2');
    this.gl = gl;
    const prog = gl.createProgram();
    gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(prog));
    gl.useProgram(prog);
    this.prog = prog;
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, 'a');
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    this.u = {};
    for (const name of ['uAB', 'uR', 'uN', 'uLetter', 'uL', 'uRes', 'uView', 'uK', 'uHalf',
      'uMag', 'uTime', 'uInk', 'uPaper', 'uPink', 'uBlue']) {
      this.u[name] = gl.getUniformLocation(prog, name);
    }
    gl.uniform3fv(this.u.uInk, hex('#222022'));
    gl.uniform3fv(this.u.uPaper, hex('#ECEBE6'));
    gl.uniform3fv(this.u.uPink, hex('#FF48B0'));
    gl.uniform3fv(this.u.uBlue, hex('#0078BF'));
    gl.uniform1f(this.u.uK, SHAPE.tension);
    gl.uniform1f(this.u.uHalf, SHAPE.half);

    this.word = pour(word);
    this.pieces = this.word.pieces;
    this.letterCount = Math.max(...this.pieces.map((p) => p.letter)) + 1;
    // Every pool gets a spring: how far its drop stands stretched toward the
    // magnet, and how fast it is getting there.
    this.drops = this.pieces
      .map((piece, index) => ({ piece, index }))
      .filter(({ piece }) => piece.kind === POOL)
      .map(({ piece, index }) => ({ index, b: piece.b, ex: 0, ey: 0, vx: 0, vy: 0 }));
    this.dropAt = new Map(this.drops.map((d) => [d.index, d]));
    // Each letter rises from a puddle on its own baseline, the foot of its
    // strokes (y runs down the page).
    this.baselines = Array.from({ length: this.letterCount }, (_, l) => Math.max(
      ...this.pieces.filter((p) => p.letter === l && p.kind === STROKE).flatMap((p) => [p.a[1], p.b[1]])));
    this.ab = new Float32Array(MAX_PIECES * 4);
    this.r = new Float32Array(MAX_PIECES * 4);
    this.letters = new Float32Array(MAX_LETTERS * 4);
    this.magnet = { x: 0, y: 0, want: 0, s: 0, vs: 0 };
    // The soundtrack's twelve bands, spread across the drops left to right, so
    // the name meters the music the way the notch does: lows at the M, highs
    // at the last E.
    this.drops.sort((p, q) => p.b[0] - q.b[0]);
    this.drops.forEach((d, i, all) => {
      d.band = Math.round((i * 11) / Math.max(1, all.length - 1));
      d.heard = 0;
    });
    this.bands = null;
    this.time = 0;
    this.pourAt = reduceMotion ? -Infinity : null;
    this.resize();
  }

  /** Css px per H and the H-space point at the canvas's top-left. */
  fit() { return { unit: this.unit, origin: this.origin }; }

  /** Fit the word to the canvas box: centred, with room for the drops to reach. */
  resize() {
    const dpr = Math.min(devicePixelRatio || 1, 2);
    const w = this.canvas.clientWidth, h = this.canvas.clientHeight;
    this.canvas.width = Math.round(w * dpr);
    this.canvas.height = Math.round(h * dpr);
    const [x0, y0, x1, y1] = this.word.bounds;
    const unit = Math.min((w * 0.9) / (x1 - x0), (h * 0.62) / (y1 - y0)); // css px per H
    this.unit = unit;
    this.origin = [(x0 + x1) / 2 - w / 2 / unit, (y0 + y1) / 2 - h / 2 / unit];
    const gl = this.gl;
    gl.viewport(0, 0, this.canvas.width, this.canvas.height);
    gl.uniform2f(this.u.uRes, this.canvas.width, this.canvas.height);
    gl.uniform3f(this.u.uView, this.origin[0], this.origin[1], unit * dpr);
  }

  /** The pointer, in the canvas's CSS pixels; `active` false when it has left. */
  point(x, y, active) {
    this.magnet.x = this.origin[0] + x / this.unit;
    this.magnet.y = this.origin[1] + y / this.unit;
    this.magnet.want = active ? 1 : 0;
  }

  /** The soundtrack's bands, 0..1 each, or null when nothing is playing. */
  listen(bands) { this.bands = bands; }

  /** Start the pour, if it has not run. */
  begin() { if (this.pourAt === null) this.pourAt = this.time; }

  /** Whether the pour has finished laying the word down. */
  get poured() { return this.pourAt !== null && this.time - this.pourAt > 1.6; }

  /** Whether anything is still moving, so the loop can rest when nothing is. */
  get settled() {
    const m = this.magnet;
    const still = this.drops.every((d) => Math.abs(d.vx) + Math.abs(d.vy) < 1e-4
      && Math.abs(d.ex) + Math.abs(d.ey) < 1e-4 && d.heard < 1e-3);
    const hearing = this.bands && this.bands.some((b) => b > 1e-3);
    return this.time - this.pourAt > 2.6 && still && m.want === 0 && m.s < 1e-3 && !hearing;
  }

  step(dt) {
    this.time += dt;
    const m = this.magnet;
    // The magnet's own strength comes and goes on a spring, not a switch.
    m.vs += (70 * (m.want - m.s) - 11 * m.vs) * dt;
    m.s = Math.max(0, m.s + m.vs * dt);
    // Only the nearest drops answer it, the nearest most, so a magnet between
    // two letters pulls one drop rather than fusing the pair.
    const ranked = this.drops
      .map((d) => ({ d, dist: Math.hypot(m.x - d.b[0], m.y - d.b[1]) }))
      .sort((p, q) => p.dist - q.dist);
    ranked.forEach(({ d, dist }, rank) => {
      let tx = 0, ty = 0;
      if (m.s > 1e-3 && rank < 2) {
        const dx = m.x - d.b[0], dy = m.y - d.b[1];
        const unit = dist || 1;
        // Reach falls off over about a cap height; the stretch stops short of
        // the magnet, runs at most half a cap height, and leans sideways less
        // than it hangs.
        const fall = Math.exp(-(dist * dist) / 1.1) * (rank === 0 ? 1 : 0.4);
        const len = Math.min(dist * 0.7, 0.5) * fall * m.s;
        tx = Math.max(-0.22, Math.min(0.22, (dx / unit) * len));
        ty = (dy / unit) * len;
      }
      // Underdamped, so a drop let go overshoots and wobbles home.
      d.vx += (140 * (tx - d.ex) - 7 * d.vx) * dt;
      d.vy += (140 * (ty - d.ey) - 7 * d.vy) * dt;
      d.ex += d.vx * dt; d.ey += d.vy * dt;
      // Its band: quick to swell, slower to let go, as a meter reads.
      const want = this.bands ? Math.min(1, this.bands[d.band] || 0) : 0;
      d.heard += (want - d.heard) * Math.min(1, dt * (want > d.heard ? 22 : 7));
    });
  }

  /**
   * How far the pour has raised letter `l`: how far its ink has spread (0-1)
   * and how tall it stands (0-1, overshooting). The whole letter is there from
   * its first frame, a puddle on its baseline, and the magnet pulls it up past
   * its height and lets it settle back, the way the fluid jumps to a magnet.
   * Nothing is laid piece by piece, so nothing appears loose or disjointed.
   */
  rise(l, pourT) {
    const t = (pourT - l * 0.06) / 0.8;
    if (!(t > 0)) return { spread: 0, height: 0 };
    const spread = 1 - (1 - Math.min(1, t / 0.25)) ** 3;
    const u = Math.min(1, Math.max(0, (t - 0.08) / 0.92)) - 1;
    const height = 1 + 2.4 * u ** 3 + 1.4 * u ** 2;
    return { spread, height };
  }

  render() {
    const gl = this.gl;
    const pourT = this.pourAt === null ? 0 : this.time - this.pourAt;
    const box = Array.from({ length: this.letterCount }, () => [Infinity, Infinity, -Infinity, -Infinity]);
    this.pieces.forEach((piece, i) => {
      let [ax, ay] = piece.a, [bx, by] = piece.b, ra = piece.ra, rb = piece.rb;
      const { spread, height } = this.rise(piece.letter, pourT);
      if (spread <= 0) {
        this.r.set([-1, -1, piece.letter, 0], i * 4);
        return;
      }
      if (spread < 1 || height !== 1) {
        const base = this.baselines[piece.letter];
        ay = base + (ay - base) * height; by = base + (by - base) * height;
        // A puddle is thinner than the stroke it rises into.
        const thick = spread * (0.5 + 0.5 * Math.min(1, height));
        ra *= thick; rb *= thick;
      }
      if (piece.kind === POOL) {
        const d = this.dropAt.get(i);
        const stretch = Math.hypot(d.ex, d.ey);
        // A stretched drop thins. A drop hearing its band swells and hangs a
        // little lower, as the notch's liquid heaves.
        bx += d.ex; by += d.ey + d.heard * 0.1;
        rb *= (1 + d.heard * 0.4) * (1 - Math.min(0.35, stretch * 0.6));
      }
      this.ab.set([ax, ay, bx, by], i * 4);
      this.r.set([ra, rb, piece.letter, piece.hard ? 1 : 0], i * 4);
      const b = box[piece.letter];
      b[0] = Math.min(b[0], ax - ra, bx - rb); b[2] = Math.max(b[2], ax + ra, bx + rb);
      b[1] = Math.min(b[1], ay - ra, by - rb); b[3] = Math.max(b[3], ay + ra, by + rb);
    });
    box.forEach(([x0, y0, x1, y1], l) => {
      const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
      // A letter with nothing poured yet gets a circle nothing can be near.
      this.letters.set(x0 === Infinity ? [0, 0, -1e3, 0] : [cx, cy, Math.hypot(x1 - cx, y1 - cy), 0], l * 4);
    });
    gl.uniform4fv(this.u.uAB, this.ab);
    gl.uniform4fv(this.u.uR, this.r);
    gl.uniform1i(this.u.uN, this.pieces.length);
    gl.uniform4fv(this.u.uLetter, this.letters);
    gl.uniform1i(this.u.uL, this.letterCount);
    const m = this.magnet;
    gl.uniform4f(this.u.uMag, m.x, m.y, this.reduceMotion ? 0 : m.s, 0);
    gl.uniform1f(this.u.uTime, this.time);
    gl.clearColor(0, 0, 0, 0);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }
}
