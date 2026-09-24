// Whether anyone is looking, and whether they asked for motion — as pure
// functions, so the gate can run them.
//
// These decisions lived inside anonymous observer callbacks in `site.js`,
// closed over module state that no gate could construct. What held them was
// text rules that NAME the machinery — `IntersectionObserver`, `onScreen`,
// `reduceMotion` — and cannot see which way any of it points. Six mutants were
// measured against the whole forty-three-check gate and every one went green:
//
//   - `reduceMotion` read as `!matchMedia(...).matches`, so the one visitor who
//     asked for stillness gets the full animation and everyone else gets a
//     frozen page;
//   - `entry.onScreen === false` written as `!entry.onScreen`, which skips
//     every view that has not been observed YET — and on a browser with no
//     `IntersectionObserver` at all, which `site.js` explicitly supports by
//     guarding on `typeof`, that is every view forever: a permanently blank
//     page;
//   - the same for the headline's ink;
//   - the film's transport inverted, so it plays while it is scrolled away
//     from and pauses the moment it comes into view;
//   - the film's pause dropped, so it plays forever offscreen;
//   - `onScreen` assigned `!record.isIntersecting`, drawing exactly the
//     canvases nobody is looking at.
//
// So the decisions are here, with no DOM in them. `shouldDraw` takes the flag
// and not the entry; `watchOutcome` takes plain records and returns what
// changed. The observers keep the parts that are genuinely browser — building
// the observer, reading `.target`, calling `.play()` — and ask this file what
// those parts MEAN.

/**
 * Does this view get drawn?
 *
 * Three-valued on purpose, and that is the whole point of the function.
 * `onScreen` is `undefined` until the observer's first callback, and stays
 * `undefined` for the entire life of a page whose browser has no
 * `IntersectionObserver`. Both of those must DRAW: the gate is an economy for
 * canvases known to be off-screen, never a precondition for the page working
 * at all. Only an explicit `false` — observed, and observed to be away —
 * skips.
 *
 * `!onScreen` is the same function on `true` and on `false` and differs only
 * on `undefined`, which is why nothing that checked the two obvious cases
 * caught it.
 */
export function shouldDraw(onScreen) {
  return onScreen !== false;
}

/**
 * What one delivery of intersection records means.
 *
 * Pure: `records` need only `target` and `isIntersecting`, so the gate can
 * hand it object literals. Returns the new `onScreen` for each target, and
 * whether the loop must be started — a view arriving on screen is the cue, and
 * a loop already running is not restarted.
 */
export function watchOutcome(records, running) {
  const states = [];
  let arrived = false;
  for (const record of records) {
    if (record.isIntersecting) arrived = true;
    states.push([record.target, record.isIntersecting]);
  }
  return { states, start: arrived && !running };
}

/** Beside the film it plays; away from it, it pauses. */
export function filmAction(intersecting) {
  return intersecting ? 'play' : 'pause';
}

/**
 * A page coming back from hidden presses play again — but only beside the
 * film. Offscreen it stays paused, which is the observer's own economy, and
 * resuming there would quietly undo it on every tab switch.
 */
export function filmResume(hidden, beside) {
  return !hidden && beside ? 'play' : 'none';
}

/**
 * One delivery of records, applied.
 *
 * `watchOutcome` decides; this spends the decision, and the spending was the
 * half nothing could reach. `entry.onScreen = onScreen` written `= !onScreen`
 * re-creates the inverted-visibility defect ONE LINE past the module that was
 * extracted to hold it, and survived the whole forty-six-check gate. No text
 * rule can honestly hold that assignment: every identifier in it is free to be
 * renamed, so any rule tight enough to catch the `!` is a rule that fails on a
 * respelling that changed nothing. So the assignment moves here, where a
 * mutant can run it, and `site.js` is left with no write to `.onScreen` at
 * all. An absence is the one rule no respelling survives.
 *
 * `watchOutcome` is left exactly as it was and called, not folded in: it has
 * its own mutants, and reshaping it to suit this would churn every one of them
 * for nothing.
 *
 * Still no DOM. A view needs only `view.canvas` to be matched against a
 * record's `target`, and the gate hands both in as object literals.
 */
export function applyWatch(records, views, running) {
  const { states, start } = watchOutcome(records, running);
  for (const [target, onScreen] of states) {
    const entry = views.find((each) => each.view.canvas === target);
    if (entry) entry.onScreen = onScreen;
  }
  return start;
}

/**
 * The film's transport, holding its own memory of where the film is.
 *
 * `beside` lived in the observer's closure in `site.js`, which left two more
 * seams there that no gate could see: `beside = record.isIntersecting`
 * inverted, and the page's hidden flag inverted on its way to `filmResume`.
 * The first is hopeless to hold textually for the same reason as the
 * assignment above, so the state moves here and `site.js` stops naming
 * `isIntersecting` anywhere — another absence rather than another pattern.
 *
 * The page keeps what is genuinely browser: calling `play()` and `pause()`,
 * and reading `document.hidden`. It is told which one to do.
 *
 * A film nobody has scrolled to yet is not beside anyone, so a tab revealed
 * before the first record starts nothing.
 */
export function filmTransport() {
  let beside = false;
  return {
    observe(record) {
      beside = record.isIntersecting;
      return filmAction(beside);
    },
    revealed(hidden) {
      return filmResume(hidden, beside);
    },
  };
}

/**
 * The motion preference, read off a `MediaQueryList`.
 *
 * Thin by construction: the polarity IS the decision, and the polarity was
 * what nothing held. Everything downstream of it — the still, the loop that
 * never starts, the film's own reduced answer — is already checked, and all of
 * it is checked against a boolean this line is free to invert.
 */
export function prefersReducedMotion(query) {
  return query.matches === true;
}
