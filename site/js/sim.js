// A port of Sources/NotchApp/Audio/FerrofluidSim.swift.
//
// Every constant here was read out of that file, not out of a design document:
// the spec this site was built from carried a lobe-spread law that no longer
// matched and two stale figures, which is the whole reason the port is verified
// against the Swift rather than against prose.
//
// The physics is deterministic given the seed. `Site.rim` and `Site.fan` are
// seeded randomly; `rim` is read only by the renderer, but a lobe's charge
// scales with its `fan`. So the same levels, the same dt and the same fans
// produce the same swell, impact, light, field and height in both languages,
// and test/portcheck.mjs asserts exactly that against a dump from the real
// Swift, which leads with the fans it drew.

export const SITE_COUNT = 17;
export const BAND_COUNT = 12;
export const SETTLED_EPSILON = 0.004;
export const SILENCE_LEVEL = 0.02;
export const GLOW_GATE = 0.14;
export const GLOW_FADE = 0.10;

// A lobe at this height counts as standing. Exported so portcheck can hold its
// held-loudness margin against the real value instead of a copy of the number.
export const STANDING_HEIGHT = 0.08;
const INITIAL_SPREAD = 0.06;
// How many swings a rise must clear to count as an onset, and how far past that
// a hit is half strength. The soft knee keeps a hit's size proportional to its
// rise, where a hard clamp made every drum a full blow.
const ONSET_FLOOR = 1.1;
const ONSET_KNEE = 1.0;
// How many typical rises a rise must be to count, against `flux`.
const FLUX_ONSET_SCALE = 8.0;
const REENTRY_AFTER = 0.35;
// How far a full hit throws the body, and a band's lobe, as a share of full travel.
const SWELL_BLOW = 0.5;
const SITE_BLOW = 12.0;
// A hit under this share of full travel charges nothing, so small hits leave
// the ink still.
const SITE_GATE = 0.35;
// How many lobes may stand at once: this many always, up to this many more as
// the music gets busier.
const FEWEST_STANDING = 2;
const EXTRA_STANDING = 7.0;
// How long the loudest recent moment is remembered, and how steeply a quieter
// passage is scaled down against it.
const LOUD_MEMORY_SECONDS = 12.0;
const LOUD_CURVE = 6.0;
// A new flash starts only this long after the last one began (the WCAG 2.3.1
// ceiling of three a second).
export const FLASH_GAP = 1.0 / 3;

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
export function glowAlpha(light, openness) {
  const t = Math.min(1, Math.max(0, (light - GLOW_GATE) / GLOW_FADE));
  const ease = t * t * (3 - 2 * t);
  return (0.10 + 0.62 * light) * ease * Math.min(1, Math.max(0, openness));
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
    this.swellVelocity = 0;
    // The body's charge from the last hit, held at the larger of its decay and
    // the newest hit, so the swell has a target to flow toward rather than a
    // blow to absorb.
    this.swellCharge = 0;
    // The loudest the music has been lately, and how near it is to that now.
    this.loudMemory = 0;
    this.loudGain = 1;
    // A track change opens the lobe budget for a moment, so the whole side it
    // leans to stands rather than whichever two lobes happen to rise first.
    this.surgeOpen = 0;
    this.raised = 0;
    this.impact = 0;
    // The hit as light: what the halo shows. `impact` may climb on every drum;
    // this starts a new flash only FLASH_GAP after the last one began. A hit
    // inside the gap still moves the ink; only the light skips it.
    this.light = 0;
    this.sinceFlash = Infinity;
    // The Swift mirrors the system's Dim Flashing Lights setting. The page has no
    // such setting to read, so this stays false.
    this.dimFlashingLights = false;
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
    // The frame before `previousLevels`. A hit's rise straddles two 16ms
    // frames, so measured against one frame back each half can fall under the
    // onset bar.
    this.olderLevels = [];
    this.kick = [];
    // Each band's typical frame-to-frame rise: a second yardstick for an onset
    // beside `spread`, which reads a section where the bass drops out and slams
    // back in as one wide swing and lifts the bar over every kick for seconds.
    this.flux = [];
    // Seconds since the music came back from silence, capped at the ramp. The
    // levels climb from nothing over the first frames back, a rise in every band
    // that is the analyser waking rather than a drum, so onsets are let in over
    // about 150ms.
    this.reentry = Infinity;
    this.baseline = [];
    this.spread = [];
    // `deviation` slowed to a drift, and the bass pool the body rests on.
    this.drift = [];
    this.pool = 0;
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
    const settled = this.swell < e && Math.abs(this.swellVelocity) < 0.02 && this.impact < e && this.light < e
      && this.pointerPull < e
      && this.inkOpen === this.openTarget
      && !this.sites.some((s) => s.height > 0.003 || Math.abs(s.velocity) > 0.05);
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
    this.reentry = 0;
    this.previousLevels = levels.slice();
    this.olderLevels = levels.slice();
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
    if (this.drift.length !== dev.length) this.drift = dev.slice();
    for (let i = 0; i < dev.length; i++) this.drift[i] += (dev[i] - this.drift[i]) * Math.min(1, 2.0 * dt);
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
        velocity: 0,
        field: 0,
        isUp: false,
      });
    }
    this.raised = 0;
    this.swell = 0;
    this.swellVelocity = 0;
    this.swellCharge = 0;
  }

  updateKick(levels, dt) {
    if (this.kick.length !== levels.length) {
      this.kick = new Array(levels.length).fill(0);
      this.previousLevels = levels.slice();
      this.olderLevels = levels.slice();
    }
    if (this.pendingSurge) {
      const held = this.pendingSurge;
      this.pendingSurge = null;
      this.surge(held.strength, held.direction);
    }
    // An onset is a rise wider than this band's own recent swing, so level
    // noise no longer kicks the surface between hits.
    const decay = Math.pow(0.00002, dt);
    this.reentry += dt;
    const wake = Math.min(1, this.reentry / 0.15);
    if (this.flux.length !== levels.length) this.flux = new Array(levels.length).fill(0.02);
    const fluxRate = Math.min(1, dt / 1.2);
    for (let i = 0; i < levels.length; i++) {
      // Subtracted at Float width, as the Swift does, before widening, and
      // measured from the lower of the last two frames.
      const rise = Math.max(0, f32(levels[i] - Math.min(this.previousLevels[i], this.olderLevels[i])));
      const swing = i < this.spread.length ? this.spread[i] : INITIAL_SPREAD;
      // Either yardstick may call it: `spread` keeps the hits it always
      // caught, `flux` adds the ones a section change hid from it.
      const ratio = Math.max(rise / Math.max(0.03, swing * 1.6),
        rise / Math.max(0.02, this.flux[i] * FLUX_ONSET_SCALE));
      const over = Math.max(0, ratio - ONSET_FLOOR);
      // Silence has no rises, so learning through it would shrink the bar to
      // nothing and the first frame back would read as a hit in every band.
      if (this.quietFor === 0) {
        this.flux[i] += (Math.max(0, f32(levels[i] - this.previousLevels[i])) - this.flux[i]) * fluxRate;
      }
      this.kick[i] = Math.max(this.kick[i] * decay, wake * Math.pow(over / (over + ONSET_KNEE), 1.5));
    }
    this.olderLevels = this.previousLevels;
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
    const weight = (band) => {
      const t = band / Math.max(1, this.kick.length - 1);
      return direction > 0 ? (0.3 + 0.7 * t) : (1 - 0.7 * t);
    };
    // The kick is raised flat, for the body and the light: leaning it as well
    // would let the end bands through the common-hit subtraction, and their
    // random spread would decide the crown instead of the surge.
    for (let i = 0; i < this.kick.length; i++) {
      this.kick[i] = Math.max(this.kick[i], strength);
    }
    // The peaks are charged directly: a surge lands in every band at once, which
    // the common-hit subtraction in `updateSites` would read as a whole-mix hit
    // and cancel, leaving a track change with no crown. A full surge stands a
    // full lobe at the end it leans to, so the crown is the surge's and not the
    // random spread's.
    for (const site of this.sites) {
      site.field = Math.max(site.field, 1.7 * strength * weight(site.band));
    }
    this.impact = Math.max(this.impact, strength);
    this.surgeOpen = Math.max(this.surgeOpen, strength);
    this.flash(strength);
    this.swell = Math.max(this.swell, strength * 0.7);
    this.publishGates();
    this.awake = true;
  }

  updateImpact(dt) {
    let hit = 0;
    for (const k of this.kick) if (k > hit) hit = k;
    this.impact = Math.max(hit, this.impact * Math.pow(0.06, dt));
    if (this.impact < SETTLED_EPSILON) this.impact = 0;
    this.sinceFlash += dt;
    this.light *= Math.pow(0.06, dt);
    this.flash(hit);
    if (this.light < SETTLED_EPSILON) this.light = 0;
  }

  /**
   * Lights a hit if the flash ceiling allows it. A hit's rise straddles two or
   * three frames, so the first 50ms of a flash may still climb; after that the
   * light only decays until the gap has passed.
   */
  flash(hit) {
    const strength = hit * (this.dimFlashingLights ? 0.35 : 1);
    if (this.sinceFlash < 0.05) {
      this.light = Math.max(this.light, strength);
    } else if (this.sinceFlash >= (this.dimFlashingLights ? 1 : FLASH_GAP) && strength > this.light + 0.1) {
      this.light = strength;
      this.sinceFlash = 0;
    }
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
    // Two parts: a pool that follows how loud the bass is over about a second,
    // so the ink rests rounded and full rather than as the bare cutout, and the
    // hit on top.
    let bass = 0;
    for (let i = 0; i < count; i++) bass += this.drift[i];
    bass /= count;
    // In silence it drains quickly, so the ink comes home and the loop can stop.
    const poolRate = this.quietFor > 0 ? 4.0 : 0.8;
    this.pool += (Math.min(1, bass * 0.03) - this.pool) * Math.min(1, poolRate * dt);
    // Any drum heaves the body, the low end hardest: a snare is a hit as much as
    // a kick, and on many mixes the sub-bass is a flat floor with the beat
    // living in the mids.
    let hit = 0;
    for (let i = 0; i < this.kick.length; i++) {
      const t = i / Math.max(1, this.kick.length - 1);
      hit = Math.max(hit, this.kick[i] * (1 - 0.9 * t));
    }
    // Critically damped toward the pool plus the held charge: the body flows out
    // over about 90ms and drains over about 400ms, with no overshoot to ring.
    const chargeTau = 0.08 / (this.quietFor > 0 ? 1.6 : 1);
    this.swellCharge = Math.max(this.swellCharge * Math.exp(-dt / chargeTau), Math.min(1.0, hit * SWELL_BLOW * this.loudGain));
    const target = this.pool + this.swellCharge;
    const omega = target > this.swell ? 30.0 : 18.0;
    this.swellVelocity += (omega * omega * (target - this.swell) - 2 * omega * this.swellVelocity) * dt;
    this.swell = Math.min(1.15, this.swell + this.swellVelocity * dt);
    if (this.swell <= 0) { this.swell = 0; this.swellVelocity = Math.max(0, this.swellVelocity); }
    if (this.swell < 0.004 && Math.abs(this.swellVelocity) < 0.02) { this.swell = 0; this.swellVelocity = 0; }
  }

  updateSites(levels, dev, dt) {
    let standing = 0;
    // What every band hit together, taken off each one, so a full-mix crash
    // raises the bands that stood out of it rather than all seventeen as one wall.
    let kickSum = 0;
    for (const k of this.kick) kickSum += k;
    const common = kickSum / Math.max(1, this.kick.length);
    // Quiet passages move less: hits are scaled by how near the music is to the
    // loudest it has been over the last several seconds, so a verse stays calm
    // under a chorus.
    this.loudMemory = Math.max(this.brightness, this.loudMemory * Math.exp(-dt / LOUD_MEMORY_SECONDS));
    this.loudGain = Math.pow(Math.min(1, this.brightness / Math.max(0.02, this.loudMemory)), LOUD_CURVE);
    for (let index = 0; index < this.sites.length; index++) {
      const site = this.sites[index];
      const band = Math.min(levels.length - 1, site.band);
      const bandT = band / Math.max(1, levels.length - 1);
      // The charge holds the larger of its own decay and the newest hit: bass
      // holds a little longer than treble, and twice as briefly once the music
      // has stopped. A hit under the gate charges nothing, so small hits leave
      // the ink still; the gate is taken off the hit, not the charge, so a held
      // lobe drains on its own curve.
      const tau = (0.11 - 0.044 * bandT) / (this.quietFor > 0 ? 1.6 : 1);
      const hit = Math.max(0, this.kick[band] - 1.3 * common) * SITE_BLOW * (1 + site.fan);
      const gated = Math.max(0, (Math.min(1.2, hit * this.loudGain) - SITE_GATE) / (1.2 - SITE_GATE));
      site.field = Math.max(site.field * Math.exp(-dt / tau), 1.2 * gated);
    }
    // Only a few lobes may stand at once, more as the music gets busier, so each
    // hit is its own move rather than the whole rim breathing.
    this.surgeOpen *= Math.exp(-dt / 0.3);
    let devSum = 0;
    for (const d of dev) devSum += d;
    const energy = Math.max(this.surgeOpen, devSum / Math.max(1, dev.length));
    const allowed = FEWEST_STANDING + Math.round(Math.min(1, energy) * EXTRA_STANDING);
    const rank = this.sites.map((_, i) => i).sort((a, b) => this.sites[b].field - this.sites[a].field);
    const mayStand = new Array(this.sites.length).fill(false);
    for (const index of rank.slice(0, allowed)) mayStand[index] = true;
    for (let index = 0; index < this.sites.length; index++) {
      const site = this.sites[index];
      const band = Math.min(levels.length - 1, site.band);
      const bandT = band / Math.max(1, levels.length - 1);
      const target = mayStand[index] ? site.field : 0;
      // The lobe follows its charge critically damped, out at about 80 rad/s and
      // home at about 20: it is out in about 60ms and drains over about 300ms,
      // never overshooting. The step is the exact solution for the frame, so it
      // starts from rest without a jump and stays stable at any rate. Bass is
      // heavy and treble light, so treble both answers and drains a little
      // quicker; one rate would smooth every band into one breath, and a quick
      // drain alone would leave the treble lower than the bass for the same hit.
      let v = site.velocity;
      const weight = 0.8 + 0.4 * bandT;
      const omega = target > site.height ? 80.0 * weight : 20.0 * weight;
      const c1 = site.height - target, c2 = v + omega * c1, decay = Math.exp(-omega * dt);
      let h = target + (c1 + c2 * dt) * decay;
      v = (c2 - omega * (c1 + c2 * dt)) * decay;
      if (h <= 0) { h = 0; v = Math.max(0, v); }
      if (h > 1.25) { h = 1.25; v = Math.min(0, v); }
      if (h < 0.003 && Math.abs(v) < 0.05) { h = 0; v = 0; }
      site.height = h;
      site.velocity = v;
      site.isUp = h > STANDING_HEIGHT;
      standing += h;
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
