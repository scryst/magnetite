// Checks the website's JavaScript port against the shipping Swift.
//
//   node site/test/portcheck.mjs                 # every check
//   node site/test/portcheck.mjs --only=<name>   # one check, alone
//
// The golden files in test/golden are produced by test/portprobe.swift, which
// compiles the REAL FerrofluidSim and Geometry and dumps their state. That is
// the point: a harness that only agrees with itself proves nothing, and the
// spec this site was built from already carried constants the source had moved
// past. Regenerate with test/refresh-golden.sh whenever the app's physics moves
// — a diff there is the app changing under the site, which is exactly the
// signal worth having.
//
// Every assertion here has been mutation-tested by test/mutate.mjs — with one
// class of exception, named rather than left to be discovered.
//
// The exceptions are the READABILITY guards: the requires that fire when this
// file can no longer find what it came to read, like "site.js declares no
// CAPTURE_HZ" or "AudioLevels.swift no longer pumps on a milliseconds sleep".
// They cannot be tripped by a mutant that leaves a working product behind —
// deleting the constant breaks the page, and a check earlier in the run says so
// first — and a mutant that only proves the file is unreadable proves nothing
// about the rule above it. Two others need an input rather than an edit: the
// entrance floor wants a capture whose onsets are all weak, and changing the
// capture to get one changes the gate, which is its own defect.
//
// That claim was a blanket one until 2026-08-28 and was false: a sweep
// cross-referencing each assertion against the message every mutant actually
// printed found eight with nothing exercising them. Five were coverable and are
// now covered — including one, the window-reach guard in
// `theReplayClockIsTheAppsClock`, that turned out not to work, and had been
// written specifically to stop a blind spot from being restored.
//
// So: if you add an assertion here that a mutant CAN reach, it is not exempt,
// and this paragraph is not cover for skipping it.

import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import {
  FerrofluidSim, mulberry32, glowAlpha, SITE_COUNT, BAND_COUNT, CRITICAL_FIELD,
} from '../js/sim.js';
import { Geometry } from '../js/geometry.js';
import { INK } from '../js/press.js';
import { REAL_LEVELS, LOOP_FRAME } from '../data/real-levels.js';
import { bankSteps, replayFrame, replayCadence, smoothStep, driveStill } from '../js/clock.js';
import {
  shouldDraw, watchOutcome, applyWatch, filmAction, filmResume, filmTransport, prefersReducedMotion,
} from '../js/visibility.js';
import { loadSourceLevels, quietestFrame } from './gen-levels.mjs';
import { deriveMark, faviconSVG, inlineGlyph, markSwift, GLYPH_IN_PAGE } from './gen-mark.mjs';
import { buildWebMcpTools, initWebMcp, resolveModelContext } from '../js/webmcp.mjs';
import { hold, camera, sheet, reach, shown, shots, focus, SHOTS, FOOTAGE, PLAYER, WORDS, DOT } from '../js/tunnel.js';
import { CUES, HAND, touchesAt } from '../js/touches.js';

const here = dirname(fileURLToPath(import.meta.url));
const golden = (name) => readFileSync(join(here, 'golden', `${name}.txt`), 'utf8')
  .split('\n').filter((l) => l.trim().length > 0);

let failures = 0;

function require(condition, message) {
  if (!condition) {
    failures++;
    throw new Error(message);
  }
}

/** Absolute tolerance. Both sides are IEEE doubles running the same operations
 *  in the same order, so anything beyond libm's last ulp is a real difference. */
function closeTo(got, want, tolerance, what) {
  const delta = Math.abs(got - want);
  require(delta <= tolerance,
    `${what}: got ${got}, the Swift says ${want} (off by ${delta.toExponential(3)})`);
}

const SIM_TOLERANCE = 1e-9;
const GEOM_TOLERANCE = 1e-7;

/**
 * One float32 step at a value's magnitude.
 *
 * SwiftUI's `Path` stores its coordinates at Float precision, so the points the
 * probe recovers from the finished path are quantised on the way out — measured
 * at up to 1.526e-5 near x=226, which is exactly 2^-16. Everything upstream of
 * the path agrees to 1e-13: `total`, `top`, `sideRun` and every lobe's seat,
 * spread and reach are compared at GEOM_TOLERANCE and match there. So the
 * points are compared against the precision they are actually stored at, and
 * the signed mean is checked separately — quantisation error is symmetric about
 * zero, and a real port error would not be.
 */
function float32Ulp(value) {
  const magnitude = Math.abs(value);
  if (magnitude === 0) return 2 ** -149;
  return 2 ** (Math.floor(Math.log2(magnitude)) - 23);
}
const SILENCE = new Array(BAND_COUNT).fill(0);

/** Replays a golden dump against a fresh port and compares every frame. */
function compareFrames(name, drive) {
  const rows = golden(name);
  const sim = new FerrofluidSim();
  let frames = 0;
  drive(sim, (index) => {
    const row = rows[frames];
    require(row !== undefined, `${name}: the port produced more frames than the Swift did`);
    const g = row.split(' ');
    const at = (label, value, offset) =>
      closeTo(value, Number(g[offset]), SIM_TOLERANCE, `${name} frame ${index} ${label}`);
    require(Number(g[0]) === index, `${name}: frame index ${g[0]} != ${index}`);
    at('swell', sim.swell, 1);
    at('raised', sim.raised, 2);
    at('impact', sim.impact, 3);
    at('brightness', sim.brightness, 4);
    at('flowPhase', sim.flowPhase, 5);
    at('inkOpen', sim.inkOpen, 6);
    at('pointerPull', sim.pointerPull, 7);
    at('pointerRim', sim.pointerRim, 8);
    require((g[9] === '1') === sim.isSettled,
      `${name} frame ${index}: isSettled is ${sim.isSettled}, the Swift says ${g[9] === '1'}`);
    require((g[10] === '1') === sim.hasSound,
      `${name} frame ${index}: hasSound is ${sim.hasSound}, the Swift says ${g[10] === '1'}`);
    for (let i = 0; i < SITE_COUNT; i++) {
      at(`field[${i}]`, sim.sites[i].field, 11 + i);
      at(`height[${i}]`, sim.sites[i].height, 11 + SITE_COUNT + i);
      require((g[11 + 2 * SITE_COUNT + i] === '1') === sim.sites[i].isUp,
        `${name} frame ${index}: isUp[${i}] disagrees with the Swift`);
    }
    frames++;
  });
  require(frames === rows.length,
    `${name}: the port produced ${frames} frames, the Swift produced ${rows.length}`);
  return sim;
}

// ---------------------------------------------------------------------------

/**
 * The whole physics, over 240 frames of the app's own captured audio.
 *
 * Sustained music is the case that matters: constructed spectra miss the
 * saturated body lift that flattens the crowns into a wall, which is the defect
 * the per-band z-score exists to prevent.
 *
 * What this does NOT prove, despite its name: that the site drives the physics
 * the way the app drives it. One step per captured frame is a cadence nothing
 * ships — not the app, which steps each frame twice, and not the page, which
 * steps on a wall clock. It is a test of the PORT's arithmetic, and a good one.
 * The cadence claim its name makes is held by `theReplayIsSteppedLikeTheApp`
 * below, which did not exist while the page was replaying at double speed.
 */
function theReplayMatchesTheShippingPhysics() {
  compareFrames('sim', (sim, check) => {
    REAL_LEVELS.forEach((levels, index) => {
      sim.advance(levels, 1 / 60);
      check(index);
    });
  });
}

/**
 * The port agrees with the Swift on the sequence the APP actually integrates.
 *
 * On the machine the render clock is 60Hz and `AudioLevels` republishes bands
 * at 30, so every captured frame is stepped twice and the second step sees a
 * delta of exactly zero. That held step is not a step the varying sequence
 * above ever takes, and it is not a step that can be assumed equivalent: both
 * of the sim's inputs are measured against a remembered past, `deviation`
 * divides by an adapting `spread`, and `isSettled` can early-return. A port can
 * agree on 240 changing frames and disagree the first time a frame repeats.
 *
 * The golden is `sim-held`, from portprobe's mode of the same name. Regenerate
 * it with the same swiftc line refresh-golden.sh uses, then
 * `.build/checks/portprobe sim-held > site/test/golden/sim-held.txt`.
 */
function theReplayIsSteppedLikeTheApp() {
  compareFrames('sim-held', (sim, check) => {
    REAL_LEVELS.forEach((levels, index) => {
      sim.advance(levels, 1 / 60);
      sim.advance(levels, 1 / 60);
      check(index);
    });
  });
}

/**
 * The replay's clock is the app's clock, whatever the display is doing.
 *
 * `frame()` advanced the sim by the WALL's dt, so a 120Hz panel integrated the
 * same music in twice as many, half-sized steps. The tempo was right — the
 * index is taken from elapsed time — but the physics is not linear in dt, and
 * the divergence is not academic: driven over this capture the way the defect
 * drove it, with the drive low-passed per callback and the captured frame taken
 * from elapsed time, 60Hz against 120Hz differs by 0.48 in site height at
 * worst. Only the 60Hz picture is the one the golden holds and the app draws,
 * so every ProMotion Mac — which is the hardware this product is about — was
 * shown a different fluid.
 *
 * Stated as a method because the 0.372 that stood here is not reproducible.
 * It belongs to the cadence in which the capture was believed to run at 60Hz;
 * under the true 30Hz no reading of it comes back under 0.48. Eight variants
 * were swept — smoothed and raw, index from elapsed time and from a held count
 * — and the 30Hz family lands between 0.48 and 0.58 against the 60Hz family's
 * 0.36 to 0.39. It is the fifth measured figure this capture-rate correction
 * invalidated by leaving quoted rather than recomputed, and the first that no
 * review caught; the other four were in the diff, and this one was not.
 *
 * Four rates, including 90Hz, which divides neither 60 nor 240: a stepper that
 * DROPS its remainder instead of banking it passes at 120 and runs slow at 90,
 * and a check that only tried multiples of 60 would call that fixed.
 */
function theReplayClockIsTheAppsClock() {
  const site = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');
  const simHz = Number(site.match(/^const SIM_HZ = ([\d.]+);/m)?.[1]);
  const captureHz = Number(site.match(/^const CAPTURE_HZ = ([\d.]+);/m)?.[1]);
  require(Number.isFinite(simHz) && Number.isFinite(captureHz),
    'site.js declares no SIM_HZ/CAPTURE_HZ, so its clock cannot be checked');
  const step = 1 / simHz;

  // Ten seconds of wall time, delivered at four refresh rates.
  const run = (hz) => {
    let state = { bank: 0, steps: 0 };
    for (let i = 0; i < hz * 10; i++) state = bankSteps(state, 1 / hz, step);
    return state.steps;
  };
  const at60 = run(60);
  for (const hz of [90, 120, 144]) {
    const taken = run(hz);
    require(Math.abs(taken - at60) <= 1,
      `over ten seconds a ${hz}Hz display takes ${taken} physics steps and a 60Hz one takes `
      + `${at60} — the fluid is a function of the refresh rate, so the page draws one thing on `
      + 'a MacBook and another on a Studio Display');
  }
  require(Math.abs(at60 - simHz * 10) <= 1,
    `ten seconds at ${simHz}Hz should be about ${simHz * 10} steps, not ${at60}`);

  // And the hold: every captured frame gets the same whole number of steps, so
  // the second one sees no change, exactly as it does on the machine.
  //
  // Driven through the REAL `replayFrame`, not through a copy. This check used
  // to carry its own `Math.floor((s / simHz) * captureHz)` — the page's own
  // arithmetic at the time, reproduced faithfully, and therefore blind in
  // exactly the place the page was: the model agreed with the thing under test
  // including where the thing under test was wrong.
  //
  // And the window was ONE SECOND. 120 callbacks at 1/120 is 60 steps, captured
  // frames 0..29, while the first breach of this very invariant was at step 246
  // — four seconds in — where `(246 / 60) * 30` came to 122.99999999999999 and
  // handed frame 122 three steps and frame 123 one. The assertion below is the
  // one whose message reads "the page is out of phase with the capture". It
  // would have passed, on a page that was.
  //
  // "Used to" and "would have" are doing real work in that paragraph: this
  // check never shipped in the blind form. `git show
  // 61258e5^:site/test/portcheck.mjs` does not contain its name, and 61258e5
  // introduced it already carrying the derived window while fixing the page in
  // the same commit. The blind version existed only inside that session's
  // development, so nothing here passed against a defect it could not see.
  const per = simHz / captureHz;
  require(Number.isInteger(per), `${simHz}Hz does not divide into ${captureHz}Hz frames`);

  // One step short of the loop. Past `REAL_LEVELS.length * per` the replay
  // wraps back to LOOP_FRAME and a wrapped frame's count is its own plus the
  // wrap's — which would read as the hold breaking rather than as the loop
  // working.
  const frames = REAL_LEVELS.length;
  const loop = LOOP_FRAME;
  const lastStep = frames * per - 1;

  // The window has to REACH the first step at which the seconds spelling parts
  // company with the integer one. Computed here rather than written down, so
  // that shortening the window back to a second fails loudly instead of
  // quietly restoring the blind spot: at 60/30 that step is 246.
  //
  // Searched over the capture's whole first pass and NOT over `lastStep`,
  // because the window under test cannot also bound the search for the thing it
  // must reach. It did, and that made this assertion decorative in the one
  // direction it exists to cover: with the search stopping at `lastStep`,
  // narrowing the window back to a second found no slip inside it, concluded
  // there was nothing to reach, and passed 35 green. The gate written to stop
  // the blind spot from being restored had the blind spot in it.
  // `the-hold-is-checked-for-one-second` in mutate.mjs is that narrowing, and
  // it survived until this loop stopped asking the window how far to look.
  const firstPass = frames * per - 1;
  let slip = -1;
  for (let s = 0; s <= firstPass && slip < 0; s++) {
    if (Math.floor((s / simHz) * captureHz) !== replayFrame(s, simHz, captureHz, frames, loop)) slip = s;
  }
  require(slip < 0 || lastStep >= slip,
    `the hold is checked over ${lastStep} steps, and the seconds-based index this replaced first `
    + `slips at step ${slip} — a window stopping short of it cannot see the defect it exists for`);

  const counts = new Map();
  let state = { bank: 0, steps: 0 };
  let drawn = 0;
  while (state.steps <= lastStep) {
    state = bankSteps(state, 1 / 120, step);
    for (let s = drawn; s < state.steps && s <= lastStep; s++) {
      const index = replayFrame(s, simHz, captureHz, frames, loop);
      counts.set(index, (counts.get(index) ?? 0) + 1);
    }
    drawn = state.steps;
  }
  // The last captured frame in the window is still being filled, so it is not
  // asked to be complete — the ones behind it are.
  const complete = [...counts.keys()].sort((a, b) => a - b).slice(0, -1);
  require(complete.length > 0, 'the clock produced no completed captured frames in a second');
  for (const index of complete) {
    require(counts.get(index) === per,
      `captured frame ${index} received ${counts.get(index)} steps, not ${per} — the page is out `
      + 'of phase with the capture, so a frame is held for the wrong length and the second step '
      + 'is not the zero-delta one the app takes');
  }

  // And `frame()`, which is the one place left that steps inline.
  //
  // Syntactic, and knowingly so: the arithmetic above is checkable because it
  // was moved somewhere with no DOM in it, and `frame()` cannot follow it there
  // without dragging the whole page along — it reads the wall clock, banks it,
  // fires the entrance and draws every view. So this reads the source instead,
  // and the rule it enforces is the narrow one that a wall-clock step is
  // never handed to `advance` — not a general claim to understand the loop.
  // This comment used to name the wrong escape. It said the alias — `const d =
  // dt` and then `advance(…, d)` — was the form it could not see, and that form
  // is caught: the token `d` is neither of the two accepted names and fails the
  // first require below. The form that actually walked through is a SHADOW,
  // `const SIM_STEP = dt` inside `frame()`, which leaves the call site's text
  // untouched and satisfies both requires. So the paragraph justified leaving
  // the gate narrow by pointing at the case it handles, while the case it
  // missed was an ordinary rename. That hole is closed below rather than
  // described: the body may not redeclare `SIM_STEP`, which is a module
  // constant.
  const body = functionBody(site, 'frame');
  require(body, 'could not find frame() in site.js');
  require(!/\b(?:const|let|var)\s+SIM_STEP\b/.test(body),
    'frame() declares its own SIM_STEP, shadowing the module\'s fixed step — the call site\'s '
    + 'text is then unchanged while the clock it names is not the one this check read');
  const advances = [...body.matchAll(/\.advance\(([\s\S]*?)\);/g)];
  require(advances.length > 0, 'frame() no longer advances the sim at all');
  for (const [whole, args] of advances) {
    const last = args.slice(args.lastIndexOf(',') + 1).trim();
    require(last === 'SIM_STEP',
      `frame() advances the sim by \`${last}\` — that is the display's clock, so the physics `
      + 'is a function of the refresh rate and a 120Hz Mac draws a fluid the golden does not '
      + `hold: ${whole.trim()}`);
  }

  // `renderStill()` used to be held by the same syntax, and the pair of rules
  // was the whole hold on it: the token handed to `advance` had to be `dt`, and
  // the step count had to read `Math.round(SIM_HZ / CAPTURE_HZ)`. Neither says
  // anything about what `dt` IS. `const dt = 2 / SIM_HZ` satisfies both, passed
  // every check in this file, and moved the still — the only picture a visitor
  // who asked for no motion is ever shown — by 12.3 points vertically and 16.4
  // horizontally on a 190-point panel.
  //
  // So the still's stepping is not in `site.js` any more and this is not a
  // syntactic rule any more. It owns no loop to get wrong; the loop is
  // `driveStill` in clock.js, and `theStillIsAFrameOfTheFilm` runs it. All this
  // asks is that the delegation is real — a body that steps for itself again
  // would be a second recipe whatever it spelled.
  const still = functionBody(site, 'renderStill');
  require(still, 'could not find renderStill() in site.js');
  require(!/\.advance\(/.test(still),
    'renderStill() advances the sim itself again — the still is then integrated by a recipe of '
    + 'its own, which is what `driveStill` exists to stop, and no check here can see what step '
    + 'it takes');
  require(/\bdriveStill\s*\(/.test(still),
    'renderStill() no longer drives the still through `driveStill` — whatever walks the capture '
    + 'for it is a second recipe, free to drift from the replay\'s the moment the cadence moves');
}

/**
 * The site replays the capture at the rate the capture was taken at.
 *
 * It did not, for as long as the capture has existed. `CAPTURE_HZ` was 60 and
 * the levels arrive at 30, so eight seconds of music played in four: the loop
 * period was stated as 3.567s and was 7.133s, the entrance fired at 1.72s of a
 * moment that happens at 3.43s, and a low pass was added to the drive to quiet
 * a "jitter" that was the double speed. Nothing caught it because nothing
 * compared the two numbers — site.js said 60 in a comment, portprobe's dump
 * said 60 in a loop, and they agreed with each other.
 *
 * So this reads the rate out of the APP, which is the only place it is a fact:
 * the pump interval in `AudioLevels.swift`. Tolerance because 33ms is 30.30Hz
 * nominal and the pump cannot beat its own sleep — the honest reading of "33ms
 * between reads" is 30Hz to within a frame, and the check fails a 2x error
 * without pretending to measure the real jitter of a main-actor timer.
 */
function theCaptureIsReplayedAtItsOwnRate() {
  const swift = readFileSync(
    join(here, '..', '..', 'Sources', 'NotchApp', 'Audio', 'AudioLevels.swift'), 'utf8');
  const pump = swift.match(/Task\.sleep\(for:\s*\.milliseconds\((\d+)\)\)/);
  require(pump, 'AudioLevels.swift no longer pumps on a milliseconds sleep — the rate the '
    + 'capture is taken at can no longer be read from the app, so site.js cannot be checked '
    + 'against it');
  const appHz = 1000 / Number(pump[1]);

  const site = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');
  const captureHz = Number(site.match(/^const CAPTURE_HZ = ([\d.]+);/m)?.[1]);
  const simHz = Number(site.match(/^const SIM_HZ = ([\d.]+);/m)?.[1]);
  require(Number.isFinite(captureHz), 'site.js declares no CAPTURE_HZ');
  require(Number.isFinite(simHz), 'site.js declares no SIM_HZ');

  require(Math.abs(captureHz - appHz) <= 1,
    `site.js replays the capture at ${captureHz}Hz and the app publishes levels every `
    + `${pump[1]}ms, which is ${appHz.toFixed(2)}Hz — the page is playing the music at `
    + `${(captureHz / appHz).toFixed(2)}x`);
  // The app's clock is its renderer's, and the site's still is stepped on the
  // same assumption that one divides the other.
  require(Number.isInteger(simHz / captureHz),
    `the sim steps at ${simHz}Hz over levels arriving at ${captureHz}Hz, which is not a whole `
    + 'number of steps per captured frame — the app holds each frame for an exact count');
  const view = readFileSync(
    join(here, '..', '..', 'Sources', 'NotchApp', 'UI', 'FerrofluidView.swift'), 'utf8');
  const timeline = view.match(/minimumInterval:\s*1\.0\s*\/\s*([\d.]+)/);
  require(timeline, 'FerrofluidView no longer states its TimelineView interval');
  require(Number(timeline[1]) === simHz,
    `the site steps at ${simHz}Hz and the app renders at ${timeline[1]}Hz`);

  // And the card, which is the third copy of this cadence.
  //
  // og.html runs standalone — it cannot import site.js, which executes DOM code
  // on load — so it restates the three rates as literals in its own call to
  // `replayCadence`. Unheld, the card could be regenerated at one step per
  // captured frame, or at half the smoothing, and ship a picture of a fluid
  // neither the app nor the page runs, with every check green.
  const card = readFileSync(join(here, 'og.html'), 'utf8');
  const tau = Number(site.match(/^const SMOOTH_TAU = ([\d.]+);/m)?.[1]);
  require(Number.isFinite(tau), 'site.js declares no SMOOTH_TAU');

  const cardCadence = card.match(/replayCadence\(([\d.]+),\s*([\d.]+),\s*([\d.]+)\)/);
  require(cardCadence,
    'the share card no longer states its cadence as `replayCadence(<sim>, <capture>, <tau>)`');
  const [cardSim, cardCapture, cardTau] = cardCadence.slice(1).map(Number);
  require(cardSim === simHz,
    `og.html steps the card at 1/${cardSim} where the page steps at 1/${simHz} — the share `
    + 'card is a picture of a simulation running at a different rate from the one it advertises');
  require(cardSim / cardCapture === simHz / captureHz,
    `og.html holds each captured frame for ${cardSim / cardCapture} steps where the page holds it `
    + `for ${simHz / captureHz} — the card is drawn from a cadence the page does not run`);
  require(cardTau === tau,
    `og.html low-passes the drive at ${cardTau} and site.js at ${tau} — the card's liquid is `
    + 'smoothed differently from the page\'s, so its crowns are not the page\'s crowns');
}

/**
 * The card is the size the page promises.
 *
 * `og:image:width` and `og:image:height` are read by a crawler BEFORE it fetches
 * the image, and the unfurl is laid out from them. Get them wrong and Slack
 * reserves the wrong box: the card arrives letterboxed or cropped, and nothing
 * in this repo renders an unfurl, so nothing here would ever show it.
 *
 * They restate a number og.html states once, on its canvas element, and they
 * cannot be deleted, because a crawler is the reader and it only reads the
 * page. So they are held against the artefact rather than against the other
 * restatement: the encoded bitmap on one side and the page's markup on the
 * other. Whether the pixels are the render og.html draws now is
 * `node site/test/cardprobe.mjs`, run on purpose — it needs a browser.
 *
 * What is NOT held: og:image:alt's wording. It is the only thing a screen
 * reader gets from an unfurl and it describes a picture, which no check here
 * can read. Its presence is held; whether it still describes the card is a
 * thing a person has to look at, and the card has been re-rendered twice since
 * the sentence was written.
 */
function theCardIsTheSizeThePagePromises() {
  const cardPath = join(here, '..', 'og.png');
  require(existsSync(cardPath), 'site/og.png is missing');
  const png = readFileSync(cardPath);
  require(png.readUInt32BE(12) === 0x49484452, 'site/og.png is not a PNG');
  const [rasterW, rasterH] = [png.readUInt32BE(16), png.readUInt32BE(20)];

  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  for (const [axis, real] of [['width', rasterW], ['height', rasterH]]) {
    const meta = new RegExp(`<meta property="og:image:${axis}" content="(\\d+)">`).exec(page);
    require(meta,
      `index.html declares no og:image:${axis} — a crawler sizes the unfurl's box before it `
      + 'fetches the card, and without this it guesses');
    require(Number(meta[1]) === real,
      `index.html tells crawlers the card is ${meta[1]}px ${axis} where site/og.png is `
      + `${real}px — every unfurl of this site is laid out from a number the image does not `
      + 'have, so the picture arrives letterboxed or cropped');
  }

  require(/<meta property="og:image:alt" content="[^"]+">/.test(page),
    'index.html declares no og:image:alt — the card is all a screen reader gets from an '
    + 'unfurl. What it SAYS cannot be checked here; that it exists can');
}

/**
 * A skip leans the way it went. Forward and back used to produce the identical
 * heave, so the ink said a track had changed but never which way you went.
 */
function aSkipLeansTheWayItWent() {
  const forward = compareFrames('surge-forward', (sim, check) => {
    sim.advance(SILENCE, 1 / 60);
    sim.surge(1, 1);
    for (let i = 0; i < 90; i++) { sim.advance(SILENCE, 1 / 60); check(i); }
  });
  const back = compareFrames('surge-back', (sim, check) => {
    sim.advance(SILENCE, 1 / 60);
    sim.surge(1, -1);
    for (let i = 0; i < 90; i++) { sim.advance(SILENCE, 1 / 60); check(i); }
  });
  // Both sims have drained to nothing after 90 frames of silence, which is the
  // point of the dump but useless for judging the lean. Measure the heave while
  // it is happening instead: agreeing with the Swift is not enough, because a
  // mirrored profile that had collapsed to one shape would match a golden dump
  // of that same collapse just as well.
  const lean = (direction) => {
    const sim = new FerrofluidSim();
    sim.advance(SILENCE, 1 / 60);
    sim.surge(1, direction);
    let low = 0;
    let high = 0;
    for (let i = 0; i < 40; i++) {
      sim.advance(SILENCE, 1 / 60);
      low += sim.sites.slice(0, 5).reduce((a, x) => a + x.height, 0);
      high += sim.sites.slice(-5).reduce((a, x) => a + x.height, 0);
    }
    return { low, high };
  };
  const ahead = lean(1);
  const behind = lean(-1);
  require(ahead.high > ahead.low,
    `a forward skip did not lean forward (${ahead.low.toFixed(3)} low vs ${ahead.high.toFixed(3)} high)`);
  require(behind.low > behind.high,
    `a back skip did not lean back (${behind.low.toFixed(3)} low vs ${behind.high.toFixed(3)} high)`);
  // The dump stops at 90 frames, where impact is still 0.0147 and the gate is
  // legitimately open. Run it out: "when the music stops it goes back in the
  // notch and holds completely still" is a claim the site makes in so many
  // words, so something has to hold it.
  require(!forward.isSettled,
    'the surge dump ends settled — 90 frames of silence should not have been enough');
  let frames = 0;
  while (!forward.isSettled && frames < 600) { forward.advance(SILENCE, 1 / 60); frames++; }
  require(forward.isSettled,
    `the reservoir never came back to rest (${frames + 90} frames of silence)`);
  // The gate closes on the frame that settles it; the loop retires on the next
  // one, which is where the Swift's clock also checks itself. After that the
  // renderer must genuinely stop rather than redraw a picture that cannot change.
  forward.advance(SILENCE, 1 / 60);
  require(forward.awake === false, 'the render loop never retired');
  forward.setPointer(0.4, 1);
  require(forward.awake === true && !forward.isSettled,
    'a retired loop cannot be woken — the pointer would move nothing');
}

/**
 * The ink follows the shell asymmetrically: slow to fill so it is visibly
 * behind the chrome, quick to drain so it beats the closing shell home rather
 * than being caught by the clip. And the open injects no energy — a panel
 * opening is not a drum hit.
 */
function theInkFollowsTheShellSlowlyAndLeavesQuickly() {
  const sim = compareFrames('open', (s, check) => {
    s.setOpen(true);
    for (let i = 0; i < 60; i++) { s.advance(SILENCE, 1 / 60); check(i); }
    s.setOpen(false);
    for (let i = 60; i < 120; i++) { s.advance(SILENCE, 1 / 60); check(i); }
  });
  require(sim.impact === 0 && sim.swell === 0,
    `opening the panel manufactured a beat (impact ${sim.impact}, swell ${sim.swell})`);

  // Measure the two rates against each other rather than trusting the dump.
  const fill = new FerrofluidSim();
  fill.setOpen(true);
  let toHalfOpen = 0;
  while (fill.inkOpen < 0.5 && toHalfOpen < 600) { fill.advance(SILENCE, 1 / 60); toHalfOpen++; }
  const drain = new FerrofluidSim();
  drain.setOpen(true);
  for (let i = 0; i < 600 && drain.inkOpen !== 1; i++) drain.advance(SILENCE, 1 / 60);
  drain.setOpen(false);
  let toHalfShut = 0;
  while (drain.inkOpen > 0.5 && toHalfShut < 600) { drain.advance(SILENCE, 1 / 60); toHalfShut++; }
  require(toHalfOpen > toHalfShut,
    `the ink did not fill slower than it drains (${toHalfOpen} frames in, ${toHalfShut} out)`);
}

/**
 * The swell trails the cursor. Setting the position directly made the bulge
 * teleport along the rim, tracking the pointer rigidly instead of being dragged
 * by it, which is the opposite of what a heavy liquid does.
 */
function theSwellTrailsTheCursor() {
  compareFrames('pointer', (sim, check) => {
    sim.setPointer(0.15, 1);
    for (let i = 0; i < 60; i++) { sim.advance(SILENCE, 1 / 60); check(i); }
    sim.setPointer(0.85, 1.4);
    for (let i = 60; i < 120; i++) { sim.advance(SILENCE, 1 / 60); check(i); }
    sim.setPointer(null);
    for (let i = 120; i < 180; i++) { sim.advance(SILENCE, 1 / 60); check(i); }
  });

  // The lag itself, which the dump would also show but only implicitly.
  const sim = new FerrofluidSim();
  sim.setPointer(0.15, 1);
  for (let i = 0; i < 120; i++) sim.advance(SILENCE, 1 / 60);
  sim.setPointer(0.85, 1);
  sim.advance(SILENCE, 1 / 60);
  require(sim.pointerRim < 0.3,
    `the swell teleported to the cursor in one frame (rim ${sim.pointerRim})`);
}

/** The fixed geometry cases the probe dumps: scalars, lobes, and every relaxed point. */
function theOutlineIsTheShippingOutline() {
  const rows = golden('geom');
  const heights = [0.94, 0.10, 0.00, 0.61, 0.00, 0.00, 0.33, 0.88,
    0.72, 0.00, 0.05, 0.00, 0.41, 0.00, 0.00, 0.19, 0.66];
  const fans = [0.31, -0.22, 0.08, -0.35, 0.17, 0.02, -0.11, 0.28,
    -0.30, 0.14, 0.36, -0.05, 0.21, -0.18, 0.09, 0.33, -0.27];
  const sites = [];
  for (let index = 0; index < SITE_COUNT; index++) {
    const position = (index + 0.5) / SITE_COUNT;
    sites.push({
      rim: position,
      band: Math.min(BAND_COUNT - 1, Math.floor(position * BAND_COUNT)),
      fan: fans[index],
      height: heights[index],
      field: 0,
      isUp: heights[index] > 0,
    });
  }

  const notch = { width: 185, height: 32 };
  const panel = { width: 640, height: 190 };
  const cases = [
    { openness: 0.0, swell: 0.42, raised: 0.30, pointerPull: 0.0, reduce: false },
    { openness: 0.35, swell: 0.42, raised: 0.30, pointerPull: 0.0, reduce: false },
    { openness: 1.0, swell: 0.42, raised: 0.30, pointerPull: 0.0, reduce: false },
    { openness: 1.0, swell: 0.00, raised: 0.00, pointerPull: 0.9, reduce: false },
    { openness: 1.0, swell: 0.42, raised: 0.30, pointerPull: 0.0, reduce: true },
  ];

  let row = 0;
  let comparedPoints = 0;
  let comparedLobes = 0;
  let signedError = 0;
  let signedTerms = 0;
  for (let caseIndex = 0; caseIndex < cases.length; caseIndex++) {
    const c = cases[caseIndex];
    const geometry = new Geometry(notch, panel, c.openness);
    const lobes = geometry.lobes(sites);

    const head = rows[row++].split(' ');
    require(head[0] === 'case' && Number(head[1]) === caseIndex,
      `geom: expected case ${caseIndex}, got "${rows[row - 1]}"`);
    const scalar = (label, value, offset) =>
      closeTo(value, Number(head[offset]), GEOM_TOLERANCE, `geom case ${caseIndex} ${label}`);
    scalar('total', geometry.total, 5);
    scalar('top', geometry.top, 7);
    scalar('sideRun', geometry.sideRun, 9);
    scalar('bottomRun', geometry.bottomRun, 11);
    scalar('arcRun', geometry.arcRun, 13);
    scalar('visibleTopU', geometry.visibleTopU, 15);
    require(lobes.length === Number(head[17]),
      `geom case ${caseIndex}: ${lobes.length} lobes, the Swift found ${head[17]}`);

    for (const lobe of lobes) {
      const g = rows[row++].split(' ');
      require(g[0] === 'lobe', `geom case ${caseIndex}: expected a lobe, got "${rows[row - 1]}"`);
      closeTo(lobe.seat, Number(g[1]), GEOM_TOLERANCE, `geom case ${caseIndex} lobe seat`);
      closeTo(lobe.height, Number(g[2]), GEOM_TOLERANCE, `geom case ${caseIndex} lobe height`);
      closeTo(lobe.spread, Number(g[3]), GEOM_TOLERANCE, `geom case ${caseIndex} lobe spread`);
      closeTo(lobe.reach, Number(g[4]), GEOM_TOLERANCE, `geom case ${caseIndex} lobe reach`);
      comparedLobes++;
    }

    const { points } = geometry.poolPoints((position, lateral, headroom, detail) =>
      geometry.displacement({
        reduce: c.reduce,
        position,
        lobes,
        swell: c.swell,
        raised: c.raised,
        lateral,
        detail,
        headroom,
        pointerRim: 0.62,
        pointerPull: c.pointerPull,
      }));

    for (const point of points) {
      const g = rows[row++].split(' ');
      require(g[0] === 'point',
        `geom case ${caseIndex}: expected a point, got "${rows[row - 1]}"`);
      const wantX = Number(g[1]);
      const wantY = Number(g[2]);
      closeTo(point.x, wantX, float32Ulp(wantX), `geom case ${caseIndex} point x`);
      closeTo(point.y, wantY, float32Ulp(wantY), `geom case ${caseIndex} point y`);
      signedError += (point.x - wantX) + (point.y - wantY);
      signedTerms += 2;
      comparedPoints++;
    }
  }
  // A tolerance wide enough to absorb Float storage is also wide enough to hide
  // a small constant offset, so the bias is measured too. Rounding is symmetric
  // about zero; a drifted constant is not.
  const bias = signedError / signedTerms;
  require(Math.abs(bias) < 1e-6,
    `the outline sits ${bias.toExponential(3)} off the Swift's on average — that is a drift, not rounding`);
  require(row === rows.length,
    `geom: read ${row} of ${rows.length} golden rows — the port skipped some`);
  // A comparison loop that runs zero times passes silently, which is the
  // vacuous-check shape this whole file exists to avoid.
  require(comparedPoints === cases.length * (Geometry.outlineSamples + 1),
    `geom: compared ${comparedPoints} points, expected ${cases.length * (Geometry.outlineSamples + 1)}`);
  require(comparedLobes > 40, `geom: only ${comparedLobes} lobes compared`);
}

/**
 * The surface normal turns with the surface.
 *
 * This is the one part of the renderer with no Swift counterpart: the app fills
 * a flat silhouette, so it never needs a normal, while the site lights one. The
 * temptation is to take it from `rim(at:)`, which is cheap and wrong — it is the
 * normal of the UNDISPLACED rim, so the highlight sits still while the liquid
 * moves under it. It is finite-differenced from the relaxed polyline instead.
 */
function theSurfaceNormalTurnsWithTheSurface() {
  const notch = { width: 185, height: 32 };
  const panel = { width: 640, height: 190 };
  const geometry = new Geometry(notch, panel, 1);

  // Flat first: with nothing driving it the finite-difference normal must agree
  // with the rim's own, which is what fixes the winding convention.
  const flat = geometry.poolPoints(() => 0);
  const regimes = [
    { label: 'left flank', position: 0.02, want: { dx: -1, dy: 0 } },
    { label: 'bottom run', position: 0.5, want: { dx: 0, dy: 1 } },
    { label: 'right flank', position: 0.98, want: { dx: 1, dy: 0 } },
  ];
  for (const regime of regimes) {
    const index = Math.round(regime.position * Geometry.outlineSamples);
    const n = flat.normals[index];
    closeTo(n.dx, regime.want.dx, 0.02, `flat normal on the ${regime.label} dx`);
    closeTo(n.dy, regime.want.dy, 0.02, `flat normal on the ${regime.label} dy`);
  }

  // Every normal is a unit vector, everywhere, in both regimes.
  const sites = [];
  for (let index = 0; index < SITE_COUNT; index++) {
    const position = (index + 0.5) / SITE_COUNT;
    sites.push({
      rim: position,
      band: Math.min(BAND_COUNT - 1, Math.floor(position * BAND_COUNT)),
      fan: 0.2,
      height: index === 8 ? 1.0 : 0.02,
      field: 0,
      isUp: index === 8,
    });
  }
  const lobes = geometry.lobes(sites);
  const driven = geometry.poolPoints((position, lateral, headroom, detail) =>
    geometry.displacement({
      position, lobes, swell: 0.5, raised: 0.2, lateral, detail, headroom,
    }));
  for (const set of [flat, driven]) {
    for (const n of set.normals) {
      closeTo(Math.hypot(n.dx, n.dy), 1, 1e-12, 'normal is not unit length');
    }
  }

  // The payload: under a single tall lobe the surface normal must swing away
  // from the rim's own — the displaced surface reports its own orientation,
  // not the resting rim's. (The rim specular this once lit was cut on sight —
  // it read as a dotted line of shine — but the normals are the ported
  // surface's own report and stay gated.)
  let worst = 0;
  for (let i = 0; i <= Geometry.outlineSamples; i++) {
    const rimNormal = geometry.rim(i / Geometry.outlineSamples).normal;
    const n = driven.normals[i];
    const dot = Math.min(1, Math.max(-1, n.dx * rimNormal.dx + n.dy * rimNormal.dy));
    worst = Math.max(worst, Math.acos(dot));
  }
  require(worst > 0.35,
    `the displaced normal never left the rim's own (worst swing ${(worst * 180 / Math.PI).toFixed(1)} degrees)`);
}

/**
 * Hysteresis: a peak holds after the hit and drains without ringing. It breaks
 * at 0.36 and does not collapse until 0.16 — if it released at the same value
 * it broke at, the crown would chatter on every band sitting near threshold.
 *
 * Both numbers in that sentence are now held, which only one of them was. The
 * COLLAPSE end has had a mutant since it was written: set it equal to the
 * critical field and the chatter this check exists to forbid shows up in the
 * decay loop below. The BREAK end had nothing. Its assertion was in a branch
 * that never runs, no mutant in the harness touched the constant, and a sweep
 * found the shipped 0.36 could be moved anywhere on [0.26, 0.42] with all
 * thirty-nine checks and every mutation run green — a page whose liquid stands
 * on quiet music, or never stands at all, passing everything.
 *
 * The break is held by a straddled pair of onsets at the top of the function
 * rather than by reading the constant back out of sim.js, which would have been
 * the same constant compared to itself.
 */
function aPeakHoldsBelowTheFieldThatRaisedIt() {
  // WHERE THE THRESHOLD ACTUALLY IS, which this check is named for and could
  // not see. `CRITICAL_FIELD` in sim.js could be moved anywhere from 0.26 to
  // 0.42 — measured by bisection — and the whole suite stayed green, the
  // mutation harness included; the nearest killers were 0.24 and 0.44, and
  // neither is this check. The assertion below that names the number is DEAD:
  // it sits in the `!before && site.isUp` branch of a decay from SILENCE, where
  // nothing ever rises again, so it has never once executed. Substituting
  // `require(false)` for it leaves this check green, which is how that was
  // established rather than supposed.
  //
  // So the threshold is straddled outright, by a pair of onsets differing only
  // in amplitude. `site.field` is a smoothed copy of the drive and never reads
  // `CRITICAL_FIELD` — the constant decides only whether a site STANDS — so the
  // guards below can spell 0.36 themselves and stay independent of the value
  // under test. That independence is the point: a guard that asks the thing it
  // is testing how far to look cannot fail, and this file has shipped that
  // exact shape before.
  const onsetTo = (amp) => {
    const probe = new FerrofluidSim();
    const drive = new Array(BAND_COUNT).fill(0);
    drive[0] = amp;
    for (let i = 0; i < 3; i++) probe.advance(SILENCE, 1 / 60);
    let reached = 0;
    let stood = false;
    for (let i = 0; i < 30; i++) {
      probe.advance(drive, 1 / 60);
      for (const site of probe.sites) {
        if (site.band !== 0) continue;
        reached = Math.max(reached, site.field);
        if (site.isUp) stood = true;
      }
    }
    return { reached, stood };
  };
  const under = onsetTo(0.032);
  const over = onsetTo(0.035);

  // The pair proves itself discriminating before it is used as evidence, and
  // the MARGINS are written down because they are what a later retune eats
  // without saying so: 0.3432 sits 0.0168 below the critical field and 0.3752
  // sits 0.0152 above it, a little over four percent either way. Tighter would
  // pin the constant harder and start failing on an honest change to the
  // smoothing; looser is the hole this closes. Swept afterwards rather than
  // predicted: the constant now survives on [0.3432, 0.3752) and is killed by
  // this check at every step outside it, where before it survived the whole of
  // [0.26, 0.42] and was killed only at 0.24 and 0.44, by two other checks.
  // The interval is half-open because each bound is a value the field REACHES,
  // and `field > CRITICAL_FIELD` is strict: at 0.3432 nothing stands and the
  // quiet case still passes, at 0.3752 nothing stands and the loud case fails.
  require(under.reached > 0.30 && under.reached < 0.36,
    `the quieter onset drives band 0 to ${under.reached.toFixed(4)}, which no longer sits just `
    + 'below the critical 0.36 — the pair has stopped straddling the threshold, and everything '
    + 'asserted after this is being asserted about a scenario that cannot see it');
  require(over.reached > 0.36 && over.reached < 0.39,
    `the louder onset drives band 0 to ${over.reached.toFixed(4)}, which no longer sits just `
    + 'above the critical 0.36 — the same failure from the other side, and the one that widens '
    + 'the band this check pins the constant to');

  require(!under.stood,
    `a site stood at field ${under.reached.toFixed(4)}, under the critical 0.36 — the surface `
    + 'breaks at a smaller field than the page is built around, so the crown stands on quiet '
    + 'music and the liquid never settles');
  require(over.stood,
    `nothing stood at field ${over.reached.toFixed(4)}, over the critical 0.36 — the surface `
    + 'needs a bigger field than the page is built around, so the loudest moments in the '
    + 'capture go by without a peak');

  // Only band 0 is driven. Sites are assigned bands by index, so this raises
  // the one or two sites sitting on band 0 and nothing else — and `allowed` is
  // never below 2, so the crown cap cannot be what knocks them down. Driving
  // every band instead makes the cap the likelier cause of any release and the
  // check stops being about hysteresis at all.
  const sim = new FerrofluidSim();
  const onset = new Array(BAND_COUNT).fill(0);
  onset[0] = 0.9;

  // Silence first, so the onset is an edge. A constant level — even a loud one
  // — produces no deviation and no kick, which is the entire point of the
  // per-band z-score and the reason a flat 0.9 raises nothing at all.
  for (let i = 0; i < 3; i++) sim.advance(SILENCE, 1 / 60);
  for (let i = 0; i < 5; i++) sim.advance(onset, 1 / 60);
  const watched = sim.sites
    .map((site, index) => ({ site, index }))
    .filter(({ site }) => site.band === 0);
  require(watched.length > 0, 'no site is driven by band 0');
  require(watched.some(({ site }) => site.isUp), 'the onset never broke the surface');

  const wasUp = new Map(watched.map(({ index }) => [index, sim.sites[index].isUp]));
  let heldBetween = false;

  for (let frame = 0; frame < 400; frame++) {
    sim.advance(SILENCE, 1 / 60);
    for (const { index } of watched) {
      const site = sim.sites[index];
      const before = wasUp.get(index);
      // A NET, not evidence, and it is worth the difference being written down.
      // This branch needs a site to RISE during a decay from silence, and one
      // never does — the assertion has never executed in this check's life, and
      // a `require(false)` in its place leaves the run green. What it would
      // catch is a future where the field can climb while the drive is gone.
      // The threshold itself is held by the straddled pair at the top of this
      // function, which is where the number is actually observed.
      if (!before && site.isUp) {
        require(site.field > 0.36,
          `a peak broke at field ${site.field.toFixed(4)}, below the critical 0.36`);
      }
      if (before && !site.isUp) {
        require(site.field < 0.16,
          `a peak released at field ${site.field.toFixed(4)}, above the collapse 0.16 — `
          + 'the hysteresis pair has collapsed to one value');
      }
      // The hold itself: standing while the field sits between the two.
      if (site.isUp && site.field > 0.16 && site.field < 0.36) heldBetween = true;
      wasUp.set(index, site.isUp);
    }
  }
  require(heldBetween,
    'no peak ever stood between the collapse and critical fields — there is no hysteresis to speak of');
  require(watched.every(({ index }) => !sim.sites[index].isUp),
    'a peak never came down at all');
}

/**
 * The crown is capped. `allowed = 2 + round(min(1, energy) * 7)` is what keeps
 * eight middling lobes from reading as a ripple; without it every band near
 * threshold stands at once and the surface is a comb.
 */
function theCrownIsCapped() {
  const sim = new FerrofluidSim();
  let worst = 0;
  REAL_LEVELS.forEach((levels) => {
    sim.advance(levels, 1 / 60);
    worst = Math.max(worst, sim.standingCount);
  });
  require(worst <= 9, `${worst} peaks stood at once, above the cap of 9`);
  require(worst >= 2, `the crown never broke at all during the replay (${worst})`);

  // Held loudness must raise nothing: the drive measures each band's change
  // against its own 2.5-second baseline, so a constant tone is a non-event
  // however loud it is.
  //
  // 0.8, not 0.7, and the difference is the whole check. A drive that read the
  // level directly would produce `raw = level * 0.5`, which at 0.7 is 0.35 —
  // just under the 0.36 critical field, so nothing would stand and this would
  // pass against exactly the defect it exists to catch. It was written at 0.7
  // first and a mutation caught it. At 0.8 the mutant stands eight peaks.
  //
  // The margin is 0.04, and it is the check's whole premise, so it is held here
  // rather than hoped for: a critical field raised past 0.40 fails by name
  // instead of leaving the count below unable to fail. `0.5` restates the dev
  // weight in updateSites (`dev * 0.5 + kick * 0.8`); if that weight ever
  // moves, this fails red rather than passing green, the safe direction for a
  // guard. (`aPeakHoldsBelowTheFieldThatRaisedIt` also pins the field to a
  // band under 0.40, but a check's premise belongs in the check that relies
  // on it — solo is where the harness proves ownership.)
  const heldLevel = 0.8;
  const levelReadingDrive = heldLevel * 0.5;
  const margin = levelReadingDrive - CRITICAL_FIELD;
  require(margin >= 0.01,
    `held level ${heldLevel} gives a level-reading drive of ${levelReadingDrive.toFixed(3)}, only `
    + `${margin.toFixed(3)} above the critical field ${CRITICAL_FIELD} — below 0.01 the count `
    + 'below cannot fail');
  const flat = new FerrofluidSim();
  const held = new Array(BAND_COUNT).fill(heldLevel);
  for (let i = 0; i < 60 * 8; i++) flat.advance(held, 1 / 60);
  require(flat.standingCount <= 2,
    `held loudness left ${flat.standingCount} peaks standing — the drive is reading level, not change`);
  require(flat.swell < 0.15, `held loudness kept the pool swollen (${flat.swell})`);
}

/**
 * The halo eases rather than switching. The gate is a hard threshold, so the
 * bloom used to appear and vanish at alpha 0.1868 in a single frame — the
 * largest per-frame change anywhere in the effect was the moment it switched
 * off, which reads as a bug rather than as light.
 */
function theHaloEasesRatherThanSwitching() {
  require(glowAlpha(0.14, 1) === 0, 'the halo is lit at the gate');
  require(glowAlpha(0.5, 0) === 0, 'the halo is lit on a closed panel');
  let worst = 0;
  let previous = glowAlpha(0, 1);
  for (let i = 1; i <= 2000; i++) {
    const value = glowAlpha(i / 2000, 1);
    worst = Math.max(worst, Math.abs(value - previous));
    previous = value;
  }
  require(worst < 0.05,
    `the halo's worst step is ${worst.toFixed(4)} — it is switching, not fading`);
  // The tuned values the Swift records, unchanged to the digit.
  closeTo(glowAlpha(1, 1), 0.72, 5e-5, 'glowAlpha(1, 1)');
  closeTo(glowAlpha(0.5, 1), 0.41, 5e-5, 'glowAlpha(0.5, 1)');
}

/**
 * The ambient motion is the app's own captured audio, and the replay seam is
 * the quietest frame in the set. A hand-pasted copy of the levels is how the
 * site ends up claiming "real captured audio" about something else.
 */
function theCapturedAudioIsTheAppsOwn() {
  const source = loadSourceLevels();
  require(source.length === REAL_LEVELS.length,
    `the site carries ${REAL_LEVELS.length} frames, Resources/real-levels.txt has ${source.length}`);
  require(REAL_LEVELS.length === 240, `expected 240 frames, found ${REAL_LEVELS.length}`);
  for (let i = 0; i < source.length; i++) {
    require(source[i].length === BAND_COUNT, `frame ${i} is not ${BAND_COUNT} bands`);
    for (let b = 0; b < BAND_COUNT; b++) {
      closeTo(REAL_LEVELS[i][b], source[i][b], 1e-12, `captured frame ${i} band ${b}`);
    }
  }
  const quietest = quietestFrame(source);
  require(LOOP_FRAME === quietest.index,
    `the replay loops at frame ${LOOP_FRAME}, but the quietest frame is ${quietest.index}`);
}

/**
 * The page's download buttons, counted as ELEMENTS.
 *
 * The shipped form matched the bare attribute name anywhere in the file, which
 * counts every mention of it in a comment as another button. That is not a
 * pedantic risk: the two checks below are the ones that keep the page's only
 * link honest, and both of them compare the count of buttons against the count
 * of requirement lines — so a sentence in a comment explaining the attribute
 * fails the build, and the obvious way to make the build pass again is to add a
 * requirement line the page does not need.
 */
function countDownloadButtons(page) {
  return (page.match(/<[^>!]*\sdata-download[\s=>]/g) || []).length;
}

/**
 * The requirement lines, as the text of the paragraphs that carry them.
 *
 * Anchored to `<p`, and stopping at the first tag rather than at the first
 * `</p>`. Unanchored, an attribute on any other element runs the match forward
 * to whatever paragraph happens to come next — and that paragraph, being the
 * real requirement line, still contains "macOS 26" and "534 KB", so every
 * assertion downstream goes green while the gate is reading a span of the page
 * nobody wrote as a claim about the build.
 */
function requirementLines(page) {
  return [...page.matchAll(/<p[^>]*\sdata-requires[^>]*>([^<]*)<\/p>/g)]
    .map((m) => m[1].replace(/\s+/g, ' ').trim());
}

/**
 * The floor the page prints is the floor the build declares.
 *
 * `Package.swift` decides whether the artifact `build.sh` produces will launch
 * at all, so it — not a comment in AudioTap, not anyone's memory of which
 * CoreAudio symbol arrived when — is the only honest source for the line under
 * a download button. The tap's own floor is a question about the *code*; this
 * is a question about the *artifact*, and only the manifest answers it.
 *
 * The one-page site prints the floor once. The agreement assertions below are
 * kept anyway, because the failure they exist for is the asymmetric one — a
 * page that promised 26 beside one button and something else beside another
 * told half its readers the truth, which is the half that does not file the
 * bug — and the second button is one edit away from coming back.
 */
function theStatedFloorIsTheBuildsFloor() {
  const manifest = readFileSync(join(here, '..', '..', 'Package.swift'), 'utf8');
  const declared = /platforms:\s*\[\s*\.macOS\("(\d+)(?:\.\d+)*"\)/.exec(manifest);
  require(declared, 'could not find the macOS platform floor in Package.swift');
  const floor = declared[1];

  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  const buttons = countDownloadButtons(page);
  const stated = requirementLines(page);

  // A page with no download button would satisfy every assertion below
  // vacuously, which is the shape this repo has shipped before.
  require(buttons >= 1, `expected at least one download button, found ${buttons}`);
  require(stated.length === buttons,
    `the page has ${buttons} download buttons but ${stated.length} requirement lines`);

  for (const line of stated) {
    const printed = /macOS (\d+)/.exec(line);
    require(printed, `a requirement line prints no macOS version: "${line}"`);
    require(printed[1] === floor,
      `the page promises macOS ${printed[1]}, Package.swift declares ${floor}: "${line}"`);
  }

  // The HARDWARE clause, which used to disagree with itself: the hero said
  // "Apple silicon" and the download sheet said "MacBook with a notch". Only
  // one of those can be the requirement, and it was the looser one — the app
  // handles a notchless display by drawing a pill, so a notch was never a gate.
  // Two buttons for one build must ask for the same machine.
  //
  // The machine is the clause right after the OS — "macOS 26 on Apple silicon."
  // or "macOS 26 · Apple silicon ·" — up to the next sentence stop or dot
  // separator. It is required to be non-empty: this used to split on `·` alone,
  // the redesigned line has none, and the notch rule below went on reading an
  // empty string and passing whatever the page demanded.
  const hardware = stated.map((line) => line.slice(line.search(/macOS \d+/))
    .replace(/^macOS \d+(?:\.\d+)*\s*(?:·|\bon\b)?\s*/, '')
    .split(/[.·]/)[0].trim());
  require(hardware.every(Boolean),
    `a requirement line names no machine after its macOS version: "${stated[hardware.indexOf('')]}"`);
  const distinct = [...new Set(hardware)];
  require(distinct.length === 1,
    `the download buttons ask for different machines: ${distinct.map((h) => `"${h}"`).join(' vs ')}`);

  // And it must be a claim the build can actually keep. A notch requirement is
  // false while ScreenMetrics has a no-notch branch, so the gate reads the
  // Swift rather than trusting the copy.
  const metrics = readFileSync(
    join(here, '..', '..', 'Sources', 'NotchApp', 'Notch', 'ScreenMetrics.swift'), 'utf8');
  const hasPillFallback = /notchRect\(for: screen\) == nil \? \.pill/.test(metrics);
  if (hasPillFallback) {
    require(!/notch/i.test(distinct[0]),
      `the page requires "${distinct[0]}", but ScreenMetrics falls back to a pill `
      + 'when there is no notch, so the app runs without one');
  }
}

/**
 * The download button points at the versioned GitHub Release, while the exact
 * asset being published exists locally and the page says its true size.
 *
 * A marketing page whose primary call to action 404s is worse than one with no
 * button at all, and nothing else in this repo would notice: the HTML is valid,
 * the CSS is fine, and the link is only wrong in the one way that matters. The
 * The release tag and local filename both carry the app version, so either can
 * drift when the app is bumped and the page is forgotten.
 */
function theDownloadLinkPointsAtARealBuild() {
  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  const root = join(here, '..', '..');

  const tags = [...page.matchAll(/<a\b[^>]*\bdata-download\b[^>]*>/g)].map((m) => m[0]);
  require(tags.length === 1,
    `the page exposes ${tags.length} release links instead of one primary call to action`);
  const href = /\bhref="([^"]+)"/.exec(tags[0])?.[1];
  require(href, 'the release control has no href');
  require(/\brel="[^"]*\bexternal\b[^"]*"/.test(tags[0]),
    'the GitHub Release control is not identified as an external destination');
  // The version in the filename is the app's own, read out of the bundle's
  // Info.plist rather than trusted — and so is the one the button's name reads
  // aloud, which was a literal here and would have gone stale on every bump.
  const plist = readFileSync(join(root, 'Resources', 'Info.plist'), 'utf8');
  const version = /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/.exec(plist);
  require(version, 'could not find CFBundleShortVersionString in Info.plist');
  const named = `Download<span class="visually-hidden">, Magnetite v${version[1]} on GitHub</span>`;
  require(new RegExp(`data-download[^>]*>\\s*${named.replace(/[.*+?^${}()|[\]\\/]/g, '\\$&')}`).test(page),
    `the primary call to action does not plainly say Download for v${version[1]}`);

  const want = `https://github.com/scryst/magnetite-releases/releases/tag/v${version[1]}`;
  require(href === want,
    `the page links ${href}, but the personal release for app ${version[1]} is ${want}`);

  const onDisk = join(here, '..', 'downloads', `Magnetite-${version[1]}.zip`);
  require(existsSync(onDisk), `the v${version[1]} release asset is absent at ${onDisk}`);

  const structured = /<script type="application\/ld\+json">\s*([\s\S]*?)\s*<\/script>/.exec(page);
  require(structured, 'the page has no SoftwareApplication metadata');
  let metadata;
  try { metadata = JSON.parse(structured[1]); } catch { metadata = null; }
  require(metadata?.['@type'] === 'SoftwareApplication'
      && metadata.softwareVersion === version[1]
      && metadata.downloadUrl === want
      && metadata.author?.name === 'scryst',
  'the SoftwareApplication metadata does not name the personal, versioned GitHub Release');
  const publicRoot = 'https://magnetite.app/';
  const customDomain = readFileSync(join(here, '..', 'CNAME'), 'utf8').trim();
  require(page.includes(`<link rel="canonical" href="${publicRoot}">`)
      && page.includes(`<meta property="og:url" content="${publicRoot}">`)
      && page.includes(`<meta property="og:image" content="${publicRoot}og.png">`)
      && page.includes(`<meta name="twitter:image" content="${publicRoot}og.png">`)
      && customDomain === 'magnetite.app'
      && !/vercel\.app/.test(page),
  'canonical and share metadata do not point exclusively at magnetite.app');

  // And the size it prints is the size it is. Stated in KB, so a kilobyte of
  // slack either way is rounding, not drift.
  // `require` rather than `closeTo` here: closeTo's message says "the Swift
  // says", which is true of every other comparison in this file and a lie about
  // this one. A gate that reports the wrong reason is most of the way to being
  // a gate nobody trusts.
  const actualKB = statSync(onDisk).size / 1024;
  // Scoped to the requirement lines, not to the whole file. Matching the first
  // "KB" anywhere in index.html meant any comment that happened to mention a
  // size — a note about the weight of the webfonts, say — was read as the
  // page's claim about the build, and the gate failed on prose it should never
  // have been looking at. A check that reads the wrong text is not a check.
  const printed = requirementLines(page)
    .map((line) => /([\d.]+)\s*KB/.exec(line))
    .find(Boolean);
  require(printed, 'no requirement line prints the download size');
  require(Math.abs(parseFloat(printed[1]) - actualKB) <= 1.5,
    `the page says ${printed[1]} KB, the build on disk is ${actualKB.toFixed(0)} KB`);
}

/** The source carries its own field notes; the rendered page carries none of them. */
function theFieldNotesStayInTheSource() {
  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  const fieldNotes = /<!--\s*MAGNETITE FIELD NOTES([\s\S]*?)-->/.exec(page)?.[1];
  require(fieldNotes?.includes('01 / Fe3O4 is ferrimagnetic.')
      && fieldNotes.includes("02 / The liquid is rendered from the app's own audio capture.")
      && fieldNotes.includes('The player in the middle is the only film on this page.')
      && fieldNotes.includes('03 / A personal project by scryst. No trackers. No frameworks.'),
  'the inspectable Magnetite field notes are missing or incomplete');
  require(/<p class="foot__formula">Fe<sub>3<\/sub>O<sub>4<\/sub><\/p>/.test(page)
      && !/<a\b[^>]*class="foot__formula"/.test(page),
  'the footer formula is masquerading as the Easter egg instead of remaining a quiet mark');
}


/**
 * Search engines get one canonical product page, a sitemap that names it, and
 * structured data that describes the same free Mac app. None of these should
 * create a second URL or a second download authority.
 */
function theSiteIsCrawlableAtItsCanonicalDomain() {
  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  const robots = readFileSync(join(here, '..', 'robots.txt'), 'utf8');
  const sitemap = readFileSync(join(here, '..', 'sitemap.xml'), 'utf8');
  const llms = readFileSync(join(here, '..', 'llms.txt'), 'utf8');
  const publicRoot = 'https://magnetite.app/';
  const structured = /<script type="application\/ld\+json">\s*([\s\S]*?)\s*<\/script>/.exec(page);
  let metadata;
  try { metadata = JSON.parse(structured?.[1]); } catch { metadata = null; }

  require(/<title>Magnetite[^<]*MacBook notch<\/title>/.test(page),
    'the search title does not say that Magnetite is a MacBook-notch product');
  require(metadata?.url === publicRoot
      && metadata.image === `${publicRoot}og.png`
      && metadata.screenshot === `${publicRoot}og.png`
      && metadata.isAccessibleForFree === true
      && Array.isArray(metadata.featureList)
      && metadata.featureList.includes('On-device audio processing with no tracking'),
  'the SoftwareApplication metadata does not describe the free product and its visible demo');
  require(robots.includes(`Sitemap: ${publicRoot}sitemap.xml`),
    'robots.txt does not point crawlers at the canonical sitemap');
  require((sitemap.match(/<url>/g) || []).length === 1
      && sitemap.includes(`<loc>${publicRoot}</loc>`),
  'the sitemap does not contain exactly the canonical product page');
  require(!/github\.io|vercel\.app/.test(sitemap),
    'the sitemap exposes a deployment host instead of magnetite.app');
  require(llms.startsWith('# Magnetite\n\n> A free, native macOS music player')
      && llms.includes('[Live demo](https://magnetite.app/)')
      && llms.includes(`[Magnetite v${metadata?.softwareVersion}](${metadata?.downloadUrl})`)
      && llms.includes('[Privacy](https://magnetite.app/privacy.html)')
      && llms.includes('[Terms](https://magnetite.app/terms.html)')
      && llms.includes('Downloading, installing, connecting a music account, and granting macOS permissions are human actions')
      && !/github\.io|vercel\.app/.test(llms),
  'llms.txt does not map agents to the current canonical, human-gated product');
}

/** The public trust pages state the app's real data and distribution boundaries. */
function thePoliciesStateTheActualBoundaries() {
  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  const privacy = readFileSync(join(here, '..', 'privacy.html'), 'utf8');
  const terms = readFileSync(join(here, '..', 'terms.html'), 'utf8');
  const security = readFileSync(join(here, '..', '.well-known', 'security.txt'), 'utf8');
  const securityExpiry = /^Expires: (\S+)$/m.exec(security)?.[1];

  require(page.includes('<a href="privacy.html">Privacy</a>')
      && page.includes('<a href="terms.html">Terms</a>'),
  'the product page does not expose both trust pages from its quiet footer');
  require(privacy.includes('<link rel="canonical" href="https://magnetite.app/privacy.html">')
      && terms.includes('<link rel="canonical" href="https://magnetite.app/terms.html">'),
  'a trust page does not belong to the canonical personal domain');
  require(!/<script\b/i.test(`${privacy}\n${terms}`),
    'a static trust page loads script instead of remaining inspectable text');
  require(privacy.includes('does not upload or save the audio.')
      && privacy.includes("download the current track's artwork")
      && privacy.includes('owner-only\n    file permissions')
      && privacy.includes('aggregate traffic, referral, star, and download\n    counts')
      && privacy.includes('no visitor profiles or in-app\n    events'),
  'the privacy page does not state the actual audio, credential, and aggregate-count boundaries');
  require(terms.includes('<a href="https://github.com/scryst/magnetite/blob/main/LICENSE" rel="external">MIT License</a>')
      && terms.includes('<a href="https://github.com/scryst/magnetite" rel="external">source code</a>')
      && terms.includes('Copyright © 2026 scryst')
      && terms.includes('not affiliated with or\n    endorsed by Spotify, Apple, or GitHub.'),
  'the terms do not state the MIT License, scryst\'s copyright, the source repository and the '
    + 'third-party affiliation boundary');
  require(security.includes('Contact: mailto:scrystyt@gmail.com')
      && security.includes('Canonical: https://magnetite.app/.well-known/security.txt')
      && security.includes('Policy: https://github.com/scryst/magnetite-releases/security/policy')
      && Number.isFinite(Date.parse(securityExpiry))
      && Date.parse(securityExpiry) > Date.now(),
  'security.txt does not point security reports at the canonical personal policy');
}

/**
 * The page's one typeface, Gloock, is a small, licensed first-party asset. A
 * privacy claim beside a runtime request to a font host is a distinction
 * visitors cannot inspect, and an extra origin is an avoidable dependency in
 * the first paint. The font directory ships whole, so every file in it is a
 * face the stylesheet uses or that face's licence — a face left behind by a
 * redesign is weight and a licence obligation for nothing.
 */
function theTypeLoadsFromTheSiteItBelongsTo() {
  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  const css = readFileSync(join(here, '..', 'css', 'magnetite.css'), 'utf8');
  const type = readFileSync(join(here, '..', 'css', 'type.css'), 'utf8');

  require(!/fonts\.(?:googleapis|gstatic)\.com/.test(`${page}\n${css}\n${type}`),
    'the first-party page still asks a Google font host for its type');
  require(page.includes('<link rel="stylesheet" href="css/type.css">'),
    'the page does not load its first-party type stylesheet');
  require(!/@font-face/.test(css), 'magnetite.css declares a face outside type.css');

  const families = [...type.matchAll(/font-family:\s*'([^']+)'/g)].map((m) => m[1]);
  require(families.length === 1 && families[0] === 'Gloock',
    `type.css declares ${families.join(', ') || 'no face'} where the page ships one, Gloock`);

  const shipped = readdirSync(join(here, '..', 'fonts'));
  const faces = shipped.filter((name) => name.endsWith('.woff2'));
  require(faces.length === 1,
    `site/fonts ships ${faces.length} faces (${faces.join(', ')}) where the page sets one`);
  for (const name of faces) {
    const bytes = readFileSync(join(here, '..', 'fonts', name));
    require(type.includes(`url('../fonts/${name}') format('woff2')`),
      `${name} exists but the shipping stylesheet does not use it`);
    require(bytes.subarray(0, 4).toString('ascii') === 'wOF2' && bytes.length < 30_000,
      `${name} is not a small WOFF2 subset`);
  }

  const license = `OFL-${families[0]}.txt`;
  const stray = shipped.filter((name) => !faces.includes(name) && name !== license);
  require(stray.length === 0,
    `site/fonts ships ${stray.join(', ')}, which is neither the face the page sets nor its licence`);
  require(shipped.includes(license)
      && readFileSync(join(here, '..', 'fonts', license), 'utf8')
        .includes('SIL OPEN FONT LICENSE Version 1.1'),
  `${license} does not carry the font's distribution terms beside it`);
}

/**
 * The page's first-launch story matches the build it serves.
 *
 * An ad-hoc build is Gatekeeper-rejected by design — build.sh says so in as
 * many words — and the rejection dialog offers Move to Trash and Done, nothing
 * else. So the one thing the page must do is say what the dialog will not:
 * where Open Anyway lives. And the moment a notarised build lands in
 * downloads/, the same paragraph becomes the opposite defect — a walkthrough
 * for a dialog no visitor sees, reading as a warning that the download is
 * broken. The stapled ticket is a file with a name, Contents/CodeResources at
 * the bundle root, and a zip stores its entry names in the clear, so the
 * archive itself answers which page is the honest one.
 */
function theFirstLaunchStoryMatchesTheBuild() {
  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  const plist = readFileSync(join(here, '..', '..', 'Resources', 'Info.plist'), 'utf8');
  const version = /<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/.exec(plist);
  require(version, 'could not find the app version for the first-launch story');
  const artifact = join(here, '..', 'downloads', `Magnetite-${version[1]}.zip`);
  require(existsSync(artifact), 'there is no local release asset for the first-launch story');
  const zip = readFileSync(artifact);
  const notarised = zip.includes('Magnetite.app/Contents/CodeResources');

  // Anchored like requirementLines, for the same reason: the paragraph must be
  // read as written, not whatever text follows some other element.
  const guidance = [...page.matchAll(/<p[^>]*\sdata-firstlaunch[^>]*>([^<]*)<\/p>/g)]
    .map((m) => m[1].replace(/\s+/g, ' ').trim());

  if (notarised) {
    require(guidance.length === 0,
      'downloads/ carries a stapled notarisation ticket, but the page still walks '
      + 'visitors through Open Anyway — guidance for a dialog they will never see, '
      + 'reading as a warning that the download is broken');
  } else {
    require(guidance.length >= 1,
      'the served zip has no stapled ticket, so Gatekeeper blocks first launch with '
      + 'a dialog that offers no way forward — and the page never says where Open '
      + 'Anyway lives');
    require(/Privacy &amp; Security/.test(guidance[0]) && /Open Anyway/.test(guidance[0]),
      'the first-launch note does not name the route the dialog hides — System '
      + `Settings › Privacy & Security › Open Anyway: "${guidance[0]}"`);
  }
}

/**
 * The page runs one frame loop, not one per tab switch.
 *
 * `frame` guards on a `running` flag, which reads as sufficient and is not. A
 * callback queued before the tab is hidden is never serviced while it is
 * hidden, so it is still pending when the page returns — and the
 * `visibilitychange` handler sets `running` back to true in the same event,
 * before that stale callback gets its turn. It then finds the flag true, runs,
 * and queues a successor of its own. Measured against the deployed bundle: 1,
 * 2, then 3 concurrent loops after one, two and three hide/show cycles, with
 * no self-healing. The physics is unharmed — the second callback of a pair
 * reads a dt of zero — so the only symptom is that every visible canvas
 * rebuilds its 145-sample outline N times a frame, which is precisely the cost
 * the on-screen gating was written to avoid.
 *
 * The property is that the handle is HELD and CANCELLED, not where the cancel
 * is written: doing it in `stop` and doing it at the top of `start` are both
 * correct, and so is any name for the handle.
 */
function theFrameLoopCannotRunTwice() {
  const source = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');

  const queues = [...source.matchAll(/requestAnimationFrame\s*\(/g)];
  require(queues.length > 0, 'site.js no longer queues an animation frame at all');

  const held = [...source.matchAll(/(\w+)\s*=\s*requestAnimationFrame\s*\(/g)].map((m) => m[1]);
  require(held.length === queues.length,
    `site.js queues ${queues.length} animation frames but keeps the handle of only ${held.length} — `
    + 'a frame nobody holds is a frame nobody can cancel');

  const handle = held[0];
  require(held.every((name) => name === handle),
    `site.js stores its frame handle under more than one name (${[...new Set(held)].join(', ')}), `
    + 'so cancelling one leaves the other running');

  require(new RegExp(`cancelAnimationFrame\\s*\\(\\s*${handle}\\s*\\)`).test(source),
    `site.js never cancels \`${handle}\` — a hidden tab leaves its queued frame pending, and the `
    + 'restart adds a second loop beside it, once per hide/show cycle');
}

/**
 * The body of a top-level function, by brace matching from its opening `{`.
 *
 * Regex to the closing brace would stop at the first `}` inside the function,
 * and every assertion below is about what happens INSIDE one particular
 * function: site.js steps the sim in `frame` and paints the still in
 * `renderStill`, so a check that reads the whole file cannot tell which of the
 * two it is looking at.
 */
function functionBody(source, name) {
  const open = source.search(new RegExp(`\\nfunction\\s+${name}\\s*\\(`));
  if (open < 0) return null;
  const brace = source.indexOf('{', open);
  let depth = 0;
  for (let j = brace; j < source.length; j++) {
    if (source[j] === '{') depth++;
    else if (source[j] === '}' && --depth === 0) return source.slice(brace + 1, j);
  }
  return null;
}

/**
 * The balanced `{ … }` block starting at or after `from`, without its braces.
 *
 * Brace-matched for the same reason `guardCondition` is: the bodies worth
 * reading here contain nested blocks, and `\{([\s\S]*?)\}` stops at the first
 * inner one.
 */
function braceBlock(source, from) {
  const brace = source.indexOf('{', from);
  if (brace < 0) return null;
  let depth = 0;
  for (let j = brace; j < source.length; j++) {
    if (source[j] === '{') depth++;
    else if (source[j] === '}' && --depth === 0) return source.slice(brace + 1, j);
  }
  return null;
}

/**
 * The page's own replay cadence, read out of site.js rather than restated.
 *
 * A captured frame is held for `SIM_HZ / CAPTURE_HZ` steps of `1 / SIM_HZ`,
 * with the drive low-passed once per STEP — the loop `frame()` and
 * `renderStill()` share, and whose shape `theReplayIsSteppedLikeTheApp` pins.
 * All three numbers are read, because all three are copies: a check that writes
 * down `1 / 60` and one step per captured frame measures a fluid nothing draws.
 *
 * The three CONSTANTS are still read out of the source — they have to be, and
 * `theCaptureIsReplayedAtItsOwnRate` holds them to the app. What is no longer
 * read is the arithmetic on them: this used to rebuild `dt`, the hold count and
 * the low pass's rate here, which is the same shape as the defect it exists to
 * catch. Rebuilding what the source asked for agrees with a source that has
 * drifted, and `const dt = 2 / SIM_HZ` in `renderStill` proved it — forty
 * checks green, the still's outline 12.3 points out. `replayCadence` is the
 * page's own derivation, driven.
 */
function pageReplay() {
  const site = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');
  const simHz = Number(site.match(/^const SIM_HZ = ([\d.]+);/m)?.[1]);
  const captureHz = Number(site.match(/^const CAPTURE_HZ = ([\d.]+);/m)?.[1]);
  const tau = Number(site.match(/^const SMOOTH_TAU = ([\d.]+);/m)?.[1]);
  require(Number.isFinite(simHz) && Number.isFinite(captureHz) && Number.isFinite(tau),
    'site.js no longer declares SIM_HZ / CAPTURE_HZ / SMOOTH_TAU at the top level, so the page\'s '
    + 'replay cannot be reproduced here');
  const cadence = replayCadence(simHz, captureHz, tau);
  require(cadence.steps >= 1,
    `site.js replays a ${captureHz}Hz capture on a ${simHz}Hz clock, which holds no frame at all`);
  return { ...cadence, simHz, captureHz, tau };
}

/**
 * A module's source with its comments taken out.
 *
 * Only ever used to count things the page DOES. site.js's prose names calls it
 * no longer makes — naming the thing it stopped doing is most of why a comment
 * is worth reading — and a check that greps the raw file counts the
 * explanation as a second call.
 *
 * Assumes no `//` or `/*` inside a string or a regex literal, which holds for
 * site.js and is asserted below by requiring the stripped source to still
 * contain the statements the caller is about to read.
 */
function codeOnly(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ');
}

/**
 * The soundtrack drives the same bands as the app.
 *
 * The page asks to play its music as it loads, from circles fixed to the foot
 * of the window (Laks, 2026-09-23: persistent on screen, playing on load, and
 * "just circles" to play, pause and switch songs). What
 * stays the visitor's is the pause: the markup never starts the element
 * itself, the page's script does, and a visitor who paused is remembered and
 * not played at again — nor made to download the tracks. Every named track is
 * a real local asset with its own sleeve, and the audio thread runs the
 * checked browser port rather than a Web Audio analyser with unrelated
 * defaults. The page keeps its captured replay as the fallback; after the
 * worklet is live it pumps those bands at the capture cadence and decays
 * honestly when the audio pauses.
 */
function theSoundtrackUsesTheAppsBands() {
  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  const css = readFileSync(join(here, '..', 'css', 'magnetite.css'), 'utf8');
  const code = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');
  const playerCode = readFileSync(join(here, '..', 'js', 'player.js'), 'utf8');
  const worklet = readFileSync(join(here, '..', 'js', 'bands-worklet.js'), 'utf8');

  const audio = /<audio\b[^>]*data-soundtrack-audio[^>]*>/s.exec(page)?.[0];
  require(audio && !/\bautoplay\b/.test(audio),
    'the soundtrack is missing, or its markup starts it — the page\'s script is what starts it, '
    + 'because the script is what remembers a visitor\'s pause');
  require(/\bpreload="none"/.test(audio),
    'the soundtrack downloads audio before the page has asked to play it — a visitor who paused '
    + 'on an earlier visit would be sent the tracks anyway');
  require(!/soundtrack__(?:invitation|eyebrow|prompt|deck)|class="listen\b/.test(page + css),
    'the soundtrack has regrown promo headings, a ruled deck, or a second transport beside its circles');

  // The button's name is what pressing it does, and it is the only statement
  // of state: a pressed-state on top of a name that changes made a screen
  // reader say "Pause, pressed", which describes two different buttons.
  const toggle = /<button\b[^>]*data-soundtrack-toggle[^>]*>[\s\S]*?<\/button>/.exec(page)?.[0];
  require(toggle && !/\baria-pressed=/.test(toggle) && !/\baria-label=/.test(toggle)
      && [...toggle.matchAll(/<svg\b[^>]*>/g)].every((svg) => /aria-hidden="true"/.test(svg[0]))
      && /data-soundtrack-toggle-label>Play</.test(toggle),
  'the audio transport is not a Play control named by its own label, its glyphs hidden');
  require(/ferrofluid that moves to whatever your Mac is playing/.test(page),
    'the page no longer says what the sound drives');
  // One circle per track, named by the track's own title — which is also what
  // the status line announces, so they cannot disagree — and pressed while it
  // is the one playing: the first, which the audio element starts on.
  const trackTags = [...page.matchAll(
    /<button\b[^>]*data-soundtrack-track[^>]*>[\s\S]*?<\/button>/g,
  )].map((match) => match[0]);
  require(trackTags.length === 2,
    `the soundtrack offers ${trackTags.length} tracks rather than the approved pair`);
  require(trackTags.every((tag) => {
    const title = /data-title="([^"]+)"/.exec(tag)?.[1];
    const text = tag.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
    return title && text === title && /data-artist="[^"]+"/.test(tag) && !/\baria-label=/.test(tag);
  }), 'a track circle is not named by its own title, or has no artist');
  const pressed = trackTags.map((tag) => /\baria-pressed="(true|false)"/.exec(tag)?.[1]);
  require(pressed[0] === 'true' && pressed.slice(1).every((state) => state === 'false'),
    'the track circles do not mark the first — the one the audio starts on — as the one playing');
  require(/player\?\.show\(soundtrackIndex\);/.test(code)
      && /setAttribute\('aria-pressed', String\(i === index\)\)/.test(playerCode),
  'choosing a track does not move the pressed state to the circle now playing');

  const sources = trackTags.map((tag) => /data-src="([^"]+)"/.exec(tag)?.[1]);
  require(sources.every(Boolean) && new Set(sources).size === sources.length,
    'a track circle has no source or both entries point at the same track');
  require(/\bsrc="([^"]+)"/.exec(audio)?.[1] === sources[0],
    'the audio element does not start on the first track the circles show');
  for (const source of sources) {
    const path = join(here, '..', source);
    const bytes = existsSync(path) ? readFileSync(path) : null;
    const mp3 = bytes && (bytes.subarray(0, 3).toString() === 'ID3'
      || (bytes[0] === 0xff && (bytes[1] & 0xe0) === 0xe0));
    require(!source.includes('..') && mp3 && statSync(path).size > 1_000_000,
      `${source} is not a real local MP3 soundtrack asset`);
  }
  // Each circle shows its track's sleeve: a real WebP, the one it names.
  for (const tag of trackTags) {
    const cover = /data-cover="([^"]+)"/.exec(tag)?.[1] || '';
    const path = join(here, '..', cover);
    const bytes = cover && !cover.includes('..') && existsSync(path) ? readFileSync(path) : null;
    const webp = bytes && bytes.subarray(0, 4).toString() === 'RIFF'
      && bytes.subarray(8, 12).toString() === 'WEBP';
    require(webp, `${cover || 'a track circle'} has no real WebP sleeve`);
    require(/<img\b[^>]*\bsrc="([^"]+)"/.exec(tag)?.[1] === cover,
      `the circle for ${cover} shows a different picture from the sleeve it names`);
  }

  const status = /<p\b([^>]*)data-soundtrack-status([^>]*)>/.exec(page);
  require(status && /aria-live="polite"/.test(status[0]) && /visually-hidden/.test(status[0]),
    'track and playback changes lack a quiet polite status for assistive technology');
  require(/import \{ LevelPump \} from '\.\/bands\.js';/.test(code)
      && /audioWorklet\s*\.addModule\('js\/bands-worklet\.js'\)/.test(code)
      && /source\.connect\(soundtrackAnalyser\);/.test(code),
  'the soundtrack is not routed through the checked browser analyser');
  require(/function setSoundtrackTransport\(playing\)/.test(code)
      && /dataset\.playing = String\(playing\)/.test(code)
      && /playing \? 'Pause' : 'Play'/.test(code)
      && !/aria-pressed/.test(codeOnly(code)),
  'playback does not keep the transport\'s label and drawn state in sync');

  // Asked on load; the pause is the visitor's. The key is read and written
  // under one name, the load's request is the element alone, and the
  // analyser — an AudioContext, which outside a gesture is a suspended one
  // holding the sound — is only ever built when the browser says the visitor
  // is acting.
  const pauseKey = /^const (\w+) = 'magnetite\.[\w.]+';$/m.exec(code)?.[1];
  require(pauseKey
      && new RegExp(`localStorage\\.getItem\\(${pauseKey}\\)`).test(code)
      && new RegExp(`localStorage\\.setItem\\(${pauseKey}, '1'\\)`).test(code)
      && new RegExp(`localStorage\\.removeItem\\(${pauseKey}\\)`).test(code),
  'a visitor\'s pause is not remembered under one key the page both reads and writes');
  require(/if \(!soundtrackWasPaused\(\)\) soundtrackAudio\.play\(\)\.catch\(\(\) => \{\}\);/.test(code),
    'the page does not ask to play on load, or asks even after the visitor paused, or asks for more '
    + 'than the element');
  const bare = codeOnly(code);
  const analyserCalls = [...bare.matchAll(/enableSoundtrackAnalyser\(\);/g)].length;
  const guarded = [...bare.matchAll(
    /if \(soundtrackMayListen\(\)\) \{?\s*(?:\/\/[^\n]*\n\s*)*enableSoundtrackAnalyser\(\);/g,
  )].length;
  require(analyserCalls > 0 && analyserCalls === guarded
      && /navigator\.userActivation \? navigator\.userActivation\.isActive : true/.test(code),
  `${analyserCalls - guarded} call(s) build the analyser without asking whether the visitor is `
    + 'acting — outside a gesture that is a suspended AudioContext, and routing the element into '
    + 'it silences the music the page just started');
  // The first gesture is left to the player's own circles when it lands on
  // them: answering it here too starts the music and the Play it hit pauses it.
  require(/closest\('\[data-player\] button'\)/.test(code)
      && /addEventListener\(type, soundtrackGesture, true\)/.test(code)
      && /removeEventListener\(type, soundtrackGesture, true\)/.test(code),
  'the first-gesture start is not captured page-wide, released once done, and kept off the '
    + 'player\'s own circles');
  require(/if \(!liveAnalyser\) return REAL_LEVELS\[frameNow\(step\)\];/.test(code)
      && /livePump\.tick\(soundtrackPlaying \? liveSource : null\);/.test(code),
  'the renderer does not switch from its proven replay to live bands with honest pause decay');
  const replayTau = Number(code.match(/^const SMOOTH_TAU = ([\d.]+);/m)?.[1]);
  const liveTau = Number(code.match(/^const LIVE_SMOOTH_TAU = ([\d.]+);/m)?.[1]);
  require(Number.isFinite(liveTau) && liveTau > 0 && liveTau <= 0.04
      && liveTau < replayTau / 2
      && /const LIVE_SMOOTH_K = 1 - Math\.exp\(-SIM_STEP \/ LIVE_SMOOTH_TAU\);/.test(code),
  `live audio is filtered for ${liveTau}s instead of receiving a short path through the drive — `
    + 'the analyser already meters its bands, so inheriting the enlarged replay filter makes the '
    + 'ferrofluid visibly answer after the music');
  // The call that chooses between the two rates, with its names read off the
  // module's own declarations rather than spelt here. mutate.mjs declares the
  // renames of the accumulator and of the cadence as correct alternatives (the
  // mutants beside `still-cadence-renamed` and
  // `the-cadence-is-called-something-else` say why), and a3a25a0 spelt both
  // names into this check and killed three of them — on the message above,
  // which is about the filter's length and not about a name. Each declaration
  // has to match exactly once: a second derived cadence is the drift the
  // binding exists to catch, and it is the clock check's own rule.
  const cadenceNames = [...code.matchAll(
    /^const (\w+) = replayCadence\(SIM_HZ, CAPTURE_HZ, SMOOTH_TAU\);/gm,
  )].map((m) => m[1]);
  const accumulatorNames = [...code.matchAll(
    /^const (\w+) = new Array\(REAL_LEVELS\[0\]\.length\)\.fill\(0\);/gm,
  )].map((m) => m[1]);
  const twoRateCall = /smoothStep\((\w+), target, liveAnalyser \? LIVE_SMOOTH_K : (\w+)\.k\)/.exec(code);
  require(cadenceNames.length === 1 && accumulatorNames.length === 1 && twoRateCall
      && twoRateCall[1] === accumulatorNames[0] && twoRateCall[2] === cadenceNames[0],
  'the live drive does not choose LIVE_SMOOTH_K against the replay cadence\'s own rate — site.js '
    + `derives ${cadenceNames.length} cadence(s) [${cadenceNames}] and ${accumulatorNames.length} `
    + `accumulator(s) [${accumulatorNames}], and the smoothStep call ${twoRateCall
      ? `reads ${twoRateCall[1]} and ${twoRateCall[2]}.k` : 'is not the two-rate call at all'}`);
  require(/import \{ BandAnalyser, BAND_COUNT \} from '\.\/bands\.js';/.test(worklet)
      && /new Float32Array\(BAND_COUNT\)/.test(worklet)
      && /registerProcessor\('bands', BandsProcessor\);/.test(worklet),
  'the audio thread is not registered against the shared checked analyser and band count');
}

/**
 * The page exposes discovery, not remote control, through the current WebMCP
 * surface. Its tools read the visible page at invocation time, register once,
 * and describe all three pieces of evidence the visitor sees: the hero print,
 * real app footage, and the menu-bar print whose notch is the download.
 */
async function thePageExposesOnlyReadOnlyDiscoveryTools() {
  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  require(/<script type="module" src="js\/webmcp\.mjs"><\/script>/.test(page),
    'index.html does not load the WebMCP discovery tools');

  const modelContext = { registerTool() {} };
  require(resolveModelContext({ modelContext }) === modelContext,
    'the tools do not resolve the current document.modelContext WebMCP surface');
  require(resolveModelContext({}) === null,
    'an unsupported browser is not treated as though it implements WebMCP');

  const link = {
    href: 'https://github.com/scryst/magnetite-releases/releases/tag/v0.1.1',
    textContent: 'Download, Magnetite v0.1.1 on GitHub',
  };
  const requirement = { textContent: 'macOS 26 · Apple silicon · Free · 575 KB' };
  const documentRef = {
    title: 'Magnetite — A ferrofluid music player for the MacBook notch',
    querySelector(selector) {
      if (selector === '[data-download]') return link;
      if (selector === '[data-requires]') return requirement;
      return null;
    },
  };
  const windowRef = {
    location: { origin: 'https://scryst.github.io', pathname: '/magnetite-releases/' },
  };
  const tools = buildWebMcpTools({ documentRef, windowRef });
  require(tools.map((tool) => tool.name).join(',') === [
    'magnetite_site_overview',
    'magnetite_get_download',
    'magnetite_get_demo_states',
  ].join(','), 'the page does not expose exactly its three approved discovery tools');
  for (const tool of tools) {
    require(tool.annotations.readOnlyHint && !tool.annotations.untrustedContentHint,
      `${tool.name} is not annotated as trusted read-only discovery`);
    require(Object.keys(tool.annotations).sort().join(',')
      === 'readOnlyHint,untrustedContentHint',
    `${tool.name} carries annotations outside the current WebMCP surface`);
  }

  const byName = new Map(tools.map((tool) => [tool.name, tool]));
  const overview = await byName.get('magnetite_site_overview').execute({});
  const download = await byName.get('magnetite_get_download').execute({});
  const states = await byName.get('magnetite_get_demo_states').execute({});
  require(/read-only/i.test(overview.protectedBoundary)
      && /do not download, install, launch, control audio, or change/i.test(
        overview.protectedBoundary,
      ),
  'the overview does not state the human-only native-app boundary');
  require(download.version === '0.1.1' && download.label.startsWith('Download, Magnetite')
      && download.requirements.endsWith('575 KB')
      && /human chooses/i.test(download.action),
  'the download tool does not return the visible build while leaving its action to a human');
  require(states.views.map((view) => view.element).join(',')
      === '#hero-print,#demo-film,#band-print',
  'the demo tool does not distinguish the page simulation, native film, and retracted view');
  for (const { element } of states.views) {
    require(page.includes(`id="${element.slice(1)}"`),
      `the WebMCP demo tool names ${element}, which is not on the page`);
  }

  const registered = [];
  const registeringContext = { registerTool(tool) { registered.push(tool); } };
  const first = await initWebMcp({ documentRef, windowRef, modelContext: registeringContext });
  const second = await initWebMcp({ documentRef, windowRef, modelContext: registeringContext });
  require(first.supported && first.registeredToolNames.length === 3
      && second.registeredToolNames.length === 0 && registered.length === 3,
  `WebMCP registered ${registered.length} tools across two initialisations instead of three once`);
}

/**
 * The demo is the app itself on film, and the film obeys the page.
 *
 * The mid-page picture is no longer the simulation: it is a screen recording
 * of the shipping app. What a static check can honestly hold about footage:
 *
 *  - There is exactly one film on the page, its tag carries the silent
 *    looping inline trio and a still, and it carries neither a self-starting
 *    attribute nor browser chrome — playback belongs to site.js, which asks
 *    the motion preference first, so Reduce Motion holds the still forever.
 *  - The two files are real, and agree: the mp4's own track header and the
 *    still's own WebP frame header state the same frame, read here from the
 *    bytes, not from anyone's claim.
 *  - The stylesheet draws that frame at its own aspect, lays it on the
 *    desktop still exactly where it was shot, and keeps at least two encoded
 *    pixels behind each CSS pixel at the desktop cap, avoiding browser
 *    upsampling on a 2x display.
 */
function theDemoIsTheAppOnFilm() {
  const html = readFileSync(join(here, '..', 'index.html'), 'utf8');
  const tags = [...html.matchAll(/<video\b[^>]*>/g)];
  require(tags.length === 1,
    `index.html carries ${tags.length} video tags — the demo is one film, exactly`);
  const tag = tags[0][0];
  require(/\bid="demo-film"/.test(tag),
    'the film has lost the id site.js plays it by — nothing will ever start it');
  for (const attr of ['muted', 'loop', 'playsinline']) {
    require(new RegExp(`\\b${attr}\\b`).test(tag),
      `the film's tag has lost ${attr} — a demo that is loud, ends, or goes fullscreen `
      + 'on tap is not the page\'s picture any more');
  }
  require(!/\bautoplay\b/.test(tag),
    'the film starts itself — playback belongs to site.js, which asks the motion '
    + 'preference first, and a self-starting tag plays motion for the one visitor '
    + 'who turned it off');
  require(!/\bcontrols\b/.test(tag),
    'the film wears browser chrome — a scrub bar over the hardware is a player '
    + 'inside a player');
  const src = /\bsrc="([^"]+)"/.exec(tag);
  const poster = /\bposter="([^"]+)"/.exec(tag);
  require(src, 'the film points at no footage');
  require(poster,
    'the film has no still — under Reduce Motion, and before the footage arrives, '
    + 'the still IS the demo');

  const mp4 = readFileSync(join(here, '..', src[1]));
  // The track header ends in the presentation size, 16.16 fixed point.
  const at = mp4.indexOf('tkhd');
  require(at > 4, `${src[1]} has no track header — not a playable mp4`);
  const box = at - 4;
  const size = mp4.readUInt32BE(box);
  const filmW = mp4.readUInt32BE(box + size - 8) >>> 16;
  const filmH = mp4.readUInt32BE(box + size - 4) >>> 16;
  require(filmW > 0 && filmH > 0, `${src[1]}'s track header reads ${filmW}x${filmH}`);

  const webp = readFileSync(join(here, '..', poster[1]));
  require(webp.subarray(0, 4).toString() === 'RIFF'
      && webp.subarray(8, 16).toString() === 'WEBPVP8 ',
  `${poster[1]} is not a lossy WebP`);
  require(webp[23] === 0x9d && webp[24] === 0x01 && webp[25] === 0x2a,
    `${poster[1]} has no VP8 frame header`);
  const stillW = webp.readUInt16LE(26) & 0x3fff;
  const stillH = webp.readUInt16LE(28) & 0x3fff;
  require(stillW === filmW && stillH === filmH,
    `the still is ${stillW}x${stillH} but the footage is ${filmW}x${filmH} — two `
    + 'different pictures wearing one frame');

  for (const module of [
    'js/site.js', 'js/sim.js', 'js/geometry.js', 'js/press.js', 'js/hero.js', 'js/band.js',
    'data/real-levels.js', 'js/clock.js', 'js/visibility.js', 'js/bands.js',
    'js/finale.js', 'js/liquid.js', 'js/filings.js', 'js/wordmark.js',
    'js/player.js', 'js/tunnel.js', 'js/touches.js',
  ]) {
    require(html.includes(`<link rel="modulepreload" href="${module}">`),
      `${module} is left behind the initial module-discovery waterfall`);
  }

  // And that is as far as this can see: both headers, no pixels. Whether the
  // still is the film's FIRST frame — the thing that decides if the demo jumps
  // when it starts playing — needs a decoder, and this gate runs on every
  // commit and must not need one. A poster recut from frame 300 passes every
  // line above, measured. `node site/test/posterprobe.mjs` is the half that
  // decodes; like cardprobe it is a tool you run on purpose.

  // The top-level rules; the phone's crop lives in a media block and is
  // indented, so it is not this match. The window (.film__mac) is a crop of
  // the desktop in display points, the still (.film__desk) is the whole
  // display in them, and the footage (.film__stage) is FOOTAGE's box of it:
  // each placed as calc(points / window points * 100%).
  const css = readFileSync(join(here, '..', 'css', 'magnetite.css'), 'utf8');
  const rule = (name, text = css) => new RegExp(`(?:^|\\n)\\.${name}\\s*\\{([^}]*)\\}`).exec(text)?.[1] || '';
  const stage = rule('film__stage');
  const aspect = /aspect-ratio:\s*(\d+)\s*\/\s*(\d+)/.exec(stage);
  require(aspect, 'the stylesheet no longer states the film\'s box — with the tag\'s size '
    + 'attributes overridden by width:100%, the aspect is what holds the page still while '
    + 'the footage loads');
  require(+aspect[1] * filmH === +aspect[2] * filmW,
    `the stylesheet draws the film at ${aspect[1]}/${aspect[2]} but the footage is `
    + `${filmW}x${filmH} — the box and the pixels disagree`);
  require(filmW === FOOTAGE.width * 2 && filmH === FOOTAGE.height * 2,
    `the footage is ${filmW}x${filmH}, not two pixels a point of the ${FOOTAGE.width}x`
    + `${FOOTAGE.height} points js/tunnel.js lays it on the desktop as`);
  const mac = rule('film__mac');
  const cap = +(/max-width:\s*(\d+)px/.exec(mac)?.[1] ?? NaN);
  const macPoints = +(/aspect-ratio:\s*(\d+)\s*\//.exec(mac)?.[1] ?? NaN);
  require(cap > 0 && macPoints > 0,'the stylesheet no longer caps the film\'s window, or states its '
    + 'width in display points — the footage needs its one-to-one width');
  // Desktop and phone crops alike: the footage sits on the still where it was
  // shot, or the pointer and the notch show twice where the two meet.
  const phone = /@media \(max-width: 719px\) \{\s*\/\*[^*]*\*\/\s*\.film \{[\s\S]*?\n\}/.exec(css)?.[0] ?? '';
  const crops = [[macPoints, css]];
  const phoneWindow = +(/\.film__mac \{ aspect-ratio: (\d+) \//.exec(phone)?.[1] ?? NaN);
  require(phoneWindow > 0, 'could not read the phone\'s crop of the film from magnetite.css');
  crops.push([phoneWindow, phone.replace(/\n {2}/g, '\n')]);
  for (const [points, text] of crops) {
    const placed = (name, prop) => {
      const m = new RegExp(`${prop}:\\s*calc\\((-?\\d+) / (\\d+) \\* 100%\\)`).exec(rule(name, text));
      require(m && +m[2] === points, `the ${points}pt crop does not place .${name}'s ${prop} in its own points`);
      return +m[1];
    };
    require(placed('film__desk', 'width') === 1512 && placed('film__stage', 'width') === FOOTAGE.width,
      `the ${points}pt crop draws the desktop or the footage at a size other than its own points`);
    require(placed('film__stage', 'left') - placed('film__desk', 'left') === FOOTAGE.x,
      `the ${points}pt crop lays the footage ${placed('film__stage', 'left') - placed('film__desk', 'left')}pt `
      + `into the desktop, not the ${FOOTAGE.x} it was shot at`);
  }
  const stageAtCap = cap * FOOTAGE.width / macPoints;
  require(cap >= 700 && stageAtCap * 2 <= filmW,
    `the film's window caps at ${cap}px, drawing ${filmW} source pixels at ${stageAtCap}px — the `
    + 'product proof must remain materially large without browser upsampling on a 2x display');

  const source = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');
  const code = codeOnly(source);
  require(/document\.getElementById\('demo-film'\)/.test(code),
    'site.js never looks the film up by the id the tag carries — the two halves of one '
    + 'fact have drifted apart, and nothing will ever start the film');
  const guard = /if\s*\(\s*film\s*&&\s*!reduceMotion\s*\)\s*\{/.exec(code);
  require(guard,
    'the film\'s playback is not behind the motion preference — Reduce Motion must hold '
    + 'the still, and this guard is the only thing that makes it do so');
  // Every play call must sit INSIDE the guarded block: the guard existing and
  // a play call existing are independently satisfiable, and an eager play()
  // beside an intact guard plays motion for the one visitor who turned it off.
  const block = braceSpan(code, guard);
  const plays = [...code.matchAll(/\bfilm\.play\s*\(/g)];
  require(plays.length > 0,
    'site.js never plays the film — with no self-starting attribute in the tag, nothing does');
  for (const play of plays) {
    require(play.index > guard.index && play.index < block.end,
      'site.js plays the film outside the motion-preference guard — Reduce Motion '
      + 'visitors get the very motion they turned off');
  }

  // And nothing seeks it.
  //
  // The still, the first played frame and the frame `loop` comes back to are
  // three different things the moment anything moves the playhead. They were
  // three different things: the cut opened on 3.7s of the shut band, a seek to
  // 4.017 stepped over that on the way in, and `loop` — which wraps to 0 and to
  // nowhere else — played it again on every lap after the first. The cut is
  // rotated now, so frame 0 IS the entry and all three collapse into it.
  //
  // No check here can decode H.264, so whether the PNG matches frame 0 cannot
  // be read from the pixels; 715a470 said as much and left the pairing to the
  // hand. What CAN be held is the thing that made the pairing checkable at all
  // — that the page does not move the film off the frame the still was cut
  // from.
  //
  // The word, not an assignment to it. This was written as
  // `/\bcurrentTime\s*=[^=]/` under a comment claiming it held for "any
  // assignment", and it did not hold for three: `film.currentTime += 4.017` has
  // a `+` in the way, `film['currentTime'] = 4.017` has a quote in the way, and
  // `Object.assign(film, { currentTime: 4.017 })` has no `=` at all. All three
  // seek — verified against a seekable source at 4.017 — and all three passed
  // 31 green. A pattern that has to enumerate the syntaxes of assignment will
  // always be one syntax short, so this asks for something the page has no
  // reason to want at all: site.js does not read the playhead either, and a
  // read is how a seek gets written next. Obfuscation is not covered and cannot
  // be — `film['current' + 'Time']` is not a hand edit anyone makes by accident.
  const seeks = [...code.matchAll(/\bcurrentTime\b/g)];
  require(seeks.length === 0,
    `site.js names currentTime ${seeks.length} time${seeks.length === 1 ? '' : 's'} — the still `
    + 'is cut from the film\'s first frame, and anything that moves the playhead moves the first '
    + 'played frame off it where nothing in this suite can decode H.264 to see that it has');

  const motionButton = /<button\b[^>]*data-demo-motion[^>]*>[\s\S]*?<\/button>/.exec(html)?.[0];
  require(motionButton && /data-demo-motion-label>Play demo</.test(motionButton),
    'the looping product film has no visible, labelled play/pause control');
  require(/querySelector\('\[data-demo-motion\]'\)/.test(code)
      && /film\.addEventListener\('play'/.test(code)
      && /film\.addEventListener\('pause'/.test(code)
      && /filmToggle\.addEventListener\('click'/.test(code),
  'the product-film control is present but does not own both transport states');
  const motionRule = /\.film__motion\s*\{([^}]*)\}/s.exec(css)?.[1] || '';
  // Undeclared is CSS's own initial value, 1.
  const restingOpacity = +(/opacity:\s*([\d.]+)/.exec(motionRule)?.[1] ?? 1);
  require(restingOpacity >= 0.6,
    `the only control that stops the looping film rests at ${restingOpacity} opacity — `
    + 'it must remain readable before hover or focus');
}

/**
 * The span from an opening-brace match to its matching close, by counting.
 * Used where a check must stay INSIDE one block: a regex that captures to the
 * end of the file is satisfied by text that lives in somebody else's block.
 */
function braceSpan(text, open) {
  let depth = 1;
  let at = open.index + open[0].length;
  while (depth > 0 && at < text.length) {
    if (text[at] === '{') depth++;
    else if (text[at] === '}') depth--;
    at++;
  }
  return { start: open.index, end: at };
}

/**
 * The credit is real layout, in the page's proven fine-print ink.
 *
 * Both halves shipped wrong once, and the product review caught what this
 * file did not. Hung absolutely below a stated box, the credit lived in
 * whatever gap the column happened to leave — which is zero at 1440×790, a
 * maximized window on a 13" MacBook Air, where the DOWNLOAD button painted
 * straight through the middle of the sentence. And a freehand 38% mix
 * computed to 2.17:1 at eleven pixels.
 *
 * So: the credit may not be positioned out of the footer's flow, the footer
 * may not state a fixed box that a taller flow cannot grow, and the ink is a
 * token that clears 4.5:1 on the paper it sits on.
 */
function theCreditSitsInTheFlow() {
  const css = readFileSync(join(here, '..', 'css', 'magnetite.css'), 'utf8');

  const rule = /\.foot__credit\s*\{([\s\S]*?)\}/.exec(css);
  require(rule, 'could not find the .foot__credit rule in magnetite.css');
  require(!/(?:^|;|\*\/)\s*position\s*:/.test(rule[1]),
    'the credit is positioned out of the flow again — the layout does not count it, and '
    + 'the foot lands on top of it wherever the column has no room to spare');
  // The credit sits in the foot, on the paper. Its grey is a token, and the
  // token has to clear 4.5:1 against the paper at thirteen pixels — the last
  // freehand mix on this page measured 2.17:1.
  const color = /(?:^|;|\*\/)\s*color\s*:\s*([^;]+);/.exec(rule[1]);
  require(color, '.foot__credit declares no color');
  const token = /^var\((--[\w-]+)\)$/.exec(color[1].trim())?.[1];
  require(token, `the credit prints in "${color[1].trim()}", a freehand mix rather than a token`);
  const hex = (name) => new RegExp(`${name}:\\s*(#[0-9A-Fa-f]{6})`).exec(css)?.[1];
  const luminance = (h) => {
    const c = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255)
      .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  };
  const fg = hex(token);
  const bg = hex('--paper');
  require(fg && bg, `could not read ${token} or --paper as a hex colour in magnetite.css`);
  const [hi, lo] = [luminance(fg), luminance(bg)].sort((a, b) => b - a);
  const ratio = (hi + 0.05) / (lo + 0.05);
  require(ratio >= 4.5,
    `the credit's ${token} (${fg}) measures ${ratio.toFixed(2)}:1 on the paper's ${bg}`);

  // Every rule whose subject is the foot, not the first text that looks like
  // one: the scripted page's own `.js .foot` sits above the plain rule, and a
  // first-match read checked that one and never the foot itself.
  const feet = [...css.matchAll(/(?:^|[{}])([^{}]*?\.foot)\s*\{([^{}]*)\}/g)]
    .map(([, selector, body]) => [selector.replace(/\/\*[\s\S]*?\*\//g, '').trim(), body]);
  require(feet.some(([selector]) => selector === '.foot'), 'could not find the .foot rule in magnetite.css');
  for (const [selector, body] of feet) {
    require(!/(?:^|;|\*\/)\s*height\s*:/.test(body),
      `${selector} states a fixed outer box for the foot — responsive content can no longer `
      + 'determine its depth, and the credit is what overflows it');
  }
}

/**
 * The credit links the work it borrows, and licenses nothing of its own.
 *
 * Three ways to get one sentence of fine print wrong, all found in review.
 *
 * CC BY 4.0 asks the borrower to keep "a URI or hyperlink to the licensed
 * material" wherever that is practicable, and Punch Deck's own page asks for
 * a song link by name. A credit that links only the artist's front door
 * names two works and points at neither — and the film shows both sleeves,
 * so the works are on screen, not merely referred to.
 *
 * The second is the trap: `rel="license"` looks like the careful thing to
 * put on a licence link, and it is the one attribute that must never go
 * there. That link type states the licence of THIS document's main content.
 * On this page the main content is the film, the prints, the copy and the
 * mark — and the credit's own last words are "© 2026 scryst". The attribute
 * hands all of it to whatever it points at.
 *
 * The third was this file's own blind spot rather than the page's: the deed
 * was checked for being linked at all, by a pattern that would have accepted
 * any licence at any version. The words and the URL are separate edits, and
 * this credit has already made that edit once — 3.0 to 4.0, when the music
 * changed. A sentence reading "CC BY 4.0" over a link to 3.0 states terms
 * that are not the ones on offer, and every reader who checks is told so by
 * the page itself.
 *
 * So: every work the credit names is a link, the terms are a link, the link
 * says what the words say, and no link anywhere on the page claims the page.
 */
function theCreditLinksWhatItBorrows() {
  // Comments out first, or this reads the note above the credit — which names
  // the attribute precisely in order to forbid it — as the attribute itself.
  const markup = readFileSync(join(here, '..', 'index.html'), 'utf8')
    .replace(/<!--[\s\S]*?-->/g, '');
  require(!/\brel="[^"]*\blicense\b[^"]*"/.test(markup),
    'a link carries rel="license" — that link type licenses this document\'s own main '
    + 'content, so it hands the film, the prints and the mark to whatever it points at, '
    + 'in the same paragraph as the page\'s own copyright');

  const credit = /<p class="foot__credit">([\s\S]*?)<\/p>/.exec(markup);
  require(credit, 'could not find the credit paragraph in index.html');
  require(/“[^”]+”/.test(credit[1]),
    'the credit names no work — the sentence exists to say WHICH music is playing, and '
    + 'the titles are what the licence asks be kept');
  // Strip the links, and any title still in quotes is one that has none.
  require(!/[“”]/.test(credit[1].replace(/<a\b[^>]*>[\s\S]*?<\/a>/g, '')),
    'the credit names a work it does not link — 4.0 asks for a hyperlink to the material '
    + 'wherever that is practicable, and this artist asks for a song link by name');
  const deed = /<a[^>]+href="https:\/\/creativecommons\.org\/licenses\/([^"]+)"[^>]*>([\s\S]*?)<\/a>/
    .exec(credit[1]);
  require(deed,
    'the credit states terms it does not link — the deed is where the terms actually '
    + 'live, and a licence named but not linked is a claim the reader cannot check');

  // And the terms it says out loud are the terms it points at. A reader is
  // asked to take "CC BY 4.0" on trust; the URL beside it is the only thing
  // that can honour that, and the two are edited at different moments — this
  // credit went from 3.0 to 4.0 when the music changed, and the words and the
  // href are separate edits either of which can be made alone.
  //
  // Either spelling is allowed, because the deed uses both: BY or Attribution,
  // SA or ShareAlike. What is not allowed is disagreement.
  const LONG = { by: 'attribution', sa: 'sharealike', nc: 'noncommercial', nd: 'noderiv' };
  const path = /^([a-z][a-z-]*)\/(\d+\.\d+)/.exec(deed[1]);
  require(path,
    `the deed link points at /licenses/${deed[1]} — that is not a deed: a licence URL `
    + 'names its terms and its version, and only those two things can be checked against '
    + 'what the sentence claims');
  const wanted = path[1].split('-');
  for (const term of wanted) {
    require(term in LONG,
      `the deed link points at /licenses/${deed[1]}, and "${term}" is not one of the four `
      + 'terms a CC licence is built from — a URL that 404s states nothing at all');
  }
  const said = deed[2].replace(/<[^>]*>/g, ' ').toLowerCase();
  const found = Object.keys(LONG).filter(term =>
    new RegExp(`\\b${term}\\b`).test(said) || said.includes(LONG[term]));
  require(found.sort().join('-') === [...wanted].sort().join('-'),
    `the credit says "${deed[2].trim()}" and links /licenses/${deed[1]} — those are `
    + 'different licences, and the words are the ones a reader believes');
  require(said.includes(path[2]),
    `the credit says "${deed[2].trim()}" and links version ${path[2]} of the deed — the `
    + 'version is which terms, not a detail: it moved 3.0 to 4.0 here the last time the '
    + 'music changed');
}

/**
 * The credit wraps between the names it carries, never through one.
 *
 * A name is not a place to wrap, and this sentence is almost all names: the
 * artist, two works in quotes, the terms. Every one of them is a link — the
 * check above is what guarantees that — so "a link does not break" and "a name
 * does not split" are one rule, spelled `white-space: nowrap` in one place.
 *
 * It shipped split at two measures, and the second only appeared once the
 * first was fixed. At a 512px measure the line ended “Cyberpunk and the next
 * began Renaissance”. Then with the names held whole, a 15px band of measures
 * put an em dash at the head of a line. So any dash is bound to the name in
 * front of it with a non-breaking space, and the break falls after the dash,
 * where a reader expects it.
 */
function theCreditBreaksBetweenNamesOnly() {
  const css = readFileSync(join(here, '..', 'css', 'magnetite.css'), 'utf8');
  const linkRule = /\.foot__credit\s+a\s*\{([\s\S]*?)\}/.exec(css);
  require(linkRule, 'could not find the .foot__credit a rule in magnetite.css');
  require(/(?:^|;|\*\/)\s*white-space\s*:\s*nowrap\s*(?:;|$)/.test(linkRule[1]),
    'the credit\'s links can break again — every name in that sentence is a link, so a '
    + 'breakable link is a name split across two lines, which is how “Cyberpunk '
    + 'Renaissance” shipped at the 512px measure');

  // Comments out first: a note above the credit may spell the dash rule in
  // prose, and prose is where an em dash follows an ordinary space.
  const markup = readFileSync(join(here, '..', 'index.html'), 'utf8')
    .replace(/<!--[\s\S]*?-->/g, '');
  const credit = /<p class="foot__credit">([\s\S]*?)<\/p>/.exec(markup);
  require(credit, 'could not find the credit paragraph in index.html');
  // Entity or character, it is the same space, so normalise once rather than
  // spell a U+00A0 into a regex where every later reader sees an ordinary one.
  const NB = String.fromCharCode(160);
  const bound = credit[1].replace(/&nbsp;/g, NB);
  for (const dash of bound.matchAll(/—/g)) {
    require(bound[dash.index - 1] === NB,
      'an em dash in the credit follows a breakable space — at some phone measure that '
      + 'dash starts its own line, orphaned from the name it belongs to');
  }
}

/**
 * Reduce Motion is answered with a frame of the fluid, not with the outline.
 *
 * The preference asks for no motion. It does not ask for a different product.
 * The page used to answer it by driving the sim with silence, which settles to
 * the resting outline — a flat pill — so the one visitor who cannot watch the
 * liquid move was also the only one shown that it never does. Measured: the
 * silence still finishes with 0 sites standing and a maximum height of 0.0000,
 * against 6 standing and 0.4948 for the same seed run through the capture.
 *
 * The second half RUNS the page's own loop rather than repeating it here. That
 * distinction is the whole value of it: every frame of this capture has a
 * crown in it, so a check that re-derives the picture from REAL_LEVELS can
 * only ever agree with itself, and `(REAL_LEVELS[i][b] * 0 - level[b]) * k`
 * would sail through it with the source still mentioning the capture on the
 * line that ignores it. `renderStill`'s body is lifted out and executed
 * against the real sim with no cameras attached, so what is measured is the
 * picture the page would have painted. WHERE that picture goes is a separate
 * question, and `eachCameraIsPaintedWithTheFluidItIsAimedAt` runs the same
 * body with cameras to ask it.
 *
 * What is NOT asserted: which frame. 110 was chosen by rendering candidates
 * and looking at them, and no measurement recovers that; frame 1 is also a
 * real frame of the fluid and passes here, as it should.
 */
function theStillIsAFrameOfTheFluid() {
  const source = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');

  // Under the preference there is no loop at all. One guard, at the one place
  // that can start one — `layout`, the intersection observer and
  // `visibilitychange` all reach the loop through it.
  const start = functionBody(source, 'start');
  require(start, 'could not find start() in site.js');
  require(/if\s*\([^)]*\breduceMotion\b[^)]*\)\s*return\s*;/.test(start),
    'site.js\'s start() no longer refuses to run under Reduce Motion — the preference is being '
    + 'answered with a frame loop that paints a still image sixty times a second, or with motion');

  const layout = functionBody(source, 'layout');
  require(layout && /\breduceMotion\b[^;]*\brenderStill\s*\(/.test(layout),
    'site.js\'s layout() does not repaint the still under Reduce Motion — setting a canvas\'s width '
    + 'clears it, and with no loop running there is nothing left to put the picture back');

  const still = functionBody(source, 'renderStill');
  require(still, 'could not find renderStill() in site.js');

  require(/\bREAL_LEVELS\b/.test(still),
    'site.js\'s renderStill() no longer reads the captured audio — whatever it is painting, it is '
    + 'not a frame of the fluid the app produces');
  require(/setOpen\(\s*true\s*\)/.test(still),
    'site.js\'s renderStill() paints the retracted band — the still is of a notch that never opened');

  require(/mulberry32\s*\(\s*[A-Za-z_$][\w$]*\s*\)/.test(still),
    'site.js\'s renderStill() does not seed its sim from a constant — the still is a different '
    + 'picture on every load and every resize');

  // And now the picture itself, by running the page's own body. `runRenderStill`
  // does the running and hands back what the body asked for; the frame is read
  // off that call rather than out of the source, so nothing here is pinned to
  // the constant's spelling.
  const { sim, frame, levels } = runRenderStill(source);
  require(levels === REAL_LEVELS,
    'site.js\'s renderStill() drives the still with something other than the capture itself');
  require(Number.isInteger(frame) && frame > 0 && frame < REAL_LEVELS.length,
    `site.js holds its still on frame ${frame}, which is not inside the capture's `
    + `${REAL_LEVELS.length} frames`);

  require(sim.standingCount > 0,
    'site.js paints its Reduce Motion still with nothing standing in it — whatever drives that sim, '
    + 'it is not the music, and the picture is the resting outline, which is the one thing it '
    + 'must not be');
}

/**
 * Cameras that record what they are handed instead of painting it.
 *
 * The page's two canvases are `views` entries, and until this existed both
 * runners below were handed `views = []`. That made every loop over them a
 * no-op, so the lines that AIM the paint — which fluid, at which openness, to
 * which camera — were run by nothing and held by nothing. A census of
 * forty-eight one-token changes measured against the gate as it stood left
 * forty-four of them alive, and the two at these lines both painted the
 * Reduce Motion still with the page's live sim — which under the preference
 * is never advanced at all, so the one picture that visitor is shown would
 * have been the flat resting pill.
 *
 * EVERY INJECTED VALUE IS DISTINCT FROM EVERY OTHER, and that is what makes a
 * swap visible rather than merely present. Each entry gets its own fluid and
 * its own openness, and no two of them share a number: with both cameras at
 * the page's real openness functions an entry swap can be invisible.
 *
 * `pageSim` is the module's own live sim as the harness sees it. It is a
 * SEPARATE object from anything an entry holds, because the mutant this is
 * built to catch is precisely the one that reaches for it.
 */
function recordingStage(specs) {
  const painted = [];
  const entries = specs.map((spec) => ({
    view: {
      canvas: { name: spec.name, getBoundingClientRect: () => ({ ...spec.box }) },
      render(fluid, openness) { painted.push({ what: spec.name, fluid, openness }); },
      resize() { painted.push({ what: `${spec.name}:resize` }); },
    },
    sim: spec.sim,
    openness: () => spec.openness,
    onScreen: spec.onScreen,
  }));
  return { entries, painted, pageSim: new FerrofluidSim(mulberry32(7)) };
}

/**
 * Run `renderStill`'s body outside the page and report what it asked for.
 *
 * Every constant the module declares is handed in under its own name, so
 * nothing here is pinned to today's spelling. With no `stage` the cameras are
 * absent, which makes the paint at the foot of the body a no-op and leaves the
 * DOM out of it; with one, they are recorders and the paints are what
 * `eachCameraIsPaintedWithTheFluidItIsAimedAt` reads. The sim the body
 * constructs is recovered by recording the construction rather than by knowing
 * what the local is called, and the frame, the capture and the cadence are
 * recovered the same way — from the `driveStill` call the body makes, which is
 * why they come back as values rather than as names to look up.
 *
 * `CADENCE` is not a literal, so it is not one of the constants handed in: the
 * module's own declaration of it is prepended to the body and run, which means
 * the derivation the page performs is the derivation this executes rather than
 * one assembled here out of the three numbers behind it. The same goes for the
 * cache the body builds its sim into once: whatever the body assigns the new
 * sim to must be declared at the module's top level, and that declaration is
 * prepended too, fresh on every run.
 *
 * With `drive` false the still is set up and not advanced — the sim comes back
 * seeded and configured exactly as the page leaves it before the first step,
 * which is what `theStillIsAFrameOfTheFilm` needs to start its two runs from
 * the same place without knowing the seed.
 */
function runRenderStill(source, drive = true, stage = null) {
  const still = functionBody(source, 'renderStill');
  require(still, 'could not find renderStill() in site.js');
  const made = [];
  class Recorded extends FerrofluidSim {
    constructor(random) { super(random); made.push(this); }
  }
  const asked = [];
  const record = (target, levels, frame, cadence) => {
    asked.push({ sim: target, levels, frame, cadence });
    return drive ? driveStill(target, levels, frame, cadence) : target;
  };
  const declared = [...source.matchAll(/^const\s+([A-Za-z_$][\w$]*)\s*=\s*(-?\d+(?:\.\d+)?)\s*;/gm)];
  const names = declared.map((m) => m[1]);
  const values = declared.map((m) => Number(m[2]));
  const derived = source.match(/^const [A-Za-z_$][\w$]* = replayCadence\([^;]+\);$/m);
  require(derived,
    'site.js no longer derives a top-level cadence through `replayCadence` — the still and the '
    + 'replay are back to a cadence apiece, and this check can no longer run the still at the '
    + 'page\'s own one');
  const cached = /^\s*([A-Za-z_$][\w$]*)\s*=\s*new\s+FerrofluidSim\s*\(/m.exec(still)?.[1];
  const cache = cached
    ? new RegExp(`^let ${cached} = null;$`, 'm').exec(source)?.[0] ?? null
    : '';
  require(cache !== null,
    `site.js's renderStill() builds its still into \`${cached}\`, which the module does not `
    + 'declare at the top level as an empty cache — the still is either rebuilt on every repaint '
    + 'or kept somewhere this check cannot run');

  try {
    // `sim` is handed in as well — the module's live fluid, which renderStill
    // must not paint with. Left out of scope a body that reached for it would
    // throw, and the failure would report as "could not be run outside the
    // page" rather than as the wrong picture, which is the finding. `printed`
    // is the page's word to the stylesheet that a sheet is down, which a
    // recorder never puts down.
    const run = new Function(...names,
      'FerrofluidSim', 'mulberry32', 'REAL_LEVELS', 'views', 'printed',
      'replayCadence', 'driveStill', 'sim', `${derived[0]}\n${cache}\n${still}`);
    run(...values, Recorded, mulberry32, REAL_LEVELS,
      stage ? stage.entries : [], () => {},
      replayCadence, record, stage ? stage.pageSim : null);
  } catch (error) {
    require(false,
      `site.js's renderStill() could not be run outside the page: ${error.message}. It reached for `
      + 'something beyond the sim, the capture and the module\'s own constants, and this check can '
      + 'no longer see the picture it paints');
  }

  require(made.length === 1,
    `running site.js's renderStill() built ${made.length} sims — it is expected to build exactly `
    + 'the one it paints, separate from the one the page owns');
  require(asked.length === 1,
    `running site.js's renderStill() called driveStill ${asked.length} times — the still is one `
    + 'walk of the capture, and anything else is a picture this check cannot reason about');
  require(asked[0].sim === made[0],
    'site.js\'s renderStill() drives a sim it did not build — the picture it paints and the one it '
    + 'advanced are not the same object');
  return { ...asked[0] };
}

/**
 * The still is the frame the FILM reaches, not a frame of its own.
 *
 * The check above runs `renderStill` and asks that something is standing in the
 * picture. That is the whole of what was asserted about it, and it is a low
 * bar: the still used to carry its own spelling of the cadence — its own
 * `1 / SIM_HZ`, its own hold count, its own `1 - Math.exp(-dt / SMOOTH_TAU)` —
 * and every wrong value of all three leaves plenty standing. Measured, with all
 * forty checks green: `const dt = 2 / SIM_HZ` moved the still's outline 12.3
 * points vertically and 16.4 horizontally on a 190-point panel; one step per
 * captured frame, 9.0 and 12.7; the tau in its low pass out by half, 2.6 and
 * 6.4. This is the only picture a visitor who asked for no motion is ever
 * shown, and it was chosen by eye from candidates — so a recipe that drifts
 * does not just move it, it invalidates the choosing.
 *
 * The two sides here are the still's loop and the FILM's, and they are not the
 * same code. `driveStill` walks captured frames in a nested integer loop, which
 * is the shape the still has always had; the film walks physics STEPS and asks
 * `replayFrame` which captured frame each one belongs to, which is the page's
 * own loop and is held separately — `theReplayClockIsTheAppsClock` drives it at
 * four refresh rates. Same seed, same preference, same openness, so the only
 * thing left that can part them is the recipe. Exactly equal, not close: both
 * sides do the same float operations in the same order when they agree, so any
 * tolerance here would be a place for a real difference to hide.
 *
 * The hold count is checked as a count rather than restated. `replayFrame` is
 * asked how many consecutive steps land on each captured frame, and the
 * cadence's `steps` has to be that number — writing `Math.round(simHz /
 * captureHz)` here would be the copy this check exists to abolish.
 */
function theStillIsAFrameOfTheFilm() {
  const source = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');

  // Both sims come from the page's own body, run twice and left unadvanced, so
  // the seed and the preference and the openness are whatever site.js sets and
  // are identical on the two sides by construction. The frame, the capture and
  // the cadence are the arguments the page hands over, not names looked up
  // here — the still's frame is this module's business to name.
  const { sim: still, frame, levels, cadence } = runRenderStill(source, false);
  const { sim: film } = runRenderStill(source, false);
  require(levels === REAL_LEVELS,
    'site.js\'s renderStill() drives the still with something other than the capture itself');
  require(Number.isInteger(frame) && frame > 0 && frame < REAL_LEVELS.length,
    `site.js holds its still on frame ${frame}, which is not inside the capture's `
    + `${REAL_LEVELS.length} frames`);
  const page = pageReplay();
  for (const key of ['dt', 'steps', 'k']) {
    require(cadence[key] === page[key],
      `renderStill is handed a cadence whose ${key} is ${cadence[key]}, where the page's own `
      + `${key} is ${page[key]} — the still is stepped by something other than the replay's clock`);
  }

  driveStill(still, levels, frame, cadence);

  const drive = new Array(levels[0].length).fill(0);
  const held = new Map();
  const total = (frame + 1) * cadence.steps;
  for (let s = 0; s < total; s++) {
    const index = replayFrame(s, page.simHz, page.captureHz, levels.length, LOOP_FRAME);
    held.set(index, (held.get(index) ?? 0) + 1);
    smoothStep(drive, levels[index], cadence.k);
    film.advance(drive, cadence.dt);
  }

  // Every frame the still walks, held for as long as the film holds it — and
  // the film's own last frame is the still's, so neither runs past the other.
  for (let i = 0; i <= frame; i++) {
    require(held.get(i) === cadence.steps,
      `the film gives captured frame ${i} ${held.get(i)} physics steps and the still's cadence `
      + `holds it for ${cadence.steps} — the two integrate different amounts of the same music, `
      + 'and the page claims they are one simulation');
  }
  require(held.size === frame + 1,
    `the film reached ${held.size} captured frames in the ${total} steps the still takes to reach `
    + `frame ${frame} — the still is a picture of a different moment in the music`);

  for (const [label, a, b] of [
    ['swell', still.swell, film.swell],
    ['raised', still.raised, film.raised],
    ['impact', still.impact, film.impact],
    ['brightness', still.brightness, film.brightness],
    ['flowPhase', still.flowPhase, film.flowPhase],
    ['inkOpen', still.inkOpen, film.inkOpen],
    ['standingCount', still.standingCount, film.standingCount],
  ]) {
    require(a === b,
      `the still finishes with ${label} ${a} where the film reaches ${b} at the same step — the `
      + 'still is integrated by a recipe the replay does not use');
  }
  // Before comparing them: that there is something to compare. `sites` is
  // empty until the sim is advanced, so a still that never stepped would make
  // the loop below iterate zero times and pass — the shape of check this
  // repo has shipped before.
  require(still.sites.length > 0 && still.sites.length === film.sites.length,
    `the still carries ${still.sites.length} sites and the film ${film.sites.length} — one of the `
    + 'two never ran, and comparing them site by site would compare nothing');

  for (let i = 0; i < still.sites.length; i++) {
    require(still.sites[i].height === film.sites[i].height
      && still.sites[i].field === film.sites[i].field
      && still.sites[i].isUp === film.sites[i].isUp,
      `site ${i} of the still stands at ${still.sites[i].height} under a field of `
      + `${still.sites[i].field} (up: ${still.sites[i].isUp}), where the film has `
      + `${film.sites[i].height}, ${film.sites[i].field} and ${film.sites[i].isUp} — the picture `
      + 'the preference is answered with is not a frame of the film beside it');
  }
}

/**
 * The drive's low pass is the exponential its comment says it is.
 *
 * `smoothStep`'s note claims the response "is the same however long the frame
 * took — a dropped frame does not become a lurch", and that claim is the reason
 * the rate is `1 - e^(-dt/tau)` rather than the `dt/tau` a first reading of a
 * time constant suggests. Nothing checked it. The rate was rebuilt in three
 * places — the still, the replay, and this file — so the linearised form, a
 * fixed rate, or a tau out by any factor could be written into any one of them
 * and the other two would go on agreeing with themselves.
 *
 * So: step the real function n times at a rate, and require it to land where
 * the CONTINUOUS `1 - e^(-n·dt/tau)` lands. That is the definition the
 * exponential form exists to satisfy, not a second spelling of it — the
 * linearised rate misses by 2.5e-3 across 60..240Hz and a fixed 0.1 by 4.2e-2,
 * where the exponential is within 1.1e-16 of the closed form. Two rates,
 * because rate-independence is half the claim, and four horizons, because a
 * rate that is wrong by a factor is right at n = 0 and right again once the
 * response saturates.
 *
 * The horizons prove themselves: the shortest has to land under a fifth of the
 * way and the longest over 99%, so the span is checked to cross the curve
 * rather than assumed to.
 */
function theDriveIsTheExponentialItClaims() {
  const { tau } = pageReplay();
  require(tau > 0, `site.js smooths with a time constant of ${tau}, which is not a low pass`);
  // In seconds, not in steps, so the two rates are asked about the same four
  // moments — the point of the second rate is that they answer alike, and
  // horizons counted in steps would put them at different places on the curve.
  const horizons = [1 / 60, 7 / 60, 0.5, 2];
  for (const hz of [60, 240]) {
    const dt = 1 / hz;
    const { k } = replayCadence(hz, hz, tau);
    const reached = [];
    for (const seconds of horizons) {
      const n = Math.round(seconds * hz);
      const drive = [0];
      for (let i = 0; i < n; i++) smoothStep(drive, [1], k);
      const want = 1 - Math.exp(-n * dt / tau);
      closeTo(drive[0], want, 1e-12,
        `the drive low-passed ${n} steps at ${hz}Hz reaches ${drive[0]}, where the exponential `
        + `it claims to be is at ${want} after the same ${(n * dt).toFixed(4)}s — the rate is not `
        + '`1 - e^(-dt/tau)`, so a dropped frame is a lurch and the page\'s smoothing depends on '
        + 'the display');
      reached.push(drive[0]);
    }
    require(reached[0] < 0.2 && reached[reached.length - 1] > 0.99,
      `at ${hz}Hz the horizons this check drives span ${reached[0]} to `
      + `${reached[reached.length - 1]} — they no longer cross the response curve, so a rate wrong `
      + 'by a factor would be measured where every rate agrees');
  }
}

// ---------------------------------------------------------------------------

/**
 * THE INK IS ONE INK, AND THE PAPER ONE PAPER.
 *
 * The page's two pigments are stated by value across several files: the
 * press's black in press.js, the stylesheet's --ink and the share card's INK;
 * then the stylesheet's --paper, the card's PAPER and index.html's
 * theme-color. Nothing imports any of them from anywhere — each is a hex
 * spelled in its own file, which is how the icon once shipped wearing #0A0A0C
 * under a comment claiming "the same ink" while every liquid pixel was
 * #0B0A0C. One digit, invisible on any screen, and a lie in the file's own
 * commentary. Invisible is the point: a drift no eye will ever catch is a
 * drift only a gate can.
 *
 * The icon is a second family and is held as one. The icon master's INK and
 * FLOOD and the favicon's two fills are the app's own pigments — the Dock
 * tile, the tab and the menu bar — while the page prints in riso inks. The
 * two families are not required to agree; each is required to agree with
 * itself.
 *
 * index.html's theme-color meets the paper the whole page is printed on, and
 * the meta is a hex in a file that has no way of knowing what the stylesheet
 * did. Holding it to the token's VALUE says two files agree about a colour,
 * not that the surface under the chrome is still painted from the token. One
 * appended line — `body { background: #1C1B1F; }`, legal CSS, later in source
 * order — repaints the page and leaves the meta matching a token nothing
 * reads. So the last thing here is the delegation itself: the body's LAST
 * top-level ground must BE `var(--paper)`, by name.
 */
function theInkIsOneInkAndThePaperOnePaper() {
  const read = (...parts) => readFileSync(join(here, ...parts), 'utf8');
  const one = (source, pattern, what) => {
    const m = pattern.exec(source);
    require(m, `${what} declares no pigment where this gate expects one — the declaration moved `
      + 'and the parity gate is reading yesterday\'s spelling');
    return m[1].toUpperCase();
  };
  const hex = (rgb) => `#${rgb.map((c) => c.toString(16).padStart(2, '0')).join('').toUpperCase()}`;

  require(Array.isArray(INK.black) && INK.black.length === 3,
    'press.js no longer states its black as an rgb triple, so the parity gate cannot read it');
  const css = read('..', 'css', 'magnetite.css');
  const card = read('og.html');
  const inks = {
    'press.js INK.black': hex(INK.black),
    'magnetite.css --ink': one(css, /--ink:\s*(#[0-9a-fA-F]{6})/, 'magnetite.css'),
    'og.html INK': one(card, /const INK = '(#[0-9a-fA-F]{6})'/, 'og.html'),
  };
  const papers = {
    'magnetite.css --paper': one(css, /--paper:\s*(#[0-9a-fA-F]{6})/, 'magnetite.css'),
    'og.html PAPER': one(card, /const PAPER = '(#[0-9a-fA-F]{6})'/, 'og.html'),
    'index.html theme-color': one(read('..', 'index.html'),
      /<meta name="theme-color" content="(#[0-9a-fA-F]{6})">/, 'index.html'),
  };

  const ink = inks['press.js INK.black'];
  const paper = papers['magnetite.css --paper'];
  require(ink !== paper,
    'the ink and the paper resolve to the same colour — the page is blank and so is this gate');
  for (const [where, value] of Object.entries(inks)) {
    require(value === ink,
      `${where} is ${value} while the press prints ${ink} — two files disagree about what `
      + 'the ink is, and whichever surface reads the odd one out wears a different liquid');
  }
  for (const [where, value] of Object.entries(papers)) {
    require(value === paper,
      `${where} is ${value} while the page's paper is ${paper} — two files disagree about `
      + 'what the paper is, and the seam shows wherever the two grounds meet');
  }

  // The delegation the comparison above does not make: the body's LAST
  // top-level ground, the one the browser applies, is the paper token by name.
  const bodyGrounds = [...css.matchAll(/^body\s*\{([\s\S]*?)\}/gm)]
    .map((m) => [...m[1].matchAll(/(?:^|;|\n)\s*background\s*:\s*([^;}]+)/g)].pop())
    .filter(Boolean)
    .map((m) => m[1].trim());
  require(bodyGrounds.length > 0,
    'no top-level `body` rule in magnetite.css declares a background — the surface the '
    + 'browser chrome sits against is whatever happens to be behind it, and theme-color is '
    + 'delegating to nothing');
  const ground = bodyGrounds[bodyGrounds.length - 1];
  require(/^var\(--paper\)(?:\s|$)/.test(ground),
    `the page's ground is \`${ground.slice(0, 40)}\` rather than var(--paper) — theme-color `
    + 'states the paper by value, so the moment the surface under the chrome stops reading that '
    + 'token the meta is matching a colour the page never paints');

  // The icon family. The favicon states both pigments and names neither, so
  // it is held to both: exactly two fills, one the tile in the icon's paper,
  // one the mark in its ink. A third fill would be a pigment this gate has
  // never heard of.
  const icon = read('icon.html');
  const iconInk = one(icon, /const INK = '(#[0-9a-fA-F]{6})'/, 'icon.html');
  const iconPaper = one(icon, /const FLOOD = '(#[0-9a-fA-F]{6})'/, 'icon.html');
  require(iconInk !== iconPaper,
    'the icon\'s ink and paper resolve to the same colour — the icon is blank');
  const fills = [...read('..', 'favicon.svg').matchAll(/fill="(#[0-9a-fA-F]{6})"/g)]
    .map((m) => m[1].toUpperCase());
  require(fills.length === 2,
    `favicon.svg carries ${fills.length} hex fills where the tile-and-mark shape has exactly two`);
  require(fills.includes(iconPaper),
    `favicon.svg's tile is ${fills[0]} — not the paper ${iconPaper} the icon master floods`);
  require(fills.includes(iconInk),
    `favicon.svg's mark is ${fills[1]} — not the ink ${iconInk} the icon master draws in`);
}

// ---------------------------------------------------------------------------

/**
 * A canvas nobody has looked at yet still gets drawn.
 *
 * The off-screen gate is an ECONOMY, not a precondition. `onScreen` is
 * `undefined` until the observer's first callback, and stays `undefined` for
 * the whole life of a page whose browser has no `IntersectionObserver` — a
 * case `site.js` deliberately supports, since it guards the observer on
 * `typeof`. Written as `!entry.onScreen` the gate agrees with the shipping
 * `entry.onScreen === false` on both booleans and differs only on that third
 * value, where it skips every view forever and serves a blank page.
 *
 * It survived the entire forty-three-check gate, in both places it is spelled:
 * the views loop and the headline's ink. So did assigning `!isIntersecting`,
 * which draws precisely the canvases nobody is looking at. Nothing here could
 * see any of it, because the callbacks are anonymous closures over module
 * state — no gate can construct one — and what held them was rules that NAME
 * `onScreen` without reading which way it points.
 *
 * The decisions moved to `visibility.js`, which has no DOM in it. This drives
 * them directly and then requires `site.js` to route through them: a check
 * that proves the module correct while the page keeps its own inline
 * comparison has proved nothing about the page.
 */
function theOffscreenEconomyNeverBlanksThePage() {
  // Three-valued, as one assertion rather than three, because no mutant can
  // separate the middle case from the first: anything that stops drawing an
  // observed-visible view stops drawing a never-observed one too, and the
  // never-observed case is checked first. Stated as a table so the third value
  // is visibly part of the contract and not an omission.
  for (const [reported, drawn] of [[undefined, true], [true, true], [false, false]]) {
    require(shouldDraw(reported) === drawn,
      `a view whose visibility is ${String(reported)} ${drawn ? 'does not draw' : 'draws anyway'}`
      + ' — undefined is a view the observer has not reported on YET, and on a browser with no'
      + ' IntersectionObserver it is every view for the whole visit, so treating it as hidden'
      + ' serves a blank page; only an explicit false is the economy this gate exists for');
  }

  const hero = {};
  const band = {};
  const seen = watchOutcome(
    [{ target: hero, isIntersecting: true }, { target: band, isIntersecting: false }], false);
  const states = new Map(seen.states);
  require(states.get(hero) === true && states.get(band) === false,
    'the observer records the opposite of what it was told, so the page draws the canvases '
    + 'that are away and skips the one being looked at');
  require(seen.start === true,
    'a view arriving on screen does not wake the loop, so scrolling to the hero shows a still');
  require(watchOutcome([{ target: hero, isIntersecting: false }], false).start === false,
    'a view LEAVING wakes the loop');
  require(watchOutcome([{ target: hero, isIntersecting: true }], true).start === false,
    'a loop already running is started a second time — see theFrameLoopCannotRunTwice for what '
    + 'a second loop costs');

  // Deciding was only half of it. SPENDING the decision — writing the flag
  // onto each view — sat in the observer callback, where `= !onScreen`
  // inverted every canvas's visibility with the whole forty-six-check gate
  // green. It is here now, so it can be run.
  // What `watchOutcome` decides is checked above, so what is left to check is
  // that this COMPOSES it: the flags land on their own views, a stray record
  // lands nowhere, and the answer about the loop comes back untouched.
  const heroView = { view: { canvas: hero } };
  const bandView = { view: { canvas: band } };
  applyWatch(
    [{ target: hero, isIntersecting: true }, { target: band, isIntersecting: false }],
    [heroView, bandView], false);
  require(heroView.onScreen === true && bandView.onScreen === false,
    'applyWatch writes the opposite of what it was told onto the views, so the page draws the '
    + 'canvases nobody is looking at and skips the one being looked at');
  // The observer really does deliver records for targets this page is not
  // tracking, and they must fall on the floor rather than on view zero.
  const lone = { view: { canvas: {} } };
  applyWatch([{ target: {}, isIntersecting: true }], [lone], false);
  require(!('onScreen' in lone),
    'applyWatch writes a record onto a view it does not belong to — one canvas\'s visibility '
    + 'decides another\'s, and the observer batches its deliveries so they arrive together');
  // One assertion over both loop states, because the two mutants worth
  // catching here — the answer inverted, and the loop\'s own state inverted on
  // the way into the decision — are each visible only by comparing the two.
  for (const [running, woken] of [[false, true], [true, false]]) {
    require(applyWatch([{ target: hero, isIntersecting: true }], [heroView], running) === woken,
      `a view arriving on screen while the loop is ${running ? 'running' : 'stopped'} reports `
      + `${!woken} — applyWatch is not handing back the decision watchOutcome made, so either `
      + 'scrolling to the hero shows a still forever or every arrival hands out a second loop');
  }

  // And the page asks. By call rather than by line: restructuring the loop
  // around `shouldDraw` instead of `continue` is the same property.
  const site = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');
  const body = functionBody(site, 'frame');
  require(body, 'site.js has no top-level `frame`, so its draw gate cannot be read');
  const gates = [...body.matchAll(/shouldDraw\s*\(/g)].length;
  require(gates >= 1,
    'frame() never asks shouldDraw — the views loop has inlined its own visibility test, and '
    + 'the policy checked above is not what the page runs');
  // Every read of the flag inside the loop goes THROUGH the policy. Testing
  // for `onScreen ===` would have been the obvious rule and is far too narrow:
  // `|| !entry.onScreen` beside an intact call re-arms the blank page without
  // writing a comparison at all, and would sail past it. So the calls are
  // struck out and what is left must not mention the flag.
  const stripped = body.replace(/shouldDraw\s*\([^)]*\)/g, '');
  require(!/\.onScreen/.test(stripped),
    'frame() reads .onScreen somewhere other than through shouldDraw — a second opinion beside '
    + 'the gate is the never-observed view skipped again, whatever it is spelled like');
  // THE WIRING, which is a different problem from the policy. Everything above
  // is reachable because it is a pure function; the lines that CARRY values
  // between the page and it are not, and five one-character inversions there
  // survived the whole gate — the inverted-visibility defect among them,
  // reborn one line past the module extracted to hold it.
  //
  // Two of the five are gone rather than held: the assignment and the film's
  // `isIntersecting` moved into the module, because no text rule can honestly
  // hold an assignment whose every identifier is free to be renamed — a rule
  // tight enough to catch the `!` is a rule an innocent respelling breaks. So
  // this one is an ABSENCE, which nothing can respell around.
  const code = codeOnly(site);
  require(!/\.onScreen\s*=(?!=)/.test(code),
    'site.js writes .onScreen itself — the flag every canvas is drawn from is being set '
    + 'outside applyWatch, which is exactly where the inverted-visibility defect lived and '
    + 'where no mutant could reach it');

  // The remaining two genuinely have to cross, so they are held by CAPTURE: the
  // identifier is read out of the source and required back, bare. A `!` breaks
  // that; renaming anything does not, which is the difference between
  // asserting the property and pattern-matching today's spelling.
  //
  // ONE assertion for the three of them, with the reason worked out rather
  // than three requires in a row. They read like separate claims and are not:
  // each later one can only be evaluated because the earlier one held, so
  // blanking any of them just moves the failure down the list, and a blanking
  // pass reports every one as doing no work. The cause is computed so the kill
  // still names which of the three went wrong.
  let watchBody = null;
  for (const made of code.matchAll(/new IntersectionObserver\(/g)) {
    const body = braceBlock(code, made.index);
    if (body && /applyWatch\s*\(/.test(body)) { watchBody = body; break; }
  }
  const handoff = watchBody
    && /(?:const|let)\s+(\w+)\s*=\s*applyWatch\(\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\)/.exec(watchBody);
  // Not "the name is mentioned" and "the name is not negated" — both are
  // weaker than they read. `void wake;` mentions it un-negated and starts
  // nothing; a bare `start()` beside it is unguarded and starts always. What
  // the page owes is that THIS identifier is what decides, in either spelling,
  // and a `!` between the two matches neither.
  const wake = handoff && handoff[1];
  const decides = wake && new RegExp(
    `(?:if\\s*\\(\\s*${wake}\\s*\\)\\s*\\{?\\s*|${wake}\\s*&&\\s*)start\\s*\\(\\s*\\)`)
    .test(watchBody);
  const broken = !watchBody
    ? 'no IntersectionObserver in site.js hands its records to applyWatch, so the policy '
      + 'checked above is not what the observer runs'
    : !handoff
      ? 'the observer does not hand applyWatch three plain identifiers — anything else there is '
        + 'a value being reshaped on the way in, and `!running` inverts the offscreen economy '
        + 'without one character of the policy changing'
      : !decides
        ? `the observer does not let \`${wake}\` decide whether to start the loop — negated, the `
          + 'loop wakes when a canvas LEAVES the screen and sleeps when one arrives; dropped, a '
          + 'canvas scrolling into view never wakes it at all'
        : null;
  require(!broken, `${broken} — the page settles onto a still and never comes back`);
}

/**
 * The film plays where it is being watched, and only there.
 *
 * Inverting the transport — play when it scrolls away, pause when it arrives —
 * survived the whole gate, and so did dropping the pause entirely, which
 * leaves a video decoding forever behind the visitor. Both are the observer's
 * own economy running backwards or not at all.
 *
 * The two actions are read OFF the policy rather than restated: whatever
 * distinct values `filmAction` can return, the page has to answer each one.
 * That is what makes the dropped pause visible here — an `else` branch that is
 * simply absent looks the same as no branch to any rule counting calls.
 */
function theFilmPlaysWhereItIsWatched() {
  // Both halves as one assertion: the only edit that breaks either is the swap
  // that breaks both, so two requires would leave one of them unreachable.
  for (const [beside, action] of [[true, 'play'], [false, 'pause']]) {
    require(filmAction(beside) === action,
      `a film ${beside ? 'on screen' : 'scrolled away from'} is not ${action}d — inverted, it `
      + 'plays while the visitor is looking elsewhere and stops the moment they arrive at it');
  }

  // Coming back from a hidden tab presses play, but only beside the film.
  require(filmResume(false, true) === 'play',
    'a page returning from hidden leaves the film paused beside the visitor — a browser that '
    + 'suspended it on its own is never told to resume');
  require(filmResume(true, true) === 'none', 'a still-hidden page starts the film');
  require(filmResume(false, false) === 'none',
    'returning to the page resumes a film nobody has scrolled to, undoing the pause above on '
    + 'every tab switch');

  // The transport holds WHERE the film is, which used to be a flag in the
  // observer's closure — `beside = !record.isIntersecting` inverted the whole
  // thing there with the gate green, and a `let` in a closure is not something
  // a text rule can hold. Driven here as a sequence, because remembering is
  // the part that is new: what it answers about a hidden tab depends on the
  // record it was handed before.
  const transport = filmTransport();
  require(transport.revealed(false) === 'none',
    'a transport that has been handed no record at all counts as beside the film — a page '
    + 'revealed before the observer has said anything starts a film nobody has scrolled to');
  // What it ANSWERS about a record, as one assertion over both directions, for
  // the same reason `filmAction` is: the defect is a swap.
  for (const [intersecting, action] of [[true, 'play'], [false, 'pause']]) {
    require(transport.observe({ isIntersecting: intersecting }) === action,
      `a film ${intersecting ? 'arriving on screen' : 'scrolled away from'} is not ${action}d by `
      + 'the transport — inverted, it plays where nobody is looking and stops where they are');
  }
  // And what it REMEMBERS, which is the part that is new and the reason this
  // is a transport rather than two more pure functions: the answer about a
  // revealed tab depends on the record handed over before it.
  transport.observe({ isIntersecting: true });
  for (const [hidden, action] of [[false, 'play'], [true, 'none']]) {
    require(transport.revealed(hidden) === action,
      `a ${hidden ? 'still-hidden' : 'revealed'} tab beside the film answers ${action === 'play'
        ? 'nothing' : 'play'} — the transport has either forgotten where the film is or read the `
      + 'tab\'s own flag backwards, and a hidden flag inverted here starts the film on the way '
      + 'OUT of the page and leaves it stopped on the way back in');
  }

  const site = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');
  // Comments stripped first: this file's own prose quotes the defects it
  // guards against — `beside = !record.isIntersecting` is written out in
  // site.js as the reason the state moved — and a rule a COMMENT can satisfy
  // is a rule that passes on a page with the code deleted.
  const source = codeOnly(site);
  const guard = /if\s*\(film\s*&&\s*!reduceMotion\s*\)\s*\{/.exec(source);
  require(guard, 'site.js no longer sets the film up, so its transport cannot be read');
  const block = source.slice(guard.index, braceSpan(source, guard).end);
  // One assertion again, and for the same reason: the name has to be read out
  // of the source before anything can be asked about it, so these three only
  // look independent. The `document.hidden` half is the one member expression
  // pinned by name in this file, deliberately — `!document.hidden` there
  // resumes the film on the way OUT of the page and leaves it paused on the
  // way back in, a value inverted in flight that no check of the policy can
  // see. Reading the state some other way (`visibilityState === 'hidden'`, for
  // instance) is a change worth updating this rule for, not a respelling it
  // should have tolerated.
  const built = /(?:const|let)\s+(\w+)\s*=\s*filmTransport\(\s*\)/.exec(block);
  const kept = built && built[1];
  const asked = kept && new RegExp(`\\b${kept}\\.observe\\(\\s*\\w+\\s*\\)`).test(block);
  const pinned = kept && new RegExp(`\\b${kept}\\.revealed\\(\\s*document\\.hidden\\s*\\)`).test(block);
  const lost = !built
    ? 'the film block no longer builds a filmTransport, so the transport checked above is not '
      + 'the transport the page runs'
    : !asked
      ? `the film block never hands \`${kept}\` a record — the transport it built is asked `
        + 'nothing, so nothing that knows where the film is ever plays or pauses it'
      : !pinned
        ? `the film block does not ask \`${kept}\` about document.hidden exactly — a tab's `
          + 'hidden flag reshaped on its way to the transport resumes the film when the visitor '
          + 'LEAVES and leaves it stopped when they come back'
        : null;
  require(!lost, `${lost} — the film's economy is decided somewhere no mutant can reach`);
  require(!/\bisIntersecting\b/.test(codeOnly(site)),
    'site.js reads isIntersecting itself — where the film sits is the transport\'s own memory, '
    + 'and a second reading of it beside the transport is the inverted transport again, '
    + 'whatever it is spelled like');

  const actions = [...new Set([filmAction(true), filmAction(false)])];
  for (const action of actions) {
    require(block.includes(`'${action}'`),
      `filmAction can return '${action}' and the film block never answers it — the transport `
      + 'has an outcome the page silently drops');
  }
  require(/if\s*\(action\s*===\s*'play'\)\s*run\(\)/.test(block),
    'the transport\'s play action is not answered by the film transport');
  require(/if\s*\(action\s*===\s*'pause'\)\s*film\.pause\(\)/.test(block),
    'the transport\'s pause action is not answered by the film transport');
}

/**
 * The motion preference is read the way it was asked.
 *
 * `matchMedia(...).matches` inverted survived every check in this file. The
 * consequences are exactly swapped: the one visitor who asked for no motion is
 * the only one shown the liquid moving, and everyone else gets a page frozen
 * on its still. Everything downstream — `renderStill`, the loop that never
 * starts, the film's reduced answer — was already checked, and all of it was
 * checked against a boolean this one line was free to flip.
 */
function thePreferenceIsReadTheWayItIsAsked() {
  // One assertion, both directions, for the same reason as above: the defect
  // is a swap, and a swap fails whichever half is checked first.
  for (const matches of [true, false]) {
    require(prefersReducedMotion({ matches }) === matches,
      `a visitor whose browser reports ${matches} for reduced motion is treated as ${!matches} — `
      + 'read backwards, the one person who asked for stillness is the only one shown the liquid '
      + 'moving, and everybody else gets a page frozen on its still');
  }

  const site = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');
  require(/const reduceMotion = prefersReducedMotion\(\s*matchMedia\(/.test(site),
    'site.js no longer resolves reduceMotion through prefersReducedMotion, so the polarity '
    + 'checked above is not the polarity the page runs');
  require(/matchMedia\(\s*'\(prefers-reduced-motion: reduce\)'\s*\)/.test(site),
    'site.js asks the browser about some other media query than reduced motion — there is still '
    + 'a boolean and it is still threaded everywhere, and it now means something else');
}

/**
 * Run site.js's real `frame()` outside the page and return what it advanced.
 *
 * The loop is the one function in this file's reach that was only ever read.
 * `renderStill` has been executed since the still drifted 12.3 points behind
 * green checks; `frame` kept its text rules, and five one-token changes at the
 * lines where it SPENDS `clock.js` — the two rates swapped on the way into
 * `replayFrame`, `dt` and the fixed step swapped on the way into `bankSteps`,
 * the low pass handed its accumulator and its target the wrong way round, the
 * batch's last index fed to every step in the batch, and the smoothing skipped
 * altogether — all survived the whole forty-six-check gate. Every one of them
 * is visible in the stream of `(levels, step)` pairs the loop hands the sim,
 * and in nothing else, so that stream is what this recovers.
 *
 * NOTHING HERE IS PINNED TO A SPELLING. The prelude is the page's own
 * top-level `const` block in source order, minus the declarations that reach
 * for the DOM and, transitively, minus anything initialised from one of those
 * — so `SIM_STEP`, the cadence and the smoothing accumulator arrive under
 * whatever names the module gives them. The module's top-level `let`s that
 * start from a literal come along too, since the loop eases state of its own.
 * Every top-level function declaration comes along verbatim; declaring a body
 * evaluates nothing, so the ones that touch the DOM are harmless and only what
 * the loop actually calls is ever run. What the harness supplies instead of
 * the page are the things it has to own: the sim, which is a recorder; the
 * cameras, which with no `stage` are absent — making the paint at the foot of
 * the body a no-op and leaving the DOM out of it — and with one are recorders
 * too; and `requestAnimationFrame`, which returns a number and schedules
 * nothing.
 *
 * THE CAPTURE HANDED IN IS A COPY, and that is load-bearing rather than tidy.
 * `smoothStep` writes into its first argument, so a page that hands it the
 * capture row instead of the accumulator destroys `REAL_LEVELS` as it plays —
 * and this file imports that array once for all forty-seven checks. Run
 * against the module's own array, such a mutant would corrupt the numbers this
 * check then compares against, and every check after it in the same process.
 * It would still have been caught, by luck rather than by construction.
 */
function runFrame(source, schedule, stage = null, reduceMotion = false) {
  const DOM = /\b(document|window|navigator|matchMedia|performance|requestAnimationFrame|location|Image|fetch|addEventListener)\b/;
  const supplied = new Set([
    'sim', 'views',
    'livePump', 'liveBands', 'liveSource', 'liveAnalyser', 'livePumpFrame', 'soundtrackPlaying',
  ]);
  const kept = [];
  for (const found of source.matchAll(/^const\s+([A-Za-z_$][\w$]*)\s*=\s*([\s\S]*?);$/gm)) {
    const [text, name, init] = found;
    const fromDropped = [...supplied].some((gone) => new RegExp(`\\b${gone}\\b`).test(init));
    if (supplied.has(name) || DOM.test(init) || fromDropped) { supplied.add(name); continue; }
    kept.push(text);
  }
  // The module's own mutable state — the band's easing, the still's cache —
  // declared as the page declares it, when what it starts from is a literal.
  // The loop's clock is not among them: the harness owns it and starts it
  // running, below.
  const harnessed = new Set(['running', 'last', 'bank', 'steps', 'stepsDrawn', 'queued']);
  for (const found of source.matchAll(/^let\s+([A-Za-z_$][\w$]*)\s*=\s*([^;\n]+);$/gm)) {
    const [text, name, init] = found;
    if (supplied.has(name) || harnessed.has(name)) continue;
    if (!/^(?:-?\d+(?:\.\d+)?|null|true|false|'[^']*')$/.test(init.trim())) continue;
    kept.push(text);
  }
  // No require in here, and none for "there is a frame() to run" either. Both
  // are preconditions of the run below rather than claims about the page: an
  // unbalanced body or a missing loop cannot be evaluated separately from
  // "the loop would not run", so as their own assertions they would report as
  // doing no work in any blanking pass. The construction below fails for them,
  // and its one message says so.
  const functions = [];
  for (const found of source.matchAll(/^function\s+[A-Za-z_$][\w$]*\s*\(/gm)) {
    const block = braceBlock(source, found.index);
    if (block === null) continue;
    functions.push(source.slice(found.index, source.indexOf(block, found.index) + block.length + 1));
  }

  const advanced = [];
  const sim = {
    advance(levels, step) { advanced.push({ levels: [...levels], step }); },
    setOpen() {},
  };
  // WHICH function is the loop is captured, not spelled. The loop is whatever
  // the page hands to `requestAnimationFrame`, so renaming it changes nothing
  // here; `return frame;` would have made an ordinary rename fail this check,
  // which is pattern-matching today's source rather than asserting anything.
  const loop = [...new Set([...source.matchAll(/requestAnimationFrame\(\s*([A-Za-z_$][\w$]*)\s*\)/g)]
    .map((found) => found[1]))];
  if (loop.length !== 1) {
    return { failed:
      `site.js hands ${loop.length} different functions to requestAnimationFrame (${loop.join(', ') || 'none'}) `
      + 'where this check needs to know which one is the loop — with no single answer it cannot '
      + 'run the loop at all' };
  }
  // WHICH function answers a resize is captured the same way the loop is —
  // off the page's own listener — so that `layout` can be driven here without
  // this file inventing a name for it. Absent, `layout` comes back null and
  // the check that wanted it says so.
  const resized = source.match(
    /addEventListener\(\s*'resize',\s*(?:\(\)\s*=>\s*)?([A-Za-z_$][\w$]*)/);
  const built = `${kept.join('\n')}
let running = true, last = 0, bank = 0, steps = 0, stepsDrawn = 0, queued = null;
${functions.join('\n\n')}
return { loop: ${loop[0]}, layout: ${resized ? resized[1] : 'null'} };`;

  const capture = REAL_LEVELS.map((row) => [...row]);
  // The two rates and the smoothing time come back as VALUES, read off the
  // page's own call, rather than by looking up three names in the source. That
  // is the only way this check learns them, so renaming them changes nothing
  // here — and a lookup by a constant's name would have been a spelling this
  // file invented and then depended on.
  const asked = [];
  const recording = (simHz, captureHz, tau) => {
    asked.push({ simHz, captureHz, tau });
    return replayCadence(simHz, captureHz, tau);
  };
  // `views` is a parameter rather than an empty declaration. Empty, the loop
  // over the cameras was a line this harness ran past; as recorders the
  // cameras are the stream `eachCameraIsPaintedWithTheFluidItIsAimedAt` reads.
  const cameras = stage ? stage.entries : [];
  let scope;
  try {
    scope = new Function(
      'REAL_LEVELS', 'LOOP_FRAME', 'bankSteps', 'replayFrame', 'replayCadence', 'smoothStep',
      'driveStill', 'shouldDraw', 'applyWatch', 'filmTransport', 'prefersReducedMotion',
      'FerrofluidSim', 'mulberry32',
      'sim', 'requestAnimationFrame', 'console', 'views', 'reduceMotion',
      'livePump', 'liveBands', 'liveSource', 'liveAnalyser', 'livePumpFrame', 'soundtrackPlaying',
      built)(
      capture, LOOP_FRAME, bankSteps, replayFrame, recording, smoothStep,
      driveStill, shouldDraw, applyWatch, filmTransport, prefersReducedMotion,
      FerrofluidSim, mulberry32,
      sim, () => 1, console,
      cameras, reduceMotion,
      { bands: [], tick() {} }, new Float32Array(12), { levels() {} }, false, -1, false);
  } catch (error) {
    return { failed:
      `site.js's frame() could not be run outside the page: ${error.message}. The loop reached for `
      + 'something beyond the capture, the clock and the module\'s own constants, or no longer '
      + 'declares a top-level frame() at all, and this check can no longer see what it spends' };
  }

  let now = 0;
  for (const gap of schedule) { now += gap; scope.loop(now); }
  return { advanced, asked, layout: scope.layout, painted: stage ? stage.painted : [] };
}

/**
 * The loop spends the clock it was given.
 *
 * `theReplayClockIsTheAppsClock` drives `bankSteps` at four refresh rates and
 * `theCaptureIsReplayedAtItsOwnRate` drives `replayFrame` across the whole
 * capture — both against the real functions, and both blind to how the page
 * CALLS them. That is the hole this closes: the module was right and the five
 * lines handing it its arguments were free, which is the same shape as the
 * visibility extraction one commit ago and was found by the same method.
 *
 * The expectation below is wired here from `clock.js` directly rather than
 * read out of `site.js`, so this is two independent spellings of one replay
 * being required to agree — not one spelling checked against itself. What it
 * borrows from the page is only the three numbers behind the cadence, and it
 * takes those as VALUES off the page's own `replayCadence` call rather than by
 * looking up `SIM_HZ` and `CAPTURE_HZ` by name. The rates being swapped there
 * is a defect, but it is `theStillIsAFrameOfTheFilm`'s, and it is caught: this
 * one is about the five lines that were caught by nothing.
 *
 * The schedule alternates 120Hz and 60Hz callbacks on purpose: at a single
 * rate the banking has no remainder to carry and swapping `dt` with the fixed
 * step lands on the same count for the wrong reason.
 */
function theLoopSpendsTheClockItWasGiven() {
  const source = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');
  const schedule = Array.from({ length: 40 }, (_, i) => (i % 3 === 0 ? 1000 / 120 : 1000 / 60));
  const { advanced, asked, failed } = runFrame(source, schedule);
  // The two tolerances are named so the check can assert its own RESOLUTION
  // below. Left as literals inside the comparisons they were the only two
  // numbers in this check that nothing held: a sweep changing every numeric
  // literal here one at a time, with a real defect restored under each, found
  // that either one of these alone at 1e3 lets that defect straight through on
  // a gate still reporting every check passing. They were the only survivors.
  // Gated, the same sweep over the forty-six literals this check now carries
  // reports none.
  const STEP_TOLERANCE = 1e-12;
  const LEVEL_TOLERANCE = 1e-9;

  // One require for four things, and for the reason the last commit gave: the
  // loop has to run before its cadence can be recovered, the cadence has to be
  // recovered before a replay can be wired, and the replay has to advance
  // before a count can disagree. Blanking any of them on its own just moves
  // the failure to the next, so as four requires they would all report as
  // doing no work. The cause is computed instead, so the kill still names
  // which one broke.
  const rates = asked && asked.length === 1 ? asked[0] : null;
  const cadence = rates ? replayCadence(rates.simHz, rates.captureHz, rates.tau) : null;
  const spread = cadence
    ? Math.max(...schedule.map((gap) => Math.abs(gap / 1000 - cadence.dt)))
    : 0;
  let want = [];
  if (rates) {
    const drive = new Array(REAL_LEVELS[0].length).fill(0);
    let state = { bank: 0, steps: 0 };
    let drawn = 0;
    for (const gap of schedule) {
      const dt = Math.max(0, Math.min(0.05, gap / 1000)) || 0;
      state = bankSteps(state, dt, cadence.dt);
      for (let s = drawn; s < state.steps; s++) {
        const index = replayFrame(s, rates.simHz, rates.captureHz, REAL_LEVELS.length, LOOP_FRAME);
        want.push({ levels: [...smoothStep(drive, REAL_LEVELS[index], cadence.k)], step: cadence.dt });
      }
      drawn = state.steps;
    }
  }

  const broken = failed
    || (!rates
      ? `site.js derived ${asked ? asked.length : 0} cadences through \`replayCadence\` where this `
        + 'check needs the one the loop runs on — the page has stopped stating its rates in a '
        + 'place this check can read them from, and the replay below cannot be wired at all'
      : want.length === 0 || advanced.length === 0
        ? 'the replay this check wired advanced nothing, so a page agreeing with it proves nothing'
        // The window, asserted rather than described. Every gap in the schedule
        // equal to the cadence's own step makes `dt` and the fixed step
        // interchangeable, and swapping them — the defect the banking exists to
        // prevent — lands on the identical count. A uniform schedule is this
        // check with its eyes shut, passing.
        //
        // Its epsilon is DERIVED from the step and not borrowed from the
        // tolerances below, which is the difference between a cause and a
        // coincidence: sharing `LEVEL_TOLERANCE` made the levels-tolerance
        // mutant die here instead, reporting a uniform schedule about a
        // schedule that alternates 120 and 60Hz — the right kill carrying a
        // false sentence. Derived, it is also self-guarding: widening it far
        // enough to swallow the alternation fails this check on clean source
        // rather than passing quietly.
        : !(spread > cadence.dt / 100)
          ? `no callback in the schedule this check drives the loop with differs from one `
            + `simulation step by more than ${spread.toFixed(6)}s, against a step of `
            + `${cadence.dt.toFixed(6)}s — the wall clock and the fixed step are interchangeable `
            + 'in it, so the loop could hand `bankSteps` either one and this check would agree'
        // And the resolution, tied to what it has to resolve rather than
        // written down and hoped for. One smoothing step moves the drive by
        // `k` times the level, and the smallest step defect worth the name is
        // a fraction of `dt`; a tolerance anywhere near either is this check
        // agreeing with a page it can no longer see.
        : !(LEVEL_TOLERANCE < cadence.k / 1000) || !(STEP_TOLERANCE < cadence.dt / 1e6)
          ? `this check compares levels to ${LEVEL_TOLERANCE} and steps to ${STEP_TOLERANCE}, `
            + `against a smoothing that moves ${cadence.k.toFixed(4)} per step and a step of `
            + `${cadence.dt.toFixed(6)} — at that resolution it would accept a loop driving the `
            + 'fluid off the wrong frame entirely and report the page correct'
        : advanced.length !== want.length
          ? `site.js's loop advanced the sim ${advanced.length} times over ${schedule.length} `
            + `callbacks where the replay it delegates to asks for ${want.length} — the page is `
            + 'banking the wall clock differently from the way `bankSteps` means it, so the '
            + 'physics is a function of the refresh rate again'
          : null);
  require(!broken, `${broken}`);

  for (let i = 0; i < want.length; i++) {
    require(Math.abs(advanced[i].step - want[i].step) < STEP_TOLERANCE,
      `advance ${i} stepped by ${advanced[i].step} where the cadence says ${want[i].step} — the `
      + 'loop integrates on a clock the capture was not taken on');
    for (let c = 0; c < want[i].levels.length; c++) {
      require(Math.abs(advanced[i].levels[c] - want[i].levels[c]) < LEVEL_TOLERANCE,
        `advance ${i} was handed ${advanced[i].levels[c].toFixed(6)} on channel ${c} where the `
        + `replay says ${want[i].levels[c].toFixed(6)} — the loop and the capture disagree about `
        + 'which frame this step belongs to, or about what the smoothing did to it, and every '
        + 'check of either one on its own stays green');
    }
  }
}

/**
 * Every camera is painted with the fluid it is aimed at, at its own openness.
 *
 * The page's headline claim is that the two canvases are two CAMERAS ON ONE
 * SIM rather than two simulations, and under Reduce Motion that one sim is
 * replaced for a single frame by a still the page builds, seeds and drives on
 * the spot. Both claims live entirely in the two lines that hand a fluid to a
 * camera. Neither line was ever run by this file: both harnesses were given
 * `views = []`, so every loop over the cameras was a loop over nothing, and
 * `renderStill` could paint its cameras from the page's live sim — which under
 * the preference is never advanced at all — with all forty-eight checks green.
 * That mutant is not hypothetical: it was measured surviving, and what it
 * ships is the flat resting pill to the one visitor who asked for no motion.
 *
 * WHAT IS ASSERTED IS THE ROUTING, not the picture. `theStillIsAFrameOfTheFluid`
 * already asks that the still has the music in it and `theLoopSpendsTheClockIt
 * WasGiven` that the loop advances on the right clock; the question left over
 * is where either result is SENT. So the cameras here are recorders whose
 * every injected value is distinct — own fluid, own openness, own fit — and
 * the stream they record is compared to the one the page's own text promises.
 *
 * The loop's half also covers the gate around the paint, because it is the
 * same line: a camera observed off-screen must not be painted (`shouldDraw` is
 * three-valued, and `undefined` — before the observer has said anything, or
 * forever in a browser without one — must DRAW).
 */
function eachCameraIsPaintedWithTheFluidItIsAimedAt() {
  const source = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');

  const named = (stage, paint) => {
    const own = stage.entries.find((entry) => entry.sim === paint.fluid);
    return own ? `the ${own.view.canvas.name} camera's own sim`
      : paint.fluid === stage.pageSim ? 'the page\'s live sim, which under Reduce Motion never moves'
      : paint.fluid === null || paint.fluid === undefined ? 'nothing at all'
      : 'a fluid that is neither the one it drove nor any it was handed';
  };

  // ── The still, which is the whole of the Reduce Motion page ──────────────
  //
  // Two cameras, no two numbers shared. The page's own openness functions are
  // `() => 1` and `() => 0`, and against those an entry swap paints exactly
  // the same two values in exactly the same order.
  const stillSpecs = [
    { name: 'hero', openness: 0.37, sim: new FerrofluidSim(mulberry32(11)) },
    { name: 'band', openness: 0.61, sim: new FerrofluidSim(mulberry32(13)) },
  ];
  const stage = recordingStage(stillSpecs);
  const { sim: still } = runRenderStill(source, true, stage);
  const shown = stage.painted;

  require(shown.map((p) => p.what).join(',') === 'hero,band',
    `site.js's renderStill() painted [${shown.map((p) => p.what).join(', ') || 'nothing'}] where the `
    + 'two cameras it was handed are hero then band — the still is the only picture a Reduce Motion '
    + 'visitor is ever shown, and a camera it skips keeps whatever was on it, which after the resize '
    + 'that called it is a cleared canvas');

  for (let i = 0; i < shown.length; i++) {
    const paint = shown[i];
    require(paint.fluid === still,
      `site.js's renderStill() paints the ${paint.what} camera with ${named(stage, paint)} rather `
      + 'than the still it just built, seeded and drove — the picture the page went to the trouble '
      + 'of making is not the picture it puts on the canvas');
    require(paint.openness === stillSpecs[i].openness,
      `site.js's renderStill() paints the ${paint.what} camera at openness ${paint.openness} where `
      + `that camera's own openness is ${stillSpecs[i].openness} — the still is drawn through the `
      + 'wrong camera\'s shutter, so the shut band opens or the hero closes');
  }

  // ── The loop ─────────────────────────────────────────────────────────────
  //
  // Here the cameras keep their OWN fluids, which is the opposite claim to the
  // still's: the page's one sim reaches them through the entries, and a loop
  // that reached past them to the module's `sim` would be right today and
  // wrong the moment a camera is aimed at anything else.
  const liveSpecs = [
    { name: 'hero', openness: 0.29, sim: new FerrofluidSim(mulberry32(17)), onScreen: true },
    // Never observed. Three-valued `shouldDraw` has to draw this one.
    { name: 'unseen', openness: 0.83, sim: new FerrofluidSim(mulberry32(19)) },
    // Observed, and observed to be away.
    { name: 'away', openness: 0.11, sim: new FerrofluidSim(mulberry32(23)), onScreen: false },
  ];
  const live = recordingStage(liveSpecs);
  const ran = runFrame(source, [16], live);
  require(!ran.failed, `${ran.failed}`);
  const drawn = live.painted;

  require(drawn.map((p) => p.what).join(',') === 'hero,unseen',
    `site.js's loop painted [${drawn.map((p) => p.what).join(', ') || 'nothing'}] in one callback. `
    + 'It is handed a camera on screen, one the observer has never spoken about, and one observed '
    + 'away: the first two draw and the third does not. A camera whose visibility is still unknown '
    + 'is the whole page in a browser without an IntersectionObserver, and skipping it leaves every '
    + 'canvas blank; drawing the one that is away spends a frame on nothing');

  for (let i = 0; i < drawn.length; i++) {
    const paint = drawn[i];
    require(paint.fluid === live.entries[i].sim,
      `site.js's loop paints the ${paint.what} camera with ${named(live, paint)} rather than the `
      + 'fluid that camera was built on — the cameras are supposed to be cameras on a sim, and this '
      + 'one is pointed somewhere else');
    require(paint.openness === liveSpecs[i].openness,
      `site.js's loop paints the ${paint.what} camera at openness ${paint.openness} where that `
      + `camera's own openness is ${liveSpecs[i].openness} — the hero shows the shut notch or the `
      + 'band above the download button opens, and the button\'s cutout answers nothing');
  }
}

/**
 * A camera is resized when its box or its pixel ratio changes, and only then.
 *
 * `layout` is the page's one answer to everything that changes a box: the
 * window resizing, the headline's face arriving, iOS Safari collapsing its
 * toolbar. It is also the only place that can start the loop, and under Reduce
 * Motion the only thing that puts the still back — setting a canvas's width
 * clears its backing store even when the value does not change, so a resize
 * that does not repaint is a canvas left blank.
 *
 * The key is the box AND the ratio. The ratio half is the reason it is a key
 * and not an epsilon: dragging a window from a 2x display to a 1x one leaves
 * every measured box identical and the backing store at the old ratio. And
 * `force` is for the one change no box shows — the face arriving, which moves
 * every word the hero measured in the fallback.
 */
function theCameraIsResizedIntoItsNewScale() {
  const source = readFileSync(join(here, '..', 'js', 'site.js'), 'utf8');
  const specs = [
    { name: 'moved', openness: 0.37, box: { width: 640, height: 360 }, sim: new FerrofluidSim(mulberry32(37)) },
    { name: 'settled', openness: 0.13, box: { width: 320, height: 48 }, sim: new FerrofluidSim(mulberry32(43)) },
  ];
  const resized = (stage) => stage.painted
    .filter((p) => p.what.endsWith(':resize')).map((p) => p.what.split(':')[0]).join(',');

  const was = globalThis.devicePixelRatio;
  try {
    globalThis.devicePixelRatio = 1;
    const stage = recordingStage(specs);
    const ran = runFrame(source, [], stage);
    require(!ran.failed, `${ran.failed}`);
    require(typeof ran.layout === 'function',
      'site.js no longer hands a function to its own resize listener, so this check cannot run the '
      + 'page\'s layout at all — and layout is the only thing that repaints the still, sizes the '
      + 'canvases and starts the loop');

    const step = (what, change, want) => {
      stage.painted.length = 0;
      change();
      ran.layout(what === 'force');
      require(resized(stage) === want,
        `site.js's layout() resized [${resized(stage) || 'nothing'}] ${what} where it resizes `
        + `[${want || 'nothing'}]. Resizing a camera that did not change clears a canvas for nothing `
        + 'on every scroll; skipping one that did leaves the print at the wrong size, or on iOS at '
        + 'the ratio of the display it came from');
    };
    step('on the first call', () => {}, 'moved,settled');
    step('with every box and the ratio unchanged', () => {}, '');
    step('when one box moved', () => { specs[0].box.width = 700; }, 'moved');
    step('when the pixel ratio changed', () => { globalThis.devicePixelRatio = 2; }, 'moved,settled');
    step('force', () => {}, 'moved,settled');

    // And under the preference, the same call has to put the picture back.
    // There is no loop to do it: `start` refuses to run, so a resize that does
    // not repaint here is a canvas that stays cleared for the rest of the visit.
    const quiet = recordingStage(specs);
    const still = runFrame(source, [], quiet, true);
    require(!still.failed, `${still.failed}`);
    still.layout();
    const repainted = quiet.painted.filter((p) => !p.what.includes(':'));
    require(repainted.map((p) => p.what).join(',') === specs.map((s) => s.name).join(','),
      `under Reduce Motion site.js's layout() repainted [${repainted.map((p) => p.what).join(', ') || 'nothing'}] `
      + `where its cameras are [${specs.map((s) => s.name).join(', ')}]. Setting a canvas's width `
      + 'clears it even when the width does not change, and under the preference there is no loop to '
      + 'draw the next frame — so every camera it does not repaint here stays blank until the visitor '
      + 'resizes the window again');
  } finally {
    globalThis.devicePixelRatio = was;
  }
}

/**
 * The mark on the page, in the tab and in the Dock is one mark, and it is the
 * icon's own contour.
 *
 * The page said so in a comment for a long time while nothing held it. Two
 * copies of the path were maintained by hand — one in favicon.svg, one inline
 * in index.html — and a hand-traced path is exactly the kind of thing that gets
 * touched up in one place. Worse, both were traced as straight segments: at
 * masthead size the drops were visibly faceted and the shoulders had corners
 * on them, and no check could tell a polygon from the poured curve it was
 * standing in for.
 *
 * So this re-derives the mark from the master's pixels — the same file the
 * icns is built from — and asserts both consumers are the derivation, byte for
 * byte. Nothing here trusts the committed SVG about its own provenance.
 */
function theMarkIsTheIconsOwnContour() {
  const mark = deriveMark();
  const derived = faviconSVG(mark);

  // The defect that made the generator necessary, stated as a rule rather than
  // left to the eye — and asserted about the DERIVATION, before the two
  // consumers are compared to it. Held against the committed files instead it
  // could never fire: they are required to equal the derivation two lines
  // below, so a polygon could only reach them through here. This is the end
  // that a change to the generator can actually break.
  const letter = /fill="#0B0A0C" d="([^"]*)"/.exec(derived)?.[1];
  require(letter, 'gen-mark.mjs no longer emits the letter as a filled path');
  const lines = (letter.match(/L/g) || []).length;
  const curves = (letter.match(/C/g) || []).length;
  require(curves > 0 && lines === 0,
    `the derived letter is drawn with ${lines} straight segments and ${curves} curves. The mark `
    + 'is a stroke blurred and thresholded — every junction in it is a fillet and every terminal '
    + 'a taper — so a polyline can only approximate it, and at the size the foot draws it the '
    + 'joints are visible. That is what stood here before the generator: seventy segments, and '
    + 'every one of them showing');

  const favicon = readFileSync(join(here, '..', 'favicon.svg'), 'utf8');
  require(favicon === derived,
    'site/favicon.svg is not what gen-mark.mjs derives from test/icon-1024.png. The favicon is '
    + 'generated, so a hand edit here is a mark that no longer matches the icon it claims to be '
    + 'traced from — run `node site/test/gen-mark.mjs`, or change the master if the mark itself '
    + 'is meant to move');

  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  const found = GLYPH_IN_PAGE.exec(page);
  require(found, 'index.html no longer carries an inline `svg.mark__glyph` with a single path — '
    + 'the page\'s logo has been restructured, and this check can no longer see what it draws');
  require(found[0] === inlineGlyph(mark),
    'the logo inline in index.html is not the one gen-mark.mjs derives from the icon master. The '
    + 'page and the tab would show different marks, which is the disagreement the generator '
    + 'exists to make impossible');

  const swift = readFileSync(join(here, '..', '..', 'Sources', 'NotchApp', 'App',
    'MagnetiteMark.swift'), 'utf8');
  require(swift === markSwift(mark),
    'Sources/NotchApp/App/MagnetiteMark.swift is not what gen-mark.mjs derives from the icon '
    + 'master. The menu bar would carry a different mark from the Dock tile it sits above — run '
    + '`node site/test/gen-mark.mjs`');

  // And that the app actually USES it. The three files above can agree
  // perfectly while the status item draws something else entirely, which is
  // exactly the state this arrived in: a generic `rectangle.topthird` sat in
  // the menu bar for the app's whole life, and no check anywhere read the one
  // line that put it there.
  const delegate = readFileSync(join(here, '..', '..', 'Sources', 'NotchApp', 'App',
    'AppDelegate.swift'), 'utf8');
  const install = /func installStatusItem\(\) \{([\s\S]*?)\n    \}/.exec(delegate);
  require(install, 'AppDelegate.swift no longer declares installStatusItem(), so this cannot see '
    + 'what the menu bar draws');
  require(/item\.button\?\.image = MagnetiteMark\./.test(install[1]),
    'the status item\'s image does not come from MagnetiteMark. The menu bar is the surface the '
    + 'app shows while it is doing its job, and it is the one place the logo was not');
  require(!/systemSymbolName/.test(install[1]),
    'installStatusItem() still reaches for a system symbol. An SF Symbol in the menu bar is a '
    + 'stand-in for the mark, and it is indistinguishable from every other app gesturing at a '
    + 'screen');
}

/**
 * The journey lands where it hands over, and never stands in the way.
 *
 * One camera from the hero to the download (js/tunnel.js), with two places
 * where one picture becomes another: the printed screen becomes the recorded
 * desktop, and the desktop's notch becomes the band's, the download link. Each
 * only reads as one camera if both sides agree on the same place and size, so
 * this drives the pure camera from a phone to a wide display the way the page
 * scrolls it: the dive aims at the wide shot and the desktop is laid on the
 * print's own screen until then, the notch hangs from the top of the window as
 * it does from a display, the wide shot fills the window with the desktop, the
 * close shot never draws a point of the footage past 1.8 CSS pixels and keeps
 * the player clear of the words, and the title and then the how-to are up
 * while the camera holds.
 *
 * Then the handover. The download is drawn up under the desktop, its notch
 * wherever the camera has the desktop's, and the camera pushes in and down
 * onto it: the words and the player away first, it lands with the link at the
 * window's centre, larger than any shot the film held and still with the
 * desktop filling the window below its edge, and the desktop goes back to
 * print there, to nothing by the time the page has the download in hand, so
 * letting the pin go changes nothing on screen. No stretch of it sits: every
 * twentieth of a window scrolled moves the camera or a fade, what the dots
 * show among them. And nothing jumps: stepped a scrolled pixel at a time, a fade
 * takes at least fifty pixels of scroll, the desktop and the band's notch move
 * at most four pixels for each one scrolled, and the desktop's size changes by
 * at most a percent.
 *
 * Between the two, the camera keeps the footage's time, not the scroll's: in
 * on the player while it is played, out to the whole desktop as it goes into
 * the notch, and in again before the loop wraps, so the seam is one shot and
 * every zoom takes a second and a half or more — a move, not a cut.
 *
 * And the download is the page's point, so the journey keeps out of its way:
 * the download is on paper and at least a window tall, unseen until it is
 * drawn up and then held there by the page, not a script, the pinned film
 * goes once it is covered, and the film, a
 * picture laid over the download's first screen, lets the clicks meant for
 * the band through. Each was broken once: the footage covered the link until
 * it reached the top edge, the transparent film took every click, a download
 * shorter than the window showed the pinned how-to under it, the pin, left
 * up, showed its words again under the download as the page went on, the
 * halftone kept a soft dot at nothing, a pink haze on the band that went in
 * one frame as the pin did, and the download, held against the scroll by a
 * script a frame behind it, jumped off the desktop on every fast scroll.
 */
function theJourneyLandsWhereItHandsOver() {
  const source = readFileSync(join(here, '..', 'js', 'tunnel.js'), 'utf8');
  require(/hero\?\.setDive\(dive, hold\(vw, vh\), scrollY,/.test(source),
    'the hero dives somewhere other than where the footage holds — the printed notch and the '
    + 'footage no longer meet');
  require(/scrollY, dive >= 1 && s >= SETTLE\);/.test(source),
    'the print is not put away once the desktop has covered it — as the pull lets the desktop go, '
    + 'the hero\'s zoomed screen shows through behind the download');
  require(/const laid = dive < 1 \? hero\?\.notchAt\(\) : null;/.test(source)
      && /const \{ x, y, scale \} = laid \|\| c;/.test(source),
    'the display that comes on over the print is not laid on the print\'s own screen while the dive '
      + 'is still moving — the two pictures part as the camera pushes in');
  // The placement skips a frame whose values it has already written. A value
  // left out of that key freezes while the camera holds still: the words
  // coming up in the hold did, and never showed.
  const placed = braceBlock(source, source.indexOf('function place(')) ?? '';
  const key = /const key = ([\s\S]*?);\n/.exec(placed)?.[1] ?? '';
  const written = [
    ...placed.matchAll(/setProperty\('(--[\w-]+)', ([^;]+)\);/g),
    ...placed.matchAll(/toggleAttribute\('([\w-]+)', ([^;]+)\);/g),
    ...placed.matchAll(/\.(hidden) = ([^;]+);/g),
    ...placed.matchAll(/\.style\.(transform|translate) = ([^;]+);/g),
  ];
  require(key && written.length >= 15, 'could not read the placement\'s skip key and the values it writes');
  for (const [, property, value] of written) {
    const names = [...value.matchAll(/(?<![\w.])(on|dive|pitch|far|held|drawn|x|y|scale|c\.\w+|at\.\w+)\b/g)]
      .map((m) => m[1]);
    require(names.length, `could not tell what ${property} is written from`);
    for (const name of names) {
      require(new RegExp(`(?<![\\w.])${name.replace('.', '\\.')}\\b`).test(key),
        `the placement writes ${property} from ${name}, but its skip key does not read ${name} — `
        + 'whenever only that changes, the frame is skipped and it stays where it was');
    }
  }
  const css = readFileSync(join(here, '..', 'css', 'magnetite.css'), 'utf8');
  const filmRule = /\.film\[data-tunnel="on"\]\s*\{([^}]*)\}/.exec(css)?.[1] ?? '';
  require(/(?:^|;|\*\/)\s*pointer-events\s*:\s*none\s*;/.test(filmRule),
    'the journeying film takes pointer events — it lies over the download\'s first screen, and the '
    + 'band\'s link under it cannot be clicked');
  // The film's scroll: its height in the stylesheet, less the window it pins.
  const tall = Number(/(?:^|;|\*\/)\s*height\s*:\s*(\d+)vh\s*;/.exec(filmRule)?.[1]);
  require(tall > 100, 'could not read the journeying film\'s height from magnetite.css');
  // The journey's footage is FOOTAGE's box of the desktop, which js/touches.js
  // draws the hand in: the same points, or the fingers land beside the player.
  const stageRule = /\.film\[data-tunnel="on"\] \.film__stage\s*\{([^}]*)\}/.exec(css)?.[1] ?? '';
  const px = (prop) => +(new RegExp(`(?:^|[;\\s])${prop}:\\s*(\\d+)px;`).exec(stageRule)?.[1] ?? NaN);
  require(px('left') === FOOTAGE.x && px('width') === FOOTAGE.width && px('height') === FOOTAGE.height,
    `the journey lays the footage at ${px('left')}pt, ${px('width')}x${px('height')}, not at FOOTAGE's `
    + `${FOOTAGE.x}pt, ${FOOTAGE.width}x${FOOTAGE.height} — it is not where it was shot on the still`);
  // The download lies under the film, on paper, a window tall at least: the
  // desktop lands on it and goes back to print over it; and the pin goes once
  // the page has it.
  const getRule = /\[data-journey="on"\] \.get\s*\{([^}]*)\}/.exec(css)?.[1] ?? '';
  const sheetRule = /\[data-journey="on"\] \.get__sheet\s*\{([^}]*)\}/.exec(css)?.[1] ?? '';
  const z = (rule) => Number(/(?:^|;|\*\/)\s*z-index\s*:\s*(\d+)\s*;/.exec(rule)?.[1]);
  require(z(getRule) < z(filmRule) && /(?:^|;|\*\/)\s*background\s*:\s*var\(--paper\)(?: var\(--tooth\))?\s*;/.test(sheetRule),
    'the journey\'s download is not under the film on paper — drawn up through the handover, it covers '
    + 'the desktop the camera is landing on, or shows the film through it');
  require(/(?:^|;|\*\/)\s*min-height\s*:\s*100svh\s*;/.test(sheetRule),
    'the journey\'s download can be shorter than the window — landed, it leaves the pinned how-to '
    + 'showing under it until the pin goes');
  // The page holds it through the handover, not a script: its sheet stuck to
  // the window at --held on a runway reaching --ahead up the film from where
  // the page lets it go. A scroll moves the page before any script hears of
  // it, so a download a script held against the scroll went a frame's scroll
  // off the desktop and back on every fast one.
  const ahead = Number(/(?:^|;|\*\/)\s*--ahead\s*:\s*(\d+)svh\s*;/.exec(getRule)?.[1]);
  require(ahead > 0 && /(?:^|;|\*\/)\s*margin-top\s*:\s*calc\(-100svh - var\(--ahead\)\)\s*;/.test(getRule)
      && /\[data-journey="on"\] \.get::after\s*\{\s*content\s*:\s*""\s*;\s*display\s*:\s*block\s*;\s*height\s*:\s*var\(--ahead\)\s*;\s*\}/.test(css)
      && /(?:^|;|\*\/)\s*position\s*:\s*sticky\s*;/.test(sheetRule)
      && /(?:^|;|\*\/)\s*top\s*:\s*var\(--held, 0px\)\s*;/.test(sheetRule)
      && /\n\s*const \{ drawn, held \} = sheet\(s, end, c\.y, at \? at\.y : 0\);/.test(placed)
      && /\n\s*const end = page \? \(get\.getBoundingClientRect\(\)\.bottom - page\.height - box\.top\) \/ vh : Infinity;/.test(placed)
      && /\n\s*get\.toggleAttribute\('data-drawn', drawn\);/.test(placed)
      && /\n\s*get\.style\.setProperty\('--held', `\$\{held\.toFixed\(1\)\}px`\);/.test(placed),
  'the journey\'s download is not held by the page through the handover — held by a script against the '
    + 'scroll, it moves a frame late, and on a fast scroll it jumps off the desktop and back');
  // The desktop lands on the band's bar at whatever fraction of a pixel the
  // camera has, over a print whose edges its screen softens: the bezel's ink
  // runs a pixel or more under it, or a hair of the printed bar shows between.
  const band = readFileSync(join(here, '..', 'js', 'band.js'), 'utf8');
  const lip = Number(/\nconst LIP = ([\d.]+);/.exec(band)?.[1]);
  require(lip >= 1 && /\n\s*K\.fillRect\(0, 0, w, edge \+ LIP\);/.test(band),
    'the band\'s bezel stops at the bar\'s top edge — a hairline of the printed bar shows between the riso '
    + 'edge and the desktop landing on it');
  require(/\[data-journey="on"\] \.get:not\(\[data-drawn\]\) \.get__sheet\s*\{\s*opacity\s*:\s*0\s*;\s*pointer-events\s*:\s*none\s*;\s*\}/.test(css),
    'the download shows on its runway before the handover draws it — through the dive, and under the '
    + 'desktop where the clicks the film lets through land on its link');
  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  require(/\[data-journey="on"\] \.get__mark\s*\{\s*top\s*:\s*var\(--ahead\)\s*;\s*\}/.test(css)
      && /<section class="get"[^>]*>\s*(?:<!--[\s\S]*?-->\s*)?<span class="get__mark" id="download"><\/span>/.test(page)
      && !/<section class="get"[^>]*\bid=/.test(page),
  'the link to the download lands at the top of its runway, in the film, not where the page has it');
  require(/\.film\[data-tunnel="on"\]\[data-covered\] \.film__pin\s*\{\s*visibility\s*:\s*hidden\s*;\s*\}/.test(css),
    'the pinned film stays up once the download has covered it — its words show again under the '
    + 'download as the page goes on');
  // The band's notch as the page lays it: as wide as a display's filling the
  // window at least, and as the close shot's; its depth 32 of its 185 points;
  // and at the window's centre under a heading that fills the window above
  // its bezel.
  const notchRule = /(?:^|;|\*\/)\s*--notch-w\s*:\s*max\(clamp\((\d+)px, (\d+)vw, (\d+)px\), 100vw \* 185 \/ 1512, 100svh \* 185 \/ 982,\s*min\((\d+)px, \(100vw - (\d+)px\) \* 185 \/ (\d+), \(100svh - (\d+)px\) \* 185 \/ (\d+)\)\)\s*;/
    .exec(getRule)?.slice(1).map(Number);
  require(notchRule, 'the journey\'s band does not size its notch as a display\'s filling the window and '
    + 'the close shot\'s at least — landed on it, the desktop leaves paper beside or under it, or the '
    + 'camera pulls out to land');
  const [least, share, most, closeW, sides, playerW, foot, playerH] = notchRule;
  const baseRule = /(?:^|\n)\.get\s*\{([^}]*)\}/.exec(css)?.[1] ?? '';
  const deep = Number(/(?:^|;|\*\/)\s*--notch-h\s*:\s*calc\(var\(--notch-w\) \* (\d+) \/ 185\)\s*;/.exec(baseRule)?.[1]);
  require(deep > 0, 'could not read the band\'s notch depth from magnetite.css');
  const titleRule = /\[data-journey="on"\] \.get__title\s*\{([^}]*)\}/.exec(css)?.[1] ?? '';
  require(/(?:^|;|\*\/)\s*min-height\s*:\s*calc\(50svh - var\(--bezel\) - var\(--notch-h\) \/ 2\)\s*;/.test(titleRule),
    'the journey\'s heading does not fill the window above the bezel — the download\'s notch, and the '
    + 'camera landing on it, is not at the window\'s centre');
  // The halftone the desktop goes off through: a dot's radius DOT pitches
  // times the square of --on, which js/tunnel.js reads what the dots show
  // from, and its soft edge a share of the pitch and no wider than the dot.
  const dotsRule = /\.film\[data-tunnel="on"\] \.film__mac\[data-dots\]\s*\{([^}]*)\}/.exec(css)?.[1] ?? '';
  const dot = Number(/(?:^|;|\*\/)\s*--r\s*:\s*calc\(var\(--on\) \* var\(--on\) \* ([\d.]+) \* var\(--dot\)\)\s*;/
    .exec(dotsRule)?.[1]);
  require(dot === DOT, `the halftone's dots are ${dot} pitches at their largest in magnetite.css and ${DOT} in `
    + 'js/tunnel.js — the desktop goes off unevenly, closed a while and then a lingering haze');
  // Going off, the dots go from the notch out: a band of halftone (the dots
  // less a clearing from the notch) with solid beyond it, both edges
  // ellipses about the notch, `across` times as far across as down. Solid all
  // over at --gone 0, the solid past the window's farthest corner at 1, and
  // the band never closed up into a hard edge between them.
  require(/\n\s*mac\.toggleAttribute\('data-going', dive >= 1\);/.test(placed),
    'the desktop going off is not marked to go from the notch out — it dissolves all over at once, the '
    + 'link no sooner than the corners');
  require(/\n\s*const far = dive < 1 \? REACH : reach\(x, y, scale, vw, vh\);/.test(placed),
    'the dots going off are not measured out to the window\'s own corners — on a window smaller than the '
    + 'desktop they sweep off it early and the rest of the scroll shows nothing changing');
  const goingRule = /\.film\[data-tunnel="on"\] \.film__mac\[data-dots\]\[data-going\]\s*\{([^}]*)\}/.exec(css)?.[1] ?? '';
  const inParens = (text, open) => {
    let depth = 0;
    for (let i = open; i < text.length; i++) {
      if (text[i] === '(') depth++;
      else if (text[i] === ')' && --depth === 0) return text.slice(open + 1, i);
    }
    return null;
  };
  // A rule's mask layers, split at the mask-image's top-level commas.
  const maskLayers = (rule) => {
    const value = /(?:^|;|\*\/)\s*mask-image\s*:\s*([^;]*);/.exec(rule)?.[1] ?? '';
    const parts = [];
    let depth = 0;
    let from = 0;
    for (let i = 0; i < value.length; i++) {
      if (value[i] === '(') depth++;
      else if (value[i] === ')') depth--;
      else if (value[i] === ',' && depth === 0) {
        parts.push(value.slice(from, i).trim());
        from = i + 1;
      }
    }
    return [...parts, value.slice(from).trim()];
  };
  const layers = maskLayers(goingRule);
  const edge = (layer) => {
    if (!layer?.startsWith('radial-gradient(')) return null;
    layer = inParens(layer, 'radial-gradient'.length) ?? '';
    const shape = /^calc\(var\(--reach\) \* ([\d.]+)\) var\(--reach\) at 50% 0,/.exec(layer);
    const stop = (colour) => {
      const from = layer.indexOf(`${colour} calc(`);
      const body = from >= 0 ? inParens(layer, from + colour.length + ' calc'.length) : null;
      if (!body || !/^[\d\s.()*+-]*$/.test(body.replace(/var\(--gone\)/g, '').replace(/100%/g, ''))) return null;
      // The stop as a share of the edge's ray at --gone g.
      return new Function('g', `return ${body.replace(/var\(--gone\)/g, 'g').replace(/100%/g, '1')};`);
    };
    return shape && { wide: Number(shape[1]), clear: stop('transparent'), solid: stop('#000') };
  };
  let [front, dots, core] = layers;
  // The same dots as coming on, the one declaration of them both masks use.
  require(dots === 'var(--dots)' && maskLayers(dotsRule)[1] === 'var(--dots)',
    'the dots the desktop goes off through are not the ones it came on through — two copies of the '
    + 'halftone in magnetite.css, and a fix to one leaves the other as it was');
  [front, core] = [edge(front), edge(core)];
  require(layers.length === 3 && front?.clear && front.solid && core?.clear && core.solid
      && front.wide === core.wide && /(?:^|;|\*\/)\s*mask-composite\s*:\s*add, intersect, add\s*;/.test(goingRule),
  'could not read the going desktop\'s halftone band from magnetite.css: the solid past its front, the '
    + 'dots, and the clearing behind it, ellipses about the notch');
  const across = front.wide;
  require(core.solid(0) <= 0, 'the desktop starts going off with a hole already cleared at the notch — it '
    + 'jumps as the dots appear');
  require(front.clear(1) >= 1, 'the desktop gone off still has solid beyond the halftone\'s front in the '
    + 'window\'s far corners — it goes in one frame as the pin does');
  require(core.clear(1) <= 1 + 1e-9,
    `the clearing reaches the window's farthest corner at --gone `
    + `${((1 - core.clear(0)) / (core.clear(1) - core.clear(0))).toFixed(2)}, `
    + 'before the page has the download — the last of the scroll moves nothing');
  for (let g = 0; g <= 1; g += 0.01) {
    require(front.clear(g) - core.solid(g) >= 0.05,
      `at --gone ${g.toFixed(2)} the solid meets the clearing with no halftone between — a hard edge wiped `
      + 'across the screen, not a print');
  }
  require(/(?:^|;|\*\/)\s*--dots\s*:\s*radial-gradient\(circle, #000 var\(--r\), transparent calc\(var\(--r\) \+ min\(var\(--dot\) \/ \d+, var\(--r\)\)\)\)\s*;/
    .test(dotsRule),
  'the halftone\'s dots keep a soft edge at nothing, or one in the desktop\'s points — gone back to '
    + 'print the desktop leaves a haze on the band that goes in one frame with the pin, or, close, the '
    + 'blur holds the dots shut while the scroll goes on');

  // The camera on the footage's clock.
  const seconds = filmSeconds();
  require(focus(0) === 1 && focus(seconds) === 1 && SHOTS.in[1] <= seconds,
    `the camera is not close at both ends of the film's ${seconds.toFixed(2)}s — the loop wraps `
    + 'from one shot to another, a cut every lap');
  require(SHOTS.out[1] <= SHOTS.in[0] && focus((SHOTS.out[1] + SHOTS.in[0]) / 2) === 0,
    'the camera never goes out to the whole desktop while the player goes into the notch');
  for (let t = 0; t + 1 / 60 <= seconds; t += 1 / 60) {
    require(Math.abs(focus(t + 1 / 60) - focus(t)) <= 1 / 30,
      `the camera cuts at ${t.toFixed(2)}s — a zoom quicker than a second and a half is a cut`);
  }
  const shotAt = { close: 0, wide: (SHOTS.out[1] + SHOTS.in[0]) / 2 };

  for (const [vw, vh] of [[390, 844], [682, 863], [768, 1024], [1280, 720], [1440, 900], [2560, 1440]]) {
    const at = hold(vw, vh);
    const { wide, close } = shots(vw, vh);
    require(at.y === 0 && at.x === vw / 2,
      `${vw}x${vh}: the held notch is at (${at.x}, ${at.y}), not hanging from the middle of the `
      + 'window\'s top edge — a notch in the middle of a desktop is no display');
    // The display is 1512 by 982 points.
    require(at.scale === wide && 1512 * wide >= vw - 1e-9 && 982 * wide >= vh - 1e-9,
      `${vw}x${vh}: the wide shot leaves the page showing round the desktop that is meant to be the screen`);
    require(close >= wide && close <= 1.8,
      `${vw}x${vh}: the close shot draws a point at ${close.toFixed(3)} CSS pixels — past 1.8, the `
      + 'footage\'s two pixels a point are upsampled soft on a 2x display');
    require(close === wide || (PLAYER.width * close <= vw - 32 && PLAYER.height * close <= vh - WORDS),
      `${vw}x${vh}: the close shot runs the player into the window's edge or under its words`);
    // The band's notch as the page lays it, where it stands with the download
    // at the window's top: centred, the heading and bezel above it.
    const notchW = Math.max(Math.min(most, Math.max(least, vw * share / 100)), vw * 185 / 1512, vh * 185 / 982,
      Math.min(closeW, (vw - sides) * 185 / playerW, (vh - foot) * 185 / playerH));
    const dock = { x: vw / 2, y: vh / 2 - notchW * deep / 185 / 2, scale: notchW / 185 };
    // Landed there, the dots go out as far as the window's farthest corner
    // below the desktop's edge, measured the way the band's ellipse is.
    const corner = Math.max(...[0, vw].map((cx) => Math.hypot((cx - dock.x) / across, vh - dock.y))) / dock.scale;
    const far = reach(dock.x, dock.y, dock.scale, vw, vh);
    require(far >= corner - 1e-9,
      `${vw}x${vh}: the dots going off reach ${far.toFixed(0)}pt from the notch, short of the window's `
      + `corner at ${corner.toFixed(0)}pt — the corner goes in one frame with the pin`);
    require(far <= corner * 1.01,
      `${vw}x${vh}: the dots going off reach ${far.toFixed(0)}pt from the notch, past the window's corner `
      + `at ${corner.toFixed(0)}pt — they sweep off the window early and the last of the scroll shows nothing`);
    // The download overlaps the film's last screen, so the page lets its
    // sheet go `run` down from the window's top at the pin, coming up a pixel
    // for each one scrolled, and reaching the window's top at `end`. Its
    // runway starts `ahead` further up, where the sheet stands until the
    // window's top reaches it and, stuck, holds at --held until the runway's
    // foot brings it away. A step is one pixel of scroll.
    const run = vh * (tall / 100 - 1);
    const end = run / vh;
    const last = Math.ceil(run + vh * 0.2);
    for (const [shot, t] of Object.entries(shotAt)) {
      const film = shot === 'close' ? close : wide;
      const frames = Array.from({ length: last + 1 }, (_, s) => {
        const c = camera(s / vh, vw, vh, dock, t, end);
        const { drawn, held } = sheet(s / vh, end, c.y, dock.y);
        const top = Math.min(Math.max(run - s - vh * ahead / 100, held), run - s);
        return { ...c, drawn, top, dots: shown(DOT * c.on * c.on) };
      });
      const start = frames[0];
      require(start.live === 1 && start.words === 0 && start.how === 0 && start.on === 1 && !start.covered
          && start.x === at.x && start.y === at.y && start.scale === at.scale,
      `${vw}x${vh}: the camera is not on the wide shot, the footage whole and its words not yet up, `
        + 'where the dive hands it over');
      require(frames.some((c) => c.live === 1 && c.words === 1 && c.how === 1 && !c.drawn
          && c.x === at.x && c.y === at.y && Math.abs(Math.log(c.scale / film)) < 1e-9),
      `${vw}x${vh}: the camera never holds on the footage's own ${shot} shot with its title and `
        + 'how-to up before the handover');
      const drawn = frames.findIndex((c) => c.drawn);
      const covered = frames.findIndex((c) => c.covered);
      require(drawn > 0 && covered > drawn,
        `${vw}x${vh}: the download is never drawn up under the desktop before the page brings it`);
      const onDock = (c) => Math.abs(c.x - dock.x) < 1e-6 && Math.abs(c.y - dock.y) < 1e-6
        && Math.abs(Math.log(c.scale / dock.scale)) < 1e-9;
      const landed = frames.findIndex(onDock);
      require(landed > drawn && landed <= covered && frames[landed].live === 0
          && frames[landed].words === 0 && frames[landed].how === 0,
      `${vw}x${vh}: the camera does not land on the band's notch, with the player and the words away, `
        + 'before the page has the download in hand');
      // It lands no further out than any shot the film held, so it never
      // pulls out onto the link, with the desktop still filling the window
      // below its edge.
      const inward = dock.scale >= close * (1 - 1e-9);
      require(inward && 1512 * dock.scale >= vw - 1e-9 && dock.y + 982 * dock.scale >= vh - 1e-9,
        `${vw}x${vh}: the camera lands on the band's notch at x${dock.scale.toFixed(3)}, `
        + (inward ? 'leaving paper beside or under the desktop'
          : `no closer than the close shot's x${close.toFixed(3)} — it pulls out onto the link`));
      const off = frames[covered];
      require(onDock(off) && off.on === 0 && off.gone === 1 && off.live === 0 && off.words === 0 && off.how === 0,
        `${vw}x${vh}: the page takes the download over with the camera at (${off.x.toFixed(1)}, `
        + `${off.y.toFixed(1)}) x${off.scale.toFixed(3)} and the desktop ${(off.on * 100).toFixed(0)}% on — `
        + 'letting the pin go jumps');
      for (let s = 0; s <= last; s++) {
        const f = frames[s];
        // Before it is drawn the stylesheet keeps it unseen and unclickable
        // (above), wherever its runway has it.
        if (s < drawn) continue;
        if (s < covered) {
          require(Math.abs(f.top + dock.y - f.y) < 1e-6 && 1512 * f.scale >= vw - 1e-9
              && f.y + 982 * f.scale >= vh - 1e-9,
          `${vw}x${vh}: ${s}px in, the band's notch is at ${(f.top + dock.y).toFixed(1)}, not under the `
            + `desktop's at ${f.y.toFixed(1)}, or the desktop leaves the window's foot or sides bare`);
          // The band shows through only as the desktop goes, which it does
          // only with the camera all but landed: short of it, the two notches
          // and menu bars show at two sizes.
          require(f.on === 1 || (Math.abs(Math.log(f.scale / dock.scale)) <= 0.025
              && Math.abs(f.y - dock.y) <= 0.025 * vh),
          `${vw}x${vh}: ${s}px in, the desktop goes back to print with the camera at `
            + `x${f.scale.toFixed(3)}, ${f.y.toFixed(1)}px down, short of the band's notch — the two show at `
            + 'two sizes');
          // The camera is on its way as soon as the words start to go, so no
          // frame holds the desktop emptied of them.
          require(f.words >= frames[drawn - 1].words || f.y > at.y,
            `${vw}x${vh}: ${s}px in, the words are going with the camera still on the ${shot} shot — it `
            + 'holds the emptied desktop');
        } else {
          require(f.drawn && f.top === run - s,
            `${vw}x${vh}: ${s}px in, the download is still held after the page has it`);
        }
      }
      // No stretch of the handover sits: every twentieth of a window moves the
      // desktop two pixels or its size half a percent, or a fade three
      // hundredths.
      const span = Math.round(vh / 20);
      for (let s = drawn; s + span <= covered; s++) {
        const [a, b] = [frames[s], frames[s + span]];
        require(Math.hypot(b.x - a.x, b.y - a.y) >= 2 || Math.abs(Math.log(b.scale / a.scale)) >= 0.005
            || ['live', 'words', 'how', 'dots', 'gone'].some((k) => Math.abs(b[k] - a[k]) >= 0.03),
        `${vw}x${vh}: from ${s}px in, a twentieth of a window of scroll moves nothing on the ${shot} `
          + 'shot — the handover sits');
      }
      for (let s = 1; s <= last; s++) {
        const [a, b] = [frames[s - 1], frames[s]];
        require(!a.covered || b.covered, `${vw}x${vh}: ${s}px in, the desktop comes back after the band covered it`);
        require(b.words >= b.how, `${vw}x${vh}: ${s}px in, the how-to is further up than its title`);
        // The dots take the desktop away as evenly as the clearing does: what
        // they show is what the wave has left, or a haze lingers.
        require(Math.abs(b.dots - (1 - b.gone)) < 1e-3,
          `${vw}x${vh}: ${s}px in, the dots show ${(b.dots * 100).toFixed(0)}% of the desktop with the wave `
          + `${(b.gone * 100).toFixed(0)}% gone — a haze lingers after it`);
        require(b.live < 1 || b.words + b.how === 0 || close === wide
            || b.y + PLAYER.height * b.scale <= vh - WORDS,
        `${vw}x${vh}: ${s}px in, the player runs under the words on the ${shot} shot`);
        require(['live', 'words', 'how', 'dots', 'gone'].every((k) => Math.abs(b[k] - a[k]) <= 0.02)
            && Math.hypot(b.x - a.x, b.y - a.y) <= 4
            && Math.abs(Math.log(b.scale / a.scale)) <= 0.01
            && (s <= drawn || Math.abs(b.top - a.top) <= 4),
        `${vw}x${vh}: the camera jumps ${s}px in, on the ${shot} shot`);
      }
    }
  }
}

/** The length of media/film.mp4 in seconds, read from its own movie header. */
function filmSeconds() {
  const mp4 = readFileSync(join(here, '..', 'media', 'film.mp4'));
  const at = mp4.indexOf('mvhd');
  require(at > 4 && mp4[at + 4] === 0, 'media/film.mp4 has no version-0 movie header');
  return mp4.readUInt32BE(at + 20) / mp4.readUInt32BE(at + 16);
}

/**
 * The hand drawn on the film goes the way the app reads it.
 *
 * The recording cannot show a two-finger swipe, only what it did, so the page
 * draws the fingers on the desktop under the player (js/touches.js). Drawn the
 * wrong way, they would teach the wrong gesture on the one page that explains
 * it: the app reads fingers moving right as forward and a vertical swipe as
 * pause and play, so a forward cue must carry them right, a back cue left and
 * a pause straight down, never back towards rest before it fires. Every line
 * of the how-to the drawing lights has to exist, in the markup and the
 * stylesheet, or it lights nothing; everything drawn stays on the footage's
 * box of the desktop and inside the player the close shot frames, and the
 * camera is close whenever a touch is drawn, or it is too small to read;
 * between cues nothing shows; and only the journey draws it, since only there
 * is the footage laid out in its own points, and Reduce Motion never starts
 * the journey.
 */
function theHandInTheFilmGoesTheWayTheAppReadsIt() {
  const swift = readFileSync(join(here, '..', '..', 'Sources', 'NotchApp', 'Notch',
    'SwipeRecogniser.swift'), 'utf8');
  require(/let action: Action = x > 0 \? \.skipForward : \.skipBackward/.test(swift),
    'SwipeRecogniser no longer states that fingers moving right skip forward — the drawn '
    + 'fingers in js/touches.js follow that rule, so check it again before trusting them');
  require(/if ay >= threshold, ay > ax \* dominance \{[^}]*return Step\(action: \.togglePlayback\)/.test(swift),
    'SwipeRecogniser no longer states that a vertical swipe pauses and plays — the drawn '
    + 'fingers in js/touches.js follow that rule, so check it again before trusting them');
  const swipes = CUES.filter((c) => c.kind === 'swipe');
  require(swipes.some((c) => c.axis === 'x' && c.dir === 1) && swipes.some((c) => c.axis === 'x' && c.dir === -1)
      && swipes.some((c) => c.axis === 'y'),
  'the film draws the swipes only some of the ways the footage does them: forward, back, and pause');
  for (const cue of swipes) {
    const [along, across] = cue.axis === 'x' ? ['dx', 'dy'] : ['dy', 'dx'];
    const way = cue.axis === 'y' ? 'down, pause' : cue.dir > 0 ? 'forward, right' : 'back, left';
    let was = 0;
    for (let t = cue.down + 0.01; t <= cue.up + 0.2; t += 0.01) {
      const { hand, doing } = touchesAt(t);
      require(hand[across] === 0 && (hand[along] === 0 || Math.sign(hand[along]) === cue.dir),
        `at ${t.toFixed(2)}s the fingers are (${hand.dx.toFixed(1)}, ${hand.dy.toFixed(1)})pt from rest, `
        + `for a swipe that goes ${way} — the drawing shows another gesture`);
      require(Math.abs(hand[along]) >= was,
        `at ${t.toFixed(2)}s the fingers turn back before the swipe fires — the app counts `
        + 'distance travelled, so the drawing says it would not');
      was = Math.abs(hand[along]);
      require(hand.shown > 0 && doing === 'swipe',
        `at ${t.toFixed(2)}s the fingers are down in the footage but not drawn, or the how-to `
        + 'does not say so');
    }
    const fired = touchesAt(cue.up).hand;
    require(fired.shown === 1 && Math.abs(fired[along]) >= HAND.reach * 0.75,
      `as the ${way} swipe fires at ${cue.up}s the fingers are ${Math.abs(fired[along]).toFixed(1)}pt `
      + 'from rest — too little of a swipe to read as one');
  }
  // Drawn only in the close shot: the swipes, the click and the scrub, from
  // the touch landing until it has lifted and gone.
  for (const cue of CUES.filter((c) => c.kind !== 'hover')) {
    const from = cue.down ?? cue.at;
    const to = (cue.up ?? cue.at + 0.5) + 0.22;
    for (let t = from; t <= to; t += 0.02) {
      require(focus(t) === 1,
        `at ${t.toFixed(2)}s the ${cue.kind} is drawn while the camera is out on the whole desktop, `
        + 'where it is too small to read');
    }
  }
  const page = readFileSync(join(here, '..', 'index.html'), 'utf8');
  const css = readFileSync(join(here, '..', 'css', 'magnetite.css'), 'utf8');
  const site = codeOnly(readFileSync(join(here, '..', 'js', 'site.js'), 'utf8'));
  require(/\nconst tunnel = startTunnel\(/.test(site)
      && /\nif \(tunnel\) startTouches\(film, document\.querySelector\('\.how'\)\);/.test(site)
      && (site.match(/startTouches\(/g) || []).length === 1,
    'the fingers are drawn without the journey — outside it the footage is not in its own '
    + 'points, so they land beside what they point at, and Reduce Motion gets them too');
  // The box it may draw in, in display points: the footage's, and within it
  // the player as the close shot frames it, hanging from the notch's middle.
  const box = {
    left: Math.max(FOOTAGE.x, 756 - PLAYER.width / 2),
    right: Math.min(FOOTAGE.x + FOOTAGE.width, 756 + PLAYER.width / 2),
    top: FOOTAGE.y,
    bottom: Math.min(FOOTAGE.y + FOOTAGE.height, PLAYER.height),
  };
  const inside = (x, y) => x >= box.left && x <= box.right && y >= box.top && y <= box.bottom;
  const seconds = filmSeconds();
  const lit = new Set();
  for (let t = 0; t < seconds; t += 1 / 60) {
    const { hand, ring, doing } = touchesAt(t);
    if (doing) lit.add(doing);
    if (hand.shown > 0) {
      // The pair's box: 46 by 24 about its middle, the middle fingertip 2pt higher, 1pt lower.
      const x = HAND.x + hand.dx;
      const y = HAND.y + hand.dy;
      require(inside(x - 23, y - 14) && inside(x + 23, y + 13),
        `at ${t.toFixed(2)}s the fingers are drawn at ${x.toFixed(0)},${y.toFixed(0)}, off the footage `
        + 'or out of the close shot');
    }
    if (ring.shown > 0) {
      require(inside(ring.x, ring.y),
        `at ${t.toFixed(2)}s the ring is at ${ring.x.toFixed(0)},${ring.y.toFixed(0)}, off the footage `
        + 'or out of the close shot');
    }
  }
  for (const cue of CUES) {
    require(Math.max(cue.up ?? 0, cue.at ?? 0, cue.to ?? 0) < seconds,
      `a ${cue.kind} cue runs past the film's ${seconds.toFixed(2)}s`);
  }
  require(lit.size > 0, 'the drawing never lights a line of the how-to');
  for (const how of lit) {
    require(page.includes(`<li data-how="${how}">`),
      `the drawing lights "${how}", which no line of the how-to carries`);
    require(css.includes(`.how[data-doing="${how}"] [data-how="${how}"]`),
      `the stylesheet does not light "${how}"`);
  }
  for (const t of [1, 12, 21]) {
    const { hand, ring, doing } = touchesAt(t);
    require(hand.shown === 0 && ring.shown === 0 && doing === null,
      `at ${t}s, between cues, the drawing still shows`);
  }
}

const CHECKS = {
  theReplayMatchesTheShippingPhysics,
  theReplayIsSteppedLikeTheApp,
  theReplayClockIsTheAppsClock,
  theCaptureIsReplayedAtItsOwnRate,
  theCardIsTheSizeThePagePromises,
  aSkipLeansTheWayItWent,
  theInkFollowsTheShellSlowlyAndLeavesQuickly,
  theSwellTrailsTheCursor,
  theFieldNotesStayInTheSource,
  theOutlineIsTheShippingOutline,
  theSurfaceNormalTurnsWithTheSurface,
  aPeakHoldsBelowTheFieldThatRaisedIt,
  theCrownIsCapped,
  theHaloEasesRatherThanSwitching,
  theCapturedAudioIsTheAppsOwn,
  theStatedFloorIsTheBuildsFloor,
  theDownloadLinkPointsAtARealBuild,
  theSiteIsCrawlableAtItsCanonicalDomain,
  thePoliciesStateTheActualBoundaries,
  theTypeLoadsFromTheSiteItBelongsTo,
  theFirstLaunchStoryMatchesTheBuild,
  theFrameLoopCannotRunTwice,
  theSoundtrackUsesTheAppsBands,
  thePageExposesOnlyReadOnlyDiscoveryTools,
  theDemoIsTheAppOnFilm,
  theCreditSitsInTheFlow,
  theCreditLinksWhatItBorrows,
  theCreditBreaksBetweenNamesOnly,
  theStillIsAFrameOfTheFluid,
  theStillIsAFrameOfTheFilm,
  theDriveIsTheExponentialItClaims,
  theInkIsOneInkAndThePaperOnePaper,
  theOffscreenEconomyNeverBlanksThePage,
  theFilmPlaysWhereItIsWatched,
  thePreferenceIsReadTheWayItIsAsked,
  theLoopSpendsTheClockItWasGiven,
  eachCameraIsPaintedWithTheFluidItIsAimedAt,
  theCameraIsResizedIntoItsNewScale,
  theMarkIsTheIconsOwnContour,
  theJourneyLandsWhereItHandsOver,
  theHandInTheFilmGoesTheWayTheAppReadsIt,
};

const only = process.argv.find((a) => a.startsWith('--only='));
const selected = only ? [only.slice('--only='.length)] : Object.keys(CHECKS);

for (const name of selected) {
  const check = CHECKS[name];
  if (!check) {
    process.stderr.write(`portcheck: no such check "${name}"\n`);
    process.exit(2);
  }
  try {
    await check();
  } catch (error) {
    process.stderr.write(`portcheck: ${name} FAILED\n  ${error.message}\n`);
    process.exit(1);
  }
}

process.stdout.write(`portcheck: all checks passed (${selected.length})\n`);
