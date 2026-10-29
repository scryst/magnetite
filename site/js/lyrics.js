// The lyrics, printed: a port of LyricsStage in Sources/NotchApp/UI/NotchView.swift.
//
// The same rules as the app. The sung line sits bright at the stage's top edge
// with the next one dim beneath; when the song reaches a line the column rolls
// up, each line a beat (45 ms) behind the one above, critically damped so it
// never springs; the line that was sung blurs out through the top fade; an
// instrumental break is three dots that light in turn as a count-in. The words
// are "Daisy Bell" (Harry Dacre, 1892, public domain), timed to its waltz.

/** Seconds into the loop each line is reached. `null` text is a break. */
export const LINES = [
  { t: 0, text: null },
  { t: 2.4, text: 'Daisy, Daisy, give me your answer, do!' },
  { t: 5.4, text: 'I’m half crazy, all for the love of you!' },
  { t: 8.4, text: 'It won’t be a stylish marriage,' },
  { t: 10.6, text: 'I can’t afford a carriage,' },
  { t: 12.8, text: 'But you’ll look sweet upon the seat' },
  { t: 15.4, text: 'Of a bicycle built for two!' },
  { t: 18.6, text: null },
];
export const LENGTH = 21.6;
/** The song's own length on the clocks, so they read like a real track. */
const SHOWN_LENGTH = 21.6;

/** The line up at `pos`, as `LyricsStage` picks it. */
export function indexAt(pos) {
  let i = 0;
  while (i + 1 < LINES.length && LINES[i + 1].t <= pos) i++;
  return i;
}

/** How far through a break `pos` is, 0 to 1. */
export function breakProgress(pos, i) {
  const end = i + 1 < LINES.length ? LINES[i + 1].t : LENGTH;
  return Math.min(Math.max((pos - LINES[i].t) / (end - LINES[i].t), 0), 1);
}

/** Opacity by distance from the sung line, from `LyricsColumn.row`. */
export function opacityFor(d, playing) {
  if (d === 0) return playing ? 1 : 0.62;
  return d === 1 ? 0.3 : d === 2 ? 0.12 : 0;
}

const clock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

export function startLyrics(root, { reduceMotion }) {
  const column = root.querySelector('[data-lyrics-column]');
  const toggle = root.querySelector('[data-lyrics-toggle]');
  const label = root.querySelector('[data-lyrics-toggle-label]');
  const elapsed = root.querySelector('[data-lyrics-elapsed]');
  const left = root.querySelector('[data-lyrics-left]');
  const trace = root.querySelector('[data-lyrics-trace]');
  if (!column) return null;

  const rows = LINES.map((line) => {
    const li = document.createElement('li');
    if (line.text) li.textContent = line.text;
    else {
      li.className = 'lyrics__break';
      for (let k = 0; k < 3; k++) li.append(document.createElement('i'));
    }
    column.append(li);
    return li;
  });

  let pos = LINES[1].t + 0.6;
  let playing = !reduceMotion;
  let visible = false;
  let current = -1;
  let last = 0;
  let frame = 0;

  function paint(force) {
    const i = indexAt(pos);
    if (i !== current || force) {
      current = i;
      // States first: only the sung line may wrap, so the column's measure
      // depends on which line it is.
      rows.forEach((row, n) => {
        const d = n - i;
        row.dataset.state = d < 0 ? 'past' : d === 0 ? 'sung' : d === 1 ? 'next' : 'later';
      });
      const shift = rows[0].offsetTop - rows[i].offsetTop;
      rows.forEach((row, n) => {
        const d = n - i;
        row.style.transitionDelay = `${Math.min(Math.max(d + 1, 0), 4) * 45}ms`;
        row.style.transform = `translateY(${shift}px) scale(${d === 0 ? 1 : 0.94})`;
        row.style.opacity = opacityFor(d, playing);
      });
      root.querySelector('[data-lyrics-now]').textContent = LINES[i].text ?? '';
    }
    const lit = LINES[i].text ? 0 : breakProgress(pos, i);
    rows[i].querySelectorAll('i').forEach((dot, k) => {
      const f = Math.min(Math.max(lit * 3 - k, 0), 1);
      dot.style.opacity = 0.28 + 0.72 * f;
      dot.style.transform = `scale(${0.8 + 0.2 * f})`;
    });
    elapsed.textContent = clock(pos);
    left.textContent = `-${clock(SHOWN_LENGTH - pos)}`;
    trace.style.transform = `scaleX(${pos / LENGTH})`;
  }

  function tick(now) {
    frame = 0;
    if (!playing || !visible) return;
    pos = (pos + Math.min((now - last) / 1000, 0.1)) % LENGTH;
    last = now;
    paint(false);
    frame = requestAnimationFrame(tick);
  }

  function run() {
    if (frame || !playing || !visible || document.hidden) return;
    last = performance.now();
    frame = requestAnimationFrame(tick);
  }

  function setPlaying(next) {
    playing = next;
    root.dataset.playing = String(playing);
    toggle?.setAttribute('aria-pressed', String(!playing));
    if (label) label.textContent = playing ? 'Pause lyrics' : 'Play lyrics';
    paint(true);
    run();
  }

  toggle?.addEventListener('click', () => setPlaying(!playing));
  document.addEventListener('visibilitychange', run);
  // The plates come into register once, the first time the print is seen.
  new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting;
    if (visible) root.dataset.inked = 'true';
    run();
  }, { threshold: 0.25 }).observe(root);
  // Lines wrap differently at each width, so the column re-measures.
  addEventListener('resize', () => paint(true), { passive: true });

  setPlaying(playing);
  return { setPlaying };
}
