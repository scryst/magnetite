// The menu bar, printed. The top edge of a MacBook display at page scale: the
// bezel, the menu bar either side of the notch, the wallpaper under it
// dissolving into paper, and the notch itself in solid black with the page's
// one simulation held retracted at its lip. The notch is the download link;
// the link's box is the source of truth and the print is drawn to it.
//
// Words in the bar are the ones the film's desktop shows, with the Finder in
// front, the clock is the visitor's own, and the status item beside it is
// Magnetite's mark. Round the notch is the idle pill the film lands on,
// showing what the page's soundtrack is playing.

import { Geometry } from './geometry.js';
import { createPress, makePlates, clearPlates, INK } from './press.js';

const PANEL = { width: 640, height: 190 };
const NOTCH = { width: 185, height: 32 };
/** Points tall, on a notched MacBook. */
const MENU_BAR = 37;
/** CSS pixels of the bezel's ink under the desktop that lands on it. */
const LIP = 2;
const MENUS = ['Finder', 'File', 'Edit', 'View', 'Go', 'Window', 'Help'];
/**
 * The idle pill, in points, as the recording's desktop has it: its width
 * about the notch, its foot's corners, the artwork's size and inset from its
 * left, the time's inset from its right and its size.
 */
const PILL = { width: 284, radius: 8, art: 18, inset: 11, time: 12, text: 11.5 };
/** Its body, in each plate's ink: the app's dark violet glass. */
const PILL_INK = { pink: 0.55, blue: 0.6, black: 0.72 };
const unit = (x) => Math.max(0, Math.min(1, x));
const elapsed = (seconds) => `${Math.floor(seconds / 60)}:${String(Math.floor(seconds % 60)).padStart(2, '0')}`;
const SYSTEM = 'system-ui, -apple-system, BlinkMacSystemFont, sans-serif';

export class RisoBand {
  /**
   * `link` is the download link laid over the notch. `mark` is the app's own
   * glyph, {path, box: [x, y, w, h]} from the page's SVG, for the status item.
   */
  constructor(canvas, link, { mark = null, reduceMotion = false } = {}) {
    this.canvas = canvas;
    this.link = link;
    this.mark = mark && { path: new Path2D(mark.path), box: mark.box };
    this.reduceMotion = reduceMotion;
    this.press = createPress(canvas, { pitch: (w) => Math.max(3.4, Math.min(4.6, w / 300)) });
    this.plates = makePlates();
    this.box = { w: 0, h: 0 };
    this.notch = null;
    this.scale = 1;
    this.dpr = 1;
    /** () => {at, of, art}: what the soundtrack is playing (js/player.js). */
    this.nowPlaying = null;
    /** The artwork parted into the three plates, kept for its source and size. */
    this.art = null;
    // Where the date does not fit beside the notch the bar keeps the time
    // alone, as a crowded Mac menu bar does.
    this.clocks = [
      new Intl.DateTimeFormat(undefined, {
        weekday: 'short', day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit',
      }),
      new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }),
    ];
  }

  resize() {
    const b = this.canvas.getBoundingClientRect();
    const l = this.link.getBoundingClientRect();
    this.box = { w: b.width, h: b.height };
    if (!this.press || !b.width || !b.height) return;
    this.notch = { x: l.left - b.left, y: l.top - b.top, w: l.width, h: l.height };
    this.scale = this.notch.w / NOTCH.width;
    this.dpr = this.press.resize(b.width, b.height);
    this.plateScale = Math.min(1.5, this.dpr);
    for (const plate of Object.values(this.plates)) {
      plate.width = Math.round(b.width * this.plateScale);
      plate.height = Math.round(b.height * this.plateScale);
    }
  }

  /**
   * `img` parted into the three inks at `px` square: black where it is dark,
   * blue where it wants red taken out, pink where it wants green, as they
   * multiply on paper (js/press.js). Kept until the sleeve or its size
   * changes; null until the sleeve has loaded.
   */
  separate(img, px) {
    const key = `${img.currentSrc || img.src}|${px}`;
    if (this.art?.key === key) return this.art.plates;
    if (!img.complete || !img.naturalWidth || px < 1) return null;
    const source = document.createElement('canvas');
    source.width = source.height = px;
    const read = source.getContext('2d', { willReadFrequently: true });
    read.drawImage(img, 0, 0, px, px);
    const { data } = read.getImageData(0, 0, px, px);
    const plates = {};
    const inks = {};
    for (const name of ['black', 'pink', 'blue']) {
      plates[name] = document.createElement('canvas');
      plates[name].width = plates[name].height = px;
      inks[name] = plates[name].getContext('2d').createImageData(px, px);
    }
    // How much of the green each colour ink takes out; the blue takes all the red.
    const blueG = 1 - INK.blue[1] / 255;
    const pinkG = 1 - INK.pink[1] / 255;
    for (let i = 0; i < data.length; i += 4) {
      const [r, g] = [data[i] / 255, data[i + 1] / 255];
      const k = 1 - Math.max(r, g, data[i + 2] / 255);
      const lit = 1 - k || 1;
      const blue = unit(1 - r / lit);
      const pink = unit((1 - g / lit / (1 - blue * blueG)) / pinkG);
      // Solid or nothing: a halftone at the band's pitch is a dozen dots
      // across a sleeve, so each ink is cut as a spot colour instead.
      inks.black.data[i + 3] = k > 0.5 ? 255 : 0;
      inks.pink.data[i + 3] = pink > 0.5 ? 255 : 0;
      inks.blue.data[i + 3] = blue > 0.5 ? 255 : 0;
    }
    for (const name of Object.keys(plates)) plates[name].getContext('2d').putImageData(inks[name], 0, 0);
    this.art = { key, plates };
    return plates;
  }

  render(sim, openness = 0) {
    if (!this.press || !this.notch) return false;
    const { black: K, pink: P, blue: B } = clearPlates(this.plates, this.plateScale);
    const { w, h } = this.box;
    const S = this.scale;
    const edge = this.notch.y;
    const bar = MENU_BAR * S;
    const cx = this.notch.x + this.notch.w / 2;

    // Wallpaper: the hero's split fountain, dissolving into paper below the bar.
    const fountain = (ctx, stops) => {
      const g = ctx.createLinearGradient(0, edge, 0, h);
      for (const [at, tone] of stops) g.addColorStop(at, `rgba(0,0,0,${tone})`);
      ctx.fillStyle = g;
      ctx.fillRect(0, edge, w, h - edge);
    };
    fountain(P, [[0, 0.9], [0.35, 0.55], [1, 0]]);
    fountain(B, [[0, 0.1], [0.45, 0.32], [1, 0]]);
    // The bar: a pale veil over the wallpaper, as macOS draws it.
    P.clearRect(0, edge, w, bar);
    P.fillStyle = 'rgba(0,0,0,0.38)';
    P.fillRect(0, edge, w, bar);

    // The idle pill: the playing track's artwork at its left, its time at its
    // right, and how far in it is drawn along its foot in the blue plate, as
    // the recording's desktop has it when the player goes back into the notch.
    const playing = this.nowPlaying?.();
    const pill = playing && { x: cx - (PILL.width * S) / 2, w: PILL.width * S, h: this.notch.h };
    if (pill) {
      const plates = { black: K, pink: P, blue: B };
      const within = (c, draw) => {
        c.save();
        c.beginPath();
        c.roundRect(pill.x, edge, pill.w, pill.h, [0, 0, PILL.radius * S, PILL.radius * S]);
        c.clip();
        draw(c);
        c.restore();
      };
      for (const [key, c] of Object.entries(plates)) {
        within(c, () => {
          if (c !== K) c.clearRect(pill.x, edge, pill.w, pill.h);
          c.fillStyle = `rgba(0,0,0,${PILL_INK[key]})`;
          c.fillRect(pill.x, edge, pill.w, pill.h);
        });
      }
      const line = Math.max(1.5, S);
      const played = playing.of ? unit(playing.at / playing.of) * pill.w : 0;
      if (played) {
        for (const [key, c] of Object.entries(plates)) {
          within(c, () => {
            c.clearRect(pill.x, edge + pill.h - line, played, line);
            if (key === 'blue') {
              c.fillStyle = '#000';
              c.fillRect(pill.x, edge + pill.h - line, played, line);
            }
          });
        }
      }
      const size = PILL.art * S;
      const ax = pill.x + PILL.inset * S;
      const ay = edge + (pill.h - size) / 2;
      const art = playing.art && this.separate(playing.art, Math.round(size * this.plateScale));
      if (art) {
        for (const [key, c] of Object.entries(plates)) {
          c.save();
          c.beginPath();
          c.roundRect(ax, ay, size, size, 4 * S);
          c.clip();
          c.clearRect(ax, ay, size, size);
          c.drawImage(art[key], ax, ay, size, size);
          c.restore();
        }
      }
      // The time in the paper, out of all three.
      for (const c of Object.values(plates)) {
        c.save();
        c.globalCompositeOperation = 'destination-out';
        c.font = `700 ${PILL.text * S}px ${SYSTEM}`;
        c.textAlign = 'right';
        c.textBaseline = 'middle';
        c.fillText(elapsed(playing.at),pill.x + pill.w - PILL.time * S, edge + pill.h / 2);
        c.restore();
      }
    }

    // Bezel, its ink run LIP under the bar's top edge: the desktop lands on
    // that edge at whatever fraction of a pixel the camera has, and the print's
    // own edge is softened by its screen, so butted exactly they left a hair
    // of the printed bar showing between the two.
    K.fillStyle = 'rgba(0,0,0,0.95)';
    K.fillRect(0, 0, w, edge + LIP);

    // Menus left of the pill, as many as fit; the clock and status items right.
    const size = 13 * S;
    const mid = edge + bar / 2;
    const gap = 20 * S;
    K.textBaseline = 'middle';
    K.fillStyle = '#000';
    let x = gap;
    const stop = (pill ? pill.x : this.notch.x) - 12 * S;
    for (const [i, word] of MENUS.entries()) {
      K.font = `${i === 0 ? 700 : 500} ${size}px ${SYSTEM}`;
      const width = K.measureText(word).width;
      if (x + width > stop) break;
      K.fillText(word, x, mid);
      x += width + gap;
    }
    K.font = `500 ${size}px ${SYSTEM}`;
    const right = w - gap;
    const start = (pill ? pill.x + pill.w : this.notch.x + this.notch.w) + 12 * S;
    const now = new Date();
    const clock = this.clocks.map((format) => format.format(now).replace(/,/g, ''))
      .find((text) => right - K.measureText(text).width > start);
    let cursor = clock ? right - K.measureText(clock).width : start;
    if (clock) {
      K.textAlign = 'right';
      K.fillText(clock, right, mid);
      K.textAlign = 'left';
      // Battery, then the app's own mark, each only if it clears the notch.
      const bw = 22 * S, bh = 10.5 * S;
      const bx = cursor - 16 * S - bw;
      if (bx > start) {
        K.lineWidth = 1.3 * S;
        K.strokeStyle = '#000';
        K.beginPath();
        K.roundRect(bx, mid - bh / 2, bw, bh, 3 * S);
        K.stroke();
        K.fillRect(bx + 2 * S, mid - bh / 2 + 2 * S, (bw - 4 * S) * 0.72, bh - 4 * S);
        K.fillRect(bx + bw + S, mid - 2 * S, 1.5 * S, 4 * S);
        cursor = bx;
      }
      const mh = 15 * S;
      const mw = this.mark ? (mh * this.mark.box[2]) / this.mark.box[3] : 0;
      const mx = cursor - 16 * S - mw;
      if (this.mark && mx > start) {
        const k = mh / this.mark.box[3];
        K.save();
        K.translate(mx - this.mark.box[0] * k, mid - mh / 2 - this.mark.box[1] * k);
        K.scale(k, k);
        K.fill(this.mark.path);
        K.restore();
      }
    }

    // The notch and its liquid, in panel points hung from the display's edge,
    // clipped as the app clips a retracted shell: nothing past the band it has
    // opened to.
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
    const floor = geometry.core.maxY + (PANEL.height - geometry.core.maxY) * inkOpen;
    const at = (px, py) => [cx + (px - PANEL.width / 2) * S, edge + Math.min(py, floor) * S];
    const liquid = (c) => {
      c.beginPath();
      c.moveTo(...at(points[0].x, points[0].y));
      for (const p of points) c.lineTo(...at(p.x, p.y));
      c.lineTo(...at(points[points.length - 1].x, -4));
      c.lineTo(...at(points[0].x, -4));
      c.closePath();
    };
    const cutout = (c) => {
      c.beginPath();
      c.roundRect(this.notch.x, edge - 2, this.notch.w, this.notch.h + 2,
        [0, 0, Geometry.cornerRadius * S, Geometry.cornerRadius * S]);
    };
    // Knocked out of the colours so the black lands on paper, not mud.
    for (const c of [P, B]) {
      c.save();
      c.globalCompositeOperation = 'destination-out';
      for (const shape of [liquid, cutout]) { shape(c); c.fill(); }
      c.restore();
    }
    // Trapped with a hairline of black over the edge, as a printer traps a
    // knockout, so the half-covered edge pixels do not print a pale halo.
    K.fillStyle = '#000';
    K.strokeStyle = '#000';
    K.lineWidth = 1.2;
    K.lineJoin = 'round';
    for (const shape of [liquid, cutout]) { shape(K); K.fill(); K.stroke(); }

    this.press.print(this.plates);
    return true;
  }
}
