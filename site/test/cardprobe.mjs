/**
 * Render site/og.png the way a person does, and say whether the shipped one is
 * still it.
 *
 * `theShippedCardIsTheCurrentRender` in portcheck.mjs holds the card's stamp
 * against og.html's constants, and that is what runs on every commit, because
 * it needs nothing but node. It cannot compare PIXELS: doing that means a
 * browser and two families off Google Fonts, and check.sh is a headless gate
 * that has to fail on a missing dependency rather than skip one — a check that
 * needs a network is a check that goes amber on a plane and is ignored by the
 * third time.
 *
 * So the pixels live here, in a tool run on purpose. Two things it does:
 *
 *   node site/test/cardprobe.mjs            re-render and compare, write nothing
 *   node site/test/cardprobe.mjs --save     re-render and put it at site/og.png
 *
 * Comparing is the default because the other one overwrites a committed file.
 *
 * WHY THE BUTTON AND NOT A CANVAS READ. `stampedCard()` is module-scoped, so it
 * cannot be called from the protocol — but more importantly the button IS the
 * shipping path. It serialises the render before the encode on purpose, so that
 * the stamp and the pixels come from one moment; reaching past it to
 * `canvas.toDataURL()` would produce a card with no stamp and would stop
 * exercising the ordering that the comment in og.html was written to defend.
 * The download is caught with `Browser.setDownloadBehavior`, which writes the
 * file the page hands over rather than a re-encode of it, so what lands is
 * byte-for-byte what a person clicking Save would have got.
 *
 * WHAT BYTE-EQUALITY IS WORTH. Two renders on this machine, in separate browser
 * launches, two days and a commit apart, came back identical — so on one
 * machine this is a real comparison and not a coin toss. Across machines it is
 * not: a different Chrome or a reissued webfont moves glyph rasterisation, and
 * the honest answer to that is to look at the difference rather than to widen a
 * tolerance until it passes. So a mismatch says where the two files part and
 * leaves the judgement to a person.
 */
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, existsSync, mkdtempSync, readdirSync, rmSync } from 'node:fs';
import { join, dirname, extname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const shipped = join(root, 'og.png');
const save = process.argv.includes('--save');

const CHROME = process.env.CHROME
  || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const DEADLINE = 120_000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * A failure with an exit code, THROWN rather than exited on.
 *
 * `process.exit` inside the block below would skip its `finally`, which is
 * where the browser is killed and the server closed — so the tool that reports
 * a problem would be the one that leaks a headless Chrome and a listening
 * socket behind it. Every way out of the work goes through here or through the
 * end of the block, and teardown runs on all of them.
 */
class Failure extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
const fail = (code, message) => { throw new Failure(code, message); };

if (!existsSync(CHROME)) {
  process.stderr.write(`cardprobe: no Chrome at ${CHROME}. This tool needs one; set CHROME to `
    + 'point at it. The gate that runs without a browser is `theShippedCardIsTheCurrentRender` '
    + 'in portcheck.mjs\n');
  process.exit(2);
}

const work = mkdtempSync(join(tmpdir(), 'magnetite-card-'));
let chrome = null;
let server = null;
let timer = null;

function teardown() {
  if (timer) clearTimeout(timer);
  if (chrome && chrome.exitCode === null) {
    try { process.kill(chrome.pid, 'SIGKILL'); } catch { /* already gone */ }
  }
  if (server) server.close();
  rmSync(work, { recursive: true, force: true });
}

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json',
  '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml' };

/** The site, served from a port the OS picks. */
function serve() {
  return new Promise((resolve) => {
    server = createServer((req, res) => {
      // The request path is joined onto the site root and then checked to be
      // still inside it. A served directory plus a path from a request is how a
      // local probe turns into a file-read primitive, and this one is only ever
      // asked for its own pages.
      const path = normalize(join(root, decodeURIComponent(req.url.split('?')[0])));
      if (!path.startsWith(root) || !existsSync(path)) { res.writeHead(404); res.end(); return; }
      res.writeHead(200, { 'content-type': TYPES[extname(path)] || 'application/octet-stream' });
      res.end(readFileSync(path));
    });
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

/**
 * Chrome's devtools endpoint, on a port IT picks.
 *
 * A hardcoded debugging port is a probe that fails when two of these run at
 * once and, worse, one that can attach to a browser somebody else started. Port
 * 0 makes the OS choose, and Chrome writes the answer into its own profile.
 */
async function devtools(profile) {
  const portFile = join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 150; i++) {
    if (existsSync(portFile)) {
      const [port, path] = readFileSync(portFile, 'utf8').split('\n');
      if (port && path) return `ws://127.0.0.1:${port.trim()}${path.trim()}`;
    }
    if (chrome.exitCode !== null) fail(3, `Chrome exited with ${chrome.exitCode} before it listened`);
    await sleep(200);
  }
  return fail(3, 'Chrome never wrote a devtools port');
}

let code = 0;
try {
  // The deadline runs on the event loop, which is free the whole time here —
  // every wait below is a timer or a socket, never a blocking call — so this
  // fires rather than merely being requested. It tears down before it exits,
  // for the same reason `fail` throws.
  timer = setTimeout(() => {
    process.stderr.write(`cardprobe: nothing finished within ${DEADLINE / 1000}s\n`);
    teardown();
    process.exit(5);
  }, DEADLINE);

  const port = await serve();
  const downloads = join(work, 'downloads');
  const profile = join(work, 'profile');

  // The card is printed with WebGL, and a headless Chrome with no GPU only
  // offers the software rasteriser to a page when asked. The page is this
  // repository's own, served locally.
  chrome = spawn(CHROME, [
    '--headless=new', '--disable-gpu', '--enable-unsafe-swiftshader',
    '--hide-scrollbars', '--mute-audio',
    '--no-first-run', '--no-default-browser-check', '--force-device-scale-factor=1',
    `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank',
  ], { stdio: 'ignore' });

  const ws = new WebSocket(await devtools(profile));
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  let nextId = 0;
  const pending = new Map();
  const events = [];
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      if (m.error) reject(new Error(JSON.stringify(m.error))); else resolve(m.result);
    } else if (m.method) events.push(m);
  };
  const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = ++nextId;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });

  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const cmd = (method, params) => send(method, params, sessionId);

  await send('Browser.setDownloadBehavior',
    { behavior: 'allow', downloadPath: downloads, eventsEnabled: true });
  await cmd('Page.enable');
  await cmd('Runtime.enable');
  await cmd('Page.navigate', { url: `http://127.0.0.1:${port}/test/og.html` });
  for (let i = 0; i < 150; i++) {
    if (events.some((e) => e.method === 'Page.loadEventFired')) break;
    await sleep(100);
  }

  // The page reports its own readiness, and says whether the real face
  // resolved. A card rendered in a fallback face is the exact failure that
  // status line exists for, so it is read rather than waited past — and it is
  // how a machine with no network finds out, since the two families come from
  // Google and a card drawn without them looks like a different product from
  // the page it links to.
  let status = '';
  for (let i = 0; i < 100; i++) {
    const r = await cmd('Runtime.evaluate',
      { expression: 'document.getElementById("status").textContent', returnByValue: true });
    status = r.result.value || '';
    if (status.startsWith('ready')) break;
    await sleep(200);
  }
  if (!status.startsWith('ready')) {
    fail(3, `the card never finished rendering (status "${status}") — open test/og.html in a `
      + 'browser and read its console');
  }
  // Read as a VALUE, not out of the sentence above it. This used to look for
  // the substring "Archivo loaded: true" in the status text, which coupled a
  // tool to a copy edit — and worse, that sentence was printing
  // `document.fonts.check(...)`, which returns true on a page with no webfont
  // at all, so the guard could not have said no. Both halves were dead:
  // deleting og.html's stylesheet link produced a card in the fallback sans,
  // saved without complaint, measured.
  const faces = await cmd('Runtime.evaluate',
    { expression: 'document.body.dataset.faces || ""', returnByValue: true });
  if (faces.result.value !== 'ok') {
    fail(2, `the page came up as "${status}" — the webfonts did not arrive, so a card saved now `
      + 'would ship in a fallback face. Check the network before reading anything into a '
      + 'difference');
  }

  const before = new Set(existsSync(downloads) ? readdirSync(downloads) : []);
  await cmd('Runtime.evaluate',
    { expression: 'document.getElementById("save").click()', returnByValue: true });

  let landed = null;
  for (let i = 0; i < 150; i++) {
    const now = existsSync(downloads)
      ? readdirSync(downloads).filter((f) => !before.has(f) && f.endsWith('.png')) : [];
    if (now.length) { landed = join(downloads, now[0]); break; }
    await sleep(200);
  }
  if (!landed) fail(4, 'the Save button produced no PNG');

  const fresh = readFileSync(landed);
  if (save) {
    writeFileSync(shipped, fresh);
    process.stdout.write(`cardprobe: wrote ${fresh.length} bytes to site/og.png\n`);
    process.stdout.write('cardprobe: now run node site/test/portcheck.mjs\n');
  } else if (!existsSync(shipped)) {
    fail(1, 'site/og.png does not exist. Re-run with --save to put this render there');
  } else {
    const old = readFileSync(shipped);
    if (old.equals(fresh)) {
      process.stdout.write(`cardprobe: site/og.png is this render, to the byte (${old.length})\n`);
    } else {
      // Kept OUTSIDE the working directory this tool deletes, because the whole
      // value of a mismatch is being able to open the other file afterwards.
      const beside = join(tmpdir(), `magnetite-card-fresh-${process.pid}.png`);
      writeFileSync(beside, fresh);
      const at = old.length === fresh.length
        ? old.findIndex((b, i) => b !== fresh[i])
        : Math.min(old.length, fresh.length);
      process.stderr.write(
        `cardprobe: site/og.png is NOT this render — shipped ${old.length} bytes, fresh `
        + `${fresh.length}, first difference at byte ${at}.\n`
        + `  the fresh one is at ${beside}\n`
        + '  A file that grew or shrank with the same picture is the tEXt stamp moving, which is\n'
        + '  a real change and the reason to re-save. Different PIXELS at the same size is either\n'
        + '  the drawing having moved or this machine rasterising type differently from the one\n'
        + '  that saved the card. Decode both and look before deciding which.\n');
      code = 1;
    }
  }
} catch (error) {
  if (!(error instanceof Failure)) throw error;
  process.stderr.write(`cardprobe: ${error.message}\n`);
  code = error.code;
} finally {
  teardown();
}

process.exit(code);
