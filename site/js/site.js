// Driving the page.
//
// One simulation, two cameras: the notch open and the notch shut. They are two
// views of the SAME `FerrofluidSim` rather than two simulations, because the
// page shows them within a screen of each other and the cheapest way to be
// honest about that is to make disagreement impossible.
//
// The input is not synthesised. `REAL_LEVELS` is 240 frames captured from the
// app's own audio tap, replayed at the 30 Hz it was captured at and stepped
// twice apiece at 60 — which is what the app does with them, and what this file
// spent its whole existence not doing. It said 60 Hz here, indexed at 60 Hz
// below, and played eight seconds of music in four. See `CAPTURE_HZ`. The ink
// is displaced by the same numbers that displace it on the machine, at the same
// pace; the one deliberate difference is the low pass, and `SMOOTH_TAU` says
// why a page five times the size of a menu bar needs one.

import { FerrofluidSim, mulberry32 } from './sim.js';
import { RisoHero, HEADLINE } from './hero.js';
import { RisoBand } from './band.js';
import { REAL_LEVELS, LOOP_FRAME } from '../data/real-levels.js';
import { bankSteps, replayFrame, replayCadence, smoothStep, driveStill } from './clock.js';
import { shouldDraw, applyWatch, filmTransport, prefersReducedMotion } from './visibility.js';
import { LevelPump } from './bands.js';
import { startFinale } from './finale.js';
import { startPlayer } from './player.js';
import { startTunnel } from './tunnel.js';
import { startTouches } from './touches.js';

/**
 * The rate the capture was TAKEN at, which is not the rate the page draws at.
 *
 * This was 60, and 60 was wrong. `AudioLevels.swift` pumps its read loop on
 * `Task.sleep(for: .milliseconds(33))` — the class comment beside it says "30
 * times a second" and the tap's own says "roughly 30 times a second" — so the
 * `[levels]` lines that `NOTCH_AUDIO_DEBUG` prints, which are byte-for-byte the
 * format of `Resources/real-levels.txt`, arrive at 30Hz. The commit that added
 * the capture (cefd7f7) says so outright: "the clock runs at 60Hz while levels
 * arrive at 30, so every second step sees a delta of exactly zero", and
 * `tools/fluidcheck.swift` steps each captured frame TWICE for that reason. The
 * pump was already 33ms at that commit, so this was never 60.
 *
 * Indexing at 60 played eight seconds of music in four. Everything downstream
 * inherited it: the loop period was reported as 3.567s and is 7.133s, the
 * entrance landed at 1.72s instead of the 3.43s of the music it claims to be
 * caused by, and `SMOOTH_TAU` was added below to quiet a "jitter" that was the
 * double speed. The page's own header said the ink is "displaced by the same
 * numbers that displace it on the machine", and it was displaced by the same
 * numbers at twice the pace.
 *
 * `theCaptureIsReplayedAtItsOwnRate` reads the pump interval out of
 * AudioLevels.swift and fails if these two ever disagree again.
 */
const CAPTURE_HZ = 30;

/**
 * The rate the PHYSICS is stepped at, which is the app's render clock.
 *
 * Two constants because they are two facts. The app runs `TimelineView` at
 * 1/60 and reads whatever `bands` currently holds, so a captured frame is
 * stepped twice and the second step sees no change — that stepped, held input
 * is the sequence the shipping fluid actually integrates, and it is what the
 * page reproduces now that the index advances at 30.
 */
const SIM_HZ = 60;


/**
 * The frame the still is held on under Reduce Motion.
 *
 * The preference asks for no motion; it does not ask for a different picture.
 * The page used to answer it with silence — the resting outline, which is a
 * flat pill — so the one visitor who cannot watch the liquid move was also the
 * one shown that it never does. This advances a seeded sim through the app's
 * own capture to a frame with the surface standing displaced and paints that,
 * once.
 *
 * Chosen by rendering candidates and looking at them — and looked at again once
 * the replay's cadence was corrected, because the first pass chose off a sim
 * stepped ONCE per captured frame, which is not the sequence the loop below
 * integrates. 110 survived that second look: across the capture it still
 * carries a wave train along its lower edge with a tapered fall at each end,
 * where its neighbours give up one or the other.
 *
 * The margin is small, and the reason is `reduceMotion` on the sim: Geometry's
 * `reducedTravel` caps the excursion, so nothing in this capture crowns
 * dramatically under the preference. What the choice buys is an edge that
 * undulates and ends that taper instead of the flat pill — not a peak.
 */
const STILL_FRAME = 110;
/** Fixed, so the still is the same still on every load and every resize. */
const STILL_SEED = 9;

/**
 * Time constant on the drive, in seconds.
 *
 * This said "the capture is a 60 Hz tap and it is BUSY — every frame is a new
 * number", and both halves were wrong: the capture is 30Hz, and once it is
 * indexed at 30 each frame is held for two steps, so half the steps are a new
 * number and the other half are the same one. The chatter it was added to quiet
 * was the double speed. That would make this a compensation for a bug that has
 * since been fixed, and the honest move looked like deleting it.
 *
 * It is not, and the reason is scale. The hero draws the liquid at three times
 * the machine's own size, so a point of travel is several pixels on the page,
 * and every sheet is screened: a surface that moves a dot pitch per step makes
 * the dots crawl. The way to measure it is the furthest any point of the
 * outline moves between one step and the next, in page pixels, over the whole
 * capture, with and without this pass. The app does not need this because the
 * app is small and unscreened.
 *
 * So it stays, as a first-order low pass on the levels going in — the same
 * numbers, arriving less abruptly. Peaks still break; they stop chattering. The
 * physics below it is untouched, and this is the one place the page is
 * knowingly not the app: `theReplayIsSteppedLikeTheApp` proves the port under
 * the app's cadence with the levels raw, and then the page smooths them.
 */
const SMOOTH_TAU = 0.11;

/**
 * Live audio is already attack/release metered by `BandAnalyser`. Reusing the
 * replay's 110ms filter made the enlarged ink feel a beat behind the music;
 * this shorter pass keeps the hero continuous without masking new hits.
 */
const LIVE_SMOOTH_TAU = 0.035;

/**
 * The three numbers above, turned into the three the loops actually use.
 *
 * Once, and in `clock.js`, because every place that spelled `1 / SIM_HZ` or
 * `1 - Math.exp(-dt / SMOOTH_TAU)` was a copy — including the gate's, which
 * rebuilt all three from the three constants it read out of this file and so
 * agreed with a still that had drifted. See `replayCadence`.
 */
const CADENCE = replayCadence(SIM_HZ, CAPTURE_HZ, SMOOTH_TAU);

const reduceMotion = prefersReducedMotion(matchMedia('(prefers-reduced-motion: reduce)'));

const sim = new FerrofluidSim();
sim.setOpen(true);
sim.reduceMotion = reduceMotion;

const views = [];

/**
 * Where a print stands, for the stylesheet: `press` while the press is
 * running and no sheet is down, `ready` once one is, and `none` where there is
 * no press — no WebGL, or forced colours, where a picture in fixed inks would
 * override the colours the visitor chose. `none` lays out the plain words.
 */
function printed(canvas, state) {
  const section = canvas.closest('[data-print-host]');
  if (section && section.dataset.print !== state) section.dataset.print = state;
}
const plain = matchMedia('(forced-colors: active)').matches;
if (plain) {
  for (const canvas of document.querySelectorAll('#hero-print, #band-print')) printed(canvas, 'none');
}

// The hero. The h1 is the words and the print sets them, line for line as the
// h1 breaks them, in the pink plate behind the machine.
const heroCanvas = !plain && document.getElementById('hero-print');
const headline = document.querySelector('.headline');
const hero = heroCanvas && headline && new RisoHero(heroCanvas, {
  lines: [...headline.children].map((line) => line.textContent.trim()),
  copy: heroCanvas.closest('.hero'),
  reduceMotion,
});
if (hero) views.push({ view: hero, sim, openness: () => 1 });

// The menu bar. The notch is the download link and the print is drawn to the
// link's box; the status item beside the clock is the app's own mark, read
// off the page's SVG so the two cannot disagree.
const bandCanvas = !plain && document.getElementById('band-print');
const download = document.querySelector('[data-download]');
const glyph = document.querySelector('.mark__glyph');
const band = bandCanvas && download && new RisoBand(bandCanvas, download, {
  mark: glyph && {
    path: glyph.querySelector('path').getAttribute('d'),
    box: glyph.getAttribute('viewBox').split(/\s+/).map(Number),
  },
  sleeve: document.querySelector('.band__sleeve'),
  reduceMotion,
});
/**
 * How far the band's liquid stands open: shut, and a little way down when the
 * notch is reached for — the app's own hover. Eased on the physics clock, so
 * the gesture takes the same time on every display.
 */
const BAND_REACH = 0.45;
const BAND_TAU = 0.14;
let bandOpenness = 0;
let bandWant = 0;
if (band) views.push({ view: band, sim, openness: () => bandOpenness });

// The soundtrack's circles at the foot of the window. Not a print, so forced
// colours keep them.
const soundtrack = document.querySelector('[data-player]');
const soundtrackAudio = soundtrack && soundtrack.querySelector('[data-soundtrack-audio]');
const player = soundtrack && soundtrackAudio && startPlayer(soundtrack, soundtrackAudio);
// The band's idle pill shows what the circles are playing.
if (band && player) band.nowPlaying = player.now;
/** The Reduce Motion still (see `renderStill`), built once on first use. */
let still = null;

for (const entry of views) printed(entry.view.canvas, entry.view.press ? 'press' : 'none');

// ── The film ────────────────────────────────────────────────────────────────
//
// The third camera is not a camera any more: mid-page the app plays ITSELF,
// screen-recorded, so the one thing the drawings cannot prove — that the
// product does this on real hardware — is footage rather than a claim.
// Playback is the page's decision, not the tag's: nothing in the markup
// self-starts, and the motion preference is asked before the element ever
// runs, so under Reduce Motion the film holds its still — its own open
// frame, the whole shape with ends, the frame the other two pictures do
// not show. Like the canvases, the film runs only near the viewport, on
// the same 200px apron the views observer uses, and a film nobody is
// beside is paused — the canvases' own frugality.
const film = document.getElementById('demo-film');
// Scrolled into: the hero's camera dives into its notch, the recorded desktop
// takes over and the camera follows the footage in and out, then lands on the
// band's notch, the download, at the window's centre, and the desktop goes.
// The camera reads the film's clock; playback stays the page's below.
const tunnel = startTunnel(film && film.closest('[data-tunnel]'), { reduceMotion, hero, dock: download, film });
// Only in the journey, where the desktop is laid out in its own points: the
// hand that the recording could not show, drawn on it (js/touches.js).
if (tunnel) startTouches(film, document.querySelector('.how'));
const filmToggle = document.querySelector('[data-demo-motion]');
const filmToggleLabel = filmToggle
  && filmToggle.querySelector('[data-demo-motion-label]');
if (film && !reduceMotion) {
  let filmUserPaused = false;
  const setFilmTransport = (playing) => {
    if (!filmToggle) return;
    filmToggle.dataset.playing = String(playing);
    if (filmToggleLabel) {
      filmToggleLabel.textContent = playing ? 'Pause demo' : 'Play demo';
    }
  };
  // Frame 0 is both the poster and the loop entry, so playback never jumps.
  // The delivery cut stays open throughout; it does not hide the product on
  // its own landing page.
  // A rejected play() is a browser declining, not a bug worth a broken page.
  const run = () => {
    if (!filmUserPaused) film.play().catch(() => {});
  };
  film.addEventListener('play', () => setFilmTransport(true));
  film.addEventListener('pause', () => setFilmTransport(false));
  if (filmToggle) {
    filmToggle.addEventListener('click', () => {
      filmUserPaused = !film.paused;
      if (filmUserPaused) film.pause();
      else run();
    });
  }
  if (typeof IntersectionObserver === 'function') {
    // Where the film sits relative to the visitor is the transport's own
    // memory, not a flag this closure keeps. It was a flag this closure kept,
    // and `beside = !record.isIntersecting` inverted the whole transport with
    // the gate green — so the state went where a mutant can reach it and this
    // file stopped naming `isIntersecting` at all.
    const transport = filmTransport();
    const near = new IntersectionObserver((entries) => {
      for (const record of entries) {
        // Both actions spelled out, rather than one and an `else`. The policy
        // returns one of two, and the gate reads the two off the policy and
        // requires each to be answered here — so dropping the pause is a
        // deletion the gate can see, not an absent branch it cannot.
        const action = transport.observe(record);
        if (action === 'play') run();
        if (action === 'pause') film.pause();
      }
    }, { rootMargin: '200px' });
    near.observe(film);
    // A browser that suspends the page can pause the film on its own — a
    // muted loop nobody pressed pause on. Coming back is the cue to press
    // play again, but only beside the film: offscreen it stays paused,
    // which is the observer's own economy.
    document.addEventListener('visibilitychange', () => {
      if (transport.revealed(document.hidden) === 'play') run();
    });
  } else {
    run();
  }
}

// ── The soundtrack ─────────────────────────────────────────────────────────
//
// The page asks to play its music as it loads, from the circles at the foot of
// the window. Browsers refuse sound until the visitor has done something, so
// a refused start waits for the visitor's first click, tap or key; a pause is
// remembered, and a visitor who paused is not played at again. Once playing,
// the element is routed through the browser port of AudioTap and the page's
// simulation reads those live bands. If AudioWorklet is unavailable the music
// still plays and the page keeps its proven captured replay; a missing
// analyser never costs the visitor the music.
const soundtrackToggle = soundtrack && soundtrack.querySelector('[data-soundtrack-toggle]');
const soundtrackToggleLabel = soundtrack
  && soundtrack.querySelector('[data-soundtrack-toggle-label]');
const soundtrackButtons = soundtrack
  ? [...soundtrack.querySelectorAll('[data-soundtrack-track]')]
  : [];
const soundtrackTracks = soundtrackButtons.map((item) => ({
  title: item.dataset.title,
  artist: item.dataset.artist,
  src: item.dataset.src,
}));
const soundtrackStatus = soundtrack && soundtrack.querySelector('[data-soundtrack-status]');
/** Where a visitor's pause is kept, so a return visit does not play at them. */
const SOUNDTRACK_PAUSED = 'magnetite.soundtrack.paused';
/** The events a browser counts as the visitor meaning it — the ones that unlock sound. */
const SOUNDTRACK_GESTURES = ['pointerdown', 'pointerup', 'keydown', 'touchend'];

const livePump = new LevelPump();
const liveBands = new Float32Array(livePump.bands.length);
const liveSource = { levels(out) { out.set(liveBands); } };
let liveAnalyser = false;
let livePumpFrame = -1;
let soundtrackPlaying = false;
let soundtrackIndex = 0;
let soundtrackContext = null;
let soundtrackAnalyser = null;
let soundtrackAnalyserPromise = null;

function soundtrackAnnounce(message) {
  if (soundtrackStatus) soundtrackStatus.textContent = message;
}

/** Storage can throw — a private window, blocked site data — and a pause is a nicety. */
function soundtrackWasPaused() {
  try { return localStorage.getItem(SOUNDTRACK_PAUSED) === '1'; } catch { return false; }
}

function rememberSoundtrackPause(paused) {
  try {
    if (paused) localStorage.setItem(SOUNDTRACK_PAUSED, '1');
    else localStorage.removeItem(SOUNDTRACK_PAUSED);
  } catch { /* the pause lasts this visit only */ }
}

/**
 * Whether this moment may start an AudioContext. Routing the element into a
 * context the browser keeps suspended silences it, so the analyser is only
 * ever built inside a gesture. A browser that cannot say is trusted.
 */
function soundtrackMayListen() {
  return navigator.userActivation ? navigator.userActivation.isActive : true;
}

/**
 * The button's name IS its state: it says what pressing it will do. A
 * pressed-state on top of a name that already changed made a screen reader
 * announce "Pause, pressed", which describes two different buttons.
 */
function setSoundtrackTransport(playing) {
  if (!soundtrackToggle) return;
  soundtrackToggle.dataset.playing = String(playing);
  if (soundtrackToggleLabel) {
    soundtrackToggleLabel.textContent = playing ? 'Pause' : 'Play';
  }
}

function selectSoundtrack(index, play = false) {
  if (!soundtrackAudio || soundtrackTracks.length === 0) return;
  soundtrackIndex = (index + soundtrackTracks.length) % soundtrackTracks.length;
  const track = soundtrackTracks[soundtrackIndex];
  player?.show(soundtrackIndex);
  if (soundtrackAudio.getAttribute('src') !== track.src) {
    soundtrackAudio.src = track.src;
    soundtrackAudio.load();
  }
  liveBands.fill(0);
  livePump.bands.fill(0);
  livePumpFrame = -1;
  if (play) playSoundtrack(true);
}

function enableSoundtrackAnalyser() {
  if (!soundtrackAudio) return Promise.resolve(false);
  if (soundtrackAnalyserPromise) return soundtrackAnalyserPromise;

  const AudioContext = window.AudioContext || window.webkitAudioContext;
  if (!AudioContext || typeof AudioWorkletNode !== 'function') return Promise.resolve(false);

  soundtrackContext = new AudioContext();
  const source = soundtrackContext.createMediaElementSource(soundtrackAudio);
  source.connect(soundtrackContext.destination);
  soundtrackContext.resume().catch(() => {});

  soundtrackAnalyserPromise = soundtrackContext.audioWorklet
    .addModule('js/bands-worklet.js')
    .then(() => {
      soundtrackAnalyser = new AudioWorkletNode(soundtrackContext, 'bands');
      const silentSink = soundtrackContext.createGain();
      silentSink.gain.value = 0;
      source.connect(soundtrackAnalyser);
      soundtrackAnalyser.connect(silentSink).connect(soundtrackContext.destination);
      soundtrackAnalyser.port.onmessage = ({ data }) => {
        if (data && data.length === liveBands.length) liveBands.set(data);
      };
      liveAnalyser = true;
      return true;
    })
    .catch(() => false);
  return soundtrackAnalyserPromise;
}

/**
 * `asked` is a press of the player's own circles. Only then is a refusal
 * worth saying out loud: the page asking on load and being told no is the
 * browser's ordinary answer, not news.
 */
function playSoundtrack(asked = false) {
  if (!soundtrackAudio) return;
  // Both calls begin inside the gesture. Waiting for the worklet module
  // before play() would spend the browser's transient user activation.
  if (soundtrackMayListen()) enableSoundtrackAnalyser();
  soundtrackAudio.play().catch(() => {
    if (asked) soundtrackAnnounce('The soundtrack could not start. Try Play again.');
  });
}

/**
 * The visitor's first gesture, anywhere on the page, is the one a browser
 * that refused the load's request is waiting for. A press on the player's own
 * circles is left to them — answering it here too would start the music and
 * let the Play it landed on pause it again.
 */
function soundtrackGesture(event) {
  const own = event.target instanceof Element
    && event.target.closest('[data-player] button');
  if (soundtrackAudio.paused) {
    if (!own && !soundtrackWasPaused()) playSoundtrack();
  } else if (soundtrackMayListen()) {
    // Playing already — a browser that allowed the load's request — so this
    // gesture is only needed for the analyser.
    enableSoundtrackAnalyser();
  }
  if (soundtrackAnalyserPromise || soundtrackWasPaused()) {
    for (const type of SOUNDTRACK_GESTURES) removeEventListener(type, soundtrackGesture, true);
  }
}

if (soundtrackAudio && soundtrackToggle) {
  soundtrackToggle.addEventListener('click', () => {
    rememberSoundtrackPause(!soundtrackAudio.paused);
    if (soundtrackAudio.paused) playSoundtrack(true);
    else soundtrackAudio.pause();
  });
  // Choosing a track strikes the ink the way the app's skip does: the
  // reservoir heaves toward the direction of travel. The one already playing
  // is the Play circle's to pause, not this one's.
  soundtrackButtons.forEach((button, index) => {
    button.addEventListener('click', () => {
      const step = index - soundtrackIndex;
      rememberSoundtrackPause(false);
      if (step === 0 && !soundtrackAudio.paused) return;
      selectSoundtrack(index, true);
      if (step && !reduceMotion) sim.surge(0.8, Math.sign(step));
    });
  });
  soundtrackAudio.addEventListener('play', () => {
    soundtrackPlaying = true;
    finale?.wake();
    setSoundtrackTransport(true);
    const track = soundtrackTracks[soundtrackIndex];
    soundtrackAnnounce(`Playing ${track.title} by ${track.artist}.`);
  });
  soundtrackAudio.addEventListener('pause', () => {
    soundtrackPlaying = false;
    liveBands.fill(0);
    setSoundtrackTransport(false);
    if (!soundtrackAudio.ended) soundtrackAnnounce('Soundtrack paused.');
  });
  soundtrackAudio.addEventListener('ended', () => {
    selectSoundtrack(soundtrackIndex + 1, true);
  });
  soundtrackAudio.addEventListener('error', () => {
    soundtrackPlaying = false;
    setSoundtrackTransport(false);
    soundtrackAnnounce('This soundtrack track is unavailable.');
  });

  selectSoundtrack(0);
  for (const type of SOUNDTRACK_GESTURES) addEventListener(type, soundtrackGesture, true);
  // The load's own request: the element alone, never the analyser, which
  // outside a gesture would be a suspended context holding the sound.
  if (!soundtrackWasPaused()) soundtrackAudio.play().catch(() => {});
}

// ── The finale ──────────────────────────────────────────────────────────────
//
// The name at the foot of the page, poured wet, in a field of iron filings. It
// keeps its own clock (js/finale.js); what it takes from here is the motion
// preference and, while the soundtrack plays, the same twelve bands the hero's
// liquid is hearing. Forced colours keep the traced wordmark in the markup.
const finaleSection = !plain && document.querySelector('[data-finale]');
const finale = finaleSection && startFinale(finaleSection, {
  reduceMotion,
  bands: () => (soundtrackPlaying ? liveBands : null),
});

/**
 * Size each print to its box, and only the ones whose box moved.
 *
 * Keyed on the box and the device pixel ratio together. Dragging the window
 * from a 2x display to a 1x one leaves the CSS size identical, so a size-only
 * key skips `resize()` and the backing store keeps the old ratio; and on iOS
 * Safari the toolbar collapsing during the first scroll is a resize event with
 * every box unchanged, which the key makes free. `force` is for the one change
 * no box shows: the headline's face arriving, which moves every word the hero
 * measured in the fallback.
 */
function layout(force = false) {
  const dpr = Math.min(2, globalThis.devicePixelRatio || 1);
  for (const entry of views) {
    const box = entry.view.canvas.getBoundingClientRect();
    const key = `${Math.round(box.width)}x${Math.round(box.height)}@${dpr}`;
    if (!force && entry.key === key) continue;
    entry.key = key;
    entry.view.resize();
  }
  // Setting any canvas's width — even to the value it already had — clears its
  // backing store, so whatever was on screen has to be put back. Under the
  // preference that is one still; otherwise it is the loop, which may have
  // been stopped by a hidden tab.
  if (reduceMotion) renderStill();
  else if (!running) start();
}

/**
 * One frame of the real fluid, held, under Reduce Motion.
 *
 * A separate sim, seeded, so it cannot disturb the one the page owns and comes
 * out identical on every load — and built once, because a resize has to
 * repaint the same picture, not walk the capture again. `reduceMotion` on the
 * sim is what caps the travel (Geometry's own `reducedTravel`), so this is the
 * app's answer to the preference and not a second one invented here.
 */
function renderStill() {
  if (!still) {
    still = new FerrofluidSim(mulberry32(STILL_SEED));
    still.reduceMotion = true;
    still.setOpen(true);
    // Stepped like the app: the clock is 1/60 and a captured frame is held for
    // two of them. The walk is in `clock.js` so the gate drives the same one;
    // see `theStillIsAFrameOfTheFilm`.
    driveStill(still, REAL_LEVELS, STILL_FRAME, CADENCE);
  }
  for (const entry of views) {
    if (entry.view.render(still, entry.openness())) printed(entry.view.canvas, 'ready');
  }
}

/**
 * Only the drawing is gated, never the physics.
 *
 * A canvas that scrolls back into view shows the simulation the rest of the
 * page has been running rather than one that froze when it left.
 * `content-visibility: auto` would not do this: the draw calls come from
 * script, so the backing store is rasterised whether or not the browser ever
 * paints the element.
 */
if (typeof IntersectionObserver === 'function') {
  const watch = new IntersectionObserver((entries) => {
    // The records go straight to the policy, which writes the flags and says
    // whether the loop has to wake. Nothing here reads or writes `.onScreen`:
    // the assignment that used to sit in this callback could be inverted
    // without a single check noticing, and no text rule can hold an assignment
    // whose every identifier is free to be renamed. So it went to `applyWatch`
    // and this file's rule became an absence — it never writes the flag.
    const wake = applyWatch(entries, views, running);
    if (wake) start();
  }, { rootMargin: '200px' });
  for (const entry of views) watch.observe(entry.view.canvas);
}

// ── The replay ──────────────────────────────────────────────────────────────

let last = 0;
let running = false;
/** One physics step, in seconds. The app's clock, not the display's. */
const SIM_STEP = CADENCE.dt;
const LIVE_SMOOTH_K = 1 - Math.exp(-SIM_STEP / LIVE_SMOOTH_TAU);
const BAND_K = 1 - Math.exp(-SIM_STEP / BAND_TAU);
/**
 * Wall time received but not yet spent as whole steps.
 *
 * A leftover of up to one step is carried rather than dropped, so a display
 * whose refresh does not divide 60 — 90Hz, or a 60Hz panel missing frames —
 * still spends every millisecond it is handed exactly once.
 */
let bank = 0;
/** Steps taken, as an integer, because `elapsed` derived from it cannot drift. */
let steps = 0;
/** Steps already integrated, so a callback advances the ones it added and no more. */
let stepsDrawn = 0;
/**
 * The frame the loop has already asked for, so `stop` can take it back.
 *
 * `frame` guards on `running`, which looks like enough and is not: a callback
 * queued before the tab was hidden is never SERVICED while it is hidden, so it
 * is still pending when the page comes back — and `start` sets `running` true
 * again in the same event, before that stale callback gets its turn. It then
 * finds the flag true, runs, and queues a successor of its own. One extra loop
 * per hide/show cycle, forever. The physics does not drift — the second
 * callback of a pair reads a dt of zero — so nothing looks wrong.
 */
let queued = 0;

/**
 * The captured frame driving a physics STEP — looping back to the quietest
 * captured frame rather than to the start.
 *
 * Takes the step, not the elapsed seconds. Converting the integer step counter
 * into seconds and back into a frame index put a float round trip between the
 * two, and it does not survive one: see `replayFrame` in clock.js, which is
 * where the arithmetic lives so a gate with no browser can drive the real
 * function rather than a copy of it.
 */
function frameNow(step) {
  return replayFrame(step, SIM_HZ, CAPTURE_HZ, REAL_LEVELS.length, LOOP_FRAME);
}

function levelsAt(step) {
  if (!liveAnalyser) return REAL_LEVELS[frameNow(step)];
  const pumpFrame = Math.floor(step / CADENCE.steps);
  if (pumpFrame !== livePumpFrame) {
    livePumpFrame = pumpFrame;
    livePump.tick(soundtrackPlaying ? liveSource : null);
  }
  return livePump.bands;
}

/**
 * The current drive, low-passed. Captured footage needs the full scale filter;
 * live audio has already passed through the app's own meter and gets only the
 * shorter continuity pass above.
 *
 * Both rates are computed once from `SIM_STEP`; recomputing either per call
 * would be another clock copy that could disagree with the still silently.
 */
const drive = new Array(REAL_LEVELS[0].length).fill(0);
function smoothed(target) {
  return smoothStep(drive, target, liveAnalyser ? LIVE_SMOOTH_K : CADENCE.k);
}

function frame(now) {
  if (!running) return;
  // Two clamps, for two different lies the clock tells. A tab restored after
  // minutes must not be handed that gap as one step — and the first callback's
  // timestamp is taken when the frame BEGAN, which can predate the reading
  // `start` just took, so the very first dt can arrive negative.
  const dt = Math.max(0, Math.min(0.05, (now - last) / 1000)) || 0;
  last = now;
  // Banked, not spent. The step below is a FIXED 1/SIM_HZ and the display's
  // rate is nobody's business but the display's: a 120Hz panel delivers twice
  // the callbacks and must integrate the same fluid, not a finer one. It did
  // not — advancing by the wall's own dt made the physics a function of the
  // refresh rate, and on the ProMotion hardware this product is about that is
  // a different picture. Driven over this capture the way the defect drove it —
  // the drive low-passed per callback, the captured frame taken from elapsed
  // time — a 120Hz panel and a 60Hz one part company by 0.48 in site height at
  // worst, and only the 60Hz picture matches the golden that
  // `theReplayIsSteppedLikeTheApp` compares to.
  //
  // That figure was 0.372 and is stated as a method now, because 0.372 is not
  // reproducible: it belongs to the cadence where the capture was believed to
  // run at 60Hz, and no reading of it under the true 30Hz comes back under
  // 0.48. Eight variants were tried — smoothed and raw, the index taken from
  // elapsed time and from a held count — and the whole 30Hz family lands
  // between 0.48 and 0.58 while the 60Hz family lands between 0.36 and 0.39.
  // The number moved in the direction that matters: the divergence this banking
  // exists to prevent is LARGER than the comment claimed, so the note left to
  // justify the fix was quietly arguing against it.
  //
  // The tempo was never wrong here — the step count is spent wall time and the
  // index is taken from it — so this buys agreement, not pace. The clamp above
  // still does its two jobs; what it hands over is banked rather than
  // integrated. Whole steps only, and the remainder stays banked. In `clock.js`
  // rather than here so it can be driven at four refresh rates by a check that
  // has no browser — see `theReplayClockIsTheAppsClock`.
  ({ bank, steps } = bankSteps({ bank, steps }, dt, SIM_STEP));

  // One advance per whole step, so a captured frame gets exactly
  // SIM_HZ / CAPTURE_HZ of them however often the browser calls back, and the
  // smoothing runs on the same clock rather than on the callback's. The index
  // comes from `s` itself: handing `levelsAt` seconds broke that hold at step
  // 246 — frame 122 took three steps and 123 took one — while all 35 gates
  // stayed green. See `replayFrame` in clock.js.
  for (let s = stepsDrawn; s < steps; s++) {
    sim.advance(smoothed(levelsAt(s)), SIM_STEP);
    bandOpenness += (bandWant - bandOpenness) * BAND_K;
  }
  stepsDrawn = steps;
  for (const entry of views) {
    if (!shouldDraw(entry.onScreen)) continue;
    // A print that returns true put a sheet down; only then are its words shown.
    if (entry.view.render(entry.sim, entry.openness())) printed(entry.view.canvas, 'ready');
  }

  queued = requestAnimationFrame(frame);
}

function start() {
  // Under the preference there is no loop at all — not one that settles and
  // retires, which is what this used to do, but none. `renderStill` has
  // already painted the picture and nothing on the page can ask for another
  // frame: this is the one guard, and it covers `layout`, the intersection
  // observer and `visibilitychange` together.
  if (running || reduceMotion) return;
  running = true;
  last = performance.now();
  queued = requestAnimationFrame(frame);
}

function stop() {
  running = false;
  // Cancelling a handle that has already fired is defined to do nothing, which
  // is what makes this safe on the settle path above, where `stop` is called
  // from inside the very callback it is cancelling.
  cancelAnimationFrame(queued);
  queued = 0;
}

// ── Gestures ────────────────────────────────────────────────────────────────

if (hero && !reduceMotion) {
  // No instruction anywhere says to do this. The machine turning a little
  // toward the pointer is the discovery, and a caption would spend it.
  addEventListener('pointermove', (event) => hero.aim(event.clientX, event.clientY), { passive: true });

  // On the documentElement, not on window. `pointerleave` does not bubble, and
  // a non-bubbling event is never dispatched at window at all, so a listener
  // there could not fire and the machine stayed turned toward a pointer that
  // had left. Aiming at the middle of the window is the resting view.
  document.documentElement.addEventListener('pointerleave',
    () => hero.aim(innerWidth / 2, innerHeight / 2), { passive: true });
}

if (download && !reduceMotion) {
  // The notch is a place the liquid answers, not just a rectangle: reaching
  // for it opens the band a little, as hovering the real one does, and since
  // both prints are cameras on one sim the laptop's notch heaves on the same
  // frame. Direction 0 because reaching for a download has no direction.
  const reach = (open) => {
    bandWant = open ? BAND_REACH : 0;
    if (open) sim.surge(1, 0);
  };
  download.addEventListener('pointerenter', () => reach(true));
  download.addEventListener('pointerleave', () => reach(false));
  // The keyboard gets the same answer, but only when the ring is showing. A
  // click focuses too, and answering twice for one gesture reads as a stutter.
  download.addEventListener('focus', () => {
    if (download.matches(':focus-visible')) reach(true);
  });
  download.addEventListener('blur', () => reach(false));
}

// ── Lifecycle ───────────────────────────────────────────────────────────────

document.addEventListener('visibilitychange', () => {
  if (document.hidden) stop();
  else start();
});

addEventListener('resize', () => layout(), { passive: true });

// Under the preference the band's clock is a still too, so it is reprinted on
// the minute rather than left telling the wrong time.
if (reduceMotion && band) setInterval(renderStill, 60_000);

/**
 * The first sheet waits for the headline's face, briefly. The hero measures
 * and sets its words in whatever face the canvas has, so printing before the
 * face arrives prints the fallback serif and swaps it a frame later — in the
 * middle of the entrance. The face is one preloaded 17 KB file; the cap is for
 * a network that never delivers it, where the fallback is the right answer.
 */
const FACE_WAIT_MS = 1500;
const face = document.fonts
  ? document.fonts.load(`${HEADLINE.weight} 64px ${HEADLINE.family}`).catch(() => {})
  : Promise.resolve();
face.then(() => layout(true));
// Past the cap, print in the fallback; the face arriving later re-sets it.
setTimeout(() => layout(), FACE_WAIT_MS);
