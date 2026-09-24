// A port of Sources/NotchApp/Audio/FerrofluidSim.swift.
//
// Every constant here was read out of that file, not out of a design document:
// the spec this site was built from carried a lobe-spread law that no longer
// matched and two stale figures, which is the whole reason the port is verified
// against the Swift rather than against prose.
//
// The physics is deterministic. `Site.rim` and `Site.fan` are seeded randomly
// but are read only by the renderer — `updateSites` touches `band` and nothing
// else — so the same levels and the same dt produce the same swell, impact,
// field and height in both languages, and test/portcheck.mjs asserts exactly
// that against a dump from the real Swift.

export const SITE_COUNT = 17;
export const BAND_COUNT = 12;
export const SETTLED_EPSILON = 0.004;
export const SILENCE_LEVEL = 0.02;
export const GLOW_GATE = 0.14;
export const GLOW_FADE = 0.10;

// Exported so portcheck can hold its held-loudness margin against the real
// value instead of a copy of the number.
export const CRITICAL_FIELD = 0.36;
const COLLAPSE_FIELD = 0.16;
const INITIAL_SPREAD = 0.06;
const REENTRY_AFTER = 0.35;

/**
 * The Swift carries band levels as `[Float]`, and three places do their
 * arithmetic at that width before widening: the per-band rise in `updateKick`,
 * the loudness sum in `updateFlow`, and the silence comparisons. JavaScript has
 * one number type, so those points are rounded explicitly — without this the
 * port tracks the shipping sim to about 1e-8 and then drifts, because
 * `Double(Float(0.55))` is 0.550000011920929 and not 0.55.
 *
 * This was not in the build spec. It came out of comparing against a dump from
 * the real thing, which is the only reason it is here.
 */
const f32 = Math.fround;
const SILENCE_F32 = f32(SILENCE_LEVEL);
const STIR_F32 = f32(0.004);

/** The halo's alpha, eased to nothing at the gate. Verbatim from the Swift. */
export function glowAlpha(impact, openness) {
  const t = Math.min(1, Math.max(0, (impact - GLOW_GATE) / GLOW_FADE));
  const ease = t * t * (3 - 2 * t);
  return (0.10 + 0.62 * impact) * ease * Math.min(1, Math.max(0, openness));
}

/** Deterministic RNG so the harness can seed sites reproducibly. */
export function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export class FerrofluidSim {
  constructor(random = Math.random) {
    this.random = random;
    this.sites = [];
    this.swell = 0;
    this.raised = 0;
    this.impact = 0;
    this.inkOpen = 0;
    this.openTarget = 0;
    this.reduceMotion = false;
    this.flowPhase = 0;
    this.brightness = 0;
    this.isSettled = true;
    this.hasSound = false;
    this.pointerRim = 0.5;
    this.pointerRimTarget = 0.5;
    this.pointerPull = 0;
    this.pointerTarget = 0;
    this.previousLevels = [];
    this.kick = [];
    this.baseline = [];
    this.spread = [];
    this.quietFor = 0;
    this.pendingSurge = null;
    // Stands in for `runClock()`. The Swift owns a 16ms Task; on the page the
    // rAF driver owns the clock and reads this to know whether to keep running.
    this.awake = false;
    // Scratch, so quantising the incoming levels does not allocate per frame.
    this.levels = [];
  }

  /** Incoming levels at the width the Swift actually carries them. */
  quantise(levels) {
    if (this.levels.length !== levels.length) this.levels = new Array(levels.length).fill(0);
    for (let i = 0; i < levels.length; i++) this.levels[i] = f32(levels[i]);
    return this.levels;
  }

  /** Clear the settled gate and guarantee something will recompute it. */
  wake() {
    if (this.isSettled) this.isSettled = false;
    this.awake = true;
  }

  setOpen(open) {
    const t = open ? 1.0 : 0.0;
    if (t === this.openTarget) return;
    this.openTarget = t;
    this.wake();
  }

  setPointer(rim, strength = 1) {
    if (rim === null || rim === undefined) {
      this.pointerTarget = 0;
      return;
    }
    this.pointerRimTarget = Math.min(1, Math.max(0, rim));
    this.pointerTarget = Math.min(1.6, Math.max(0, strength));
    this.wake();
  }

  publishGates() {
    const e = SETTLED_EPSILON;
    const settled = this.swell < e && this.impact < e && this.pointerPull < e
      && this.inkOpen === this.openTarget
      && !this.sites.some((s) => s.height > 0.003);
    if (settled !== this.isSettled) this.isSettled = settled;
    const sound = this.brightness >= 0.002;
    if (sound !== this.hasSound) this.hasSound = sound;
  }

  /**
   * Resuming is not an onset: re-seed the memory both of the sim's inputs
   * measure change against, so the first frame after a pause is a non-event.
   * `spread` is deliberately NOT reset.
   */
  reenter(levels) {
    this.previousLevels = levels.slice();
    this.baseline = levels.map(Number);
  }

  advance(input, dt) {
    if (!input.length) return;
    const levels = this.quantise(input);

    const scale = this.reduceMotion ? 2.6 : 1.0;
    const openRate = (this.openTarget > this.inkOpen
      ? (1.4 + 10.0 * this.inkOpen)
      : (8.0 + 16.0 * (1 - this.inkOpen))) * scale;
    this.inkOpen += (this.openTarget - this.inkOpen) * Math.min(1, openRate * dt);
    if (this.openTarget === 1 && this.inkOpen > 0.98) this.inkOpen = 1;
    if (this.openTarget === 0 && this.inkOpen < 0.02) this.inkOpen = 0;

    const pullRate = this.pointerTarget > this.pointerPull ? 7.0 : 3.4;
    this.pointerPull += (this.pointerTarget - this.pointerPull) * Math.min(1, pullRate * dt);
    if (this.pointerPull < 0.002) this.pointerPull = 0;
    this.pointerRim += (this.pointerRimTarget - this.pointerRim) * Math.min(1, 5.0 * dt);

    if (levels.some((v) => v > SILENCE_F32)) {
      if (this.quietFor >= REENTRY_AFTER) this.reenter(levels);
      this.quietFor = 0;
    } else {
      this.quietFor += dt;
    }

    // Nothing to advance: silent, and every part of the fluid already home.
    if (this.sites.length === SITE_COUNT && this.isSettled && this.brightness < 0.002
      && this.pointerTarget === 0 && this.pointerPull === 0
      && this.inkOpen === this.openTarget
      && !levels.some((v) => v > STIR_F32)) {
      this.awake = false;
      return;
    }

    if (this.sites.length !== SITE_COUNT) this.seed(levels);
    this.updateKick(levels, dt);
    const dev = this.deviation(levels, dt);
    this.updateSwell(levels, dev, dt);
    this.updateFlow(levels, dt);
    this.updateImpact(dt);
    this.publishGates();
    this.updateSites(levels, dev, dt);
  }

  seed(levels) {
    const r = this.random;
    this.sites = [];
    for (let index = 0; index < SITE_COUNT; index++) {
      const position = (index + 0.5) / SITE_COUNT;
      const band = Math.min(levels.length - 1, Math.floor(position * levels.length));
      this.sites.push({
        rim: Math.min(1, Math.max(0, position + (r() * 0.024 - 0.012))),
        band,
        fan: r() * 0.76 - 0.38,
        height: 0,
        field: 0,
        isUp: false,
      });
    }
    this.raised = 0;
    this.swell = 0;
  }

  updateKick(levels, dt) {
    if (this.kick.length !== levels.length) {
      this.kick = new Array(levels.length).fill(0);
      this.previousLevels = levels.slice();
    }
    if (this.pendingSurge) {
      const held = this.pendingSurge;
      this.pendingSurge = null;
      this.surge(held.strength, held.direction);
    }
    const decay = Math.pow(0.05, dt);
    for (let i = 0; i < levels.length; i++) {
      // Subtracted at Float width, as the Swift does, before widening.
      const rise = Math.max(0, f32(levels[i] - this.previousLevels[i]));
      this.kick[i] = Math.max(this.kick[i] * decay, Math.min(1, rise * 8));
    }
    this.previousLevels = levels.slice();
  }

  deviation(levels, dt) {
    if (this.baseline.length !== levels.length) {
      this.baseline = levels.map(Number);
      this.spread = new Array(levels.length).fill(INITIAL_SPREAD);
    }
    const rate = Math.min(1, dt / 2.5);
    const result = new Array(levels.length).fill(0);
    for (let i = 0; i < levels.length; i++) {
      const value = levels[i];
      const delta = value - this.baseline[i];
      this.baseline[i] += delta * rate;
      this.spread[i] += (Math.abs(delta) - this.spread[i]) * rate;
      result[i] = Math.max(0, delta) / Math.max(0.035, this.spread[i] * 1.6);
    }
    return result;
  }

  /**
   * Slam the reservoir. A track change is exactly as much of an event as a drum
   * hit, so it goes in through the same door. `direction` is +1 forward, -1
   * back, 0 for anything with no direction. The profile is mirrored rather than
   * travelling — a moving front reads as a pile at the wrong end for ~0.27s.
   */
  surge(strength = 1, direction = 0) {
    if (!this.kick.length) {
      this.pendingSurge = {
        strength: Math.max(this.pendingSurge ? this.pendingSurge.strength : 0, strength),
        direction: direction !== 0 ? direction : (this.pendingSurge ? this.pendingSurge.direction : 0),
      };
      this.awake = true;
      return;
    }
    for (let i = 0; i < this.kick.length; i++) {
      const t = i / Math.max(1, this.kick.length - 1);
      const w = direction > 0 ? (0.45 + 0.55 * t) : (1 - 0.55 * t);
      this.kick[i] = Math.max(this.kick[i], strength * w);
    }
    this.impact = Math.max(this.impact, strength);
    this.swell = Math.max(this.swell, strength * 0.7);
    this.publishGates();
    this.awake = true;
  }

  updateImpact(dt) {
    let hit = 0;
    for (const k of this.kick) if (k > hit) hit = k;
    this.impact = Math.max(hit, this.impact * Math.pow(0.06, dt));
    if (this.impact < SETTLED_EPSILON) this.impact = 0;
  }

  updateFlow(levels, dt) {
    // `levels.reduce(0, +)` accumulates at Float width and is widened once.
    let sum = 0;
    for (const v of levels) sum = f32(sum + v);
    const loud = levels.length ? sum / levels.length : 0;
    const rate = loud > this.brightness ? 6.0 : 2.2;
    this.brightness += (loud - this.brightness) * Math.min(1, rate * dt);
    if (this.brightness < 0.002) this.brightness = 0;
    this.flowPhase += this.brightness * 2.6 * dt;
  }

  updateSwell(levels, dev, dt) {
    const count = Math.max(1, Math.min(3, levels.length));
    let bass = 0;
    for (let i = 0; i < count; i++) bass += dev[i];
    bass /= count;
    const target = Math.min(1, bass * 0.8);
    const rate = target > this.swell ? 22.0 : 5.5;
    this.swell += (target - this.swell) * Math.min(1, rate * dt);
    if (this.swell < 0.004) this.swell = 0;
  }

  updateSites(levels, dev, dt) {
    let standing = 0;
    let energySum = 0;
    for (const d of dev) energySum += d;
    const energy = energySum / Math.max(1, dev.length);
    const allowed = 2 + Math.round(Math.min(1, energy) * 7);

    const rank = this.sites.map((_, i) => i)
      .sort((a, b) => this.sites[b].field - this.sites[a].field);
    const mayStand = new Array(this.sites.length).fill(false);
    for (const index of rank.slice(0, allowed)) mayStand[index] = true;

    for (let index = 0; index < this.sites.length; index++) {
      const site = this.sites[index];
      const band = Math.min(levels.length - 1, site.band);
      const raw = Math.min(1, dev[band] * 0.5 + this.kick[band] * 0.8);

      const fieldRate = raw > site.field ? 40.0 : 9.0;
      site.field += (raw - site.field) * Math.min(1, fieldRate * dt);
      const field = site.field;

      if (site.isUp) {
        if (field < COLLAPSE_FIELD || !mayStand[index]) site.isUp = false;
      } else if (field > CRITICAL_FIELD && mayStand[index]) {
        site.isUp = true;
      }

      let target;
      if (site.isUp) {
        // Power law, not a floor plus a curve: 0.1441…1.0 is a 6.94:1 range, so
        // a quiet band is a ripple and a hit is a spire. A floor made every
        // standing peak at least 0.32, which is the same-height spike comb.
        //
        // That figure is a FUNCTION of CRITICAL_FIELD, not a constant beside
        // it: onset is ((CRITICAL_FIELD − COLLAPSE_FIELD) / (1 − COLLAPSE_FIELD))
        // ** 1.35. It read 0.089 and 11:1 for as long as the field was 0.30,
        // and stayed at 0.089 when 858889f moved the field to 0.36 — in the
        // Swift original and here in the port, so one constant moving left the
        // same wrong number in two languages.
        const excess = (field - COLLAPSE_FIELD) / (1 - COLLAPSE_FIELD);
        target = Math.min(1, Math.pow(Math.max(0, excess), 1.35));
      } else {
        target = 0;
      }

      // Bass is heavy and drains slowly; treble is light and snaps back.
      const bandT = band / Math.max(1, levels.length - 1);
      const fall = 4.6 * (0.55 + 1.5 * bandT);
      const heightRate = target > site.height ? 24.0 : fall;
      site.height += (target - site.height) * Math.min(1, heightRate * dt);
      if (site.height < 0.003) site.height = 0;
      standing += site.height;
    }

    // Surface tension shares ink between neighbours. First-order diffusion
    // only: no springs and no overshoot.
    if (this.sites.length > 2) {
      const heights = this.sites.map((s) => s.height);
      const rate = Math.min(0.5, 3.2 * dt);
      for (let index = 1; index < this.sites.length - 1; index++) {
        const mean = (heights[index - 1] + heights[index + 1]) / 2;
        this.sites[index].height += (mean - heights[index]) * rate;
      }
    }

    const targetRaised = Math.min(1, standing / Math.max(1, this.sites.length) * 1.4);
    this.raised += (targetRaised - this.raised) * Math.min(1, 9 * dt);
  }

  /** How many sites are currently standing. Printed by the page's readouts. */
  get standingCount() {
    let n = 0;
    for (const s of this.sites) if (s.isUp) n++;
    return n;
  }

  get meanField() {
    if (!this.sites.length) return 0;
    let sum = 0;
    for (const s of this.sites) sum += s.field;
    return sum / this.sites.length;
  }
}
