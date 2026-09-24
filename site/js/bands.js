/**
 * The analyser, ported: AudioTap's ring, window, FFT, partition and meter,
 * restated in JavaScript so the page can reduce audio it is handed to the
 * same twelve bands the app reduces the system mixdown to.
 *
 * Checked against goldens dumped from the REAL Swift pipeline over committed
 * PCM fixtures — site/test/bandscheck.mjs replays every fixture through this
 * file and compares each published frame. The constants below are the app's;
 * a change on either side fails the check, which is the point.
 */

export const BAND_COUNT = 12;
export const FFT_SIZE = 1024;

/**
 * Which FFT bins each band sums — AudioTap.bandPartition verbatim: log-spaced
 * edges, each band beginning where the last ended, so the partition is
 * non-overlapping and gapless by construction and no band is empty.
 */
export function bandPartition(fftSize, bandCount) {
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

/**
 * vDSP's normalised Hann: 0.5·sqrt(8/3)·(1 − cos(2πn/N)), periodic in N.
 * The sqrt(8/3) restores the power the plain window takes away; without it
 * every band sits 4.3 dB low and the meter's floor swallows quiet music.
 * Pinned by bandscheck against the Swift dump, not by reading Apple's docs.
 */
function hannNorm(n) {
  const w = new Float32Array(n);
  const k = 0.5 * Math.sqrt(8 / 3);
  for (let i = 0; i < n; i++) w[i] = k * (1 - Math.cos((2 * Math.PI * i) / n));
  return w;
}

/** Iterative radix-2 complex FFT, in place over re/im. Enough at 94 Hz. */
function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      let t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const ur = re[i + k], ui = im[i + k];
        const vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
        const vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k] = ur + vr; im[i + k] = ui + vi;
        re[i + k + len / 2] = ur - vr; im[i + k + len / 2] = ui - vi;
        const nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr; cr = nr;
      }
    }
  }
}

/**
 * One analyser instance: feed it PCM, read `bands`.
 *
 * Mirrors the Swift exactly: interleaved samples are meaned to mono, appended
 * to a ring, and nothing is published until a full FFT block has been seen —
 * the first chunk of a fresh instance reads as zeros, the same gating the
 * probe's first golden row records. Each fed chunk that lands after the ring
 * has filled publishes once, with the app's own attack/release meter.
 */
export class BandAnalyser {
  constructor() {
    this.window = hannNorm(FFT_SIZE);
    this.edges = bandPartition(FFT_SIZE, BAND_COUNT);
    this.ring = new Float32Array(FFT_SIZE);
    this.writeIndex = 0;
    this.framesWritten = 0;
    this.re = new Float64Array(FFT_SIZE);
    this.im = new Float64Array(FFT_SIZE);
    this.bands = new Float32Array(BAND_COUNT);
  }

  /** Feed interleaved float PCM; channels are meaned like the Swift's mixdown. */
  feed(samples, channels = 1) {
    const frames = Math.min(FFT_SIZE, Math.floor(samples.length / channels));
    if (frames <= 0) return;
    for (let i = 0; i < frames; i++) {
      let sum = 0;
      for (let c = 0; c < channels; c++) sum += samples[i * channels + c];
      this.ring[this.writeIndex] = Math.fround(sum / channels);
      this.writeIndex = (this.writeIndex + 1) % FFT_SIZE;
    }
    this.framesWritten += frames;
    if (this.framesWritten < FFT_SIZE) return;
    this.#compute();
  }

  #compute() {
    const { re, im, ring, window } = this;
    // Most recent FFT_SIZE samples in chronological order, windowed.
    const head = FFT_SIZE - this.writeIndex;
    for (let i = 0; i < head; i++) re[i] = ring[this.writeIndex + i] * window[i];
    for (let i = 0; i < this.writeIndex; i++) re[head + i] = ring[i] * window[head + i];
    im.fill(0);
    fft(re, im);

    for (let b = 0; b < BAND_COUNT; b++) {
      const [i0, i1] = this.edges[b];
      let sum = 0;
      // |X[k]|/N mirrors vDSP: zrip returns twice the textbook DFT and the
      // Swift scales by 1/(2N), which cancels to the textbook magnitude / N.
      for (let k = i0; k < i1; k++) {
        sum += Math.hypot(re[k], im[k]) / FFT_SIZE;
      }
      const mean = sum / (i1 - i0);
      const db = 20 * Math.log10(Math.max(mean, 1e-7));
      const level = Math.min(1, Math.max(0, (db + 70) / 55));
      // Attack fast, release slow — the app's meter, applied per publish.
      const prev = this.bands[b];
      this.bands[b] = Math.fround(prev + (level - prev) * (level > prev ? 0.55 : 0.16));
    }
  }

  /** Copy the current levels into caller-owned storage, like levels(into:). */
  levels(out) {
    for (let i = 0; i < BAND_COUNT; i++) out[i] = this.bands[i];
  }
}

/**
 * AudioLevels' pump, ported: the layer that decides what the page may honestly
 * show. A live analyser whose bands all sit under the silence floor decays to
 * zero rather than freezing — inventing motion after the music stops is the
 * failure the Swift file's header warns about.
 */
export const SILENCE_LEVEL = 0.02;

export class LevelPump {
  constructor() {
    this.bands = new Float32Array(BAND_COUNT);
    this.scratch = new Float32Array(BAND_COUNT);
  }

  /** One 30 Hz-ish tick: adopt live bands, or decay toward honest silence. */
  tick(analyser) {
    if (analyser) {
      analyser.levels(this.scratch);
      let audible = false;
      for (let i = 0; i < BAND_COUNT; i++) {
        if (this.scratch[i] > SILENCE_LEVEL) { audible = true; break; }
      }
      if (audible) {
        this.bands.set(this.scratch);
        return true;
      }
    }
    for (let i = 0; i < BAND_COUNT; i++) {
      const decayed = this.bands[i] * 0.82;
      this.bands[i] = decayed < 0.002 ? 0 : decayed;
    }
    return false;
  }
}
