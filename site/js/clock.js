// The replay's clock, as a pure function, so it can be checked.
//
// This lived inside `site.js`'s `frame()` and could not be tested there: the
// loop needs a browser, so every gate the suite had read the CONSTANTS and none
// of them read the behaviour. That is exactly how the bug this file exists
// because of survived — `CAPTURE_HZ` was 60 for the capture's whole life, and
// nothing anywhere compared it to the 30 the app publishes at, because nothing
// could run the loop.
//
// So the arithmetic is here, with no DOM in it, and `theReplayClockIsTheAppsClock`
// drives it at 60, 90, 120 and 144Hz and asserts they all produce the same
// sequence. A physics that changes with the display is not the shipping
// physics, and a ProMotion Mac is the machine this product is about.

/**
 * Bank wall time and spend it in whole steps.
 *
 * `steps` is an integer count and `elapsed` is derived from it rather than
 * accumulated, because `elapsed += 1/60` drifts in binary floating point: after
 * a few minutes the drift is enough to hand some captured frame one step or
 * three, which puts the page permanently half a step out of phase with the
 * golden and looks like nothing at all.
 *
 * The remainder is CARRIED, not dropped. A display whose refresh does not
 * divide the step rate — 90Hz, or a 60Hz panel dropping frames — must still
 * spend every millisecond it is handed exactly once, or the replay runs slow by
 * whatever it throws away each callback.
 */
export function bankSteps(state, dt, simStep) {
  let { bank, steps } = state;
  bank += dt;
  while (bank >= simStep) {
    bank -= simStep;
    steps += 1;
  }
  return { bank, steps };
}

/**
 * Which captured frame a physics STEP is driven by, looping back to the
 * quietest frame rather than to the start.
 *
 * Indexed by the integer step, and that is the whole reason it is here rather
 * than in `site.js`. The page used to convert its step counter into seconds and
 * multiply back — `Math.floor((s / SIM_HZ) * CAPTURE_HZ)` — which is not exact
 * in binary floating point. At step 246, `(246 / 60) * 30` is 122.99999999999999,
 * so captured frame 122 was handed THREE steps and frame 123 one: 22 of every
 * 3600 steps landed on the wrong frame, starting four seconds into every page
 * load. 3600 steps at SIM_HZ is one minute, so that IS the first minute's rate;
 * no separate per-minute figure is quoted here because the density is not
 * stable — it climbs over longer windows. This said "about eleven times a
 * minute", which is exactly half of 22, the same 60-for-30 halving the rest of
 * this file exists to correct. The header above justifies the
 * integer `steps` on precisely the grounds that drift must not "hand some
 * captured frame one step or three", and then the call site put the float back.
 *
 * Nothing could see it. `renderStill()` and portcheck's `replayLikeThePage` both
 * walk captured frames in a nested integer loop, so they hold each frame twice
 * BY CONSTRUCTION and cannot reproduce the page's slip; the one gate that names
 * the invariant drove a window of one second, and the first breach is at 4.1s.
 * The arithmetic is a pure function here so that gate can drive the real thing.
 *
 * `Math.floor(step / per)` on integers, not `step * captureHz / simHz`: the
 * quotient form is exact only when the rates divide as a power of two, and this
 * takes the rates as arguments.
 */
export function replayFrame(step, simHz, captureHz, length, loopFrame) {
  const per = Math.round(simHz / captureHz);
  const index = Math.floor(step / per);
  if (index < length) return Math.max(0, index);
  const period = length - loopFrame;
  return loopFrame + ((index - loopFrame) % period);
}

/**
 * The cadence the page replays at, derived in one place.
 *
 * `dt`, the steps a captured frame is held for, and the low pass's per-step
 * rate are all functions of `SIM_HZ`, `CAPTURE_HZ` and `SMOOTH_TAU`, and until
 * this existed they were derived THREE times: once in `site.js`'s replay loop,
 * once in `site.js`'s `renderStill`, and once in portcheck's `pageReplay`,
 * which rebuilt all three expressions from the three constants it read out of
 * the source. The constants were held to the app end to end — see
 * `theCaptureIsReplayedAtItsOwnRate` — and the expressions were held by
 * nothing. `const dt = 2 / SIM_HZ` in `renderStill` passed the whole gate and
 * moved the still's outline by 12.3 points vertically and 16.4 horizontally on
 * a 190-point panel; one step per captured frame moved it 9.0 and 12.7.
 *
 * A gate that rebuilds what the source asked for cannot see that. So there is
 * one spelling now and the gate drives it, which is the same move `replayFrame`
 * above exists because of, one derivation further out.
 */
export function replayCadence(simHz, captureHz, tau) {
  const dt = 1 / simHz;
  return { dt, steps: Math.round(simHz / captureHz), k: 1 - Math.exp(-dt / tau) };
}

/**
 * The drive, low-passed by one step, in place.
 *
 * Exponential, so the response is the same however long the frame took — a
 * dropped frame does not become a lurch. That claim is the check: stepping this
 * n times has to land where the continuous `1 - e^(-n·dt/tau)` lands, at any
 * rate, which the linearised `dt/tau` and a fixed rate both fail. See
 * `theDriveIsTheExponentialItClaims`.
 */
export function smoothStep(drive, target, k) {
  for (let i = 0; i < drive.length; i++) drive[i] += (target[i] - drive[i]) * k;
  return drive;
}

/**
 * Advance `sim` through captured frames 0..`frame` the way the page's loop
 * does, and hand it back.
 *
 * Here rather than in `renderStill` for the reason at the top of this file: the
 * still is the only thing a visitor who asked for no motion is ever shown, and
 * it was chosen BY EYE from candidates rendered under a stepping recipe that
 * `site.js` then had to keep in step with the replay loop by hand. It did not,
 * once already — the first pass chose off a sim stepped once per captured
 * frame, which is not the sequence the loop integrates — and the only thing
 * that caught it was looking again.
 *
 * The gate could already RUN `renderStill`: `theStillIsAFrameOfTheFluid` lifts
 * its body out and executes it against a real sim with an empty `views`. What
 * it asked of the result was that something was standing in it, which every
 * wrong recipe also satisfies. The recipe being a function is what lets
 * `theStillIsAFrameOfTheFilm` ask the harder question instead — the same walk,
 * against the film indexed by `replayFrame`, step for step.
 *
 * The sim is passed in, not made here: the still's seed, its `reduceMotion` and
 * its openness are the page's business and the gate has to be able to set them
 * to the page's values rather than inherit a copy of them.
 */
export function driveStill(sim, levels, frame, cadence) {
  const { dt, steps, k } = cadence;
  const drive = new Array(levels[0].length).fill(0);
  for (let i = 0; i <= frame; i++) {
    for (let s = 0; s < steps; s++) {
      smoothStep(drive, levels[i], k);
      sim.advance(drive, dt);
    }
  }
  return sim;
}
