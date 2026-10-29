// The notch at the top of the window, which works the way the app does.
//
// Hover it (or tap it, or press it from the keyboard) and the player pours
// out of it: the soundtrack, and under it the page's sections as a lyric
// column, rolled so the section in view is the line being sung — the same
// rule as LyricsStage (js/lyrics.js). Its foot is the page's playhead: drag
// along it to seek through the page, as you scrub the app's notch to seek a
// track. A sideways two-finger swipe on it skips to the next or previous
// section, as it skips a track. Opening, its two colour plates swing in from
// well out of register and land a hair off the black (css/magnetite.css).

/** How long the pointer may be away before the player goes back in, in ms. */
const LINGER = 320;
/** Sideways wheel travel, in CSS pixels, that counts as one swipe. */
const SWIPE = 60;
/** A swipe's cooldown, so one gesture's momentum skips one section. */
const SWIPE_REST = 700;
/** Where on the window a section counts as the one being read. */
const READ_LINE = 0.4;

const clock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

/**
 * @param {HTMLElement} root  the `[data-notch]` element
 * @param {{ reduceMotion: boolean, audio: HTMLAudioElement | null }} options
 */
export function startNotch(root, { reduceMotion, audio }) {
  const pill = root.querySelector('[data-notch-pill]');
  const player = root.querySelector('[data-player]');
  const edge = root.querySelector('[data-notch-edge]');
  const trace = root.querySelector('[data-notch-trace]');
  const column = root.querySelector('[data-notch-column]');
  const elapsed = root.querySelector('[data-notch-elapsed]');
  const left = root.querySelector('[data-notch-left]');
  const rows = [...column.children];
  const targets = rows.map((row) => document.querySelector(row.querySelector('a').hash));

  // ── Open and close ──────────────────────────────────────────────────────
  let open = false;
  let linger = 0;
  function setOpen(next) {
    clearTimeout(linger);
    if (next === open) return;
    open = next;
    if (open) root.style.setProperty('--open-h', `${player.scrollHeight}px`);
    root.dataset.open = String(open);
    pill.setAttribute('aria-expanded', String(open));
    player.inert = !open;
    if (open) paint(true);
  }
  player.inert = true;
  pill.addEventListener('click', () => setOpen(!open));
  root.addEventListener('pointerenter', (event) => {
    if (event.pointerType === 'mouse') setOpen(true);
  });
  root.addEventListener('pointerleave', (event) => {
    if (event.pointerType !== 'mouse' || scrubbing) return;
    linger = setTimeout(() => setOpen(false), LINGER);
  });
  root.addEventListener('focusout', (event) => {
    if (!root.contains(event.relatedTarget)) setOpen(false);
  });
  addEventListener('keydown', (event) => {
    if (event.key !== 'Escape' || !open) return;
    setOpen(false);
    pill.focus();
  });
  addEventListener('pointerdown', (event) => {
    if (open && !root.contains(event.target)) setOpen(false);
  });
  column.addEventListener('click', () => setOpen(false));

  // ── The page's playhead ─────────────────────────────────────────────────
  const range = () => Math.max(1, document.documentElement.scrollHeight - innerHeight);
  let current = -1;
  function sectionAt() {
    const line = innerHeight * READ_LINE;
    let i = 0;
    targets.forEach((target, n) => {
      if (target && target.getBoundingClientRect().top <= line) i = n;
    });
    return i;
  }
  function paint(force) {
    trace.style.transform = `scaleX(${Math.min(1, scrollY / range())})`;
    const i = sectionAt();
    if (i === current && !force) return;
    current = i;
    const shift = rows[0].offsetTop - rows[i].offsetTop;
    rows.forEach((row, n) => {
      const d = n - i;
      row.dataset.state = d < 0 ? 'past' : d === 0 ? 'sung' : d === 1 ? 'next' : 'later';
      row.style.transitionDelay = `${Math.min(Math.max(d + 1, 0), 4) * 45}ms`;
      row.style.transform = `translateY(${shift}px)`;
    });
  }
  let frame = 0;
  const schedule = () => {
    if (!frame) frame = requestAnimationFrame(() => { frame = 0; paint(false); });
  };
  addEventListener('scroll', schedule, { passive: true });
  addEventListener('resize', () => paint(true), { passive: true });
  paint(true);

  // Scrub: drag along the foot to seek through the page.
  let scrubbing = false;
  function seek(event) {
    const box = edge.getBoundingClientRect();
    const at = Math.min(1, Math.max(0, (event.clientX - box.left) / box.width));
    scrollTo({ top: at * range(), behavior: 'instant' });
  }
  edge.addEventListener('pointerdown', (event) => {
    scrubbing = true;
    root.dataset.scrubbing = 'true';
    edge.setPointerCapture(event.pointerId);
    seek(event);
    event.preventDefault();
  });
  edge.addEventListener('pointermove', (event) => { if (scrubbing) seek(event); });
  const stop = () => { scrubbing = false; delete root.dataset.scrubbing; };
  edge.addEventListener('pointerup', stop);
  edge.addEventListener('pointercancel', stop);

  // Swipe: sideways on the notch skips a section.
  let travel = 0;
  let restUntil = 0;
  root.addEventListener('wheel', (event) => {
    if (Math.abs(event.deltaX) <= Math.abs(event.deltaY)) return;
    event.preventDefault();
    if (performance.now() < restUntil) return;
    travel += event.deltaX;
    if (Math.abs(travel) < SWIPE) return;
    const next = Math.min(targets.length - 1, Math.max(0, sectionAt() + Math.sign(travel)));
    travel = 0;
    restUntil = performance.now() + SWIPE_REST;
    targets[next]?.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth' });
  }, { passive: false });

  // ── The soundtrack's clocks, either side of the notch ────────────────────
  if (audio) {
    const tick = () => {
      const length = audio.duration || 0;
      root.dataset.timed = String(length > 0);
      elapsed.textContent = clock(audio.currentTime || 0);
      left.textContent = `-${clock(Math.max(0, length - (audio.currentTime || 0)))}`;
    };
    for (const type of ['timeupdate', 'durationchange', 'emptied']) audio.addEventListener(type, tick);
    tick();
  }

  return { setOpen };
}

/**
 * Print each section title in three plates (css/magnetite.css): the words are
 * wrapped in a box of their own, whose colour plates draw the same text, so
 * the plates sit on the words however the title lays itself out. They come
 * into register the first time the title is half on screen.
 */
export function inkTitles(titles) {
  const watch = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.firstElementChild.dataset.inked = '';
      watch.unobserve(entry.target);
    }
  }, { threshold: 0.5 });
  for (const title of titles) {
    const words = document.createElement('span');
    words.dataset.platesText = title.textContent.trim();
    words.append(...title.childNodes);
    title.append(words);
    watch.observe(title);
  }
}
