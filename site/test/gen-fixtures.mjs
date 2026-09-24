// Writes the PCM fixtures the bands goldens and bandscheck both read.
//
//   node site/test/gen-fixtures.mjs
//
// The committed .f32 files are the canon, not this script's output on any
// given day: they are raw mono float32, read byte-identically by the Swift
// probe and the JS check, so neither side depends on the other's (or this
// script's) trigonometry agreeing to the last ulp. Regenerating rewrites the
// canon — do it only deliberately, and refresh the goldens in the same breath.
//
// Every sample passes through Math.fround: the app's pipeline is single
// precision end to end, and a fixture with more precision than the pipeline
// would be a fixture of nothing.

import { writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const dir = join(here, 'fixtures');
mkdirSync(dir, { recursive: true });

const FFT_SIZE = 1024;

/** The app's partition, restated to pick fixture frequencies. If it drifts
 *  from `AudioTap.bandPartition`, the sine-lights-its-own-band assertion in
 *  bandscheck fails — the drift is caught, not hidden. */
function bandPartition(fftSize, bandCount) {
  const half = fftSize / 2;
  const minBin = 1.0, maxBin = half - 1;
  const edges = [];
  let lower = 1;
  for (let b = 0; b < bandCount; b++) {
    const hi = minBin * Math.pow(maxBin / minBin, (b + 1) / bandCount);
    const upper = Math.min(half, Math.max(lower + 1, Math.min(half - 1, Math.trunc(hi))));
    edges.push([lower, upper]);
    lower = upper;
  }
  return edges;
}

function write(name, samples) {
  const out = new Float32Array(samples.length);
  for (let i = 0; i < samples.length; i++) out[i] = Math.fround(samples[i]);
  writeFileSync(join(dir, `${name}.f32`), Buffer.from(out.buffer));
  console.log(`  ${name}.f32  ${out.length} samples`);
}

// Silence: the meter must report nothing, not almost nothing.
write('silence', new Array(4096).fill(0));

// Full-band noise from an integer-deterministic generator (mulberry32, the
// same recipe the site's sim seeds with) — no libm in the signal path.
{
  let a = 0x9e3779b9 >>> 0;
  const rand = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return (((t ^ (t >>> 14)) >>> 0) / 4294967296);
  };
  const s = [];
  for (let i = 0; i < 8192; i++) s.push((rand() * 2 - 1) * 0.5);
  write('noise', s);
}

// One sine per band, dead on an integer bin at the band's centre: periodic in
// the analysis window, so it must light its own band and leak nowhere the
// window's sidelobes don't reach.
const edges = bandPartition(FFT_SIZE, 12);
edges.forEach(([lo, hi], b) => {
  const bin = Math.max(lo, Math.min(hi - 1, Math.round((lo + hi - 1) / 2)));
  const s = [];
  for (let n = 0; n < 4096; n++) s.push(0.5 * Math.sin((2 * Math.PI * bin * n) / FFT_SIZE));
  write(`band-${String(b).padStart(2, '0')}`, s);
});

// A quiet tone: the dB map's midrange, where a wrong normalisation shows as a
// level shift long before it clips against either clamp.
{
  const [lo, hi] = edges[6];
  const bin = Math.round((lo + hi - 1) / 2);
  const s = [];
  for (let n = 0; n < 4096; n++) s.push(0.05 * Math.sin((2 * Math.PI * bin * n) / FFT_SIZE));
  write('level', s);
}

// A chirp across the whole spectrum: every band must rise and fall in order.
{
  const s = [];
  let phase = 0;
  for (let n = 0; n < 16384; n++) {
    const bin = 2 + ((500 - 2) * n) / 16383;
    phase += (2 * Math.PI * bin) / FFT_SIZE;
    s.push(0.5 * Math.sin(phase));
  }
  write('sweep', s);
}
