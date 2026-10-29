/**
 * Iron filings on the paper around the name.
 *
 * Magnetite is lodestone, the rock that is a magnet on its own, so the name is
 * treated as one: a bar magnet the width of the word, north at the M and south
 * at the last E, and the filings lie along its field the way they do on a
 * school desk. They are scattered at random until the name has finished
 * pouring, and then the field switches on and they swing into line.
 *
 * The pointer is a second magnet. Near it the filings turn to its field on a
 * spring and lean in toward it; away from it they settle back into the word's.
 */
import { distance } from './wordmark.js';

export class Filings {
  /** `liquid` is the LiquidName they share a word and a fit with. */
  constructor(canvas, liquid, { reduceMotion = false } = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.liquid = liquid;
    this.reduceMotion = reduceMotion;
    this.magnet = { x: 0, y: 0, want: 0, s: 0 };
    // How much of the word's field is on: none until the pour lands.
    this.on = reduceMotion ? 1 : 0;
    this.resize();
  }

  resize() {
    const dpr = Math.min(devicePixelRatio || 1, 2);
    const w = this.canvas.clientWidth, h = this.canvas.clientHeight;
    this.w = w; this.h = h;
    this.canvas.width = Math.round(w * dpr);
    this.canvas.height = Math.round(h * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const { unit, origin } = this.liquid.fit();
    this.unit = unit;
    const { bounds, pieces } = this.liquid.word;
    const [x0, y0, x1, y1] = bounds;
    const toPx = (x, y) => [(x - origin[0]) * unit, (y - origin[1]) * unit];
    const cy = (y0 + y1) / 2;
    this.poles = [[...toPx(x0 + 0.5, cy), 1], [...toPx(x1 - 0.5, cy), -1]];
    this.centre = toPx((x0 + x1) / 2, cy);
    this.reach = [((x1 - x0) / 2 + 1.2) * unit, ((y1 - y0) / 2 + 1.6) * unit];

    // On a jittered grid, off the ink, and seeded so every visit scatters the
    // same way.
    const pitch = Math.max(12, Math.min(17, w / 80));
    let seed = 7;
    const rand = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
    const filings = [];
    for (let y = pitch / 2; y < h; y += pitch) {
      for (let x = pitch / 2; x < w; x += pitch) {
        const fx = x + (rand() - 0.5) * pitch * 0.9;
        const fy = y + (rand() - 0.5) * pitch * 0.9;
        const scatter = rand() * Math.PI;
        const length = pitch * (0.4 + rand() * 0.3);
        if (distance(origin[0] + fx / unit, origin[1] + fy / unit, pieces) < 0.18) continue;
        // Thinner toward the edges of the section, so the field has a middle.
        const ex = (fx - this.centre[0]) / this.reach[0], ey = (fy - this.centre[1]) / this.reach[1];
        const tone = Math.max(0, 1 - Math.hypot(ex, ey) * 0.75);
        if (tone < 0.08) continue;
        filings.push({ x: fx, y: fy, len: length, tone,
          angle: this.on ? this.field(fx, fy, 0).angle : scatter, spin: 0, dx: 0, dy: 0 });
      }
    }
    this.filings = filings;
  }

  /** The field at a point in css px: its direction, and how near the pointer is. */
  field(x, y, s) {
    let bx = 0, by = 0;
    const add = (px, py, q) => {
      const dx = x - px, dy = y - py;
      const r2 = dx * dx + dy * dy + 40;
      const inv = q / (r2 * Math.sqrt(r2));
      bx += dx * inv; by += dy * inv;
    };
    const word = this.unit * this.unit * 2.2 * this.on;
    for (const [px, py, q] of this.poles) add(px, py, q * word);
    let near = 0;
    if (s > 1e-3) {
      // The pointer, as a short bar magnet standing north-up.
      const m = this.magnet, half = 14, strength = this.unit * this.unit * 1.6 * s;
      add(m.x, m.y - half, strength);
      add(m.x, m.y + half, -strength);
      const d = Math.hypot(x - m.x, y - m.y);
      near = s * Math.exp(-(d * d) / (this.unit * this.unit * 2.2));
    }
    return { angle: Math.atan2(by, bx), near };
  }

  point(x, y, active) {
    this.magnet.x = x; this.magnet.y = y; this.magnet.want = active ? 1 : 0;
  }

  get settled() {
    return this.on === 1 && this.magnet.want === 0 && this.magnet.s < 1e-3
      && this.filings.every((f) => Math.abs(f.spin) < 2e-3 && Math.abs(f.dx) + Math.abs(f.dy) < 0.05);
  }

  step(dt) {
    const m = this.magnet;
    m.s += (m.want - m.s) * Math.min(1, dt * 6);
    if (m.want === 0 && m.s < 1e-3) m.s = 0;
    if (this.liquid.poured) this.on = Math.min(1, this.on + dt * 2.5);
    for (const f of this.filings) {
      const { angle, near } = this.field(f.x, f.y, m.s);
      const pull = Math.max(this.on, near);
      if (pull > 0) {
        // A filing has no head: it turns the short way to lie along the field.
        let delta = angle - f.angle;
        delta = ((((delta + Math.PI / 2) % Math.PI) + Math.PI) % Math.PI) - Math.PI / 2;
        f.spin += (delta * (26 + near * 60) * pull - f.spin * 7) * dt;
      } else f.spin *= 1 - Math.min(1, dt * 7);
      f.angle += f.spin * dt;
      // And leans in toward the pointer when it is close.
      let tx = 0, ty = 0;
      if (near > 1e-3) {
        const dx = m.x - f.x, dy = m.y - f.y, d = Math.hypot(dx, dy) || 1;
        const lean = Math.min(d * 0.25, 7) * near;
        tx = (dx / d) * lean; ty = (dy / d) * lean;
      }
      f.dx += (tx - f.dx) * Math.min(1, dt * 10);
      f.dy += (ty - f.dy) * Math.min(1, dt * 10);
    }
  }

  render() {
    const { ctx, w, h } = this;
    ctx.clearRect(0, 0, w, h);
    ctx.lineWidth = 1.5;
    ctx.lineCap = 'round';
    // Four tones, one path each, rather than a stroke per filing.
    for (let band = 0; band < 4; band++) {
      ctx.strokeStyle = `rgba(34, 32, 34, ${(0.2 + band * 0.16).toFixed(2)})`;
      ctx.beginPath();
      for (const f of this.filings) {
        if (Math.min(3, Math.floor(f.tone * 4)) !== band) continue;
        const cx = f.x + f.dx, cy = f.y + f.dy;
        const ux = (Math.cos(f.angle) * f.len) / 2, uy = (Math.sin(f.angle) * f.len) / 2;
        ctx.moveTo(cx - ux, cy - uy);
        ctx.lineTo(cx + ux, cy + uy);
      }
      ctx.stroke();
    }
  }
}
