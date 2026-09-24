/**
 * The last thing on the page: the name, poured, in a field of iron filings.
 *
 * Its own small loop rather than a view on site.js's, because nothing here is
 * the app's physics: no captured audio replays through it, it keeps no fixed
 * step, and it sleeps whenever nothing on it is moving — which is most of the
 * time. It runs while the section is on screen and something is settling: the
 * pour, a drop coming home, filings swinging, a soundtrack playing.
 *
 * Under Reduce Motion there is no loop and no magnet: the name is drawn once,
 * whole, with the filings already lying along its field.
 */
import { LiquidName } from './liquid.js';
import { Filings } from './filings.js';

/** Past this share of the section on screen, the pour begins. */
const POUR_AT = 0.35;

export function startFinale(section, { reduceMotion, bands }) {
  const nameCanvas = section.querySelector('[data-finale-name]');
  const filingsCanvas = section.querySelector('[data-finale-filings]');
  let name;
  try {
    name = new LiquidName(nameCanvas, { reduceMotion });
  } catch {
    // No WebGL2: the traced wordmark in the markup stays, and the filings,
    // which would frame a word that is not being drawn, stay away.
    section.dataset.pour = 'none';
    return null;
  }
  const filings = new Filings(filingsCanvas, name, { reduceMotion });
  section.dataset.pour = 'ready';

  let onScreen = false;
  let running = false;
  let queued = 0;
  let last = 0;

  const draw = () => { name.render(); filings.render(); };

  function frame(now) {
    if (!running) return;
    const dt = Math.min(1 / 30, Math.max(0, (now - last) / 1000));
    last = now;
    name.listen(bands());
    // Substepped, so the springs integrate the same on a 120Hz panel as on a
    // 60Hz one and stay stable on a slow frame.
    for (let t = 0; t < dt - 1e-9; t += 1 / 120) {
      const h = Math.min(1 / 120, dt - t);
      name.step(h);
      filings.step(h);
    }
    draw();
    if (name.settled && filings.settled) { running = false; return; }
    queued = requestAnimationFrame(frame);
  }

  function wake() {
    if (running || reduceMotion || !onScreen || document.hidden) return;
    running = true;
    last = performance.now();
    queued = requestAnimationFrame(frame);
  }

  function sleep() {
    running = false;
    cancelAnimationFrame(queued);
  }

  if (reduceMotion) {
    draw();
  } else {
    const seen = new IntersectionObserver(([entry]) => {
      onScreen = entry.isIntersecting;
      if (entry.intersectionRatio >= POUR_AT) name.begin();
      if (onScreen) wake(); else sleep();
    }, { threshold: [0, POUR_AT] });
    seen.observe(section);

    // The pointer is the magnet: a mouse wherever it moves over the section,
    // a finger where it touches down, and gone when either leaves.
    const at = (event) => {
      const box = section.getBoundingClientRect();
      const x = event.clientX - box.left, y = event.clientY - box.top;
      name.point(x, y, true);
      filings.point(x, y, true);
      wake();
    };
    const away = () => {
      name.point(0, 0, false);
      filings.point(0, 0, false);
      wake();
    };
    section.addEventListener('pointermove', (event) => {
      if (event.pointerType === 'mouse' || event.buttons) at(event);
    }, { passive: true });
    section.addEventListener('pointerdown', at, { passive: true });
    section.addEventListener('pointerleave', away, { passive: true });
    section.addEventListener('pointerup', (event) => {
      if (event.pointerType !== 'mouse') away();
    }, { passive: true });
    section.addEventListener('pointercancel', away, { passive: true });
    document.addEventListener('visibilitychange', () => (document.hidden ? sleep() : wake()));
  }

  // A new box refits both, and a still is redrawn at once rather than waiting
  // for a loop that may be asleep.
  new ResizeObserver(() => {
    name.resize();
    filings.resize();
    draw();
    wake();
  }).observe(section);

  // The soundtrack is the one thing that can start motion from outside.
  return { wake };
}
