#!/usr/bin/env node
// tilecheck: does a phone run out of GPU memory and drop the page's tiles mid-scroll?
//
// Android Chrome keeps only so much of a page drawn. Past that budget it skips tiles, and on the
// site they showed as rectangles and diagonal strips of the light, the screen and the deck
// blinking out while the journey scrolled: the "spazzing" Laks caught three passes running
// (10-30). The songs were the cost: four lights and four desktops, each desktop with two turning
// copies wider than the screen, some 500-700 MB at 412 px wide. No DOM or style check sees a
// dropped tile, so this one compares pixels.
//
//   node tools/tilecheck.mjs [--site=DIR | --url=URL] [--mb=24] [--out=DIR]
//
// How: the page is opened twice in real Chrome on the GPU at a phone's size (412x915 at 2.625),
// once with --force-gpu-mem-available-mb=MB and once without, with time, the film and the
// page's own animations frozen at the same instant. Both are stepped down the first 40% of the
// journey. Any 16 px block that differs between the two at the same scroll point is a tile the
// capped Chrome did not draw. Exit 1 on any. The old layered songs dropped 3,523 blocks at 24 MB
// (and none at 64); the canvas songs drop none.
import { createServer } from 'node:http';
import { existsSync, statSync, createReadStream, mkdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve, extname, normalize, sep } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { decodePNG } from './lib/png.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const arg = (k, d) => process.argv.find((a) => a.startsWith(`--${k}=`))?.slice(k.length + 3) ?? d;
const MB = +arg('mb', 24), OUT = arg('out', '');

const require = createRequire(import.meta.url);
const pw = (() => {
  for (const r of [process.env.PLAYWRIGHT_DIR, process.cwd(), join(homedir(), 'rolepass'), join(homedir(), 'anaheim-wms'), HERE].filter(Boolean)) {
    try { return require(require.resolve('playwright', { paths: [r] })); } catch { /* next */ }
  }
  console.error('tilecheck: playwright is not installed (set PLAYWRIGHT_DIR)'); process.exit(2);
})();

// A static server with Range, so the film can be seeked.
const TYPES = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.webp': 'image/webp', '.png': 'image/png',
  '.svg': 'image/svg+xml', '.mp4': 'video/mp4', '.woff2': 'font/woff2' };
function serve(root) {
  const base = resolve(root);
  const server = createServer((req, res) => {
    let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (p.endsWith('/')) p += 'index.html';
    const file = normalize(join(base, p));
    if ((file !== base && !file.startsWith(base + sep)) || !existsSync(file) || !statSync(file).isFile()) { res.writeHead(404); return res.end(); }
    const size = statSync(file).size, head = { 'content-type': TYPES[extname(file)] || 'application/octet-stream', 'accept-ranges': 'bytes' };
    const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || '');
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

const freeze = () => {
  const T = 5000; performance.now = () => T;
  const raf = window.requestAnimationFrame.bind(window); window.requestAnimationFrame = (cb) => raf(() => cb(T));
};
async function shots(url, extra) {
  const b = await pw.chromium.launch({ channel: 'chrome', headless: true,
    args: ['--use-angle=metal', '--enable-gpu-rasterization', '--ignore-gpu-blocklist', ...extra] });
  try {
    const ctx = await b.newContext({ viewport: { width: 412, height: 915 }, deviceScaleFactor: 2.625, isMobile: true, hasTouch: true });
    await ctx.addInitScript(freeze);
    const p = await ctx.newPage();
    await p.goto(url); await p.waitForTimeout(3000);
    await p.evaluate(() => {
      const v = document.querySelector('[data-demo]'); if (v) { v.pause(); v.currentTime = 3; }
      for (const a of document.getAnimations()) if (a.timeline === document.timeline) { a.pause(); a.currentTime = 5000; }
    });
    await p.waitForTimeout(800);
    const H = await p.evaluate(() => document.querySelector('.journey').offsetHeight);
    const out = [];
    for (let i = 0; i <= 20; i++) {
      await p.evaluate((y) => scrollTo(0, y), Math.round(H * i * 0.02)); await p.waitForTimeout(350);
      out.push(await p.screenshot({ type: 'png', scale: 'css' }));
    }
    return out;
  } finally { await b.close(); }
}

const site = arg('site', join(HERE, '../site'));
const served = arg('url') ? null : await serve(site);
const url = arg('url', served?.url);
try {
  const capped = await shots(url, [`--force-gpu-mem-available-mb=${MB}`]);
  const free = await shots(url, []);
  let total = 0; const rows = [];
  for (let i = 0; i < capped.length; i++) {
    const a = decodePNG(capped[i]), c = decodePNG(free[i]), n = a.channels;
    let bad = 0;
    for (let by = 0; by + 16 <= a.height; by += 16) for (let bx = 0; bx + 16 <= a.width; bx += 16) {
      let d = 0;
      for (let y = by; y < by + 16; y++) for (let x = bx; x < bx + 16; x++) {
        const k = (y * a.width + x) * n;
        d += Math.abs(a.data[k] - c.data[k]) + Math.abs(a.data[k + 1] - c.data[k + 1]) + Math.abs(a.data[k + 2] - c.data[k + 2]);
      }
      if (d / 256 > 24) bad++;
    }
    total += bad; rows.push(`${i * 2}%:${bad}`);
    if (bad && OUT) { mkdirSync(OUT, { recursive: true }); writeFileSync(join(OUT, `capped-${i * 2}.png`), capped[i]); writeFileSync(join(OUT, `free-${i * 2}.png`), free[i]); }
  }
  console.log(`tilecheck ${MB} MB: ${total} dropped blocks  ${rows.join(' ')}`);
  process.exitCode = total ? 1 : 0;
} finally { served?.server.close(); }
