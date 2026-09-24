// The hero, printed: a 14-inch MacBook Pro in three spot inks, with the page's
// one simulation hanging from its notch and the headline set in the pink plate
// behind it. A camera on the shared sim like the menu-bar band below it, and
// the same interface: `resize()`, then `render(sim, openness)` per frame, which
// returns whether a sheet went down.
//
// The liquid is drawn at three times the machine's own scale. At true scale it
// is a sixth of the screen's width and a twentieth of its height — the product,
// and unreadable in a picture of the whole laptop.

import { Geometry } from './geometry.js';
import { createPress, makePlates, clearPlates } from './press.js';

const PANEL = { width: 640, height: 190 };
const NOTCH = { width: 185, height: 32 };
const NOTCH_SCALE = 3;

/** A 14-inch MacBook Pro, in millimetres. */
const MB = {
  w: 312.6, d: 221.2, base: 15.5, baseR: 11,
  lidH: 215, lidT: 4.8, lidR: 10,
  bezelSide: 6.5, bezelTop: 7.5, bezelBottom: 13,
  screenPt: { w: 1512, h: 982 },
};
MB.screenW = MB.w - MB.bezelSide * 2;
MB.screenH = MB.lidH - MB.bezelTop - MB.bezelBottom;
MB.pt = MB.screenW / MB.screenPt.w;

/** The resting view, and how open the lid stands. */
const BASE_YAW = -0.5;
const BASE_PITCH = 0.36;
const OPEN = (108 * Math.PI) / 180;
const SHUT = (18 * Math.PI) / 180;
/** The entrance: the lid opens and the run comes into register, once. */
const ENTRANCE_MS = 1600;
const REGISTER_MS = 900;

/**
 * The display face as the pink plate sets it. Gloock is one weight; the lead
 * is its baseline step and `cap` the most of the viewport's height a line may
 * take, wide and narrow.
 */
export const HEADLINE = {
  family: '"Gloock"', weight: 400, track: -0.01, lead: 1, cap: [0.14, 0.1],
};

const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const mul = (a, s) => [a[0] * s, a[1] * s, a[2] * s];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const norm = (a) => mul(a, 1 / Math.hypot(a[0], a[1], a[2]));
const LIGHT = norm([-0.45, 0.8, 0.55]);
/** A surface's tone from the light: aluminium reads as its lit value. */
const shade = (n, lo, hi) => lo + (hi - lo) * (1 - Math.max(0, dot(norm(n), LIGHT)));

/** A rounded rectangle's outline in its own 2D frame, y up, counter-clockwise. */
function roundedOutline(w, h, rTop, rBottom, segments = 6) {
  const out = [];
  const corner = (cx, cy, r, a0) => {
    for (let i = 0; i <= segments; i++) {
      const a = a0 + (Math.PI / 2) * (i / segments);
      out.push([cx + Math.cos(a) * r, cy + Math.sin(a) * r]);
    }
  };
  corner(w / 2 - rBottom, rBottom, rBottom, -Math.PI / 2);
  corner(w / 2 - rTop, h - rTop, rTop, 0);
  corner(-w / 2 + rTop, h - rTop, rTop, Math.PI / 2);
  corner(-w / 2 + rBottom, rBottom, rBottom, Math.PI);
  return out;
}

function makeCamera(yaw, pitch, frame) {
  const cy = Math.cos(yaw), sy = Math.sin(yaw);
  const cp = Math.cos(pitch), sp = Math.sin(pitch);
  const rotate = (v) => {
    const x1 = cy * v[0] + sy * v[2];
    const z1 = -sy * v[0] + cy * v[2];
    return [x1, cp * v[1] - sp * z1, sp * v[1] + cp * z1];
  };
  const D = 1200;
  const project = (p) => {
    const r = rotate([p[0], p[1] - 70, p[2] - MB.d / 2]);
    const depth = D - r[2];
    return [frame.cx + (r[0] * frame.focal) / depth, frame.cy - (r[1] * frame.focal) / depth];
  };
  // A face is seen when its rotated normal points back along the view.
  const facing = (n) => rotate(n)[2] > 0.02;
  return { project, facing };
}

function trace(ctx, pts) {
  ctx.beginPath();
  ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
  ctx.closePath();
}
/** Knock a shape out of a plate. */
function clear(ctx, pts) {
  trace(ctx, pts);
  ctx.save();
  ctx.globalCompositeOperation = 'destination-out';
  ctx.fillStyle = '#000';
  ctx.fill();
  ctx.restore();
}
/** Fill a shape at exactly `tone`, whatever the plate held under it. */
function own(ctx, pts, tone) {
  clear(ctx, pts);
  ctx.fillStyle = `rgba(0,0,0,${tone})`;
  ctx.fill();
}

/** The laptop's extent at the resting view, for fitting it into a box. */
function modelBounds() {
  const cam = makeCamera(BASE_YAW, BASE_PITCH, { cx: 0, cy: 0, focal: 1000 });
  const u = [0, Math.sin(OPEN), Math.cos(OPEN)];
  const hinge = [0, MB.base, MB.lidT];
  const pts = [];
  for (const x of [-MB.w / 2, MB.w / 2]) {
    for (const z of [0, MB.d]) for (const y of [0, MB.base]) pts.push(cam.project([x, y, z]));
    pts.push(cam.project(add(add(hinge, [x, 0, 0]), mul(u, MB.lidH))));
  }
  const xs = pts.map((p) => p[0]);
  const ys = pts.map((p) => p[1]);
  return { x0: Math.min(...xs), x1: Math.max(...xs), y0: Math.min(...ys), y1: Math.max(...ys) };
}

export class RisoHero {
  /**
   * `lines` is the headline as it breaks, from the page's own h1. `copy` is the
   * element the stylesheet positions from the custom properties this writes.
   */
  constructor(canvas, { lines, copy, reduceMotion = false }) {
    this.canvas = canvas;
    this.lines = lines;
    this.copy = copy;
    this.reduceMotion = reduceMotion;
    this.press = createPress(canvas, { pitch: (w) => Math.max(3.6, Math.min(5.2, w / 300)) });
    this.plates = makePlates();
    this.view = { yaw: BASE_YAW, pitch: BASE_PITCH, tx: BASE_YAW, ty: BASE_PITCH };
    this.born = null;
    this.box = { w: 0, h: 0 };
    this.dpr = 1;
    this.frame = null;
    this.outline = null;
  }

  /** The pointer turns the machine a little toward itself. */
  aim(clientX, clientY) {
    if (this.reduceMotion) return;
    this.view.tx = BASE_YAW + (clientX / innerWidth - 0.5) * 0.3;
    this.view.ty = BASE_PITCH + (clientY / innerHeight - 0.5) * 0.1;
  }

  setFont(ctx, size) {
    ctx.font = `${HEADLINE.weight} ${size}px ${HEADLINE.family}, Georgia, serif`;
    if ('letterSpacing' in ctx) ctx.letterSpacing = `${HEADLINE.track * size}px`;
  }

  /** Measure the box, size the press and plates, and place the words. */
  resize() {
    const box = this.canvas.getBoundingClientRect();
    this.box = { w: box.width, h: box.height };
    if (!this.press || !box.width || !box.height) return;
    this.dpr = this.press.resize(box.width, box.height);
    this.plateScale = Math.min(1.5, this.dpr);
    for (const plate of Object.values(this.plates)) {
      plate.width = Math.round(box.width * this.plateScale);
      plate.height = Math.round(box.height * this.plateScale);
    }
    this.frame = this.fit();
    const style = this.copy?.style;
    if (style) {
      style.setProperty('--copy-left', `${this.frame.margin}px`);
      style.setProperty('--copy-top', `${this.frame.copyTop}px`);
      style.setProperty('--copy-width', `${this.frame.copyWidth}px`);
    }
  }

  /**
   * Where the machine and the words go. Wide: the headline and copy on the
   * left, the laptop on the right, the headline running up to the lid's upper
   * corner and no further. Narrow: headline, laptop, copy, top to bottom.
   */
  fit() {
    const { w, h } = this.box;
    const wide = w / h > 1.05;
    const ctx = this.plates.pink.getContext('2d');
    ctx.save();
    this.setFont(ctx, 100);
    const em = Math.max(...this.lines.map((line) => ctx.measureText(line).width)) / 100;
    ctx.restore();
    const margin = wide ? w * 0.055 : w * 0.05;
    const b = modelBounds();
    const place = (area) => {
      const scale = Math.min((area.x1 - area.x0) / (b.x1 - b.x0), (area.y1 - area.y0) / (b.y1 - b.y0));
      return {
        focal: 1000 * scale,
        cx: (area.x0 + area.x1) / 2 - ((b.x0 + b.x1) / 2) * scale,
        cy: (area.y0 + area.y1) / 2 - ((b.y0 + b.y1) / 2) * scale,
      };
    };
    const tail = 0.95 + HEADLINE.lead * (this.lines.length - 1);
    if (wide) {
      const cam = place({ x0: w * 0.4, x1: w * 0.97, y0: h * 0.12, y1: h * 0.95 });
      const corner = makeCamera(BASE_YAW, BASE_PITCH, cam).project(
        add([-MB.w / 2, MB.base, MB.lidT], mul([0, Math.sin(OPEN), Math.cos(OPEN)], MB.lidH)),
      );
      const type = Math.min(h * HEADLINE.cap[0], (corner[0] - margin - w * 0.03) / em);
      const top = h * 0.1;
      return {
        wide, ...cam, type, margin, top,
        copyTop: top + type * (tail + 0.6),
        copyWidth: Math.min(440, corner[0] - margin - 40),
      };
    }
    const type = Math.min(h * HEADLINE.cap[1], (w - margin * 2) / em);
    // Clear of the masthead, which a phone's short top margin would crowd.
    const top = h * 0.06 + 22;
    const machineTop = top + type * (tail + 0.25);
    const cam = place({ x0: w * 0.04, x1: w * 0.96, y0: machineTop, y1: machineTop + h * 0.38 });
    return { wide, ...cam, type, margin, top, copyTop: machineTop + h * 0.41, copyWidth: w - margin * 2 };
  }

  /** How far through its entrance the print is, 0 to 1, from the first frame. */
  entrance(now) {
    if (this.reduceMotion) return { lid: 1, register: 0 };
    if (this.born === null) this.born = now;
    const t = Math.min(1, (now - this.born) / ENTRANCE_MS);
    const r = Math.min(1, (now - this.born) / REGISTER_MS);
    return { lid: 1 - (1 - t) ** 3, register: (1 - r) ** 3 };
  }

  render(sim, openness = 1, now = performance.now()) {
    if (!this.press || !this.frame) return false;
    const { lid, register } = this.entrance(now);
    if (!this.reduceMotion) {
      this.view.yaw += (this.view.tx - this.view.yaw) * 0.06;
      this.view.pitch += (this.view.ty - this.view.pitch) * 0.06;
    }
    this.draw(sim, openness, SHUT + (OPEN - SHUT) * lid);
    this.press.register(register);
    this.press.print(this.plates);
    return true;
  }

  headline(ctx, tone) {
    const { type, margin, top } = this.frame;
    ctx.save();
    this.setFont(ctx, type);
    ctx.fillStyle = `rgba(0,0,0,${tone})`;
    ctx.textBaseline = 'alphabetic';
    this.lines.forEach((line, i) => ctx.fillText(line, margin, top + type * (0.95 + HEADLINE.lead * i)));
    ctx.restore();
  }

  draw(sim, openness, lidAngle) {
    const cam = makeCamera(this.view.yaw, this.view.pitch, this.frame);
    const P = cam.project;
    const { black: K, pink: Pk, blue: B } = clearPlates(this.plates, this.plateScale);

    // The headline is the pink plate's own solid, printed first and overprinted
    // by whatever of the machine crosses it. A fifth of blue under it deepens
    // the pink enough to read: fluorescent pink alone on this paper is 2.6:1.
    this.headline(Pk, 1);
    this.headline(B, 0.22);

    // Ground shadow: the footprint pushed away from the light, softened.
    const foot = roundedOutline(MB.w, MB.d, MB.baseR, MB.baseR).map(([x, z]) => P([x + 16, 0, z + 10]));
    K.save();
    K.filter = `blur(${Math.max(6, this.frame.focal / 110)}px)`;
    trace(K, foot);
    K.fillStyle = 'rgba(0,0,0,0.28)';
    K.fill();
    K.restore();

    // The lid first: the deck is nearer and covers the hinge.
    const u = [0, Math.sin(lidAngle), Math.cos(lidAngle)];
    const n = [0, -Math.cos(lidAngle), Math.sin(lidAngle)];
    const hinge = [0, MB.base - 0.5, MB.lidT + 1.5];
    const lidPoint = (x, s, t) => add(add(add(hinge, [x, 0, 0]), mul(u, s)), mul(n, t));
    const lidRim = roundedOutline(MB.w, MB.lidH, MB.lidR, 3);
    for (let i = 0; i < lidRim.length; i++) {
      const [x0, s0] = lidRim[i];
      const [x1, s1] = lidRim[(i + 1) % lidRim.length];
      const out = [s1 - s0, -(x1 - x0)];
      const normal = norm(add(mul([1, 0, 0], out[0]), mul(u, out[1])));
      if (!cam.facing(normal)) continue;
      const quad = [lidPoint(x0, s0, 0), lidPoint(x1, s1, 0), lidPoint(x1, s1, -MB.lidT), lidPoint(x0, s0, -MB.lidT)].map(P);
      clear(Pk, quad);
      own(B, quad, shade(normal, 0.5, 0.9));
    }
    if (cam.facing(mul(n, -1))) {
      own(B, lidRim.map(([x, s]) => P(lidPoint(x, s, -MB.lidT))), shade(mul(n, -1), 0.25, 0.6));
    }
    if (cam.facing(n)) this.screen(cam, lidPoint, sim, openness, { K, Pk, B });

    // The base: an extruded rounded rectangle.
    const baseRim = roundedOutline(MB.w, MB.d, MB.baseR, MB.baseR);
    const basePoint = (x, z, y) => [x, y, z];
    for (let i = 0; i < baseRim.length; i++) {
      const [x0, z0] = baseRim[i];
      const [x1, z1] = baseRim[(i + 1) % baseRim.length];
      const normal = norm([z1 - z0, 0, -(x1 - x0)]);
      if (!cam.facing(normal)) continue;
      const quad = [basePoint(x0, z0, 0), basePoint(x1, z1, 0),
        basePoint(x1, z1, MB.base), basePoint(x0, z0, MB.base)].map(P);
      clear(K, quad);
      clear(Pk, quad);
      own(B, quad, shade(normal, 0.55, 0.95));
    }
    const deck = baseRim.map(([x, z]) => P(basePoint(x, z, MB.base)));
    clear(K, deck);
    clear(Pk, deck);
    // Lit from the back left, so the deck brightens toward the viewer.
    const back = P([0, MB.base, 0]);
    const front = P([0, MB.base, MB.d]);
    const deckTone = B.createLinearGradient(back[0], back[1], front[0], front[1]);
    deckTone.addColorStop(0, 'rgba(0,0,0,0.66)');
    deckTone.addColorStop(1, 'rgba(0,0,0,0.44)');
    clear(B, deck);
    B.fillStyle = deckTone;
    B.fill();
    // The screen's own light, spilling pink onto the deck under it.
    const glowEnd = P([0, MB.base, MB.d * 0.38]);
    const glow = Pk.createLinearGradient(back[0], back[1], glowEnd[0], glowEnd[1]);
    glow.addColorStop(0, 'rgba(0,0,0,0.36)');
    glow.addColorStop(1, 'rgba(0,0,0,0)');
    trace(Pk, deck);
    Pk.fillStyle = glow;
    Pk.fill();

    // Keyboard: a black well, black keys, the gaps a lighter black.
    const deckY = MB.base + 0.05;
    const kbW = 276, kbZ0 = 14, kbZ1 = 118;
    own(K, roundedOutline(kbW + 4, kbZ1 - kbZ0 + 4, 3, 3).map(([x, z]) => P([x, deckY, kbZ1 + 2 - z])), 0.42);
    const rows = [
      { h: 0.55, keys: Array(14).fill(1) },
      { h: 1, keys: [...Array(13).fill(1), 1.5] },
      { h: 1, keys: [1.5, ...Array(12).fill(1), 1] },
      { h: 1, keys: [1.8, ...Array(11).fill(1), 1.7] },
      { h: 1, keys: [2.35, ...Array(10).fill(1), 2.35] },
      { h: 1, keys: [1, 1, 1, 1.25, 5.1, 1.25, 1, 1, 1] },
    ];
    const pitchZ = (kbZ1 - kbZ0) / rows.reduce((s, r) => s + r.h, 0);
    let z = kbZ0;
    for (const row of rows) {
      const pitchX = kbW / row.keys.reduce((s, k) => s + k, 0);
      const depth = row.h * pitchZ;
      let x = -kbW / 2;
      for (const k of row.keys) {
        const w = k * pitchX;
        const gap = pitchX * 0.1;
        own(K, roundedOutline(w - gap, depth - gap, 1.4, 1.4, 3)
          .map(([dx, dz]) => P([x + w / 2 + dx, deckY + 0.05, z + depth - gap / 2 - dz])), 0.9);
        x += w;
      }
      z += depth;
    }
    for (const side of [-1, 1]) {
      own(B, roundedOutline(9, kbZ1 - kbZ0, 2, 2)
        .map(([dx, dz]) => P([side * (kbW / 2 + 9) + dx, deckY, kbZ1 - dz])), 0.52);
    }
    // Trackpad: glass, lighter than the deck, with a drawn edge.
    const pad = roundedOutline(150, 88, 5, 5).map(([x, pz]) => P([x, deckY, MB.d - 10 - pz]));
    own(B, pad, 0.3);
    trace(B, pad);
    B.lineWidth = Math.max(1.2, this.frame.focal / 900);
    B.strokeStyle = 'rgba(0,0,0,0.6)';
    B.stroke();
  }

  /** The lid's face: bezel, the lit screen, the Dock, and the liquid. */
  screen(cam, lidPoint, sim, openness, { K, Pk, B }) {
    const P = cam.project;
    const lidFace = roundedOutline(MB.w, MB.lidH, MB.lidR, 3).map(([x, s]) => P(lidPoint(x, s, 0.01)));
    clear(B, lidFace);
    clear(Pk, lidFace);
    own(K, lidFace, 0.94);

    // The screen, a split fountain: pink falling off down the glass, blue rising.
    const top = MB.lidH - MB.bezelTop;
    const bottom = MB.bezelBottom;
    const glass = roundedOutline(MB.screenW, MB.screenH, 5, 1).map(([x, s]) => P(lidPoint(x, s + bottom, 0.02)));
    clear(K, glass);
    const a = P(lidPoint(0, top, 0.02));
    const b = P(lidPoint(0, bottom, 0.02));
    const fountain = (ctx, stops) => {
      const g = ctx.createLinearGradient(a[0], a[1], b[0], b[1]);
      for (const [at, tone] of stops) g.addColorStop(at, `rgba(0,0,0,${tone})`);
      trace(ctx, glass);
      ctx.fillStyle = g;
      ctx.fill();
    };
    fountain(Pk, [[0, 0.95], [0.55, 0.45], [1, 0.06]]);
    fountain(B, [[0, 0.04], [0.5, 0.4], [1, 0.92]]);

    // The Dock: paper tiles knocked through both inks, lightly blued.
    const dockY = bottom + MB.screenH * 0.035;
    const tile = MB.screenH * 0.06;
    for (let i = 0; i < 9; i++) {
      const x = (i - 4) * tile * 1.22;
      const sq = roundedOutline(tile, tile, tile * 0.22, tile * 0.22, 4)
        .map(([dx, ds]) => P(lidPoint(x + dx, dockY + ds, 0.03)));
      clear(Pk, sq);
      own(B, sq, i % 3 === 1 ? 0.55 : 0.18);
    }

    // The liquid, in panel points, hung from the notch. Clipped exactly as the
    // app clips it: never above the display's edge, and never past the band
    // the shell has opened to.
    const k = MB.pt * NOTCH_SCALE;
    const at = (px, py) => P(lidPoint((px - PANEL.width / 2) * k, top - py * k, 0.04));
    const inkOpen = Math.max(0, Math.min(openness, sim.inkOpen));
    const geometry = new Geometry(NOTCH, PANEL, inkOpen);
    const lobes = geometry.lobes(sim.sites);
    const { points } = geometry.poolPoints(
      (position, lateral, headroom, detail) => geometry.displacement({
        reduce: this.reduceMotion, position, lobes, swell: sim.swell, raised: sim.raised,
        lateral, detail, headroom, pointerRim: sim.pointerRim, pointerPull: sim.pointerPull,
      }),
      { samples: Geometry.outlineSamples },
    );
    this.outline = points;
    const floor = geometry.core.maxY + (PANEL.height - geometry.core.maxY) * inkOpen;
    // Closed inside the bezel, which is black anyway, and never past the lid.
    const lip = -(MB.bezelTop * 0.8) / k;
    const fluid = points.map((p) => at(p.x, Math.min(p.y, floor)));
    fluid.push(at(points[points.length - 1].x, lip), at(points[0].x, lip));
    const core = geometry.core;
    const cutout = roundedOutline(core.width, core.maxY - lip, core.maxY - lip > 12 ? Geometry.cornerRadius : 0,
      Geometry.cornerRadius, 4).map(([dx, dy]) => at(core.x + core.width / 2 + dx, core.maxY - dy));
    // Knocked out of the colour plates so the black lands on paper, not mud.
    // Every clear before any fill: clearing the second shape out of the black
    // after the first was filled cut the cutout's antialiased edge back out of
    // the liquid, and it printed as a dotted rectangle inside the black.
    for (const shape of [fluid, cutout]) {
      clear(Pk, shape);
      clear(B, shape);
      clear(K, shape);
    }
    // And trapped, as a printer traps a knockout: a hairline of black over the
    // edge, or the pixels the edge half-covers get half of each ink and print
    // a pale halo round the liquid.
    K.fillStyle = '#000';
    K.strokeStyle = '#000';
    K.lineWidth = 1.2;
    K.lineJoin = 'round';
    for (const shape of [fluid, cutout]) {
      trace(K, shape);
      K.fill();
      K.stroke();
    }
  }
}
