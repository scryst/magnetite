// The product page's promises, read off the files that keep them.
//
// The page is static now: one film of the real app, one small script for its
// two buttons, and the download. So what can break is what it says. A version
// that is not the one the installer pins, a size from the last build, a
// requirement a download button no longer points at, a credit the license asks
// for, a poster that is not the film's size, or a link to a file that moved.
// Each check below names the mistake it catches.
//
//   node site/test/sitecheck.mjs                 # every check
//   node site/test/sitecheck.mjs --only=floor    # one check (sitemutate.mjs uses this)
//   node site/test/sitecheck.mjs --site=DIR      # check a copy of site/ (likewise)
//
// Exits 1 if any check fails.

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(process.argv.slice(2).map((a) => {
  const m = a.match(/^--(\w+)=(.*)$/);
  if (!m) { console.error(`unknown argument ${a}`); process.exit(2); }
  return [m[1], m[2]];
}));
const site = resolve(args.site ?? join(here, '..'));
const repo = resolve(args.repo ?? join(site, '..'));

const read = (path) => readFileSync(join(site, path), 'utf8');
const html = read('index.html');
const css = read('css/magnetite.css');
const installer = readFileSync(join(repo, 'install.sh'), 'utf8');
const plist = readFileSync(join(repo, 'Resources/Info.plist'), 'utf8');

const pinned = installer.match(/^PIN_VERSION="([^"]+)"$/m)?.[1];
const pinSha = installer.match(/^PIN_SHA256="([0-9a-f]{64})"$/m)?.[1];
const appVersion = plist.match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)?.[1];
const zipPath = join(site, 'downloads', `Magnetite-${pinned}.zip`);
const releaseZip = `https://github.com/scryst/magnetite-releases/releases/download/v${pinned}/Magnetite-${pinned}.zip`;

// Every start tag with its attributes, so a check can ask "the element with X".
const tags = [...html.matchAll(/<([a-z][\w-]*)((?:\s+[\w:-]+(?:="[^"]*")?)*)\s*\/?>/g)].map((m) => ({
  name: m[1],
  at: m.index,
  attrs: Object.fromEntries([...m[2].matchAll(/([\w:-]+)(?:="([^"]*)")?/g)].map((a) => [a[1], a[2] ?? ''])),
}));
const byId = (id) => tags.find((t) => t.attrs.id === id);
// The text of the element whose start tag is `tag`, up to its matching close.
const textOf = (tag) => {
  const close = html.indexOf(`</${tag.name}>`, tag.at);
  return html.slice(tag.at, close).replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ').trim();
};

const CHECKS = {
  // The page, the app and the installer name one release. 0.1.10 shipped with
  // the page still offering 0.1.9 for a day.
  floor() {
    const out = [];
    if (!pinned || !pinSha) out.push('install.sh has no PIN_VERSION/PIN_SHA256');
    if (appVersion !== pinned) out.push(`Info.plist says ${appVersion}, install.sh pins ${pinned}`);
    const versions = new Set([...html.matchAll(/\bv?(\d+\.\d+\.\d+)\b/g)].map((m) => m[1]));
    for (const v of versions) if (v !== pinned) out.push(`index.html mentions ${v}, install.sh pins ${pinned}`);
    const ld = JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]);
    if (ld.softwareVersion !== pinned) out.push(`structured data says ${ld.softwareVersion}`);
    if (ld.downloadUrl !== releaseZip) out.push(`structured data downloads ${ld.downloadUrl}`);
    const llms = read('llms.txt');
    for (const m of llms.matchAll(/\bv?(\d+\.\d+\.\d+)\b/g)) if (m[1] !== pinned) out.push(`llms.txt mentions ${m[1]}`);
    return out;
  },

  // Every Download is the pinned zip on GitHub, and the zip beside the site is
  // the one the pin hashes, at the size the page prints (as Finder shows it).
  download() {
    const out = [];
    const buttons = tags.filter((t) => 'data-download' in t.attrs);
    if (buttons.length < 2) out.push(`expected the hero and the download section to each have a download button, found ${buttons.length}`);
    for (const b of buttons) if (b.attrs.href !== releaseZip) out.push(`a download button links ${b.attrs.href}`);
    if (!existsSync(zipPath)) return [...out, `missing ${zipPath}`];
    const bytes = readFileSync(zipPath);
    const sha = createHash('sha256').update(bytes).digest('hex');
    if (sha !== pinSha) out.push(`Magnetite-${pinned}.zip hashes to ${sha}, install.sh pins ${pinSha}`);
    const sidecar = read(`downloads/Magnetite-${pinned}.sha256`).trim();
    if (sidecar !== `${pinSha}  Magnetite-${pinned}.zip`) out.push(`the .sha256 file says "${sidecar}"`);
    const kb = `${Math.round(bytes.length / 1000)} KB`;
    for (const m of html.matchAll(/(\d+(?:\.\d+)?) ?([KM]B)\b/g)) {
      if (`${m[1]} ${m[2]}` !== kb) out.push(`the page says ${m[1]} ${m[2]}, the zip is ${kb}`);
    }
    if (!html.includes(kb)) out.push(`the page never states the download size (${kb})`);
    return out;
  },

  // Each Download names what it runs on, through aria-describedby, so a screen
  // reader hears the requirement with the button and nobody downloads a Mac app
  // for an Intel Mac or macOS 15 without having been told.
  requires() {
    const out = [];
    for (const b of tags.filter((t) => 'data-download' in t.attrs)) {
      const target = byId(b.attrs['aria-describedby'] ?? '');
      if (!target) { out.push(`download button ${b.attrs.href} describes no element`); continue; }
      if (!('data-requires' in target.attrs)) out.push(`#${target.attrs.id} is not marked data-requires`);
      const text = textOf(target);
      for (const need of ['macOS 26', 'Apple silicon']) if (!text.includes(need)) out.push(`#${target.attrs.id} does not say ${need}`);
    }
    return out;
  },

  // Search engines and share sheets get a real picture and a parseable record.
  crawlable() {
    const out = [];
    let ld;
    try { ld = JSON.parse(html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]); }
    catch (e) { return [`structured data does not parse: ${e.message}`]; }
    for (const key of ['image', 'screenshot']) {
      const local = ld[key]?.replace('https://magnetite.app/', '');
      if (!local || !existsSync(join(site, local))) out.push(`structured data ${key} ${ld[key]} is not a file in site/`);
    }
    for (const prop of ['og:image', 'twitter:image']) {
      const url = html.match(new RegExp(`(?:property|name)="${prop}" content="([^"]+)"`))?.[1];
      if (!url?.startsWith('https://')) out.push(`${prop} is not an absolute URL`);
      else if (!existsSync(join(site, url.replace('https://magnetite.app/', '')))) out.push(`${prop} ${url} is not a file`);
    }
    const og = readFileSync(join(site, 'og.png'));
    const [w, h] = [og.readUInt32BE(16), og.readUInt32BE(20)];
    if (w !== 1200 || h !== 630) out.push(`og.png is ${w}×${h}, its meta says 1200×630`);
    if (!/<link rel="canonical" href="https:\/\/magnetite\.app\/">/.test(html)) out.push('no canonical link');
    if (!/<h1\b/.test(html)) out.push('no h1');
    return out;
  },

  // Privacy and Terms exist and sit in the footer, where every page keeps them;
  // a link in one FAQ answer is not one people find.
  policies() {
    const out = [];
    const foot = html.slice(html.indexOf('<footer'), html.indexOf('</footer>'));
    for (const page of ['privacy.html', 'terms.html']) {
      if (!existsSync(join(site, page))) out.push(`missing ${page}`);
      if (!foot.includes(`href="${page}"`)) out.push(`the footer does not link ${page}`);
    }
    return out;
  },

  // One typeface, self-hosted, with its license. Gloock was the last look and
  // must not come back by a stray font-family.
  type() {
    const out = [];
    const typeCss = read('css/type.css');
    const font = typeCss.match(/url\('\.\.\/(fonts\/[^']+\.woff2)'\)/)?.[1];
    if (!font || !existsSync(join(site, font))) out.push(`type.css loads ${font}, which is not a file`);
    if (!html.includes(`href="${font}" as="font"`)) out.push(`index.html does not preload ${font}`);
    const license = typeCss.match(/OFL: (fonts\/OFL-[\w-]+\.txt)/)?.[1];
    if (!license || !existsSync(join(site, license))) out.push(`type.css names no font license file that ships (${license})`);
    for (const [name, text] of [['index.html', html], ['magnetite.css', css], ['legal.css', read('css/legal.css')]]) {
      if (/gloock/i.test(text)) out.push(`${name} still names Gloock`);
    }
    const display = css.match(/--display:\s*'([^']+)'/)?.[1];
    if (display !== 'Geist') out.push(`the display face is ${display}, not Geist`);
    if (!/\bvar\(--display\)/.test(css.match(/\.hero__title\s*\{[^}]*\}/)?.[0] ?? '')) out.push('the headline is not set in the display face');
    return out;
  },

  // The zip is not notarised, so macOS blocks the first launch. The steps past
  // that must stay on the page, and say Open Anyway, or the download is a dead end.
  firstlaunch() {
    const out = [];
    const box = tags.find((t) => 'data-firstlaunch' in t.attrs);
    if (!box) return ['no [data-firstlaunch]'];
    const text = textOf(box);
    for (const need of ['Applications', 'Privacy & Security', 'Open Anyway']) if (!text.includes(need)) out.push(`first-launch steps do not say ${need}`);
    if (box.attrs.id !== 'first-launch') out.push('first-launch steps lost their #first-launch anchor');
    return out;
  },

  // CC BY 4.0 asks for the title, the artist and the license wherever the track
  // plays: under the film and in the footer. A credit is never split mid-name.
  credit() {
    const out = [];
    for (const cls of ['demo__credit', 'foot__credit']) {
      const tag = tags.find((t) => t.attrs.class === cls);
      if (!tag) { out.push(`no .${cls}`); continue; }
      const block = html.slice(tag.at, html.indexOf('</p>', tag.at));
      for (const href of ['https://freemusicarchive.org/music/beat-mekanik/', 'https://freemusicarchive.org/music/beat-mekanik/single/encryption/', 'https://creativecommons.org/licenses/by/4.0/']) {
        if (!block.includes(`href="${href}"`)) out.push(`.${cls} does not link ${href}`);
      }
      for (const words of ['Beat Mekanik', 'Encryption', 'CC BY 4.0']) if (!block.includes(words)) out.push(`.${cls} does not say ${words}`);
    }
    const nowrap = css.replace(/\/\*[\s\S]*?\*\//g, '').match(/([^{}]*)\{\s*white-space:\s*nowrap;\s*\}/g) ?? [];
    for (const sel of ['.foot__credit a', '.demo__credit a']) {
      if (!nowrap.some((rule) => rule.split('{')[0].split(',').map((s) => s.trim()).includes(sel))) out.push(`${sel} can wrap`);
    }
    return out;
  },

  // The bar's mark, the favicon and the menu-bar icon are one glyph, derived
  // from the icon master by gen-mark.mjs. Re-derive it and hold each consumer
  // to the result, so a hand edit to any of them fails here.
  async mark() {
    const out = [];
    const gen = await import(pathToFileURL(join(site, 'test/gen-mark.mjs')).href);
    const mark = gen.deriveMark();
    if (read('favicon.svg') !== gen.faviconSVG(mark)) out.push('favicon.svg is not what gen-mark.mjs derives');
    if (html.match(gen.GLYPH_IN_PAGE)?.[0] !== gen.inlineGlyph(mark)) out.push('the #mark symbol in index.html is not what gen-mark.mjs derives');
    if (!html.includes('<use href="#mark"')) out.push('nothing uses #mark');
    const swift = readFileSync(join(repo, 'Sources/NotchApp/App/MagnetiteMark.swift'), 'utf8');
    if (swift !== gen.markSwift(mark)) out.push('MagnetiteMark.swift is not what gen-mark.mjs derives');
    if (out.length > 1) out.push('rerun node site/test/gen-mark.mjs');
    // The symbol sheet is an inline <svg>, 300×150 by default: without a zero-size
    // rule it pushes the whole page down on a phone (2026-10-29, a 157 px gap).
    const sheet = html.match(/<svg class="([\w-]+)"[^>]*>\s*<symbol/)?.[1];
    const sized = sheet && css.match(new RegExp(`\\.${sheet}\\s*\\{[^}]*\\}`))?.[0];
    if (!sized || !/width:\s*0[;\s]/.test(sized) || !/height:\s*0[;\s]/.test(sized)) out.push(`the #mark symbol sheet (.${sheet}) has no zero width and height in magnetite.css, so it takes 150 px of the page`);
    return out;
  },

  // The film is the app's own panel, and its poster and box are its size, so
  // nothing jumps when it loads and the poster is not a stale frame from another cut.
  demo() {
    const out = [];
    const video = tags.find((t) => t.name === 'video');
    if (!video) return ['no video'];
    const source = tags.find((t) => t.name === 'source' && t.at > video.at);
    const film = join(site, source?.attrs.src ?? '');
    if (!source || !existsSync(film)) return [`video source ${source?.attrs.src} is not a file`];
    const [codec, fw, fh] = mp4Video(readFileSync(film));
    if (codec !== 'h264') out.push(`the film is ${codec}; Safari and every browser play h264`);
    if (`${fw}×${fh}` !== `${video.attrs.width}×${video.attrs.height}`) out.push(`the film is ${fw}×${fh}, the video tag says ${video.attrs.width}×${video.attrs.height}`);
    const poster = readFileSync(join(site, video.attrs.poster ?? ''));
    const [pw, ph] = webpSize(poster);
    if (`${pw}×${ph}` !== `${fw}×${fh}`) out.push(`the poster is ${pw}×${ph}, the film ${fw}×${fh}`);
    if (statSync(film).size > 6e6) out.push(`the film is ${(statSync(film).size / 1e6).toFixed(1)} MB; keep it under 6`);
    for (const attr of ['muted', 'playsinline', 'loop']) if (!(attr in video.attrs)) out.push(`the video is not ${attr}`);
    if (!video.attrs['aria-describedby'] || !byId(video.attrs['aria-describedby'])) out.push('the video has no description');
    for (const hook of ['data-demo-play', 'data-demo-sound']) if (!tags.some((t) => t.name === 'button' && hook in t.attrs)) out.push(`no button[${hook}]`);
    return out;
  },

  // No simulations. The page runs one module, site.js, which drives the film's
  // two buttons; the old canvas sims cost a fan spin and a second of main thread.
  script() {
    const out = [];
    const scripts = tags.filter((t) => t.name === 'script' && t.attrs.type !== 'application/ld+json');
    if (scripts.length !== 1 || scripts[0].attrs.src !== 'js/site.js') out.push(`scripts: ${scripts.map((s) => s.attrs.src ?? 'inline').join(', ')}`);
    const js = readdirSync(join(site, 'js'));
    if (js.join() !== 'site.js') out.push(`site/js holds ${js.join(', ')}`);
    const code = read('js/site.js');
    if (/canvas|requestAnimationFrame|AudioContext|Worklet/i.test(code)) out.push('site.js draws or listens to audio again');
    if (statSync(join(site, 'js/site.js')).size > 4000) out.push('site.js grew past 4 KB');
    return out;
  },

  // US spelling in everything a visitor or crawler reads. The British forms of
  // "license", "notarized" and "visualizer" shipped until Laks caught them (2026-10-29).
  spelling() {
    const out = [];
    const uk = /\b(licence|colour\w*|favourite\w*|notaris\w*|organis\w*|visualis\w*|authoris\w*|normalis\w*|programme|centre[sd]?|behaviour\w*|catalogue|grey)\b/gi; // us-spelling: ok
    for (const page of ['index.html', 'privacy.html', 'terms.html', 'llms.txt']) {
      const text = read(page).replace(/https?:\/\/\S+/g, '');
      for (const m of text.matchAll(uk)) out.push(`${page} says "${m[0]}"; write US English`);
    }
    return out;
  },

  // The page has no color of its own: every color in its stylesheets is a
  // neutral, so the recording is the only color on screen. A pink full stop
  // was added as flair and Laks called it random (2026-10-29).
  accent() {
    const out = [];
    for (const name of ['css/magnetite.css', 'css/legal.css']) {
      const text = read(name).replace(/\/\*[\s\S]*?\*\//g, '');
      for (const m of text.matchAll(/#([0-9a-f]{6}|[0-9a-f]{3})\b|rgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)/gi)) {
        const hex = m[1] && (m[1].length === 3 ? [...m[1]].map((c) => c + c).join('') : m[1]);
        const rgb = hex ? [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16)) : [m[2], m[3], m[4]].map(Number);
        if (Math.max(...rgb) - Math.min(...rgb) > 12) out.push(`${name} uses ${m[0]}, a color; the page keeps to neutrals`);
      }
    }
    return out;
  },

  // The MacBook is drawn to Apple's measurements, not by eye. These are read
  // off Apple's top-down store photo of the 14-inch (mbp14-spaceblack-gallery2,
  // the body 1298 px wide) in hundredths of the body's width. The grilles were
  // drawn at half their width and Laks caught it (2026-10-29).
  deck() {
    const out = [];
    const text = read('css/magnetite.css');
    const rule = (sel) => text.match(new RegExp(`^${sel.replace(/[.:]/g, '\\$&')} \\{([^}]*)\\}`, 'm'))?.[1] ?? '';
    const num = (decls, prop) => decls.match(new RegExp(`(?:^|[\\s;])${prop}:\\s*([\\d.]+)cqw`))?.[1];
    const near = (what, got, want) => {
      if (got === undefined || Number.isNaN(Number(got))) out.push(`${what} is not set in cqw`);
      else if (Math.abs(Number(got) - want) > 0.3) out.push(`${what} is ${got}cqw; Apple's photo measures ${want}`);
    };
    const deck = rule('.mac__deck');
    const cols = deck.match(/grid-template-columns:\s*([\d.]+)cqw\s+([\d.]+)cqw\s+([\d.]+)cqw/);
    const gap = num(deck, 'column-gap');
    if (!cols) out.push('.mac__deck has no three-column grid in cqw');
    else {
      near('the grille width', cols[1], 4.4);
      near('the keyboard well width', cols[2], 89.4);
      near('the grille inset from the side', (100 - Number(cols[1]) * 2 - Number(cols[2]) - Number(gap) * 2) / 2, 0.6);
    }
    near('the well top', num(deck, 'padding-top'), 5.55);
    near('the grille height', num(rule('.mac__grille'), 'height'), 33.9);
    const pad = rule('.mac__pad');
    near('the trackpad width', num(pad, 'width'), 41.4);
    near('the trackpad height', num(pad, 'height'), 25.9);
    const scoop = rule('.mac__front::before');
    near('the front scoop width', num(scoop, 'width'), 17);
    near('the front scoop left', num(scoop, 'left'), 41.5);
    return out;
  },

  // Every local href and src on every page is a file that ships. deploy.sh drops
  // test/ and downloads/, so a link into either is a 404 in production.
  links() {
    const out = [];
    for (const page of ['index.html', 'privacy.html', 'terms.html']) {
      const text = read(page);
      for (const m of text.matchAll(/\b(?:href|src|poster)="([^"#:]+?)(?:#[^"]*)?"/g)) {
        const path = m[1];
        if (/^(test|downloads)\//.test(path)) out.push(`${page} links ${path}, which deploy.sh does not publish`);
        else if (!existsSync(join(site, path))) out.push(`${page} links ${path}, which is not a file`);
      }
      for (const m of text.matchAll(/href="#([^"]+)"/g)) {
        if (!text.includes(`id="${m[1]}"`)) out.push(`${page} links #${m[1]}, which no element carries`);
      }
    }
    for (const file of readdirSync(join(site, 'media'))) {
      const used = [html, read('llms.txt'), css].some((t) => t.includes(`media/${file}`));
      if (!used) out.push(`media/${file} ships but nothing uses it`);
    }
    return out;
  },
};

// The first video sample entry in the film's sample table: its codec and size.
// Read from the bytes rather than ffprobe, which check-runtime's PATH does not carry.
function mp4Video(buf) {
  const stsd = buf.indexOf('stsd');
  if (stsd < 0) return ['none', 0, 0];
  const entry = stsd + 4 + 8; // version and flags, entry count
  const type = buf.toString('ascii', entry + 4, entry + 8);
  const codec = { avc1: 'h264', avc3: 'h264', hvc1: 'hevc', hev1: 'hevc', av01: 'av1' }[type] ?? type;
  return [codec, buf.readUInt16BE(entry + 8 + 24), buf.readUInt16BE(entry + 8 + 26)];
}

function webpSize(buf) {
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WEBP') return [0, 0];
  const chunk = buf.toString('ascii', 12, 16);
  if (chunk === 'VP8X') return [1 + buf.readUIntLE(24, 3), 1 + buf.readUIntLE(27, 3)];
  if (chunk === 'VP8L') {
    const b = buf.readUInt32LE(21);
    return [1 + (b & 0x3fff), 1 + ((b >> 14) & 0x3fff)];
  }
  return [buf.readUInt16LE(26) & 0x3fff, buf.readUInt16LE(28) & 0x3fff];
}

const names = args.only ? [args.only] : Object.keys(CHECKS);
let failed = 0;
for (const name of names) {
  if (!CHECKS[name]) { console.error(`no check named ${name}`); process.exit(2); }
  let problems;
  try { problems = await CHECKS[name](); } catch (e) { problems = [`threw: ${e.message}`]; }
  if (problems.length) {
    failed++;
    console.log(`FAIL ${name}`);
    for (const p of problems) console.log(`     ${p}`);
  } else {
    console.log(`ok   ${name}`);
  }
}
process.exit(failed ? 1 : 0);
