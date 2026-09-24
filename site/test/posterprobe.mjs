/**
 * Is site/media/demo-poster.webp actually the first frame of site/media/demo.mp4?
 *
 *   node site/test/posterprobe.mjs
 *
 * The poster is what the page shows until the video decodes, so if it is not
 * frame 0 the demo JUMPS the moment it starts playing — a cut nobody put there,
 * on the one element of the page whose whole job is to look continuous.
 *
 * `theDemoIsTheAppOnFilm` in portcheck.mjs already holds the two files against
 * each other, but only through their headers: the WebP's VP8 frame header
 * against the mp4's `tkhd`, so they agree about SIZE. Not one byte of either
 * image is decoded
 * there, and deliberately — portcheck is a gate that runs on every commit and
 * must not need a decoder. So a poster cut from frame 300 passes it, which is
 * measured rather than supposed: swapping in frame 300 at the same dimensions
 * left all thirty-nine checks green.
 *
 * That is why this is a probe rather than a check. It needs ffmpeg, and the
 * rule this repo already follows for cardprobe applies — a dependency that can
 * be missing belongs in a tool you run on purpose, never in the gate, because a
 * gate that goes amber on a plane is a gate nobody reads by the third time.
 *
 * WHAT IT ASSERTS, and why it is a comparison rather than a threshold. The
 * poster is compared to SEVERAL candidate frames and the nearest one must be
 * frame 0. Both sides come from different places — the poster out of the PNG,
 * each rival out of a different offset in the video — so this cannot be
 * satisfied by reading one artefact twice, which is this repo's characteristic
 * way of passing against broken code. A second, deliberately loose bound
 * catches a poster cut from some frame that is not a candidate at all; it must
 * NOT be tightened toward the observed separation, because a threshold tuned
 * until it passes is prose with a number in it. The argmin does the
 * discriminating work.
 *
 * A missing ffmpeg exits 2 and says SKIPPED. It does not pass. A probe that
 * goes green because its tool is absent is worse than the gap it replaces.
 *
 * WHY FRAME 0 IS NOT AN EXACT MATCH. The shipped poster scores 0.6142 against a
 * fresh decode of frame 0, not 0.0000 — while a poster recut here with ffmpeg
 * scores exactly 0.0000 against the frame it was cut from. So the committed
 * file did not come out of this pipeline; some other decode or colour handling
 * produced it. That is the whole reason the second bound is loose and the
 * argmin does the work: an exact-equality assertion here would be asserting
 * which TOOL cut the poster, which is not the claim.
 *
 * WHAT NO MUTANT COVERS. mutate.mjs replaces literal text in a file it reads as
 * utf8, so it cannot swap a PNG, and there is no mutant for any of this. The
 * substitute is a control that was run rather than described: the poster was
 * recut from frames 300, 30, 917 and — the hard case — 1, and this probe caught
 * every one while `node site/test/portcheck.mjs` stayed green at thirty-nine
 * through all four. Frame 1 is the case worth naming: the two are 0.2899 apart,
 * which is under half the poster's own re-encode distance from frame 0, and the
 * argmin is the only thing that separates them.
 */
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const film = join(here, '..', 'media', 'demo.mp4');
const still = join(here, '..', 'media', 'demo-poster.webp');

// Loose on purpose. The separation measured today is far below this; the point
// is to catch a poster cut from a frame that is not in the candidate set, not
// to encode how close frame 0 happens to be.
const LOOSE = 2.0;

const have = (tool) => {
  try { execFileSync('/bin/sh', ['-c', `command -v ${tool}`], { stdio: 'ignore' }); return true; }
  catch { return false; }
};
if (!have('ffmpeg') || !have('ffprobe')) {
  process.stderr.write('posterprobe: SKIPPED — ffmpeg and ffprobe are not on PATH. This tool '
    + 'decodes video, so it cannot answer without them. It is not reporting a pass.\n');
  process.exit(2);
}

for (const [what, path] of [['demo.mp4', film], ['demo-poster.webp', still]]) {
  if (!existsSync(path)) {
    process.stderr.write(`posterprobe: ${what} is missing at ${path}\n`);
    process.exit(1);
  }
}

/** Raw rgb24 pixels, whatever the container. One decoder for both files. */
const pixels = (path, args = []) => execFileSync('ffmpeg',
  ['-v', 'error', ...args, '-i', path, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
  { maxBuffer: 1 << 28 });

const probe = (stream) => JSON.parse(execFileSync('ffprobe',
  ['-v', 'error', '-select_streams', 'v:0', '-show_entries', stream, '-of', 'json', film],
  { encoding: 'utf8' }));

const info = probe('stream=width,height,nb_frames,avg_frame_rate').streams[0];
const [W, H] = [Number(info.width), Number(info.height)];
const counted = Number(info.nb_frames);
const frames = Number.isFinite(counted) && counted > 0
  ? counted
  : Number(execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0',
    '-count_frames', '-show_entries', 'stream=nb_read_frames', '-of', 'csv=p=0', film],
  { encoding: 'utf8' }).trim());

const poster = pixels(still);
if (poster.length !== W * H * 3) {
  process.stderr.write(`posterprobe: the poster decodes to ${poster.length} bytes where the film's `
    + `${W}×${H} frames are ${W * H * 3} — the two are not the same picture size, which `
    + '`theDemoIsTheAppOnFilm` in portcheck.mjs is the check for\n');
  process.exit(1);
}

/** Mean absolute difference per channel, 0..255. */
const mad = (a, b) => {
  let sum = 0;
  for (let i = 0; i < a.length; i++) sum += Math.abs(a[i] - b[i]);
  return sum / a.length;
};

// Frame 0 and a spread of rivals: the neighbour it would be confused with, one
// a moment later, one deep in the film, and the last frame — which is the one a
// poster grabbed from a paused player would be.
const candidates = [...new Set([0, 1, 5, 30, 300, frames - 1])]
  .filter((n) => Number.isFinite(n) && n >= 0 && n < frames)
  .sort((a, b) => a - b);

const scores = candidates.map((n) => {
  // `select` after the input, so the decoder walks to the frame rather than
  // seeking near it: an inaccurate seek would compare the poster to whichever
  // frame the demuxer landed on and call the answer noise. No `-vsync`: it was
  // removed from ffmpeg, and `-vframes 1` after the filter already writes
  // exactly the one frame.
  const raw = execFileSync('ffmpeg',
    ['-v', 'error', '-i', film, '-vf', `select=eq(n\\,${n})`, '-vframes', '1',
      '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'],
    { maxBuffer: 1 << 28 });
  if (raw.length !== poster.length) {
    process.stderr.write(`posterprobe: frame ${n} decoded to ${raw.length} bytes where the `
      + `poster is ${poster.length} — this probe is comparing two different picture sizes and `
      + 'any answer it gave would be arithmetic on mismatched buffers\n');
    process.exit(1);
  }
  return { n, mad: mad(poster, raw) };
});

for (const s of scores) {
  process.stdout.write(`posterprobe: frame ${String(s.n).padStart(4)}  mad ${s.mad.toFixed(4)}\n`);
}

const best = scores.reduce((a, b) => (b.mad < a.mad ? b : a));
const zero = scores.find((s) => s.n === 0);

if (best.n !== 0) {
  process.stderr.write(`posterprobe: the poster is closest to frame ${best.n} (mad `
    + `${best.mad.toFixed(4)}), not to frame 0 (mad ${zero.mad.toFixed(4)}). The page shows this `
    + 'picture until the video decodes, so the demo jumps the moment it starts playing. '
    + 'Recut it, then encode it: ffmpeg -y -i site/media/demo.mp4 -vframes 1 /tmp/demo-poster.png '
    + '&& cwebp -quiet -m 6 -q 95 /tmp/demo-poster.png -o site/media/demo-poster.webp\n');
  process.exit(1);
}

if (zero.mad >= LOOSE) {
  process.stderr.write(`posterprobe: the poster is nearest frame 0 of the candidates, but ${
    zero.mad.toFixed(4)} away from it — further than any re-encode of the same picture should be. `
    + 'It was most likely cut from a frame that is not among the ones tested here\n');
  process.exit(1);
}

const runnerUp = scores.filter((s) => s.n !== 0).reduce((a, b) => (b.mad < a.mad ? b : a));
process.stdout.write(`posterprobe: the poster is frame 0 — mad ${zero.mad.toFixed(4)} against `
  + `${runnerUp.mad.toFixed(4)} for the nearest rival (frame ${runnerUp.n}), over `
  + `${candidates.length} candidates of ${frames} frames\n`);
