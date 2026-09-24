// The soundtrack's corner.
//
// The circles are fixed in a corner the page goes by under. Where words, a
// control or the band's printed menu bar stand in that corner, the circles
// give it up, and take it back once it has been clear a moment, so nothing a
// visitor reads or presses is ever under them (css/magnetite.css's
// [data-aside]). What counts is what shows: the film's words only while they
// are up, the download's only once the handover has drawn them. Measured a
// frame after each scroll, after the tunnel has placed it, so the check never
// forces a layout of its own.

const CORNER_WORDS = '.masthead a, .hero__copy > *, .film__title, .film__foot, .get__title, '
  + '.get__sheet > :not(.get__title, .band), .finale__still, .foot > *';
/** What a visitor presses, or copies, measured by its whole box. */
const CONTROLS = 'a, button, code';
/** How near, in CSS pixels, counts as under the circles. */
const CORNER_MARGIN = 8;
/** How long the corner stays clear before the circles come back, in ms. */
const CORNER_SETTLE = 250;

/**
 * @param {HTMLElement} soundtrack  the circles
 * @param {{ journey: boolean, notch: HTMLElement | null }} options  whether the
 *   tunnel runs, and the band's notch, whose foot is the foot of its menu bar
 */
export function startCorner(soundtrack, { journey, notch }) {
  const words = [...document.querySelectorAll(CORNER_WORDS)];
  const bar = document.querySelector('.band');
  const text = document.createRange();
  let asked = false;
  let back = 0;
  const shows = (el) => {
    const film = el.closest('.film[data-tunnel="on"]');
    if (film) {
      return film.hasAttribute(el.matches('.film__title') ? 'data-title' : 'data-words')
        && !film.hasAttribute('data-covered');
    }
    const get = el.closest('.get');
    if (get && journey && !get.hasAttribute('data-drawn')) return false;
    // The name's still hides once the pour draws the same name over it.
    if (el.matches('.finale__still')) return true;
    return el.checkVisibility ? el.checkVisibility({ opacityProperty: true, visibilityProperty: true }) : true;
  };
  const meets = (r, zone) => r.width > 0 && r.right > zone.left && r.left < zone.right
    && r.bottom > zone.top && r.top < zone.bottom;
  /**
   * Whether `el` puts ink in `zone`: a control's whole box, each run of its
   * words, the name's letters. Not a block's box, which is the column's
   * width whatever its lines are.
   */
  const inks = (el, zone) => {
    if (el.matches('.finale__still')) {
      const r = el.getBoundingClientRect();
      const w = Math.min(r.width, (r.height * 1278) / 140);
      const h = (w * 140) / 1278;
      const x = r.left + (r.width - w) / 2;
      const y = r.top + (r.height - h) / 2;
      return meets({ left: x, right: x + w, top: y, bottom: y + h, width: w }, zone);
    }
    const controls = el.matches(CONTROLS) ? [el] : [...el.querySelectorAll(CONTROLS)];
    if (controls.some((c) => meets(c.getBoundingClientRect(), zone))) return true;
    const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    for (let node = walk.nextNode(); node; node = walk.nextNode()) {
      if (!node.data.trim() || controls.some((c) => c.contains(node))) continue;
      text.selectNodeContents(node);
      if (meets(text.getBoundingClientRect(), zone)) return true;
    }
    return false;
  };
  const look = () => {
    asked = false;
    const box = soundtrack.getBoundingClientRect();
    const zone = { left: box.left - CORNER_MARGIN, right: box.right + CORNER_MARGIN,
      top: box.top - CORNER_MARGIN, bottom: box.bottom + CORNER_MARGIN };
    let under = words.some((el) => shows(el) && inks(el, zone));
    // The band's figures are drawn, not set: its menu bar is the strip down to
    // the notch's foot, the width of the window.
    if (!under && bar && notch && shows(bar)) {
      const strip = bar.getBoundingClientRect();
      under = meets({ left: strip.left, right: strip.right, top: strip.top,
        bottom: notch.getBoundingClientRect().bottom, width: strip.width }, zone);
    }
    clearTimeout(back);
    if (under) soundtrack.toggleAttribute('data-aside', true);
    else back = setTimeout(() => soundtrack.removeAttribute('data-aside'), CORNER_SETTLE);
  };
  const ask = () => {
    if (asked) return;
    asked = true;
    requestAnimationFrame(look);
  };
  addEventListener('scroll', ask, { passive: true });
  addEventListener('resize', ask, { passive: true });
  if (document.readyState === 'complete') ask();
  else addEventListener('load', ask);
}
