#!/usr/bin/env node
// flickercheck: does the site's 3D scene pop while the camera moves?
//
// The hero is a MacBook drawn in CSS 3D that a scroll timeline dollies, tips and fades. Chrome
// sorts the faces of such a scene itself, and two faces in one plane (the lid and the screen on
// it) or touching along an edge are ordered by rounding noise: at some scroll positions half the
// screen went behind the lid's black for one frame, "as if two objects were inside each other".
// Print-fine textures on a face seen nearly edge-on (the deck's halftone) are sampled without
// mipmaps and crawl as moire while the camera moves. Neither changes anything in the DOM, so no
// style or layout check can see them. This one measures pixels.
//
//   node tools/flickercheck.mjs [--site=DIR | --url=URL] [--browser=chromium|webkit]
//        [--sizes=1280x800@1,1512x862@2] [--step=4] [--frames=2] [--settle=140] [--out=DIR]
//        [--top=8] [--block=16] [--theta=24] [--eps=8] [--min-blocks=3] [--scales=1,3]
//        [--css=FILE] [--hide=SEL,SEL] [--y0=PX --y1=PX] [--reverse] [--quiet] [--selftest]
//        [--live [--speed=800] [--live-theta=30] [--max-frames=240] [--ref-step=6] [--lag-max=120]
//                [--live-time=freeze|run] [--live-song=free] [--mask=SEL,SEL]]
//        [--idle [--idle-ms=3000] [--idle-at=0,5,10,...] [--film-at=SEC]]
//        [--dump=Y0:Y1:STEP [--dump-crop=x,y,w,h] [--dump-up=SCALE]]
//        [--channel=chrome|msedge] [--exe=PATH] [--launch-args="--flag --flag"]
//
// How (the default, stepped sweep): the page is served from DIR (or read from URL) at each
// size, its infinite animations and its video are frozen, and the scroll is stepped down the
// journey --step px at a time. Every step is captured --frames times. A step's picture is
// reduced to 16 CSS px block means (and to 48 px ones, --scales), and two things are flagged:
//   pop     a block that goes A -> B -> A over one to three steps (a monotonic camera move
//           never takes a block somewhere and straight back),
//   rest    a block that differs between two captures at the same scroll position,
// then clustered into hotspots: scroll y, journey %, box, the elements under it. Step 1 finds
// what step 2 steps over: the screen's order flip lasted one scroll pixel.
// --css injects a stylesheet and --hide display:nones elements, to bisect a hotspot.
//
// --live is the other half: the video plays, the camera is scrolled at --speed px/s by a wheel
// gesture, and a CDP screencast records the frames the compositor really produced. Settled
// pictures are taken every --ref-step px, and each live frame is matched to the nearest one
// within --lag-max px (the offset a frame reports is the main thread's, a frame or two behind
// the pixels). A frame no settled picture explains is torn or stale; a block that is wrong for
// one frame and right again is a flip. Time is frozen unless --live-time=run; the song is pinned
// unless --live-song=free, and --mask's elements (default: the screen, the dock, the download
// buttons) are left out of the comparison.
// A live or idle 0 counts only once the same build flags a plant: --live --live-time=run
// --css=tools/flicker-plants/one-frame-blink.css and --idle --css=tools/flicker-plants/strobe.css must both
// report h1#hero-title (10-30: frozen time hid a blink, and a three-frame blink is not a one-frame flip).
// --idle parks the camera at several points of the journey with time running and looks for
// blocks that strobe from frame to frame. --dump writes the frames of a scroll range (cropped
// to --dump-crop in CSS px, scaled by --dump-up) to OUT/frames, for a before/after strip.
// --channel/--exe/--launch-args pick a real Chrome and its GPU flags instead of the bundled
// headless shell, which draws with software GL. Playwright's headless Chrome composited the page
// in software in every run so far (GPU raster and WebGL stayed on), so a pass says nothing about
// the Mac's GPU path; every report records what it was in env.gpu.
// What block means cannot see: a blur (it keeps a block's mean), so "crisp to soft" needs eyes.
//
// Exit 0: no hotspots. Exit 1: hotspots (report-BROWSER.json, hotspots.png and frame pairs are
// in --out). Exit 2: usage or tooling error. A browser that cannot run the scroll timeline has
// no journey to flicker: it is reported as skipped and passes.

import { createServer } from 'node:http';
import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync, createReadStream } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve, extname, normalize, sep } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { decodePNG, encodePNG, newImage, blit, drawText, textWidth, fillRect } from './lib/png.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(process.argv.slice(2).map((a) => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/);
  return m ? [m[1], m[2] ?? '1'] : [`_${a}`, '1'];
}));
const num = (k, d) => (args[k] === undefined ? d : Number(args[k]));
const OPT = {
  browser: args.browser || 'chromium',
  step: num('step', 4), frames: Math.max(1, num('frames', 2)), top: num('top', 8),
  block: num('block', 16), theta: num('theta', 24), eps: num('eps', 8), minBlocks: num('min-blocks', 3),
  maxRun: num('max-run', 3), quiet: !!args.quiet, reverse: !!args.reverse,
  settle: num('settle', 140), strict: args['fail-on'] !== 'coarse',
  scales: String(args.scales || '1,3').split(',').map(Number),
  live: !!args.live, speed: num('speed', 800), liveTheta: num('live-theta', 30), maxFrames: num('max-frames', 240),
  dump: args.dump || '', idle: !!args.idle, idleMs: num('idle-ms', 3000), refStep: num('ref-step', 6), liveTime: args['live-time'] || 'freeze', lagMax: num('lag-max', 120),
  mask: String(args.mask || '.mac__screen,[data-dock],[data-download]'),
};
const OUT = resolve(args.out || join(HERE, '..', '.build', 'flickercheck'));
const say = (...a) => { if (!OPT.quiet) console.error(...a); };
const die = (msg, code = 2) => { console.error(`flickercheck: ${msg}`); process.exit(code); };

function parseSizes(s) {
  return String(s || '1280x800@1').split(',').map((t) => {
    const m = t.trim().match(/^(\d+)x(\d+)(?:@(\d+(?:\.\d+)?))?$/);
    if (!m) die(`bad size "${t}" (want 1280x800@1)`);
    return { w: +m[1], h: +m[2], dpr: m[3] ? +m[3] : 1 };
  });
}

// ---- Playwright, wherever it lives --------------------------------------------------------
async function loadPlaywright() {
  const roots = [process.env.PLAYWRIGHT_DIR, process.cwd(), join(homedir(), 'rolepass'), HERE].filter(Boolean);
  const require = createRequire(import.meta.url);
  for (const r of roots) {
    try { return require(require.resolve('playwright', { paths: [r] })); } catch { /* next */ }
  }
  try { return await import('playwright'); } catch { /* none */ }
  die('playwright is not installed (set PLAYWRIGHT_DIR to a folder whose node_modules has it)');
}

// ---- a small static server: Range for video, no caching -----------------------------------
const TYPES = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json', '.webp': 'image/webp', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml', '.mp4': 'video/mp4', '.webm': 'video/webm', '.woff2': 'font/woff2', '.ico': 'image/x-icon', '.txt': 'text/plain' };
function serve(root, overrides = {}) {
  const base = resolve(root);
  const server = createServer((req, res) => {
    let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (overrides[p] !== undefined) { res.writeHead(200, { 'content-type': TYPES['.html'], 'cache-control': 'no-store' }); return res.end(overrides[p]); }
    if (p.endsWith('/')) p += 'index.html';
    const file = normalize(join(base, p));
    if (file !== base && !file.startsWith(base + sep)) { res.writeHead(403); return res.end(); }
    if (!existsSync(file) || !statSync(file).isFile()) { res.writeHead(404); return res.end('not found'); }
    const size = statSync(file).size, type = TYPES[extname(file)] || 'application/octet-stream';
    const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || '');
    const head = { 'content-type': type, 'cache-control': 'no-store', 'accept-ranges': 'bytes' };
    if (range && (range[1] || range[2])) {
      const start = range[1] ? +range[1] : Math.max(0, size - +range[2]);
      const end = range[1] && range[2] ? Math.min(+range[2], size - 1) : size - 1;
      res.writeHead(206, { ...head, 'content-range': `bytes ${start}-${end}/${size}`, 'content-length': end - start + 1 });
      return createReadStream(file, { start, end }).pipe(res);
    }
    res.writeHead(200, { ...head, 'content-length': size });
    createReadStream(file).pipe(res);
  });
  return new Promise((ok) => server.listen(0, '127.0.0.1', () => ok({ server, url: `http://127.0.0.1:${server.address().port}/` })));
}

// ---- pixels -> block means ----------------------------------------------------------------
function blockMeans(png, dpr, blockCss) {
  const { width, height, channels, data } = decodePNG(png);
  const B = Math.max(2, Math.round(blockCss * dpr));
  const bw = Math.ceil(width / B), bh = Math.ceil(height / B);
  const out = new Float32Array(bw * bh * 3);
  const sub = B >= 8 ? 2 : 1; // every other pixel is plenty for a mean over 16+ px
  for (let by = 0; by < bh; by++) for (let bx = 0; bx < bw; bx++) {
    let r = 0, g = 0, b = 0, n = 0;
    const y1 = Math.min(height, (by + 1) * B), x1 = Math.min(width, (bx + 1) * B);
    for (let y = by * B; y < y1; y += sub) for (let x = bx * B; x < x1; x += sub) {
      const o = (y * width + x) * channels;
      if (channels >= 3) { r += data[o]; g += data[o + 1]; b += data[o + 2]; } else { r += data[o]; g += data[o]; b += data[o]; }
      n++;
    }
    const i = (by * bw + bx) * 3;
    out[i] = r / n; out[i + 1] = g / n; out[i + 2] = b / n;
  }
  return { means: out, bw, bh, B, width, height };
}
const bdist = (a, i, b, j) => (Math.abs(a[i * 3] - b[j * 3]) + Math.abs(a[i * 3 + 1] - b[j * 3 + 1]) + Math.abs(a[i * 3 + 2] - b[j * 3 + 2])) / 3;

// Average f x f blocks into one: a halftone that shimmers at 16 px is flat at 48.
function coarsen(means, bw, bh, f) {
  if (f === 1) return { means, bw, bh };
  const bw2 = Math.ceil(bw / f), bh2 = Math.ceil(bh / f), out = new Float32Array(bw2 * bh2 * 3);
  for (let y = 0; y < bh2; y++) for (let x = 0; x < bw2; x++) {
    let r = 0, g = 0, b = 0, n = 0;
    for (let yy = y * f; yy < Math.min(bh, (y + 1) * f); yy++) for (let xx = x * f; xx < Math.min(bw, (x + 1) * f); xx++) {
      const i = (yy * bw + xx) * 3; r += means[i]; g += means[i + 1]; b += means[i + 2]; n++;
    }
    const o = (y * bw2 + x) * 3; out[o] = r / n; out[o + 1] = g / n; out[o + 2] = b / n;
  }
  return { means: out, bw: bw2, bh: bh2 };
}

// A -> B -> A over 1..maxRun steps: both edges at least theta, the two A's within eps (or a
// quarter of the smaller jump, whichever is larger).
function findPops(series, bw, bh, { theta, eps, maxRun }) {
  const K = series.length, N = bw * bh, hits = new Map();
  for (let w = 1; w <= maxRun; w++) for (let k = 1; k + w < K; k++) {
    const pre = series[k - 1], post = series[k + w];
    for (let i = 0; i < N; i++) {
      if (hits.has(k * N + i)) continue;
      const d1 = bdist(pre, i, series[k], i); if (d1 < theta) continue;
      const d2 = bdist(post, i, series[k + w - 1], i); if (d2 < theta) continue;
      const amp = Math.min(d1, d2), tol = Math.max(eps, 0.25 * amp);
      if (bdist(pre, i, post, i) > tol) continue;
      let flat = true;
      for (let j = 1; j < w && flat; j++) if (bdist(series[k], i, series[k + j], i) > tol) flat = false;
      if (flat) hits.set(k * N + i, { k, i, amp, run: w });
    }
  }
  return [...hits.values()];
}
function findRest(frameSets, bw, bh, { theta }) {
  const N = bw * bh, hits = [];
  frameSets.forEach((fs, k) => {
    if (fs.length < 2) return;
    for (let i = 0; i < N; i++) {
      let amp = 0;
      for (let f = 1; f < fs.length; f++) amp = Math.max(amp, bdist(fs[0], i, fs[f], i));
      if (amp >= theta) hits.push({ k, i, amp, run: 0 });
    }
  });
  return hits;
}
// Union blocks that touch in space (8-neighborhood) and in time (within two steps).
function cluster(hits, bw, kind) {
  const parent = hits.map((_, n) => n);
  const find = (n) => { while (parent[n] !== n) { parent[n] = parent[parent[n]]; n = parent[n]; } return n; };
  const at = new Map();
  hits.forEach((h, n) => { const key = `${h.k},${h.i}`; at.set(key, n); });
  hits.forEach((h, n) => {
    const bx = h.i % bw, by = (h.i - bx) / bw;
    for (let dk = -2; dk <= 2; dk++) for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
      const m = at.get(`${h.k + dk},${(by + dy) * bw + bx + dx}`);
      if (m !== undefined && bx + dx >= 0 && bx + dx < bw) parent[find(n)] = find(m);
    }
  });
  const groups = new Map();
  hits.forEach((h, n) => { const r = find(n); (groups.get(r) || groups.set(r, []).get(r)).push(h); });
  return [...groups.values()].map((g) => {
    const xs = g.map((h) => h.i % bw), ys = g.map((h) => Math.floor(h.i / bw)), ks = g.map((h) => h.k);
    const peak = g.reduce((a, b) => (b.amp > a.amp ? b : a));
    return { kind, blocks: new Set(g.map((h) => h.i)).size, hits: g.length, steps: new Set(ks).size, k0: Math.min(...ks), k1: Math.max(...ks),
      bx0: Math.min(...xs), bx1: Math.max(...xs), by0: Math.min(...ys), by1: Math.max(...ys), peak: peak.amp, kPeak: peak.k, iPeak: peak.i, run: peak.run };
  });
}

// ---- the browser side ---------------------------------------------------------------------
const FREEZE = `(() => {
  HTMLMediaElement.prototype.play = function () { return Promise.resolve(); };
  const add = () => { const st = document.createElement('style'); st.textContent = '*,*::before,*::after{transition:none !important}'; (document.head || document.documentElement).appendChild(st); };
  if (document.head) add(); else document.addEventListener('DOMContentLoaded', add);
})();`;

async function freeze(page) {
  await page.evaluate(() => {
    for (const v of document.querySelectorAll('video')) { try { v.pause(); } catch {} }
    const ST = typeof ScrollTimeline === 'function' ? ScrollTimeline : null;
    for (const a of document.getAnimations()) {
      if (ST && a.timeline instanceof ST) continue; // the camera: leave it to the scroll
      try { a.pause(); a.currentTime = 0; } catch {}
    }
    for (const s of document.querySelectorAll('*')) if (s.style && s.style.transition) s.style.transition = 'none';
  });
}
const PIN = `(() => {
  const pin = () => { for (const g of document.querySelectorAll('[data-glow]')) if (g.dataset.song && g.dataset.song !== 'pop') g.dataset.song = 'pop'; };
  new MutationObserver(pin).observe(document, { attributes: true, subtree: true, attributeFilter: ['data-song'] });
})();`;
const raf2 = (page) => page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r()))));

async function makeGrab(ctx, page) {
  if (OPT.browser === 'chromium') {
    const cdp = await ctx.newCDPSession(page);
    return async () => Buffer.from((await cdp.send('Page.captureScreenshot', { format: 'png', optimizeForSpeed: true, fromSurface: true })).data, 'base64');
  }
  return () => page.screenshot({ type: 'png', animations: 'allow', caret: 'initial' });
}

async function describeAt(page, x, y) {
  return page.evaluate(([px, py]) => {
    const name = (e) => e.tagName.toLowerCase() + (e.id ? `#${e.id}` : '') + [...e.classList].slice(0, 3).map((c) => `.${c}`).join('');
    return document.elementsFromPoint(px, py).slice(0, 5).map(name);
  }, [x, y]);
}

async function sweep(pw, base, cfg) {
  const type = pw[OPT.browser];
  if (!type) die(`no browser type ${OPT.browser}`);
  const launch = { headless: true };
  if (args.channel) launch.channel = args.channel;
  if (args.exe) launch.executablePath = args.exe;
  if (args['launch-args']) launch.args = String(args['launch-args']).split(/\s+/).filter(Boolean);
  const browser = await type.launch(launch);
  try {
    const ctx = await browser.newContext({ viewport: { width: cfg.w, height: cfg.h }, deviceScaleFactor: cfg.dpr, reducedMotion: 'no-preference' });
    const page = await ctx.newPage();
    // stepped sweeps freeze every time-driven thing; --live does too unless --live-time=run;
    // --idle never does (time is what it looks at)
    const frozen = !OPT.idle && (!OPT.live || OPT.liveTime !== 'run');
    if (frozen) await page.addInitScript(FREEZE);
    else if (args['live-song'] !== 'free') await page.addInitScript(PIN);
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e).slice(0, 200)));
    await page.goto(base, { waitUntil: 'load' });
    await page.evaluate(() => document.fonts && document.fonts.ready);
    if (args.css) await page.addStyleTag({ content: readFileSync(resolve(args.css), 'utf8') });
    if (args.hide) await page.addStyleTag({ content: `${args.hide} { display: none !important; }` });
    const env = await page.evaluate(() => {
      let gl = ''; try { const c = document.createElement('canvas').getContext('webgl'); const e = c.getExtension('WEBGL_debug_renderer_info'); gl = e ? c.getParameter(e.UNMASKED_RENDERER_WEBGL) : 'webgl'; } catch { gl = 'no webgl'; }
      return { ua: navigator.userAgent, gl, timeline: CSS.supports('animation-timeline: view()') };
    });
    // Playwright's headless Chrome composited in software (gpu_compositing disabled_software) in
    // every run here, whatever the GPU; a headed Chrome may not. A report says which one it was.
    if (OPT.browser === 'chromium') {
      try {
        const cdp = await browser.newBrowserCDPSession(), f = (await cdp.send('SystemInfo.getInfo')).gpu.featureStatus || {};
        env.gpu = `compositing ${f.gpu_compositing}, raster ${f.rasterization}, webgl ${f.webgl}`;
        await cdp.detach();
      } catch { env.gpu = 'unknown'; }
    }
    const j = await page.evaluate(() => {
      const e = document.querySelector('.journey') || document.body, r = e.getBoundingClientRect();
      return { top: r.top + scrollY, height: r.height, max: document.documentElement.scrollHeight - innerHeight };
    });
    const j0 = j.top, j1 = Math.max(j0 + 1, j.top + j.height - cfg.h);
    const y0 = args.y0 !== undefined ? +args.y0 : Math.max(0, Math.floor(j0 - cfg.h * 0.25));
    const y1 = Math.min(j.max, args.y1 !== undefined ? +args.y1 : Math.ceil(j1 + cfg.h * 0.25));
    const res = { cfg, env, journey: { top: j0, bottom: j1 }, errors, range: [y0, y1], steps: 0, hotspots: [], skipped: null };
    if (!env.timeline) { res.skipped = 'this browser has no animation-timeline: view(), so there is no journey to flicker'; return res; }

    if (frozen) await freeze(page);
    if (OPT.idle) return await idleSweep(ctx, page, cfg, res, { y0, y1, j0, j1 });
    if (OPT.live) return await liveSweep(ctx, page, cfg, res, { y0, y1, j0, j1 });
    const grab = await makeGrab(ctx, page);
    const ys = []; for (let y = y0; y <= y1; y += OPT.step) ys.push(y);
    if (OPT.reverse) for (let y = y1; y >= y0; y -= OPT.step) ys.push(y);
    const at = async (y) => { await page.evaluate((v) => window.scrollTo({ top: v, behavior: 'instant' }), y); await raf2(page); if (OPT.settle) await page.waitForTimeout(OPT.settle); };

    if (OPT.dump) { // a run of frames for a clip: --dump=Y0:Y1:STEP [--dump-crop=x,y,w,h in CSS px] [--dump-up=2]
      const [da, db, ds] = String(OPT.dump).split(':').map(Number);
      const crop = args['dump-crop'] ? String(args['dump-crop']).split(',').map(Number) : [0, 0, cfg.w, cfg.h];
      const up = num('dump-up', cfg.dpr), t1 = Date.now();
      mkdirSync(join(OUT, 'frames'), { recursive: true });
      let n = 0;
      for (let y = da; y <= db; y += ds) {
        await at(y);
        writeFileSync(join(OUT, 'frames', `${String(n++).padStart(4, '0')}.png`), cropLabel(decodePNG(await grab()), cfg.dpr, crop, up, `Y ${y}`));
      }
      res.steps = n; res.seconds = (Date.now() - t1) / 1000; res.totalClusters = 0; res.counts = {};
      return res;
    }
    const series = [], frameSets = [];
    let geom = null;
    const t0 = Date.now();
    for (let n = 0; n < ys.length; n++) {
      await at(ys[n]);
      const fs = [];
      for (let f = 0; f < OPT.frames; f++) {
        const m = blockMeans(await grab(), cfg.dpr, OPT.block);
        geom ||= m; fs.push(m.means);
      }
      series.push(fs[0]); frameSets.push(fs);
      if (!OPT.quiet && n % 100 === 99) say(`  ${cfg.w}x${cfg.h}@${cfg.dpr}: ${n + 1}/${ys.length} steps, ${((Date.now() - t0) / 1000).toFixed(0)}s`);
    }
    res.steps = ys.length; res.seconds = (Date.now() - t0) / 1000;
    const { bw, bh, B } = geom;
    const th = { theta: OPT.theta, eps: OPT.eps, maxRun: OPT.maxRun };
    const all = [], counts = {};
    for (const f of OPT.scales) {
      const cs = series.map((m) => coarsen(m, bw, bh, f)), g2 = cs[0];
      const sets = frameSets.map((fs) => fs.map((m) => coarsen(m, bw, bh, f).means));
      const sc = (B * f) / cfg.dpr;
      const cl = [...cluster(findPops(cs.map((c) => c.means), g2.bw, g2.bh, th), g2.bw, 'pop'), ...cluster(findRest(sets, g2.bw, g2.bh, th), g2.bw, 'rest')]
        .filter((c) => c.blocks >= (f === 1 ? OPT.minBlocks : 1))
        .map((c) => ({ ...c, scale: sc }))
        .sort((x, y) => y.hits * y.peak - x.hits * x.peak);
      counts[sc] = cl.length;
      for (const c of cl.slice(0, Math.max(OPT.top, 1))) {
        const box = { x: c.bx0 * sc, y: c.by0 * sc, w: (c.bx1 - c.bx0 + 1) * sc, h: (c.by1 - c.by0 + 1) * sc };
        await at(ys[c.kPeak]);
        const els = await describeAt(page, Math.min(cfg.w - 1, box.x + box.w / 2), Math.min(cfg.h - 1, box.y + box.h / 2));
        all.push({ ...c, y: ys[c.kPeak], yFrom: ys[c.k0], yTo: ys[c.k1], journeyPct: +(((ys[c.kPeak] - j0) / (j1 - j0)) * 100).toFixed(1), box, elements: els });
      }
    }
    all.sort((x, y) => y.scale - x.scale || y.hits * y.peak - x.hits * x.peak);
    res.hotspots = all; res.counts = counts;
    const coarse = Math.max(...Object.keys(counts).map(Number));
    res.totalClusters = OPT.strict ? Object.values(counts).reduce((a, b2) => a + b2, 0) : (counts[coarse] || 0);
    res.ys = ys; res.geom = { bw, bh, B };
    // frame pairs for the top hotspots: the step before, the peak, the step after
    if (res.hotspots.length) {
      mkdirSync(OUT, { recursive: true });
      const tag = `${OPT.browser}-${cfg.w}x${cfg.h}@${cfg.dpr}`;
      const rows = [];
      for (const [hi, h] of res.hotspots.slice(0, 6).entries()) {
        const crops = [];
        const ks = [h.kPeak - 1, h.kPeak, h.kPeak + 1, h.kPeak + 2].filter((k) => k >= 0 && k < ys.length);
        for (const k of ks) {
          await at(ys[k]);
          const img = decodePNG(await grab());
          crops.push({ k, y: ys[k], img });
          if (hi === 0) writeFileSync(join(OUT, `${tag}-hotspot1-y${ys[k]}.png`), await sharePng(img, cfg.dpr));
        }
        rows.push({ h, hi, crops });
      }
      writeFileSync(join(OUT, `${tag}-hotspots.png`), sheet(rows, cfg));
    }
    return res;
  } finally { await browser.close(); }
}

// ---- live and idle modes: what the compositor really drew --------------------------------
// Blocks of the fine grid whose center lies in one of `rects` (the screen, the dock: they move
// on their own) are left out; a coarse block counts only when every fine block under it is kept.
function maskFine(valid, L, rects) {
  for (const r of rects) for (let by = 0; by < L.bh; by++) for (let bx = 0; bx < L.bw; bx++) {
    const cx = (bx + 0.5) * L.B, cy = (by + 0.5) * L.B;
    if (cx >= r.x && cx <= r.x + r.w && cy >= r.y && cy <= r.y + r.h) valid[by * L.bw + bx] = 0;
  }
}
function coarsenMasked(means, valid, bw, bh, f) {
  const bw2 = Math.ceil(bw / f), bh2 = Math.ceil(bh / f), out = new Float32Array(bw2 * bh2 * 3), full = new Uint8Array(bw2 * bh2);
  for (let y = 0; y < bh2; y++) for (let x = 0; x < bw2; x++) {
    let r = 0, g = 0, b = 0, n = 0, all = 0;
    for (let yy = y * f; yy < Math.min(bh, (y + 1) * f); yy++) for (let xx = x * f; xx < Math.min(bw, (x + 1) * f); xx++) {
      all++; const i = yy * bw + xx; if (!valid[i]) continue;
      r += means[i * 3]; g += means[i * 3 + 1]; b += means[i * 3 + 2]; n++;
    }
    if (n) { const o = y * bw2 + x; out[o * 3] = r / n; out[o * 3 + 1] = g / n; out[o * 3 + 2] = b / n; full[o] = n === all ? 1 : 0; }
  }
  return { means: out, full, bw: bw2, bh: bh2 };
}
// The rectangles of the elements that are left out of a comparison, as the page lays them out now.
const maskRects = (page) => page.evaluate((sel) => {
  const rects = [];
  for (const e of document.querySelectorAll(sel)) { const r = e.getBoundingClientRect(); if (r.width > 0 && r.height > 0) rects.push({ x: r.left - 4, y: r.top - 4, w: r.width + 8, h: r.height + 8 }); }
  return { rects, px: visualViewport.pageLeft, py: visualViewport.pageTop };
}, OPT.mask);

function screencast(cdp, cfg) {
  const st = { got: [], on: false };
  cdp.on('Page.screencastFrame', (ev) => {
    if (st.on) st.got.push({ y: ev.metadata.scrollOffsetY, ts: ev.metadata.timestamp, data: ev.data });
    cdp.send('Page.screencastFrameAck', { sessionId: ev.sessionId }).catch(() => {});
  });
  return {
    got: () => st.got,
    async start() { st.got = []; st.on = true; await cdp.send('Page.startScreencast', { format: 'png', everyNthFrame: 1, maxWidth: cfg.w, maxHeight: cfg.h }); },
    async stop() { await cdp.send('Page.stopScreencast'); st.on = false; },
  };
}
const gapStats = (got) => {
  const gaps = got.slice(1).map((f, i) => (f.ts - got[i].ts) * 1000).sort((p, q) => p - q);
  return { frames: got.length, fps: gaps.length ? +(1000 / (gaps.reduce((p, q) => p + q, 0) / gaps.length)).toFixed(1) : 0,
    medianGapMs: gaps.length ? +gaps[gaps.length >> 1].toFixed(1) : 0, maxGapMs: gaps.length ? +gaps[gaps.length - 1].toFixed(1) : 0 };
};

// Every frame the compositor draws while the page scrolls must look like the settled page at
// SOME scroll offset: the settled pictures are captured every --ref-step px and each live frame
// is matched to the nearest one (the offset a screencast frame reports is the main thread's, a
// frame or two behind the pixels). What no settled picture explains is a torn or stale frame.
async function liveSweep(ctx, page, cfg, res, { y0, y1, j0, j1 }) {
  const cdp = await ctx.newCDPSession(page);
  const cast = screencast(cdp, cfg);
  const at = async (y) => { await page.evaluate((v) => window.scrollTo({ top: v, behavior: 'instant' }), y); await raf2(page); if (OPT.settle) await page.waitForTimeout(OPT.settle); };
  const F = Math.max(...OPT.scales), t0 = Date.now();
  await at(y0); await page.waitForTimeout(900);
  await cast.start();
  const passes = [[y0, y1]]; if (OPT.reverse) passes.push([y1, y0]);
  for (const [a, b] of passes) {
    await cdp.send('Input.synthesizeScrollGesture', { x: Math.round(cfg.w / 2), y: Math.round(cfg.h / 2), yDistance: a - b, speed: OPT.speed, gestureSourceType: 'mouse', preventFling: true });
    await page.waitForTimeout(500);
  }
  await cast.stop();
  const got = cast.got();
  res.live = { ...gapStats(got), from: got.length ? got[0].y : null, to: got.length ? got[got.length - 1].y : null, speed: OPT.speed };
  say(`  live: ${got.length} frames at ${res.live.fps} fps (median gap ${res.live.medianGapMs} ms, max ${res.live.maxGapMs} ms), scroll ${res.live.from} -> ${res.live.to}`);
  const stride = got.length > OPT.maxFrames ? got.length / OPT.maxFrames : 1;
  const picks = []; for (let q = 0; q < got.length; q += stride) picks.push(got[Math.floor(q)]);

  // the settled pictures, one every --ref-step px (block means only: 400 PNGs would not fit in memory),
  // at the screencast's own size: what clip.scale means differs between Chrome builds (at 390x844@3 Mac
  // Chrome gave 130x281 against 390x844 live frames, so no frame matched and the sweep crashed, 10-30).
  const pngW = (b64) => Buffer.from(b64, 'base64').readUInt32BE(16);
  const shotAt = (where, scale) => cdp.send('Page.captureScreenshot', { format: 'png', optimizeForSpeed: true, fromSurface: true, clip: { x: where.px, y: where.py, width: cfg.w, height: cfg.h, scale } });
  let refScale = 1 / cfg.dpr;
  if (got.length) { const w0 = pngW(got[0].data), wr = pngW((await shotAt(await maskRects(page), refScale)).data); if (wr !== w0) refScale *= w0 / wr; }
  const refs = [];
  // Pixels run up to --lag-max px ahead of the offset a frame reports, so the settled pictures reach that far past
  // both ends; otherwise frames at the turn of a pass (still a real scroll position) read as torn (10-30).
  const maxY = await page.evaluate(() => document.scrollingElement.scrollHeight - innerHeight);
  for (let y = Math.max(0, y0 - OPT.lagMax); y <= Math.min(maxY, y1 + OPT.lagMax); y += OPT.refStep) {
    await at(y);
    const where = await maskRects(page);
    const shot = await shotAt(where, refScale);
    const R = blockMeans(Buffer.from(shot.data, 'base64'), 1, OPT.block);
    const valid = new Uint8Array(R.bw * R.bh).fill(1); maskFine(valid, R, where.rects);
    refs.push({ y, c: coarsenMasked(R.means, valid, R.bw, R.bh, F), R });
  }
  say(`  live: ${refs.length} settled pictures in ${((Date.now() - t0) / 1000).toFixed(0)}s`);

  const cap = OPT.liveTheta, hits = [], flips = [], lag = [], costs = [];
  let masked = 0;
  const frames = [];
  let geom = null;
  for (let n = 0; n < picks.length; n++) {
    const L = blockMeans(Buffer.from(picks[n].data, 'base64'), 1, OPT.block);
    if (L.bw !== refs[0].R.bw || L.bh !== refs[0].R.bh) continue;
    geom ||= L;
    const lc = coarsen(L.means, L.bw, L.bh, F);
    // Where the mask (the playing film) covers most of the settled page there is nothing to compare, and the
    // nearest picture that has something is far enough off to read the film as torn (390x844 past y 2142, 10-30).
    const near = refs.reduce((a, r, i) => (Math.abs(r.y - picks[n].y) < Math.abs(refs[a].y - picks[n].y) ? i : a), 0);
    if (refs[near].c.full.reduce((p, q) => p + (q ? 1 : 0), 0) < 0.25 * refs[near].c.full.length) { masked++; continue; }
    let best = -1, bestCost = Infinity;
    for (let r = 0; r < refs.length; r++) {
      if (Math.abs(refs[r].y - picks[n].y) > OPT.lagMax) continue;
      const c = refs[r].c; let s = 0, m = 0;
      for (let i = 0; i < c.full.length; i++) if (c.full[i]) { const d = bdist(lc.means, i, c.means, i); s += d < cap ? d : cap; m++; }
      if (m && s / m < bestCost) { bestCost = s / m; best = r; }
    }
    if (best < 0) continue;
    const c = refs[best].c;
    lag.push(refs[best].y - picks[n].y); costs.push(bestCost);
    frames.push({ n, lc, best, bestCost });
    for (let i = 0; i < c.full.length; i++) if (c.full[i]) { const d = bdist(lc.means, i, c.means, i); if (d >= cap) hits.push({ k: n, i, amp: d, run: 0 }); }
  }
  // a block that is not the settled picture's on one frame and is again on the next two
  for (let q = 1; q + 1 < frames.length; q++) {
    const A = frames[q - 1], B = frames[q], C = frames[q + 1];
    const cA = refs[A.best].c.full, cB = refs[B.best].c.full, cC = refs[C.best].c.full;
    for (let i = 0; i < cB.length; i++) {
      if (!(cA[i] && cB[i] && cC[i])) continue;
      const d1 = bdist(A.lc.means, i, B.lc.means, i), d2 = bdist(B.lc.means, i, C.lc.means, i);
      if (d1 < OPT.theta || d2 < OPT.theta) continue;
      // B matching the settled page at its own offset is content that moved, not a flip (a 3D deck scrolled 40 px a frame).
      if (bdist(B.lc.means, i, refs[B.best].c.means, i) < OPT.theta) continue;
      if (bdist(A.lc.means, i, C.lc.means, i) <= Math.max(OPT.eps, 0.25 * Math.min(d1, d2))) flips.push({ k: B.n, i, amp: Math.min(d1, d2), run: 1 });
    }
  }
  const sorted = (a) => [...a].sort((p, q) => p - q), pct = (a, f) => (a.length ? sorted(a)[Math.min(a.length - 1, Math.floor(a.length * f))] : 0);
  res.live.match = { frames: frames.length, lagPx: { median: pct(lag.map(Math.abs), 0.5), p95: pct(lag.map(Math.abs), 0.95), max: Math.max(0, ...lag.map(Math.abs)) },
    cost: { median: +pct(costs, 0.5).toFixed(2), p95: +pct(costs, 0.95).toFixed(2), max: +Math.max(0, ...costs).toFixed(2) }, refStep: OPT.refStep, maskedFrames: masked };
  res.steps = picks.length; res.seconds = (Date.now() - t0) / 1000; res.range = [y0, y1];
  if (!geom) die(`live: none of ${picks.length} frames matched a settled picture's size`);
  const bw2 = Math.ceil(geom.bw / F), sc = geom.B * F;
  const all = [], counts = {};
  const cl = [...cluster(hits, bw2, 'torn'), ...cluster(flips, bw2, 'flip')].filter((c) => c.blocks >= 1).map((c) => ({ ...c, scale: sc })).sort((x, y) => y.hits * y.peak - x.hits * x.peak);
  counts[sc] = cl.length;
  const tornFrames = new Set(hits.map((h) => h.k)).size;
  res.live.match.tornFrames = tornFrames;
  const byN = new Map(frames.map((f) => [f.n, f]));
  for (const c of cl.slice(0, Math.max(OPT.top, 1))) {
    const box = { x: c.bx0 * sc, y: c.by0 * sc, w: (c.bx1 - c.bx0 + 1) * sc, h: (c.by1 - c.by0 + 1) * sc };
    const y = picks[c.kPeak].y, bestY = byN.get(c.kPeak) ? refs[byN.get(c.kPeak).best].y : y;
    await at(bestY);
    const els = await describeAt(page, Math.min(cfg.w - 1, box.x + box.w / 2), Math.min(cfg.h - 1, box.y + box.h / 2));
    all.push({ ...c, y, yFrom: picks[c.k0].y, yTo: picks[c.k1].y, bestY, journeyPct: +(((y - j0) / (j1 - j0)) * 100).toFixed(1), box, elements: els });
  }
  all.sort((x, y) => y.hits * y.peak - x.hits * x.peak);
  res.hotspots = all; res.counts = counts; res.totalClusters = cl.length;
  if (all.length) {
    mkdirSync(OUT, { recursive: true });
    const tag = `${OPT.browser}-${cfg.w}x${cfg.h}@${cfg.dpr}-live`;
    const rows = [];
    for (const [hi, h] of all.slice(0, 6).entries()) {
      const k = h.kPeak, crops = [];
      for (const kk of [k - 1, k, k + 1].filter((q) => q >= 0 && q < picks.length)) crops.push({ k: kk, y: picks[kk].y, img: decodePNG(Buffer.from(picks[kk].data, 'base64')), label: `LIVE ${Math.round(picks[kk].y)}${kk === k ? ' <' : ''}` });
      await at(h.bestY);
      const where = await maskRects(page);
      const shot = await shotAt(where, refScale);
      crops.push({ k, y: h.bestY, img: decodePNG(Buffer.from(shot.data, 'base64')), label: `SETTLED ${Math.round(h.bestY)}` });
      rows.push({ h, hi, crops });
      if (hi === 0) {
        writeFileSync(join(OUT, `${tag}-hotspot1-y${Math.round(h.y)}-live.png`), Buffer.from(picks[k].data, 'base64'));
        writeFileSync(join(OUT, `${tag}-hotspot1-y${Math.round(h.y)}-settled.png`), Buffer.from(shot.data, 'base64'));
      }
    }
    writeFileSync(join(OUT, `${tag}-hotspots.png`), sheet(rows, cfg, 1));
  }
  return res;
}

// Idle: the camera is parked at --idle-at (percent of the journey) while time-driven things run
// (the wall's slow turns, the glow, the lid's rim). A page at rest should not change, and one
// that strobes shows as blocks going A -> B -> A between consecutive frames.
async function idleSweep(ctx, page, cfg, res, { y0, y1, j0, j1 }) {
  const cdp = await ctx.newCDPSession(page);
  const cast = screencast(cdp, cfg);
  const pcts = String(args['idle-at'] || '0,5,10,15,20,25,30,35,40,50,70,100').split(',').map(Number);
  const F = Math.max(...OPT.scales), t0 = Date.now(), all = [], idle = [], evidence = [];
  let geom = null;
  for (const p of pcts) {
    const y = Math.max(0, Math.min(y1, Math.round(j0 + (j1 - j0) * (p / 100))));
    await page.evaluate((v) => window.scrollTo({ top: v, behavior: 'instant' }), y); await raf2(page); await page.waitForTimeout(OPT.settle + 700);
    const where = await maskRects(page);
    // --film-at=SEC: the film is cued a little before a cut, so the park sees a song change
    if (args['film-at']) await page.evaluate(async (t) => { for (const v of document.querySelectorAll('video.mac__film')) { v.muted = true; v.currentTime = t; await v.play().catch(() => {}); } }, +args['film-at']);
    await cast.start(); await page.waitForTimeout(OPT.idleMs); await cast.stop();
    const seq = cast.got();
    const st = { pct: p, y, ...gapStats(seq) };
    idle.push(st);
    if (seq.length < 3) { say(`  idle @${p}% (y=${y}): ${seq.length} frames (the page is not moving)`); continue; }
    const L0 = blockMeans(Buffer.from(seq[0].data, 'base64'), 1, OPT.block);
    geom ||= L0;
    const valid = new Uint8Array(L0.bw * L0.bh).fill(1); maskFine(valid, L0, where.rects);
    const fine = seq.map((f) => blockMeans(Buffer.from(f.data, 'base64'), 1, OPT.block).means);
    let nHits = 0;
    for (const f of OPT.scales) {
      const ser = fine.map((m) => { const c = coarsenMasked(m, valid, L0.bw, L0.bh, f); for (let i = 0; i < c.full.length; i++) if (!c.full[i]) { c.means[i * 3] = c.means[i * 3 + 1] = c.means[i * 3 + 2] = 0; } return c; });
      const g2 = ser[0], sc = L0.B * f;
      const cl = cluster(findPops(ser.map((c) => c.means), g2.bw, g2.bh, { theta: OPT.theta, eps: OPT.eps, maxRun: OPT.maxRun }), g2.bw, 'pop').filter((c) => c.blocks >= (f === 1 ? OPT.minBlocks : 1));
      nHits += cl.length;
      for (const c of cl) {
        const box = { x: c.bx0 * sc, y: c.by0 * sc, w: (c.bx1 - c.bx0 + 1) * sc, h: (c.by1 - c.by0 + 1) * sc };
        const h = { ...c, scale: sc, y, yFrom: y, yTo: y, journeyPct: p, box, elements: [], frames: seq.length };
        all.push(h);
        if (evidence.length < 40) evidence.push({ h, crops: [c.kPeak - 1, c.kPeak, c.kPeak + 1].filter((q) => q >= 0 && q < seq.length).map((q) => ({ k: q, y, img: decodePNG(Buffer.from(seq[q].data, 'base64')), label: `P${p} F${q}${q === c.kPeak ? ' <' : ''}` })) });
      }
    }
    say(`  idle @${p}% (y=${y}): ${seq.length} frames at ${st.fps} fps, ${nHits} hotspot(s)`);
  }
  for (const h of all.sort((x, y) => y.scale - x.scale || y.hits * y.peak - x.hits * x.peak).slice(0, Math.max(OPT.top, 1))) {
    await page.evaluate((v) => window.scrollTo({ top: v, behavior: 'instant' }), h.y); await raf2(page);
    h.elements = await describeAt(page, Math.min(cfg.w - 1, h.box.x + h.box.w / 2), Math.min(cfg.h - 1, h.box.y + h.box.h / 2));
  }
  const counts = {}; for (const h of all) counts[h.scale] = (counts[h.scale] || 0) + 1;
  res.idle = idle; res.steps = idle.reduce((a, b) => a + b.frames, 0); res.seconds = (Date.now() - t0) / 1000; res.range = [y0, y1];
  res.hotspots = all.slice(0, Math.max(OPT.top, 1)); res.counts = counts;
  const coarse = Math.max(0, ...Object.keys(counts).map(Number));
  res.totalClusters = OPT.strict ? all.length : (counts[coarse] || 0);
  if (evidence.length) {
    mkdirSync(OUT, { recursive: true });
    const top = evidence.sort((a, b) => b.h.scale - a.h.scale || b.h.hits * b.h.peak - a.h.hits * a.h.peak).slice(0, 6);
    writeFileSync(join(OUT, `${OPT.browser}-${cfg.w}x${cfg.h}@${cfg.dpr}-idle-hotspots.png`), sheet(top.map(({ h, crops }, hi) => ({ h, hi, crops })), cfg, 1));
  }
  return res;
}

// A crop of a capture (rect in CSS px) enlarged `up` times, with a label burnt in: one frame of a clip.
function cropLabel(img, dpr, [cx, cy, cw, ch], up, label) {
  const w = Math.round(cw * up), h = Math.round(ch * up), out = new Uint8Array(w * h * 3);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const sx = Math.min(img.width - 1, Math.floor((cx + x / up) * dpr)), sy = Math.min(img.height - 1, Math.floor((cy + y / up) * dpr));
    const o = (sy * img.width + sx) * img.channels, d = (y * w + x) * 3;
    out[d] = img.data[o]; out[d + 1] = img.data[o + (img.channels > 1 ? 1 : 0)]; out[d + 2] = img.data[o + (img.channels > 1 ? 2 : 0)];
  }
  const im = { width: w, height: h, data: out };
  if (label) drawText(im, 8, 8, label, { scale: 2, fg: [255, 214, 90], bg: [0, 0, 0] });
  return encodePNG(w, h, out, 3);
}

// A full frame shrunk to CSS pixels, as RGB.
async function sharePng(img, dpr) {
  const s = Math.max(1, Math.round(dpr)), w = Math.floor(img.width / s), h = Math.floor(img.height / s), out = new Uint8Array(w * h * 3);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const o = (y * s * img.width + x * s) * img.channels, d = (y * w + x) * 3;
    out[d] = img.data[o]; out[d + 1] = img.data[o + (img.channels > 1 ? 1 : 0)]; out[d + 2] = img.data[o + (img.channels > 1 ? 2 : 0)];
  }
  return encodePNG(w, h, out, 3);
}

function sheet(rows, cfg, css = cfg.dpr) {
  const CELLH = 200, GAP = 6, HEAD = 22, MARGIN = 24;
  const cells = rows.map(({ h, crops }) => {
    const bx = Math.max(0, h.box.x - MARGIN), by = Math.max(0, h.box.y - MARGIN);
    const bwid = h.box.w + 2 * MARGIN, bhei = h.box.h + 2 * MARGIN;
    const scale = Math.min(4, CELLH / bhei, 360 / bwid);
    const cw = Math.max(8, Math.round(bwid * scale)), ch = Math.max(8, Math.round(bhei * scale));
    return crops.map(({ k, y, img, label }) => {
      const tile = new Uint8Array(cw * ch * 3);
      for (let ty = 0; ty < ch; ty++) for (let tx = 0; tx < cw; tx++) {
        const sx = Math.min(img.width - 1, Math.floor((bx + tx / scale) * css)), sy = Math.min(img.height - 1, Math.floor((by + ty / scale) * css));
        const o = (sy * img.width + sx) * img.channels, d = (ty * cw + tx) * 3;
        tile[d] = img.data[o]; tile[d + 1] = img.data[o + (img.channels > 1 ? 1 : 0)]; tile[d + 2] = img.data[o + (img.channels > 1 ? 2 : 0)];
      }
      return { tile, cw, ch, label: label ?? `Y ${y}${k === h.kPeak ? ' <' : ''}` };
    });
  });
  const width = Math.max(...cells.map((r) => r.reduce((a, c) => a + c.cw + GAP, GAP)), 400);
  const height = cells.reduce((a, r) => a + HEAD + Math.max(...r.map((c) => c.ch)) + 14 + GAP * 2, GAP);
  const img = newImage(width, height, [20, 20, 22]);
  let y = GAP;
  cells.forEach((row, ri) => {
    const h = rows[ri].h;
    drawText(img, GAP, y + 4, `#${ri + 1} ${h.kind} ${h.scale}PX Y ${h.y} JOURNEY ${h.journeyPct}% ${h.blocks} BLOCKS ${h.steps} STEPS AMP ${h.peak.toFixed(0)} ${(h.elements[0] || '').slice(0, 24)}`, { scale: 2, fg: [255, 214, 90] });
    y += HEAD;
    let x = GAP; const rh = Math.max(...row.map((c) => c.ch));
    for (const c of row) { blit(img, x, y, c.cw, c.ch, c.tile); drawText(img, x + 2, y + c.ch + 3, c.label, { scale: 1, fg: [200, 200, 200] }); x += c.cw + GAP; }
    y += rh + 14 + GAP * 2;
  });
  return encodePNG(width, height, img.data, 3);
}

// ---- self test: the detector must see a planted pop and stay quiet on a steady page --------
const PAGE = (toggle) => `<!doctype html><meta charset=utf-8><title>selftest</title><style>
html{background:#000}body{margin:0;height:1400px}
.journey{position:absolute;top:0;left:0;right:0;height:1400px}
.flow{position:absolute;top:0;left:640px;width:300px;height:1400px;background:repeating-linear-gradient(0deg,#111 0 18px,#888 18px 22px,#111 22px 40px)}
.card{position:fixed;left:120px;top:120px;width:360px;height:240px;background:#2a6cf0}
</style><div class=journey></div><div class=flow></div><div class=card id=c></div>
${toggle ? `<script>addEventListener('scroll',()=>{c.style.background=(Math.round(scrollY/${OPT.step})%2)?'#f03a2a':'#2a6cf0'})</script>` : ''}`;

async function selftest(pw) {
  const results = [];
  for (const [name, toggle, want] of [['planted pop', true, 'hotspot'], ['steady page', false, 'none']]) {
    const { server, url } = await serve(HERE, { '/selftest.html': PAGE(toggle) });
    try {
      const r = await sweep(pw, `${url}selftest.html`, { w: 960, h: 480, dpr: 1 });
      const found = r.hotspots.length > 0;
      results.push({ name, want, got: found ? `hotspot (${r.hotspots[0].kind}, ${r.hotspots[0].blocks} blocks)` : 'none', ok: found === (want === 'hotspot') });
    } finally { server.close(); }
  }
  for (const r of results) say(`selftest ${r.ok ? 'ok  ' : 'FAIL'} ${r.name}: wanted ${r.want}, got ${r.got}`);
  process.exit(results.every((r) => r.ok) ? 0 : 1);
}

// ---- main ---------------------------------------------------------------------------------
const pw = await loadPlaywright();
if (args.selftest) await selftest(pw);

const sizes = parseSizes(args.sizes || args.size);
let server = null, base = args.url;
if (!base) {
  const root = resolve(args.site || join(HERE, '..', 'site'));
  if (!existsSync(join(root, 'index.html'))) die(`no index.html in ${root}`);
  ({ server, url: base } = await serve(root));
}
mkdirSync(OUT, { recursive: true });
const report = { tool: 'flickercheck', browser: OPT.browser, target: args.url || args.site || 'site', options: OPT, runs: [] };
let failed = 0;
for (const cfg of sizes) {
  const r = await sweep(pw, base, cfg);
  delete r.ys;
  report.runs.push(r);
  const tag = `${OPT.browser} ${cfg.w}x${cfg.h}@${cfg.dpr}`;
  if (r.skipped) { say(`${tag}: skipped (${r.skipped})`); continue; }
  failed += r.totalClusters ? 1 : 0;
  say(`${tag}: ${r.steps} steps in ${r.seconds.toFixed(0)}s, ${JSON.stringify(r.counts)} hotspots by block px${r.errors.length ? `, page errors: ${r.errors.join(' | ')}` : ''}`);
  for (const h of r.hotspots) {
    say(`  ${h.kind.padEnd(4)} @${String(h.scale).padStart(3)}px y=${h.y} (${h.journeyPct}% of the journey, steps ${h.yFrom}..${h.yTo}) box ${h.box.x.toFixed(0)},${h.box.y.toFixed(0)} ${h.box.w.toFixed(0)}x${h.box.h.toFixed(0)}  blocks ${h.blocks}  hits ${h.hits}  amp ${h.peak.toFixed(0)}  under: ${h.elements.join(' > ')}`);
  }
}
if (server) server.close();
writeFileSync(join(OUT, `report-${OPT.browser}.json`), JSON.stringify(report, null, 1));
console.log(JSON.stringify({ browser: OPT.browser, ok: failed === 0, runs: report.runs.map((r) => ({ size: `${r.cfg.w}x${r.cfg.h}@${r.cfg.dpr}`, steps: r.steps, hotspots: r.totalClusters ?? 0, skipped: r.skipped })), out: OUT })) ;
process.exit(failed ? 1 : 0);
