// The journey, scrolled through.
//
// One camera from the top of the page to the download. The printed laptop in
// the hero stays put as the words scroll away, turns square on and pushes into
// its notch (js/hero.js, `setDive`). Over the last of that push its screen
// comes on: the display, in the footage's own grey with the footage under its
// notch, laid exactly on the printed screen wherever the dive has it, so the
// print lights up while the camera is still moving. The film section pins
// with the notch hanging from the top of the window, as it does from the top
// of a display, and holds. Scrolling on, the page comes back and the footage
// rides down onto the menu bar below, shrinking until its notch is the band's
// notch — the download link — where it hands over to the print.
//
// The footage sits where it was recorded: centred under the notch at the top
// of the screen, 512 points wide. The camera holds at no more than 1.5 times
// that — the footage's 1536 pixels across 768 CSS pixels, one to one on a
// Retina display — so the type in it is never resampled larger than it was
// shot.
//
// Reduce Motion gets none of this: no pin, no camera, the footage as it was.

const FILM = { width: 512, height: 240 };
/** The display the footage was recorded on, in points; the print's is the same. */
const SCREEN = { width: 1512, height: 982 };
/** The notch's width in display points: the unit every scale here is in. */
const NOTCH_WIDTH = 185;
/** 1536 recorded pixels over 768 CSS pixels at 2x: the most the footage takes. */
const SHARPEST = 1.5;
/** The last share of the dive, over which the screen comes on. */
const ON = 0.25;
/** The film's own region of the scroll: the desktop filling the window by FADE, then held. */
const FADE = 0.12;
/**
 * The pull runs on the band's notch, not on the film's scroll. It begins as
 * that notch comes within FROM window-heights of the top, still below the
 * window, and the footage has landed on it, and let it go, by the time it has
 * risen to LAND: the download is in the clear for the rest of its way up.
 */
const FROM = 1.5;
const LAND = 0.72;

const unit = (x) => Math.max(0, Math.min(1, x));
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);

/**
 * Where the footage holds, for a viewport of `vw` x `vh`: the notch's top edge
 * at (x, y), hanging from the top of the window, and the CSS pixels a display
 * point takes. Pure, so the dive and the tunnel agree on one number and a
 * check can hold them to it.
 */
export function hold(vw, vh) {
  const scale = Math.min(SHARPEST, (vw - 32) / FILM.width, (vh * 0.56) / FILM.height);
  return { x: vw / 2, y: 0, scale };
}

/**
 * Where the camera is at the film's scroll progress `p` (0-1), once the dive
 * is done: the footage's notch and scale, how much of the window the desktop
 * fills, and how much of the footage is left. `dock` is the band's notch,
 * {x, y, scale}, wherever it is on screen now.
 */
export function camera(p, vw, vh, dock) {
  const at = hold(vw, vh);
  const k = dock ? ease(unit((FROM * vh - dock.y) / ((FROM - LAND) * vh))) : 0;
  const lerp = (a, b) => a + (b - a) * k;
  return {
    x: dock ? lerp(at.x, dock.x) : at.x,
    y: dock ? lerp(at.y, dock.y) : at.y,
    // In log space, so the pull reads as one steady move.
    scale: dock ? at.scale * (dock.scale / at.scale) ** k : at.scale,
    // The desktop past the display's edges, filling the window, and letting
    // the page back as the pull goes.
    dark: unit(p / FADE) * (1 - k),
    // The footage hands over to the print in the last of the pull.
    fade: unit((1 - k) / 0.2),
    words: unit((p - FADE) / 0.1) * (1 - unit(k / 0.2)),
    k,
  };
}

export function startTunnel(section, { reduceMotion = false, hero = null, dock = null } = {}) {
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
    const c = camera(p, vw, vh, band);
    const at = hold(vw, vh);
    // The print is only worth drawing until the desktop has covered it, and
    // it must not come back behind the page as the pull lets the desktop go.
    hero?.setDive(dive, at, scrollY, dive >= 1 && p >= FADE);
    // Until the pin, the display is laid on the print's own screen, wherever
    // the dive has it; from the pin on, it is the camera's.
    const on = unit((dive - (1 - ON)) / ON);
    const laid = dive < 1 ? hero?.notchAt() : null;
    const { x, y, scale } = laid || c;
    // The display's own grey stands in for the desktop until that fills the
    // window; after, the two would double, and the pull would show a box.
    const solid = c.dark < 1 && c.k === 0 ? 1 : 0;

    // Every value written below, or a fade that moves while the camera holds
    // still (the words coming up in the hold) is skipped and stays where it was.
    const key = `${scale.toFixed(4)}|${x.toFixed(1)}|${y.toFixed(1)}|${on.toFixed(3)}|${solid}|`
      + `${c.dark.toFixed(3)}|${c.fade.toFixed(3)}|${c.words.toFixed(3)}|${c.k.toFixed(3)}|${at.scale}`;
    if (key === last) return;
    last = key;
    mac.style.transform = `translate3d(${(x - notch.x * scale).toFixed(2)}px, `
      + `${y.toFixed(2)}px, 0) scale(${scale.toFixed(4)})`;
    // The pin is fixed, so the footage is always in the window as far as the
    // page's own observer knows (js/site.js plays it there). Out of the box
    // when none of it shows, it is paused rather than decoded unseen.
    mac.hidden = on * c.fade === 0;
    section.style.setProperty('--on', (on * c.fade).toFixed(3));
    section.style.setProperty('--solid', String(solid));
    section.style.setProperty('--dark', c.dark.toFixed(3));
    section.style.setProperty('--edge', c.k.toFixed(3));
    section.style.setProperty('--words', c.words.toFixed(3));
    section.style.setProperty('--under', `${(FILM.height * at.scale).toFixed(1)}px`);
    section.toggleAttribute('data-words', c.words > 0.5);
  }
  const ask = () => { if (!queued) queued = requestAnimationFrame(place); };
  addEventListener('scroll', ask, { passive: true });
  addEventListener('resize', ask, { passive: true });
  place();
  return { place };
}
