// Mutation harness for portcheck.mjs.
//
//   node site/test/mutate.mjs
//
// A check that has never been watched to fail is not evidence of anything. Each
// mutant below breaks one specific thing and names the check that must catch
// it; the run reports SURVIVED if it did not.
//
// Every mutant runs FULL and SOLO. Solo is the one that matters: "killed by the
// wrong check" hides a vacuous check behind an unrelated earlier one, and this
// harness is here precisely because that shape has shipped in this repo before.
//
// Nothing is patched in place — the site tree and the app's Resources are
// copied into a temporary directory and the copies are edited, so an
// interrupted run cannot leave a mutation in the working tree.

import { cpSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');

const REPLAY = 'theReplayMatchesTheShippingPhysics';
const SKIP = 'aSkipLeansTheWayItWent';
const INK = 'theInkFollowsTheShellSlowlyAndLeavesQuickly';
const POINTER = 'theSwellTrailsTheCursor';
const FIELD_NOTES = 'theFieldNotesStayInTheSource';
const OUTLINE = 'theOutlineIsTheShippingOutline';
const NORMAL = 'theSurfaceNormalTurnsWithTheSurface';
const HYSTERESIS = 'aPeakHoldsBelowTheFieldThatRaisedIt';
const CROWN = 'theCrownIsCapped';
const HALO = 'theHaloEasesRatherThanSwitching';
const AUDIO = 'theCapturedAudioIsTheAppsOwn';

const FLOOR = 'theStatedFloorIsTheBuildsFloor';
const DOWNLOAD = 'theDownloadLinkPointsAtARealBuild';
const CRAWLABLE = 'theSiteIsCrawlableAtItsCanonicalDomain';
const POLICIES = 'thePoliciesStateTheActualBoundaries';
const LOCAL_TYPE = 'theTypeLoadsFromTheSiteItBelongsTo';
const LOOP = 'theFrameLoopCannotRunTwice';
const STILL = 'theStillIsAFrameOfTheFluid';
const STILLFILM = 'theStillIsAFrameOfTheFilm';
const EXPONENTIAL = 'theDriveIsTheExponentialItClaims';
const HELD = 'theReplayIsSteppedLikeTheApp';
const CLOCKED = 'theReplayClockIsTheAppsClock';
const RATE = 'theCaptureIsReplayedAtItsOwnRate';
const PIGMENT = 'theInkIsOneInkAndThePaperOnePaper';
const FIRSTLAUNCH = 'theFirstLaunchStoryMatchesTheBuild';
const FILM = 'theDemoIsTheAppOnFilm';
const SOUNDTRACK = 'theSoundtrackUsesTheAppsBands';
const WEBMCP = 'thePageExposesOnlyReadOnlyDiscoveryTools';
const CREDIT = 'theCreditSitsInTheFlow';
const BORROWED = 'theCreditLinksWhatItBorrows';
const UNBROKEN = 'theCreditBreaksBetweenNamesOnly';
const SIZE = 'theCardIsTheSizeThePagePromises';

const MANIFEST = 'Package.swift';
const PLIST = 'Resources/Info.plist';
const PAGE = 'site/index.html';
const CNAME = 'site/CNAME';
const ROBOTS = 'site/robots.txt';
const SITEMAP = 'site/sitemap.xml';
const LLMS = 'site/llms.txt';
const PRIVACY = 'site/privacy.html';
const TERMS = 'site/terms.html';
const SECURITY = 'site/.well-known/security.txt';
const SIM = 'site/js/sim.js';
const GEOM = 'site/js/geometry.js';
const SITE_JS = 'site/js/site.js';
const PLAYER_JS = 'site/js/player.js';
const CSS = 'site/css/magnetite.css';
const TYPE = 'site/css/type.css';
const DATA = 'site/data/real-levels.js';
const OG = 'site/test/og.html';
const ICON_HTML = 'site/test/icon.html';
const FAVICON = 'site/favicon.svg';
const METRICS_SWIFT = 'Sources/NotchApp/Notch/ScreenMetrics.swift';
const SWIPE_SWIFT = 'Sources/NotchApp/Notch/SwipeRecogniser.swift';
const CLOCK = 'site/js/clock.js';
const VIS = 'site/js/visibility.js';
const BLANK = 'theOffscreenEconomyNeverBlanksThePage';
const TRANSPORT = 'theFilmPlaysWhereItIsWatched';
const PREFERENCE = 'thePreferenceIsReadTheWayItIsAsked';
const SPENDS = 'theLoopSpendsTheClockItWasGiven';
// The only mutant target that is the checker itself. A gate whose WINDOW is
// derived can have the derivation quietly undone, and no mutant on the product
// can show that — the page would still be correct; the check would simply stop
// looking. So the narrowing is mutated where it lives.
const PORTCHECK = 'site/test/portcheck.mjs';
const GEN_MARK = 'site/test/gen-mark.mjs';
const MARK_SWIFT = 'Sources/NotchApp/App/MagnetiteMark.swift';
const DELEGATE = 'Sources/NotchApp/App/AppDelegate.swift';
const CONTOUR = 'theMarkIsTheIconsOwnContour';
const CAMERAS = 'eachCameraIsPaintedWithTheFluidItIsAimedAt';
const SCALED = 'theCameraIsResizedIntoItsNewScale';
const LEVELS_SWIFT = 'Sources/NotchApp/Audio/AudioLevels.swift';
const VIEW_SWIFT = 'Sources/NotchApp/UI/FerrofluidView.swift';
const BANDS_JS = 'site/js/bands.js';
const BANDS_WORKLET = 'site/js/bands-worklet.js';
const WEBMCP_JS = 'site/js/webmcp.mjs';
const BAND_PORT = 'thePortAgreesWithTheTap';
const BAND_SINES = 'eachBandAnswersItsOwnSine';
const BAND_PARTITION = 'thePartitionCoversWithoutOverlap';
const BAND_PUMP = 'thePumpDecaysToHonestSilence';
const JOURNEY = 'theJourneyLandsWhereItHandsOver';
const TUNNEL_JS = 'site/js/tunnel.js';
const HAND = 'theHandInTheFilmGoesTheWayTheAppReadsIt';
const TOUCHES_JS = 'site/js/touches.js';
const BAND_CHECKS = [BAND_PORT, BAND_SINES, BAND_PARTITION, BAND_PUMP];

const MUTANTS = {
  'the-search-title-drops-the-product-category': {
    check: CRAWLABLE,
    file: PAGE,
    from: '<title>Magnetite — A ferrofluid music player for the MacBook notch</title>',
    to: '<title>Magnetite — Music, magnetized.</title>',
  },
  'the-structured-app-drops-the-local-audio-promise': {
    check: CRAWLABLE,
    file: PAGE,
    from: '    "On-device audio processing with no tracking"',
    to: '    "A generic music player"',
  },
  'the-agent-map-points-at-the-old-deployment-host': {
    check: CRAWLABLE,
    file: LLMS,
    from: '[Live demo](https://magnetite.app/)',
    to: '[Live demo](https://magnetite-sage.vercel.app/)',
  },
  'the-display-face-goes-back-to-google': {
    check: LOCAL_TYPE,
    file: TYPE,
    from: "url('../fonts/gloock-400-latin.woff2') format('woff2')",
    to: "url('https://fonts.gstatic.com/gloock.woff2') format('woff2')",
  },
  'the-privacy-page-starts-uploading-audio': {
    check: POLICIES,
    file: PRIVACY,
    from: 'does not upload or save the audio.',
    to: 'uploads the audio to improve the service.',
  },
  'the-security-contact-points-away-from-the-maintainer': {
    check: POLICIES,
    file: SECURITY,
    from: 'Contact: mailto:scrystyt@gmail.com',
    to: 'Contact: mailto:nobody@example.com',
  },
  'the-security-policy-has-expired': {
    check: POLICIES,
    file: SECURITY,
    from: 'Expires: 2027-08-31T23:59:59Z',
    to: 'Expires: 2025-08-31T23:59:59Z',
  },
  // The bug exactly as it shipped, and as it shipped for the capture's whole
  // life: the page plays eight seconds of music in four. Nothing in the suite
  // could see it, because site.js said 60 and portprobe dumped at 60 and the
  // two agreed with each other.
  'the-capture-plays-at-double-speed': {
    check: RATE,
    file: SITE_JS,
    from: 'const CAPTURE_HZ = 30;',
    to: 'const CAPTURE_HZ = 60;',
  },
  // The same 2x from the other end: the app's pump retimed and the site left
  // where it was. The rate is a fact about the app, so the check has to fail
  // when the APP moves, not only when the page does.
  'the-app-republishes-twice-as-often': {
    check: RATE,
    file: LEVELS_SWIFT,
    from: 'try? await Task.sleep(for: .milliseconds(33))',
    to: 'try? await Task.sleep(for: .milliseconds(16))',
  },
  // A step rate that is not the app's render clock. `SIM_HZ` divides
  // `CAPTURE_HZ` here, so the arithmetic still works and every frame still gets
  // a whole number of steps — it is simply a different physics from the one the
  // golden holds.
  'the-page-steps-at-its-own-rate': {
    check: RATE,
    file: SITE_JS,
    from: 'const SIM_HZ = 60;',
    to: 'const SIM_HZ = 90;',
  },
  // A rate pair that does not divide. `the-page-steps-at-its-own-rate` uses 90,
  // which still gives a whole 3 steps per captured frame, so it proves the rate
  // must be the APP's and leaves the divisibility guard beside it unexercised.
  // 45 over 30 is one and a half steps per frame: every other captured frame
  // would be held for a different number of steps than its neighbour, which is
  // not a cadence at all. The guard exists so that arrives as a failure rather
  // than as a `per` of 1.5 quietly rounding somewhere downstream.
  'the-rates-do-not-divide': {
    check: RATE,
    file: SITE_JS,
    from: 'const SIM_HZ = 60;',
    to: 'const SIM_HZ = 45;',
  },
  // And the same three numbers in the card, which is the third copy of this
  // cadence and was the ungated one. og.html cannot import site.js — it runs
  // DOM code on load — so it restates them, exactly as it restates the crop.
  // The crop copy has been mutated since it was written; these had never been
  // compared to anything, and two of them arrived with the change that fixed
  // the cadence in the first place.
  //
  // Each of these ships a share card drawn from a fluid neither the app nor the
  // page runs, with every other check green. That is the shape of the defect
  // this whole chain exists to catch, one file further down.
  'the-card-steps-at-the-capture-rate': {
    check: RATE,
    file: OG,
    from: 'const CADENCE = replayCadence(60, 30, 0.11);',
    to: 'const CADENCE = replayCadence(30, 30, 0.11);',
  },
  'the-card-holds-each-frame-once': {
    check: RATE,
    file: OG,
    from: 'const CADENCE = replayCadence(60, 30, 0.11);',
    to: 'const CADENCE = replayCadence(60, 60, 0.11);',
  },
  'the-card-smooths-differently': {
    check: RATE,
    file: OG,
    from: 'const CADENCE = replayCadence(60, 30, 0.11);',
    to: 'const CADENCE = replayCadence(60, 30, 0.2);',
  },
  // The remainder thrown away instead of carried. Passes at 120Hz, where the
  // step divides the callback exactly, and runs SLOW at 90 — which is why the
  // check drives a rate that divides neither 60 nor 240.
  'the-clock-drops-its-remainder': {
    check: CLOCKED,
    file: CLOCK,
    from: '    bank -= simStep;',
    to: '    bank = 0;',
  },
  // Steps counted as an accumulated float rather than an integer. The phase
  // error is not visible for minutes, and then a captured frame gets one step
  // or three for the rest of the session.
  'the-clock-counts-in-floats': {
    check: CLOCKED,
    file: CLOCK,
    from: '    steps += 1;',
    to: '    steps += 1.0000001;',
  },
  // A step only once the whole of it is banked: on a 60Hz display's rounded
  // frame times, a third of the frames take none and the next take two.
  'the-clock-steps-in-lumps': {
    check: CLOCKED,
    file: CLOCK,
    from: 'while (bank >= simStep * (1 - STEP_SLACK)) {',
    to: 'while (bank >= simStep) {',
  },
  // The defect as it actually shipped, restored: the step counter converted to
  // seconds and multiplied back into a frame index. `(246 / 60) * 30` is
  // 122.99999999999999, so captured frame 122 takes three steps and 123 takes
  // one — 22 of every 3600 steps on the wrong frame, starting four seconds into
  // every page load.
  //
  // Nothing caught this for as long as it existed. Both nested-loop replays
  // hold each frame twice by construction and cannot express it, and the one
  // gate that names the invariant did not exist until the commit that fixed the
  // defect — and a one-second window would have been blind to it in any case,
  // the first breach being at 4.1s. It is here because the gate's window is
  // now derived from
  // where the two spellings part company rather than written down — this mutant
  // is what makes that derivation load-bearing instead of decorative.
  'the-replay-index-goes-through-seconds': {
    check: CLOCKED,
    file: CLOCK,
    from: '  const index = Math.floor(step / per);',
    to: '  const index = Math.floor((step / simHz) * captureHz);',
  },
  // The optimisation that looks free and is not: skip the step when the levels
  // have not changed. On the SITE's old cadence every frame was a new number,
  // so this did nothing and every check stayed green — it is invisible to
  // anything driven one-step-per-frame. On the APP's cadence it deletes half
  // the steps, which is where `inkOpen`, the pointer pull and the settle timer
  // all live. Only `sim-held` can see it, and only because the golden has a
  // held frame in it.
  'the-port-skips-a-held-frame': {
    check: HELD,
    file: SIM,
    from: '  advance(input, dt) {\n    if (!input.length) return;',
    to: '  advance(input, dt) {\n    if (!input.length) return;\n'
      + '    if (this.lastInput && input.every((v, i) => v === this.lastInput[i])) return;\n'
      + '    this.lastInput = input.slice();',
  },
  // The defect as it actually was: the sim advanced by the WALL's dt, so the
  // fluid is a function of the refresh rate and a ProMotion Mac draws a
  // different picture. Every constant is still correct, which is why the
  // constants were never enough.
  // The blind spot CONSTRUCTED, not restored. With `lastStep = 59` the hold is
  // asserted over one second while the first breach of the invariant is at step
  // 246, so the assertion covers exactly the span in which the hold cannot
  // break — which is the shape worth having a mutant for.
  //
  // What this comment used to say — that the check "drove a window of one
  // second for its whole life" and "stayed green against the shipping defect" —
  // is false, and git says so plainly: `git show
  // 61258e5^:site/test/portcheck.mjs` does not contain the name at all, and
  // 61258e5 introduced the check already carrying `frames * per - 1` while
  // fixing the defect in the same commit. It never coexisted with the bug.
  //
  // The window is derived now (`frames * per - 1`), and the comment above it
  // claims that shortening it back "fails loudly instead of quietly restoring
  // the blind spot". That claim was the only thing standing behind the
  // derivation. This mutant is what makes it true: `lastStep = 59` is steps
  // 0..59, sixty steps of a 60Hz sim, which is the one second the check's own
  // docstring spells out — "120 callbacks at 1/120 is 60 steps, captured frames
  // 0..29". It must now trip the reach assertion rather than pass green.
  //
  // It said 119 until this was re-derived, which is 120 steps and so TWO
  // seconds — still short enough to kill the check, since the first breach is
  // at step 246 either way, so nothing was red and nothing looked wrong. A
  // mutant that kills for the right reason with the wrong number is the easiest
  // kind of wrong thing to keep: the harness only reports the kill.
  //
  // Not pointed at the hold assertion — a short window passes THAT, which is
  // the entire point. It has to die on the window being too short to look.
  'the-hold-is-checked-for-one-second': {
    check: CLOCKED,
    file: PORTCHECK,
    from: '  const lastStep = frames * per - 1;',
    to: '  const lastStep = 59;',
  },
  // The OTHER half of that comment's correction, and the half that had no
  // mutant either way. The paragraph above the gate now states as fact that the
  // alias — `const d = SIM_STEP` and then `advance(…, d)` — IS caught, having
  // previously claimed the opposite. Both the wrong claim and the right one
  // went unproven: nothing exercised the require that does the catching, so the
  // comment was the only evidence for it in either direction.
  //
  // A comment is not a gate. This is the gate.
  'the-page-steps-through-an-alias': {
    check: CLOCKED,
    file: SITE_JS,
    from: '    sim.advance(smoothed(levelsAt(s)), SIM_STEP);',
    to: '    const d = SIM_STEP;\n    sim.advance(smoothed(levelsAt(s)), d);',
  },
  // The escape the gate's own comment used to advertise as unreachable, and the
  // reason that comment was rewritten: a SHADOW. Redeclaring the module's fixed
  // step inside `frame()` leaves the call site reading `advance(…, SIM_STEP)`
  // exactly as before, so a check that inspects the last argument's TEXT sees
  // nothing wrong and the page runs its physics at 144Hz. It is an ordinary
  // rename, not a contrivance — which is what made it worth closing with a
  // require rather than describing.
  //
  // 1/144 rather than a wilder number on purpose: it is a real refresh rate, so
  // a reader who trips this sees the mistake someone would actually make.
  'the-page-shadows-the-fixed-step': {
    check: CLOCKED,
    file: SITE_JS,
    from: '  const dt = Math.max(0, Math.min(0.05, (now - last) / 1000)) || 0;',
    to: '  const dt = Math.max(0, Math.min(0.05, (now - last) / 1000)) || 0;\n  const SIM_STEP = 1 / 144;',
  },
  'the-page-steps-on-the-display-clock': {
    check: CLOCKED,
    file: SITE_JS,
    from: '    sim.advance(smoothed(levelsAt(s)), SIM_STEP);',
    to: '    sim.advance(smoothed(levelsAt(s)), dt);',
  },
  // The hold dropped from the still: one step per captured frame instead of
  // two, so the reduce-motion picture is integrated over half the audio the
  // moving one is. It reads as a frame of the fluid to every source-pattern
  // assertion, because it is one — of a different cadence.
  //
  // In clock.js now, and answering to a different check. This was `const steps
  // = 1` inside `renderStill`, where it was caught by the SYNTAX of the line it
  // replaced rather than by anything about the picture — which is why `const dt
  // = 2 / SIM_HZ` on the line above it walked straight through. The still has
  // no recipe of its own any more, so the mutation has to be made where the
  // recipe lives, and what catches it is the film disagreeing with it.
  'the-still-does-not-hold-its-frames': {
    check: STILLFILM,
    file: CLOCK,
    from: '  return { dt, steps: Math.round(simHz / captureHz), k: 1 - Math.exp(-dt / tau) };',
    to: '  return { dt, steps: 1, k: 1 - Math.exp(-dt / tau) };',
  },
  // The still's own walk, one step short per captured frame. Not the same
  // mutant as the one above: the cadence still says two, so every source
  // pattern and every count agrees, and the only thing that can tell is running
  // the loop against the replay's index.
  'the-still-walks-short': {
    check: STILLFILM,
    file: CLOCK,
    from: '    for (let s = 0; s < steps; s++) {',
    to: '    for (let s = 0; s < steps - 1; s++) {',
  },
  // The still stops delegating and grows a loop again. The picture it paints is
  // the right one — this is the recipe copied back verbatim — so nothing about
  // the fluid can catch it. What must catch it is the rule that the still owns
  // no stepping, because the copy is the defect: it is free to drift the moment
  // the cadence moves, and that drift is invisible to every check here.
  'the-still-takes-its-recipe-back': {
    check: CLOCKED,
    file: SITE_JS,
    from: '  driveStill(still, REAL_LEVELS, STILL_FRAME, CADENCE);',
    to: '  const level = new Array(REAL_LEVELS[0].length).fill(0);\n'
      + '  for (let i = 0; i <= STILL_FRAME; i++) {\n'
      + '    for (let s = 0; s < CADENCE.steps; s++) {\n'
      + '      for (let b = 0; b < level.length; b++) '
      + 'level[b] += (REAL_LEVELS[i][b] - level[b]) * CADENCE.k;\n'
      + '      still.advance(level, CADENCE.dt);\n'
      + '    }\n  }',
  },
  // The still's drive starts hot. The low pass forgets it — by the frame the
  // still stops on the two drives agree to 2.6e-15 — but the FLUID does not:
  // what stood up in the first tenth of a second is standing for reasons that
  // outlive the input that raised it, and the height is still 0.4948 apart 110
  // frames later. A check that compared the drive would call this converged.
  'the-still-starts-hot': {
    check: STILLFILM,
    file: CLOCK,
    from: '  const drive = new Array(levels[0].length).fill(0);',
    to: '  const drive = new Array(levels[0].length).fill(1);',
  },
  // The low pass linearised. `dt / tau` is what a first reading of a time
  // constant suggests and it is very nearly right at 60Hz — which is the whole
  // problem, because "very nearly right at one rate" is what the exponential
  // form exists to avoid. Under it a 240Hz display smooths differently from a
  // 60Hz one, and the page's own note claims the opposite.
  'the-low-pass-is-linear': {
    check: EXPONENTIAL,
    file: CLOCK,
    from: '  return { dt, steps: Math.round(simHz / captureHz), k: 1 - Math.exp(-dt / tau) };',
    to: '  return { dt, steps: Math.round(simHz / captureHz), k: dt / tau };',
  },
  // The step doubled where the cadence is derived — the mutant that started
  // this. In `renderStill` it passed every check in the suite; here it has two
  // independent killers, because the drive's response is measured against the
  // exponential it claims and the hero's crop is measured against a fluid that
  // now moves further.
  'the-cadence-steps-twice-as-far': {
    check: EXPONENTIAL,
    file: CLOCK,
    from: '  const dt = 1 / simHz;',
    to: '  const dt = 2 / simHz;',
  },
  // The low pass, one and a half times as eager, at the one line that performs
  // it. Every derived constant is untouched, so this is invisible to anything
  // that reads the cadence; it is only visible to something that runs it.
  'the-drive-overshoots-its-rate': {
    check: EXPONENTIAL,
    file: CLOCK,
    from: '  for (let i = 0; i < drive.length; i++) drive[i] += (target[i] - drive[i]) * k;',
    to: '  for (let i = 0; i < drive.length; i++) drive[i] += (target[i] - drive[i]) * k * 1.5;',
  },
  // The drive reads loudness again — the original defect, which left 16 of 17
  // peaks standing permanently on a surface that had become a static wall.
  'drive-reads-level': {
    check: CROWN,
    file: SIM,
    from: '      result[i] = Math.max(0, delta) / Math.max(0.035, this.spread[i] * 1.6);',
    to: '      result[i] = value;',
  },
  // The critical field raised past the held check's level-reading drive
  // (0.8 * 0.5 = 0.40). Above that, `drive-reads-level` stands no peaks and
  // the held-loudness count passes against the very defect it names. In a full
  // run the hysteresis pair above kills this first; solo is where the crown
  // check has to hold its own premise, and does, by the margin's name.
  'critical-field-above-the-held-drive': {
    check: CROWN,
    file: SIM,
    from: 'const CRITICAL_FIELD = 0.36;',
    to: 'const CRITICAL_FIELD = 0.41;',
  },
  // Band levels carried at double width. This is the one the build spec could
  // never have caught, because it is invisible without the real Swift to
  // compare against.
  'levels-at-double-width': {
    check: REPLAY,
    file: SIM,
    from: '    for (let i = 0; i < levels.length; i++) this.levels[i] = f32(levels[i]);',
    to: '    for (let i = 0; i < levels.length; i++) this.levels[i] = levels[i];',
  },
  // The loudness sum widened before it is accumulated rather than after.
  'flow-sum-at-double-width': {
    check: REPLAY,
    file: SIM,
    from: '    for (const v of levels) sum = f32(sum + v);',
    to: '    for (const v of levels) sum = sum + v;',
  },
  // The bass drive off by a hair — the kind of drift a hand-copied constant has.
  'swell-gain-drift': {
    check: REPLAY,
    file: SIM,
    from: '    const target = Math.min(1, bass * 0.8);',
    to: '    const target = Math.min(1, bass * 0.82);',
  },
  // Forward and back produce the identical heave, so the ink says a track
  // changed but never which way you went.
  'surge-not-mirrored': {
    check: SKIP,
    file: SIM,
    from: '      const w = direction > 0 ? (0.45 + 0.55 * t) : (1 - 0.55 * t);',
    to: '      const w = 1;',
  },
  // The ink fills and drains at one rate, so it neither trails the opening
  // shell nor beats the closing one home.
  'ink-open-symmetric': {
    check: INK,
    file: SIM,
    from: `    const openRate = (this.openTarget > this.inkOpen
      ? (1.4 + 10.0 * this.inkOpen)
      : (8.0 + 16.0 * (1 - this.inkOpen))) * scale;`,
    to: '    const openRate = 8.0 * scale;',
  },
  // The swell teleports to the cursor instead of being dragged by it.
  'pointer-snaps': {
    check: POINTER,
    file: SIM,
    from: '    this.pointerRim += (this.pointerRimTarget - this.pointerRim) * Math.min(1, 5.0 * dt);',
    to: '    this.pointerRim = this.pointerRimTarget;',
  },
  // The hysteresis pair collapsed to one value: peaks chatter on every band
  // sitting near threshold.
  'no-hysteresis': {
    check: HYSTERESIS,
    file: SIM,
    from: 'const COLLAPSE_FIELD = 0.16;',
    to: 'const COLLAPSE_FIELD = 0.36;',
  },
  // The OTHER half of the pair, which had no mutant at all and needed none to
  // survive: `CRITICAL_FIELD` could be moved anywhere on [0.26, 0.42] with all
  // thirty-nine checks and every run in this harness green. Both directions are
  // mutated because the straddled pair that now holds it is two assertions —
  // one that nothing stands below the threshold, one that something stands
  // above it — and a single mutant would leave whichever it missed unwatched.
  // The values are just outside the band the check now permits, [0.3432,
  // 0.3752): far enough to be unambiguous, near enough that they would both
  // have passed before.
  'the-surface-breaks-at-a-smaller-field-than-the-page-is-built-on': {
    check: HYSTERESIS,
    file: SIM,
    from: 'const CRITICAL_FIELD = 0.36;',
    to: 'const CRITICAL_FIELD = 0.32;',
  },
  'the-surface-needs-a-bigger-field-than-the-page-is-built-on': {
    check: HYSTERESIS,
    file: SIM,
    from: 'const CRITICAL_FIELD = 0.36;',
    to: 'const CRITICAL_FIELD = 0.40;',
  },
  // No cap on the crown, so every band near threshold stands at once.
  'crown-uncapped': {
    check: CROWN,
    file: SIM,
    from: '    const allowed = 2 + Math.round(Math.min(1, energy) * 7);',
    to: '    const allowed = SITE_COUNT;',
  },
  // The halo switches at the gate instead of easing across it — the largest
  // per-frame change in the whole effect being the moment it turns off.
  'halo-switches': {
    check: HALO,
    file: SIM,
    from: '  const ease = t * t * (3 - 2 * t);',
    to: '  const ease = t > 0 ? 1 : 0;',
  },
  // The stale lobe gain from the build spec: `mound * 23`, which the source
  // moved past.
  'stale-lobe-gain': {
    check: OUTLINE,
    file: GEOM,
    from: '    const lobeSum = mound * 27 * detail;',
    to: '    const lobeSum = mound * 23 * detail;',
  },
  // The stale lobe spread from the build spec. At 12 each mound has a FWHM of
  // ~42pt while the sites sit ~14.5pt apart, so seventeen peaks sum into one
  // hill and the 11:1 height range is smeared away before it reaches the screen.
  'stale-lobe-spread': {
    check: OUTLINE,
    file: GEOM,
    from: '      const base = 34 - 13 * this.openness;',
    to: '      const base = 12;',
  },
  // The Mexican-hat neck removed, so the outline cannot curve inward at all.
  'no-inward-curvature': {
    check: OUTLINE,
    file: GEOM,
    from: '      const surround = Math.exp(-d * d * 0.35) * 0.18;',
    to: '      const surround = 0;',
  },
  // Fewer relaxation passes: the outline corners where the normal rotates
  // fastest.
  'fewer-relaxation-passes': {
    check: OUTLINE,
    file: GEOM,
    from: '    for (let pass = 0; pass < 8; pass++) {',
    to: '    for (let pass = 0; pass < 6; pass++) {',
  },
  // THE mutant. The specular normal taken from the undisplaced rim, which is
  // what every direction in the design workflow proposed: it produces a
  // stationary gradient painted under a moving surface.
  'normal-from-rim': {
    check: NORMAL,
    file: GEOM,
    from: `    const normals = new Array(points.length);
    for (let i = 0; i < points.length; i++) {
      const a = points[Math.max(0, i - 1)];
      const b = points[Math.min(points.length - 1, i + 1)];
      let tx = b.x - a.x;
      let ty = b.y - a.y;
      const len = Math.hypot(tx, ty);
      if (len > 1e-9) { tx /= len; ty /= len; } else { tx = 0; ty = 1; }
      normals[i] = { dx: -ty, dy: tx };
    }`,
    to: `    const normals = new Array(points.length);
    for (let i = 0; i < points.length; i++) {
      normals[i] = this.rim(i / (points.length - 1)).normal;
    }`,
  },
  // The winding flipped, so every highlight lands on the inside of the body.
  'normal-wound-inward': {
    check: NORMAL,
    file: GEOM,
    from: '      normals[i] = { dx: -ty, dy: tx };',
    to: '      normals[i] = { dx: ty, dy: -tx };',
  },
  // The captured audio quietly diverges from the app's own resource.
  'levels-not-the-apps': {
    check: AUDIO,
    file: DATA,
    from: '  [0.55,0.55,0.61,0.61,0.54,0.50,0.35,0.16,0.01,0.00,0.00,0.00],',
    to: '  [0.55,0.55,0.61,0.61,0.54,0.50,0.35,0.16,0.02,0.00,0.00,0.00],',
  },
  // The replay seam moved off the quietest frame, so the four-second period
  // becomes audible as a visible hitch.
  'loop-seam-moved': {
    check: AUDIO,
    file: DATA,
    from: 'export const LOOP_FRAME = 26;',
    to: 'export const LOOP_FRAME = 0;',
  },
  // The direction that actually matters: the BUILD's floor moves and the page
  // goes on promising last year's. Nobody rereads a marketing line while
  // bumping a deployment target.
  'floor-moved-in-the-build': {
    check: FLOOR,
    file: MANIFEST,
    from: '    platforms: [.macOS("26.0")],',
    to: '    platforms: [.macOS("15.0")],',
  },
  // The page drifts instead.
  'floor-stale-under-the-button': {
    check: FLOOR,
    file: PAGE,
    from: '>Needs macOS 26 on Apple silicon. Free and open source, 575 KB.</p>',
    to: '>Needs macOS 15 on Apple silicon. Free and open source, 575 KB.</p>',
  },
  // A download button that carries no floor at all. Only the count assertion
  // can see this one — every line still present is still correct.
  'floor-dropped-from-the-close': {
    check: FLOOR,
    file: PAGE,
    from: '<p class="get__requires" data-requires id="requires">Needs macOS 26',
    to: '<p class="get__requires" id="requires">Needs macOS 26',
  },
  // The line survives a copy edit that decided "Free" was the important half.
  'floor-unstated-under-the-button': {
    check: FLOOR,
    file: PAGE,
    from: '>Needs macOS 26 on Apple silicon. Free and open source, 575 KB.</p>',
    to: '>Needs Apple silicon. Free and open source, 575 KB.</p>',
  },
  // The machine dropped instead. The floor is still right, so only the rule
  // that the line names hardware at all can see it — without that rule the
  // no-notch clause below it reads an empty string and passes anything.
  'floor-line-names-no-machine': {
    check: FLOOR,
    file: PAGE,
    from: '>Needs macOS 26 on Apple silicon. Free and open source, 575 KB.</p>',
    to: '>Needs macOS 26. Free and open source, 575 KB.</p>',
  },
  // The notch stops being a download button, and every per-button assertion
  // after it would go quiet against a page that still ships one.
  'download-button-unmarked': {
    check: FLOOR,
    file: PAGE,
    from: '<a class="notch-link" data-download rel="external"',
    to: '<a class="notch-link" rel="external"',
  },
  // Not a defect: a comment that names the attribute is prose, not a second
  // button. The counter used to match the bare string anywhere in the file, so
  // explaining the markup in the markup failed the build — and the obvious way
  // to make it pass again is to add a requirement line the page does not need.
  // This one has to SURVIVE.
  'download-attribute-named-in-a-comment': {
    check: FLOOR,
    survives: true,
    file: PAGE,
    from: "       is the download: the print is drawn to the link's own box. -->",
    to: "       is the download: the print is drawn to the link's own box, and the\n"
      + '       attribute that marks it is data-download. -->',
  },
  // The same shape, on the other side of the same check. Unanchored, the
  // requirement-line match could start inside a comment and run forward to the
  // next paragraph's close — which, being the real requirement line, still
  // contains "macOS 26" and "575 KB", so the gate read a span of the page
  // nobody wrote as a claim and counted it as one. This one has to SURVIVE.
  'requirements-attribute-named-in-a-comment': {
    check: FLOOR,
    survives: true,
    file: PAGE,
    from: "       is the download: the print is drawn to the link's own box. -->",
    to: "       is the download, and data-requires prints the rest: the print is drawn\n"
      + "       to the link's own box. -->",
  },
  // The whole point of the check: the page's primary call to action 404s. Every
  // link still agrees with every other, so only the does-it-exist assertion can
  // see it.
  'download-link-404': {
    check: DOWNLOAD,
    file: PAGE,
    all: true,
    from: 'https://github.com/scryst/magnetite-releases/releases/tag/v0.1.2',
    to: 'https://github.com/scryst/magnetite-releases/releases/tag/v9.9.9',
  },
  'release-link-loses-its-external-destination': {
    check: DOWNLOAD,
    file: PAGE,
    from: 'data-download rel="external"',
    to: 'data-download',
  },
  'download-copy-reverts-to-release': {
    check: DOWNLOAD,
    file: PAGE,
    from: 'Download<span class="visually-hidden">, Magnetite v0.1.2 on GitHub</span>',
    to: 'Release<span class="visually-hidden">, Magnetite v0.1.2 on GitHub</span>',
  },
  'structured-release-names-someone-else': {
    check: DOWNLOAD,
    file: PAGE,
    from: '"author": { "@type": "Person", "name": "scryst" }',
    to: '"author": { "@type": "Person", "name": "somebody else" }',
  },
  'field-notes-call-the-film-the-liquid': {
    check: FIELD_NOTES,
    file: PAGE,
    from: "02 / The liquid is rendered from the app's own audio capture.",
    to: '02 / The liquid is a pre-rendered video.',
  },
  'formula-pretends-to-be-the-easter-egg': {
    check: FIELD_NOTES,
    file: PAGE,
    from: '<p class="foot__formula">Fe<sub>3</sub>O<sub>4</sub></p>',
    to: '<a class="foot__formula" href="#field-note">Fe<sub>3</sub>O<sub>4</sub></a>',
  },
  'canonical-keeps-the-old-host': {
    check: DOWNLOAD,
    file: PAGE,
    from: '<link rel="canonical" href="https://magnetite.app/">',
    to: '<link rel="canonical" href="https://scryst.github.io/magnetite-releases/">',
  },
  'custom-domain-file-keeps-the-old-host': {
    check: DOWNLOAD,
    file: CNAME,
    from: 'magnetite.app',
    to: 'scryst.github.io',
  },
  // The app is versioned up and the page keeps shipping the old build — the
  // same drift the floor check catches, one directory over.
  'download-version-drift': {
    check: DOWNLOAD,
    file: PLIST,
    from: '<key>CFBundleShortVersionString</key>\n\t<string>0.1.2</string>',
    to: '<key>CFBundleShortVersionString</key>\n\t<string>0.2.0</string>',
  },
  // The same drift, in the one direction the check used to be blind to. The
  // gate was `href.includes(version)`, and version strings are substrings of
  // each other constantly: bumped to 1.0, the page went on linking
  // Magnetite-0.1.0.zip — "1.0" is inside that filename — and every check
  // passed while the only button on the page served the previous release.
  'download-version-bumped-into-a-substring': {
    check: DOWNLOAD,
    file: PLIST,
    from: '<key>CFBundleShortVersionString</key>\n\t<string>0.1.2</string>',
    to: '<key>CFBundleShortVersionString</key>\n\t<string>1.1</string>',
  },
  // The size under the button is left over from an older, smaller build.
  'download-size-stale': {
    check: DOWNLOAD,
    file: PAGE,
    from: 'Free and open source, 575 KB.',
    to: 'Free and open source, 210 KB.',
  },
  // Consistent, and false: a notch is not a requirement while ScreenMetrics
  // draws a pill without one. Only the cross-check against the Swift can see
  // this; every page-internal assertion is satisfied.
  'requirements-demand-a-notch': {
    check: FLOOR,
    file: PAGE,
    all: true,
    from: 'Apple silicon',
    to: 'MacBook with a notch',
  },
  // The shipped defect, restored: `stop` flips the flag and lets the queued
  // frame stand. Every hide/show cycle then leaves one more live loop behind,
  // and nothing about the page looks or measures wrong — the extra callbacks
  // read a dt of zero, so only the frame cost doubles, then triples.
  'frame-loop-uncancelled': {
    check: LOOP,
    file: SITE_JS,
    from: '  cancelAnimationFrame(queued);\n  queued = 0;\n}',
    to: '}',
  },
  // Subtler: the loop still cancels, but one of the two places that queue a
  // frame drops the handle on the floor. The cancel then reaches only the
  // frames queued by the other one.
  'frame-handle-dropped': {
    check: LOOP,
    file: SITE_JS,
    from: '  last = performance.now();\n  queued = requestAnimationFrame(frame);',
    to: '  last = performance.now();\n  requestAnimationFrame(frame);',
  },
  // Not a defect: the handle's NAME is nobody's business but this module's.
  // A gate that pins the identifier is pinning today's source, not the
  // property. This one has to SURVIVE.
  'frame-handle-renamed': {
    check: LOOP,
    survives: true,
    file: SITE_JS,
    all: true,
    from: 'queued',
    to: 'pending',
  },
  // The shipped defect, restored: Reduce Motion is answered with silence, so
  // the sim settles to the resting outline and the one visitor who cannot
  // watch the liquid move is the only one shown that it never does.
  'still-driven-by-silence': {
    check: STILL,
    file: CLOCK,
    from: '      smoothStep(drive, levels[i], k);\n      sim.advance(drive, dt);',
    to: '      smoothStep(drive, drive.map(() => 0), k);\n      sim.advance(drive, dt);',
  },
  // The same silence, with the capture still named on the line that ignores
  // it. Every source-reading assertion is satisfied; only running the page's
  // own loop and looking at what stands up catches this one.
  'still-driven-by-silence-in-disguise': {
    check: STILL,
    file: CLOCK,
    from: '      smoothStep(drive, levels[i], k);',
    to: '      smoothStep(drive, levels[i].map(() => 0), k);',
  },
  // The loop runs under the preference after all. It settles and retires, so
  // it looks like the old code and reads as harmless — but between the first
  // frame and the settle, the liquid moves, which is the one thing the
  // preference asked it not to do.
  'still-loop-runs-under-the-preference': {
    check: STILL,
    file: SITE_JS,
    from: '  if (running || reduceMotion) return;',
    to: '  if (running) return;',
  },
  // Resize under the preference. Setting a canvas's width clears it, and with
  // no loop running there is nothing to put the picture back — so the still
  // survives until the first resize and the page is blank from then on.
  'still-not-repainted-after-a-resize': {
    check: STILL,
    file: SITE_JS,
    from: '  if (reduceMotion) renderStill();\n  else if (!running) start();',
    to: '  if (!running) start();',
  },
  // The blank page. `!onScreen` agrees with the shipping `onScreen !== false`
  // on both booleans and differs only on the third value — a view the observer
  // has not reported on yet, which on a browser with no IntersectionObserver
  // is every view for the whole visit. This survived all forty-three checks.
  'a-never-observed-view-is-skipped': {
    check: BLANK,
    file: VIS,
    from: '  return onScreen !== false;',
    to: '  return !!onScreen;',
  },
  // The same defect written back into the page, past the extraction. The
  // module stays correct and the loop stops asking it.
  'the-draw-gate-inlined-backwards': {
    check: BLANK,
    file: SITE_JS,
    from: '    if (!shouldDraw(entry.onScreen)) continue;',
    to: '    if (!entry.onScreen) continue;',
  },
  // Draws exactly the canvases nobody is looking at.
  'view-visibility-inverted': {
    check: BLANK,
    file: VIS,
    from: '    states.push([record.target, record.isIntersecting]);',
    to: '    states.push([record.target, !record.isIntersecting]);',
  },
  // Scrolling to a canvas never wakes the loop, so a page that has settled
  // shows a still from then on — and the physics the still is a frame of has
  // stopped advancing too.
  'arrival-never-wakes-the-loop': {
    check: BLANK,
    file: VIS,
    from: '  return { states, start: arrived && !running };',
    to: '  return { states, start: false };',
  },
  // The transport backwards: the film plays while it is scrolled away from and
  // pauses the moment the visitor arrives at it.
  'film-transport-inverted': {
    check: TRANSPORT,
    file: VIS,
    from: "  return intersecting ? 'play' : 'pause';",
    to: "  return intersecting ? 'pause' : 'play';",
  },
  // The pause deleted rather than inverted. No branch is left to read, which
  // is why a rule counting calls cannot see it and the gate reads the actions
  // off `filmAction` instead.
  'film-never-pauses-offscreen': {
    check: TRANSPORT,
    file: SITE_JS,
    from: "        if (action === 'pause') film.pause();\n",
    to: '',
  },
  // Every tab switch undoes the pause: the page comes back and presses play on
  // a film nobody has scrolled to.
  'film-resumed-away-from-the-screen': {
    check: TRANSPORT,
    file: VIS,
    from: "  return !hidden && beside ? 'play' : 'none';",
    to: "  return !hidden ? 'play' : 'none';",
  },
  // The preference, backwards. The one visitor who asked for no motion is the
  // only one shown the liquid moving, and every other visitor gets a page
  // frozen on its still.
  'reduce-motion-read-backwards': {
    check: PREFERENCE,
    file: VIS,
    from: '  return query.matches === true;',
    to: '  return query.matches !== true;',
  },
  // The same inversion at the call, leaving the module honest.
  'reduce-motion-inverted-at-the-call': {
    check: PREFERENCE,
    file: SITE_JS,
    from: 'const reduceMotion = prefersReducedMotion(',
    to: 'const reduceMotion = !prefersReducedMotion(',
  },
  // The economy abandoned: every canvas draws, including the ones scrolled
  // well past. Harmless-looking, and it is the whole cost the observer exists
  // to avoid — every view rebuilding a 145-sample outline every frame.
  'the-economy-is-abandoned': {
    check: BLANK,
    file: VIS,
    from: '  return onScreen !== false;',
    to: '  return true;',
  },
  // A view LEAVING wakes the loop, so a page that has settled restarts every
  // time anything scrolls off the bottom of the window.
  'departure-wakes-the-loop': {
    check: BLANK,
    file: VIS,
    from: '    if (record.isIntersecting) arrived = true;',
    to: '    arrived = true;',
  },
  // `start()` guards on `running` itself, so this one is invisible in the
  // product today — and it is the observer handing out a second loop per
  // arrival the moment that guard is the thing being changed.
  'a-second-loop-per-arrival': {
    check: BLANK,
    file: VIS,
    from: '  return { states, start: arrived && !running };',
    to: '  return { states, start: arrived };',
  },
  // The film starts while the tab is still hidden.
  'film-resumed-while-hidden': {
    check: TRANSPORT,
    file: VIS,
    from: "  return !hidden && beside ? 'play' : 'none';",
    to: "  return beside ? 'play' : 'none';",
  },
  // The page asks the browser a different question and calls the answer a
  // motion preference. Every downstream check stays green: there is still a
  // boolean, it is still threaded everywhere, and it now means dark mode.
  'the-preference-asks-the-wrong-question': {
    check: PREFERENCE,
    file: SITE_JS,
    from: "matchMedia('(prefers-reduced-motion: reduce)')",
    to: "matchMedia('(prefers-color-scheme: dark)')",
  },
  // The three delegations undone, one per check. Each leaves the extracted
  // module correct and untouched, and takes the page back to the spelling that
  // was free to invert — which is the whole reason a behaviour check alone is
  // not enough here.
  'the-observer-inlined-again': {
    check: BLANK,
    file: SITE_JS,
    from: '    const wake = applyWatch(entries, views, running);\n'
      + '    if (wake) start();',
    to: '    let arrived = false;\n'
      + '    for (const record of entries) {\n'
      + '      if (record.isIntersecting) arrived = true;\n'
      + '      const entry = views.find((each) => each.view.canvas === record.target);\n'
      + '      if (entry) entry.onScreen = record.isIntersecting;\n'
      + '    }\n'
      + '    if (arrived && !running) start();',
  },
  'the-film-transport-inlined-again': {
    check: TRANSPORT,
    file: SITE_JS,
    from: '        const action = transport.observe(record);\n'
      + "        if (action === 'play') run();\n"
      + "        if (action === 'pause') film.pause();",
    to: "        const action = record.intersectionRatio > 0 ? 'play' : 'pause';\n"
      + "        if (action === 'play') run();\n"
      + "        if (action === 'pause') film.pause();",
  },
  'the-preference-inlined-again': {
    check: PREFERENCE,
    file: SITE_JS,
    from: "const reduceMotion = prefersReducedMotion(matchMedia('(prefers-reduced-motion: reduce)'));",
    to: "const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;",
  },
  // A second opinion beside the gate. The call is still there and the count is
  // unchanged, so a rule that counted calls — or one that looked for `===` —
  // sees nothing; the page skips every never-observed view exactly as if the
  // extraction had never happened.
  'the-gate-doubled-with-an-inline-copy': {
    check: BLANK,
    file: SITE_JS,
    from: '    if (!shouldDraw(entry.onScreen)) continue;',
    to: '    if (!shouldDraw(entry.onScreen) || !entry.onScreen) continue;',
  },
  // The loop loses its gate outright: no flag read, no comparison, nothing for
  // the rule above to catch — every print is drawn whether or not anyone can
  // see it.
  'the-loop-loses-its-gate': {
    check: BLANK,
    file: SITE_JS,
    from: '    if (!shouldDraw(entry.onScreen)) continue;\n',
    to: '',
  },
  // The film is never resumed at all, so a tab switch leaves it paused beside
  // a visitor who is looking straight at it.
  'film-never-resumes': {
    check: TRANSPORT,
    file: VIS,
    from: "  return !hidden && beside ? 'play' : 'none';",
    to: "  return 'none';",
  },
  // Only the RESUME inlined, leaving the transport delegated. The block still
  // asks filmAction and still answers both of its actions, so every rule about
  // the transport passes; the tab-switch policy is back to a spelling nothing
  // reads.
  'the-films-resume-inlined-again': {
    check: TRANSPORT,
    file: SITE_JS,
    from: "      if (transport.revealed(document.hidden) === 'play') run();",
    to: '      if (!document.hidden) run();',
  },
  // The pause answered under a name the policy never returns. `film.pause()`
  // is still there for a rule that only asks whether the block can pause at
  // all — and the branch is dead, so it never does.
  'the-pause-answered-under-another-name': {
    check: TRANSPORT,
    file: SITE_JS,
    from: "        if (action === 'pause') film.pause();",
    to: "        if (action === 'paused') film.pause();",
  },
  // The pause answered with nothing. The action is still named in the block,
  // so the rule that reads the actions off the policy is satisfied — and the
  // film plays on behind the visitor exactly as if the branch were missing.
  'the-pause-is-answered-with-nothing': {
    check: TRANSPORT,
    file: SITE_JS,
    from: "        if (action === 'pause') film.pause();",
    to: "        if (action === 'pause') void action;",
  },
  // THE WIRING. The five below were measured surviving the forty-six-check
  // gate as one-character edits in site.js, where nothing could reach them.
  // Two of them are gone rather than caught — the code they inverted moved
  // into the module — so those two are written here, against the module, where
  // a mutant can run. The other three still cross and are caught crossing.

  // The seam this whole slice is named for, now inside the policy: every
  // canvas is drawn exactly when nobody is looking at it. Identical in effect
  // to `view-visibility-inverted`, one layer down and finally reachable.
  'the-applied-flag-is-inverted': {
    check: BLANK,
    file: VIS,
    from: '    if (entry) entry.onScreen = onScreen;',
    to: '    if (entry) entry.onScreen = !onScreen;',
  },
  // The flags are written correctly and the answer about the loop is inverted,
  // so the page settles and never wakes.
  'the-applied-wake-is-inverted': {
    check: BLANK,
    file: VIS,
    from: '  return start;',
    to: '  return !start;',
  },
  // The loop's own state inverted on its way into the decision: a running loop
  // is told it is stopped, so every arrival hands out a second loop.
  'the-loop-state-is-inverted-in-the-policy': {
    check: BLANK,
    file: VIS,
    from: '  const { states, start } = watchOutcome(records, running);',
    to: '  const { states, start } = watchOutcome(records, !running);',
  },
  // A record whose target is in no view falls back to the first one instead of
  // being dropped. Subtle on purpose: every record that DOES match still lands
  // correctly, so the table above passes untouched, and only the stray record
  // — which the observer really does deliver — writes onto a canvas it has
  // nothing to do with.
  'the-record-lands-on-the-wrong-view': {
    check: BLANK,
    file: VIS,
    from: '    const entry = views.find((each) => each.view.canvas === target);',
    to: '    const entry = views.find((each) => each.view.canvas === target) || views[0];',
  },
  // The record is REMEMBERED correctly and answered backwards, which is the
  // only edit that separates what the transport stores from what it says.
  'the-transports-answer-is-inverted': {
    check: TRANSPORT,
    file: VIS,
    from: '      return filmAction(beside);',
    to: '      return filmAction(!beside);',
  },
  // The film's seam, also moved: the transport reads every record backwards.
  'the-transport-reads-the-record-backwards': {
    check: TRANSPORT,
    file: VIS,
    from: '      beside = record.isIntersecting;',
    to: '      beside = !record.isIntersecting;',
  },
  // The transport remembers nothing and treats every revealed tab as beside
  // the film, so a switch back starts a film scrolled far past.
  'the-transport-forgets-where-the-film-is': {
    check: TRANSPORT,
    file: VIS,
    from: '      return filmResume(hidden, beside);',
    to: '      return filmResume(hidden, true);',
  },
  // The tab's hidden flag inverted inside the transport: leaving the page
  // starts the film, arriving back leaves it stopped.
  'the-transports-hidden-flag-is-inverted': {
    check: TRANSPORT,
    file: VIS,
    from: '      return filmResume(hidden, beside);',
    to: '      return filmResume(!hidden, beside);',
  },
  // Before the observer has said anything the film counts as beside the
  // visitor, so a tab revealed early plays a film nobody has scrolled to.
  'the-transport-starts-beside-the-film': {
    check: TRANSPORT,
    file: VIS,
    from: '  let beside = false;',
    to: '  let beside = true;',
  },

  // The observer stops asking at all and just starts the loop on every
  // delivery. Nothing is written to the flag, so the absence rule above has
  // nothing to say — this is the one that answers for the delegation itself.
  'the-observer-stops-asking': {
    check: BLANK,
    file: SITE_JS,
    from: '    const wake = applyWatch(entries, views, running);\n'
      + '    if (wake) start();',
    to: '    start();',
  },
  // The transport gone entirely, its two questions answered inline. The film
  // still plays and pauses, on a page that has stopped asking anything that
  // can be run in this harness.
  'the-transport-is-gone-entirely': {
    check: TRANSPORT,
    file: SITE_JS,
    from: '    const transport = filmTransport();\n',
    to: '',
    also: [
      { from: '        const action = transport.observe(record);',
        to: "        const action = record.intersectionRatio > 0 ? 'play' : 'pause';" },
      { from: "      if (transport.revealed(document.hidden) === 'play') run();",
        to: '      if (!document.hidden) run();' },
    ],
  },

  // And the three that still cross. The loop wakes when a canvas LEAVES.
  'the-wake-is-spent-backwards': {
    check: BLANK,
    file: SITE_JS,
    from: '    if (wake) start();',
    to: '    if (!wake) start();',
  },
  // The answer is taken, mentioned, and dropped. The delegation is intact and
  // the identifier is right there un-negated — which is exactly why "it is
  // mentioned and not negated" was not a rule worth having.
  'the-wake-is-never-spent': {
    check: BLANK,
    file: SITE_JS,
    from: '    if (wake) start();',
    to: '    void wake;',
  },
  // The loop started on every delivery instead of on an arrival, which is the
  // offscreen economy abandoned at the call rather than in the policy.
  'the-wake-is-not-consulted': {
    check: BLANK,
    file: SITE_JS,
    from: '    if (wake) start();',
    to: '    void wake;\n    start();',
  },
  // The loop's state inverted on the way IN, which is the same defect as the
  // policy-side one above and a different line — the page can reshape a value
  // it passes without touching a character of what it passes it to.
  'the-loop-state-is-inverted-on-the-way-in': {
    check: BLANK,
    file: SITE_JS,
    from: '    const wake = applyWatch(entries, views, running);',
    to: '    const wake = applyWatch(entries, views, !running);',
  },
  // The write put back beside an intact call — the wiring's version of
  // `the-gate-doubled-with-an-inline-copy`. The delegation is untouched and
  // every flag is overwritten backwards a line later.
  'the-page-writes-the-flag-again': {
    check: BLANK,
    file: SITE_JS,
    from: '    const wake = applyWatch(entries, views, running);',
    to: '    const wake = applyWatch(entries, views, running);\n'
      + '    for (const record of entries) {\n'
      + '      const seen = views.find((each) => each.view.canvas === record.target);\n'
      + '      if (seen) seen.onScreen = !record.isIntersecting;\n'
      + '    }',
  },
  // The tab's hidden flag inverted in flight. The transport is intact and is
  // asked the opposite question.
  'the-hidden-flag-is-inverted-on-the-way-in': {
    check: TRANSPORT,
    file: SITE_JS,
    from: "      if (transport.revealed(document.hidden) === 'play') run();",
    to: "      if (transport.revealed(!document.hidden) === 'play') run();",
  },
  // A second opinion about the record beside an intact transport, which wins
  // because it is last: the film pauses exactly where it is being watched.
  'the-page-reads-the-record-itself': {
    check: TRANSPORT,
    file: SITE_JS,
    from: "        if (action === 'pause') film.pause();",
    to: "        if (action === 'pause') film.pause();\n"
      + '        if (record.isIntersecting) film.pause();',
  },

  // THE TWINS. Every rule above that reads an identifier out of the source has
  // to survive that identifier being called something else, or it is matching
  // today's spelling rather than asserting anything. These have to SURVIVE.
  'the-wake-is-called-something-else': {
    check: BLANK,
    file: SITE_JS,
    from: '    const wake = applyWatch(entries, views, running);\n'
      + '    if (wake) start();',
    to: '    const awake = applyWatch(entries, views, running);\n'
      + '    if (awake) start();',
    survives: true,
  },
  // Spent without an `if`. Same page, different control flow.
  'the-wake-is-spent-without-an-if': {
    check: BLANK,
    file: SITE_JS,
    from: '    if (wake) start();',
    to: '    wake && start();',
    survives: true,
  },
  // And spent inside braces, which is the same `if` with a house style.
  'the-wake-is-spent-inside-braces': {
    check: BLANK,
    file: SITE_JS,
    from: '    if (wake) start();',
    to: '    if (wake) {\n      start();\n    }',
    survives: true,
  },
  // The transport under another name, at all three of its mentions.
  'the-transport-is-called-something-else': {
    check: TRANSPORT,
    file: SITE_JS,
    from: '    const transport = filmTransport();',
    to: '    const reel = filmTransport();',
    also: [
      { from: '        const action = transport.observe(record);',
        to: '        const action = reel.observe(record);' },
      { from: "      if (transport.revealed(document.hidden) === 'play') run();",
        to: "      if (reel.revealed(document.hidden) === 'play') run();" },
    ],
    survives: true,
  },
  // Restructured, not broken: the gate as an `if` around the render instead of
  // a `continue` past it. The rule reads the CALL, not the control flow, so
  // this one has to SURVIVE.
  'draw-gate-restructured': {
    check: BLANK,
    file: SITE_JS,
    from: '    if (!shouldDraw(entry.onScreen)) continue;\n'
      + '    // A print that returns true put a sheet down; only then are its words shown.\n'
      + "    if (entry.view.render(entry.sim, entry.openness())) printed(entry.view.canvas, 'ready');",
    to: '    // A print that returns true put a sheet down; only then are its words shown.\n'
      + '    if (shouldDraw(entry.onScreen) && entry.view.render(entry.sim, entry.openness())) {\n'
      + "      printed(entry.view.canvas, 'ready');\n"
      + '    }',
    survives: true,
  },
  // The two actions answered in the other order. They are mutually exclusive,
  // so this is the same page. This one has to SURVIVE.
  'film-actions-answered-in-either-order': {
    check: TRANSPORT,
    file: SITE_JS,
    from: "        if (action === 'play') run();\n"
      + "        if (action === 'pause') film.pause();",
    to: "        if (action === 'pause') film.pause();\n"
      + "        if (action === 'play') run();",
    survives: true,
  },
  // Not a defect: the held frame's NAME is nobody's business but this
  // module's. This one has to SURVIVE.
  'still-frame-renamed': {
    check: STILL,
    survives: true,
    file: SITE_JS,
    all: true,
    from: 'STILL_FRAME',
    to: 'HELD_FRAME',
  },
  // Nor is the cadence's. This one is here because the check that runs the
  // still very nearly did pin it: the first spelling of the delegation rule
  // matched `driveStill(…, REAL_LEVELS, STILL_FRAME, CADENCE)` literally, and
  // the mutant above caught it. The frame and the cadence are read off the call
  // the body makes, so both names are free.
  'still-cadence-renamed': {
    check: STILL,
    survives: true,
    file: SITE_JS,
    all: true,
    from: 'CADENCE',
    to: 'REPLAY_CLOCK',
  },
  // The exact defect that shipped: the icon master pouring #0A0A0C under a
  // comment claiming "the same ink" while the reservoir renders #0B0A0C. One
  // digit, and no eye at any size will ever catch it.
  'icon-wears-yesterdays-ink': {
    check: PIGMENT,
    file: ICON_HTML,
    from: "const INK = '#0B0A0C';",
    to: "const INK = '#0A0A0C';",
  },
  // The other pigment, in the file that names neither: the favicon's tile
  // drifts off the paper by one blue step, and every browser tab wears it.
  'favicon-tile-off-the-paper': {
    check: PIGMENT,
    file: FAVICON,
    from: '<path fill="#E8E9EB"',
    to: '<path fill="#E8E9EC"',
  },
  // A copy edit loses the route's name: the note still warns about the dialog
  // but no longer says where Open Anyway lives, which is the one thing the
  // dialog itself refuses to tell the visitor.
  'first-launch-note-loses-the-route': {
    check: FIRSTLAUNCH,
    file: PAGE,
    from: '      approve it under System Settings › Privacy &amp; Security › Open Anyway.',
    to: '      approve it under System Settings.',
  },
  // The film starts itself: a self-starting attribute takes the decision
  // away from site.js, which is the only place the motion preference is
  // asked — so the one visitor who turned motion off gets the very motion
  // they turned off.
  'film-starts-itself': {
    check: FILM,
    file: PAGE,
    from: '<video class="film__video" id="demo-film" muted loop playsinline',
    to: '<video class="film__video" id="demo-film" muted loop playsinline autoplay',
  },
  // The guard forgets the preference: the film plays for everyone, and
  // Reduce Motion visitors get a screen recording instead of the open still.
  'film-plays-past-the-preference': {
    check: FILM,
    file: SITE_JS,
    from: 'if (film && !reduceMotion) {',
    to: 'if (film) {',
  },
  // The still goes missing: with playback JS-gated, an element with no still
  // is a void under Reduce Motion and before the footage arrives.
  'film-loses-its-still': {
    check: FILM,
    file: PAGE,
    from: ' poster="media/film-poster.webp" src="media/film.mp4"',
    to: ' src="media/film.mp4"',
  },
  'film-renderer-stays-behind-the-waterfall': {
    check: FILM,
    file: PAGE,
    from: '<link rel="modulepreload" href="js/geometry.js">',
    to: '',
  },
  // The window forgets the footage's scale: at 920px the encode is shown past
  // one-to-one on a 2x display and the panel's type melts — the exact resample
  // the cap exists to make impossible. Stated ahead of the window's own cap,
  // so it is the one the rule reads whatever that cap is today.
  'film-shown-resampled': {
    check: FILM,
    file: CSS,
    from: '.film__mac {\n  position: relative;\n  max-width: ',
    to: '.film__mac {\n  position: relative;\n  max-width: 920px;\n  max-width: ',
  },
  // The box drifts off the footage's proportions, and the page jumps when the
  // first frame arrives and the video takes the shape the stage never had.
  'film-box-disagrees-with-the-footage': {
    check: FILM,
    file: CSS,
    from: '  aspect-ratio: 570 / 660;',
    to: '  aspect-ratio: 570 / 700;',
  },
  // The footage slides off the still on a phone: the pointer and the notch
  // show twice where the two pictures meet.
  'film-slips-off-the-still-on-a-phone': {
    check: FILM,
    file: CSS,
    from: '.film__stage { left: calc(4 / 440 * 100%);',
    to: '.film__stage { left: calc(14 / 440 * 100%);',
  },
  'film-slips-off-the-still': {
    check: FILM,
    file: CSS,
    from: '  left: calc(134 / 700 * 100%);',
    to: '  left: calc(144 / 700 * 100%);',
  },
  // The lookup drifts off the tag's id: film is null, the guard never runs,
  // and the mid-page demo is a permanent poster with every other gate green.
  'film-loses-its-player': {
    check: FILM,
    file: SITE_JS,
    from: "document.getElementById('demo-film')",
    to: "document.getElementById('demo-movie')",
  },
  // A second play call lands outside the guard — the eager kick-it-on-load
  // fix — and Reduce Motion visitors get the very motion they turned off,
  // while the guard itself stands untouched and green.
  'film-plays-outside-the-guard': {
    check: FILM,
    file: SITE_JS,
    from: "const film = document.getElementById('demo-film');",
    to: "const film = document.getElementById('demo-film');\nif (film) film.play().catch(() => {});",
  },
  // The seek put back, exactly as it shipped. With the cut rotated, 4.017
  // lands 4s into a film that already opens where it should — so the still
  // is frame 0, the first played frame is frame 120, and the swap from
  // picture to footage jumps. Nothing else on the page changes.
  'film-seeks-past-its-still': {
    check: FILM,
    file: SITE_JS,
    from: '  const run = () => {\n    if (!filmUserPaused) film.play().catch(() => {});\n  };',
    to: '  if (film.currentTime < 4.017) film.currentTime = 4.017;\n'
      + '  const run = () => {\n    if (!filmUserPaused) film.play().catch(() => {});\n  };',
  },
  // The same seek through a second name for the same element. The check
  // claims it holds for any assignment rather than for `film.currentTime`
  // alone, and a claim a mutant cannot reach is a claim nothing is keeping.
  'film-seeks-under-another-name': {
    check: FILM,
    file: SITE_JS,
    from: '  const run = () => {\n    if (!filmUserPaused) film.play().catch(() => {});\n  };',
    to: '  const reel = film;\n  reel.currentTime = 4.017;\n'
      + '  const run = () => {\n    if (!filmUserPaused) film.play().catch(() => {});\n  };',
  },
  // The three syntaxes that got past the first version of that check, which
  // matched `currentTime` followed by `=`. Compound assignment puts a `+` in
  // the way, a computed key puts a quote in the way, and a property in an
  // object literal has no `=` at all. Each of them really seeks — against a
  // seekable source all three land the playhead on 4.017 — and each of them
  // passed all 31 checks. They are three mutants and not one because the
  // reason each escaped is a different reason.
  'film-seeks-by-compound-assignment': {
    check: FILM,
    file: SITE_JS,
    from: '  const run = () => {\n    if (!filmUserPaused) film.play().catch(() => {});\n  };',
    to: '  film.currentTime += 4.017;\n  const run = () => {\n    if (!filmUserPaused) film.play().catch(() => {});\n  };',
  },
  'film-seeks-through-a-computed-key': {
    check: FILM,
    file: SITE_JS,
    from: '  const run = () => {\n    if (!filmUserPaused) film.play().catch(() => {});\n  };',
    to: "  film['currentTime'] = 4.017;\n  const run = () => {\n    if (!filmUserPaused) film.play().catch(() => {});\n  };",
  },
  'film-seeks-by-object-assign': {
    check: FILM,
    file: SITE_JS,
    from: '  const run = () => {\n    if (!filmUserPaused) film.play().catch(() => {});\n  };',
    to: '  Object.assign(film, { currentTime: 4.017 });\n'
      + '  const run = () => {\n    if (!filmUserPaused) film.play().catch(() => {});\n  };',
  },
  // The sole control for stopping the long product loop cannot become faint
  // until pointer hover or keyboard focus reveals it.
  'demo-pause-fades-below-readable': {
    check: FILM,
    file: CSS,
    from: '  cursor: pointer;\n}\n.how {',
    to: '  cursor: pointer;\n  opacity: 0.38;\n}\n.how {',
  },
  // The credit hung back out of the flow. The layout stops counting it, and
  // the foot's links paint straight through the middle of the sentence.
  'credit-hung-over-the-foot-again': {
    check: CREDIT,
    file: CSS,
    from: '.foot__credit { grid-column: 1 / -1;',
    to: '.foot__credit { position: absolute; grid-column: 1 / -1;',
  },
  // The credit in a freehand mix again: 2.17:1 was the last one measured here.
  'credit-in-the-freehand-mix-again': {
    check: CREDIT,
    file: CSS,
    from: 'color: var(--ink-soft); font-size: 13px; }',
    to: 'color: color-mix(in srgb, var(--ink) 38%, var(--paper)); font-size: 13px; }',
  },
  // A token, and too faint for the paper: the credit washes out of the foot.
  'credit-in-a-token-too-faint-for-the-paper': {
    check: CREDIT,
    file: CSS,
    from: 'color: var(--ink-soft); font-size: 13px; }',
    to: 'color: var(--film-ground); font-size: 13px; }',
  },
  // The foot's box stated instead of floored: its content no longer decides
  // its depth.
  'foot-box-stated-again': {
    check: CREDIT,
    file: CSS,
    from: '.foot {\n  display: grid;',
    to: '.foot {\n  height: 240px;\n  display: grid;',
  },
  'the-scripted-foot-states-a-box': {
    check: CREDIT,
    file: CSS,
    from: '.js .foot { padding-bottom: 104px; }',
    to: '.js .foot { height: 240px; padding-bottom: 104px; }',
  },
  // The tidy-looking attribute back on the licence link, which is the one
  // place it may never go: it states the terms of THIS document's main
  // content, so the film, the still and the mark all become CC BY 4.0 —
  // three lines above the page's own all-rights-reserved line.
  'licence-link-claims-the-page-again': {
    check: BORROWED,
    file: PAGE,
    from: '<a href="https://creativecommons.org/licenses/by/4.0/" rel="external">',
    to: '<a href="https://creativecommons.org/licenses/by/4.0/" rel="license">',
  },
  // A work named and not linked. The credit still reads correctly to a human
  // — which is exactly why it went unnoticed until a licence review read
  // 4.0 §3(a)(1)(A) back at it.
  'a-named-work-with-nowhere-to-go': {
    check: BORROWED,
    file: PAGE,
    from: '<a href="https://punchdeck.bandcamp.com/track/chrome-funk"\n       rel="external">“Chrome Funk”</a>',
    to: '“Chrome Funk”',
  },
  // The titles stripped of the quotes that mark them as titles. The links
  // survive, so only the assertion that the credit names a work at all can
  // see this — and without it, the no-unlinked-work rule above would pass on
  // a credit that named nothing.
  'the-works-lose-the-marks-that-name-them': {
    check: BORROWED,
    file: PAGE,
    from: 'rel="external">“Cyberpunk Renaissance”</a>,\n'
      + '    <a href="https://punchdeck.bandcamp.com/track/chrome-funk"\n'
      + '       rel="external">“Chrome Funk”</a> and\n'
      + '    <a href="https://punchdeck.bandcamp.com/track/neon-underworld"\n'
      + '       rel="external">“Neon Underworld”</a>',
    to: 'rel="external">Cyberpunk Renaissance</a>,\n'
      + '    <a href="https://punchdeck.bandcamp.com/track/chrome-funk"\n'
      + '       rel="external">Chrome Funk</a> and\n'
      + '    <a href="https://punchdeck.bandcamp.com/track/neon-underworld"\n'
      + '       rel="external">Neon Underworld</a>',
  },
  // An em dash after a breakable space: at some phone measure it starts its
  // own line, orphaned from the name it belongs to.
  //
  // The other half of this check — the names made breakable again by taking
  // `white-space: nowrap` off `.foot__credit a` — has no mutant, because the
  // redesigned stylesheet has no such rule to take it off: the check fails on
  // clean source until the page states it again. Add the removal mutant back
  // with the rule.
  'a-dash-orphaned-from-its-name': {
    check: UNBROKEN,
    file: PAGE,
    from: '    © 2026 scryst.\n  </p>',
    to: '    — © 2026 scryst.\n  </p>',
  },
  // The deed left a version behind while the sentence moved on — exactly the
  // shape of edit this credit has already made once, 3.0 to 4.0 with the
  // music. Every earlier assertion here is satisfied: the terms are named,
  // and they are linked. They are linked to the wrong terms.
  'the-deed-is-a-version-behind': {
    check: BORROWED,
    file: PAGE,
    from: 'href="https://creativecommons.org/licenses/by/4.0/" rel="external">CC BY 4.0',
    to: 'href="https://creativecommons.org/licenses/by/3.0/" rel="external">CC BY 4.0',
  },
  // A condition the page never states, carried only by the URL. "CC BY" and
  // by-nc are different offers, and the words are the ones a reader believes.
  'the-deed-carries-a-term-the-words-do-not': {
    check: BORROWED,
    file: PAGE,
    from: 'href="https://creativecommons.org/licenses/by/4.0/" rel="external">CC BY 4.0',
    to: 'href="https://creativecommons.org/licenses/by-nc/4.0/" rel="external">CC BY 4.0',
  },
  // Terms named but not linked: "CC BY 4.0" as bare text is a claim about
  // someone else's rights that the reader has no way to check.
  'the-terms-stated-without-the-deed': {
    check: BORROWED,
    file: PAGE,
    from: '<a href="https://creativecommons.org/licenses/by/4.0/" rel="external">CC BY 4.0</a>',
    to: 'CC BY 4.0',
  },
  // The tab strip told to match the ink instead. The page is untouched and the
  // browser's own chrome wears a colour that is nowhere on the paper under it.
  'the-tab-strip-leaves-the-paper': {
    check: PIGMENT,
    file: PAGE,
    from: '<meta name="theme-color" content="#ECEBE6">',
    to: '<meta name="theme-color" content="#222022">',
  },

  // THE CHEAPEST EDIT IN THE STYLESHEET: append a block. Two top-level rules
  // for one selector are legal CSS and the browser applies the later one, so
  // neither of these touches a line any check was watching — and both
  // were green before the cascade reads below them started taking the LAST
  // declaration rather than the first. They are anchored on the reduced-motion
  // block's closing lines because that is the least fashionable text in the
  // file; a target copied off a rule someone is still tuning retires itself.
  //
  // Both are answered by the pigment gate's last-rule read of `body`: one
  // repaints the ground with a literal, the other with another token by name,
  // and neither touches a hex the parity comparison reads.
  'the-ground-is-repainted-under-the-chrome': {
    check: PIGMENT,
    file: CSS,
    from: '  .hero[data-print="ready"] .hero__copy { animation: none; }\n}\n',
    to: '  .hero[data-print="ready"] .hero__copy { animation: none; }\n}\n\n'
      + 'body { background: #1C1B1F; }\n',
  },
  'the-body-is-repainted-further-down-the-file': {
    check: PIGMENT,
    file: CSS,
    from: '  .hero[data-print="ready"] .hero__copy { animation: none; }\n}\n',
    to: '  .hero[data-print="ready"] .hero__copy { animation: none; }\n}\n\n'
      + 'body { background: var(--film-ground); }\n',
  },

  // The size the PAGE promises about the card, which is read by a crawler
  // before the image is fetched and is therefore invisible to every render in
  // this repo. Four mutants: each number wrong by one, the declaration gone,
  // and the alt text gone. One-off rather than a wilder number on purpose —
  // a check written with a tolerance would pass these and fail only the absurd
  // ones, and the failure that actually happens is a card resized by 30px in
  // one place.
  'the-page-promises-a-wider-card-than-it-ships': {
    check: SIZE,
    file: PAGE,
    from: '<meta property="og:image:width" content="1200">',
    to: '<meta property="og:image:width" content="1201">',
  },
  'the-page-promises-a-taller-card-than-it-ships': {
    check: SIZE,
    file: PAGE,
    from: '<meta property="og:image:height" content="630">',
    to: '<meta property="og:image:height" content="631">',
  },
  'the-page-stops-saying-how-big-the-card-is': {
    check: SIZE,
    file: PAGE,
    from: '<meta property="og:image:width" content="1200">\n',
    to: '',
  },
  'the-page-stops-describing-the-card-to-a-reader': {
    check: SIZE,
    file: PAGE,
    from: '<meta property="og:image:alt" content="A MacBook printed in black, pink and blue ink, with black ferrofluid hanging from its notch.">\n',
    to: '',
  },

  // THE FIVE WIRES INTO `clock.js`. The module is untouched in every one of
  // these: each changes one token at the line where the LOOP hands the clock an
  // argument or spends its answer, and all five survived the whole forty-six
  // check gate before `theLoopSpendsTheClockItWasGiven` ran the loop instead of
  // reading it. Same shape as the visibility wiring one commit ago, found by
  // the same method and killed by execution rather than by a tighter rule.
  //
  // The two rates handed to `replayFrame` the wrong way round. 30/60 instead of
  // 60/30 is two steps per captured frame becoming half of one, so the replay
  // walks the capture at four times its own rate and every check that drives
  // `replayFrame` directly stays green, because the function is correct.
  'the-replay-runs-at-the-wrong-rate': {
    check: SPENDS,
    file: SITE_JS,
    from: '  return replayFrame(step, SIM_HZ, CAPTURE_HZ, REAL_LEVELS.length, LOOP_FRAME);',
    to: '  return replayFrame(step, CAPTURE_HZ, SIM_HZ, REAL_LEVELS.length, LOOP_FRAME);',
  },
  // The wall's gap and the fixed step swapped on the way into the bank. This is
  // the defect the banking exists to prevent, re-entered at the call: the
  // physics becomes a function of the refresh rate again, which is what
  // `theReplayClockIsTheAppsClock` drives `bankSteps` at four rates to stop —
  // and cannot see, because it never asks who calls it or with what.
  'the-bank-is-handed-the-step-as-its-elapsed-time': {
    check: SPENDS,
    file: SITE_JS,
    from: '  ({ bank, steps } = bankSteps({ bank, steps }, dt, SIM_STEP));',
    to: '  ({ bank, steps } = bankSteps({ bank, steps }, SIM_STEP, dt));',
  },
  // The low pass handed its accumulator and its target the wrong way round.
  // Worse than a wrong number: `smoothStep` writes into its first argument, so
  // this walks the CAPTURE toward zero and hands the page a row of the capture
  // that is being destroyed as it plays. `theDriveIsTheExponentialItClaims`
  // drives the real function and sees none of it.
  'the-smoothing-writes-into-the-capture': {
    check: SPENDS,
    file: SITE_JS,
    from: '  return smoothStep(drive, target, liveAnalyser ? LIVE_SMOOTH_K : CADENCE.k);',
    to: '  return smoothStep(target, drive, liveAnalyser ? LIVE_SMOOTH_K : CADENCE.k);',
  },
  // Every step in a callback fed the batch's LAST index instead of its own.
  // At 60Hz with one step per callback the two are equal, which is why a check
  // that drove one step at a time would report this correct; it only parts
  // company when a callback is late and the loop catches up several steps.
  'the-catch-up-steps-all-read-one-frame': {
    check: SPENDS,
    file: SITE_JS,
    from: '    sim.advance(smoothed(levelsAt(s)), SIM_STEP);',
    to: '    sim.advance(smoothed(levelsAt(steps)), SIM_STEP);',
  },
  // The smoothing skipped at the seam. The low pass is still there, still
  // correct, still checked — and nothing on the page calls it, so the fluid is
  // driven by the raw capture and every transient it was there to soften.
  'the-loop-stops-smoothing-what-it-advances': {
    check: SPENDS,
    file: SITE_JS,
    from: '    sim.advance(smoothed(levelsAt(s)), SIM_STEP);',
    to: '    sim.advance(levelsAt(s), SIM_STEP);',
  },
  // The check's own RESOLUTION, blunted — twice, because there are two
  // comparisons and each number was free on its own. A sweep changing every
  // numeric literal in the new check, one at a time, found exactly these two:
  // loosened, the check still reports every one of its assertions passing while
  // a loop driving the fluid off the wrong frame walks through it. They are
  // named constants now so the check can require them to be smaller than what
  // they have to resolve, and the same sweep over its forty-six literals now
  // reports no survivor at all.
  'the-loop-check-stops-resolving-levels': {
    check: SPENDS,
    file: PORTCHECK,
    from: '  const LEVEL_TOLERANCE = 1e-9;',
    to: '  const LEVEL_TOLERANCE = 1e3;',
  },
  'the-loop-check-stops-resolving-steps': {
    check: SPENDS,
    file: PORTCHECK,
    from: '  const STEP_TOLERANCE = 1e-12;',
    to: '  const STEP_TOLERANCE = 1e3;',
  },
  // The check's own WINDOW, shut. Driving the loop at a uniform 60Hz makes
  // every callback exactly one simulation step long, and `dt` and the fixed
  // step become the same number — so `the-bank-is-handed-the-step-as-its-
  // elapsed-time` lands on the identical count and this check agrees with a
  // page that has the defect. Nothing on the product changes; the gate simply
  // stops looking, which is the only way this file can be made to lie.
  'the-loop-is-driven-at-one-rate': {
    check: SPENDS,
    file: PORTCHECK,
    from: '  const schedule = Array.from({ length: 40 }, (_, i) => (i % 3 === 0 ? 1000 / 120 : 1000 / 60));',
    to: '  const schedule = Array.from({ length: 40 }, () => 1000 / 60);',
  },
  // The cadence recipe copied back into the page. The numbers come out
  // identical, so nothing about the picture changes — what changes is that the
  // page and `clock.js` now hold two copies of one derivation, free to drift
  // the moment either moves, and the loop check can no longer read the rates
  // off the page's own call. It is the blindness that makes this a mutant
  // worth keeping: an inlined cadence is exactly how a gate stops looking
  // without anything on the page appearing to break.
  'the-cadence-recipe-is-copied-into-the-page': {
    check: SPENDS,
    file: SITE_JS,
    from: 'const CADENCE = replayCadence(SIM_HZ, CAPTURE_HZ, SMOOTH_TAU);',
    to: 'const CADENCE = { dt: 1 / SIM_HZ, steps: Math.round(SIM_HZ / CAPTURE_HZ), '
      + 'k: 1 - Math.exp(-(1 / SIM_HZ) / SMOOTH_TAU) };',
  },
  // Banked at one step and integrated at another. The count comes out right —
  // the bank is still given the cadence's own `dt` — and the levels come out
  // right, so this is the one defect here that the step assertion alone
  // catches. `theReplayClockIsTheAppsClock` requires the token handed to
  // `advance` to BE `SIM_STEP` and forbids shadowing it inside the loop; both
  // hold here, because what moved is what the name is worth.
  'the-loop-integrates-twice-the-step-it-banks': {
    check: SPENDS,
    file: SITE_JS,
    from: 'const SIM_STEP = CADENCE.dt;',
    to: 'const SIM_STEP = CADENCE.dt * 2;',
    also: [
      { from: '  ({ bank, steps } = bankSteps({ bank, steps }, dt, SIM_STEP));',
        to: '  ({ bank, steps } = bankSteps({ bank, steps }, dt, CADENCE.dt));' },
    ],
  },
  // And the twins. The harness rebuilds the loop out of the module's own
  // declarations rather than out of names written down here, so renaming the
  // accumulator or the cadence has to SURVIVE — a check that dies to a
  // respelling is pattern-matching today's source.
  //
  // `SIM_STEP` is deliberately not among them, and neither is the loop's own
  // name. `theReplayClockIsTheAppsClock` requires the token handed to
  // `advance` to BE `SIM_STEP`, with a rule against shadowing it beside, and
  // reads the loop out of the file as `frame` — pins this repo argued for and
  // kept. Renaming either is therefore caught, by that check and not this one,
  // and a twin asserting it survives would assert the opposite of a decision
  // already made. `theLoopSpendsTheClockItWasGiven` tolerates both on its own:
  // it captures the loop from the page's `requestAnimationFrame` call and
  // rebuilds the constants from the module's own declarations.
  'the-smoothing-accumulator-is-called-something-else': {
    check: SPENDS,
    file: SITE_JS,
    survives: true,
    from: 'const drive = new Array(REAL_LEVELS[0].length).fill(0);',
    to: 'const lowPassed = new Array(REAL_LEVELS[0].length).fill(0);',
    also: [
      { from: '  return smoothStep(drive, target, liveAnalyser ? LIVE_SMOOTH_K : CADENCE.k);',
        to: '  return smoothStep(lowPassed, target, liveAnalyser ? LIVE_SMOOTH_K : CADENCE.k);' },
    ],
  },
  'the-cadence-is-called-something-else': {
    check: SPENDS,
    file: SITE_JS,
    survives: true,
    from: 'const CADENCE = replayCadence(SIM_HZ, CAPTURE_HZ, SMOOTH_TAU);',
    to: 'const REPLAY = replayCadence(SIM_HZ, CAPTURE_HZ, SMOOTH_TAU);',
    also: [
      { from: 'const SIM_STEP = CADENCE.dt;', to: 'const SIM_STEP = REPLAY.dt;' },
      { from: '  return smoothStep(drive, target, liveAnalyser ? LIVE_SMOOTH_K : CADENCE.k);',
        to: '  return smoothStep(drive, target, liveAnalyser ? LIVE_SMOOTH_K : REPLAY.k);' },
      { from: '  driveStill(still, REAL_LEVELS, STILL_FRAME, CADENCE);',
        to: '  driveStill(still, REAL_LEVELS, STILL_FRAME, REPLAY);' },
    ],
  },

  // The mark. Three mutants on the files that carry it and three on the
  // derivation behind them, because "the two copies agree" and "the two copies
  // are the icon" are different claims and only the second is the one the page
  // makes in prose.
  //
  // A hand edit to the generated favicon: a control point nudged two pixels,
  // the kind of touch-up a traced path invites and the kind that used to leave
  // the tab showing a mark the Dock did not.
  'the-favicon-is-touched-up-by-hand': {
    check: CONTOUR,
    file: FAVICON,
    from: 'M272.5 283C278.4 281.8',
    to: 'M272.5 283C278.4 279.8',
  },
  // The other copy, edited alone — the drift the two-file arrangement was
  // always one careless commit away from.
  'the-page-keeps-a-mark-of-its-own': {
    check: CONTOUR,
    file: PAGE,
    from: 'M272.5 283C278.4 281.8',
    to: 'M272.5 283C281.4 281.8',
  },
  // The master moves and the vector does not. `n` is the superellipse exponent
  // — the tile's corner curvature — so this is the icon changing under the
  // site, which is the signal the golden files exist for elsewhere and which
  // the mark had no equivalent of.
  'the-tile-corner-changes-under-the-page': {
    check: CONTOUR,
    file: ICON_HTML,
    from: 'const n = 5;',
    to: 'const n = 4;',
  },
  // The fit loosened past the point where it still describes the pour. Nothing
  // about the page's markup changes; the shape does.
  'the-fit-stops-tracking-the-contour': {
    check: CONTOUR,
    file: GEN_MARK,
    from: 'const TOLERANCE = 0.45;',
    to: 'const TOLERANCE = 6;',
  },
  // The pour's hard edge traced as found. Without the blur that puts the
  // sub-pixel boundary back, marching squares returns a staircase and the fit
  // chases every stair — the mark comes back as hundreds of curves that are
  // individually smooth and collectively a rasterisation.
  'the-hard-edge-is-traced-as-found': {
    check: CONTOUR,
    file: GEN_MARK,
    from: 'const EDGE_SIGMA = 2;',
    to: 'const EDGE_SIGMA = 0.01;',
  },
  // The defect itself, put back where it can no longer be seen by eye: the
  // generator keeps every fitted endpoint and throws the control points away,
  // so the letter is emitted as the polygon it used to be. The two consumers
  // still agree with the derivation and with each other. Only the rule about
  // what the mark IS can catch this one.
  'the-letter-is-emitted-as-a-polygon': {
    check: CONTOUR,
    file: GEN_MARK,
    from: '    out += `C${round(c[1][0])} ${round(c[1][1])} ${round(c[2][0])} ${round(c[2][1])}`\n'
        + '         + ` ${round(c[3][0])} ${round(c[3][1])}`;',
    to: '    out += `L${round(c[3][0])} ${round(c[3][1])}`;',
  },
  // The app's copy, edited alone — the same drift as the page's, one platform
  // over.
  'the-app-keeps-a-mark-of-its-own': {
    check: CONTOUR,
    file: MARK_SWIFT,
    from: 'static let aspect: CGFloat = 1.44132',
    to: 'static let aspect: CGFloat = 1.5',
  },
  // The mark restored to the generator's output everywhere and the menu bar
  // still not drawing it. This is the defect as it actually shipped: three
  // consumers in perfect agreement and the one visible surface showing a
  // system symbol instead.
  'the-menu-bar-goes-back-to-a-system-symbol': {
    check: CONTOUR,
    file: DELEGATE,
    from: '        item.button?.image = MagnetiteMark.menuBarImage(height: 16)',
    to: '        item.button?.image = NSImage(systemSymbolName: '
      + '"rectangle.topthird.inset.filled", accessibilityDescription: "Magnetite")',
  },
  // The mark assigned and then overwritten. This is the only mutant that
  // reaches the "no system symbol" rule: the assignment the previous mutant
  // deletes is still there, so a check that only asks whether MagnetiteMark is
  // mentioned passes while the bar draws the symbol that ran last.
  'the-mark-is-set-and-then-replaced': {
    check: CONTOUR,
    file: DELEGATE,
    from: '        item.button?.image = MagnetiteMark.menuBarImage(height: 16)',
    to: '        item.button?.image = MagnetiteMark.menuBarImage(height: 16)\n'
      + '        item.button?.image = NSImage(systemSymbolName: '
      + '"rectangle.topthird.inset.filled", accessibilityDescription: "Magnetite")',
  },
  // The mark upside down. AppKit counts y up and SVG counts it down, so the
  // flip is a real decision the generator makes; undoing it leaves a mark that
  // is still the right shape, still the right size, and standing on its head.
  'the-menu-bar-mark-is-inverted': {
    check: CONTOUR,
    file: GEN_MARK,
    from: 'y: ${(1 - (p[1] - b.y0) / h).toFixed(5)}',
    to: 'y: ${((p[1] - b.y0) / h).toFixed(5)}',
  },

  // The lines that AIM a paint. A census of forty-eight one-token changes
  // measured against the gate as it stood found five of these lines' shapes
  // alive — the two stills below and the three at the resize — so the hole was
  // named by measurement rather than by the check written for it. The rest are
  // the other ways the same empty loop went unheld.
  'the-still-paints-only-the-first-camera': {
    check: CAMERAS,
    file: SITE_JS,
    from: '  for (const entry of views) {\n    if (entry.view.render(still, entry.openness()))',
    to: '  for (const entry of views.slice(0, 1)) {\n    if (entry.view.render(still, entry.openness()))',
  },
  // The one that started this. Under the preference the page's own sim is
  // never advanced at all, so the still becomes the flat resting pill — the
  // one picture that visitor must not be shown.
  'the-still-is-painted-from-the-page-sim': {
    check: CAMERAS,
    file: SITE_JS,
    from: 'entry.view.render(still, entry.openness())',
    to: 'entry.view.render(sim, entry.openness())',
  },
  // The same defect reached through the entry rather than through the module's
  // local. On the page these are the same object, which is exactly why it read
  // as harmless; it was measured surviving alongside the one above.
  'the-still-is-painted-from-the-cameras-own-fluid': {
    check: CAMERAS,
    file: SITE_JS,
    from: 'entry.view.render(still, entry.openness())',
    to: 'entry.view.render(entry.sim, entry.openness())',
  },
  'the-still-opens-every-camera': {
    check: CAMERAS,
    file: SITE_JS,
    from: 'entry.view.render(still, entry.openness())',
    to: 'entry.view.render(still, 1)',
  },
  // `shouldDraw` is three-valued and this is the two-valued spelling of it: a
  // camera the observer has never spoken about — every camera on a page whose
  // browser has no IntersectionObserver — stops being drawn.
  'the-loop-draws-only-what-it-has-been-told-about': {
    check: CAMERAS,
    file: SITE_JS,
    from: '    if (!shouldDraw(entry.onScreen)) continue;',
    to: '    if (!entry.onScreen) continue;',
  },
  'the-loop-paints-every-camera-from-the-module-sim': {
    check: CAMERAS,
    file: SITE_JS,
    from: 'entry.view.render(entry.sim, entry.openness())',
    to: 'entry.view.render(sim, entry.openness())',
  },
  'the-loop-opens-every-camera': {
    check: CAMERAS,
    file: SITE_JS,
    from: 'entry.view.render(entry.sim, entry.openness())',
    to: 'entry.view.render(entry.sim, 1)',
  },

  // And the lines that resize. The key is the box AND the ratio; drop either
  // half and the resize is skipped whenever only that half changed — the
  // ratio half is a window dragged between a 2x display and a 1x one, where
  // every box measures the same and the backing store keeps the old ratio.
  'the-layout-key-forgets-the-ratio': {
    check: SCALED,
    file: SITE_JS,
    from: '    const key = `${Math.round(box.width)}x${Math.round(box.height)}@${dpr}`;',
    to: '    const key = `${Math.round(box.width)}x${Math.round(box.height)}`;',
  },
  'the-layout-key-forgets-the-box': {
    check: SCALED,
    file: SITE_JS,
    from: '    const key = `${Math.round(box.width)}x${Math.round(box.height)}@${dpr}`;',
    to: '    const key = `@${dpr}`;',
  },
  // The face arriving moves every word the hero measured and no box shows it.
  'the-layout-ignores-force': {
    check: SCALED,
    file: SITE_JS,
    from: '    if (!force && entry.key === key) continue;',
    to: '    if (entry.key === key) continue;',
  },
  // Every camera resized on every call: each scroll on iOS clears every canvas.
  'the-layout-resizes-every-camera-every-time': {
    check: SCALED,
    file: SITE_JS,
    from: '    if (!force && entry.key === key) continue;\n',
    to: '',
  },
  'the-layout-never-remembers-the-key': {
    check: SCALED,
    file: SITE_JS,
    from: '    entry.key = key;\n',
    to: '',
  },
  // The page stops answering a resize at all. Nothing else in the gate reaches
  // the listener, and without it the canvases keep the size and the pixel
  // ratio they were loaded at for the rest of the visit.
  'the-page-stops-answering-a-resize': {
    check: SCALED,
    file: SITE_JS,
    from: "addEventListener('resize', () => layout(), { passive: true });",
    to: "addEventListener('orientationchange', () => layout(), { passive: true });",
  },
  // Under the preference there is no loop to draw the next frame, so a resize
  // that does not repaint is a canvas that stays cleared for the whole visit.
  'the-preference-is-answered-with-no-repaint': {
    check: SCALED,
    file: SITE_JS,
    from: '  if (reduceMotion) renderStill();',
    to: '  if (!reduceMotion) renderStill();',
  },

  // The journey's handovers: the printed notch into the footage, and the
  // footage into the band's notch. Each is one camera only if both sides
  // agree on the place and the size.
  'the-dive-aims-off-the-hold': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'hero?.setDive(dive, hold(vw, vh), scrollY,',
    to: 'hero?.setDive(dive, hold(vw, vh * 0.9), scrollY,',
  },
  'the-display-parts-from-the-print': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const laid = dive < 1 ? hero?.notchAt() : null;',
    to: 'const laid = null;',
  },
  // Focus the eye cannot see: the demo's button under the print, the
  // download under the film.
  'the-hidden-demo-button-takes-focus': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: "if (!motion.matches(':focus-visible') || section.hasAttribute('data-words')) return;",
    to: 'return;',
  },
  'the-pill-runs-off-a-phone': {
    check: JOURNEY,
    file: CSS,
    from: '(100vw - 2 * var(--gutter)) * 185 / 284)',
    to: '(100vw - 2 * var(--gutter)) * 185 / 200)',
  },
  'the-film-words-stand-as-ghosts': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: "section.toggleAttribute('data-title', c.words > 0.5 && !c.covered);",
    to: "section.style.setProperty('--words', c.words.toFixed(3));",
  },
  'the-reload-shows-the-page-short': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'scrollTo(0, Number(restoring) || 0);',
    to: '',
  },
  'the-resize-loses-the-beat': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: "else if ('s' in keep) y = top + keep.s * vh;",
    to: "else if ('s' in keep) y = scrollY;",
  },
  'the-download-takes-focus-under-the-film': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'mark.getBoundingClientRect().top > 1) mark.scrollIntoView();',
    to: 'mark.getBoundingClientRect().top > 1) mark.focus();',
  },
  // Queued behind the page's loop, the dive reached the print a frame late.
  'the-print-trails-the-scroll': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: "addEventListener('scroll', () => place(), { passive: true });",
    to: "addEventListener('scroll', () => requestAnimationFrame(place), { passive: true });",
  },
  'the-notch-floats-mid-screen': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'return { x: vw / 2, y: 0, scale: shots(vw, vh).wide };',
    to: 'return { x: vw / 2, y: vh * 0.3, scale: shots(vw, vh).wide };',
  },
  // The journey's footage off its box of the desktop, where the hand is drawn.
  'the-journey-lays-the-footage-off-the-still': {
    check: JOURNEY,
    file: CSS,
    from: '  left: 540px;\n  width: 570px;',
    to: '  left: 548px;\n  width: 570px;',
  },
  // The wide shot sized to the window's width alone: on anything taller than
  // the display's own proportion, the page shows under the desktop.
  'the-wide-shot-leaves-the-page-showing': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const wide = Math.max(vw / SCREEN.width, vh / SCREEN.height);',
    to: 'const wide = vw / SCREEN.width;',
  },
  // The close shot framed by the window's height alone runs the player under
  // the words at its foot.
  'the-close-shot-runs-under-the-words': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: '(vh - WORDS) / PLAYER.height',
    to: '(vh * 0.8) / PLAYER.height',
  },
  'the-skip-freezes-the-words': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: '|${c.live.toFixed(3)}|${c.words.toFixed(3)}|`',
    to: '|${c.live.toFixed(3)}|`',
  },
  // The bloom's reach and the download's lift left out of the key: a frame
  // where only they change keeps the old ones.
  'the-skip-freezes-the-reach': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: '`${far.toFixed(0)}|',
    to: '`',
  },
  'the-skip-freezes-the-held-sheet': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: '|${held.toFixed(1)}|',
    to: '|',
  },
  'the-skip-freezes-the-drawing': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: '|${drawn}|',
    to: '|',
  },
  // The halftone's pitch left out of the key: a resize that changes it alone
  // keeps the old dots.
  'the-skip-freezes-the-halftone': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: '|${pitch.toFixed(2)}|',
    to: '|',
  },
  // The download over the film: drawn up through the handover, it covers the
  // desktop the camera is landing on.
  'the-download-covers-the-landing': {
    check: JOURNEY,
    file: CSS,
    from: '  position: relative;\n  z-index: 1;\n  margin-top: calc(-100svh - var(--ahead));',
    to: '  position: relative;\n  z-index: 3;\n  margin-top: calc(-100svh - var(--ahead));',
  },
  // The heading short of half the window: the notch, and the camera landing
  // on it, above the window's centre.
  'the-link-lands-off-centre': {
    check: JOURNEY,
    file: CSS,
    from: 'min-height: calc(50svh - var(--bezel) - var(--notch-h) / 2);',
    to: 'min-height: calc(40svh - var(--bezel) - var(--notch-h) / 2);',
  },
  // The band's notch narrower than the close shot's on a tablet: the camera
  // pulls out to land on the link.
  'the-camera-pulls-out-onto-the-link': {
    check: JOURNEY,
    file: CSS,
    from: 'min(333px, (100vw - 32px) * 185 / 372',
    to: 'min(300px, (100vw - 32px) * 185 / 372',
  },
  // A dot's soft edge left at 0.6pt when it has gone: a pink haze on the band
  // that goes in one frame as the pin does.
  'the-halftone-leaves-a-haze': {
    check: JOURNEY,
    file: CSS,
    from: 'transparent calc(var(--r) + min(var(--dot) / 8, var(--r)))',
    to: 'transparent calc(var(--r) + 0.6px)',
  },
  // The soft edge in the desktop's points: close, a blur that holds the dots
  // shut while the scroll goes on.
  'the-halftone-blurs-shut-close': {
    check: JOURNEY,
    file: CSS,
    from: 'transparent calc(var(--r) + min(var(--dot) / 8, var(--r)))',
    to: 'transparent calc(var(--r) + min(0.6px, var(--r)))',
  },
  // The download as tall as its content: landed, the pinned how-to shows
  // under it until the pin goes.
  'the-download-is-shorter-than-the-window': {
    check: JOURNEY,
    file: CSS,
    from: '  min-height: 100vh;\n  min-height: 100svh;\n}',
    to: '}',
  },
  'the-pin-stays-up-under-the-download': {
    check: JOURNEY,
    file: CSS,
    from: '[data-covered] .film__pin { visibility: hidden; }',
    to: '[data-covered] .film__pin { }',
  },
  'the-film-takes-the-download-clicks': {
    check: JOURNEY,
    file: CSS,
    from: 'while they are up. */\n  pointer-events: none;',
    to: 'while they are up. */',
  },
  'the-print-returns-behind-the-pull': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'scrollY, dive >= 1 && s >= SETTLE);',
    to: 'scrollY, dive >= 1 && !c.covered);',
  },
  'the-footage-holds-past-its-pixels': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const CLOSEST = 1.8;',
    to: 'const CLOSEST = 2.2;',
  },
  // The how-to still coming up as the band arrives: covered before it is read.
  'the-band-comes-before-the-how-to': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const HOW = 0.24;',
    to: 'const HOW = 0.9;',
  },
  'the-how-to-comes-before-its-title': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const TITLE = 0.12;',
    to: 'const TITLE = 0.3;',
  },
  'the-footage-cuts-in': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const SETTLE = 0.3;',
    to: 'const SETTLE = 0.0004;',
  },
  // The player still going into the notch as the camera lands: what lands on
  // the band's notch is a player mid-gesture, not the idle notch the band has.
  'the-camera-lands-on-the-player': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const RETRACT = 0.48;',
    to: 'const RETRACT = 0.9;',
  },
  // The player put away in a few pixels of scroll: a cut, not the app's move.
  'the-player-snaps-into-the-notch': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const RETRACT = 0.48;',
    to: 'const RETRACT = 0.01;',
  },
  // The move onto the band's notch left to its last pixels: a jump.
  'the-camera-snaps-onto-the-band': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const MOVE = [0, 0.5];',
    to: 'const MOVE = [0.495, 0.5];',
  },
  // The camera setting off once the words have gone: it holds the emptied
  // desktop.
  'the-camera-waits-on-the-empty-desktop': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const MOVE = [0, 0.5];',
    to: 'const MOVE = [0.1, 0.5];',
  },
  // The desktop going back to print evenly in the dots' radius: what they
  // show goes as its square, so a last haze lingers while the scroll goes on.
  'the-last-dots-linger': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'on: showing(1 - unit((leave - OFF) / (LEAVE - OFF))),',
    to: 'on: Math.sqrt(1 - unit((leave - OFF) / (LEAVE - OFF))),',
  },
  // The desktop not quite gone as the page takes the download: the pin goes
  // with some of it still lit.
  'the-pin-goes-with-the-desktop-lit': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'on: showing(1 - unit((leave - OFF) / (LEAVE - OFF))),',
    to: 'on: showing(1 - unit((leave - OFF) / (LEAVE + 0.1 - OFF))),',
  },
  // The stylesheet's dots a size the camera does not read them at: what it
  // takes away evenly is not what shows.
  'the-dots-are-another-size': {
    check: JOURNEY,
    file: CSS,
    from: '--r: calc(var(--on) * var(--on) * 0.75 * var(--dot));',
    to: '--r: calc(var(--on) * var(--on) * 0.7 * var(--dot));',
  },
  // Held where the camera starts rather than where it is: the band's notch
  // parts from the desktop's as the camera moves.
  'the-band-parts-from-the-desktop': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'return { drawn: s >= end - LEAVE, held: y - dockY };',
    to: 'return { drawn: s >= end - LEAVE, held: -dockY };',
  },
  // The sheet in the page's flow, not stuck to the window: a script held it
  // there, a frame behind every scroll, and it jumped on a fast one.
  'the-download-is-held-by-script': {
    check: JOURNEY,
    file: CSS,
    from: '  position: sticky;\n  top: var(--held, 0px);',
    to: '  position: relative;\n  top: var(--held, 0px);',
  },
  // A runway a window long: the sheet only reaches the window's top after
  // the handover has begun, its notch below the desktop's.
  'the-runway-is-short': {
    check: JOURNEY,
    file: CSS,
    from: '--ahead: 200svh;',
    to: '--ahead: 100svh;',
  },
  // Seen on its runway before it is drawn: through the dive, and clickable
  // under the desktop.
  'the-download-shows-on-its-runway': {
    check: JOURNEY,
    file: CSS,
    from: '.get__sheet { opacity: 0; pointer-events: none; }',
    to: '.get__sheet { pointer-events: none; }',
  },
  // The band's pill never told the desktop is over it: it prints the
  // soundtrack's clock under the recording's.
  'the-pill-shows-two-clocks': {
    check: JOURNEY,
    file: 'site/js/band.js',
    from: "live.played && !this.link.closest('[data-under]') ? live : this.recorded",
    to: 'live.played ? live : this.recorded',
  },
  // The words back on one threshold for every window.
  'the-words-come-up-through-the-dots': {
    check: JOURNEY,
    file: CSS,
    from: '(var(--gone, 1) - var(--clear, 0)) / 0.06',
    to: '(var(--gone, 1) - 0.55) / 0.35',
  },
  // The sheet's paper left to its tooth alone: the film shows through it.
  'the-download-is-only-tooth': {
    check: JOURNEY,
    file: CSS,
    from: 'flex-direction: column;\n  background: var(--paper) var(--tooth);',
    to: 'flex-direction: column;\n  background: var(--tooth);',
  },
  // The bezel butted to the bar's edge: a hairline of the printed bar shows
  // between the riso edge and the desktop landing on it.
  'the-seam-shows-the-printed-bar': {
    check: JOURNEY,
    file: 'site/js/band.js',
    from: 'const LIP = 2;',
    to: 'const LIP = 0;',
  },
  // The link to the download landing at its runway's top, in the film.
  'the-download-link-lands-in-the-film': {
    check: JOURNEY,
    file: CSS,
    from: '[data-journey="on"] .get__mark { top: var(--ahead); }',
    to: '[data-journey="on"] .get__mark { top: 0; }',
  },
  // Drawn as the camera lands rather than a window before the page has it.
  'the-download-is-drawn-late': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'return { drawn: s >= end - LEAVE, held: y - dockY };',
    to: 'return { drawn: s >= end - LEAVE / 2, held: y - dockY };',
  },
  // The push in finishing after the film has wrapped: every lap starts on a cut.
  'the-loop-wraps-on-a-cut': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'in: [28.3, 30] }',
    to: 'in: [29.8, 31.5] }',
  },
  // The pull back done in a third of a second: a cut, not a move.
  'the-zoom-is-a-cut': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'out: [20.3, 22]',
    to: 'out: [20.3, 20.6]',
  },
  'the-camera-stops-short-of-the-band': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const k = dock ? ease(unit((leave - MOVE[0]) / (MOVE[1] - MOVE[0]))) : 0;',
    to: 'const k = dock ? 0.97 * ease(unit((leave - MOVE[0]) / (MOVE[1] - MOVE[0]))) : 0;',
  },
  // The desktop going back to print with the camera still well short of the
  // band's notch: the two notches and menu bars show at two sizes.
  'the-desktop-goes-before-it-lands': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const OFF = 0.42;',
    to: 'const OFF = 0.2;',
  },
  // The desktop dissolving all over at once as it goes: the link under it no
  // sooner than the far corners.
  'the-desktop-goes-all-at-once': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: "mac.toggleAttribute('data-going', dive >= 1);",
    to: "mac.toggleAttribute('data-going', false);",
  },
  // The wave measured to the whole desktop, not the window: on a phone it
  // sweeps off early and the last of the scroll shows nothing.
  'the-wave-overshoots-the-window': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'const far = dive < 1 ? REACH : reach(x, y, scale, vw, vh);',
    to: 'const far = REACH;',
  },
  // Measured four times as far across as down against a band twice: the
  // bottom corners still solid as the pin goes.
  'the-wave-falls-short-of-the-corners': {
    check: JOURNEY,
    file: TUNNEL_JS,
    from: 'return Math.hypot(Math.max(x, vw - x) / 2, Math.max(0, vh - y)) / scale;',
    to: 'return Math.hypot(Math.max(x, vw - x) / 4, Math.max(0, vh - y)) / scale;',
  },
  // The solid's edge travelling slower than the clearing: they meet mid-way
  // and a hard edge wipes across the screen.
  'the-band-closes-to-a-hard-edge': {
    check: JOURNEY,
    file: CSS,
    from: 'transparent calc((var(--gone) * 1.3 + 0.1) * 100%), #000 calc((var(--gone) * 1.3 + 0.3) * 100%)),',
    to: 'transparent calc((var(--gone) * 1.1 + 0.1) * 100%), #000 calc((var(--gone) * 1.1 + 0.3) * 100%)),',
  },
  // The clearing already open at the notch as the dots come: a hole jumps in.
  'the-notch-opens-with-a-jump': {
    check: JOURNEY,
    file: CSS,
    from: 'transparent calc((var(--gone) * 1.3 - 0.3) * 100%), #000 calc(var(--gone) * 1.3 * 100%));',
    to: 'transparent calc((var(--gone) * 1.3 - 0.1) * 100%), #000 calc((var(--gone) * 1.3 + 0.2) * 100%));',
  },
  // The whole band sped up alike, so it never closes: the clearing passes the
  // window's corner a tenth of a window before the page lets go, and that
  // last stretch of scroll moves nothing.
  'the-desktop-is-gone-before-the-pin': {
    check: JOURNEY,
    file: CSS,
    from: 'transparent calc((var(--gone) * 1.3 - 0.3) * 100%), #000 calc(var(--gone) * 1.3 * 100%));',
    to: 'transparent calc((var(--gone) * 1.6 - 0.3) * 100%), #000 calc(var(--gone) * 1.6 * 100%));',
    also: [
      { from: 'transparent calc((var(--gone) * 1.3 + 0.1) * 100%), #000 calc((var(--gone) * 1.3 + 0.3) * 100%)),',
        to: 'transparent calc((var(--gone) * 1.6 + 0.1) * 100%), #000 calc((var(--gone) * 1.6 + 0.3) * 100%)),' },
    ],
  },

  // The hand drawn on the film: the gesture it teaches has to be the one the
  // app reads, and it is drawn only where the footage is in its own points.
  'the-fingers-swipe-the-wrong-way': {
    check: HAND,
    file: TOUCHES_JS,
    from: 'const along = cue.dir * HAND.reach',
    to: 'const along = -cue.dir * HAND.reach',
  },
  // The pause drawn with a sideways drift: a diagonal the app reads as neither.
  'the-pause-swipe-drifts-sideways': {
    check: HAND,
    file: TOUCHES_JS,
    from: "if (cue.axis === 'x') hand.dx = along;\n      else hand.dy = along;",
    to: "hand.dx = along;\n      if (cue.axis === 'y') hand.dy = along;",
  },
  'the-app-reads-a-vertical-swipe-as-a-skip': {
    check: HAND,
    file: SWIPE_SWIFT,
    from: '            return Step(action: .togglePlayback)',
    to: '            return Step(action: .skipForward)',
  },
  // The click drawn while the camera is out on the whole desktop.
  'a-touch-is-drawn-in-the-wide-shot': {
    check: HAND,
    file: TOUCHES_JS,
    from: "{ kind: 'click', at: 12.873,",
    to: "{ kind: 'click', at: 21.5,",
  },
  // The fingers rested lower: a swipe down carries them out of the close shot.
  'the-fingers-leave-the-close-shot': {
    check: HAND,
    file: TOUCHES_JS,
    from: 'export const HAND = { x: 756, y: 215, reach: 56 };',
    to: 'export const HAND = { x: 756, y: 245, reach: 56 };',
  },
  'the-fingers-lift-before-the-swipe-fires': {
    check: HAND,
    file: TOUCHES_JS,
    from: 'const gone = unit((t - cue.up) / LIFT);\n      hand.shown',
    to: 'const gone = unit((t - cue.up + 0.3) / LIFT);\n      hand.shown',
  },
  'the-fingers-draw-outside-the-journey': {
    check: HAND,
    file: SITE_JS,
    from: 'if (tunnel) startTouches(',
    to: 'if (film) startTouches(',
  },
  'the-fingers-ease-back-before-it-fires': {
    check: HAND,
    file: TOUCHES_JS,
    from: '(inOut(unit((t - cue.down) / (cue.up - cue.down))) + 0.1 * gone)',
    to: '(Math.sin(Math.PI * unit((t - cue.down) / (cue.up - cue.down))) + 0.1 * gone)',
  },
  'the-app-reads-a-swipe-the-other-way': {
    check: HAND,
    file: SWIPE_SWIFT,
    from: 'let action: Action = x > 0 ? .skipForward : .skipBackward',
    to: 'let action: Action = x < 0 ? .skipForward : .skipBackward',
  },
  'the-how-to-lights-a-line-it-lacks': {
    check: HAND,
    file: PAGE,
    from: '<li data-how="swipe">',
    to: '<li data-how="swipes">',
  },

  // The page asks to play on load; the pause is the visitor's. The markup
  // starting the element itself would play at a visitor who paused last time,
  // since only the script remembers that.
  'the-soundtrack-autoplays': {
    check: SOUNDTRACK,
    file: PAGE,
    from: '<audio hidden preload="none"',
    to: '<audio hidden autoplay preload="none"',
  },
  'the-soundtrack-downloads-before-play': {
    check: SOUNDTRACK,
    file: PAGE,
    from: '<audio hidden preload="none"',
    to: '<audio hidden preload="metadata"',
  },
  'the-soundtrack-regrows-a-promo-heading': {
    check: SOUNDTRACK,
    file: PAGE,
    from: ' data-soundtrack-audio></audio>',
    to: ' data-soundtrack-audio></audio>\n'
      + '  <p class="soundtrack__eyebrow">Live ferrofluid</p>',
  },
  // One transport, in the circles. The hero's old one coming back would be two
  // players for one track.
  'a-second-transport-regrows-in-the-hero': {
    check: SOUNDTRACK,
    file: PAGE,
    from: '      <p class="hero__meta">',
    to: '      <div class="listen"><button type="button">Play</button></div>\n'
      + '      <p class="hero__meta">',
  },
  'the-soundtrack-toggle-is-named-over-its-label': {
    check: SOUNDTRACK,
    file: PAGE,
    from: 'data-soundtrack-toggle data-playing="false">',
    to: 'data-soundtrack-toggle data-playing="false" aria-label="Play or pause">',
  },
  'the-soundtrack-status-competes-with-the-demo': {
    check: SOUNDTRACK,
    file: PAGE,
    from: '<p class="visually-hidden" data-soundtrack-status',
    to: '<p data-soundtrack-status',
  },
  'the-soundtrack-toggle-never-says-pause': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: "soundtrackToggleLabel.textContent = playing ? 'Pause' : 'Play';",
    to: "soundtrackToggleLabel.textContent = 'Play';",
  },
  'the-second-track-claims-to-be-playing': {
    check: SOUNDTRACK,
    file: PAGE,
    from: 'data-soundtrack-track aria-pressed="false"',
    to: 'data-soundtrack-track aria-pressed="true"',
  },
  'a-track-circle-is-named-over-its-title': {
    check: SOUNDTRACK,
    file: PAGE,
    from: 'data-soundtrack-track aria-pressed="true"',
    to: 'data-soundtrack-track aria-label="Track one" aria-pressed="true"',
  },
  'the-pressed-circle-never-follows-the-track': {
    check: SOUNDTRACK,
    file: PLAYER_JS,
    from: "String(i === index)",
    to: "String(i === 0)",
  },
  'a-circle-shows-another-tracks-sleeve': {
    check: SOUNDTRACK,
    file: PAGE,
    from: 'src="media/cover-cyberpunk-renaissance.webp" alt=""',
    to: 'src="media/cover-chrome-funk.webp" alt=""',
  },
  'the-second-track-points-at-nothing': {
    check: SOUNDTRACK,
    file: PAGE,
    from: 'data-src="media/cyberpunk-renaissance.mp3"',
    to: 'data-src="media/missing.mp3"',
  },
  'the-second-track-has-no-sleeve': {
    check: SOUNDTRACK,
    file: PAGE,
    from: 'data-cover="media/cover-cyberpunk-renaissance.webp"',
    to: 'data-cover="media/missing.webp"',
  },
  'the-player-opens-on-a-track-it-does-not-show': {
    check: SOUNDTRACK,
    file: PAGE,
    from: '<audio hidden preload="none" src="media/chrome-funk.mp3"',
    to: '<audio hidden preload="none" src="media/cyberpunk-renaissance.mp3"',
  },
  // A pause written under one key and read under another is a pause that is
  // never remembered: the next visit plays at the visitor again.
  'a-pause-is-written-but-never-read': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: 'localStorage.getItem(SOUNDTRACK_PAUSED)',
    to: "localStorage.getItem('magnetite.paused')",
  },
  'the-load-ignores-a-remembered-pause': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: 'if (!soundtrackWasPaused()) soundtrackAudio.play().catch(() => {});',
    to: 'soundtrackAudio.play().catch(() => {});',
  },
  // Outside a gesture an AudioContext starts suspended, and the element
  // routed into it goes silent: the music the page just started, muted by
  // the thing that was meant to listen to it.
  'the-analyser-is-built-outside-a-gesture': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: '  if (soundtrackMayListen()) enableSoundtrackAnalyser();',
    to: '  enableSoundtrackAnalyser();',
  },
  // Music the browser let start on load: routed into a context before the
  // browser says it runs, it goes silent; never asked for, the liquid replays
  // its capture over the song until the visitor clicks.
  'the-unasked-analyser-takes-a-suspended-context': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: "if (context.state === 'running' && !soundtrackAnalyserPromise) enableSoundtrackAnalyser(context);",
    to: 'if (!soundtrackAnalyserPromise) enableSoundtrackAnalyser(context);',
  },
  'music-started-on-load-is-never-heard': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: '    if (!soundtrackAnalyserPromise) listenUnasked();',
    to: '',
  },
  'the-circles-sit-on-the-words': {
    check: SOUNDTRACK,
    file: 'site/js/corner.js',
    from: "if (under) soundtrack.toggleAttribute('data-aside', true);",
    to: "if (under) soundtrack.toggleAttribute('data-aside', false);",
  },
  'the-unheard-song-plays-on': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: '          soundtrackAudio.pause();\n          return;',
    to: '          return;',
  },
  'the-unheard-song-resumes-partway-in': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: '        player.rewind();\n',
    to: '',
  },
  'the-unheard-song-is-announced-as-paused': {
    check: SOUNDTRACK,
    file: SITE_JS,
    // The way it was: unmuted at once, before the queued pause event.
    from: "          soundtrackAudio.addEventListener('pause', () => { soundtrackAudio.muted = false; }, { once: true });\n"
      + '          soundtrackAudio.pause();\n          return;',
    to: '          soundtrackAudio.pause();',
  },
  'the-first-gesture-answers-the-players-own-play': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: ".closest('[data-player] button');",
    to: ".closest('[data-player] a');",
  },
  'soundtrack-changes-are-silent-to-assistive-technology': {
    check: SOUNDTRACK,
    file: PAGE,
    from: 'data-soundtrack-status aria-live="polite"',
    to: 'data-soundtrack-status',
  },
  'the-soundtrack-bypasses-the-analyser': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: '      source.connect(soundtrackAnalyser);',
    to: '      source.connect(soundtrackContext.destination);',
  },
  'the-live-analyser-keeps-playing-the-capture': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: '  if (!liveAnalyser) return REAL_LEVELS[frameNow(step)];',
    to: '  if (liveAnalyser) return REAL_LEVELS[frameNow(step)];',
  },
  'the-live-drive-reinherits-the-showcase-lag': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: 'const LIVE_SMOOTH_TAU = 0.035;',
    to: 'const LIVE_SMOOTH_TAU = 0.11;',
  },
  'the-live-drive-computes-the-replay-rate': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: 'const LIVE_SMOOTH_K = 1 - Math.exp(-SIM_STEP / LIVE_SMOOTH_TAU);',
    to: 'const LIVE_SMOOTH_K = 1 - Math.exp(-SIM_STEP / SMOOTH_TAU);',
  },
  'the-live-drive-never-uses-its-short-rate': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: '  return smoothStep(drive, target, liveAnalyser ? LIVE_SMOOTH_K : CADENCE.k);',
    to: '  return smoothStep(drive, target, CADENCE.k);',
  },
  // The binding, not the spelling: a declaration renamed while the two-rate
  // call still says the old name. In a full run this is a ReferenceError and
  // dies wherever the page is first run; solo, the soundtrack check has to own
  // it, which is how the harness proves the check read the name off the
  // declaration instead of carrying a copy — the copy is what a3a25a0 did,
  // and it killed the three renames declared correct further up.
  'the-cadence-declaration-and-the-call-disagree': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: 'const CADENCE = replayCadence(SIM_HZ, CAPTURE_HZ, SMOOTH_TAU);',
    to: 'const REPLAY = replayCadence(SIM_HZ, CAPTURE_HZ, SMOOTH_TAU);',
  },
  'the-accumulator-declaration-and-the-call-disagree': {
    check: SOUNDTRACK,
    file: SITE_JS,
    from: 'const drive = new Array(REAL_LEVELS[0].length).fill(0);',
    to: 'const lowPassed = new Array(REAL_LEVELS[0].length).fill(0);',
  },
  'the-worklet-registers-under-the-wrong-name': {
    check: SOUNDTRACK,
    file: BANDS_WORKLET,
    from: "registerProcessor('bands', BandsProcessor);",
    to: "registerProcessor('levels', BandsProcessor);",
  },

  // WebMCP is discovery-only and progressive. The page must load it, every
  // tool must carry the current read-only annotation, its story must include
  // the real native footage, and repeated initialisation must not register a
  // second copy of every tool.
  'the-webmcp-module-is-not-loaded': {
    check: WEBMCP,
    file: PAGE,
    from: '<script type="module" src="js/webmcp.mjs"></script>',
    to: '<script type="module" src="js/missing-webmcp.mjs"></script>',
  },
  'the-webmcp-tools-claim-they-can-write': {
    check: WEBMCP,
    file: WEBMCP_JS,
    from: '  readOnlyHint: true,',
    to: '  readOnlyHint: false,',
  },
  'the-webmcp-story-drops-the-native-film': {
    check: WEBMCP,
    file: WEBMCP_JS,
    from: "{ state: 'native-film', element: '#demo-film'",
    to: "{ state: 'native-film', element: '#demo-missing'",
  },
  'the-webmcp-tools-register-twice': {
    check: WEBMCP,
    file: WEBMCP_JS,
    from: '    if (registered.has(tool.name)) continue;',
    to: '    if (false) continue;',
  },

  // The browser analyser's own four checks join this harness. Full mode also
  // runs portcheck; solo mode dispatches straight to bandscheck so each one
  // has to kill its own mutation rather than shelter behind parity.
  'the-browser-window-loses-its-power-normalisation': {
    check: BAND_PORT,
    file: BANDS_JS,
    from: '  const k = 0.5 * Math.sqrt(8 / 3);',
    to: '  const k = 0.5;',
  },
  'the-browser-partition-leaves-a-bin-between-bands': {
    check: BAND_PARTITION,
    file: BANDS_JS,
    from: '    lower = upper;',
    to: '    lower = upper + 1;',
  },
  'the-silence-pump-never-reaches-zero': {
    check: BAND_PUMP,
    file: BANDS_JS,
    from: '      const decayed = this.bands[i] * 0.82;',
    to: '      const decayed = this.bands[i];',
  },
  'the-lowest-sine-lights-the-next-band': {
    check: BAND_SINES,
    file: 'site/test/golden/bands-band-00.txt',
    from: '7 9.96263325e-01 9.08905327e-01',
    to: '7 9.08905327e-01 9.96263325e-01',
  },
};

const ALL_CHECKS = [REPLAY, HELD, CLOCKED, RATE, SIZE, SKIP, INK, POINTER, FIELD_NOTES, OUTLINE, NORMAL, HYSTERESIS, CROWN, HALO, AUDIO, FLOOR, DOWNLOAD, CRAWLABLE, POLICIES, LOCAL_TYPE, FIRSTLAUNCH, LOOP, SOUNDTRACK, WEBMCP, FILM, CREDIT, BORROWED, UNBROKEN, STILL, STILLFILM, EXPONENTIAL, PIGMENT, BLANK, TRANSPORT, PREFERENCE, SPENDS, CONTOUR, CAMERAS, SCALED, JOURNEY, HAND, ...BAND_CHECKS];

/**
 * Every check portcheck runs is a check this harness has watched fail.
 *
 * The header of this file has claimed since it was written that "every
 * assertion here has been mutation-tested", and nothing enforced it: a check
 * added to portcheck's CHECKS map and forgotten here was still green, still
 * counted, and still never once observed to catch anything. That happened —
 * `theRecordPlateStandsItsLiquidUp` was added, ran clean, and had no mutant
 * behind it until this ran. The coverage claim is now an assertion.
 */
function requireEveryCheckIsCovered() {
  const names = [];
  for (const script of ['portcheck.mjs', 'bandscheck.mjs']) {
    const source = readFileSync(join(repo, 'site', 'test', script), 'utf8');
    const map = /const CHECKS = \{([\s\S]*?)\n\};/.exec(source);
    if (!map) throw new Error(`could not find ${script}'s CHECKS map — this harness is stale`);
    names.push(...[...map[1].matchAll(/^ {2}([A-Za-z_$][\w$]*)(?:,|\(\)\s*\{)/gm)]
      .map((match) => match[1]));
  }

  const listed = new Set(ALL_CHECKS);
  const missing = names.filter((name) => !listed.has(name));
  if (missing.length) {
    throw new Error(`portcheck runs ${missing.join(', ')} but this harness never runs them alone`);
  }
  const named = new Set(Object.values(MUTANTS).map((m) => m.check));
  const uncovered = names.filter((name) => !named.has(name));
  if (uncovered.length) {
    throw new Error(`no mutant names ${uncovered.join(', ')} — a check nothing has broken is not `
      + 'evidence of anything, which is the whole argument of this file');
  }
}

requireEveryCheckIsCovered();

function fresh(work) {
  rmSync(work, { recursive: true, force: true });
  mkdirSync(work, { recursive: true });
  cpSync(join(repo, 'site', 'js'), join(work, 'site', 'js'), { recursive: true });
  cpSync(join(repo, 'site', 'data'), join(work, 'site', 'data'), { recursive: true });
  cpSync(join(repo, 'site', 'test'), join(work, 'site', 'test'), { recursive: true });
  // The button's box is four fractions of the retracted camera's crop, stated
  // in the stylesheet and derived from site.js. Both sides have to be mutable
  // here, or the only mutants possible are the ones that move the crop.
  cpSync(join(repo, 'site', 'css'), join(work, 'site', 'css'), { recursive: true });
  cpSync(join(repo, 'site', 'fonts'), join(work, 'site', 'fonts'), { recursive: true });
  // gen-levels.mjs reads the app's own resource, and the audio check compares
  // against it — so the copy needs it too, at the same relative path.
  mkdirSync(join(work, 'Resources'), { recursive: true });
  cpSync(join(repo, 'Resources', 'real-levels.txt'), join(work, 'Resources', 'real-levels.txt'));
  // The floor check reads the page's promise and the build's manifest and
  // compares them, so both have to be mutable here — the interesting mutant is
  // the one that moves the BUILD and watches the page fail to notice.
  cpSync(join(repo, 'Package.swift'), join(work, 'Package.swift'));
  cpSync(join(repo, 'site', 'index.html'), join(work, 'site', 'index.html'));
  // The Pages custom-domain file is part of the public identity checked with
  // the canonical metadata, so it must be present and independently mutable.
  cpSync(join(repo, 'site', 'CNAME'), join(work, 'site', 'CNAME'));
  cpSync(join(repo, ROBOTS), join(work, ROBOTS));
  cpSync(join(repo, SITEMAP), join(work, SITEMAP));
  cpSync(join(repo, LLMS), join(work, LLMS));
  cpSync(join(repo, PRIVACY), join(work, PRIVACY));
  cpSync(join(repo, TERMS), join(work, TERMS));
  mkdirSync(join(work, dirname(SECURITY)), { recursive: true });
  cpSync(join(repo, SECURITY), join(work, SECURITY));
  // Same check, second source: the hardware clause is only false because the
  // app draws a pill when there is no notch, so the gate reads that branch out
  // of the Swift rather than trusting the page's copy.
  mkdirSync(join(work, dirname(METRICS_SWIFT)), { recursive: true });
  cpSync(join(repo, METRICS_SWIFT), join(work, METRICS_SWIFT));
  // The fingers drawn on the film go the way the app reads a swipe, which the
  // check reads out of the recogniser.
  cpSync(join(repo, SWIPE_SWIFT), join(work, SWIPE_SWIFT));
  // The rate the capture was taken at is a fact about the APP, so the check
  // that holds site.js to it reads the pump interval out of this file — and a
  // mutant has to be able to move the app's end of that comparison, not only
  // the page's.
  mkdirSync(join(work, dirname(LEVELS_SWIFT)), { recursive: true });
  cpSync(join(repo, LEVELS_SWIFT), join(work, LEVELS_SWIFT));
  // Same reason, second constant: the site's step rate is checked against the
  // app's TimelineView interval.
  mkdirSync(join(work, dirname(VIEW_SWIFT)), { recursive: true });
  cpSync(join(repo, VIEW_SWIFT), join(work, VIEW_SWIFT));
  // The mark check reads the app's generated copy of the contour, and the one
  // line that decides whether the menu bar draws it.
  mkdirSync(join(work, dirname(MARK_SWIFT)), { recursive: true });
  cpSync(join(repo, MARK_SWIFT), join(work, MARK_SWIFT));
  cpSync(join(repo, DELEGATE), join(work, DELEGATE));
  // The download check asks whether the linked build is really there and really
  // the version the bundle claims, so the copy needs both the file and the
  // Info.plist that names its version.
  cpSync(join(repo, 'Resources', 'Info.plist'), join(work, 'Resources', 'Info.plist'));
  cpSync(join(repo, 'site', 'downloads'), join(work, 'site', 'downloads'), { recursive: true });
  // The pigment parity gate reads the favicon's two fills against the ink and
  // the paper, so the copy needs the file — and needs it mutable, because the
  // interesting mutant is the one that moves a pigment nobody would ever see.
  cpSync(join(repo, 'site', 'favicon.svg'), join(work, 'site', 'favicon.svg'));
  // The film gate reads the footage's own track header and the still's own
  // header and derives the stylesheet's numbers from them, so the copy needs
  // the real bytes at the same relative path.
  cpSync(join(repo, 'site', 'media'), join(work, 'site', 'media'), { recursive: true });
  // The share card itself, whose size gate reads the IHDR out of its bytes.
  // Copied and never mutated: this harness replaces literal text and a PNG is
  // not text, so every mutant that reaches that check moves the page's promise
  // about the card instead.
  cpSync(join(repo, 'site', 'og.png'), join(work, 'site', 'og.png'));
}

function apply(work, name, mutant) {
  const path = join(work, mutant.file);
  const text = readFileSync(path, 'utf8');
  const count = text.split(mutant.from).length - 1;
  // `all` exists for one shape only: a value the page repeats deliberately, like
  // the build's filename under every download button. Moving one of those tests
  // that the copies agree; moving ALL of them is the only way to reach the
  // assertions past that one. Everything else stays exactly-once, because a
  // target that silently matched twice is a stale harness, not a mutation.
  // Naming the mutant matters more than it looks. A stale target is a gate that
  // has stopped being tested, and the way it arrives is an edit somewhere else
  // — two of these went stale on a no-break space typed into a line that reads
  // identically. "the harness is stale" with no name sends you looking through
  // every mutant that touches the file; the name sends you at the one.
  if (mutant.all) {
    if (count < 1) {
      throw new Error(`${name}: target matched 0 times in ${mutant.file} — the harness is stale`);
    }
    writeFileSync(path, text.split(mutant.from).join(mutant.to));
    return;
  }
  if (count !== 1) {
    throw new Error(`${name}: target matched ${count} times in ${mutant.file} — the harness is stale`);
  }
  let next = text.replace(mutant.from, mutant.to);
  // `also` exists for one shape too: RENAMING something. A rule that reads an
  // identifier out of the source and requires it back has to survive the thing
  // being called something else, or it is matching today's spelling rather
  // than asserting a property — and an identifier's mentions are not
  // contiguous, so a rename cannot be one `from`. Same exactly-once discipline
  // per edit, because a rename that silently missed a mention is a mutant
  // testing something other than what it is named for.
  for (const edit of mutant.also || []) {
    const seen = next.split(edit.from).length - 1;
    if (seen !== 1) {
      throw new Error(`${name}: also-target matched ${seen} times in ${mutant.file} — the harness is stale`);
    }
    next = next.replace(edit.from, edit.to);
  }
  writeFileSync(path, next);
}

function runOne(work, script, only) {
  const args = [join(work, 'site', 'test', script)];
  if (only) args.push(`--only=${only}`);
  try {
    const out = execFileSync(process.execPath, args, { encoding: 'utf8', stdio: 'pipe' });
    return { code: 0, output: out.trim().replace(/\n/g, ' ') };
  } catch (error) {
    const text = `${error.stdout || ''}${error.stderr || ''}`.trim().replace(/\n+/g, ' | ');
    return { code: error.status === undefined ? 1 : error.status, output: text };
  }
}

function run(work, only) {
  if (only) {
    const script = BAND_CHECKS.includes(only) ? 'bandscheck.mjs' : 'portcheck.mjs';
    return runOne(work, script, only);
  }
  const port = runOne(work, 'portcheck.mjs', null);
  const bands = runOne(work, 'bandscheck.mjs', null);
  return {
    code: port.code || bands.code,
    output: [port.output, bands.output].filter(Boolean).join(' | '),
  };
}

/**
 * Every target checked against the pristine tree before anything runs.
 *
 * Each mutant is applied to a fresh copy, so the pristine file is exactly what
 * each one will meet. Checking them all up front turns "the harness is stale"
 * from one name per run — fix, wait out a full suite, find the next — into the
 * whole list at once. Which matters because staleness arrives in batches: one
 * copy edit to a line of the page took four of these together.
 */
function preflight() {
  const cache = new Map();
  const stale = [];
  for (const [name, mutant] of Object.entries(MUTANTS)) {
    if (!cache.has(mutant.file)) {
      cache.set(mutant.file, readFileSync(join(repo, mutant.file), 'utf8'));
    }
    const count = cache.get(mutant.file).split(mutant.from).length - 1;
    const ok = mutant.all ? count >= 1 : count === 1;
    if (!ok) stale.push(`  ${name}: matched ${count} times in ${mutant.file}`);
    // The rename edits go stale on their own, and silently: the mutant still
    // applies, it just stops being the rename it is named for.
    for (const edit of mutant.also || []) {
      const seen = cache.get(mutant.file).split(edit.from).length - 1;
      if (seen !== 1) stale.push(`  ${name} (also): matched ${seen} times in ${mutant.file}`);
    }
  }
  if (stale.length) {
    process.stderr.write(`mutate: ${stale.length} stale target(s) — these gates are untested:\n`
      + `${stale.join('\n')}\n`);
    process.exit(2);
  }
}

preflight();

const work = mkdtempSync(join(tmpdir(), 'magnetite-mutate-'));
const results = [];

try {
  // Clean, full and then once per check alone. A check that cannot pass by
  // itself on unmutated source is broken whether or not a mutant kills it.
  fresh(work);
  results.push({ label: 'clean / full', clean: true, ...run(work, null) });
  for (const name of ALL_CHECKS) {
    fresh(work);
    results.push({ label: `clean / solo ${name}`, clean: true, ...run(work, name) });
  }

  for (const [name, mutant] of Object.entries(MUTANTS)) {
    fresh(work);
    apply(work, name, mutant);
    const shared = { expect: mutant.check, survives: mutant.survives };
    results.push({ label: `${name} / full`, ...shared, solo: false, ...run(work, null) });
    fresh(work);
    apply(work, name, mutant);
    results.push({ label: `${name} / solo`, ...shared, solo: true, ...run(work, mutant.check) });
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}

let bad = 0;
for (const r of results) {
  let verdict;
  if (r.clean) {
    verdict = r.code === 0 ? 'passed' : 'FAILED ON CLEAN SOURCE';
  } else if (r.survives) {
    // The negative direction. A check that rejects a correct alternative is
    // pattern-matching today's source, not asserting the property, and it will
    // fail the first honest refactor — so it fails the harness here instead.
    verdict = r.code === 0 ? 'survived (intended)' : 'KILLED CORRECT SOURCE';
  } else if (r.code === 0) {
    verdict = 'SURVIVED';
  } else if (r.solo && !r.output.includes(r.expect)) {
    // Solo is where ownership is proved. In a full run the replay comparison
    // runs first and is sensitive to almost any change to the physics, so it
    // legitimately catches most sim mutants before their own check gets a turn
    // — that is the suite working, not a vacuous check. Solo removes it, and
    // there the named check has to do the killing itself.
    verdict = 'KILLED BY THE WRONG CHECK';
  } else {
    verdict = 'killed';
  }
  if (verdict !== 'passed' && verdict !== 'killed' && verdict !== 'survived (intended)') bad++;
  process.stdout.write(`${r.label.padEnd(52)} exit=${String(r.code).padEnd(3)} ${verdict.padEnd(24)} ${r.output.slice(0, 120)}\n`);
}

process.stdout.write(`\n${results.length} runs, ${bad} problem${bad === 1 ? '' : 's'}\n`);
process.exit(bad === 0 ? 0 : 1);
