// A port of `Geometry` from Sources/NotchApp/UI/FerrofluidView.swift.
//
// One closed outline displaced along its own normal. Bass heaves the whole
// surface; each band raises a smooth mound where its site sits on the rim.
// Nothing is assembled from circles and nothing detaches.
//
// Two departures from the Swift, both deliberate and both listed here rather
// than buried:
//
// 1. `poolPoints` returns the relaxed polyline instead of a finished path,
//    with a finite-differenced surface normal per point. The rim specular
//    that first needed those normals was cut on sight — it read as a dotted
//    line of shine — but the normals stay: they are the displaced surface's
//    own report (a normal from `rim(at:)` sits still while the liquid moves
//    underneath it), and `theSurfaceNormalTurnsWithTheSurface` gates them.
// 2. The `blur(3.4) -> alphaThreshold(0.5)` pass is not ported. It has no Canvas
//    2D equivalent, and it is redundant here: eight relaxation passes plus the
//    Catmull-Rom conversion already deliver one smooth body, and the outline is
//    generated as a single closed path rather than as parts needing fusing.
//    `Geometry.blur` is still 3.4 because the ceiling reserves that margin.

import { SITE_COUNT } from './sim.js';

export class Geometry {
  static cornerRadius = 6;
  static outlineSamples = 144;
  static anchorRun = 10;
  static edgeSlope = 4;
  static edgeFloor = 0.35;
  /// FerrofluidView.blur — the margin the ceiling leaves at the panel edge.
  static blur = 3.4;
  /// Motion.travel under Reduce Motion.
  static reducedTravel = 0.4;

  constructor(notch, panel, openness, cornerRadius = Geometry.cornerRadius) {
    this.openness = openness;
    this.panel = panel;
    this.cornerRadius = cornerRadius;

    const centerX = panel.width / 2;
    // Zero margin: the resting ink *is* the cutout, so colour begins on the same
    // line the housing ends on and there is no black skirt hanging past it.
    const inset = 0;
    const below = 0;
    const x = centerX - notch.width / 2 - inset;
    const y = -30;
    const width = notch.width + inset * 2;
    const height = 30 + notch.height + below;
    this.core = {
      x, y, width, height,
      minX: x, maxX: x + width, minY: y, maxY: y + height,
    };
    this.top = this.core.maxY - Math.min(this.core.height, notch.height + below + 6);
    const radius = cornerRadius;
    this.sideRun = Math.max(0, (this.core.maxY - this.top) - radius);
    this.arcRun = Math.PI * radius / 2;
    this.bottomRun = Math.max(0, this.core.width - 2 * radius);
    this.total = this.sideRun * 2 + this.arcRun * 2 + this.bottomRun;
  }

  /** The topmost point of the outline that is actually on screen. */
  get visibleTopU() { return (2 - this.top) / this.total; }

  /**
   * Where a site sits on the outline, blended between the two seatings.
   * A piecewise-linear warp hands each vertical run the first and last 3/17 of
   * the spectrum, so there are three peaks a side to tell apart. Monotonic and
   * continuous, so a band walks smoothly as its neighbours rise and fall.
   */
  seatU(rim) {
    const side = this.sideRun / this.total;
    const q = 3.0 / SITE_COUNT;
    const lip = this.visibleTopU;
    let open;
    if (rim < q) {
      open = lip + (rim / q) * (side - lip);
    } else if (rim > 1 - q) {
      open = 1 - lip - ((1 - rim) / q) * (side - lip);
    } else {
      open = side + ((rim - q) / (1 - 2 * q)) * (1 - 2 * side);
    }

    const visibleTop = (3 - this.top) / this.total;
    const span = Math.max(0.004, side - visibleTop);
    const closed = rim < 0.5
      ? visibleTop + rim * 2 * span
      : 1 - (visibleTop + (1 - rim) * 2 * span);

    const t = Math.min(1, Math.max(0, this.openness));
    return closed + (open - closed) * t;
  }

  /** Expanded, the vertical sides swing further than the bottom does. */
  lateralLift(normal) { return Math.abs(normal.dx) * this.openness; }

  /**
   * Retracted, only the sideways component may move: anything with a downward
   * component would push ink below the menu bar onto window chrome.
   */
  lateralGate(normal) {
    return Math.abs(normal.dx) + (1 - Math.abs(normal.dx)) * this.openness;
  }

  /**
   * The curve where the ink leaves the bezel. The run scales with the travel,
   * so the join keeps its shape at every drive. The floor is never zero — that
   * is what choked the top and handed the relaxation an anchor of zero at the
   * screen edge.
   */
  edgeFillet(point, amount) {
    const run = Math.max(0.5, Math.abs(amount) / Geometry.edgeSlope);
    const t = Math.min(1, Math.max(0, point.y / run));
    return Geometry.edgeFloor + (1 - Geometry.edgeFloor) * (t * t * (3 - 2 * t));
  }

  /**
   * How much per-band detail this piece of rim may carry, 0 at the bezel. The
   * whole-body swell deliberately ignores it: offsetting a rounded shape keeps
   * it rounded, while narrow lobes at the bezel put bumps on the one corner the
   * hardware also draws. Smootherstep, not smoothstep.
   */
  edgeDetail(point) {
    const t = Math.min(1, Math.max(0, point.y / Geometry.anchorRun));
    return t * t * t * (t * (t * 6 - 15) + 10);
  }

  /** Distance to the panel edge along the normal, so the surface is never cut flat. */
  headroom(point, normal) {
    let limit = Infinity;
    if (normal.dx > 0.001) limit = Math.min(limit, (this.panel.width - point.x) / normal.dx);
    if (normal.dx < -0.001) limit = Math.min(limit, point.x / -normal.dx);
    // Downward only. Above the panel is the bezel, off screen and already
    // handled by the retracted gate.
    if (normal.dy > 0.001) limit = Math.min(limit, (this.panel.height - point.y) / normal.dy);
    return Math.max(0, limit);
  }

  rim(position) {
    const radius = this.cornerRadius;
    let distance = Math.min(1, Math.max(0, position)) * this.total;

    if (distance < this.sideRun) {
      return {
        point: { x: this.core.minX, y: this.top + distance },
        normal: { dx: -1, dy: 0 },
      };
    }
    distance -= this.sideRun;

    if (distance < this.arcRun) {
      const angle = Math.PI - (distance / this.arcRun) * (Math.PI / 2);
      const cx = this.core.minX + radius;
      const cy = this.core.maxY - radius;
      return {
        point: { x: cx + Math.cos(angle) * radius, y: cy + Math.sin(angle) * radius },
        normal: { dx: Math.cos(angle), dy: Math.sin(angle) },
      };
    }
    distance -= this.arcRun;

    if (distance < this.bottomRun) {
      return {
        point: { x: this.core.minX + radius + distance, y: this.core.maxY },
        normal: { dx: 0, dy: 1 },
      };
    }
    distance -= this.bottomRun;

    if (distance < this.arcRun) {
      const angle = Math.PI / 2 - (distance / this.arcRun) * (Math.PI / 2);
      const cx = this.core.maxX - radius;
      const cy = this.core.maxY - radius;
      return {
        point: { x: cx + Math.cos(angle) * radius, y: cy + Math.sin(angle) * radius },
        normal: { dx: Math.cos(angle), dy: Math.sin(angle) },
      };
    }
    distance -= this.arcRun;

    return {
      point: { x: this.core.maxX, y: this.core.maxY - radius - distance },
      normal: { dx: 1, dy: 0 },
    };
  }

  /**
   * The active sites' seats and heights, resolved once for the frame.
   *
   * The height coupling in `spread` is the Rosensweig signature: a weak lobe
   * spreads into a broad ripple, a full peak pulls in tight and becomes its own
   * spire. Width tells you how hard the band hit, not just height.
   */
  lobes(sites) {
    const out = [];
    for (const site of sites) {
      if (!(site.height > 0.003)) continue;
      // Scaled to the LOCAL seat spacing, not a fixed slice of the rim: a flat
      // 0.35/17 is 30% of the spacing on the bottom run but 47% on a side,
      // where it could throw two lobes 3pt apart and fuse them.
      const step = 1.0 / (SITE_COUNT - 1);
      const local = Math.abs(this.seatU(Math.min(1, site.rim + step)) - this.seatU(site.rim));
      const jitter = site.fan * 0.3 * local;
      const seat = Math.min(1 - this.visibleTopU,
        Math.max(this.visibleTopU, this.seatU(site.rim) + jitter));
      // How sideways this lobe's OWN seat is — taken from the seat, not the
      // sample, so the lobe keeps one width and stays a symmetric mound.
      const sideness = Math.abs(this.rim(seat).normal.dx) * this.openness;
      const base = 34 - 13 * this.openness;
      const spread = base * (1 + 0.35 * site.height)
        * (1 + 0.22 * site.fan)
        * (1 + 1.0 * sideness);
      // Past this the wider Gaussian is under 1e-4.
      const reach = 5.0 / spread;
      out.push({ seat, height: site.height, spread, reach });
    }
    return out;
  }

  /**
   * Bass heaves the whole body and every active band raises a broad Gaussian
   * mound in that same surface. This is a warp, never a pile of blobs.
   */
  displacement({
    reduce = false,
    position,
    lobes,
    swell,
    raised,
    lateral = 0,
    detail = 1,
    headroom = Infinity,
    pointerRim = 0.5,
    pointerPull = 0,
  }) {
    let mound = 0;
    // A Mexican-hat basis: a narrow positive core inside a wider negative
    // surround. Ink drawn up into a peak comes from somewhere — the surface
    // between two peaks is pulled DOWN, and that inward curvature is the one
    // thing a magnetised liquid always has.
    for (const lobe of lobes) {
      if (Math.abs(lobe.seat - position) >= lobe.reach) continue;
      const d = (lobe.seat - position) * lobe.spread;
      const core = Math.exp(-d * d);
      // Shallow and only just wider than the core. A broad deep surround made
      // every neighbour subtract ~0.15 and the ink stopped leaving the cutout.
      const surround = Math.exp(-d * d * 0.35) * 0.18;
      mound += lobe.height * (core - surround);
    }

    // The pointer's own swell: a hand leaning on the surface, not a finger
    // poking it. Wider and gentler than a band's lobe.
    if (pointerPull > 0.002) {
      const d = (pointerRim - position) * 4.6;
      mound += pointerPull * 0.8 * Math.exp(-d * d);
    }

    const travel = reduce ? Geometry.reducedTravel : 1;
    // Retracted is a menu bar, not a canvas.
    const room = 0.42 + 0.58 * this.openness;
    // Less body, more crown: at swell*15 against mound*23 the bass lifted the
    // whole outline so far the per-band peaks rode on it as ripples.
    const bass = swell * 12;
    const drain = raised * 4;
    const lobeSum = mound * 27 * detail;
    // The sides are driven harder BEFORE the saturation, not scaled after it.
    const raw = (bass - drain + lobeSum) * travel * room * (1 + 1.2 * lateral);
    const ceiling = Math.min((34 + 14 * lateral) * room,
      Math.max(0, headroom - Geometry.blur));
    // Inward, and further inward on the sides, so the body pinches rather than
    // only bulging.
    const inward = () => Math.max((-7 - 7 * lateral) * room, raw * 0.55);

    if (ceiling < 0.01) return raw < 0 ? inward() : 0;
    if (raw < 0) return inward();
    return ceiling * Math.tanh(raw / ceiling);
  }

  /**
   * The displaced, relaxed outline as a polyline, plus the finite-differenced
   * surface normal at every point.
   *
   * The normal is the whole reason this returns points rather than a path. It
   * is computed AFTER relaxation, from the neighbours of the displaced point —
   * `T = normalize(P[i+1] - P[i-1])`, `N = (-T.y, T.x)` — which in this y-down
   * space gives the outward normal in all three regimes: on the left flank
   * T=(0,+1) so N=(-1,0); along the bottom T=(+1,0) so N=(0,+1); on the right
   * flank T=(0,-1) so N=(+1,0). Taking it from `rim(at:)` instead leaves the
   * highlight stationary under a moving surface.
   */
  poolPoints(displacementFn, { samples = Geometry.outlineSamples } = {}) {
    const surfaces = [];
    const amounts = new Array(samples + 1).fill(0);

    for (let sample = 0; sample <= samples; sample++) {
      const position = sample / samples;
      const surface = this.rim(position);
      surfaces.push(surface);
      amounts[sample] = displacementFn(
        position,
        this.lateralLift(surface.normal),
        this.headroom(surface.point, surface.normal),
        this.edgeDetail(surface.point),
      ) * this.lateralGate(surface.normal);
    }

    // The bezel join first, then relax the whole outline — the sweep runs LAST
    // so the thing that ships is smooth by construction, whatever shaped it.
    for (let sample = 0; sample <= samples; sample++) {
      amounts[sample] *= this.edgeFillet(surfaces[sample].point, amounts[sample]);
    }

    let points = new Array(samples + 1);
    for (let sample = 0; sample <= samples; sample++) {
      const { point, normal } = surfaces[sample];
      points[sample] = {
        x: point.x + normal.dx * amounts[sample],
        y: point.y + normal.dy * amounts[sample],
      };
    }

    // Eight light passes, endpoints held, so the outline still closes exactly
    // where the shell does. Averaging each point toward its neighbours attacks
    // the TURN directly, which is what the eye reads as sharp — bounding
    // displacement between samples does not.
    for (let pass = 0; pass < 8; pass++) {
      const relaxed = points.slice();
      for (let i = 1; i < points.length - 1; i++) {
        relaxed[i] = {
          x: points[i].x + 0.38 * (points[i - 1].x + points[i + 1].x - 2 * points[i].x),
          y: points[i].y + 0.38 * (points[i - 1].y + points[i + 1].y - 2 * points[i].y),
        };
      }
      points = relaxed;
    }

    const normals = new Array(points.length);
    for (let i = 0; i < points.length; i++) {
      const a = points[Math.max(0, i - 1)];
      const b = points[Math.min(points.length - 1, i + 1)];
      let tx = b.x - a.x;
      let ty = b.y - a.y;
      const len = Math.hypot(tx, ty);
      if (len > 1e-9) { tx /= len; ty /= len; } else { tx = 0; ty = 1; }
      normals[i] = { dx: -ty, dy: tx };
    }

    return { points, normals, amounts, surfaces };
  }
}

/**
 * Catmull-Rom through the relaxed points, then the two lines that close the
 * body above the screen edge — the same closure the Swift path makes.
 */
export function poolPath(points) {
  const path = new Path2D();
  if (points.length <= 3) return path;
  path.moveTo(points[0].x, points[0].y);
  for (let index = 0; index < points.length - 1; index++) {
    const p0 = points[Math.max(0, index - 1)];
    const p1 = points[index];
    const p2 = points[index + 1];
    const p3 = points[Math.min(points.length - 1, index + 2)];
    path.bezierCurveTo(
      p1.x + (p2.x - p0.x) / 6, p1.y + (p2.y - p0.y) / 6,
      p2.x - (p3.x - p1.x) / 6, p2.y - (p3.y - p1.y) / 6,
      p2.x, p2.y,
    );
  }
  path.lineTo(points[points.length - 1].x, -40);
  path.lineTo(points[0].x, -40);
  path.closePath();
  return path;
}
