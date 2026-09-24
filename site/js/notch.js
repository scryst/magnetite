// The page's own notch: the soundtrack player, drawn the way the app draws
// itself.
//
// Fixed to the top of the window at the app's own size, one CSS pixel to the
// point, and in the app's three states rather than a web player's: retracted
// to the bare cutout until the soundtrack first plays; the peek beside it —
// sleeve, clock, the progress trace along its lip — once a track is loaded;
// and the open player while the pointer, the keyboard focus or a tap is on
// it: the two halves of the clock flanking the camera, the sleeve, the title,
// the transport and the seek strip on its bottom edge. The liquid is the
// page's one simulation, hung from this notch by the same `Geometry` the hero
// and the band use, so the ink in the open panel is the ink everywhere else.
//
// The numbers are the app's. ChromeRules: panel 372 wide, the peek 100 wider
// than the cutout and a point taller, an 88pt sleeve, 24 between the band and
// the body, 14 under it. NotchController: corners 9 shut and 24 open, the top
// squared as it opens. Motion: open on a 0.42s spring damped 0.74, shut on
// 0.34 damped 0.88.
//
// The soundtrack's playhead is read and written here rather than in site.js,
// which is held to never naming the film's. This element is not the film.

import { Geometry } from './geometry.js';

const NOTCH = { width: 185, height: 32 };
const PEEK = { width: NOTCH.width + 100, height: 33 };
const PANEL = { width: 372, height: NOTCH.height + 24 + 88 + 14 };
/**
 * The app rounds the retracted shell's top (9) so it reads as a capsule
 * inside the menu bar. The page has no menu bar: at the window's edge a
 * rounded top leaves two slivers of paper and reads as a pill that floats,
 * and a square one reads as hanging from the edge, which is what a notch does.
 */
const RADIUS = { top: 0, shut: 9, open: 24 };
/** Canvas room around the open panel for its shadow, in CSS pixels. */
const SHADOW = 44;
const EXPAND = { response: 0.42, damping: 0.74 };
const COLLAPSE = { response: 0.34, damping: 0.88 };
/** The pointer has to mean it: a pass across the top of the window is not a hover. */
const DWELL_MS = 90;
const LEAVE_MS = 240;

/**
 * A damped spring stepped on the physics clock, so the notch opens in the same
 * time on every display. Semi-implicit Euler; at 1/60 the stiffest of the two
 * (ω ≈ 18.5) is well inside its stable range.
 */
class Spring {
  constructor(value = 0) {
    this.value = value;
    this.velocity = 0;
    this.target = value;
  }

  step(dt, { response, damping }) {
    const omega = (2 * Math.PI) / response;
    const pull = -omega * omega * (this.value - this.target) - 2 * damping * omega * this.velocity;
    this.velocity += pull * dt;
    this.value += this.velocity * dt;
  }

  snap() {
    this.value = this.target;
    this.velocity = 0;
  }
}

const lerp = (a, b, t) => a + (b - a) * t;
const unit = (x) => Math.max(0, Math.min(1, x));

/** `m:ss`, the app's `ExpandedPlayer.time`. */
export function clock(seconds) {
  const whole = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
}

/**
 * The outline of the shell, the app's `NotchShape.simplePath`: quadratic
 * quarter-turns at every corner, the top ones unrolling to square as it opens.
 */
function shell(c, x, w, h, top, bottom) {
  const tr = Math.max(0, Math.min(top, h / 2, w / 2));
  const br = Math.max(0, Math.min(bottom, h / 2, w / 2));
  c.beginPath();
  c.moveTo(x + tr, 0);
  if (tr > 0) c.quadraticCurveTo(x, 0, x, tr);
  c.lineTo(x, h - br);
  c.quadraticCurveTo(x, h, x + br, h);
  c.lineTo(x + w - br, h);
  c.quadraticCurveTo(x + w, h, x + w, h - br);
  c.lineTo(x + w, tr);
  if (tr > 0) c.quadraticCurveTo(x + w, 0, x + w - tr, 0);
  c.closePath();
}

/** Its bottom edge alone, corner to corner, for the progress trace. */
function lip(c, x, w, h, bottom) {
  const br = Math.max(0, Math.min(bottom, h / 2, w / 2));
  c.beginPath();
  c.moveTo(x, h - br);
  c.quadraticCurveTo(x, h, x + br, h);
  c.lineTo(x + w - br, h);
  c.quadraticCurveTo(x + w, h, x + w, h - br);
}

/** A quadratic quarter-turn is ≈ 1.18r long; near enough to walk the lip by. */
const TURN = 1.18;

/** Arc length of `lip`. */
function lipLength(w, h, bottom) {
  const br = Math.max(0, Math.min(bottom, h / 2, w / 2));
  return w - 2 * br + 2 * TURN * br;
}

/** The point `along` the lip from its left end, on the curve itself. */
function lipPoint(x, w, h, bottom, along) {
  const br = Math.max(0, Math.min(bottom, h / 2, w / 2));
  const turn = TURN * br;
  const quad = (u, p0, p1, p2) => (1 - u) * (1 - u) * p0 + 2 * (1 - u) * u * p1 + u * u * p2;
  if (turn > 0 && along < turn) {
    const u = along / turn;
    return [quad(u, x, x, x + br), quad(u, h - br, h, h)];
  }
  const right = lipLength(w, h, bottom) - along;
  if (turn > 0 && right < turn) {
    const u = right / turn;
    return [quad(u, x + w, x + w, x + w - br), quad(u, h - br, h, h)];
  }
  return [x + br + (along - turn), h];
}

export class NotchView {
  /**
   * `host` is the notch's section, which carries its state for the stylesheet;
   * its `[data-notch-shell]` is the box this sizes to the drawn shell every
   * frame, so the pointer meets exactly what is drawn. `audio` is the
   * soundtrack. `repaint` is called when a state change needs a frame and no
   * loop is running to draw one — under Reduce Motion, where there is no loop.
   */
  constructor(canvas, host, audio, { reduceMotion = false, repaint = () => {} } = {}) {
    this.canvas = canvas;
    this.host = host;
    this.shell = host.querySelector('[data-notch-shell]') || host;
    this.audio = audio;
    this.ctx = canvas.getContext('2d');
    this.reduceMotion = reduceMotion;
    this.repaint = repaint;
    this.open = new Spring(0);
    this.peek = new Spring(0);
    this.dpr = 1;
    this.track = null;
    this.wash = null;
    this.drawn = '';
    this.shown = '';
    this.boxed = '';
    this.swallow = false;
    this.hovering = false;
    this.focused = false;
    this.pinned = false;
    this.scrubbing = false;
    this.stripHot = false;
    this.timers = { dwell: 0, leave: 0 };

    const find = (name) => host.querySelector(`[data-notch-${name}]`);
    this.parts = {
      sleeve: find('sleeve'),
      title: find('title'),
      artist: find('artist'),
      elapsed: find('elapsed'),
      remaining: find('remaining'),
      peekClock: find('peek-clock'),
      seek: find('seek'),
    };

    this.wire();
    this.sync();
  }

  wire() {
    const { host, shell, audio } = this;
    const { seek } = this.parts;
    const later = (name, ms, fn) => {
      clearTimeout(this.timers[name]);
      this.timers[name] = setTimeout(fn, ms);
    };
    const cancel = (name) => clearTimeout(this.timers[name]);

    shell.addEventListener('pointerenter', (event) => {
      if (event.pointerType === 'touch') return;
      cancel('leave');
      later('dwell', DWELL_MS, () => { this.hovering = true; this.update(); });
    });
    shell.addEventListener('pointerleave', (event) => {
      if (event.pointerType === 'touch') return;
      cancel('dwell');
      later('leave', LEAVE_MS, () => { this.hovering = false; this.update(); });
    });
    // A tap opens it and a tap anywhere else shuts it. The first tap on a shut
    // notch only opens: its controls are not where the finger landed yet.
    // Decided afresh on every press, so a tap that became a scroll and never
    // clicked cannot leave the next real tap swallowed.
    shell.addEventListener('pointerdown', (event) => {
      this.swallow = event.pointerType === 'touch' && !this.pinned;
      if (!this.swallow) return;
      this.pinned = true;
      this.update();
    });
    shell.addEventListener('click', (event) => {
      if (!this.swallow) return;
      this.swallow = false;
      event.preventDefault();
      event.stopPropagation();
    }, true);
    document.addEventListener('pointerdown', (event) => {
      if (!this.pinned || shell.contains(event.target)) return;
      this.pinned = false;
      this.update();
    });
    // The keyboard opens it when the ring is showing; a click focuses too, and
    // that is the pointer's gesture, already answered by the hover.
    host.addEventListener('focusin', (event) => {
      if (event.target.matches(':focus-visible')) { this.focused = true; this.update(); }
    });
    host.addEventListener('focusout', (event) => {
      if (host.contains(event.relatedTarget)) return;
      this.focused = false;
      this.update();
    });
    host.addEventListener('keydown', (event) => {
      if (event.key !== 'Escape' || !this.open.target) return;
      this.hovering = this.focused = this.pinned = false;
      this.update();
    });

    // Seeking. The strip is a real range input, laid along the lip where the
    // app's seek strip is, so the arrow keys and a screen reader get it too.
    if (seek) {
      seek.addEventListener('input', () => {
        this.scrubbing = true;
        const duration = this.duration();
        if (duration) audio.currentTime = (seek.valueAsNumber / 1000) * duration;
        this.sync();
      });
      seek.addEventListener('change', () => { this.scrubbing = false; this.sync(); });
      seek.addEventListener('pointerenter', () => { this.stripHot = true; this.poke(); });
      seek.addEventListener('pointerleave', () => { this.stripHot = false; this.poke(); });
      seek.addEventListener('focus', () => { this.stripHot = seek.matches(':focus-visible'); this.poke(); });
      seek.addEventListener('blur', () => { this.stripHot = false; this.poke(); });
    }
    for (const type of ['timeupdate', 'durationchange', 'loadedmetadata', 'seeked', 'emptied', 'play', 'pause']) {
      audio.addEventListener(type, () => this.sync());
    }
  }

  /** The loaded track's length: the file's once it has said, the markup's until then. */
  duration() {
    const own = this.audio.duration;
    if (Number.isFinite(own) && own > 0) return own;
    return this.track?.duration || 0;
  }

  progress() {
    const duration = this.duration();
    return duration ? unit(this.audio.currentTime / duration) : 0;
  }

  /** The words and the strip, from the element. The canvas reads the same numbers each frame. */
  sync() {
    const { elapsed, remaining, peekClock, seek } = this.parts;
    const duration = this.duration();
    const at = this.audio.currentTime || 0;
    const shown = `${clock(at)}|${clock(duration - at)}`;
    if (shown !== this.shown) {
      this.shown = shown;
      if (elapsed) elapsed.textContent = clock(at);
      if (peekClock) peekClock.textContent = clock(at);
      if (remaining) remaining.textContent = `-${clock(duration - at)}`;
      if (seek) seek.setAttribute('aria-valuetext', `${clock(at)} of ${clock(duration)}`);
    }
    if (seek) {
      seek.disabled = !(Number.isFinite(this.audio.duration) && this.audio.duration > 0);
      if (!this.scrubbing) seek.value = String(Math.round(this.progress() * 1000));
    }
    this.host.dataset.playing = String(!this.audio.paused);
    this.poke();
  }

  /** Show a track: its sleeve, its words, and the colour its cover washes the glass. */
  show(track) {
    this.track = track;
    const { sleeve, title, artist } = this.parts;
    if (sleeve) sleeve.src = track.cover;
    if (title) title.textContent = track.title;
    if (artist) artist.textContent = track.artist;
    this.host.style.setProperty('--tint', track.tint);
    // The wash is the cover itself, shrunk to three pixels and stretched back
    // over the glass: bilinear upscaling of a 3x3 is the blur the app asks
    // `.blur(radius: 46)` for, at no cost per frame and in every browser.
    const cover = new Image();
    cover.decoding = 'async';
    cover.onload = () => {
      if (this.track !== track) return;
      const wash = document.createElement('canvas');
      wash.width = wash.height = 3;
      const w = wash.getContext('2d', { willReadFrequently: true });
      w.imageSmoothingQuality = 'high';
      w.drawImage(cover, 0, 0, 3, 3);
      // Averaging a cover down to nine pixels greys it: every colour in it is
      // mixed with its neighbours. The app's glass is lit by the cover's
      // colours, so their saturation is put back and their lightness held
      // where white type stays legible on it.
      try {
        const pixels = w.getImageData(0, 0, 3, 3);
        const d = pixels.data;
        for (let i = 0; i < d.length; i += 4) {
          const [r, g, b] = [d[i], d[i + 1], d[i + 2]];
          const grey = (r + g + b) / 3;
          const lift = Math.min(1.9, 150 / Math.max(1, Math.max(r, g, b)));
          for (let k = 0; k < 3; k++) {
            const saturated = grey + (d[i + k] - grey) * 2.2;
            d[i + k] = Math.max(0, Math.min(255, saturated * Math.max(1, lift * 0.8)));
          }
        }
        w.putImageData(pixels, 0, 0);
      } catch { /* a tainted cover keeps its plain wash */ }
      this.wash = wash;
      this.drawn = '';
      this.poke();
    };
    cover.src = track.cover;
    this.drawn = '';
    this.sync();
  }

  /** The peek stays out once a track has played, paused or not — as the app's does. */
  set loaded(value) {
    this.peek.target = value ? 1 : 0;
    this.update();
  }

  get loaded() { return this.peek.target === 1; }

  update() {
    const open = this.hovering || this.focused || this.pinned;
    this.open.target = open ? 1 : 0;
    this.host.toggleAttribute('data-open', open);
    this.poke();
  }

  /** Ask for a frame when nothing else will draw one. */
  poke() {
    if (!this.reduceMotion) return;
    this.open.snap();
    this.peek.snap();
    this.repaint();
  }

  /** One physics step. */
  step(dt) {
    this.open.step(dt, this.open.target ? EXPAND : COLLAPSE);
    this.peek.step(dt, this.peek.target ? EXPAND : COLLAPSE);
  }

  /** How far the ink hangs open: the shell's own openness, overshoot trimmed. */
  get openness() { return unit(this.open.value); }

  resize() {
    if (!this.ctx) return;
    this.dpr = Math.min(2, globalThis.devicePixelRatio || 1);
    const w = PANEL.width + SHADOW * 2;
    const h = PANEL.height + SHADOW * 1.5;
    this.canvas.style.width = `${w}px`;
    this.canvas.style.height = `${h}px`;
    this.canvas.width = Math.round(w * this.dpr);
    this.canvas.height = Math.round(h * this.dpr);
    this.drawn = '';
  }

  render(sim, openness = this.openness) {
    const c = this.ctx;
    if (!c) return false;
    const o = this.open.value;
    const shown = unit(o);
    const p = this.peek.value;
    const w = lerp(lerp(NOTCH.width, PEEK.width, p), PANEL.width, o);
    const h = lerp(lerp(NOTCH.height, PEEK.height, p), PANEL.height, o);
    const top = lerp(RADIUS.top, 0, shown);
    const bottom = lerp(RADIUS.shut, RADIUS.open, shown);
    const progress = this.progress();
    const hot = this.stripHot || this.scrubbing;

    // The box follows the shell, so hit-testing and the clip on the words are
    // the drawn outline and not a box around it. Written only when it moved:
    // at rest this is every frame, and a style write is a style recalc.
    const boxed = `${w.toFixed(1)}|${h.toFixed(1)}|${shown.toFixed(3)}|${unit(p).toFixed(3)}`;
    if (boxed !== this.boxed) {
      this.boxed = boxed;
      const style = this.shell.style;
      style.width = `${w.toFixed(1)}px`;
      style.height = `${h.toFixed(1)}px`;
      style.borderRadius = `${top.toFixed(1)}px ${top.toFixed(1)}px ${bottom.toFixed(1)}px ${bottom.toFixed(1)}px`;
      this.host.style.setProperty('--open', shown.toFixed(3));
      this.host.style.setProperty('--peek', unit(p).toFixed(3));
    }

    // Shut, the ink is black on a black shell and cannot be seen: only the
    // size and the trace can change what is on screen, so an unchanged frame
    // is not redrawn.
    const key = `${w.toFixed(1)}|${h.toFixed(1)}|${o.toFixed(3)}|${Math.round(progress * w)}|${hot}|${!!this.wash}`;
    if (o < 0.002 && key === this.drawn) return true;
    this.drawn = key;

    const dpr = this.dpr;
    const cw = this.canvas.width / dpr;
    const x = (cw - w) / 2;
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    c.clearRect(0, 0, cw, this.canvas.height / dpr);

    // The shell, and under it the shadow the open panel casts.
    c.save();
    c.shadowColor = `rgba(0,0,0,${0.5 * shown})`;
    c.shadowBlur = 28 * shown * dpr;
    c.shadowOffsetY = 14 * shown * dpr;
    c.fillStyle = '#000';
    shell(c, x, w, h, top, bottom);
    c.fill();
    c.restore();

    c.save();
    shell(c, x, w, h, top, bottom);
    c.clip();

    // The glass: the cover washed across it, under a scrim, fading in as the
    // shell opens. Shut it is the black of the cutout it grows from.
    if (this.wash && shown > 0.002) {
      c.globalAlpha = shown;
      c.imageSmoothingEnabled = true;
      c.imageSmoothingQuality = 'high';
      c.drawImage(this.wash, x - w * 0.09, -h * 0.09, w * 1.18, h * 1.18);
      c.fillStyle = 'rgba(0,0,0,0.22)';
      c.fillRect(x, 0, w, h);
      c.globalAlpha = 1;
    }

    // The ink, hung from the cutout and clipped as the app clips it: nothing
    // past the band it has opened to.
    if (sim) {
      const inkOpen = Math.max(0, Math.min(openness, sim.inkOpen));
      const panel = { width: w, height: h };
      const geometry = new Geometry(NOTCH, panel, inkOpen);
      const lobes = geometry.lobes(sim.sites);
      const { points } = geometry.poolPoints(
        (position, lateral, headroom, detail) => geometry.displacement({
          reduce: this.reduceMotion, position, lobes, swell: sim.swell, raised: sim.raised,
          lateral, detail, headroom, pointerRim: sim.pointerRim, pointerPull: sim.pointerPull,
        }),
        { samples: Geometry.outlineSamples },
      );
      const floor = geometry.core.maxY + (h - geometry.core.maxY) * inkOpen;
      c.beginPath();
      c.moveTo(x + points[0].x, Math.min(points[0].y, floor));
      for (const pt of points) c.lineTo(x + pt.x, Math.min(pt.y, floor));
      c.lineTo(x + points[points.length - 1].x, -4);
      c.lineTo(x + points[0].x, -4);
      c.closePath();
      c.fillStyle = '#000';
      c.fill();
    }
    c.restore();

    // The trace: the lip in the cover's colour, lit as far as the track has
    // played. It thickens under the pointer, where it is the seek strip.
    if (this.loaded || shown > 0.002) {
      const tint = this.track?.tint || '#8aa';
      const width = hot ? 6 : 2.5;
      const length = lipLength(w, h, bottom);
      c.lineCap = 'round';
      c.lineWidth = width;
      c.strokeStyle = tint;
      c.globalAlpha = 0.3 * Math.max(unit(p), shown);
      lip(c, x, w, h - width / 2, bottom);
      c.stroke();
      // Lit along the flat of the lip only, so the playhead sits on the edge
      // it seeks along rather than on a wall at 0:00 and 3:21.
      const br = Math.max(0, Math.min(bottom, h / 2, w / 2));
      const turn = TURN * br;
      const along = turn + (length - 2 * turn) * progress;
      c.globalAlpha = Math.max(unit(p), shown);
      c.setLineDash([Math.max(0.01, along - turn), length + 10]);
      c.lineDashOffset = -turn;
      lip(c, x, w, h - width / 2, bottom);
      c.stroke();
      c.setLineDash([]);
      c.lineDashOffset = 0;
      c.globalAlpha = 1;
      // The playhead, where the open strip can be taken hold of.
      if (shown > 0.5) {
        const [hx, hy] = lipPoint(x, w, h - width / 2, bottom, along);
        c.fillStyle = '#fff';
        c.globalAlpha = (shown - 0.5) * 2;
        c.beginPath();
        c.arc(hx, hy, hot ? 6 : 3.2, 0, Math.PI * 2);
        c.fill();
        c.globalAlpha = 1;
      }
    }
    return true;
  }
}
