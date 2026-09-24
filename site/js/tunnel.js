// The film, scrolled into.
//
// The section pins for a while and the scroll drives a camera: it starts on
// the whole display, pushes in until the footage under the notch fills the
// frame, holds there with the rest of the page gone dark around it, and pulls
// back out to the display before the section lets go. Everything moved is one
// transform on one element and a few numbers for the stylesheet, so a scroll
// frame is a composite and a gradient, not a layout.
//
// The display is drawn at its true size in points — a 14-inch MacBook Pro's
// 1512 x 982 — and the footage sits where it was recorded: centred under the
// notch at the top of the screen, 512 points wide, which is the size that
// puts the recorded panel at the app's own 372. The camera stops at 1.5
// times that: the footage's 1536 pixels across 768 CSS pixels, one to one on
// a Retina display, so the type in it is never resampled larger than it was
// shot.
//
// Reduce Motion gets none of this: no pin, no camera, the footage as it was.

const SCREEN = { width: 1512, height: 982 };
const FILM = { width: 512, height: 240 };
/** 1536 recorded pixels over 768 CSS pixels at 2x: the most the footage takes. */
const SHARPEST = 1.5;
/** The bezel and the base, in points, as the stylesheet draws them. */
const BEZEL = 16;
const BASE = 22;
/** The film's own region of the scroll: in, held, out. */
const PUSH = 0.4;
const PULL = 0.8;

const unit = (x) => Math.max(0, Math.min(1, x));
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);

/**
 * Where the camera is at scroll progress `p` (0-1), for a viewport of `vw` x
 * `vh`: the scale, the notch's position on screen, and how far the page has
 * gone dark. Pure, so the three phases can be checked without a browser.
 */
export function camera(p, vw, vh) {
  const outer = { width: SCREEN.width + 2 * BEZEL, height: SCREEN.height + 2 * BEZEL + BASE };
  // The whole machine, below the title.
  const wide = Math.min((vw * 0.84) / outer.width, (vh * 0.56) / outer.height);
  // The footage alone, never past its own pixels, with room round it for the words.
  const close = Math.min(SHARPEST, (vw - 32) / FILM.width, (vh * 0.62) / FILM.height);
  const k = ease(unit(p / PUSH)) * (1 - ease(unit((p - PULL) / (1 - PULL))));
  const scale = wide + (close - wide) * k;
  // Centred a little low, under the title, and never up into it.
  const wideTop = Math.max(vh * 0.3, (vh - outer.height * wide) / 2 + vh * 0.06) + BEZEL * wide;
  const closeTop = (vh - FILM.height * close) / 2 - vh * 0.06;
  return { scale, x: vw / 2, y: wideTop + (closeTop - wideTop) * k, dark: k };
}

export function startTunnel(section, { reduceMotion = false } = {}) {
  const mac = section && section.querySelector('[data-tunnel-mac]');
  const pin = section && section.querySelector('.film__pin');
  if (!mac || !pin || reduceMotion) return null;
  section.dataset.tunnel = 'on';
  mac.style.transformOrigin = `${SCREEN.width / 2 + BEZEL}px ${BEZEL}px`;

  let queued = 0;
  let last = '';
  function place() {
    queued = 0;
    const box = section.getBoundingClientRect();
    const vw = pin.clientWidth;
    const vh = pin.clientHeight;
    const run = box.height - vh;
    const p = run > 0 ? unit(-box.top / run) : 0;
    const { scale, x, y, dark } = camera(p, vw, vh);
    const key = `${scale.toFixed(4)}|${x.toFixed(1)}|${y.toFixed(1)}`;
    if (key === last) return;
    last = key;
    // Translate so the notch lands at (x, y), then scale about the notch.
    mac.style.transform = `translate3d(${(x - SCREEN.width / 2 - BEZEL).toFixed(2)}px, `
      + `${(y - BEZEL).toFixed(2)}px, 0) scale(${scale.toFixed(4)})`;
    // The dark closes on the footage wherever it is on its way in: an ellipse
    // round its current box, so the edges of the frame go first.
    const words = unit((dark - 0.8) / 0.2);
    section.style.setProperty('--dark', dark.toFixed(3));
    section.style.setProperty('--cx', `${x.toFixed(1)}px`);
    section.style.setProperty('--cy', `${(y + (FILM.height * scale) / 2).toFixed(1)}px`);
    section.style.setProperty('--rx', `${(FILM.width * scale * 0.8).toFixed(1)}px`);
    section.style.setProperty('--ry', `${(FILM.height * scale * 1.25).toFixed(1)}px`);
    section.style.setProperty('--title', unit(1 - p / 0.16).toFixed(3));
    section.style.setProperty('--words', words.toFixed(3));
    section.toggleAttribute('data-words', words > 0.5);
  }
  const ask = () => { if (!queued) queued = requestAnimationFrame(place); };
  addEventListener('scroll', ask, { passive: true });
  addEventListener('resize', ask, { passive: true });
  place();
  return { place };
}
