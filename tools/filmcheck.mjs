#!/usr/bin/env node
// filmcheck: does a site film glitch on its own, whatever the page does with it?
//
// It decodes every frame of an mp4 (ffmpeg, presentation order, nothing dropped or
// repeated) and looks for what a viewer sees as the picture "spazzing":
//
//   jump     the picture, or a band of it (top, middle, bottom), moves sideways for one
//            frame and comes back; the whole picture can also move up and down. This is
//            what a layer that resizes mid-recording does: Magnetite 0.1.13's film has the
//            liquid at the top jumping 32 or 64 px about thirty times.
//   flash    the whole frame is an A, B, A: one frame unlike both of its neighbors,
//            which are alike (a black frame, a stale frame delivered twice).
//   local    the same A, B, A in part of the frame. Fast lyric scrolls and springs do
//            this on purpose, so these are listed, never failed on.
//   blend    a frame that is a mix of its neighbors over much of the picture, i.e. two
//            UI states on top of each other. A run is a fade; a single one is suspect.
//   stutter  timestamps: variable frame rate, long gaps, and how long each frame is held
//            on a 60 Hz and a 120 Hz display.
//   seam     the loop: how far the last frame is from the first.
//   decode   anything ffmpeg reports while decoding (a broken keyframe shows here).
//
//   node tools/filmcheck.mjs site/media/demo.mp4 [--out=DIR] [--top=12] [--sheet=1]
//        [--ffmpeg=PATH] [--ffprobe=PATH] [--shift=96]
//
// Writes DIR/filmcheck.json, DIR/frames.csv and, with --sheet=1, DIR/sheet.png: the
// worst moments as rows of five frames with their timestamps. Exit 1 if there is a
// jump, a whole-frame flash, a decode error or a frame count mismatch; 2 on a usage
// or tool error. The seam, stutter, blends and local flashes are reported only.

import { spawn, spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { encodePNG, newImage, blit, drawText, fillRect } from './lib/png.mjs';

const argv = process.argv.slice(2);
const opt = Object.fromEntries(argv.filter((a) => a.startsWith('--')).map((a) => { const [k, v = '1'] = a.slice(2).split('='); return [k, v]; }));
const input = argv.find((a) => !a.startsWith('--'));
if (!input) { console.error('usage: filmcheck.mjs VIDEO [--out=DIR] [--top=12] [--sheet=1]'); process.exit(2); }
const FFMPEG = opt.ffmpeg ?? 'ffmpeg';
const FFPROBE = opt.ffprobe ?? 'ffprobe';
const TOP = Number(opt.top ?? 12);
const MAXS = Number(opt.shift ?? 96);          // largest whole-picture shift looked for, px
const BLOCK = 16;
const out = resolve(opt.out ?? '.');
mkdirSync(out, { recursive: true });

const run = (cmd, args) => {
  const r = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 1 << 28 });
  if (r.error) { console.error(`cannot run ${cmd}: ${r.error.message}`); process.exit(2); }
  return r;
};

// ---- the container: stream facts and every frame's timestamp ---------------------------
const probe = (args) => JSON.parse(run(FFPROBE, ['-v', 'error', '-select_streams', 'v:0', ...args, '-of', 'json', input]).stdout || '{}');
const stream = probe(['-show_entries', 'stream=codec_name,profile,width,height,pix_fmt,avg_frame_rate,r_frame_rate,time_base,nb_frames,duration,has_b_frames,color_range,color_space']).streams?.[0];
if (!stream) { console.error(`${input}: no video stream`); process.exit(2); }
const W = stream.width, H = stream.height;
const rows = probe(['-show_frames', '-show_entries', 'frame=pts_time,best_effort_timestamp_time,pkt_dts_time,pict_type,flags,key_frame']).frames ?? [];
const N = rows.length;
const pts = rows.map((f) => Number(f.pts_time ?? f.best_effort_timestamp_time));
const dts = rows.map((f) => Number(f.pkt_dts_time ?? NaN));
const isKey = rows.map((f) => f.key_frame === 1 || f.key_frame === '1' || String(f.flags ?? '').includes('K'));

// ---- the pixels -----------------------------------------------------------------------
const bw = Math.floor(W / BLOCK), bh = Math.floor(H / BLOCK), nb = bw * bh, per = BLOCK * BLOCK;
const blockOf = new Uint16Array(W * H).fill(65535);
for (let y = 0; y < bh * BLOCK; y++) for (let x = 0; x < bw * BLOCK; x++) blockOf[y * W + x] = ((y / BLOCK) | 0) * bw + ((x / BLOCK) | 0);

function blockDiff(a, b, into) {                                  // mean |a-b| per block; returns the frame mean
  into.fill(0);
  let total = 0;
  for (let i = 0; i < a.length; i++) {
    const d = a[i] - b[i], m = d < 0 ? -d : d;
    total += m;
    const k = blockOf[i];
    if (k !== 65535) into[k] += m;
  }
  for (let k = 0; k < nb; k++) into[k] /= per;
  return total / a.length;
}

// Blocks where F_t is a mix alpha*F_(t-1) + (1-alpha)*F_(t+1) while the neighbors differ.
function blendBlocks(p, c, n) {
  const saa = new Float64Array(nb), sab = new Float64Array(nb), sbb = new Float64Array(nb);
  for (let i = 0; i < p.length; i++) {
    const k = blockOf[i];
    if (k === 65535) continue;
    const a = p[i] - n[i], b = c[i] - n[i];
    saa[k] += a * a; sab[k] += a * b; sbb[k] += b * b;
  }
  let hits = 0, alphaSum = 0;
  for (let k = 0; k < nb; k++) {
    if (saa[k] < per * 14 * 14 || sbb[k] < per * 6 * 6) continue;
    const alpha = sab[k] / saa[k];
    if (alpha > 0.12 && alpha < 0.88 && (sab[k] * sab[k]) / (saa[k] * sbb[k]) > 0.93) { hits++; alphaSum += alpha; }
  }
  return { hits, alpha: hits ? alphaSum / hits : 0 };
}

// One-frame shifts: column (and row) brightness profiles, high-passed, then the shift that
// best lines two frames up. Run on the whole frame and on a top, middle and bottom band, because
// a layer that jumps (the liquid at the top) does not always take the whole picture with it.
// Confirmed on the pixels before a frame is called a jump.
const BANDS = [['top', 0, Math.round(H * 0.25)], ['middle', Math.round(H * 0.25), Math.round(H * 0.75)], ['bottom', Math.round(H * 0.75), H]];
function profile(f) {
  const col = new Float32Array(W), row = new Float32Array(H), band = BANDS.map(() => new Float32Array(W));
  for (let y = 0, i = 0; y < H; y++) {
    const bc = band[y < BANDS[0][2] ? 0 : y < BANDS[1][2] ? 1 : 2];
    for (let x = 0; x < W; x++, i++) { col[x] += f[i]; bc[x] += f[i]; row[y] += f[i]; }
  }
  for (let x = 0; x < W; x++) col[x] /= H;
  for (let y = 0; y < H; y++) row[y] /= W;
  band.forEach((b, k) => { for (let x = 0; x < W; x++) b[x] /= BANDS[k][2] - BANDS[k][1]; });
  return [hp(col), hp(row), ...band.map((b) => hp(b))];
}
// The darkest mass in each band (the liquid at the top is pure black): where its center sits.
const DARK = 10;
function darkMass(f) {
  const out = BANDS.map(() => [0, 0]);
  for (let y = 0, i = 0; y < H; y++) {
    const o = out[y < BANDS[0][2] ? 0 : y < BANDS[1][2] ? 1 : 2];
    for (let x = 0; x < W; x++, i++) if (f[i] <= DARK) { o[0]++; o[1] += x; }
  }
  return out.map(([n, sx]) => ({ n, cx: n ? sx / n : 0 }));
}
function hp(p, k = 20) {
  const n = p.length, cs = new Float64Array(n + 1), o = new Float32Array(n);
  for (let i = 0; i < n; i++) cs[i + 1] = cs[i] + p[i];
  for (let i = 0; i < n; i++) { const a = Math.max(0, i - k), b = Math.min(n, i + k + 1); o[i] = p[i] - (cs[b] - cs[a]) / (b - a); }
  return o;
}
function bestShift(a, b) {                                       // content of a appears in b at x + s
  const n = a.length, lo = Math.min(MAXS, n >> 3), hi = n - lo;
  let best = Infinity, bs = 0, c0 = 0;
  for (let s = -lo; s <= lo; s++) {
    let c = 0;
    for (let x = lo; x < hi; x++) c += Math.abs(a[x] - b[x + s]);
    c /= hi - lo;
    if (s === 0) c0 = c;
    if (c < best) { best = c; bs = s; }
  }
  return { s: bs, cost: best, cost0: c0 };
}
function sad2d(a, b, dx, dy, x0, x1, y0, y1) {                   // mean |a(x,y) - b(x+dx, y+dy)| over x0..x1, y0..y1
  let t = 0, c = 0;
  for (let y = y0; y < y1; y += 2) for (let x = x0; x < x1; x += 2) { t += Math.abs(a[y * W + x] - b[(y + dy) * W + x + dx]); c++; }
  return t / c;
}

const M = Array.from({ length: N }, () => ({ mad: 0, wholeFlash: 0, local: 0, localScore: 0, localBox: null, blend: 0, alpha: 0, jump: null }));
const dark = [];
const prof = [[], [], [], [], []];               // full-frame column, full-frame row, then the three band column profiles
const ring = [null, null, null];
const bdUp = new Float32Array(nb), bdDown = new Float32Array(nb), bdNet = new Float32Array(nb);
let first = null, last = null, decoded = 0;
const decodeErrors = [];

function analyze(t) {                                            // ring = [F(t-1), F(t), F(t+1)]
  const [p, c, n] = ring;
  const m = M[t];
  m.mad = blockDiff(c, p, bdUp);
  const down = blockDiff(c, n, bdDown);
  const net = blockDiff(p, n, bdNet);
  const lowest = Math.min(m.mad, down);
  if (lowest >= 2.5 && net <= 0.35 * lowest) m.wholeFlash = lowest - net;
  let hits = 0, score = 0, bx0 = 1e9, by0 = 1e9, bx1 = -1, by1 = -1;
  for (let k = 0; k < nb; k++) {
    const lo = Math.min(bdUp[k], bdDown[k]);
    if (lo >= 8 && bdNet[k] <= 0.35 * lo) {
      hits++; score += lo - bdNet[k];
      const x = (k % bw) * BLOCK, y = ((k / bw) | 0) * BLOCK;
      bx0 = Math.min(bx0, x); by0 = Math.min(by0, y); bx1 = Math.max(bx1, x + BLOCK); by1 = Math.max(by1, y + BLOCK);
    }
  }
  m.local = hits; m.localScore = score; m.localBox = hits ? [bx0, by0, bx1, by1] : null;
  const bl = blendBlocks(p, c, n);
  m.blend = bl.hits; m.alpha = bl.alpha;
  // a one-frame jump: F_t is displaced from both neighbors by the same amount, and they agree with each other
  const tests = [['frame', 'x', prof[0], 0, H], ['frame', 'y', prof[1], 0, H], ...BANDS.map(([name, y0, y1], k) => [name, 'x', prof[2 + k], y0, y1])];
  for (const [region, axis, pr, y0, y1] of tests) {
    const s1 = bestShift(pr[t - 1], pr[t]), s2 = bestShift(pr[t + 1], pr[t]), edge = Math.min(MAXS, pr[t].length >> 3) - 1;
    if (Math.min(Math.abs(s1.s), Math.abs(s2.s)) < 12 || Math.max(Math.abs(s1.s), Math.abs(s2.s)) >= edge) continue;
    if (s1.s * s2.s < 0 || Math.abs(s1.s - s2.s) > Math.max(2, 0.4 * Math.min(Math.abs(s1.s), Math.abs(s2.s)))) continue;
    if (s1.cost > 0.7 * s1.cost0 || s2.cost > 0.7 * s2.cost0) continue;
    const dx = axis === 'x' ? s1.s : 0, dy = axis === 'y' ? s1.s : 0, dxN = axis === 'x' ? s2.s : 0, dyN = axis === 'y' ? s2.s : 0;
    const mx = Math.max(32, Math.abs(dx) + 2, Math.abs(dxN) + 2), my = axis === 'y' ? Math.max(32, Math.abs(dy) + 2, Math.abs(dyN) + 2) : 0;
    const [a0, a1] = [mx, W - mx], [b0, b1] = [y0 + my, y1 - my];
    const still = sad2d(p, c, 0, 0, a0, a1, b0, b1), moved = sad2d(p, c, dx, dy, a0, a1, b0, b1);
    const stillN = sad2d(n, c, 0, 0, a0, a1, b0, b1), movedN = sad2d(n, c, dxN, dyN, a0, a1, b0, b1), agree = sad2d(p, n, 0, 0, a0, a1, b0, b1);
    if (still >= 1.5 && stillN >= 1.5 && moved <= 0.75 * still && movedN <= 0.75 * stillN && agree <= 0.6 * still) { m.jump = { region, axis, px: s1.s, still: +still.toFixed(2), moved: +moved.toFixed(2) }; break; }
  }
  // the dark mass of a band goes out and straight back (a layer that jumps for one frame)
  if (!m.jump) for (const [k, [name, y0, y1]] of BANDS.entries()) {
    const a = dark[t - 1][k], b = dark[t][k], d = dark[t + 1][k], need = 0.02 * W * (y1 - y0);
    if (a.n < need || b.n < need || d.n < need) continue;
    const d1 = b.cx - a.cx, d2 = d.cx - b.cx;
    if (Math.abs(d1) >= 14 && Math.abs(d2) >= 14 && d1 * d2 < 0 && Math.abs(d1 + d2) <= 0.5 * Math.min(Math.abs(d1), Math.abs(d2))) { m.jump = { region: name, axis: 'x', px: Math.round(d1), how: 'dark mass' }; break; }
  }
}

await new Promise((done) => {
  const dec = spawn(FFMPEG, ['-v', 'error', '-nostdin', '-i', input, '-map', '0:v:0', '-an', '-fps_mode', 'passthrough', '-f', 'rawvideo', '-pix_fmt', 'gray', '-'], { stdio: ['ignore', 'pipe', 'pipe'] });
  dec.on('error', (e) => { console.error(`cannot run ${FFMPEG}: ${e.message}`); process.exit(2); });
  dec.stderr.on('data', (d) => decodeErrors.push(...String(d).split('\n').filter(Boolean)));
  const size = W * H;
  let acc = Buffer.alloc(0);
  const feed = (frame) => {
    if (decoded === 0) first = frame;
    last = frame;
    profile(frame).forEach((v, k) => prof[k].push(v));
    dark.push(darkMass(frame));
    ring[0] = ring[1]; ring[1] = ring[2]; ring[2] = frame;
    decoded++;
    if (decoded >= 3 && decoded - 2 < N) analyze(decoded - 2);
  };
  dec.stdout.on('data', (chunk) => {
    acc = acc.length ? Buffer.concat([acc, chunk]) : chunk;
    while (acc.length >= size) { feed(new Uint8Array(acc.subarray(0, size))); acc = acc.subarray(size); }
  });
  dec.on('close', () => {
    if (decoded >= 2 && decoded <= N) M[decoded - 1].mad = blockDiff(ring[2], ring[1], bdUp);
    done();
  });
});

// ---- timestamps -------------------------------------------------------------------------
const gaps = []; for (let t = 1; t < N; t++) gaps.push(pts[t] - pts[t - 1]);
const sortedGaps = [...gaps].sort((a, b) => a - b), median = sortedGaps[sortedGaps.length >> 1];
const gapMs = {}; for (const g of gaps) { const ms = Math.round(g * 1000); gapMs[ms] = (gapMs[ms] ?? 0) + 1; }
const longGaps = gaps.map((g, i) => ({ frame: i + 1, at: pts[i + 1], gap: g })).filter((g) => g.gap > Math.max(3 * median, 0.05)).sort((a, b) => b.gap - a.gap);
const keyTimes = pts.filter((_, i) => isKey[i]);
const gop = keyTimes.slice(1).map((v, i) => v - keyTimes[i]);
function hold(hz) {                                              // how many vsyncs each frame is on screen
  const held = new Int32Array(N); let i = 0;
  for (let k = 0; k / hz <= pts[N - 1]; k++) { while (i + 1 < N && pts[i + 1] <= k / hz + 1e-9) i++; held[i]++; }
  const h = {}; for (const v of held) h[v] = (h[v] ?? 0) + 1;
  return h;
}

// ---- findings ---------------------------------------------------------------------------
const jumps = M.map((m, t) => ({ t, ...m })).filter((m) => m.jump);
const wholeFlashes = M.map((m, t) => ({ t, ...m })).filter((m) => m.wholeFlash && !m.jump);
const locals = M.map((m, t) => ({ t, ...m })).filter((m) => m.local);
const wholeBlend = M.map((m) => m.blend >= 0.25 * nb);
const blendRuns = [];
for (let t = 0; t < N; t++) if (wholeBlend[t]) { let e = t; while (e + 1 < N && wholeBlend[e + 1]) e++; blendRuns.push({ from: t, to: e, length: e - t + 1, at: +pts[t].toFixed(3), peak_blocks: Math.max(...M.slice(t, e + 1).map((m) => m.blend)) }); t = e; }
const mads = M.slice(1).map((m) => m.mad).sort((a, b) => a - b);
const q = (p) => mads[Math.min(mads.length - 1, Math.floor(p * mads.length))];
const seam = first && last ? (() => { let s = 0; for (let i = 0; i < first.length; i++) s += Math.abs(first[i] - last[i]); return s / first.length; })() : null;

const report = {
  file: resolve(input),
  stream: { codec: stream.codec_name, profile: stream.profile, size: `${W}x${H}`, pix_fmt: stream.pix_fmt, avg_fps: stream.avg_frame_rate, r_frame_rate: stream.r_frame_rate, nb_frames: Number(stream.nb_frames), duration_s: Number(stream.duration) },
  frames: { probed: N, decoded },
  timing: {
    median_gap_ms: +(median * 1000).toFixed(2), vfr: Object.keys(gapMs).length > 3, gap_histogram_ms: gapMs,
    non_increasing_pts: pts.filter((v, i) => i && v <= pts[i - 1]).length, dts_backwards: dts.filter((v, i) => i && v < dts[i - 1]).length,
    long_gaps: longGaps.slice(0, 8).map((g) => ({ frame: g.frame, at: +g.at.toFixed(3), gap_ms: +(g.gap * 1000).toFixed(1) })),
    keyframes: keyTimes.length, first_is_key: isKey[0], gop_s: gop.length ? { min: +Math.min(...gop).toFixed(2), max: +Math.max(...gop).toFixed(2) } : null,
    frames_held_vsyncs: { '60Hz': hold(60), '120Hz': hold(120) },
  },
  motion: { mad_p50: +q(0.5).toFixed(2), mad_p95: +q(0.95).toFixed(2), mad_p99: +q(0.99).toFixed(2), mad_max: +mads[mads.length - 1].toFixed(2) },
  seam: seam === null ? null : { last_to_first_mad: +seam.toFixed(2), times_p99: +(seam / Math.max(q(0.99), 1e-6)).toFixed(2) },
  jumps: jumps.map((j) => ({ frame: j.t, at: +pts[j.t].toFixed(3), ...j.jump })),
  whole_frame_flashes: wholeFlashes.map((f) => ({ frame: f.t, at: +pts[f.t].toFixed(3), strength: +f.wholeFlash.toFixed(2) })),
  whole_frame_blend_runs: blendRuns,
  local_flashes: { frames: locals.length, strongest: [...locals].sort((a, b) => b.localScore - a.localScore).slice(0, 10).map((f) => ({ frame: f.t, at: +pts[f.t].toFixed(3), blocks: f.local, box: f.localBox })), all: locals.map((f) => ({ frame: f.t, at: +pts[f.t].toFixed(3), blocks: f.local, score: +f.localScore.toFixed(1), box: f.localBox })) },
  decode_errors: decodeErrors.slice(0, 20),
};

// ---- the worst moments, ranked ------------------------------------------------------------
const cand = [];
for (const j of jumps) cand.push({ kind: 'jump', frame: j.t, rank: 1e5 + Math.abs(j.jump.px), note: `${j.jump.region === 'frame' ? 'whole picture' : `${j.jump.region} band`} ${j.jump.px > 0 ? '+' : ''}${j.jump.px}px ${j.jump.axis === 'x' ? 'sideways' : 'vertical'} for 1 frame` });
for (const f of wholeFlashes) cand.push({ kind: 'flash', frame: f.t, rank: 9e4 + f.wholeFlash, note: `whole frame unlike both neighbors (${f.wholeFlash.toFixed(1)})` });
if (seam !== null) cand.push({ kind: 'seam', frame: N - 1, rank: 8e4 + seam, note: `loop seam, last to first ${seam.toFixed(1)} mean change` });
for (const g of longGaps.slice(0, 3)) cand.push({ kind: 'gap', frame: g.frame, rank: 7e4 + g.gap, note: `${(g.gap * 1000).toFixed(0)} ms between frames` });
for (const r of blendRuns.filter((r) => r.length === 1)) cand.push({ kind: 'blend', frame: r.from, rank: 6e4 + r.peak_blocks, note: 'one frame mixing its neighbors' });
for (const [t, m] of M.entries()) if (t > 0 && t < N - 1) cand.push({ kind: 'change', frame: t, rank: 1e4 + m.mad * 10, note: `${m.mad.toFixed(1)} mean change from the frame before` });
for (const f of locals) cand.push({ kind: 'local', frame: f.t, rank: f.localScore / 10, note: `${f.local} blocks flash and return` });
cand.sort((a, b) => b.rank - a.rank);
const chosen = [];
for (const m of cand) {
  if (chosen.length >= TOP) break;
  if (chosen.some((c) => c.kind !== 'seam' && m.kind !== 'seam' && Math.abs(c.frame - m.frame) < 8)) continue;
  chosen.push({ ...m, at: +pts[m.frame].toFixed(3) });
}
report.worst_moments = chosen.map(({ rank, ...m }) => m);

writeFileSync(join(out, 'filmcheck.json'), JSON.stringify(report, null, 2));
writeFileSync(join(out, 'frames.csv'), ['frame,pts,gap_ms,mad,whole_flash,local_blocks,blend_blocks,jump_px'].concat(
  M.map((m, t) => [t, pts[t].toFixed(4), t ? ((pts[t] - pts[t - 1]) * 1000).toFixed(1) : '', m.mad.toFixed(3), m.wholeFlash.toFixed(2), m.local, m.blend, m.jump ? m.jump.px : ''].join(','))).join('\n') + '\n');

// ---- the sheet: five frames around each moment, timestamps burned in --------------------------
if (opt.sheet === '1' && chosen.length) {
  const TW = 320, TH = Math.round((H * TW) / W), PAD = 3, HEAD = 24, CELLS = 5;
  const around = (m) => (m.kind === 'seam' ? [N - 3, N - 2, N - 1, 0, 1] : [-2, -1, 0, 1, 2].map((d) => m.frame + d)).map((v) => Math.min(N - 1, Math.max(0, v)));
  const need = [...new Set(chosen.flatMap(around))].sort((a, b) => a - b);
  const r = spawnSync(FFMPEG, ['-v', 'error', '-nostdin', '-i', input, '-vf', `select='${need.map((v) => `eq(n\\,${v})`).join('+')}',scale=${TW}:${TH}:flags=area`,
    '-fps_mode', 'passthrough', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], { maxBuffer: 1 << 29 });
  const tile = TW * TH * 3;
  if (r.status !== 0 || r.stdout.length < need.length * tile) console.error(`sheet: ffmpeg gave ${r.stdout?.length ?? 0} bytes for ${need.length} frames`);
  else {
    const img = newImage(CELLS * (TW + PAD) + PAD, chosen.length * (HEAD + TH + PAD) + PAD, [24, 24, 24]);
    chosen.forEach((m, i) => {
      const y0 = PAD + i * (HEAD + TH + PAD);
      drawText(img, PAD + 2, y0 + 4, `#${i + 1} ${m.kind} @ ${m.at.toFixed(3)}s f${m.frame}: ${m.note}`, { scale: 2, fg: [255, 208, 96] });
      around(m).forEach((fi, c) => {
        const x0 = PAD + c * (TW + PAD), y1 = y0 + HEAD, k = need.indexOf(fi);
        blit(img, x0, y1, TW, TH, r.stdout.subarray(k * tile, (k + 1) * tile));
        const center = m.kind === 'seam' ? c === 2 || c === 3 : c === 2;
        drawText(img, x0 + 4, y1 + 4, `${pts[fi].toFixed(3)}s f${fi}`, { scale: 2, fg: center ? [255, 255, 255] : [200, 200, 200], bg: center ? [190, 40, 40] : [0, 0, 0] });
        if (center) for (const [rx, ry, rw, rh] of [[x0, y1, TW, 2], [x0, y1 + TH - 2, TW, 2], [x0, y1, 2, TH], [x0 + TW - 2, y1, 2, TH]]) fillRect(img, rx, ry, rw, rh, [190, 40, 40]);
      });
    });
    writeFileSync(join(out, 'sheet.png'), encodePNG(img.width, img.height, img.data, 3));
  }
}

const bad = jumps.length + wholeFlashes.length + decodeErrors.length + (N !== decoded ? 1 : 0);
console.log(JSON.stringify({ ...report, jumps: report.jumps.slice(0, 40), whole_frame_flashes: report.whole_frame_flashes.slice(0, 40),
  summary: { jumps: jumps.length, whole_frame_flashes: wholeFlashes.length, whole_frame_blend_runs: blendRuns.length, local_flash_frames: locals.length, decode_errors: decodeErrors.length, verdict: bad ? 'FAIL' : 'PASS' } }, null, 2));
process.exit(bad ? 1 : 0);
