// The journey, scrolled through.
//
// One camera from the top of the page to the download. The printed laptop in
// the hero stays put as its words fade away, turns square on and pushes in
// until its screen is the window (js/hero.js, `setDive`). Over the last of
// that push its screen comes on: the recorded desktop, laid exactly on the
// printed screen wherever the dive has it, lit through a halftone of the
// print's own pitch whose dots swell until they close, so the print turns
// into the screen. The film section pins with the desktop filling the window,
// the notch hanging from its top, and from there the camera follows the
// footage rather than the scroll: in on the player as the pointer rises to
// it, held there through every gesture, back out to the whole desktop as the
// player goes into the notch. Scrolling on, the words go, the player goes back
// into the notch, and the camera carries the desktop's notch in and down onto
// the band's — the download link — at the window's centre. The download is
// drawn up under the desktop the whole way, its notch wherever the camera has
// the desktop's, so above the desktop's top edge is the band's bezel and the
// heading over it. As it lands, the desktop goes back to print the way it
// came, through the halftone, its dots shrinking evenly until they are gone,
// so the recorded menu bar becomes the printed one in place and the idle
// notch becomes the link.
//
// The desktop is a still of the take's own first frame and the footage covers
// only the part of it that moves: the player under the notch and the
// pointer's whole way to it, where the take recorded them. The footage has
// two pixels a point, and the camera draws a point at no more than 1.8 CSS
// pixels: close enough to be a push in, and on a Retina display the type in
// it is drawn at most 1.8 times as large as it was shot, which stays crisp.
//
// Scroll here is counted in window heights past the pin, so the settle and
// the words take the same scroll on every window, however tall the film is.
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
 * The player as the close shot frames it, in points: its panel, 372 wide
 * about the notch, and the fingers drawn under it down to the lowest a swipe
 * carries them. It keeps 16px clear of the window's sides and stays above
 * WORDS, the CSS pixels the film's words take at the window's foot.
 */
export const PLAYER = { width: 372, height: 290 };
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
const ON = 0.3;
/** Window heights of scroll over which the camera settles from the dive onto the footage's shot. */
const SETTLE = 0.3;
/** Where the title and then the how-to begin to come up, each over RISE window heights. */
const TITLE = 0.12;
const HOW = 0.24;
const RISE = 0.3;
/**
 * The handover, in window heights before the download's top reaches the
 * window's: over its first WORDS_OUT the words go and over RETRACT the player
 * goes back into the notch; from MOVE[0] the camera carries the notch in and
 * down onto the band's, at the window's centre, landing at MOVE[1]; and from
 * OFF to the end the desktop goes back to print. The camera sets off as the
 * words start to go, so no frame of it holds the empty desktop. Until it is
 * drawn, LEAVE before the end, the download stands unseen and out of reach
 * of the clicks the film lets through (css/magnetite.css).
 */
const LEAVE = 1;
const WORDS_OUT = 0.25;
const RETRACT = 0.48;
const MOVE = [0, 0.5];
/**
 * Where the desktop starts going back to print: just before the camera lands,
 * where it is within a couple of percent of the band's notch, so no frame of
 * the camera's slowing holds still.
 */
const OFF = 0.42;
/**
 * How far out from the notch's top edge, in the desktop's points, the
 * halftone's edge travels. Coming on over the print's small screen, the solid
 * bloom that lights it reaches the whole desktop: a bottom corner. Going off,
 * full size across the window, the dots go from the notch out to the
 * window's farthest corner below the desktop's edge (reach(), below), so the
 * link clears first and the corners last.
 */
const REACH = Math.hypot(SCREEN.width / 2, SCREEN.height);
/** A dot's radius at --on 1, in pitches of the halftone (css/magnetite.css's --r). */
export const DOT = 0.75;

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
 * Where the camera is `s` window heights past the pin, with the footage `t`
 * seconds in: the notch's top edge and scale, how much of the player is out
 * of the notch, how far up the title and the how-to are, and how much of the
 * desktop is still lit (`on`, 0 gone back to print). `dock` is the band's
 * notch, {x, y, scale}, where it stands when the download is at the window's
 * top, and `end` is where that is, in the same window heights as `s`. From
 * there on the desktop is `covered`: the page has the download in hand.
 */
export function camera(s, vw, vh, dock, t = 0, end = Infinity) {
  const at = hold(vw, vh);
  const { wide, close } = shots(vw, vh);
  // In log space, so a zoom reads as one steady move. The footage's own shot
  // comes in over the film's first scroll, from where the dive left it.
  const film = wide * (close / wide) ** focus(t);
  const held = wide * (film / wide) ** ease(unit(s / SETTLE));
  const leave = s - (end - LEAVE);
  const k = dock ? ease(unit((leave - MOVE[0]) / (MOVE[1] - MOVE[0]))) : 0;
  const out = 1 - ease(unit(leave / WORDS_OUT));
  return {
    x: dock ? at.x + (dock.x - at.x) * k : at.x,
    y: dock ? at.y + (dock.y - at.y) * k : at.y,
    scale: dock ? held * (dock.scale / held) ** k : held,
    live: 1 - ease(unit(leave / RETRACT)),
    words: ease(unit((s - TITLE) / RISE)) * out,
    how: ease(unit((s - HOW) / RISE)) * out,
    // Taken away evenly in what the dots show, not in their radius, while
    // their edge goes out from the notch (`gone`, css/magnetite.css).
    on: showing(1 - unit((leave - OFF) / (LEAVE - OFF))),
    gone: unit((leave - OFF) / (LEAVE - OFF)),
    covered: s >= end,
  };
}

/**
 * The download's sheet, `s` window heights past the pin: drawn from a window
 * before `end`, where the page lets it go, and held (css/magnetite.css's
 * --held, CSS pixels down from the window's top) so that its notch, `dockY`
 * below its top, stands wherever the camera has the desktop's, `y`. The page
 * holds it there, stuck to the window, so a scroll no script has heard of
 * yet cannot move it off the desktop.
 */
export function sheet(s, end, y, dockY) {
  return { drawn: s >= end - LEAVE, held: y - dockY };
}

/**
 * How far down the dots go out from the notch as the desktop goes off, in the
 * desktop's points, going twice as far across: to the window's farthest
 * corner below the desktop's edge, with the notch's top edge at (x, y) CSS
 * pixels and the desktop at `scale`.
 */
export function reach(x, y, scale, vw, vh) {
  return Math.hypot(Math.max(x, vw - x) / 2, Math.max(0, vh - y)) / scale;
}

/** The screen coming on: 0 dark, 1 lit, over the last ON of the dive. */
export function lit(dive) {
  return unit((dive - (1 - ON)) / ON);
}

/**
 * How much of the desktop the halftone shows with its dots `r` pitches
 * across: each a circle clipped to its own square of the grid, so past half
 * a pitch it loses the four caps outside the square, and whole at a root half.
 */
export function shown(r) {
  if (r >= Math.SQRT1_2) return 1;
  const cap = r > 0.5 ? r * r * Math.acos(0.5 / r) - 0.5 * Math.sqrt(r * r - 0.25) : 0;
  return Math.PI * r * r - 4 * cap;
}

/**
 * The --on at which the halftone shows `share` of the desktop. Going off by
 * radius, the dots stay all but closed for the first tenth and leave a haze
 * that lingers at the end; by share, each stretch of scroll takes as much.
 */
function showing(share) {
  if (share >= 1) return 1;
  if (share <= 0) return 0;
  let [lo, hi] = [0, 1];
  for (let i = 0; i < 30; i++) {
    const mid = (lo + hi) / 2;
    if (shown(DOT * mid * mid) < share) lo = mid;
    else hi = mid;
  }
  return hi;
}

export function startTunnel(section, { reduceMotion = false, hero = null, dock = null, film = null } = {}) {
  const mac = section && section.querySelector('[data-tunnel-mac]');
  const pin = section && section.querySelector('.film__pin');
  if (!mac || !pin || reduceMotion) return null;
  section.dataset.tunnel = 'on';
  const root = document.documentElement;
  root.dataset.journey = 'on';
  const get = dock && dock.closest('.get');
  const leaf = get && get.querySelector('.get__sheet');
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
    const s = Math.max(0, -box.top) / vh;
    // The band's notch where it stands with the download at the window's top,
    // and where in the scroll the page brings it there, its sheet at the foot
    // of its runway: both the same wherever the sheet is held now.
    const page = leaf && leaf.getBoundingClientRect();
    const link = dock && dock.getBoundingClientRect();
    const at = page && link.width
      ? { x: link.left + link.width / 2, y: link.top - page.top, scale: link.width / NOTCH_WIDTH }
      : null;
    const end = page ? (get.getBoundingClientRect().bottom - page.height - box.top) / vh : Infinity;
    const c = camera(s, vw, vh, at, t, end);
    const { drawn, held } = sheet(s, end, c.y, at ? at.y : 0);
    // The print is only worth drawing until the desktop has covered it.
    hero?.setDive(dive, hold(vw, vh), scrollY, dive >= 1 && s >= SETTLE);
    // Until the pin, the desktop is laid on the print's own screen, wherever
    // the dive has it; from the pin on, it is the camera's.
    const on = Math.min(lit(dive), c.on);
    const laid = dive < 1 ? hero?.notchAt() : null;
    const { x, y, scale } = laid || c;
    // The halftone the screen comes on and goes off through: the print's own
    // pitch on the page, so a tile of it is that many CSS pixels over the
    // desktop's scale.
    const pitch = Math.max(3.6, Math.min(5.2, vw / 300)) / scale;
    const far = dive < 1 ? REACH : reach(x, y, scale, vw, vh);

    // Every value written below, or a fade that moves while the camera holds
    // still (the words coming up in the hold) is skipped and stays where it was.
    const key = `${scale.toFixed(4)}|${x.toFixed(1)}|${y.toFixed(1)}|${on.toFixed(3)}|${pitch.toFixed(2)}|`
      + `${far.toFixed(0)}|${held.toFixed(1)}|${drawn}|${c.covered}|${c.live.toFixed(3)}|${c.words.toFixed(3)}|`
      + `${c.how.toFixed(3)}|${c.gone.toFixed(3)}|${dive.toFixed(3)}`;
    if (key === last) return;
    last = key;
    mac.style.transform = `translate3d(${(x - notch.x * scale).toFixed(2)}px, `
      + `${y.toFixed(2)}px, 0) scale(${scale.toFixed(4)})`;
    // Drawn a window before the page has it, under the lit desktop, and held
    // there by the page itself until the runway's foot lets it go.
    if (get) {
      get.toggleAttribute('data-drawn', drawn);
      get.style.setProperty('--held', `${held.toFixed(1)}px`);
      get.style.setProperty('--gone', c.gone.toFixed(3));
    }
    // The pin is fixed, so the footage is always in the window as far as the
    // page's own observer knows (js/site.js plays it there). Out of the box
    // when none of it shows, it is paused rather than decoded unseen.
    mac.hidden = on === 0 || c.covered;
    mac.toggleAttribute('data-dots', on < 1);
    // Past the pin the dots only ever go, and go from the notch out.
    mac.toggleAttribute('data-going', dive >= 1);
    section.style.setProperty('--on', on.toFixed(3));
    section.style.setProperty('--gone', c.gone.toFixed(3));
    section.style.setProperty('--dot', `${pitch.toFixed(2)}px`);
    section.style.setProperty('--reach', `${far.toFixed(0)}px`);
    section.style.setProperty('--live', c.live.toFixed(3));
    section.style.setProperty('--words', c.words.toFixed(3));
    section.style.setProperty('--how', c.how.toFixed(3));
    section.toggleAttribute('data-words', c.how > 0.5 && !c.covered);
    section.toggleAttribute('data-retract', c.live < 1);
    section.toggleAttribute('data-covered', c.covered);
    root.style.setProperty('--dive', dive.toFixed(3));
    root.toggleAttribute('data-dived', dive > 0.2);
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
