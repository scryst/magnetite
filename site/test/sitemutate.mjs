// Proves each check in sitecheck.mjs still rejects the regression it names.
//
// Each mutation breaks one thing in a temporary copy of site/ (plus the three
// repository files the checks read) and runs only the check that should catch
// it. A mutation that check passes, or that no longer applies because its target
// text moved, fails this harness, and so does a check with no mutation at all.
// The real tree is never written.
//
//   node site/test/sitemutate.mjs

import { cpSync, mkdtempSync, readFileSync, writeFileSync, rmSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const site = join(here, '..');
const repo = join(site, '..');
const check = join(here, 'sitecheck.mjs');

// The release-tied cases read the pinned release from install.sh and the size
// from the page, so a version bump does not leave them aiming at text that moved.
const installer = readFileSync(join(repo, 'install.sh'), 'utf8');
const VERSION = installer.match(/^PIN_VERSION="([^"]+)"/m)[1];
const PIN = installer.match(/^PIN_SHA256="([0-9a-f]{4})/m)[1];
const OTHER_PIN = (PIN[0] === 'f' ? '0' : 'f') + PIN.slice(1);
const [major, minor, patch] = VERSION.split('.').map(Number);
const OLDER = patch > 0 ? `${major}.${minor}.${patch - 1}` : `${major}.${minor - 1}.0`;
const KB = readFileSync(join(site, 'index.html'), 'utf8').match(/Free and open source, (\d+) KB\./)[1];
const ZIP = `releases/download/v${VERSION}/Magnetite-${VERSION}.zip`;

// [check, what breaks, file (relative to the copy's root), from, to]
// The copy's root holds site/ and the three repository files the checks read.
const MUTATIONS = [
  ['floor', 'the page offers an older release', 'site/index.html', `"softwareVersion": "${VERSION}"`, `"softwareVersion": "${OLDER}"`],
  ['floor', 'the app is a version behind the pin', 'Resources/Info.plist', `<string>${VERSION}</string>`, `<string>${OLDER}</string>`],
  ['floor', 'llms.txt offers an older release', 'site/llms.txt', `Magnetite v${VERSION}`, `Magnetite v${OLDER}`],
  ['download', 'a button links the releases page, not the zip', 'site/index.html', `href="https://github.com/scryst/magnetite-releases/${ZIP}"\n           aria-describedby="hero-requires"`, 'href="https://github.com/scryst/magnetite-releases/releases"\n           aria-describedby="hero-requires"'],
  ['download', 'the size is from an older build', 'site/index.html', `Free and open source, ${KB} KB.`, `Free and open source, ${Number(KB) + 2} KB.`],
  ['download', 'install.sh pins other bytes', 'install.sh', `PIN_SHA256="${PIN}`, `PIN_SHA256="${OTHER_PIN}`],
  ['requires', 'a download button lost its requirement', 'site/index.html', '\n         aria-describedby="requires"', ''],
  ['requires', 'the requirement drops Apple silicon', 'site/index.html', 'Needs macOS 26 on Apple silicon.', 'Needs macOS 26.'],
  ['crawlable', 'structured data stops parsing', 'site/index.html', '"isAccessibleForFree": true,', '"isAccessibleForFree": true,,'],
  ['crawlable', 'the screenshot points at a deleted file', 'site/index.html', 'media/demo-poster.webp",', 'media/desktop.webp",'],
  ['policies', 'the footer drops Privacy', 'site/index.html', '<a href="privacy.html">Privacy</a>', ''],
  ['type', 'the headline falls back to the old face', 'site/css/magnetite.css', "--display: 'Archivo'", "--display: 'Gloock'"],
  ['firstlaunch', 'the steps lose Open Anyway', 'site/index.html', 'Click <b>Open Anyway</b>', 'Click <b>Open</b>'],
  ['credit', 'the footer drops the licence link', 'site/index.html', 'from the Free Music Archive, under\n    <a href="https://creativecommons.org/licenses/by/4.0/" rel="external">CC BY 4.0</a>', 'from the Free Music Archive'],
  ['credit', 'credit names wrap', 'site/css/magnetite.css', '.demo__credit a, .foot__credit a { white-space: nowrap; }', ''],
  ['mark', 'the inline glyph is edited by hand', 'site/index.html', '<path fill="currentColor" d="M272.5 283C', '<path fill="currentColor" d="M272.5 284C'],
  ['mark', 'the menu-bar icon is edited by hand', 'Sources/NotchApp/App/MagnetiteMark.swift', 'static let aspect: CGFloat = ', 'static let aspect: CGFloat = 1.0 * '],
  ['demo', 'the box is not the film size', 'site/index.html', 'width="1600" height="700"', 'width="1600" height="900"'],
  ['demo', 'the film can make sound by itself', 'site/index.html', 'data-demo muted loop', 'data-demo loop'],
  ['script', 'a simulation script comes back', 'site/index.html', '<script type="module" src="js/site.js"></script>', '<script type="module" src="js/site.js"></script>\n<script type="module" src="js/sim.js"></script>'],
  ['script', 'site.js starts drawing', 'site/js/site.js', 'label();\n', 'label();\nrequestAnimationFrame(() => {});\n'],
  ['links', 'a link into test/', 'site/index.html', '<a href="privacy.html">Privacy</a>', '<a href="test/og.html">Privacy</a> <a href="privacy.html">Privacy</a>'],
  ['links', 'an anchor no element carries', 'site/index.html', '<a class="wings__get" href="#download">', '<a class="wings__get" href="#get">'],
];

const checks = [...readFileSync(check, 'utf8').matchAll(/^  (?:async )?(\w+)\(\) \{$/gm)].map((m) => m[1]);
const results = [];
for (const name of checks) {
  if (!MUTATIONS.some((m) => m[0] === name)) results.push(`FAIL ${name}: no mutation covers it`);
}

for (const [name, what, file, from, to] of MUTATIONS) {
  const root = mkdtempSync(join(tmpdir(), 'sitemutate-'));
  try {
    cpSync(site, join(root, 'site'), { recursive: true });
    mkdirSync(join(root, 'Resources'));
    cpSync(join(repo, 'Resources/Info.plist'), join(root, 'Resources/Info.plist'));
    cpSync(join(repo, 'install.sh'), join(root, 'install.sh'));
    cpSync(join(repo, 'Sources/NotchApp/App/MagnetiteMark.swift'), join(root, 'Sources/NotchApp/App/MagnetiteMark.swift'));
    const path = join(root, file);
    const text = readFileSync(path, 'utf8');
    if (!text.includes(from)) { results.push(`FAIL ${name}: "${what}" no longer applies (target text not in ${file})`); continue; }
    writeFileSync(path, text.replace(from, to));
    const run = spawnSync(process.execPath, [check, `--only=${name}`, `--site=${join(root, 'site')}`, `--repo=${root}`], { encoding: 'utf8' });
    results.push(run.status === 1 ? `ok   ${name}: rejects ${what}` : `FAIL ${name}: passed with ${what}\n${run.stdout}${run.stderr}`);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// The unmutated copy must pass every check, or the mutations prove nothing.
const clean = spawnSync(process.execPath, [check], { encoding: 'utf8' });
results.push(clean.status === 0 ? 'ok   baseline: the real tree passes' : `FAIL baseline\n${clean.stdout}`);

console.log(results.join('\n'));
process.exit(results.some((r) => r.startsWith('FAIL')) ? 1 : 0);
