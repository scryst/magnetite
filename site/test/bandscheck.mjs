// Checks the website's analyser port against the shipping Swift's dumps.
//
//   node site/test/bandscheck.mjs
//
// The goldens in test/golden/bands-*.txt are produced by test/bandsprobe.swift,
// which compiles the REAL AudioTap and feeds it the committed PCM fixtures in
// test/fixtures — raw mono float32 both sides read byte-identically, so
// nothing here depends on two languages' trigonometry agreeing. Regenerate
// with test/refresh-golden.sh when the app's analyser moves; a diff there is
// the app changing under the site, which is exactly the signal worth having.

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { BandAnalyser, LevelPump, bandPartition, BAND_COUNT, FFT_SIZE, SILENCE_LEVEL }
  from '../js/bands.js';

const here = dirname(fileURLToPath(import.meta.url));
let failures = 0;

function require_(condition, message) {
  if (!condition) { failures++; throw new Error(message); }
}

/**
 * The two sides run the same arithmetic at different precisions: the Swift
 * FFT is single-precision vDSP, the port's is double. Measured across every
 * fixture the worst disagreement is 1.5e-7 of full scale, through the dB map
 * and the meter; a real port error — a wrong window constant, a dropped
 * scale, a shifted bin — moves bands by whole percent. 1e-4 keeps almost
 * three orders of margin against the noise and three against the errors.
 */
const TOLERANCE = 1e-4;

const CHUNK = 512;

function replay(name) {
  const bytes = readFileSync(join(here, 'fixtures', `${name}.f32`));
  const pcm = new Float32Array(
    bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength));
  const rows = readFileSync(join(here, 'golden', `bands-${name}.txt`), 'utf8')
    .split('\n').filter((l) => l.trim().length > 0);
  const analyser = new BandAnalyser();
  const out = new Float32Array(BAND_COUNT);
  let worst = 0;
  for (let row = 0; row * CHUNK < pcm.length; row++) {
    analyser.feed(pcm.subarray(row * CHUNK, (row + 1) * CHUNK));
    analyser.levels(out);
    const g = rows[row];
    require_(g !== undefined, `${name}: the port produced more frames than the Swift did`);
    const cols = g.split(' ');
    require_(Number(cols[0]) === row, `${name}: golden row ${cols[0]} where ${row} expected`);
    for (let b = 0; b < BAND_COUNT; b++) {
      const want = Number(cols[b + 1]);
      const delta = Math.abs(out[b] - want);
      worst = Math.max(worst, delta);
      require_(delta <= TOLERANCE,
        `${name} chunk ${row} band ${b}: port says ${out[b]}, the Swift says ${want} `
        + `(off by ${delta.toExponential(3)})`);
    }
  }
  require_(rows.length === Math.ceil(pcm.length / CHUNK),
    `${name}: the Swift dumped ${rows.length} rows for ${Math.ceil(pcm.length / CHUNK)} chunks`);
  return worst;
}

const CHECKS = {
  /** Every fixture, every chunk, every band, against the Swift's own dump. */
  thePortAgreesWithTheTap() {
    const fixtures = readdirSync(join(here, 'fixtures'))
      .filter((f) => f.endsWith('.f32')).map((f) => f.replace(/\.f32$/, ''));
    require_(fixtures.length >= 15,
      `only ${fixtures.length} fixtures on disk — the committed bench has been thinned`);
    let worst = 0;
    for (const name of fixtures) worst = Math.max(worst, replay(name));
    if (process.env.BANDS_STATS) console.log(`  worst delta ${worst.toExponential(3)}`);
  },

  /**
   * A sine at a band's own centre lights that band above every other. This is
   * what the fixtures are FOR: the golden agreement above would hold even if
   * the partition sent every bin to band 0 on both sides, and the twelve-of-
   * twelve claim died exactly that way once — two bands sharing one bin, in
   * 240 of 240 frames of the app's own capture.
   */
  eachBandAnswersItsOwnSine() {
    for (let b = 0; b < BAND_COUNT; b++) {
      const rows = readFileSync(
        join(here, 'golden', `bands-band-${String(b).padStart(2, '0')}.txt`), 'utf8')
        .split('\n').filter((l) => l.trim().length > 0);
      const last = rows[rows.length - 1].split(' ').slice(1).map(Number);
      const top = last.indexOf(Math.max(...last));
      require_(top === b,
        `the band-${b} sine lights band ${top} hardest — the partition or the fixture drifted`);
    }
  },

  /** The partition itself: monotone, gapless, non-empty, in bounds. */
  thePartitionCoversWithoutOverlap() {
    const edges = bandPartition(FFT_SIZE, BAND_COUNT);
    require_(edges.length === BAND_COUNT, `${edges.length} bands from a ${BAND_COUNT}-band ask`);
    let lower = 1;
    for (const [i0, i1] of edges) {
      require_(i0 === lower, `band starts at bin ${i0} where ${lower} ends — gap or overlap`);
      require_(i1 > i0, `empty band [${i0}, ${i1})`);
      lower = i1;
    }
    require_(lower <= FFT_SIZE / 2, `the last band runs past the spectrum to bin ${lower}`);
  },

  /** The pump: honest silence decays to zero and never invents motion. */
  thePumpDecaysToHonestSilence() {
    const pump = new LevelPump();
    pump.bands.fill(0.5);
    const still = { levels(out) { out.fill(SILENCE_LEVEL); } };
    let live = false;
    for (let i = 0; i < 400; i++) live = pump.tick(still);
    require_(!live, 'a pump fed silence still reports live audio');
    require_([...pump.bands].every((b) => b === 0),
      `400 silent ticks left the bands at [${pump.bands}] — the floor never landed`);
    const loud = { levels(out) { out.fill(0.8); } };
    require_(pump.tick(loud) && pump.bands[0] === Math.fround(0.8),
      'a pump fed loud bands did not adopt them');
  },
};

let passed = 0;
const only = process.argv.find((a) => a.startsWith('--only='))?.slice(7);
if (only && !CHECKS[only]) {
  console.error(`bandscheck: no such check "${only}"`);
  process.exit(2);
}
for (const [name, check] of only ? [[only, CHECKS[only]]] : Object.entries(CHECKS)) {
  try {
    check();
    passed++;
  } catch (error) {
    console.error(`bandscheck: ${name} FAILED`);
    console.error(`  ${error.message}`);
  }
}

if (failures > 0) process.exit(1);
console.log(`bandscheck: all checks passed (${passed})`);
