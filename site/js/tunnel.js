// The journey, scrolled through.
//
// One camera from the top of the page to the download. The printed laptop in
// the hero stays put as the words scroll away, turns square on and pushes in
// until its screen is the window (js/hero.js, `setDive`). Over the last of
// that push its screen comes on: the recorded desktop, laid exactly on the
// printed screen wherever the dive has it, the same pink falling into blue, so
// the print lights up while the camera is still moving. The film section pins
// with the desktop filling the window, the notch hanging from its top, and
// from there the camera follows the footage rather than the scroll: in on the
// player as the pointer rises to it, held there through every gesture, back
// out to the whole desktop as the player goes into the notch. Scrolling on,
// the page comes back and the desktop rides down onto the menu bar below
// until its notch is the band's notch — the download link — where it hands
// over to the print.
//
// The desktop is a still of the take's own first frame and the footage covers
// only the part of it that moves: the player under the notch and the
// pointer's whole way to it, where the take recorded them. The footage has
// two pixels a point, and the camera draws a point at no more than 1.8 CSS
// pixels: close enough to be a push in, and on a Retina display the type in
// it is drawn at most 1.8 times as large as it was shot, which stays crisp.
//
// Reduce Motion gets none of this: no pin, no camera, the footage as it was.

/** The display the take was recorded on, in points; the print's is the same. */
const SCREEN = { width: 1512, height: 982 };
/**
 * The footage's region of that display, in the same points: the player under
 * the notch and all of the pointer's way to it. The still carries the rest.
 */
export const FOOTAGE = { x: 540, y: 0, width: 570, height: 660 };
/** The notch's width in display points: the unit every scale here is in. */
const NOTCH_WIDTH = 185;
/** The most CSS pixels a display point takes: the footage's two, 1.8 times as large at 2x. */
const CLOSEST = 1.8;
/**
 * The player as the close shot frames it, in points: its panel, and the
 * fingers drawn under it down to the lowest a swipe carries them. It stays
 * above WORDS, the CSS pixels the film's words take at the window's foot.
 */
export const PLAYER = { width: 440, height: 290 };
export const WORDS = 300;
/**
 * Seconds into media/film.mp4 where the camera moves, read off the take. The
 * film opens on the player, close. It pulls back as the pointer leaves the
 * player and the player goes into the notch (the pointer sets off at 20.39s),
 * and pushes in again as the pointer rises to the notch (from 28.39s) and the
 * player opens, so the loop comes round to its first frame close.
 */
export const SHOTS = { out: [20.3, 22], in: [28.3, 30] };
/** The last share of the dive, over which the screen comes on. */
const ON = 0.25;
/** The film's own region of the scroll: the camera handed from the dive to the footage by SETTLE. */
const SETTLE = 0.12;
/**
 * The pull runs on the band's notch, not on the film's scroll. It begins as
 * that notch comes within FROM window-heights of the top, still below the
 * window, and the desktop has landed on it, and let it go, by the time it has
 * risen to LAND: the download is in the clear for the rest of its way up.
 */
const FROM = 1.5;
const LAND = 0.72;

const unit = (x) => Math.max(0, Math.min(1, x));
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);

/**
 * The two shots for a viewport of `vw` x `vh`, as CSS pixels a display point
 * takes: `wide`, the whole desktop just filling the window, and `close`, the
 * player as large as the footage's pixels and the window allow — never less
 * than wide, so a phone, whose window the desktop only fills already close,
 * holds one shot. Pure, so the dive and the tunnel agree on one number and a
 * check can hold them to it.
 */
export function shots(vw, vh) {
  const wide = Math.max(vw / SCREEN.width, vh / SCREEN.height);
  const close = Math.max(wide, Math.min(CLOSEST, (vw - 32) / PLAYER.width, (vh - WORDS) / PLAYER.height));
  return { wide, close };
}

/**
 * Where the dive lands: the notch's top edge at (x, y), hanging from the
 * middle of the window's top edge, and the wide shot's scale.
 */
export function hold(vw, vh) {
  return { x: vw / 2, y: 0, scale: shots(vw, vh).wide };
}

/** How far in the camera is at `t` seconds into the footage: 0 wide, 1 close. */
export function focus(t) {
  const [o0, o1] = SHOTS.out;
  const [i0, i1] = SHOTS.in;
  if (t < o0) return 1;
  if (t < o1) return 1 - ease((t - o0) / (o1 - o0));
  if (t < i0) return 0;
  if (t < i1) return ease((t - i0) / (i1 - i0));
  return 1;
}

/**
 * Where the camera is at the film's scroll progress `p` (0-1), once the dive
 * is done, with the footage `t` seconds in: the notch's top edge and scale,
 * how much of the footage is left, and how far up its words are. `dock` is
 * the band's notch, {x, y, scale}, wherever it is on screen now.
 */
export function camera(p, vw, vh, dock, t = 0) {
  const at = hold(vw, vh);
  const { wide, close } = shots(vw, vh);
  // In log space, so a zoom reads as one steady move. The footage's own shot
  // comes in over the film's first scroll, from where the dive left it.
  const film = wide * (close / wide) ** focus(t);
  const held = wide * (film / wide) ** unit(p / SETTLE);
  const k = dock ? ease(unit((FROM * vh - dock.y) / ((FROM - LAND) * vh))) : 0;
  const lerp = (a, b) => a + (b - a) * k;
  return {
    x: dock ? lerp(at.x, dock.x) : at.x,
    y: dock ? lerp(at.y, dock.y) : at.y,
    scale: dock ? held * (dock.scale / held) ** k : held,
    // The footage goes first, over the first of the pull, and leaves the
    // still: the desktop idle, the player back in the notch, as the band's is.
    live: unit(1 - k / 0.35),
    // The desktop hands over to the print in the last of the pull.
    fade: unit((1 - k) / 0.2),
    words: unit((p - SETTLE) / 0.1) * (1 - unit(k / 0.2)),
    k,
  };
}

export function startTunnel(section, { reduceMotion = false, hero = null, dock = null, film = null } = {}) {
  const mac = section && section.querySelector('[data-tunnel-mac]');
  const pin = section && section.querySelector('.film__pin');
  if (!mac || !pin || reduceMotion) return null;
  section.dataset.tunnel = 'on';
  document.documentElement.dataset.journey = 'on';
  // The notch's top edge, in the display's own points: centred, at the top.
  const notch = { x: SCREEN.width / 2, y: 0 };
  mac.style.transformOrigin = '0 0';

  let queued = 0;
  let last = '';
  /** Seconds into the footage, as of the frame on screen. */
  let t = 0;
  function place() {
    queued = 0;
    const vw = innerWidth;
    const vh = pin.clientHeight || innerHeight;
    const box = section.getBoundingClientRect();
    // The dive: from the top of the page to the film pinning.
    const before = box.top + scrollY;
    const dive = before > 0 ? unit(scrollY / before) : 1;
    const run = box.height - vh;
    const p = run > 0 ? unit(-box.top / run) : 0;
    const link = dock && dock.getBoundingClientRect();
    const band = link && link.width
      ? { x: link.left + link.width / 2, y: link.top, scale: link.width / NOTCH_WIDTH }
      : null;
    const c = camera(p, vw, vh, band, t);
    const at = hold(vw, vh);
    // The print is only worth drawing until the desktop has covered it, and
    // it must not come back behind the page as the pull lets the desktop go.
    hero?.setDive(dive, at, scrollY, dive >= 1 && p >= SETTLE);
    // Until the pin, the desktop is laid on the print's own screen, wherever
    // the dive has it; from the pin on, it is the camera's.
    const on = unit((dive - (1 - ON)) / ON);
    const laid = dive < 1 ? hero?.notchAt() : null;
    const { x, y, scale } = laid || c;

    // Every value written below, or a fade that moves while the camera holds
    // still (the words coming up in the hold) is skipped and stays where it was.
    const key = `${scale.toFixed(4)}|${x.toFixed(1)}|${y.toFixed(1)}|${on.toFixed(3)}|`
      + `${c.live.toFixed(3)}|${c.fade.toFixed(3)}|${c.words.toFixed(3)}|${c.k.toFixed(3)}`;
    if (key === last) return;
    last = key;
    mac.style.transform = `translate3d(${(x - notch.x * scale).toFixed(2)}px, `
      + `${y.toFixed(2)}px, 0) scale(${scale.toFixed(4)})`;
    // The pin is fixed, so the footage is always in the window as far as the
    // page's own observer knows (js/site.js plays it there). Out of the box
    // when none of it shows, it is paused rather than decoded unseen.
    mac.hidden = on * c.fade === 0;
    section.style.setProperty('--on', (on * c.fade).toFixed(3));
    section.style.setProperty('--live', c.live.toFixed(3));
    section.style.setProperty('--edge', c.k.toFixed(3));
    section.style.setProperty('--words', c.words.toFixed(3));
    section.toggleAttribute('data-words', c.words > 0.5);
  }
  const ask = () => { if (!queued) queued = requestAnimationFrame(place); };
  addEventListener('scroll', ask, { passive: true });
  addEventListener('resize', ask, { passive: true });
  // The camera keeps the footage's time: on the footage's own frames where
  // the browser offers them, so a zoom lands on the frame it was read from,
  // and on the page's frames otherwise, while it plays.
  if (film && 'requestVideoFrameCallback' in film) {
    const frame = (now, meta) => {
      t = meta.mediaTime;
      place();
      film.requestVideoFrameCallback(frame);
    };
    film.requestVideoFrameCallback(frame);
  } else if (film) {
    const frame = () => {
      if (!film.paused) {
        t = film.currentTime;
        place();
      }
      requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }
  place();
  return { place };
}
