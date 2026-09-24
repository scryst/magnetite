// The journey, scrolled through.
//
// One camera from the top of the page to the download. The printed laptop in
// the hero stays put as the words scroll away, turns square on and pushes into
// its notch until the notch is the size of the one in the footage (js/hero.js,
// `setDive`). The film section then pins: the footage fades in over the
// printed notch at exactly its size and place, the page goes dark round it,
// and it holds. Scrolling on, the page comes back and the footage rides down
// onto the menu bar below, shrinking until its notch is the band's notch —
// the download link — where it hands over to the print.
//
// The footage sits where it was recorded: centred under the notch at the top
// of the screen, 512 points wide. The camera holds at no more than 1.5 times
// that — the footage's 1536 pixels across 768 CSS pixels, one to one on a
// Retina display — so the type in it is never resampled larger than it was
// shot.
//
// Reduce Motion gets none of this: no pin, no camera, the footage as it was.

const FILM = { width: 512, height: 240 };
/** The notch's width in display points: the unit every scale here is in. */
const NOTCH_WIDTH = 185;
/** 1536 recorded pixels over 768 CSS pixels at 2x: the most the footage takes. */
const SHARPEST = 1.5;
/** The film's own region of the scroll: faded in by FADE, held, docked from PULL. */
const FADE = 0.12;
const PULL = 0.6;

const unit = (x) => Math.max(0, Math.min(1, x));
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);

/**
 * Where the footage holds, for a viewport of `vw` x `vh`: the notch's top edge
 * at (x, y) and the CSS pixels a display point takes. Pure, so the dive and
 * the tunnel agree on one number and a check can hold them to it.
 */
export function hold(vw, vh) {
  const scale = Math.min(SHARPEST, (vw - 32) / FILM.width, (vh * 0.56) / FILM.height);
  return { x: vw / 2, y: (vh - FILM.height * scale) / 2 - vh * 0.04, scale };
}

/**
 * Where the camera is at the film's scroll progress `p` (0-1): the footage's
 * notch and scale, how dark the page is, and how far the footage has faded in.
 * `dock` is the band's notch, {x, y, scale}, wherever it is on screen now.
 */
export function camera(p, vw, vh, dock) {
  const at = hold(vw, vh);
  const k = dock ? ease(unit((p - PULL) / (1 - PULL))) : 0;
  const shown = unit(p / FADE);
  const lerp = (a, b) => a + (b - a) * k;
  return {
    x: dock ? lerp(at.x, dock.x) : at.x,
    y: dock ? lerp(at.y, dock.y) : at.y,
    // In log space, so the pull reads as one steady move.
    scale: dock ? at.scale * (dock.scale / at.scale) ** k : at.scale,
    dark: shown * (1 - k),
    // The footage hands over to the print in the last of the pull.
    film: shown * (1 - unit((k - 0.86) / 0.14)),
    words: unit((p - FADE) / 0.1) * (1 - unit((p - PULL) / 0.08)),
    k,
  };
}

export function startTunnel(section, { reduceMotion = false, hero = null, dock = null } = {}) {
  const mac = section && section.querySelector('[data-tunnel-mac]');
  const pin = section && section.querySelector('.film__pin');
  if (!mac || !pin || reduceMotion) return null;
  section.dataset.tunnel = 'on';
  document.documentElement.dataset.journey = 'on';
  // The notch's top edge, in the footage's own points: centred, at the top.
  const notch = { x: FILM.width / 2, y: 0 };
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
    // The print is only worth drawing until the footage has covered it, and
    // it must not come back behind the page as the pull lets the dark go.
    hero?.setDive(dive, hold(vw, vh), scrollY, dive >= 1 && p >= FADE);

    const key = `${dive.toFixed(4)}|${c.scale.toFixed(4)}|${c.x.toFixed(1)}|${c.y.toFixed(1)}|${c.film.toFixed(3)}`;
    if (key === last) return;
    last = key;
    mac.style.transform = `translate3d(${(c.x - notch.x * c.scale).toFixed(2)}px, `
      + `${c.y.toFixed(2)}px, 0) scale(${c.scale.toFixed(4)})`;
    section.style.setProperty('--dark', c.dark.toFixed(3));
    section.style.setProperty('--film', c.film.toFixed(3));
    section.style.setProperty('--cx', `${c.x.toFixed(1)}px`);
    section.style.setProperty('--cy', `${(c.y + (FILM.height * c.scale) / 2).toFixed(1)}px`);
    section.style.setProperty('--rx', `${(FILM.width * c.scale * 0.8).toFixed(1)}px`);
    section.style.setProperty('--ry', `${(FILM.height * c.scale * 1.25).toFixed(1)}px`);
    section.style.setProperty('--words', c.words.toFixed(3));
    section.toggleAttribute('data-words', c.words > 0.5);
  }
  const ask = () => { if (!queued) queued = requestAnimationFrame(place); };
  addEventListener('scroll', ask, { passive: true });
  addEventListener('resize', ask, { passive: true });
  place();
  return { place };
}
